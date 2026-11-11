// Sana model adapters. One interface, one file per provider: adding a provider = one new file + one line in pick().
// Runtime-neutral (fetch only, erasable TypeScript), so the same code runs in the Supabase Edge Function (Deno) and in the
// local test gateway (Node 24 type stripping).

export interface ToolSpec { name: string; description: string; input_schema: Record<string, unknown> }
export interface ToolCall { id: string; name: string; input: Record<string, unknown> }
/** A message in the provider's own format (the core only appends what the adapter gives it). */
export type ProviderMessage = { role: 'user' | 'assistant'; content: unknown };
export interface Turn {
  text: string;            // the text of this turn (may be a short preamble when the model also calls tools)
  toolCalls: ToolCall[];   // empty = final answer
  assistant: ProviderMessage; // to append to the history before the tool results
}
export interface AskRequest {
  system: string;
  messages: ProviderMessage[];
  tools: ToolSpec[];
  maxTokens: number;
  signal: AbortSignal;
  /** Streaming: called with each text delta as it arrives. Without it the call is non-streaming. */
  onText?: (delta: string) => void;
}
export interface SanaModel {
  name: string;
  ask(req: AskRequest): Promise<Turn>;
  toolResults(results: Array<{ id: string; content: string }>): ProviderMessage;
}

export class ModelError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}

// ---------- Anthropic Messages API (tool use, optional SSE streaming) ----------
type Block = { type: string; text?: string; id?: string; name?: string; input?: Record<string, unknown> };

export function anthropic(apiKey: string, model: string): SanaModel {
  const headers = { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' };
  return {
    name: `anthropic:${model}`,
    toolResults: (results) => ({ role: 'user', content: results.map((r) => ({ type: 'tool_result', tool_use_id: r.id, content: r.content })) }),
    async ask({ system, messages, tools, maxTokens, signal, onText }) {
      const body = { model, max_tokens: maxTokens, system, messages, tools, ...(onText ? { stream: true } : {}) };
      const res = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers, body: JSON.stringify(body), signal });
      if (!res.ok) throw new ModelError(`model error ${res.status}`, res.status);
      let blocks: Block[] = [];
      if (!onText) {
        const data = await res.json() as { content: Block[] };
        blocks = data.content ?? [];
      } else {
        // Server-sent events: content_block_start / content_block_delta (text_delta | input_json_delta) / content_block_stop.
        const partial: Record<number, { block: Block; json: string }> = {};
        const reader = (res.body as ReadableStream<Uint8Array>).getReader();
        const dec = new TextDecoder();
        let buf = '';
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += dec.decode(value, { stream: true });
          let i: number;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
            const line = chunk.split('\n').find((l) => l.startsWith('data:'));
            if (!line) continue;
            let ev: { type: string; index?: number; content_block?: Block; delta?: { type: string; text?: string; partial_json?: string }; error?: { message?: string } };
            try { ev = JSON.parse(line.slice(5).trim()); } catch { continue; }
            if (ev.type === 'error') throw new ModelError(ev.error?.message ?? 'model stream error', 502);
            if (ev.type === 'content_block_start' && ev.content_block) partial[ev.index ?? 0] = { block: { ...ev.content_block, text: ev.content_block.text ?? '' }, json: '' };
            if (ev.type === 'content_block_delta' && ev.delta) {
              const p = partial[ev.index ?? 0];
              if (!p) continue;
              if (ev.delta.type === 'text_delta' && ev.delta.text) { p.block.text = (p.block.text ?? '') + ev.delta.text; onText(ev.delta.text); }
              if (ev.delta.type === 'input_json_delta') p.json += ev.delta.partial_json ?? '';
            }
          }
        }
        blocks = Object.keys(partial).map(Number).sort((a, b) => a - b).map((k) => {
          const p = partial[k];
          if (p.block.type === 'tool_use') { try { p.block.input = p.json ? JSON.parse(p.json) : {}; } catch { p.block.input = {}; } }
          return p.block;
        });
      }
      return {
        text: blocks.filter((b) => b.type === 'text').map((b) => b.text ?? '').join('\n').trim(),
        toolCalls: blocks.filter((b) => b.type === 'tool_use').map((b) => ({ id: b.id ?? '', name: b.name ?? '', input: b.input ?? {} })),
        assistant: { role: 'assistant', content: blocks },
      };
    },
  };
}

/** The configured model, or null = basic mode. Keys come only from server secrets. */
export function pickModel(env: { ANTHROPIC_API_KEY?: string; SANA_MODEL?: string; SANA_PROVIDER?: string }): SanaModel | null {
  const provider = (env.SANA_PROVIDER || 'anthropic').toLowerCase();
  if (provider === 'anthropic' && env.ANTHROPIC_API_KEY) return anthropic(env.ANTHROPIC_API_KEY, env.SANA_MODEL || 'claude-sonnet-5-5');
  return null;
}

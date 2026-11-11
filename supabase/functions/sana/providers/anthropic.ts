// Anthropic Messages API adapter (tool use, optional SSE streaming). Since S2 the FALLBACK provider: used only when the
// Supabase secret SANA_PROVIDER=anthropic, with ANTHROPIC_API_KEY. The key is sent only in the x-api-key header.
import { ModelError, sseJson, type SanaModel, type Usage } from './types.ts';

export const ANTHROPIC_BASE = 'https://api.anthropic.com';
export const ANTHROPIC_DEFAULT_MODEL = 'claude-sonnet-5-5';

type Block = { type: string; text?: string; id?: string; name?: string; input?: Record<string, unknown> };

/** baseUrl exists for the LOCAL provider mock only (the local gateway passes it; the Edge Function never does). */
export function anthropic(apiKey: string, model: string, opts: { baseUrl?: string } = {}): SanaModel {
  const base = (opts.baseUrl || ANTHROPIC_BASE).replace(/\/+$/, '');
  const headers = { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' };
  return {
    provider: 'anthropic',
    model,
    name: `anthropic:${model}`,
    toolResults: (results) => ({ role: 'user', content: results.map((r) => ({ type: 'tool_result', tool_use_id: r.id, content: r.content })) }),
    async ask({ system, messages, tools, maxTokens, signal, onText }) {
      const body = { model, max_tokens: maxTokens, system, messages, tools, ...(onText ? { stream: true } : {}) };
      const res = await fetch(`${base}/v1/messages`, { method: 'POST', headers, body: JSON.stringify(body), signal });
      if (!res.ok) throw new ModelError(`model error ${res.status}`, res.status);
      let blocks: Block[] = [];
      let stop = '';
      const usage: Usage = { in: 0, out: 0 };
      if (!onText) {
        const data = await res.json() as { content: Block[]; stop_reason?: string; usage?: { input_tokens?: number; output_tokens?: number } };
        blocks = data.content ?? [];
        stop = data.stop_reason ?? '';
        usage.in = data.usage?.input_tokens ?? 0; usage.out = data.usage?.output_tokens ?? 0;
      } else {
        // message_start / content_block_start / content_block_delta (text_delta | input_json_delta) / content_block_stop /
        // message_delta (stop_reason, usage) / message_stop
        const partial: Record<number, { block: Block; json: string }> = {};
        for await (const raw of sseJson(res.body as ReadableStream<Uint8Array>)) {
          const ev = raw as { type: string; index?: number; content_block?: Block; message?: { usage?: { input_tokens?: number } };
            delta?: { type?: string; text?: string; partial_json?: string; stop_reason?: string }; usage?: { output_tokens?: number }; error?: { message?: string } };
          if (ev.type === 'error') throw new ModelError(ev.error?.message ?? 'model stream error', 502);
          if (ev.type === 'message_start') usage.in = ev.message?.usage?.input_tokens ?? 0;
          if (ev.type === 'message_delta') { stop = ev.delta?.stop_reason ?? stop; usage.out = ev.usage?.output_tokens ?? usage.out; }
          if (ev.type === 'content_block_start' && ev.content_block) partial[ev.index ?? 0] = { block: { ...ev.content_block, text: ev.content_block.text ?? '' }, json: '' };
          if (ev.type === 'content_block_delta' && ev.delta) {
            const p = partial[ev.index ?? 0];
            if (!p) continue;
            if (ev.delta.type === 'text_delta' && ev.delta.text) { p.block.text = (p.block.text ?? '') + ev.delta.text; onText(ev.delta.text); }
            if (ev.delta.type === 'input_json_delta') p.json += ev.delta.partial_json ?? '';
          }
        }
        blocks = Object.keys(partial).map(Number).sort((a, b) => a - b).map((k) => {
          const p = partial[k];
          if (p.block.type === 'tool_use') { try { p.block.input = p.json ? JSON.parse(p.json) : {}; } catch { p.block.input = {}; } }
          return p.block;
        });
      }
      const text = blocks.filter((b) => b.type === 'text').map((b) => b.text ?? '').join('\n').trim();
      return {
        text,
        toolCalls: blocks.filter((b) => b.type === 'tool_use').map((b) => ({ id: b.id ?? '', name: b.name ?? '', input: b.input ?? {} })),
        assistant: { role: 'assistant', content: blocks.length ? blocks : [{ type: 'text', text: '(no answer)' }] },
        refused: stop === 'refusal',
        usage,
      };
    },
  };
}

// Sana model adapters: the shared interface. Runtime-neutral (fetch only, erasable TypeScript), so the same code runs in the
// Supabase Edge Functions (Deno) and in the local test gateway (Node 24 type stripping).

export interface ToolSpec { name: string; description: string; input_schema: Record<string, unknown> }
export interface ToolCall { id: string; name: string; input: Record<string, unknown> }
/** A message in the provider's own format (the core only appends what the adapter gives it). */
export type ProviderMessage = { role: 'user' | 'assistant'; content: unknown };
export interface Usage { in: number; out: number }
export interface Turn {
  text: string;            // the text of this turn (may be a short preamble when the model also calls tools)
  toolCalls: ToolCall[];   // empty = final answer
  assistant: ProviderMessage; // to append to the history before the tool results
  /** The provider declined to answer (Anthropic stop_reason "refusal", Gemini safety block): Sana gives the standard refusal. */
  refused?: boolean;
  /** Token counts reported by the provider for this call (input, output incl. thinking). */
  usage?: Usage;
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
  /** 'gemini' | 'anthropic' */
  provider: string;
  model: string;
  /** provider:model, e.g. gemini:gemini-3.8-flash */
  name: string;
  ask(req: AskRequest): Promise<Turn>;
  toolResults(results: Array<{ id: string; content: string }>): ProviderMessage;
}

export class ModelError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}

/** Server-sent events: yields the JSON of every `data:` line (both providers stream this way). */
export async function* sseJson(body: ReadableStream<Uint8Array>): AsyncGenerator<Record<string, unknown>> {
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true }).replace(/\r\n/g, '\n');
    let i: number;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
      const data = chunk.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join('');
      if (!data || data === '[DONE]') continue;
      try { yield JSON.parse(data); } catch { /* not JSON: skip */ }
    }
  }
}

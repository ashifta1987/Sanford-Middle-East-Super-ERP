// Gemini adapter (S2, decision 11 Nov 2026: Gemini is Sana's single AI provider for text and voice).
// REST API v1beta: models/{model}:generateContent and :streamGenerateContent?alt=sse, function calling, speech-to-text
// (audio in generateContent) and text-to-speech (the TTS model returns 16-bit PCM that we wrap as WAV for the browser).
// The key comes only from the Edge Function's environment (GEMINI_API_KEY) and is sent only in the x-goog-api-key header,
// never in a URL, a log, a response or an error message.
// Runtime-neutral (fetch, atob/btoa, TextDecoder, erasable TypeScript): runs in Deno (Edge Functions) and Node 24 (local gateway).
import { ModelError, sseJson, type SanaModel, type ToolSpec, type Turn, type Usage } from './types.ts';

export const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta';
/** Text (and tool use). Secret SANA_MODEL. */
export const GEMINI_DEFAULT_MODEL = 'gemini-3.8-flash';
/** Speech-to-text runs on the normal multimodal model (audio in, text out). Secret SANA_STT_MODEL. */
export const GEMINI_DEFAULT_STT_MODEL = 'gemini-3.8-flash';
/** Text-to-speech model. Secret SANA_VOICE_MODEL. */
export const GEMINI_DEFAULT_TTS_MODEL = 'gemini-3.8-flash-tts';
/** Prebuilt TTS voice. Secret SANA_TTS_VOICE. */
export const GEMINI_DEFAULT_VOICE = 'Kore';

// Finish reasons / block reasons that mean "the provider declined" (Sana answers with the standard refusal).
const BLOCKED = new Set(['SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII', 'RECITATION', 'IMAGE_SAFETY', 'OTHER']);

type Part = { text?: string; thought?: boolean; thoughtSignature?: string; functionCall?: { name: string; args?: Record<string, unknown>; id?: string };
  functionResponse?: unknown; inlineData?: { mimeType: string; data: string } };
type GenResponse = {
  candidates?: Array<{ content?: { role?: string; parts?: Part[] }; finishReason?: string }>;
  promptFeedback?: { blockReason?: string };
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number };
  error?: { message?: string; code?: number };
};

const KEEP = new Set(['type', 'description', 'enum', 'properties', 'required', 'items', 'format', 'nullable', 'minimum', 'maximum']);
/** JSON schema of a Sana tool → Gemini (OpenAPI subset) schema. Unknown keywords are dropped. */
export function toGeminiSchema(s: unknown): Record<string, unknown> {
  if (!s || typeof s !== 'object' || Array.isArray(s)) return {};
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(s as Record<string, unknown>)) {
    if (!KEEP.has(k)) continue;
    if (k === 'properties' && v && typeof v === 'object') out.properties = Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([p, d]) => [p, toGeminiSchema(d)]));
    else if (k === 'items') out.items = toGeminiSchema(v);
    else out[k] = v;
  }
  return out;
}
/** Tools → functionDeclarations. Tools without parameters get no `parameters` (Gemini refuses an empty object schema). */
export function functionDeclarations(tools: ToolSpec[]) {
  return tools.map((t) => {
    const props = (t.input_schema?.properties ?? {}) as Record<string, unknown>;
    return Object.keys(props).length ? { name: t.name, description: t.description, parameters: toGeminiSchema(t.input_schema) } : { name: t.name, description: t.description };
  });
}

function usageOf(u: GenResponse['usageMetadata']): Usage {
  return { in: u?.promptTokenCount ?? 0, out: (u?.candidatesTokenCount ?? 0) + (u?.thoughtsTokenCount ?? 0) };
}
function headers(apiKey: string) { return { 'x-goog-api-key': apiKey, 'content-type': 'application/json' }; }
async function post(url: string, apiKey: string, body: unknown, signal: AbortSignal): Promise<Response> {
  const res = await fetch(url, { method: 'POST', headers: headers(apiKey), body: JSON.stringify(body), signal });
  if (!res.ok) {
    // Google's own error message only (status + reason); the request body is never echoed.
    let reason = '';
    try { reason = String(((await res.json()) as { error?: { message?: string } })?.error?.message ?? '').slice(0, 300); } catch { /* no JSON body */ }
    throw new ModelError(`model error ${res.status}${reason ? ': ' + reason : ''}`, res.status);
  }
  return res;
}

export interface GeminiOptions { baseUrl?: string; thinkingBudget?: number | null }

/** baseUrl exists for the LOCAL provider mock only (the local gateway passes it; the Edge Function never does). */
export function gemini(apiKey: string, model: string, opts: GeminiOptions = {}): SanaModel {
  const base = (opts.baseUrl || GEMINI_BASE).replace(/\/+$/, '');
  // Gemini Flash models think by default and thinking tokens count as output: Sana's answers are lookups, so thinking is off
  // (budget 0) unless SANA_THINKING_BUDGET says otherwise. Models that cannot switch it off (Pro) get no thinkingConfig.
  const budget = opts.thinkingBudget ?? (/flash/.test(model) ? 0 : null);
  const ids = new Map<string, { name: string; gid?: string }>();
  let seq = 0;
  const toContents = (messages: Array<{ role: string; content: unknown }>) => messages.map((m) => ({
    role: m.role === 'assistant' ? 'model' : 'user',
    parts: typeof m.content === 'string' ? [{ text: m.content || '(empty)' }] : m.content,
  }));
  return {
    provider: 'gemini',
    model,
    name: `gemini:${model}`,
    toolResults: (results) => ({
      role: 'user',
      content: results.map((r) => {
        const call = ids.get(r.id);
        let response: unknown;
        try { response = JSON.parse(r.content); } catch { response = { text: r.content }; }   // a result cut at 12 kB is no longer JSON
        if (!response || typeof response !== 'object' || Array.isArray(response)) response = { result: response };
        return { functionResponse: { name: call?.name ?? 'unknown', ...(call?.gid ? { id: call.gid } : {}), response } };
      }),
    }),
    async ask({ system, messages, tools, maxTokens, signal, onText }): Promise<Turn> {
      const decl = functionDeclarations(tools);
      const body = {
        systemInstruction: { parts: [{ text: system }] },
        contents: toContents(messages),
        ...(decl.length ? { tools: [{ functionDeclarations: decl }], toolConfig: { functionCallingConfig: { mode: 'AUTO' } } } : {}),
        generationConfig: { maxOutputTokens: maxTokens, temperature: 0.2, ...(budget != null ? { thinkingConfig: { thinkingBudget: budget } } : {}) },
      };
      const path = `${base}/models/${encodeURIComponent(model)}`;
      const parts: Part[] = [];
      let finish = '';
      let block = '';
      let usage: Usage = { in: 0, out: 0 };
      const take = (r: GenResponse, stream: boolean) => {
        if (r.error) throw new ModelError(r.error.message ?? 'model error', r.error.code ?? 502);
        if (r.promptFeedback?.blockReason) block = r.promptFeedback.blockReason;
        const c = r.candidates?.[0];
        if (c?.finishReason) finish = c.finishReason;
        for (const p of c?.content?.parts ?? []) {
          if (p.text != null && !p.thought && !p.functionCall) {
            if (!p.text && !p.thoughtSignature) continue;
            if (stream && onText && p.text) onText(p.text);
          }
          parts.push(p);
        }
        if (r.usageMetadata) usage = usageOf(r.usageMetadata);
      };
      if (onText) {
        const res = await post(`${path}:streamGenerateContent?alt=sse`, apiKey, body, signal);
        for await (const chunk of sseJson(res.body as ReadableStream<Uint8Array>)) take(chunk as GenResponse, true);
      } else {
        const res = await post(`${path}:generateContent`, apiKey, body, signal);
        take(await res.json() as GenResponse, false);
      }
      if (finish === 'MALFORMED_FUNCTION_CALL') throw new ModelError('malformed function call', 502);
      const text = parts.filter((p) => typeof p.text === 'string' && !p.thought && !p.functionCall).map((p) => p.text).join('').trim();
      const toolCalls = parts.filter((p) => p.functionCall).map((p) => {
        const id = `g${++seq}`;
        ids.set(id, { name: p.functionCall!.name, gid: p.functionCall!.id });
        return { id, name: p.functionCall!.name, input: (p.functionCall!.args ?? {}) as Record<string, unknown> };
      });
      // The model's own parts go back unchanged (thought signatures must be returned with function calls).
      const own = parts.filter((p) => !p.thought || p.thoughtSignature);
      return {
        text,
        toolCalls,
        assistant: { role: 'assistant', content: own.length ? own : [{ text: '(no answer)' }] },
        refused: !text && !toolCalls.length && (Boolean(block) || BLOCKED.has(finish)),
        usage,
      };
    },
  };
}

// ---------- Voice ----------
const b64ToBytes = (b64: string) => { const bin = atob(b64); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };

/** Speech-to-text: audio (base64) → the words as spoken, in their own script. */
export async function geminiTranscribe(o: { apiKey: string; model: string; baseUrl?: string; audio: string; mime: string; languageHint: string; signal: AbortSignal }):
  Promise<{ text: string; usage: Usage }> {
  const base = (o.baseUrl || GEMINI_BASE).replace(/\/+$/, '');
  const prompt = `Transcribe this recording of a person asking a business question. ${o.languageHint} `
    + 'Write exactly the words spoken, in the language and script they were spoken in (do not translate, do not answer the question, '
    + 'do not add comments). Write numbers and codes as digits. If there is no speech, return nothing.';
  const body = {
    contents: [{ role: 'user', parts: [{ inlineData: { mimeType: o.mime, data: o.audio } }, { text: prompt }] }],
    generationConfig: { temperature: 0, maxOutputTokens: 400, ...(/flash/.test(o.model) ? { thinkingConfig: { thinkingBudget: 0 } } : {}) },
  };
  const res = await post(`${base}/models/${encodeURIComponent(o.model)}:generateContent`, o.apiKey, body, o.signal);
  const r = await res.json() as GenResponse;
  const text = (r.candidates?.[0]?.content?.parts ?? []).filter((p) => p.text && !p.thought).map((p) => p.text).join('').trim();
  return { text, usage: usageOf(r.usageMetadata) };
}

/** Text-to-speech: answer text → 16-bit mono PCM from the TTS model (sample rate from its mime type, 24 kHz by default). */
export async function geminiSpeak(o: { apiKey: string; model: string; voice: string; baseUrl?: string; text: string; signal: AbortSignal }):
  Promise<{ pcm: Uint8Array; rate: number; isWav: boolean; usage: Usage }> {
  const base = (o.baseUrl || GEMINI_BASE).replace(/\/+$/, '');
  const body = {
    contents: [{ role: 'user', parts: [{ text: o.text }] }],
    generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: o.voice } } } },
  };
  const res = await post(`${base}/models/${encodeURIComponent(o.model)}:generateContent`, o.apiKey, body, o.signal);
  const r = await res.json() as GenResponse;
  const inline = (r.candidates?.[0]?.content?.parts ?? []).find((p) => p.inlineData?.data)?.inlineData;
  if (!inline) throw new ModelError('no audio in the reply', 502);
  const rate = Number(inline.mimeType.match(/rate=(\d+)/)?.[1] ?? 24000);
  const bytes = b64ToBytes(inline.data);
  // gemini-3.8-flash-tts returns a complete WAV (RIFF header); older TTS models return headerless PCM.
  const isWav = bytes.length > 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46;
  return { pcm: bytes, rate, isWav, usage: usageOf(r.usageMetadata) };
}

/** Wraps 16-bit little-endian mono PCM in a WAV header, so every browser can play it. */
export function pcmToWav(pcm: Uint8Array, rate: number, channels = 1, bits = 16): Uint8Array {
  const out = new Uint8Array(44 + pcm.length);
  const v = new DataView(out.buffer);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) out[o + i] = s.charCodeAt(i); };
  str(0, 'RIFF'); v.setUint32(4, 36 + pcm.length, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, channels, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * channels * bits / 8, true); v.setUint16(32, channels * bits / 8, true); v.setUint16(34, bits, true);
  str(36, 'data'); v.setUint32(40, pcm.length, true);
  out.set(pcm, 44);
  return out;
}

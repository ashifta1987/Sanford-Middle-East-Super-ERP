// SANA voice through the provider (S2): speech-to-text and text-to-speech with Gemini, for companies whose admin chose
// voice mode "provider" (Administration › Add-Ons › AI Assistant (Sana)). Solves "no Malayalam voice on this device".
// Runtime-neutral (fetch only, erasable TypeScript): the Supabase Edge Function (index.ts, Deno) and the local test gateway
// (Node 24) run this same file.
//
// Privacy: audio is NEVER stored or logged — not in a table, not in a log line, not in an error. It goes from the request
// straight to Gemini and the reply goes straight back. Only metadata is audited (erp.sana_voice_use: mode, language, seconds,
// provider, model, ok). Every call needs the user's own token; sana_status / sana_voice_use apply the company settings
// (Sana on, voice on, voice mode provider, languages, daily limit).
import { detectLanguage, LANGS, makeRpc, plainForVoice, redact, type Env } from '../sana/core.ts';
import { voiceModels } from '../sana/providers.ts';
import { geminiSpeak, geminiTranscribe, pcmToWav } from '../sana/providers/gemini.ts';

// S4 voice policy (16 Nov 2026): Gemini TTS is 10 requests/minute and 100/day on the key, so the device voice is the default and
// Gemini speaks only when the user ticks "Always use Sana's voice". Per user per day at most TTS_DAILY_CAP Gemini calls (a cache hit
// costs nothing and is still served). Counted from sana_usage.voice_calls (provider speech-to-text calls count too); this becomes a
// per-company setting in erp.sana_settings later (needs SQL).
export const TTS_DAILY_CAP = 10;
export const VOICE_LIMITS = { audioBytes: 1_500_000, seconds: 60, ttsChars: 1500, timeoutMs: 25_000 };
const AUDIO_TYPES = ['audio/wav', 'audio/x-wav', 'audio/wave', 'audio/webm', 'audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/mp3', 'audio/aac', 'audio/flac'];

type Json = Record<string, unknown>;
interface Status { profile: boolean; enabled: boolean; voice_enabled?: boolean; voice_mode?: string; daily_limit?: number; used?: number; voice_calls?: number; languages?: string[]; company?: string }
export type VoiceResult = { status: number; json: unknown } | { status: number; audio: Uint8Array; headers: Record<string, string> };

const b64Bytes = (b64: string) => Math.floor((b64.length * 3) / 4) - (b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0);
/** Seconds of a PCM WAV from its header (byte rate) and size; null when it is not a WAV. */
function wavSeconds(b64: string): number | null {
  try {
    const head = atob(b64.slice(0, 64));
    if (head.slice(0, 4) !== 'RIFF' || head.slice(8, 12) !== 'WAVE') return null;
    const byteRate = head.charCodeAt(28) | (head.charCodeAt(29) << 8) | (head.charCodeAt(30) << 16) | (head.charCodeAt(31) << 24);
    return byteRate > 0 ? Math.max(0, b64Bytes(b64) - 44) / byteRate : null;
  } catch { return null; }
}

// S4: text-to-speech cache, in memory for the life of the function instance only (never written anywhere). Key = model, voice,
// language and the already-filtered text, so repeated sentences ("Good morning.") are free. Least recently used entries go
// first; capped at 200 entries and 16 MB of PCM. Only text the caller sent is matched, so a hit never reveals anything new.
const ttsCache = new Map<string, { pcm: Uint8Array; rate: number }>();
let ttsBytes = 0;
const TTS_CACHE = { entries: 200, bytes: 16_000_000 };
const ttsKey = (model: string, voice: string, lang: string, text: string) => `${model}\u0000${voice}\u0000${lang}\u0000${text}`;
function ttsPut(key: string, v: { pcm: Uint8Array; rate: number }) {
  if (v.pcm.length > TTS_CACHE.bytes / 4) return;
  ttsCache.set(key, v); ttsBytes += v.pcm.length;
  for (const [k, old] of ttsCache) {
    if (ttsCache.size <= TTS_CACHE.entries && ttsBytes <= TTS_CACHE.bytes) break;
    ttsCache.delete(k); ttsBytes -= old.pcm.length;
  }
}
export const ttsCacheClear = () => { ttsCache.clear(); ttsBytes = 0; };

export async function handleVoice(auth: string | null, body: unknown, env: Env): Promise<VoiceResult> {
  const fail = (status: number, error: string): VoiceResult => ({ status, json: { error } });
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return fail(401, 'Sign in to use Sana.');
  const b = (body ?? {}) as Json;
  const mode = b.mode === 'stt' || b.mode === 'tts' ? b.mode : null;
  if (!mode) return fail(400, 'Say whether to listen (stt) or speak (tts).');
  const company = typeof b.company === 'string' && /^[A-Z0-9]{2,8}$/.test(b.company) && b.company !== 'GRP' ? b.company : null;
  const asked = typeof b.language === 'string' && b.language !== 'auto' && LANGS[b.language] ? b.language : null;
  const rpc = makeRpc(env, auth);
  try {
    const st = await rpc('sana_status', { p_company: company }) as Status;
    if (!st?.profile) return fail(403, 'You need a Southfield profile to use Sana. Ask IT to add you.');
    if (!st.enabled) return fail(403, 'Sana is switched off for your company. Ask your system admin.');
    if (st.voice_enabled === false) return fail(403, 'Voice is switched off for your company. Type your question instead.');
    if (st.voice_mode !== 'provider') return fail(409, `Provider voice is not switched on for ${st.company}. The browser's own voice is used.`);
    const lim = st.daily_limit ?? 200;
    if ((st.used ?? 0) >= lim || (st.voice_calls ?? 0) >= 2 * lim) return fail(429, `You've reached today's limit of ${lim} questions. It resets at midnight.`);
    if (!env.GEMINI_API_KEY) return fail(503, "Provider voice isn't set up on the server yet. The browser's own voice is used.");
    const langs = st.languages?.length ? st.languages : Object.keys(LANGS);
    if (asked && !langs.includes(asked)) return fail(400, `That language is not switched on for Sana in ${st.company}.`);
    const fallbackLang = langs.includes('en') ? 'en' : langs[0];
    const m = voiceModels(env);
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), Number(env.SANA_TIMEOUT_MS) || VOICE_LIMITS.timeoutMs);
    const record = (lang: string, seconds: number, model: string, ok: boolean) =>
      rpc('sana_voice_use', { p_company: company, p_mode: mode, p_language: lang, p_seconds: Math.round(seconds * 10) / 10, p_provider: 'gemini', p_model: model, p_ok: ok });
    try {
      if (mode === 'stt') {
        const audio = typeof b.audio === 'string' ? b.audio.replace(/\s+/g, '') : '';
        const mime = typeof b.mime === 'string' ? b.mime.split(';')[0].trim().toLowerCase() : '';
        if (!audio || !/^[A-Za-z0-9+/]+={0,2}$/.test(audio)) return fail(400, 'Record your question first.');
        if (!AUDIO_TYPES.includes(mime)) return fail(415, 'This recording format is not supported. Try again in Chrome, Edge or Safari, or type instead.');
        if (b64Bytes(audio) > VOICE_LIMITS.audioBytes) return fail(413, 'Keep voice questions under 60 seconds.');
        const claimed = typeof b.seconds === 'number' && b.seconds >= 0 ? b.seconds : 0;
        const seconds = wavSeconds(audio) ?? Math.min(claimed, VOICE_LIMITS.seconds);
        if (seconds > VOICE_LIMITS.seconds) return fail(413, 'Keep voice questions under 60 seconds.');
        const hint = asked ? `The speaker uses ${LANGS[asked]}.`
          : `The speaker most likely uses one of: ${langs.map((l) => LANGS[l]).join(', ')} (English and Malayalam are the most common).`;
        let text = '';
        try {
          text = (await geminiTranscribe({ apiKey: env.GEMINI_API_KEY, model: m.stt, baseUrl: env.SANA_GEMINI_BASE_URL, audio, mime, languageHint: hint, signal: ac.signal })).text;
        } catch (e) {
          console.error('sana stt failed', (e as { status?: number })?.status ?? 'network', (e as Error)?.message ?? '');
          await record(asked ?? fallbackLang, seconds, m.stt, false).catch(() => {});
          return fail(502, "Sana couldn't hear that clearly. Try again or type your question.");
        }
        text = text.replace(/\s+/g, ' ').trim().slice(0, 2000);
        let lang = detectLanguage(text, asked ?? undefined);
        if (!langs.includes(lang)) lang = fallbackLang;
        await record(lang, seconds, m.stt, Boolean(text));
        if (!text) return fail(422, "I didn't hear anything. Tap the microphone and try again.");
        return { status: 200, json: { text, language: lang, provider: 'gemini', model: m.stt, seconds: Math.round(seconds * 10) / 10 } };
      }
      // tts
      const raw = typeof b.text === 'string' ? b.text : '';
      const text = redact(plainForVoice(raw)).slice(0, VOICE_LIMITS.ttsChars).trim();
      if (!text) return fail(400, 'There is nothing to read aloud.');
      let lang = asked ?? detectLanguage(text);
      if (!langs.includes(lang)) lang = fallbackLang;
      // S4: 'pcm16' = raw 16-bit little-endian mono PCM (rate in X-Sana-Rate) for the browser's Web Audio queue; default WAV.
      const pcm16 = b.format === 'pcm16';
      const key = ttsKey(m.tts, m.voice, lang, text);
      let hit = ttsCache.get(key);
      const cached = Boolean(hit);
      if (!hit && (st.voice_calls ?? 0) >= TTS_DAILY_CAP) {
        return fail(429, "Sana's own voice is used up for today. Your device's voice reads the answers instead.");
      }
      if (!hit) {
        try {
          const r = await geminiSpeak({ apiKey: env.GEMINI_API_KEY, model: m.tts, voice: m.voice, baseUrl: env.SANA_GEMINI_BASE_URL, text, signal: ac.signal });
          hit = { pcm: r.isWav ? r.pcm.subarray(44) : r.pcm, rate: r.rate };
          ttsPut(key, hit);
        } catch (e) {
          console.error('sana tts failed', (e as { status?: number })?.status ?? 'network', (e as Error)?.message ?? '');
          await record(lang, 0, m.tts, false).catch(() => {});
          return fail(502, "Sana couldn't read that aloud right now. Try again in a moment.");
        }
      } else { ttsCache.delete(key); ttsCache.set(key, hit); }   // most recently used last
      const seconds = hit.pcm.length / (hit.rate * 2);
      // every call is still counted (daily voice limit); a cache hit is marked in the model name
      await record(lang, seconds, cached ? `${m.tts}:cache` : m.tts, true);
      return { status: 200, audio: pcm16 ? hit.pcm : pcmToWav(hit.pcm, hit.rate),
        headers: { 'Content-Type': pcm16 ? `audio/L16; rate=${hit.rate}; channels=1` : 'audio/wav', 'Cache-Control': 'no-store', 'X-Sana-Provider': 'gemini',
          'X-Sana-Model': m.tts, 'X-Sana-Language': lang, 'X-Sana-Seconds': String(Math.round(seconds * 10) / 10), 'X-Sana-Rate': String(hit.rate),
          'X-Sana-Format': pcm16 ? 'pcm16' : 'wav', 'X-Sana-Cache': cached ? 'hit' : 'miss' } };
    } finally { clearTimeout(timer); }
  } catch (e) {
    const err = e as { status?: number; message?: string; code?: string };
    if (err.code === 'P0001' && /limit/.test(err.message ?? '')) return fail(429, err.message!);
    if (err.code === '42501' || err.code === 'P0001') return fail(err.code === '42501' ? 403 : 400, err.message ?? 'Not allowed.');
    if (err.status === 401 || err.status === 403) return fail(403, "You don't have access to Sana.");
    return fail(502, "Sana's voice couldn't answer right now. Try again in a moment.");
  }
}

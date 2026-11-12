// Supabase Edge Function "sana-voice" (S2): provider voice for Sana with Gemini, for companies whose voice mode is "provider".
//   POST { mode: 'stt', audio: <base64>, mime: 'audio/wav', language: 'auto'|'en'|'ml'|…, company? }  → { text, language, provider, model, seconds }
//   POST { mode: 'tts', text, language?, company? }                                                → audio/wav (16-bit PCM from the Gemini TTS model)
// Needs the user's session token. Audio is never stored or logged; only metadata is audited (erp.sana_voice_use).
// Deploy:  supabase functions deploy sana-voice
// Secrets: GEMINI_API_KEY (already set on live — never printed or written anywhere), optional SANA_STT_MODEL
//          (default gemini-3.8-flash), SANA_VOICE_MODEL (TTS, default gemini-3.8-flash-tts), SANA_TTS_VOICE (default Kore).
// The test-only base-URL variable of the local provider mock is deliberately NOT read here.
import { handleVoice } from './core.ts';
import type { Env } from '../sana/core.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, accept',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Expose-Headers': 'x-sana-provider, x-sana-model, x-sana-language, x-sana-seconds',
};
const get = (k: string) => Deno.env.get(k) || undefined;
const env = (): Env => ({
  SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '',
  SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  GEMINI_API_KEY: get('GEMINI_API_KEY'),
  SANA_STT_MODEL: get('SANA_STT_MODEL'),
  SANA_VOICE_MODEL: get('SANA_VOICE_MODEL'),
  SANA_TTS_VOICE: get('SANA_TTS_VOICE'),
});

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const size = Number(req.headers.get('content-length') ?? 0);
  if (size > 2_200_000) return Response.json({ error: 'Keep voice questions under 60 seconds.' }, { status: 413, headers: cors });
  const body = await req.json().catch(() => null);
  const r = await handleVoice(req.headers.get('Authorization'), body, env());
  if ('audio' in r) return new Response(r.audio.slice().buffer as ArrayBuffer, { status: r.status, headers: { ...cors, ...r.headers } });
  return Response.json(r.json, { status: r.status, headers: cors });
});

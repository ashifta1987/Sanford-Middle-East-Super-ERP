// Sana model adapters. One interface (providers/types.ts), one file per provider; the Supabase secret SANA_PROVIDER picks one.
//   gemini    (default, decision 11 Nov 2026) — providers/gemini.ts, key GEMINI_API_KEY, model SANA_MODEL (default gemini-2.5-flash)
//   anthropic (fallback)                      — providers/anthropic.ts, key ANTHROPIC_API_KEY, model SANA_MODEL if it is a
//                                               claude-* name, else claude-sonnet-5-5
// No key for the chosen provider = basic mode (keyword routing, no model). Keys are read only from the Edge Function's
// environment and never leave it. Adding a provider = one new file + one line in pickModel().
// Runtime-neutral (fetch only, erasable TypeScript), so the same code runs in the Supabase Edge Functions (Deno) and in the
// local test gateway (Node 24 type stripping).
import { anthropic, ANTHROPIC_DEFAULT_MODEL } from './providers/anthropic.ts';
import { gemini, GEMINI_DEFAULT_MODEL, GEMINI_DEFAULT_STT_MODEL, GEMINI_DEFAULT_TTS_MODEL, GEMINI_DEFAULT_VOICE } from './providers/gemini.ts';
import type { SanaModel } from './providers/types.ts';

export { ModelError, type AskRequest, type ProviderMessage, type SanaModel, type ToolCall, type ToolSpec, type Turn, type Usage } from './providers/types.ts';
export { anthropic } from './providers/anthropic.ts';
export { gemini } from './providers/gemini.ts';

export interface ProviderEnv {
  SANA_PROVIDER?: string;
  SANA_MODEL?: string;
  GEMINI_API_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  SANA_THINKING_BUDGET?: string;
  SANA_STT_MODEL?: string;
  SANA_VOICE_MODEL?: string;
  SANA_TTS_VOICE?: string;
  /** LOCAL TESTING ONLY: the local gateway points the adapters at scripts/local-stack/provider-mock.mjs. The Edge Functions
   *  never set these (their index.ts does not read them), so deployed code always talks to the real provider. */
  SANA_GEMINI_BASE_URL?: string;
  SANA_ANTHROPIC_BASE_URL?: string;
}

export const providerName = (env: ProviderEnv): 'gemini' | 'anthropic' => ((env.SANA_PROVIDER || 'gemini').trim().toLowerCase() === 'anthropic' ? 'anthropic' : 'gemini');
export function modelName(env: ProviderEnv): string {
  const m = (env.SANA_MODEL || '').trim();
  if (providerName(env) === 'anthropic') return /^claude-[A-Za-z0-9._-]{1,60}$/.test(m) ? m : ANTHROPIC_DEFAULT_MODEL;
  return /^gemini-[A-Za-z0-9._-]{1,60}$/.test(m) ? m : GEMINI_DEFAULT_MODEL;
}
const budget = (v?: string) => (v != null && /^\d{1,5}$/.test(v.trim()) ? Number(v) : null);

/** The configured model, or null = basic mode. Keys come only from server secrets. */
export function pickModel(env: ProviderEnv): SanaModel | null {
  if (providerName(env) === 'anthropic') return env.ANTHROPIC_API_KEY ? anthropic(env.ANTHROPIC_API_KEY, modelName(env), { baseUrl: env.SANA_ANTHROPIC_BASE_URL }) : null;
  return env.GEMINI_API_KEY ? gemini(env.GEMINI_API_KEY, modelName(env), { baseUrl: env.SANA_GEMINI_BASE_URL, thinkingBudget: budget(env.SANA_THINKING_BUDGET) }) : null;
}

/** Voice models (provider voice always uses Gemini, whatever SANA_PROVIDER says). */
export const voiceModels = (env: ProviderEnv) => ({
  stt: /^gemini-[A-Za-z0-9._-]{1,60}$/.test(env.SANA_STT_MODEL ?? '') ? env.SANA_STT_MODEL! : GEMINI_DEFAULT_STT_MODEL,
  tts: /^gemini-[A-Za-z0-9._-]{1,60}$/.test(env.SANA_VOICE_MODEL ?? '') ? env.SANA_VOICE_MODEL! : GEMINI_DEFAULT_TTS_MODEL,
  voice: /^[A-Za-z]{2,30}$/.test(env.SANA_TTS_VOICE ?? '') ? env.SANA_TTS_VOICE! : GEMINI_DEFAULT_VOICE,
});

/** What the admin screen may show: names and yes/no only — NEVER a key, a key prefix or a key length. */
export function providerConfig(env: ProviderEnv) {
  const provider = providerName(env);
  const v = voiceModels(env);
  return {
    provider,
    model: modelName(env),
    key_configured: provider === 'gemini' ? Boolean(env.GEMINI_API_KEY) : Boolean(env.ANTHROPIC_API_KEY),
    mode: pickModel(env) ? 'ai' : 'basic',
    voice: { provider: 'gemini', stt_model: v.stt, tts_model: v.tts, tts_voice: v.voice, key_configured: Boolean(env.GEMINI_API_KEY) },
    fallback: { provider: 'anthropic', key_configured: Boolean(env.ANTHROPIC_API_KEY) },
    /** true only in the local stack, when the gateway points Sana at the LOCAL-ONLY provider mock (not AI) */
    local_mock: Boolean(env.SANA_GEMINI_BASE_URL || env.SANA_ANTHROPIC_BASE_URL),
  };
}

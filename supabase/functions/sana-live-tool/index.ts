// Supabase Edge Function "sana-live-tool" (S5 · Sana Live, M1).
// The browser never calls the database for the Live model. It posts here with the user's session token:
//   { action: 'tool', live_session_id, company, tool: 'get_stock', args: { query } } → { result }   (erp.sana_stock, user JWT,
//      3 s guard, masked — the same RPC and role rule as Ask)
//   { action: 'log_turn', live_session_id, company, language, conversation_id?, user_text, sana_text, tools: [names],
//      timings: { ms_first_audio, ms_total }, device } → { conversation_id, message_id, unverified }
//      Logged like a typed turn (sana_log: conversation, messages, usage, audit) with context label 'live-test', then the timing
//      (sana_timing_set) and the audio beacon (sana_audio_beacon, engine 'gemini'). Rule 1a: a figure without a tool call is marked
//      unverified (label 'live-test-unverified'), because Live cannot be re-asked.
// M2 adds the server-side session table (51) so live_session_id is checked; in M1 every call is checked with the user's JWT only.
import { hasCompanyFigure, makeRpc, redact, type Env } from '../sana/core.ts';
import { maskDeep } from '../sana/mask.ts';
import { liveModel } from '../sana/live.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (status: number, body: unknown) => Response.json(body, { status, headers: cors });
const GUARD_MS = 3000;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Use POST.' });
  const auth = req.headers.get('Authorization');
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return json(401, { error: 'Sign in to use Sana.' });
  const b = await req.json().catch(() => ({})) as Record<string, unknown>;
  const company = typeof b.company === 'string' && /^[A-Z0-9]{2,8}$/.test(b.company) ? b.company : null;
  if (!company) return json(400, { error: 'Choose a company first.' });
  const env: Env = { SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '', SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '' };
  const rpc = makeRpc(env, auth);
  try {
    if (b.action === 'tool') {
      if (b.tool !== 'get_stock') return json(200, { result: { denied: true } });
      const who = await rpc('sana_whoami', {}) as { profile: boolean; topics?: Record<string, boolean> };
      if (!who?.profile || !who.topics?.stock) return json(200, { result: { denied: true } });
      const query = String((b.args as { query?: unknown } | undefined)?.query ?? '').slice(0, 80);
      let timer: ReturnType<typeof setTimeout> | undefined;
      const slow = new Promise((res) => { timer = setTimeout(() => res({ found: false, no_match: true, note: 'The lookup took too long; treat it as no match.' }), GUARD_MS); });
      const result = await Promise.race([rpc('sana_stock', { p_query: query, p_company: company }), slow]).finally(() => clearTimeout(timer));
      return json(200, { result: maskDeep(result) });
    }
    if (b.action === 'log_turn') {
      const tools = Array.isArray(b.tools) ? (b.tools as unknown[]).map(String).slice(0, 10) : [];
      const sana = redact(String(b.sana_text ?? '')).slice(0, 4000);
      const unverified = hasCompanyFigure(sana) && tools.length === 0;
      const t = (b.timings ?? {}) as { ms_first_audio?: number; ms_total?: number };
      const model = liveModel({ SANA_LIVE_MODEL: Deno.env.get('SANA_LIVE_MODEL') ?? undefined });
      const conv = typeof b.conversation_id === 'string' && /^[0-9a-f-]{36}$/i.test(b.conversation_id) ? b.conversation_id : null;
      const logged = await rpc('sana_log', { p_conversation: conv, p_company: company, p_language: typeof b.language === 'string' ? b.language : 'en',
        p_question: String(b.user_text ?? '').slice(0, 2000) || '(spoken)', p_answer: sana || '(no answer)', p_tools: tools.map((x) => ({ tool: x })), p_sources: [],
        p_denied: false, p_mode: 'ai', p_via: 'voice', p_context: { type: 'page', label: unverified ? 'live-test-unverified' : 'live-test' }, p_fallback: false,
        p_provider: 'gemini', p_model: model, p_tokens: null }) as { conversation_id: string; message_id: number };
      const msTotal = Number.isFinite(t.ms_total) ? Math.round(t.ms_total!) : null, msAudio = Number.isFinite(t.ms_first_audio) ? Math.round(t.ms_first_audio!) : null;
      await rpc('sana_timing_set', { p_message: logged.message_id, p_timing: { ms_first_token: msAudio ?? msTotal ?? 0, ms_total: msTotal ?? msAudio ?? 0, tool_rounds: tools.length, model_fast: model } }).catch(() => null);
      if (msAudio != null) await rpc('sana_audio_beacon', { p_message: logged.message_id, p_ms_first_audio: msAudio, p_engine: 'gemini', p_device: b.device === 'phone' ? 'phone' : 'desktop' }).catch(() => null);
      return json(200, { ...logged, unverified });
    }
    return json(400, { error: 'Unknown action.' });
  } catch (e) {
    const err = e as { code?: string; status?: number; message?: string };
    if (err.code === 'P0001' && /limit/.test(err.message ?? '')) return json(429, { error: err.message });
    if (err.code === '42501' || err.status === 403) return json(403, { error: "You don't have access to that." });
    console.error('sana-live-tool', err.status ?? 'error', String(err.message ?? '').slice(0, 200));
    return json(502, { error: "Sana Live couldn't do that right now." });
  }
});

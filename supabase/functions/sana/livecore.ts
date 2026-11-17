// Sana Live (S5 · M2) · the two server handlers, runtime-neutral (fetch only, erasable TypeScript): the Edge Functions
// sana-live-token / sana-live-tool (Deno) and the local test gateway (Node) run this same file.
//
// handleLiveToken: the same checks as `sana` (profile, company, Sana and voice on, daily question limit), then a server-side
// session (erp.sana_live_start: refused at the daily Live-minutes cap) and a single-use ephemeral token (≤ 10 min, never longer
// than the minutes left) with the whole setup locked in it: model, system instruction, the role's allowed tools (the same list
// as Ask), audio, and transcription pinned to the session language. The browser cannot change any of it.
// handleLiveTool: every call is checked against that session (erp.sana_live_check: own session, open, not expired, tool in the
// minted list) and the role (the tool's own allowed() rule again); the tool runs as the same erp.sana_* RPC as Ask with the
// user's JWT and the 3 s limit; the result is masked. log_turn writes the transcript like a typed turn (via 'live'), with the
// timing and the audio beacon, and flags a figure without a lookup (rule 1a) as unverified. end closes the session.
import { currencyMismatch, hasCompanyFigure, languageMissing, scriptViolation, makeRpc, redact, runTool, TOOLS, type Env, type Topics } from './core.ts';
import { functionDeclarations } from './providers/gemini.ts';
import { maskDeep } from './mask.ts';
import { LIVE_WS, liveModel, liveSetup, liveSystemPrompt, mintLiveToken } from './live.ts';

type Json = Record<string, unknown>;
type Res = { status: number; json: unknown };
type Who = { profile: boolean; name?: string; position?: string; home_company?: string; companies?: Array<{ code: string; currency?: string }>; topics?: Topics };
/** S5 (second live run): the Malayalam answer said 88 pieces where the 48 warehouse rows add up to 122 — the model summed a long
 *  list of mostly-zero rows. Live stock results therefore carry the totals per item and only the warehouses that hold, owe or
 *  expect stock. Same data, same RPC (erp.sana_stock); only the shape handed to the model changes. */
export function stockTotals(result: unknown): unknown {
  const r = result as { items?: Array<Record<string, unknown> & { warehouses?: Array<Record<string, number>> }> };
  if (!r || !Array.isArray(r.items)) return result;
  const n = (x: unknown) => (Number.isFinite(Number(x)) ? Number(x) : 0);
  return { ...r, items: r.items.map((it) => {
    const w = Array.isArray(it.warehouses) ? it.warehouses : [];
    const sum = (k: string) => Math.round(w.reduce((a, x) => a + n(x[k]), 0) * 1000) / 1000;
    return { ...it, total_on_hand: sum('on_hand'), total_committed: sum('committed'), total_ordered: sum('ordered'), total_available: sum('available'),
      warehouses: w.filter((x) => n(x.on_hand) || n(x.committed) || n(x.ordered)), warehouses_without_stock: w.filter((x) => !(n(x.on_hand) || n(x.committed) || n(x.ordered))).length };
  }) };
}
/** S5 fix (bare-code answer): a stock turn whose reply names the item code but says no quantity. Codes (tokens with letters and
 *  digits, e.g. SF5160IC KC) are removed first; what is left must have a number. */
export function stockWithoutQuantity(text: string, tools: string[]): boolean {
  if (!tools.includes('get_stock') || !text.trim()) return false;
  const hasCode = /\b(?=[A-Z0-9-]*[A-Z])(?=[A-Z0-9-]*\d)[A-Z0-9-]{4,}\b/i.test(text);
  const rest = text.replace(/\b(?=[A-Z0-9-]*[A-Z])(?=[A-Z0-9-]*\d)[A-Z0-9-]+\b/gi, ' ').replace(/\b[A-Z]{1,3}\b/g, ' ');
  const codes = new Set((text.match(/\b(?=[A-Z0-9-]*[A-Z])(?=[A-Z0-9-]*\d)[A-Z0-9-]{4,}\b/gi) ?? []).map((c) => c.toUpperCase()));
  if (codes.size >= 2) return false;   // a choice between codes (did_you_mean), not a stock answer
  const none = /\b(?:no|zero|none|nothing|out of stock)\b|ഇല്ല|പൂജ്യം|لا يوجد|صفر|نفد/i.test(text);   // "no stock" is a quantity
  return hasCode && !none && !/\d/.test(rest);
}
export interface LiveEnv extends Env { GEMINI_API_KEY?: string; SANA_LIVE_MODEL?: string }
export type Mint = (setup: Record<string, unknown>, expiresAt: string) => Promise<{ token: string; expireTime: string }>;

const LANG_OK = ['en', 'ml', 'ar', 'hi', 'ta', 'ur', 'bn', 'tl', 'zh', 'fr', 'ru'];
const CAP_MSG: Record<string, string> = {
  en: "You've used today's Sana Live minutes. Type or use the microphone button instead; Live is back tomorrow.",
  ml: 'ഇന്നത്തെ സന ലൈവ് മിനിറ്റുകൾ തീർന്നു. ടൈപ്പ് ചെയ്യുകയോ മൈക്ക് ബട്ടൺ ഉപയോഗിക്കുകയോ ചെയ്യുക; നാളെ ലൈവ് വീണ്ടും ലഭിക്കും.',
  ar: 'لقد استخدمت دقائق سنا لايف لهذا اليوم. اكتب أو استخدم زر الميكروفون بدلاً من ذلك؛ يعود لايف غداً.',
};
const fail = (status: number, error: string): Res => ({ status, json: { error } });
const companyOf = (b: Json) => (typeof b.company === 'string' && /^[A-Z0-9]{2,8}$/.test(b.company) && b.company !== 'GRP' ? b.company : null);

export async function handleLiveToken(auth: string | null, body: unknown, env: LiveEnv, mint?: Mint): Promise<Res> {
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return fail(401, 'Sign in to use Sana.');
  const b = (body ?? {}) as Json;
  const language = typeof b.language === 'string' && LANG_OK.includes(b.language) ? b.language : 'en';
  const rpc = makeRpc(env, auth);
  try {
    const who = await rpc('sana_whoami', {}) as Who;
    if (!who?.profile) return fail(403, 'You need a Southfield profile to use Sana.');
    const company = companyOf(b) ?? who.home_company ?? null;   // "All companies" (GRP) → home company
    if (!company) return fail(400, 'Pick a company first.');
    if (!who.companies?.some((c) => c.code === company)) return fail(403, "You don't have access to that company.");
    const st = await rpc('sana_status', { p_company: company }) as { enabled: boolean; voice_enabled?: boolean; used?: number; daily_limit?: number };
    if (!st?.enabled) return fail(403, 'Sana is switched off for your company.');
    if (st.voice_enabled === false) return fail(403, 'Voice is switched off for your company.');
    if ((st.used ?? 0) >= (st.daily_limit ?? 200)) return fail(429, `You've reached today's limit of ${st.daily_limit} questions.`);
    const tools = TOOLS.filter((t) => t.allowed(who.topics!));
    const model = liveModel(env);
    let session: { live_session_id: string; expires_at: string; seconds_left: number };
    try {
      session = await rpc('sana_live_start', { p_company: company, p_model: model, p_language: language, p_tools: tools.map((t) => t.name),
        p_expires_at: new Date(Date.now() + 10 * 60_000).toISOString() }) as typeof session;
    } catch (e) {
      if (/live minutes limit/.test((e as Error).message ?? '')) return fail(429, CAP_MSG[language] ?? CAP_MSG.en);
      throw e;
    }
    const currency = who.companies?.find((c) => c.code === company)?.currency ?? 'AED';
    const setup = liveSetup(model, liveSystemPrompt({ name: who.name ?? 'the user', position: who.position ?? '', company, language, currency }),
      [{ functionDeclarations: functionDeclarations(tools) }], language);
    const doMint: Mint = mint ?? ((s, exp) => mintLiveToken(env.GEMINI_API_KEY ?? '', s, undefined, undefined, exp));
    let t: { token: string; expireTime: string };
    try { t = await doMint(setup, session.expires_at); } catch (e) {
      await rpc('sana_live_end', { p_session: session.live_session_id, p_reason: 'error' }).catch(() => null);
      throw e;
    }
    return { status: 200, json: { company, token: t.token, expires_at: t.expireTime, ws: LIVE_WS, model, language, live_session_id: session.live_session_id,
      seconds_left: session.seconds_left, tools: tools.map((x) => x.name) } };
  } catch (e) {
    const err = e as { code?: string; status?: number; message?: string };
    if (err.status === 401 || err.code === 'PGRST301' || err.code === 'PGRST303') return fail(401, 'Sign in to use Sana.');   // bad or expired JWT
    if (err.code === '42501' || err.status === 403) return fail(403, err.message || "You don't have access to that.");
    console.error('sana-live-token', err.status ?? err.code ?? 'error', String(err.message ?? '').slice(0, 200));
    return fail(502, "Sana Live couldn't start right now.");
  }
}

export async function handleLiveTool(auth: string | null, body: unknown, env: LiveEnv): Promise<Res> {
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return fail(401, 'Sign in to use Sana.');
  const b = (body ?? {}) as Json;
  const sid = typeof b.live_session_id === 'string' && /^[0-9a-f-]{36}$/i.test(b.live_session_id) ? b.live_session_id : null;
  if (!sid) return fail(400, 'No Live session.');
  const rpc = makeRpc(env, auth);
  try {
    if (b.action === 'tool') {
      const tool = TOOLS.find((t) => t.name === b.tool);
      if (!tool) return fail(403, 'That lookup is not available in this session.');
      const s = await rpc('sana_live_check', { p_session: sid, p_tool: tool.name }) as { company: string; refused?: string };   // own, open, in the minted list
      if (s.refused) return fail(403, s.refused);   // expired: closed by the check, refused here
      const who = await rpc('sana_whoami', {}) as Who;
      if (!who?.profile || !tool.allowed(who.topics!)) return { status: 200, json: { result: { denied: true } } };   // the role again, today
      const input = (b.args && typeof b.args === 'object' ? b.args : {}) as Json;
      const raw = await runTool(rpc, tool.rpc, tool.args(input, s.company));   // same RPC as Ask, user JWT, 3 s limit
      const result = tool.rpc === 'sana_stock' ? stockTotals(raw) : raw;
      return { status: 200, json: { result: maskDeep(result) } };
    }
    if (b.action === 'log_turn') {
      const s = await rpc('sana_live_check', { p_session: sid, p_turn: true }) as { company: string; model: string; language: string | null; refused?: string };
      if (s.refused) return fail(403, s.refused);
      const who = await rpc('sana_whoami', {}) as Who;
      const cur = who?.companies?.find((c) => c.code === s.company)?.currency ?? 'AED';
      const tools = Array.isArray(b.tools) ? (b.tools as unknown[]).map(String).filter((x) => TOOLS.some((t) => t.name === x || t.rpc === x)).slice(0, 10) : [];
      const sana = redact(String(b.sana_text ?? '')).slice(0, 4000);
      const unverified = hasCompanyFigure(sana) && tools.length === 0;
      // In Live the reply cannot be re-asked: these are flagged on the turn (label) and shown on the transcript line
      const noQuantity = stockWithoutQuantity(sana, tools);
      const wrongCurrency = currencyMismatch(sana, cur, Array.isArray(b.currencies) ? (b.currencies as unknown[]).map(String).slice(0, 5).map((c) => ({ currency: c })) : []);
      // third live run: a Malayalam refusal carried a Hindi word (परवानगी) — the same script check as Ask, flagged (no re-ask in Live)
      const badScript = scriptViolation(sana, s.language ?? 'en') || languageMissing(sana, s.language ?? 'en');
      const label = unverified ? 'live-unverified' : noQuantity ? 'live-no-quantity' : wrongCurrency ? 'live-currency' : badScript ? 'live-script' : 'live';
      const t = (b.timings ?? {}) as { ms_first_audio?: number; ms_total?: number };
      const conv = typeof b.conversation_id === 'string' && /^[0-9a-f-]{36}$/i.test(b.conversation_id) ? b.conversation_id : null;
      const logged = await rpc('sana_log', { p_conversation: conv, p_company: s.company, p_language: s.language ?? 'en',
        p_question: String(b.user_text ?? '').slice(0, 2000) || '(spoken)', p_answer: sana || '(no answer)', p_tools: tools.map((x) => ({ tool: x })), p_sources: [],
        p_denied: false, p_mode: 'ai', p_via: 'live', p_context: { type: 'page', label }, p_fallback: false,
        p_provider: 'gemini', p_model: s.model, p_tokens: null }) as { conversation_id: string; message_id: number };
      const msAudio = Number.isFinite(t.ms_first_audio) ? Math.round(t.ms_first_audio!) : null, msTotal = Number.isFinite(t.ms_total) ? Math.round(t.ms_total!) : null;
      await rpc('sana_timing_set', { p_message: logged.message_id, p_timing: { ms_first_token: msAudio ?? msTotal ?? 0, ms_total: msTotal ?? msAudio ?? 0, tool_rounds: tools.length, model_fast: s.model } }).catch(() => null);
      if (msAudio != null) await rpc('sana_audio_beacon', { p_message: logged.message_id, p_ms_first_audio: msAudio, p_engine: 'gemini', p_device: b.device === 'phone' ? 'phone' : 'desktop' }).catch(() => null);
      return { status: 200, json: { ...logged, unverified, no_quantity: noQuantity, wrong_currency: wrongCurrency, script: badScript } };
    }
    if (b.action === 'end') {
      const reason = ['user', 'silence', 'cap', 'hidden', 'expired', 'error'].includes(String(b.reason)) ? String(b.reason) : 'user';
      return { status: 200, json: await rpc('sana_live_end', { p_session: sid, p_reason: reason }) };
    }
    return fail(400, 'Unknown action.');
  } catch (e) {
    const err = e as { code?: string; status?: number; message?: string };
    if (err.status === 401 || err.code === 'PGRST301' || err.code === 'PGRST303') return fail(401, 'Sign in to use Sana.');   // bad or expired JWT
    if (err.code === '42501' || err.status === 403) return fail(403, err.message || "You don't have access to that.");
    if (err.code === 'P0001' && /limit/.test(err.message ?? '')) return fail(429, err.message!);
    console.error('sana-live-tool', err.status ?? err.code ?? 'error', String(err.message ?? '').slice(0, 200));
    return fail(502, "Sana Live couldn't do that right now.");
  }
}

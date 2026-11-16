// Supabase Edge Function "sana-live-token" (S5 · Sana Live, M1 = admin-only test page).
// POST { company, language } with the user's session token → { token, ws, model, expires_at, live_session_id, tools }.
// Runs the same checks as `sana` (profile, company access, Sana on, daily limit) and, in M1, Administration access (admin, IT or
// owner, via erp.sana_setup). Then mints a single-use Gemini Live ephemeral token (≤ 10 min) with the whole setup locked in it
// (model, system instruction, tools, audio + transcription): the browser cannot change any of it. The API key never leaves here.
// Secrets: GEMINI_API_KEY (exists), optional SANA_LIVE_MODEL (default gemini-3.1-flash-live-preview).
import { makeRpc, type Env } from '../sana/core.ts';
import { LIVE_TOOLS, LIVE_WS, liveModel, liveSetup, liveSystemPrompt, mintLiveToken } from '../sana/live.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (status: number, body: unknown) => Response.json(body, { status, headers: cors });
type Who = { profile: boolean; name?: string; position?: string; companies?: Array<{ code: string }>; topics?: Record<string, boolean> };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Use POST.' });
  const auth = req.headers.get('Authorization');
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return json(401, { error: 'Sign in to use Sana.' });
  const b = await req.json().catch(() => ({})) as { company?: string; language?: string };
  const company = typeof b.company === 'string' && /^[A-Z0-9]{2,8}$/.test(b.company) ? b.company : null;
  if (!company) return json(400, { error: 'Choose a company first.' });
  const language = typeof b.language === 'string' && /^[a-z]{2}$/.test(b.language) ? b.language : 'en';
  const env: Env = { SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '', SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '' };
  const rpc = makeRpc(env, auth);
  try {
    const [who, st] = await Promise.all([rpc('sana_whoami', {}) as Promise<Who>, rpc('sana_status', { p_company: company }) as Promise<{ enabled: boolean; used?: number; daily_limit?: number }>]);
    if (!who?.profile) return json(403, { error: 'You need a Southfield profile to use Sana.' });
    if (!who.companies?.some((c) => c.code === company)) return json(403, { error: "You don't have access to that company." });
    if (!st?.enabled) return json(403, { error: 'Sana is switched off for your company.' });
    if ((st.used ?? 0) >= (st.daily_limit ?? 200)) return json(429, { error: "You've reached today's Sana limit." });
    await rpc('sana_setup', { p_company: company });   // M1: Administration (admin, IT, owner) only — raises 42501 otherwise
    const model = liveModel({ SANA_LIVE_MODEL: Deno.env.get('SANA_LIVE_MODEL') ?? undefined });
    const setup = liveSetup(model, liveSystemPrompt({ name: who.name ?? 'the user', position: who.position ?? '', company, language }));
    if (!who.topics?.stock) (setup as { tools: unknown[] }).tools = [];   // the one M1 tool only for roles that see stock
    const t = await mintLiveToken(Deno.env.get('GEMINI_API_KEY') ?? '', setup);
    return json(200, { token: t.token, expires_at: t.expireTime, ws: LIVE_WS, model, live_session_id: crypto.randomUUID(),
      tools: who.topics?.stock ? LIVE_TOOLS[0].functionDeclarations.map((f) => f.name) : [] });
  } catch (e) {
    const err = e as { code?: string; status?: number; message?: string };
    if (err.code === '42501' || err.status === 403) return json(403, { error: 'Sana Live test is for the system admin, IT and the owner.' });
    console.error('sana-live-token', err.status ?? 'error', String(err.message ?? '').slice(0, 200));
    return json(502, { error: "Sana Live couldn't start right now." });
  }
});

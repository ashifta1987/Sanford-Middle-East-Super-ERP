// Supabase Edge Function "sana-live-token" (S5 · Sana Live). POST { company, language } with the user's session token.
// Deployed with --no-verify-jwt (the warm-up ping carries no JWT): every real call is checked by the handler — no Bearer → 401,
// and each RPC runs with the caller's JWT, which PostgREST verifies (an invalid token → 401).
// The handler is runtime-neutral (../sana/livecore.ts) so the local gateway runs the same code. See livecore.ts for the rules.
// Secrets: GEMINI_API_KEY (exists), optional SANA_LIVE_MODEL. The API key never leaves this function.
import { handleLiveToken } from '../sana/livecore.ts';

const BOOT = Date.now();
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const env = () => ({ SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '', SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  GEMINI_API_KEY: Deno.env.get('GEMINI_API_KEY') ?? undefined, SANA_LIVE_MODEL: Deno.env.get('SANA_LIVE_MODEL') ?? undefined });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const body = await req.json().catch(() => ({}));
  // S5 warm-up: erp's pg_cron job pings every 5 min with {ping: true} so a user's first call does not pay the cold start.
  // Answers before anything else (no auth, no data); instance_age_ms shows whether this instance was cold.
  if (body && (body as { ping?: unknown }).ping === true) return Response.json({ ok: true, instance_age_ms: Date.now() - BOOT }, { headers: cors });
  const r = await handleLiveToken(req.headers.get('Authorization'), body, env());
  return Response.json(r.json, { status: r.status, headers: cors });
});

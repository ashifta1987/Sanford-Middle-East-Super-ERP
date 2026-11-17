// Supabase Edge Function "sana-live-token" (S5 · Sana Live). POST { company, language } with the user's session token.
// The handler is runtime-neutral (../sana/livecore.ts) so the local gateway runs the same code. See livecore.ts for the rules.
// Secrets: GEMINI_API_KEY (exists), optional SANA_LIVE_MODEL. The API key never leaves this function.
import { handleLiveToken } from '../sana/livecore.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const env = () => ({ SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '', SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  GEMINI_API_KEY: Deno.env.get('GEMINI_API_KEY') ?? undefined, SANA_LIVE_MODEL: Deno.env.get('SANA_LIVE_MODEL') ?? undefined });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const r = await handleLiveToken(req.headers.get('Authorization'), await req.json().catch(() => ({})), env());
  return Response.json(r.json, { status: r.status, headers: cors });
});

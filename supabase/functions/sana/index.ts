// Supabase Edge Function "sana": POST { message, conversation_id?, company?, language?, via? } with the user's session token.
// Deploy:  supabase functions deploy sana
// Secrets: supabase secrets set ANTHROPIC_API_KEY=... SANA_MODEL=claude-sonnet-5-5   (without a key Sana runs in basic mode)
// SUPABASE_URL and SUPABASE_ANON_KEY are provided by Supabase automatically. The service role key is NOT used.
import { handleAsk } from './core.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const body = await req.json().catch(() => null);
  const { status, json } = await handleAsk(req.headers.get('Authorization'), body, {
    SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '',
    SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    ANTHROPIC_API_KEY: Deno.env.get('ANTHROPIC_API_KEY') ?? undefined,
    SANA_MODEL: Deno.env.get('SANA_MODEL') ?? undefined,
  });
  return Response.json(json, { status, headers: cors });
});

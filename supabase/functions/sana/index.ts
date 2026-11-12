// Supabase Edge Function "sana": POST { message, conversation_id?, company?, language?, via?, context? } with the user's session token.
// Accept: text/event-stream → the answer streams as Server-Sent Events (meta, delta, reset, done, error); otherwise one JSON reply.
// POST { action: 'config', company } → admin-only provider config for the settings screen (names and yes/no, never a key).
// Deploy:  supabase functions deploy sana
// Secrets (S2, decision 11 Nov 2026 — Gemini is the provider; the key values are set by IT and never written anywhere else):
//   supabase secrets set SANA_PROVIDER=gemini SANA_MODEL=gemini-3.8-flash      (GEMINI_API_KEY is already a secret on live)
//   Fallback: SANA_PROVIDER=anthropic with ANTHROPIC_API_KEY (SANA_MODEL=claude-…). Without a key for the chosen provider Sana
//   runs in basic mode. Optional: SANA_THINKING_BUDGET (default 0 on Flash).
// SUPABASE_URL and SUPABASE_ANON_KEY are provided by Supabase automatically. The service role key is NOT used.
// The test-only base-URL variables of the local provider mock are deliberately NOT read here.
import { handleAsk, handleConfig, type Env } from './core.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, accept',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const get = (k: string) => Deno.env.get(k) || undefined;
const env = (): Env => ({
  SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '',
  SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  SANA_PROVIDER: get('SANA_PROVIDER'),
  SANA_MODEL: get('SANA_MODEL'),
  GEMINI_API_KEY: get('GEMINI_API_KEY'),
  ANTHROPIC_API_KEY: get('ANTHROPIC_API_KEY'),
  SANA_THINKING_BUDGET: get('SANA_THINKING_BUDGET'),
  SANA_STT_MODEL: get('SANA_STT_MODEL'),
  SANA_VOICE_MODEL: get('SANA_VOICE_MODEL'),
  SANA_TTS_VOICE: get('SANA_TTS_VOICE'),
});

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const body = await req.json().catch(() => null);
  const auth = req.headers.get('Authorization');
  if (body && typeof body === 'object' && (body as { action?: unknown }).action === 'config') {
    const { status, json } = await handleConfig(auth, body, env());
    return Response.json(json, { status, headers: cors });
  }
  if ((req.headers.get('Accept') ?? '').includes('text/event-stream')) {
    const enc = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        const send = (event: string, data: unknown) => controller.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        try { await handleAsk(auth, body, env(), send); } finally { controller.close(); }
      },
    });
    return new Response(stream, { headers: { ...cors, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' } });
  }
  const { status, json } = await handleAsk(auth, body, env());
  return Response.json(json, { status, headers: cors });
});

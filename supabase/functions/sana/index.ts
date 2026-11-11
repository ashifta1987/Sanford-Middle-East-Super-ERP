// Supabase Edge Function "sana": POST { message, conversation_id?, company?, language?, via?, context? } with the user's session token.
// Accept: text/event-stream → the answer streams as Server-Sent Events (meta, delta, reset, done, error); otherwise one JSON reply.
// Deploy:  supabase functions deploy sana
// Secrets: supabase secrets set ANTHROPIC_API_KEY=... SANA_MODEL=claude-sonnet-5-5   (without a key Sana runs in basic mode)
// SUPABASE_URL and SUPABASE_ANON_KEY are provided by Supabase automatically. The service role key is NOT used.
import { handleAsk, type Env } from './core.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, accept',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const env = (): Env => ({
  SUPABASE_URL: Deno.env.get('SUPABASE_URL') ?? '',
  SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  ANTHROPIC_API_KEY: Deno.env.get('ANTHROPIC_API_KEY') ?? undefined,
  SANA_MODEL: Deno.env.get('SANA_MODEL') ?? undefined,
  SANA_PROVIDER: Deno.env.get('SANA_PROVIDER') ?? undefined,
});

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  const body = await req.json().catch(() => null);
  const auth = req.headers.get('Authorization');
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

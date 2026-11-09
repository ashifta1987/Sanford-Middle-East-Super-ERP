// Supabase Edge Function: ai-assistant (A10 · Add-Ons › AI Assistant). NOT DEPLOYED by the phase build.
//
// The provider API key lives ONLY in Supabase secrets (AI_API_KEY). No table holds it, so the browser can never read it.
// Settings that are not secret (on/off, provider, model, modules and tables, monthly limit) are in erp.ai_setting.
//
// Flow per request
//   1. As the caller (their JWT): rpc erp.ai_request_check(company) → assistant on? limit left? which modules (only those the
//      user can read) and tables. Then reads data through the user's own session, so RLS applies (never schema sap, never salary).
//   2. Calls the provider with AI_API_KEY.
//   3. As the service role: rpc erp.ai_usage_record(company, 1, tokens).
//
// Deploy (Ashif / IT, once the provider is chosen):
//   supabase functions deploy ai-assistant
//   supabase secrets set AI_API_KEY=<provider key>
// The Ask AI button stays "Planned" in the app until this is deployed and switched on.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

interface Check { chat_provider: string; chat_model: string | null; modules: string[]; tables: string[]; remaining: number }

async function askProvider(c: Check, key: string, question: string, context: unknown): Promise<{ text: string; tokens: number }> {
  const prompt = `Answer using only this data (JSON). If the data does not answer it, say so.\n${JSON.stringify(context).slice(0, 60000)}\n\nQuestion: ${question}`;
  if (c.chat_provider === 'google') {
    const model = c.chat_model ?? 'gemini-2.5-flash';
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }] }),
    });
    const j = await r.json();
    return { text: j.candidates?.[0]?.content?.parts?.[0]?.text ?? '', tokens: j.usageMetadata?.totalTokenCount ?? 0 };
  }
  if (c.chat_provider === 'openai') {
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: c.chat_model ?? 'gpt-4o-mini', messages: [{ role: 'user', content: prompt }] }),
    });
    const j = await r.json();
    return { text: j.choices?.[0]?.message?.content ?? '', tokens: j.usage?.total_tokens ?? 0 };
  }
  throw new Error(`Provider ${c.chat_provider} is not wired in this function yet.`);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  const key = Deno.env.get('AI_API_KEY');
  if (!key) return json(503, { code: 'P0001', message: 'The AI Assistant has no provider key yet. Ask the system admin.' });
  const url = Deno.env.get('SUPABASE_URL')!;
  const authHeader = req.headers.get('Authorization') ?? '';
  const { company, question, table } = await req.json().catch(() => ({}));
  if (!company || !question) return json(400, { code: 'P0001', message: 'Send the company and the question.' });

  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, db: { schema: 'erp' } });
  const check = await asUser.rpc('ai_request_check', { p_company: company });
  if (check.error) return json(check.error.code === '42501' ? 403 : 400, { code: check.error.code, message: check.error.message });
  const c = check.data as Check;
  if (table && !c.tables.includes(table)) return json(403, { code: '42501', message: `The assistant may not read ${table}.` });

  // Data is read with the user's own session: RLS and module access apply exactly as in the app.
  const context = table ? (await asUser.from(table).select('*').eq('company_code', company).limit(200)).data ?? [] : [];
  const answer = await askProvider(c, key, String(question), context);

  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false }, db: { schema: 'erp' } });
  await service.rpc('ai_usage_record', { p_company: company, p_requests: 1, p_tokens: answer.tokens });
  return json(200, { answer: answer.text, remaining: c.remaining - 1 });
});

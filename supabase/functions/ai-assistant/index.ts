// Supabase Edge Function: ai-assistant (A10 settings · A11 Ask AI). NOT DEPLOYED by the phase build.
//
// The provider API key lives ONLY in Supabase secrets (AI_API_KEY). No table holds it, so the browser can never read it.
// Settings that are not secret (on/off, provider, model, modules and tables, monthly limit) are in erp.ai_setting.
//
// Flow per request (body: { company, question, ref?: { obj_type, doc_entry } })
//   0. No AI_API_KEY → 503 { code: 'ai_not_configured' }. The app shows "AI not configured"; nothing is read or logged.
//   1. As the caller (their JWT): rpc erp.ai_ask_context(company, question, ref). It checks the assistant is on and the monthly
//      limit, picks the tools (report functions, SECURITY INVOKER), runs them with the caller's own rights (RLS + module access;
//      a tool the caller can't read comes back 'not_allowed' / 'refused' with no data), and logs the question and tools in
//      erp.audit_log as actor 'ai:assistant'. Nothing else is read: never schema sap, never salary tables.
//   2. Sends ONLY that context to the provider and asks for a short answer that cites the sources by label.
//   3. As the caller: rpc erp.ai_log_answer(audit_id, provider, chars). As the service role: rpc erp.ai_usage_record.
//   4. Returns { answer, responder: <provider>, sources, tools, audit_id }. The assistant never changes data.
//
// On the local stack (scripts/local-stack/gateway.mjs) a stand-in runs steps 1 and 3 and answers with a deterministic text
// labelled "Local test responder — not AI" (responder: 'local-test'). That stand-in is never deployed.
//
// Deploy (Ashif / IT, once the provider is chosen):
//   supabase functions deploy ai-assistant
//   supabase secrets set AI_API_KEY=<provider key>
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

interface Context {
  audit_id: number; question: string; provider: string; model: string | null;
  tools: Array<{ tool: string; status: string; message?: string; summary?: unknown; rows?: unknown[] }>;
  sources: Array<{ label: string; link: string }>;
}

const SYSTEM = [
  'You are the assistant inside Sanford Super ERP.',
  'Answer ONLY from the JSON tool results you are given. They were read with the user\'s own access rights.',
  'If a tool has status not_allowed or refused, say plainly that the user has no access to that data; do not guess it.',
  'If the results do not answer the question, say so. Never claim you changed, created or approved anything.',
  'Keep it short. Amounts are in the company currency. End with "Sources:" and the labels you used.',
].join(' ');

async function askProvider(provider: string, model: string | null, key: string, ctx: Context): Promise<{ text: string; tokens: number }> {
  const prompt = `${SYSTEM}\n\nTool results (JSON):\n${JSON.stringify({ tools: ctx.tools, sources: ctx.sources }).slice(0, 60000)}\n\nQuestion: ${ctx.question}`;
  if (provider === 'google') {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model ?? 'gemini-2.5-flash'}:generateContent`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }] }),
    });
    const j = await r.json();
    return { text: j.candidates?.[0]?.content?.parts?.[0]?.text ?? '', tokens: j.usageMetadata?.totalTokenCount ?? 0 };
  }
  if (provider === 'openai') {
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: model ?? 'gpt-4o-mini', messages: [{ role: 'system', content: SYSTEM }, { role: 'user', content: prompt }] }),
    });
    const j = await r.json();
    return { text: j.choices?.[0]?.message?.content ?? '', tokens: j.usage?.total_tokens ?? 0 };
  }
  throw new Error(`Provider ${provider} is not wired in this function yet.`);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  const key = Deno.env.get('AI_API_KEY');
  if (!key) return json(503, { code: 'ai_not_configured', message: 'AI is not configured: the AI Assistant has no provider key yet. Ask the system admin.' });
  const url = Deno.env.get('SUPABASE_URL')!;
  const authHeader = req.headers.get('Authorization') ?? '';
  const { company, question, ref } = await req.json().catch(() => ({}));
  if (!company || !question) return json(400, { code: 'P0001', message: 'Send the company and the question.' });

  // 1. Context with the caller's own rights (RLS, module access, assistant settings), logged as ai:assistant.
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, db: { schema: 'erp' } });
  const c = await asUser.rpc('ai_ask_context', { p_company: company, p_question: String(question), p_ref: ref ?? null });
  if (c.error) return json(c.error.code === '42501' ? 403 : 400, { code: c.error.code, message: c.error.message });
  const ctx = c.data as Context;

  // 2. Provider sees only that context.
  let answer: { text: string; tokens: number };
  try {
    answer = await askProvider(ctx.provider, ctx.model, key, ctx);
  } catch (e) {
    return json(502, { code: 'ai_provider', message: `The AI provider did not answer: ${(e as Error).message}` });
  }

  // 3. Who answered, and usage.
  await asUser.rpc('ai_log_answer', { p_audit_id: ctx.audit_id, p_responder: ctx.provider, p_chars: answer.text.length });
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false }, db: { schema: 'erp' } });
  await service.rpc('ai_usage_record', { p_company: company, p_requests: 1, p_tokens: answer.tokens });
  return json(200, { answer: answer.text, responder: ctx.provider, sources: ctx.sources, tools: ctx.tools, audit_id: ctx.audit_id });
});

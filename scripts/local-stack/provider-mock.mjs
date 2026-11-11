// ============================================================================================================================
//  LOCAL-ONLY PROVIDER MOCK — NOT AI.  A deterministic stand-in for the Gemini REST API and the Anthropic Messages API, so the
//  Sana adapters (supabase/functions/sana/providers/*.ts) and the sana-voice function run their real code paths locally
//  without any key. It speaks each provider's real wire format (requests are validated like the real APIs would; replies
//  carry function calls / tool_use blocks, SSE chunks, usage counts, TTS audio and STT transcripts), but every "answer" comes
//  from a keyword router below. Every text it writes starts with "[mock]". Its results say nothing about model quality.
//
//  Mounted by scripts/local-stack/gateway.mjs under /local/mock/* (only when the gateway is switched to a mock provider
//  via POST /local/sana-provider). Standalone: node scripts/local-stack/provider-mock.mjs [port]  (default 54329).
//    Gemini     POST /local/mock/gemini/v1beta/models/{model}:generateContent
//               POST /local/mock/gemini/v1beta/models/{model}:streamGenerateContent?alt=sse
//    Anthropic  POST /local/mock/anthropic/v1/messages            (stream: true → SSE events)
//    Stats      GET  /local/mock/stats   POST /local/mock/stats/reset   (request sizes for scripts/local-stack/sana-cost.mjs;
//               sizes and token estimates only — never headers, keys or audio)
//  Test directives inside a question (mock only): [[mock:slow]] (40 s, for the timeout), [[mock:error]] (HTTP 500),
//  [[mock:safety]] (provider refusal), [[mock:malformed]] (Gemini MALFORMED_FUNCTION_CALL), [[mock:refuse-text]] (the model
//  writes the refusal sentence itself), [[mock:acctno]] (an IBAN-like number in the answer, to test redaction).
// ============================================================================================================================
import http from 'node:http';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

/** Documented token estimate (S2 cost table): ASCII ≈ 4 characters per token, other scripts (Arabic, Malayalam, …) ≈ 2. */
export function estimateTokens(s) {
  let ascii = 0, other = 0;
  for (const ch of String(s ?? '')) (ch.codePointAt(0) < 128 ? ascii++ : other++);
  return Math.ceil(ascii / 4 + other / 2);
}

export const stats = { requests: [] };
const record = (r) => { stats.requests.push({ at: new Date().toISOString(), ...r }); if (stats.requests.length > 5000) stats.requests.shift(); };

// ---------- the keyword router (NOT AI) ----------
const ROUTES = [
  [/\[\[mock:refuse-text\]\]/, { refuseText: true }],
  [/who am i|what can you|my role|ഞാൻ ആര|من أنا/i, { whoami: true }],
  [/approv|waiting for me|അംഗീകാര|اعتماد/i, { name: 'my_approvals' }],
  [/my (manager|department|job|title|joining|employee record)|who is my manager|എന്റെ മാനേജർ|مديري/i, { name: 'my_employee_record' }],
  [/headcount|employees|staff|how many people|ജീവനക്കാർ|موظف/i, { name: 'people', args: () => ({}) }],
  [/bank|cash position|cash balance|payments?|ബാങ്ക്|بنك/i, { name: 'banking' }],
  [/payable|we owe|supplier invoices? due|നൽകാനുള്ള/i, { name: 'payables' }],
  [/overdue|receivable|aging|ageing|owe us|കുടിശ്ശിക|متأخر|مستحق/i, { name: 'receivables' }],
  [/journal|profit|balance sheet|trial balance|ledger|p ?& ?l|ലാഭ|أرباح|ميزانية/i, { name: 'finance_summary' }],
  [/alert|problem|exception|risk|attention|control tower|മുന്നറിയിപ്പ്|تنبيه/i, { name: 'alerts' }],
  [/(inventory|stock) (summary|overview)|below minimum|low stock/i, { name: 'inventory_summary' }],
  [/purchase order|\bpo\b|أوامر الشراء|പർച്ചേസ് ഓർഡ/i, { name: 'list_documents', args: (q) => ({ kind: 'purchase_order', ...(/open|pending|തുറന്ന|مفتوح/i.test(q) ? { status: 'open' } : {}) }) }],
  [/sales order|\borders?\b|commandes?|заказ|订单|ऑर्डर|آرڈر|أوامر البيع|ഓർഡർ|ഓർഡറ/i, { name: 'list_documents', args: (q) => ({ kind: 'sales_order', ...(/open|pending|തുറന്ന|مفتوح/i.test(q) ? { status: 'open' } : {}) }) }],
  [/invoice|فاتورة|ഇൻവോയ്/i, { name: 'list_documents', args: () => ({ kind: 'ar_invoice' }) }],
  [/stock|inventory|available|on hand|स्टॉक|اسٹاک|库存|запас|остат|സ്റ്റോക്ക്|مخزون|متوفر/i, { name: 'get_stock', args: (q) => ({ query: q.match(/\b[A-Z]{2,6}-[A-Z0-9-]{2,12}\b/i)?.[0] ?? q.replace(/[?؟.]/g, '').split(/\s+/).slice(-1)[0] }) }],
  [/supplier|vendor|customer|client|partner|\b[CS]\d{4}\b|عميل|مورد|ഉപഭോക്താ/i, { name: 'get_partner', args: (q) => ({ query: q.match(/\b[CS][0-9A-Z]{4,6}\b/)?.[0] ?? q }) }],
  [/purchas|buying|വാങ്ങൽ|مشتريات/i, { name: 'purchase_summary', args: () => ({ from: monthStart(), to: today() }) }],
  [/sales|revenue|sold|വിൽപ്പന|مبيعات/i, { name: 'sales_summary', args: () => ({ from: monthStart(), to: today() }) }],
];
const today = () => new Date().toISOString().slice(0, 10);
const monthStart = () => today().slice(0, 8) + '01';

function route(question, declared, system = '') {
  // page context ("Ask Sana about this"): the system prompt names the record; fetch it with the matching tool
  const ctx = system.match(/The user opened Sana from this screen: (document|partner|item)(?: ([a-z_]+))?(?: ([A-Z0-9-]+))?/);
  if (ctx && /\bthis\b|balance|in stock|هذا|ഇത്/i.test(question)) {
    const [, type, a, b] = ctx;
    const want = type === 'document' ? { name: 'get_document', args: { kind: a, number: b } } : type === 'partner' ? { name: 'get_partner', args: { query: a ?? b } } : { name: 'get_stock', args: { query: a ?? b } };
    return declared.includes(want.name) ? { call: want } : { refuse: true };
  }
  const docNo = question.match(/\b([A-Z]{1,5}-\d{2}-\d{3,8})\b/i)?.[1];
  if (docNo && declared.includes('get_document')) {
    const kind = /purchase/i.test(question) ? 'purchase_order' : /invoice/i.test(question) ? 'ar_invoice' : /delivery/i.test(question) ? 'delivery' : 'sales_order';
    return { call: { name: 'get_document', args: { kind, number: docNo } } };
  }
  for (const [re, r] of ROUTES) {
    if (!re.test(question)) continue;
    if (r.refuseText) return { refuse: true };
    if (r.whoami) return { whoami: true };
    if (!declared.includes(r.name)) return { refuse: true };   // a compliant model refuses a topic it has no tool for
    return { call: { name: r.name, args: r.args ? r.args(question) : {} } };
  }
  return declared.includes('find_records') ? { call: { name: 'find_records', args: { query: question.slice(0, 60) } } } : { refuse: true };
}
const refusalFrom = (system) => system.match(/reply with exactly this sentence and nothing else: "([^"]+)"/)?.[1]
  ?? "That information isn't available for your role. If you need it, ask your manager or the responsible team.";
const replyLang = (system) => system.match(/\n6\. Reply in ([A-Za-z]+)/)?.[1] ?? 'English';
function facts(results) {
  const out = [];
  const add = (k, v) => { if (out.length < 4) out.push(`${k.replace(/_/g, ' ')} ${typeof v === 'number' ? v.toLocaleString('en-US') : v}`); };
  for (const r of results) {
    if (!r || typeof r !== 'object') continue;
    for (const k of ['code', 'number', 'name', 'manager', 'department', 'status']) if (typeof r[k] === 'string') add(k, r[k]);
    for (const [k, v] of Object.entries(r)) {
      if (typeof v === 'number') add(k, v);
      else if (Array.isArray(v) && v.length && typeof v[0] === 'object') {
        const f = v[0]; const label = f.code ?? f.number ?? f.name ?? f.customer ?? f.bank ?? f.subject;
        if (label != null) add(k, `${v.length} (first: ${label})`);
      } else if (v && typeof v === 'object' && !Array.isArray(v)) {
        for (const [k2, v2] of Object.entries(v)) if (typeof v2 === 'number') add(`${k} ${k2}`, v2);
      }
    }
  }
  return out;
}
function finalText(system, results, question) {
  if (results.some((r) => r && typeof r === 'object' && r.denied === true)) return refusalFrom(system);
  const lang = replyLang(system);
  const f = facts(results);
  let t = `[mock] (${lang}) ${f.length ? f.join(' · ') : 'No matching records.'}`;
  if (/\[\[mock:acctno\]\]/.test(question)) t += ' Pay to AE07 0331 2345 6789 0123 456.';
  return t;
}
function whoamiText(system) {
  return `[mock] (${replyLang(system)}) I can help with: ${system.match(/Topics this role covers: ([^\n]+)\./)?.[1] ?? 'your own records'}.`;
}

// ---------- helpers ----------
const readBody = (req) => new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c).toString('utf8'))); });
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const sleep = (ms, req) => new Promise((r) => { const t = setTimeout(r, ms); req.on('close', () => { clearTimeout(t); r(); }); });
const words = (t) => t.match(/\S+\s*/g) ?? [t];
const sse = (res, data, event) => res.write(`${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(data)}\n\n`);
function tone(seconds, rate = 24000) {
  const n = Math.max(1, Math.round(seconds * rate));
  const buf = Buffer.alloc(n * 2);
  for (let i = 0; i < n; i++) buf.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 3000), i * 2);
  return buf;
}

// ---------- Gemini ----------
const gErr = (res, code, status, message) => json(res, code, { error: { code, message, status } });
const PART_KEYS = ['text', 'inlineData', 'inline_data', 'functionCall', 'functionResponse', 'fileData'];
async function gemini(req, res, url) {
  const m = url.pathname.match(/\/models\/([^/:]+):(generateContent|streamGenerateContent)$/);
  if (!m) return gErr(res, 404, 'NOT_FOUND', 'Unknown method.');
  const [, model, method] = m;
  const stream = method === 'streamGenerateContent';
  if (url.searchParams.has('key')) return gErr(res, 400, 'INVALID_ARGUMENT', 'mock: send the key in the x-goog-api-key header, not the URL.');
  if (!req.headers['x-goog-api-key']) return gErr(res, 403, 'PERMISSION_DENIED', 'Method doesn\'t allow unregistered callers. Please use an API key.');
  if (stream && url.searchParams.get('alt') !== 'sse') return gErr(res, 400, 'INVALID_ARGUMENT', 'mock: use alt=sse for streaming.');
  let body;
  try { body = JSON.parse(await readBody(req)); } catch { return gErr(res, 400, 'INVALID_ARGUMENT', 'Invalid JSON payload received.'); }
  // ---- validation like the real API ----
  const contents = body.contents;
  if (!Array.isArray(contents) || !contents.length) return gErr(res, 400, 'INVALID_ARGUMENT', '* GenerateContentRequest.contents: contents is not specified');
  let prevCalls = null;
  for (const [i, c] of contents.entries()) {
    if (!['user', 'model'].includes(c.role)) return gErr(res, 400, 'INVALID_ARGUMENT', `Please use a valid role: user, model. (contents[${i}])`);
    if (!Array.isArray(c.parts) || !c.parts.length) return gErr(res, 400, 'INVALID_ARGUMENT', `* GenerateContentRequest.contents[${i}].parts: contents.parts must not be empty.`);
    for (const p of c.parts) {
      const kinds = PART_KEYS.filter((k) => k in p);
      if (kinds.length !== 1) return gErr(res, 400, 'INVALID_ARGUMENT', `* contents[${i}].parts: a part needs exactly one data field (has ${kinds.join(',') || 'none'})`);
      if ('text' in p && (typeof p.text !== 'string' || (!p.text && !p.thoughtSignature))) return gErr(res, 400, 'INVALID_ARGUMENT', `* contents[${i}].parts.text must be a non-empty string`);
    }
    const responses = c.parts.filter((p) => p.functionResponse);
    if (responses.length) {
      if (c.role !== 'user' || !prevCalls) return gErr(res, 400, 'INVALID_ARGUMENT', 'Please ensure that function response turn comes immediately after a function call turn.');
      const names = responses.map((p) => p.functionResponse.name).sort().join(',');
      if (names !== prevCalls.map((p) => p.functionCall.name).sort().join(',')) return gErr(res, 400, 'INVALID_ARGUMENT', 'Please ensure that the number of function response parts is equal to the number of function call parts of the function call turn.');
      if (responses.some((p) => !p.functionResponse.response || typeof p.functionResponse.response !== 'object' || Array.isArray(p.functionResponse.response))) return gErr(res, 400, 'INVALID_ARGUMENT', 'functionResponse.response must be an object.');
    }
    const calls = c.parts.filter((p) => p.functionCall);
    if (calls.length && c.role !== 'model') return gErr(res, 400, 'INVALID_ARGUMENT', 'functionCall parts belong to the model.');
    if (calls.length && calls.some((p) => !String(p.thoughtSignature ?? '').startsWith('mock-sig-'))) return gErr(res, 400, 'INVALID_ARGUMENT', 'Function call is missing a thought_signature in functionCall parts.');
    prevCalls = calls.length ? calls : null;
  }
  const decls = body.tools?.flatMap((t) => t.functionDeclarations ?? []) ?? [];
  for (const d of decls) {
    if (!/^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$/.test(d.name ?? '')) return gErr(res, 400, 'INVALID_ARGUMENT', `Invalid function name: ${d.name}`);
    if (d.parameters && (String(d.parameters.type).toLowerCase() !== 'object' || !d.parameters.properties || !Object.keys(d.parameters.properties).length))
      return gErr(res, 400, 'INVALID_ARGUMENT', `* tools.function_declarations.parameters.properties: should be non-empty for OBJECT type (${d.name})`);
  }
  const gc = body.generationConfig ?? {};
  if (gc.maxOutputTokens != null && !(Number.isInteger(gc.maxOutputTokens) && gc.maxOutputTokens > 0)) return gErr(res, 400, 'INVALID_ARGUMENT', 'maxOutputTokens must be a positive integer.');
  const system = (body.systemInstruction?.parts ?? []).map((p) => p.text ?? '').join('\n');
  const last = contents[contents.length - 1];
  const question = contents.filter((c) => c.role === 'user' && c.parts.some((p) => typeof p.text === 'string')).map((c) => c.parts.map((p) => p.text ?? '').join(' ')).pop() ?? '';
  const promptTokens = estimateTokens(system) + estimateTokens(JSON.stringify(decls)) + estimateTokens(JSON.stringify(contents.map((c) => c.parts.map((p) => (p.inlineData ? { inlineData: '…' } : p)))));
  const audioPart = last.parts.find((p) => (p.inlineData ?? p.inline_data)?.mimeType?.startsWith('audio/'));
  const fnResp = last.parts.filter((p) => p.functionResponse).map((p) => p.functionResponse.response);
  const base = { provider: 'gemini', model, stream, system_chars: system.length, tools_chars: JSON.stringify(decls).length, tools: decls.length,
    contents: contents.length, contents_chars: JSON.stringify(contents.map((c) => c.parts.map((p) => (p.inlineData ? 0 : p)))).length,
    function_response_chars: JSON.stringify(fnResp).length, est_prompt_tokens: promptTokens,
    est_system: estimateTokens(system), est_tools: estimateTokens(JSON.stringify(decls)), est_function_response: estimateTokens(JSON.stringify(fnResp)),
    est_contents: estimateTokens(JSON.stringify(contents.map((c) => c.parts.map((p) => (p.inlineData ? { inlineData: '…' } : p))))) };

  // ---- text-to-speech ----
  if ((gc.responseModalities ?? []).map((x) => String(x).toUpperCase()).includes('AUDIO')) {
    if (!/tts/.test(model)) return gErr(res, 400, 'INVALID_ARGUMENT', 'mock: this model does not produce audio (use a *-tts model).');
    const voice = gc.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName;
    if (!voice) return gErr(res, 400, 'INVALID_ARGUMENT', 'mock: speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName is required.');
    const text = last.parts.map((p) => p.text ?? '').join(' ');
    const seconds = Math.min(Math.max(text.length * 0.02, 0.4), 4);
    const pcm = tone(seconds);
    record({ ...base, kind: 'tts', text_chars: text.length, est_output_tokens: Math.round(seconds * 25), audio_seconds: seconds });
    return json(res, 200, { candidates: [{ content: { role: 'model', parts: [{ inlineData: { mimeType: 'audio/L16;codec=pcm;rate=24000', data: pcm.toString('base64') } }] }, finishReason: 'STOP' }],
      usageMetadata: { promptTokenCount: estimateTokens(text), candidatesTokenCount: Math.round(seconds * 25), totalTokenCount: estimateTokens(text) + Math.round(seconds * 25) }, modelVersion: model });
  }
  // ---- speech-to-text ----
  if (audioPart) {
    const data = (audioPart.inlineData ?? audioPart.inline_data).data ?? '';
    const bytes = Math.floor(data.length * 3 / 4);
    const prompt = last.parts.map((p) => p.text ?? '').join(' ');
    const lang = prompt.match(/The speaker uses ([A-Za-z]+)\./)?.[1];
    const said = bytes < 2000 ? '' : lang === 'Malayalam' ? '[mock] തുറന്ന സെയിൽസ് ഓർഡറുകൾ എത്ര?' : lang === 'Arabic' ? '[mock] كم عدد أوامر البيع المفتوحة؟' : '[mock] How many open sales orders do we have?';
    record({ ...base, kind: 'stt', audio_bytes: bytes, audio_seconds: bytes / 32000, est_prompt_tokens: estimateTokens(prompt) + Math.round((bytes / 32000) * 32), est_output_tokens: estimateTokens(said) });
    return json(res, 200, { candidates: [{ content: { role: 'model', parts: said ? [{ text: said }] : [] }, finishReason: 'STOP' }],
      usageMetadata: { promptTokenCount: estimateTokens(prompt) + Math.round((bytes / 32000) * 32), candidatesTokenCount: estimateTokens(said) }, modelVersion: model });
  }
  // ---- text / function calling ----
  if (/\[\[mock:error\]\]/.test(question)) return gErr(res, 500, 'INTERNAL', 'mock: internal error');
  if (/\[\[mock:slow\]\]/.test(question)) { await sleep(40_000, req); if (res.destroyed || res.writableEnded) return; }
  let parts; let finish = 'STOP'; let block;
  if (/\[\[mock:safety\]\]/.test(question)) { parts = []; finish = 'SAFETY'; }
  else if (/\[\[mock:malformed\]\]/.test(question)) { parts = []; finish = 'MALFORMED_FUNCTION_CALL'; }
  else if (fnResp.length) parts = [{ text: finalText(system, fnResp, question) }];
  else {
    const r = route(question, decls.map((d) => d.name), system);
    if (r.call) parts = [{ functionCall: { name: r.call.name, args: r.call.args }, thoughtSignature: `mock-sig-${crypto.randomBytes(6).toString('hex')}` }];
    else if (r.whoami) parts = [{ text: whoamiText(system) }];
    else parts = [{ text: refusalFrom(system) }];
  }
  const outTokens = estimateTokens(JSON.stringify(parts));
  const usageMetadata = { promptTokenCount: promptTokens, candidatesTokenCount: outTokens, totalTokenCount: promptTokens + outTokens };
  record({ ...base, kind: 'text', est_output_tokens: outTokens, function_call: parts.find((p) => p.functionCall)?.functionCall.name ?? null });
  if (!stream) {
    return json(res, 200, { candidates: [{ content: { role: 'model', parts }, finishReason: finish, index: 0 }], ...(block ? { promptFeedback: { blockReason: block } } : {}), usageMetadata, modelVersion: model });
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const textPart = parts.find((p) => typeof p.text === 'string');
  if (textPart) {
    const w = words(textPart.text);
    for (let i = 0; i < w.length; i += 3) { sse(res, { candidates: [{ content: { role: 'model', parts: [{ text: w.slice(i, i + 3).join('') }] }, index: 0 }], modelVersion: model }); await sleep(15, req); }
    sse(res, { candidates: [{ content: { role: 'model', parts: [{ text: '' }] }, finishReason: finish, index: 0 }], usageMetadata, modelVersion: model });
  } else {
    sse(res, { candidates: [{ content: { role: 'model', parts }, finishReason: finish, index: 0 }], usageMetadata, modelVersion: model });
  }
  res.end();
}

// ---------- Anthropic ----------
const aErr = (res, code, type, message) => json(res, code, { type: 'error', error: { type, message } });
async function anthropic(req, res) {
  if (!req.headers['x-api-key']) return aErr(res, 401, 'authentication_error', 'x-api-key header is required');
  if (req.headers['anthropic-version'] !== '2023-06-01') return aErr(res, 400, 'invalid_request_error', 'anthropic-version header is required');
  let body;
  try { body = JSON.parse(await readBody(req)); } catch { return aErr(res, 400, 'invalid_request_error', 'Invalid JSON'); }
  if (!body.model || !Number.isInteger(body.max_tokens)) return aErr(res, 400, 'invalid_request_error', 'model and max_tokens are required');
  const msgs = body.messages;
  if (!Array.isArray(msgs) || !msgs.length || msgs[0].role !== 'user') return aErr(res, 400, 'invalid_request_error', 'messages: first message must use the "user" role');
  let prevUses = null;
  for (const [i, mm] of msgs.entries()) {
    if (i && msgs[i - 1].role === mm.role) return aErr(res, 400, 'invalid_request_error', `messages: roles must alternate between "user" and "assistant" (messages.${i})`);
    const blocks = typeof mm.content === 'string' ? [{ type: 'text', text: mm.content }] : mm.content;
    if (!Array.isArray(blocks) || !blocks.length) return aErr(res, 400, 'invalid_request_error', `messages.${i}: content must be a non-empty string or list`);
    const results = blocks.filter((b) => b.type === 'tool_result');
    if (results.length) {
      const ids = (prevUses ?? []).map((b) => b.id).sort().join(',');
      if (results.map((b) => b.tool_use_id).sort().join(',') !== ids) return aErr(res, 400, 'invalid_request_error', `messages.${i}: tool_result block(s) must match the tool_use ids of the previous message`);
    }
    prevUses = mm.role === 'assistant' ? blocks.filter((b) => b.type === 'tool_use') : null;
    if (mm.role === 'assistant' && blocks.some((b) => b.type === 'text' && !b.text)) return aErr(res, 400, 'invalid_request_error', `messages.${i}: text content blocks must be non-empty`);
  }
  for (const t of body.tools ?? []) if (!t.name || t.input_schema?.type !== 'object') return aErr(res, 400, 'invalid_request_error', `tools: ${t.name} needs input_schema of type object`);
  const system = typeof body.system === 'string' ? body.system : (body.system ?? []).map((b) => b.text ?? '').join('\n');
  const last = msgs[msgs.length - 1];
  const lastBlocks = typeof last.content === 'string' ? [{ type: 'text', text: last.content }] : last.content;
  const question = [...msgs].reverse().find((mm) => mm.role === 'user' && (typeof mm.content === 'string' || mm.content.some((b) => b.type === 'text')));
  const qText = typeof question?.content === 'string' ? question.content : (question?.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join(' ');
  const toolResults = lastBlocks.filter((b) => b.type === 'tool_result').map((b) => { try { return JSON.parse(typeof b.content === 'string' ? b.content : JSON.stringify(b.content)); } catch { return { text: b.content }; } });
  const promptTokens = estimateTokens(system) + estimateTokens(JSON.stringify(body.tools ?? [])) + estimateTokens(JSON.stringify(msgs));
  if (/\[\[mock:error\]\]/.test(qText)) return aErr(res, 500, 'api_error', 'mock: internal error');
  if (/\[\[mock:slow\]\]/.test(qText)) { await sleep(40_000, req); if (res.destroyed || res.writableEnded) return; }
  let content; let stop = 'end_turn';
  if (/\[\[mock:safety\]\]/.test(qText)) { content = []; stop = 'refusal'; }
  else if (toolResults.length) content = [{ type: 'text', text: finalText(system, toolResults, qText) }];
  else {
    const r = route(qText, (body.tools ?? []).map((t) => t.name), system);
    if (r.call) { content = [{ type: 'tool_use', id: `toolu_mock_${crypto.randomBytes(6).toString('hex')}`, name: r.call.name, input: r.call.args }]; stop = 'tool_use'; }
    else content = [{ type: 'text', text: r.whoami ? whoamiText(system) : refusalFrom(system) }];
  }
  const outTokens = estimateTokens(JSON.stringify(content));
  record({ provider: 'anthropic', model: body.model, stream: Boolean(body.stream), kind: 'text', system_chars: system.length, tools_chars: JSON.stringify(body.tools ?? []).length,
    tools: (body.tools ?? []).length, contents: msgs.length, contents_chars: JSON.stringify(msgs).length, function_response_chars: JSON.stringify(toolResults).length,
    est_prompt_tokens: promptTokens, est_system: estimateTokens(system), est_tools: estimateTokens(JSON.stringify(body.tools ?? [])),
    est_function_response: estimateTokens(JSON.stringify(toolResults)), est_contents: estimateTokens(JSON.stringify(msgs)), est_output_tokens: outTokens, function_call: content.find((b) => b.type === 'tool_use')?.name ?? null });
  const id = `msg_mock_${crypto.randomBytes(6).toString('hex')}`;
  if (!body.stream) return json(res, 200, { id, type: 'message', role: 'assistant', model: body.model, content, stop_reason: stop, stop_sequence: null, usage: { input_tokens: promptTokens, output_tokens: outTokens } });
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  sse(res, { type: 'message_start', message: { id, type: 'message', role: 'assistant', model: body.model, content: [], stop_reason: null, usage: { input_tokens: promptTokens, output_tokens: 1 } } }, 'message_start');
  for (const [index, b] of content.entries()) {
    if (b.type === 'text') {
      sse(res, { type: 'content_block_start', index, content_block: { type: 'text', text: '' } }, 'content_block_start');
      for (const w of words(b.text)) { sse(res, { type: 'content_block_delta', index, delta: { type: 'text_delta', text: w } }, 'content_block_delta'); await sleep(5, req); }
    } else {
      sse(res, { type: 'content_block_start', index, content_block: { type: 'tool_use', id: b.id, name: b.name, input: {} } }, 'content_block_start');
      const j = JSON.stringify(b.input);
      for (let i = 0; i < j.length; i += 12) sse(res, { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: j.slice(i, i + 12) } }, 'content_block_delta');
    }
    sse(res, { type: 'content_block_stop', index }, 'content_block_stop');
  }
  sse(res, { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: outTokens } }, 'message_delta');
  sse(res, { type: 'message_stop' }, 'message_stop');
  res.end();
}

/** Handles /local/mock/* (returns false for other paths). */
export async function mockHandler(req, res, url) {
  if (!url.pathname.startsWith('/local/mock/')) return false;
  if (url.pathname === '/local/mock/stats') { json(res, 200, stats); return true; }
  if (url.pathname === '/local/mock/stats/reset') { stats.requests = []; json(res, 200, { reset: true }); return true; }
  if (req.method !== 'POST') { json(res, 405, { error: 'POST only' }); return true; }
  if (url.pathname.startsWith('/local/mock/gemini/v1beta/')) { await gemini(req, res, url); return true; }
  if (url.pathname === '/local/mock/anthropic/v1/messages') { await anthropic(req, res); return true; }
  json(res, 404, { error: 'mock: unknown path' });
  return true;
}

export function startMock(port = 54329) {
  return new Promise((resolve) => {
    const server = http.createServer(async (req, res) => {
      const url = new URL(req.url, 'http://x');
      if (!(await mockHandler(req, res, url))) json(res, 404, { error: 'mock: unknown path' });
    }).listen(port, '127.0.0.1', () => resolve(server));
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] ?? 54329);
  await startMock(port);
  console.log(`LOCAL-ONLY provider mock (not AI) on http://127.0.0.1:${port}/local/mock/{gemini/v1beta,anthropic}`);
}

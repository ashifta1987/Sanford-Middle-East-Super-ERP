// Sana live quality gate (S4 step 4): the 10 timing questions in English and Malayalam, as a sales and a finance test user, against
// the DEPLOYED function (real model). For every answer: was a tool called, is the key figure right, is a refusal right. The
// truth comes from the same erp.sana_* RPCs called directly with the same user's token (so the role rules are identical).
//   SANA_TIMING_URL=… SANA_TIMING_ANON_KEY=… SANA_TIMING_USERS=<users.json> node scripts/local-stack/sana-live-eval.mjs --company AE05 --label lite --json out.json
//   node scripts/local-stack/sana-live-eval.mjs --compare a.json b.json      (questions where the two runs differ)
// Test users only; their questions count toward their daily limit. No answer text is stored beyond the local JSON file.
import fs from 'node:fs';
import { languageMissing, scriptViolation } from '../../supabase/functions/sana/core.ts';
// the same 10 questions as sana-timing.mjs (copied: importing that file would start a timing run)
const QUESTIONS = [
  { en: 'How many open sales orders do we have?', ml: 'എത്ര തുറന്ന സെയിൽസ് ഓർഡറുകൾ ഉണ്ട്?' },
  { en: 'What were our net sales this month?', ml: 'ഈ മാസത്തെ മൊത്തം വിൽപ്പന എത്ര?' },
  { en: 'Show the overdue customer invoices.', ml: 'കുടിശ്ശികയുള്ള ഉപഭോക്തൃ ഇൻവോയ്സുകൾ കാണിക്കുക.' },
  { en: 'What is the stock of SMP-1010?', ml: 'SMP-1010 ന്റെ സ്റ്റോക്ക് എത്ര?' },
  { en: 'Which customers owe us the most?', ml: 'ഏറ്റവും കൂടുതൽ പണം തരാനുള്ള ഉപഭോക്താക്കൾ ആരൊക്കെ?' },
  { en: 'What is the balance of customer C0001?', ml: 'C0001 എന്ന ഉപഭോക്താവിന്റെ ബാലൻസ് എത്ര?' },
  { en: 'How much do we owe our suppliers?', ml: 'വിതരണക്കാർക്ക് നമ്മൾ എത്ര കൊടുക്കാനുണ്ട്?' },
  { en: 'List the open purchase orders.', ml: 'തുറന്ന പർച്ചേസ് ഓർഡറുകൾ കാണിക്കുക.' },
  { en: 'What were the top selling items this month?', ml: 'ഈ മാസം ഏറ്റവും കൂടുതൽ വിറ്റ ഇനങ്ങൾ ഏതൊക്കെ?' },
  { en: 'Summarise the receivables ageing.', ml: 'സ്വീകാര്യ തുകകളുടെ കാലപ്പഴക്കം ചുരുക്കി പറയുക.' },
];
// 17 Nov: more Malayalam and Arabic (script check) and the "active customers" question (record status, not today's invoices).
// q = the truth to compare with (same numbering as QUESTIONS; 11 = active customers by status).
// 17 Nov: answered with the role refusal although the lookup only came back empty → these must say "not found" (en + ml)
const MUST_NOT_FOUND = [4, 6];
const EXTRA = [
  { q: 3, lang: 'ml', text: 'കാലാവധി കഴിഞ്ഞ ഇൻവോയ്സുകൾ എത്രയാണ്?' }, { q: 5, lang: 'ml', text: 'ഏത് കസ്റ്റമറാണ് ഏറ്റവും കൂടുതൽ കുടിശ്ശിക വരുത്തിയത്?' },
  { q: 2, lang: 'ml', text: 'ഈ മാസം ഇതുവരെയുള്ള വിൽപ്പന എത്ര?' }, { q: 8, lang: 'ml', text: 'ഇപ്പോൾ തുറന്നിരിക്കുന്ന പർച്ചേസ് ഓർഡറുകൾ എത്ര?' },
  { q: 7, lang: 'ml', text: 'സപ്ലയർമാർക്ക് കൊടുക്കാനുള്ള ആകെ തുക എത്ര?' }, { q: 10, lang: 'ml', text: '30, 60, 90 ദിവസത്തെ കുടിശ്ശിക എത്രയാണ്?' },
  { q: 9, lang: 'ml', text: 'ഈ മാസം ഏറ്റവും കൂടുതൽ വിറ്റ ഉൽപ്പന്നം ഏതാണ്?' }, { q: 1, lang: 'ml', text: 'തുറന്ന സെയിൽസ് ഓർഡറുകൾ ഉണ്ടോ?' },
  { q: 4, lang: 'ml', text: 'SMP-1010 സ്റ്റോക്കിൽ ഉണ്ടോ?' }, { q: 6, lang: 'ml', text: 'C0001 ന്റെ ബാലൻസ് പറയാമോ?' },
  { q: 8, lang: 'ar', text: 'كم عدد أوامر الشراء المفتوحة؟' }, { q: 2, lang: 'ar', text: 'ما هو صافي المبيعات هذا الشهر؟' },
  { q: 7, lang: 'ar', text: 'كم ندين للموردين؟' }, { q: 5, lang: 'ar', text: 'من هم العملاء الأكثر مديونية؟' }, { q: 3, lang: 'ar', text: 'اعرض فواتير العملاء المتأخرة.' },
  { q: 11, lang: 'en', text: 'How many customers are active today?' }, { q: 11, lang: 'ml', text: 'ഇന്ന് എത്ര കസ്റ്റമേഴ്സ് ആക്ടീവ് ആണ്?' },
];


const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const has = (k) => args.includes(k);

if (has('--compare')) {
  const [a, b] = args.slice(args.indexOf('--compare') + 1).map((f) => JSON.parse(fs.readFileSync(f, 'utf8')));
  const key = (r) => `${r.user}|${r.lang}|q${r.q}`;
  const mb = new Map(b.rows.map((r) => [key(r), r]));
  const score = (r) => (r.tool ? 1 : 0) + (r.figure_ok ? 1 : 0) + (r.refusal_ok ? 1 : 0);
  let worse = 0;
  console.log(`question            ${a.label.padEnd(26)} ${b.label}`);
  for (const r of a.rows) {
    const o = mb.get(key(r)); if (!o) continue;
    const f = (x) => `tool ${x.tool ? 'y' : 'n'} · figure ${x.figure_ok ? 'y' : 'n'} · refusal ${x.refusal_ok ? 'y' : 'n'}`;
    if (score(r) !== score(o) || r.figure_ok !== o.figure_ok || r.refusal_ok !== o.refusal_ok) {
      if (score(r) < score(o)) worse++;
      console.log(`${key(r).padEnd(19)} ${f(r).padEnd(26)} ${f(o)}`);
    }
  }
  console.log(`\n${a.label} worse than ${b.label} on ${worse} answers`);
  process.exit(0);
}

const BASE = process.env.SANA_TIMING_URL, ANON = process.env.SANA_TIMING_ANON_KEY;
const users = JSON.parse(fs.readFileSync(process.env.SANA_TIMING_USERS, 'utf8'));
const company = opt('--company', 'AE05');
const signIn = async (u) => (await (await fetch(`${BASE}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify(u) })).json()).access_token;
const rpc = async (tok, fn, a) => (await fetch(`${BASE}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${tok}`, 'content-type': 'application/json', 'content-profile': 'erp', 'accept-profile': 'erp' }, body: JSON.stringify(a) })).json();
const monthStart = new Date().toISOString().slice(0, 8) + '01', today = new Date().toISOString().slice(0, 10);

// truth per question: { denied } or { figures: [numbers that count as right], names: [strings that count as right], none: true (nothing found) }
async function truth(tok, q) {
  const den = (r) => r?.denied === true;
  const ov = (r) => ['d1_30', 'd31_60', 'd61_90', 'over_90'].reduce((s, k) => s + Number(r[k] ?? 0), 0);
  switch (q) {
    case 1: { const r = await rpc(tok, 'sana_documents', { p_kind: 'sales_order', p_status: 'open', p_company: company, p_limit: 3 }); return den(r) ? { denied: true } : { figures: [r.count, r.open_amount, r.total], zero: r.count === 0 }; }
    case 2: { const r = await rpc(tok, 'sana_sales_summary', { p_from: monthStart, p_to: today, p_company: company }); return den(r) ? { denied: true } : { figures: [r.net_sales] }; }
    case 3: { const r = await rpc(tok, 'sana_receivables', { p_company: company }); return den(r) ? { denied: true } : { figures: [ov(r), r.open_total, ...(r.top_overdue ?? []).slice(0, 3).map((x) => x.overdue)] }; }
    case 4: { const r = await rpc(tok, 'sana_stock', { p_query: 'SMP-1010', p_company: company }); return den(r) ? { denied: true } : (r.items?.length ? { figures: r.items.flatMap((i) => i.warehouses.map((w) => w.available)) } : { none: true }); }
    case 5: { const r = await rpc(tok, 'sana_receivables', { p_company: company }); return den(r) ? { denied: true } : { names: (r.top_overdue ?? []).slice(0, 1).flatMap((x) => [x.code, String(x.customer).split(/[\s-]+/).slice(0, 2).join(' ')]) }; }
    case 6: { const r = await rpc(tok, 'sana_partner', { p_query: 'C0001', p_company: company }); return den(r) ? { denied: true } : (r.found === false ? { none: true } : { figures: [r.balance] }); }
    case 7: { const r = await rpc(tok, 'sana_payables', { p_company: company }); return den(r) ? { denied: true } : { figures: [r.open_total, r.overdue] }; }
    case 8: { const r = await rpc(tok, 'sana_documents', { p_kind: 'purchase_order', p_status: 'open', p_company: company, p_limit: 3 }); return den(r) ? { denied: true } : { figures: [r.count, r.total] }; }
    case 9: { const r = await rpc(tok, 'sana_sales_summary', { p_from: monthStart, p_to: today, p_company: company }); return den(r) ? { denied: true } : { names: (r.top_items ?? []).slice(0, 1).flatMap((x) => [x.code]) }; }
    case 11: { const r = await rpc(tok, 'sana_partner_counts', { p_company: company }); return den(r) || !r.customers ? { denied: true } : { figures: [r.customers.active], status_count: true }; }
    case 10: { const r = await rpc(tok, 'sana_receivables', { p_company: company }); return den(r) ? { denied: true } : { figures: [r.not_due, r.d1_30, r.d31_60, r.d61_90, r.over_90], need: 2 }; }
  }
}
function numbersIn(text) {
  const out = [];
  for (const m of text.matchAll(/(\d[\d,]*(?:\.\d+)?)\s*(million|m\b|mn|thousand|k\b|ദശലക്ഷം|ലക്ഷം|കോടി)?/gi)) {
    let n = Number(m[1].replace(/,/g, '')); const u = (m[2] ?? '').toLowerCase();
    if (/^(million|m|mn|ദശലക്ഷം)$/.test(u)) n *= 1e6; else if (/^(thousand|k)$/.test(u)) n *= 1e3; else if (u === 'ലക്ഷം') n *= 1e5; else if (u === 'കോടി') n *= 1e7;
    if (Number.isFinite(n)) out.push(n);
  }
  return out;
}
// numbers that only repeat the question (SMP-1010, C0001) do not count as figures
const figuresIn = (reply, question) => { const qn = new Set(numbersIn(question)); return numbersIn(reply).filter((n) => n >= 10 && !qn.has(n)); };
const ZERO = /\bno open|\bno (sales|purchase) orders|\bnone\b|\bzero\b|\b0\b|ഒന്നും|ഇല്ല|ഒന്നുമില്ല/i;
const close = (a, b) => Math.abs(a - b) <= Math.max(0.6, Math.abs(b) * 0.006);

// streamed like the panel, so the same run also gives the timing (feedback, first text, total — as sana-timing.mjs)
async function ask(tok, message, language) {
  const t0 = performance.now();
  const res = await fetch(`${BASE}/functions/v1/sana`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${tok}`, 'content-type': 'application/json' },
    body: JSON.stringify({ message, language, company, via: 'text', stream: true }) });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = ''; const ev = []; const tm = { feedback_ms: null, first_ms: null, total_ms: null };
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const c = buf.slice(0, i); buf = buf.slice(i + 2);
      const e = c.match(/^event: (.+)$/m)?.[1]; let d = {}; try { d = JSON.parse(c.match(/^data: (.*)$/m)?.[1] ?? '{}'); } catch { /* skip */ }
      const now = performance.now() - t0;
      if (tm.feedback_ms == null && (e === 'tool' || (e === 'delta' && String(d.text ?? '').trim()))) tm.feedback_ms = now;
      if (tm.first_ms == null && e === 'delta' && String(d.text ?? '').trim()) tm.first_ms = now;
      if (e === 'done') { tm.total_ms = now; tm.first_ms ??= now; tm.feedback_ms ??= now; }
      ev.push({ e, d });
    }
  }
  const meta = ev.find((x) => x.e === 'meta')?.d ?? {}, done = ev.find((x) => x.e === 'done')?.d;
  return { tools: ev.filter((x) => x.e === 'tool').map((x) => x.d.name), done, model: meta.model, ...tm, error: done ? null : (ev.find((x) => x.e === 'error')?.d?.error ?? 'no done') };
}

const rows = [];
for (const user of (opt('--user') ? [opt('--user')] : ['sales', 'finance'])) {
  const tok = await signIn(users[user]);
  let turns = [...['en', 'ml'].flatMap((lang) => QUESTIONS.map((Q, i) => ({ q: i + 1, lang, text: Q[lang] }))), ...(has('--base-only') ? [] : EXTRA)];
  // --subset refusal: the questions this user must have refused, plus the "must say not found" pair (q4 stock SMP-1010, q6 balance C0001)
  if (opt('--subset') === 'refusal') {
    const denied = new Set();
    for (const q of new Set(turns.map((t) => t.q))) if ((await truth(tok, q)).denied) denied.add(q);
    turns = turns.filter((t) => denied.has(t.q) || MUST_NOT_FOUND.includes(t.q));
  }
  if (opt('--subset') === 'ml-ar') turns = turns.filter((t) => t.lang === 'ml' || t.lang === 'ar');   // every Malayalam and Arabic turn
  {
    for (const T of turns) {
      const { q, lang } = T; const Q = { [lang]: T.text };
      const tr = await truth(tok, q), a = await ask(tok, T.text, lang);
      const reply = String(a.done?.reply ?? ''), denied = a.done?.denied === true, nums = numbersIn(reply);
      const refusal_ok = tr.denied ? denied : !denied;
      let figure_ok;
      if (tr.denied) figure_ok = denied && figuresIn(reply, Q[lang]).length === 0;
      else if (tr.none) figure_ok = !denied && figuresIn(reply, Q[lang]).length === 0;
      else if (tr.names) figure_ok = tr.names.some((n) => n && reply.toLowerCase().includes(String(n).toLowerCase()));
      else if (tr.zero) figure_ok = ZERO.test(reply);
      else { const hits = tr.figures.filter((f) => f != null && nums.some((n) => close(n, Number(f)))).length; figure_ok = hits >= (tr.need ?? 1); }
      const tool_ok = tr.denied ? true : a.tools.length > 0;   // a refusal needs no lookup
      const script_ok = !scriptViolation(reply, lang) && !languageMissing(reply, lang);   // right script, and the answer is in that language
      const must = MUST_NOT_FOUND.includes(q) && !tr.denied ? 'must say not found' : tr.denied ? 'must refuse' : '';
      const row = { user, lang, q, must, text: T.text, tool_ok, script_ok, model: a.model, feedback_ms: a.feedback_ms, first_ms: a.first_ms, total_ms: a.total_ms, tool: a.tools.length > 0, tools: a.tools, figure_ok, refusal_ok, expected: tr.denied ? 'refusal' : tr.none ? 'nothing found' : 'answer', denied, error: a.error, reply: reply.slice(0, 300) };
      rows.push(row);
      console.log(`${user} ${lang} q${q}: tool ${row.tool ? 'y' : 'n'} · figure ${figure_ok ? 'y' : 'n'} · refusal ${refusal_ok ? 'y' : 'n'} · script ${script_ok ? 'y' : 'n'}${a.error ? ' · ERROR ' + a.error : ''}`);
    }
  }
}
const label = opt('--label', 'live');
const sum = (k) => rows.filter((r) => r[k]).length;
const pct = (xs, p) => { const v = xs.filter((x) => x != null).sort((a, b) => a - b); return v.length ? Math.round(v[Math.min(v.length - 1, Math.ceil(p / 100 * v.length) - 1)]) : null; };
const ok = rows.filter((r) => !r.error);
console.log(`timing: feedback p50/p90 ${pct(ok.map((r) => r.feedback_ms), 50)}/${pct(ok.map((r) => r.feedback_ms), 90)} · first text ${pct(ok.map((r) => r.first_ms), 50)}/${pct(ok.map((r) => r.first_ms), 90)} · total ${pct(ok.map((r) => r.total_ms), 50)}/${pct(ok.map((r) => r.total_ms), 90)} ms · errors ${rows.length - ok.length}`);
console.log(`\n${label} (${rows[0]?.model}): tool ${sum('tool')}/${rows.length} · figure ${sum('figure_ok')}/${rows.length} · refusal ${sum('refusal_ok')}/${rows.length} · script ${sum('script_ok')}/${rows.length}`);
if (opt('--json')) fs.writeFileSync(opt('--json'), JSON.stringify({ label, model: rows[0]?.model, at: new Date().toISOString(), rows }, null, 1));

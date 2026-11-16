// Sana timing runner (S4). Asks the same 10 questions in English and Malayalam as a sales user and a finance user, over the
// streaming path, and reports per request: ms to the first visible text (first non-empty `delta`), ms to `done`, tool rounds.
// Prints p50 / p90 per user x language and overall.
//
// feedback = first visible sign of progress: a lookup hint ('tool' event) or the first text, whichever comes first.
// LOCAL (default; local stack: gateway :54321). The model is the LOCAL-ONLY provider MOCK; its latency is SYNTHETIC
// (start the gateway with MOCK_TTFT_MS / MOCK_CHUNK_MS to imitate a real model). Local numbers compare code paths only.
//   node scripts/local-stack/sana-timing.mjs [--provider gemini-mock|basic] [--json out.json] [--label before]
// REMOTE (a deployed sana function; real model). Credentials come from a file that is never committed:
//   SANA_TIMING_URL=https://<ref>.supabase.co SANA_TIMING_ANON_KEY=<publishable key> SANA_TIMING_USERS=<users.json> \
//   node scripts/local-stack/sana-timing.mjs --remote [--company AE05] --json live-before.json --label live-before
//   users.json: { "sales": { "email": "...", "password": "..." }, "finance": { "email": "...", "password": "..." } }
//   (--accept-only sends only the Accept: text/event-stream header, as the deployed function before S4 expects)
// Compare two saved runs:  node scripts/local-stack/sana-timing.mjs --tables before.json after.json
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const has = (k) => args.includes(k);

export const QUESTIONS = [
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

const pct = (xs, p) => { const s = xs.filter((x) => x != null).sort((a, b) => a - b); if (!s.length) return null; return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
const f = (v) => (v == null ? '—' : `${Math.round(v)}`);

function table(rows, label) {
  const groups = {};
  for (const r of rows) for (const k of [`${r.user} · ${r.lang}`, 'all']) (groups[k] ??= []).push(r);
  const out = [`${label}`, `${'group'.padEnd(16)} ${'n'.padStart(3)}  ${'feedback p50'.padStart(12)} ${'p90'.padStart(6)}  ${'first text p50'.padStart(14)} ${'p90'.padStart(6)}  ${'total p50'.padStart(9)} ${'p90'.padStart(6)}  ${'tool rounds avg'.padStart(15)}  errors`];
  for (const [k, g] of Object.entries(groups)) {
    const ok = g.filter((r) => !r.error);
    out.push(`${k.padEnd(16)} ${String(g.length).padStart(3)}  ${f(pct(ok.map((r) => r.feedback_ms ?? r.first_ms), 50)).padStart(12)} ${f(pct(ok.map((r) => r.feedback_ms ?? r.first_ms), 90)).padStart(6)}  ${f(pct(ok.map((r) => r.first_ms), 50)).padStart(14)} ${f(pct(ok.map((r) => r.first_ms), 90)).padStart(6)}  ${f(pct(ok.map((r) => r.total_ms), 50)).padStart(9)} ${f(pct(ok.map((r) => r.total_ms), 90)).padStart(6)}  ${(ok.reduce((s, r) => s + r.tools, 0) / Math.max(1, ok.length)).toFixed(1).padStart(15)}  ${g.length - ok.length}`);
  }
  return out.join('\n');
}

if (has('--tables')) {
  const files = args.slice(args.indexOf('--tables') + 1);
  for (const file of files) { const j = JSON.parse(fs.readFileSync(file, 'utf8')); console.log(table(j.rows, `${j.label} (${j.where}, ${j.provider}, ${j.at})`) + '\n'); }
  process.exit(0);
}

const remote = has('--remote');
const BASE = remote ? process.env.SANA_TIMING_URL : 'http://127.0.0.1:54321';
const ANON = remote ? process.env.SANA_TIMING_ANON_KEY : 'local';
if (!BASE || !ANON) throw new Error('set SANA_TIMING_URL and SANA_TIMING_ANON_KEY for --remote');
let users;
if (remote) users = JSON.parse(fs.readFileSync(process.env.SANA_TIMING_USERS, 'utf8'));
else {
  const local = JSON.parse(fs.readFileSync(path.join(HERE, 'users.json'), 'utf8'));
  const pick = (e) => { const u = local.find((x) => x.email === e); return { email: u.email, password: u.password }; };
  users = { sales: pick('qa.sales@sample.test'), finance: pick('qa.finance@sample.test') };
}
const provider = remote ? 'deployed' : opt('--provider', 'gemini-mock');
if (!remote) {
  const r = await fetch(`${BASE}/local/sana-provider`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ provider }) });
  if (!r.ok) throw new Error('could not switch the local provider');
}
const company = opt('--company', remote ? null : 'ZZ99');

async function signIn(u) {
  const r = await fetch(`${BASE}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email: u.email, password: u.password }) });
  const j = await r.json();
  if (!j.access_token) throw new Error(`sign-in failed for ${u.email}`);
  return j.access_token;
}

/** One streamed question: times are measured from just before the request is sent. */
async function timed(tok, message, language) {
  const t0 = performance.now();
  const body = { message, language, company, via: 'text', ...(has('--accept-only') ? {} : { stream: true }) };
  const res = await fetch(`${BASE}/functions/v1/sana`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${tok}`, 'content-type': 'application/json', accept: 'text/event-stream' }, body: JSON.stringify(body) });
  const row = { feedback_ms: null, first_ms: null, total_ms: null, tools: 0, events: [], mode: null, denied: null, error: null };
  if (!(res.headers.get('content-type') ?? '').includes('text/event-stream')) {
    const j = await res.json().catch(() => ({}));
    row.total_ms = performance.now() - t0; row.first_ms = row.total_ms; row.feedback_ms = row.total_ms; row.error = res.ok ? null : (j.error ?? res.status); row.mode = j.mode ?? null;
    return row;
  }
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
      const ev = chunk.match(/^event: (.+)$/m)?.[1]; const raw = chunk.match(/^data: (.*)$/m)?.[1];
      if (!ev) continue;
      const d = raw ? JSON.parse(raw) : {};
      row.events.push(ev);
      if (ev === 'delta' && row.first_ms == null && String(d.text ?? '').trim()) row.first_ms = performance.now() - t0;
      if (ev === 'tool') row.tools++;
      if (row.feedback_ms == null && ((ev === 'delta' && String(d.text ?? '').trim()) || ev === 'tool')) row.feedback_ms = performance.now() - t0;
      if (ev === 'meta') row.mode = d.mode;
      if (ev === 'done') { row.total_ms = performance.now() - t0; row.denied = d.denied; if (row.first_ms == null) row.first_ms = row.total_ms; if (row.feedback_ms == null) row.feedback_ms = row.first_ms; }
      if (ev === 'error') row.error = d.error ?? 'error';
    }
  }
  if (row.total_ms == null && !row.error) row.error = 'stream ended without done';
  row.events = [...new Set(row.events)];
  return row;
}

const rows = [];
for (const user of ['sales', 'finance']) {
  const tok = await signIn(users[user]);
  for (const lang of ['en', 'ml']) {
    for (const [n, q] of QUESTIONS.entries()) {
      const r = await timed(tok, q[lang], lang);
      rows.push({ user, lang, q: n + 1, ...r });
      process.stdout.write(`${user} ${lang} q${n + 1}: first ${f(r.first_ms)} ms, total ${f(r.total_ms)} ms, tools ${r.tools}${r.error ? ', ERROR ' + r.error : ''}\n`);
    }
  }
}
if (!remote) await fetch(`${BASE}/local/sana-provider`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ provider: 'basic' }) });   // leave the stack as found
const label = opt('--label', remote ? 'remote' : 'local');
const meta = { label, where: remote ? BASE.replace(/^https?:\/\//, '') : 'local stack', provider, at: new Date().toISOString(),
  mock_ttft_ms: remote ? null : Number(process.env.MOCK_TTFT_MS || 0), rows };
console.log('\n' + table(rows, `${label} (${meta.where}, ${provider})`));
const out = opt('--json');
if (out) fs.writeFileSync(out, JSON.stringify(meta, null, 1));

// S5 · 55: re-time the finance questions on Ask (live `sana`, streaming) as qa.finance. Prints first text, total, tools, answer.
//   SANA_TIMING_URL=… SANA_TIMING_ANON_KEY=… SANA_TIMING_USERS=… node scripts/local-stack/sana-finance-timing.mjs [label]
import fs from 'node:fs';
const BASE = process.env.SANA_TIMING_URL, ANON = process.env.SANA_TIMING_ANON_KEY;
const U = JSON.parse(fs.readFileSync(process.env.SANA_TIMING_USERS, 'utf8')).finance;
const label = process.argv[2] ?? 'run';
const Q = [
  ['en', 'Give me the finance summary: account totals by drawer.'],
  ['en', 'How many journal entries were posted in the last 30 days?'],
  ['en', 'What are total assets and liabilities right now?'],
  ['ml', 'അക്കൗണ്ടുകളുടെ ആകെ തുക ഡ്രോയർ തിരിച്ച് പറയൂ.'],
  ['ml', 'കഴിഞ്ഞ 30 ദിവസത്തിൽ എത്ര ജേർണൽ എൻട്രികൾ ഉണ്ട്?'],
  ['ml', 'അടുത്ത 7 ദിവസത്തിനുള്ളിൽ അടയ്ക്കേണ്ട സപ്ലയർ ബില്ലുകൾ എത്ര?'],
];
const tok = (await (await fetch(`${BASE}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify(U) })).json()).access_token;
const rows = [];
for (const [lang, q] of Q) {
  const t0 = performance.now(); let first = null; const tools = []; let done = null;
  const res = await fetch(`${BASE}/functions/v1/sana`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${tok}`, 'content-type': 'application/json', accept: 'text/event-stream' },
    body: JSON.stringify({ message: q, company: 'AE05', language: lang, via: 'text', stream: true }) });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = '';
  outer: for (;;) {
    const { value, done: end } = await reader.read(); if (end) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
      const ev = chunk.match(/^event: (.+)$/m)?.[1]; const raw = chunk.match(/^data: (.*)$/m)?.[1]; if (!raw) continue;
      const d = JSON.parse(raw);
      if (ev === 'tool') tools.push(d.name);
      if (ev === 'delta' && first == null && String(d.text ?? '').trim()) first = Math.round(performance.now() - t0);
      if (ev === 'done') { done = d; break outer; }
    }
  }
  const total = Math.round(performance.now() - t0);
  reader.cancel().catch(() => {});
  rows.push({ lang, q, first, total, tools, model: done?.timing?.model ?? done?.model, retry: done?.timing && Object.entries(done.timing).filter(([k, v]) => k.endsWith('_retry') && v).map(([k]) => k).join(','), reply: String(done?.reply ?? '').slice(0, 160) });
  console.log(`${label} ${lang} first ${first} ms · total ${total} ms · tools ${tools.join(',') || '-'} · ${String(done?.reply ?? '').replace(/\s+/g, ' ').slice(0, 140)}`);
}
const p = (xs, q) => { const v = xs.filter((x) => x != null).sort((a, b) => a - b); return v.length ? v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)] : null; };
console.log(`${label}: first text p50 ${p(rows.map((r) => r.first), 0.5)} / p90 ${p(rows.map((r) => r.first), 0.9)} · total p50 ${p(rows.map((r) => r.total), 0.5)} / p90 ${p(rows.map((r) => r.total), 0.9)} ms`);
fs.writeFileSync(`${process.env.HOME}/erp-work/s5/finance-${label}.json`, JSON.stringify(rows, null, 1));


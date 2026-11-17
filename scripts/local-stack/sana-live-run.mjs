// Sana Live · one REAL run on live (S5 M2 go). The browser path without a browser: the deployed sana-live-token mints the locked
// token, the socket goes straight to Gemini Live, every tool call goes through the deployed sana-live-tool, each turn is logged
// (log_turn) and the session is ended (end). Malayalam speech comes from the reference clips of the model comparison
// (~/erp-work/s5/compare/input-N.wav, 24 kHz → 16 kHz); the other turns are typed into the same session.
//   SANA_TIMING_URL=… SANA_TIMING_ANON_KEY=… SANA_TIMING_USERS=~/erp-work/s4/users.json node scripts/local-stack/sana-live-run.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const BASE = process.env.SANA_TIMING_URL, ANON = process.env.SANA_TIMING_ANON_KEY;
const USERS = JSON.parse(fs.readFileSync(process.env.SANA_TIMING_USERS, 'utf8'));
const OUT = path.join(os.homedir(), 'erp-work/s5/live-run'); fs.mkdirSync(OUT, { recursive: true });
const CLIPS = path.join(os.homedir(), 'erp-work/s5/compare');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const signIn = async (u) => (await (await fetch(`${BASE}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify(u) })).json()).access_token;
const fn = async (name, tok, body) => { const r = await fetch(`${BASE}/functions/v1/${name}`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: JSON.stringify(body) }); return { status: r.status, j: await r.json().catch(() => ({})) }; };
const wav16 = (file) => {   // reference clip: 24 kHz mono PCM16 WAV → 16 kHz PCM16
  const b = fs.readFileSync(file); const pcm = b.subarray(44); const n = Math.floor(pcm.length / 2), m = Math.floor(n * 2 / 3), out = Buffer.alloc(m * 2);
  for (let j = 0; j < m; j++) { const x = j * 1.5, i = Math.floor(x), f = x - i; const a = pcm.readInt16LE(i * 2), c = i + 1 < n ? pcm.readInt16LE((i + 1) * 2) : a; out.writeInt16LE(Math.round(a + (c - a) * f), j * 2); }
  return out;
};
const SCRIPT = { ml: /[\u0D00-\u0D7F]/, en: /[A-Za-z]/ };

const PLAN = [
  { user: 'sales', language: 'ml', turns: [
    { label: 'ml speech · item code (clip 6: "SF5160IC KC യുടെ ലഭ്യമായ എണ്ണം മാത്രം പറയൂ.")', audio: 'input-6.wav' },
    { label: 'ml speech · item code (clip 3: "SF2665SL LC എന്ന ലൈറ്റ് സ്റ്റോക്കിൽ ഉണ്ടോ?")', audio: 'input-3.wav' },
    { label: 'ml typed · near-miss code → did_you_mean', text: 'SF5160ICKX എന്ന ഐറ്റത്തിന്റെ സ്റ്റോക്ക് എത്ര?' },
    { label: 'ml typed · outside the role (payables)', text: 'ഈ ആഴ്ച സപ്ലയർമാർക്ക് എത്ര പണം കൊടുക്കാനുണ്ട്?' },
  ] },
  { user: 'sales', language: 'en', turns: [
    { label: 'en typed · item code with spaces', text: 'How much stock do we have of S F 5160 I C K C?' },
    { label: 'en typed · near-miss code → did_you_mean', text: 'What is the stock of SF5160ICKX?' },
  ] },
  { user: 'finance', language: 'ml', turns: [
    { label: 'ml speech · item code, finance role has no stock lookup (clip 6)', audio: 'input-6.wav' },
    { label: 'ml typed · payables (in the role)', text: 'അടുത്ത 7 ദിവസത്തിനുള്ളിൽ അടയ്ക്കേണ്ട സപ്ലയർ ബില്ലുകൾ എത്ര?' },
  ] },
  { user: 'finance', language: 'en', turns: [
    { label: 'en typed · receivables (in the role)', text: 'How much do customers owe us that is overdue?' },
    { label: 'en typed · item code, not in the finance role', text: 'What is the stock of SF5160IC KC?' },
  ] },
];

const report = [];
for (const S of PLAN) {
  const tok = await signIn(USERS[S.user]);
  const pingT = performance.now();
  const ping = await (await fetch(`${BASE}/functions/v1/sana-live-token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"ping":true}' })).json().catch(() => ({}));
  const pingMs = Math.round(performance.now() - pingT);
  const t0 = performance.now();
  const t = await fn('sana-live-token', tok, { company: 'AE05', language: S.language });
  const tokenMs = Math.round(performance.now() - t0);
  const sess = { user: S.user, language: S.language, ping_ms: pingMs, instance_age_ms: ping.instance_age_ms ?? null, token_status: t.status, token_ms: tokenMs, model: t.j.model, tools: t.j.tools, seconds_left: t.j.seconds_left, turns: [], error: t.j.error };
  report.push(sess);
  console.log(`\n== ${S.user}/${S.language}: ping ${pingMs} ms (instance age ${ping.instance_age_ms ?? '?'} ms) · token ${t.status} in ${tokenMs} ms · ${t.j.model} · tools ${t.j.tools?.join(',')}`);
  if (t.status !== 200) continue;
  const sid = t.j.live_session_id;
  // a tool outside the session's list, straight at sana-live-tool (what a tampered browser could try)
  const outside = S.user === 'sales' ? 'payables' : 'get_stock';
  const tamper = await fn('sana-live-tool', tok, { action: 'tool', live_session_id: sid, tool: outside, args: { query: 'SF5160IC KC' } });
  sess.tamper = { tool: outside, status: tamper.status, error: tamper.j.error };
  console.log(`   tampered call ${outside}: ${tamper.status} ${tamper.j.error ?? ''}`);

  const ws = new WebSocket(`${t.j.ws}?access_token=${encodeURIComponent(t.j.token)}`);
  const handlers = new Set();
  ws.onmessage = async (e) => { const m = JSON.parse(typeof e.data === 'string' ? e.data : Buffer.from(await e.data.arrayBuffer()).toString()); for (const h of [...handlers]) await h(m); };
  let closed = null; ws.onclose = (e) => { closed = `${e.code} ${e.reason}`; };
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('ws error')); });
  const setupOk = await new Promise((res) => { const h = (m) => { if (m.setupComplete) { handlers.delete(h); res(true); } }; handlers.add(h); ws.send(JSON.stringify({ setup: { model: `models/${t.j.model}` } })); setTimeout(() => res(false), 10000); });
  sess.setup = setupOk ? 'ok' : `no setupComplete (${closed})`;
  if (!setupOk) { await fn('sana-live-tool', tok, { action: 'end', live_session_id: sid, reason: 'error' }); continue; }

  let conv = null;
  for (const T of S.turns) {
    const r = { label: T.label, heard: '', said: '', tools: [], first_audio_ms: null, audio_bytes: 0, split: { to_tool_call_ms: null, tool_rtt_ms: 0, tool_to_audio_ms: null } };
    let tToolSent = null; const currencies = new Set();
    let tEnd = null;
    const done = new Promise((res) => {
      const h = async (m) => {
        if (m.toolCall) {
          const responses = [];
          if (r.split.to_tool_call_ms == null && tEnd != null) r.split.to_tool_call_ms = Math.round(performance.now() - tEnd);   // model: speech end → tool call
          for (const f of m.toolCall.functionCalls ?? []) {
            const tt = performance.now();
            const x = await fn('sana-live-tool', tok, { action: 'tool', live_session_id: sid, tool: f.name, args: f.args });
            r.split.tool_rtt_ms += Math.round(performance.now() - tt);   // browser → sana-live-tool → RPC → back
            for (const c of JSON.stringify(x.j).matchAll(/"currency":"([A-Z]{3})"/g)) currencies.add(c[1]);
            const res1 = x.status === 200 ? x.j.result : { error: x.j.error };
            r.tools.push({ name: f.name, args: f.args, status: x.status, result: JSON.stringify(res1).slice(0, 300) });
            responses.push({ id: f.id, name: f.name, response: res1 });
          }
          ws.send(JSON.stringify({ toolResponse: { functionResponses: responses } }));
          tToolSent = performance.now();
          return;
        }
        const sc = m.serverContent; if (!sc) return;
        if (sc.inputTranscription?.text) r.heard += sc.inputTranscription.text;
        if (sc.outputTranscription?.text) r.said += sc.outputTranscription.text;
        for (const p of sc.modelTurn?.parts ?? []) if (p.inlineData?.data) { r.audio_bytes += p.inlineData.data.length * 0.75; if (r.first_audio_ms == null && tEnd != null) { r.first_audio_ms = Math.round(performance.now() - tEnd); if (tToolSent != null) r.split.tool_to_audio_ms = Math.round(performance.now() - tToolSent); } }
        if (sc.turnComplete) { handlers.delete(h); res(); }
      };
      handlers.add(h);
      setTimeout(() => { handlers.delete(h); r.error = 'no turnComplete in 45 s'; res(); }, 45000);
    });
    if (T.text) { r.heard = T.text; tEnd = performance.now(); ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text: T.text }] }], turnComplete: true } })); }
    else {
      const pcm = wav16(path.join(CLIPS, T.audio)); const chunk = 3200;
      for (let i = 0; i < pcm.length; i += chunk) { ws.send(JSON.stringify({ realtimeInput: { audio: { data: pcm.subarray(i, i + chunk).toString('base64'), mimeType: 'audio/pcm;rate=16000' } } })); await sleep(100); }
      tEnd = performance.now();
      const silence = Buffer.alloc(chunk).toString('base64');
      for (let s = 0; s < 1500 && r.first_audio_ms == null; s += 100) { ws.send(JSON.stringify({ realtimeInput: { audio: { data: silence, mimeType: 'audio/pcm;rate=16000' } } })); await sleep(100); }
    }
    await done;
    const log = await fn('sana-live-tool', tok, { action: 'log_turn', live_session_id: sid, conversation_id: conv, user_text: r.heard, sana_text: r.said, tools: r.tools.map((x) => x.name), currencies: [...currencies],
      timings: { ms_first_audio: r.first_audio_ms, ms_total: r.first_audio_ms }, device: 'desktop' });
    conv = log.j.conversation_id ?? conv;
    r.logged = log.status === 200 ? { message_id: log.j.message_id, unverified: log.j.unverified, no_quantity: log.j.no_quantity, wrong_currency: log.j.wrong_currency } : { status: log.status, error: log.j.error };
    r.heard_script_ok = SCRIPT[S.language].test(r.heard);
    r.said_script_ok = SCRIPT[S.language].test(r.said);
    sess.turns.push(r);
    console.log(`-- ${T.label}\n   heard: ${r.heard}\n   tools: ${r.tools.map((x) => `${x.name}(${JSON.stringify(x.args)}) → ${x.status} ${x.result.slice(0, 160)}`).join(' | ') || '-'}\n   said:  ${r.said}\n   first audio ${r.first_audio_ms} ms (speech end→tool call ${r.split.to_tool_call_ms ?? '-'} · tool round trip ${r.split.tool_rtt_ms || '-'} · tool result→audio ${r.split.tool_to_audio_ms ?? '-'}) · logged ${JSON.stringify(r.logged)}`);
    await sleep(600);
  }
  ws.close();
  const end = await fn('sana-live-tool', tok, { action: 'end', live_session_id: sid, reason: 'user' });
  sess.end = end.j; sess.closed = closed;
  console.log(`   end: ${JSON.stringify(end.j)}`);
}
const file = path.join(OUT, `run-${Date.now()}.json`);
fs.writeFileSync(file, JSON.stringify(report, null, 1));
console.log(`\nsaved ${file}`);

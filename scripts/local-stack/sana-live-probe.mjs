// Sana Live M1 · automated probe of the Gemini Live API (real model) — latency, language, interruption, tool call.
// Needs a minted ephemeral token: the TEMPORARY function sana-live-probe (service key) is called; nothing else on the project is
// touched. English questions are spoken by macOS `say` (16 kHz PCM, streamed at real-time pace); Malayalam has no macOS voice,
// so Malayalam turns are sent as text, and Sana's own Malayalam audio is fed back as speech input to check understanding.
//   SUPABASE_URL=… SUPABASE_SECRET_KEY=… node scripts/local-stack/sana-live-probe.mjs --out ~/erp-work/s5
// Output: per-turn JSON + WAV files of a few answers (for listening), and a summary table.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const OUT = opt('--out', path.join(os.homedir(), 'erp-work/s5'));
fs.mkdirSync(OUT, { recursive: true });
const SB = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SECRET_KEY;
const MODEL = opt('--model', undefined);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => { const v = xs.filter((x) => x != null).sort((a, b) => a - b); return v.length ? Math.round(v[Math.min(v.length - 1, Math.ceil(p / 100 * v.length) - 1)]) : null; };

async function token(language) {
  const r = await fetch(`${SB}/functions/v1/sana-live-probe`, { method: 'POST', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': 'application/json' }, body: JSON.stringify({ language, model: MODEL }) });
  const j = await r.json(); if (!j.token) throw new Error('token: ' + JSON.stringify(j)); return j;
}
/** English speech → 16 kHz mono 16-bit PCM (macOS say + afconvert). */
function speak(text, voice = 'Samantha') {
  const aiff = path.join(os.tmpdir(), `sana-${Date.now()}.aiff`), wav = aiff.replace('.aiff', '.wav');
  execFileSync('say', ['-v', voice, '-o', aiff, text]);
  execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', aiff, wav]);
  const buf = fs.readFileSync(wav); fs.unlinkSync(aiff); fs.unlinkSync(wav);
  const i = buf.indexOf('data'); return buf.subarray(i + 8);
}
function wavFile(file, pcm, rate) {
  const h = Buffer.alloc(44); h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  fs.writeFileSync(file, Buffer.concat([h, pcm]));
}
/** 24 kHz → 16 kHz (linear) for feeding Sana's own audio back as input. */
function resample24to16(pcm) {
  const n = Math.floor(pcm.length / 2), m = Math.floor(n * 2 / 3), out = Buffer.alloc(m * 2);
  for (let j = 0; j < m; j++) { const x = j * 1.5, i = Math.floor(x), f = x - i; const a = pcm.readInt16LE(i * 2), b = i + 1 < n ? pcm.readInt16LE((i + 1) * 2) : a; out.writeInt16LE(Math.round(a + (b - a) * f), j * 2); }
  return out;
}

class Live {
  constructor(t) { this.t = t; this.handlers = []; }
  async open() {
    this.ws = new WebSocket(`${this.t.ws}?access_token=${encodeURIComponent(this.t.token)}`);
    this.ws.onmessage = async (e) => { const raw = typeof e.data === 'string' ? e.data : Buffer.from(await e.data.arrayBuffer()).toString(); const m = JSON.parse(raw); for (const h of [...this.handlers]) h(m); };
    await new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = (e) => rej(new Error('ws error')); });
    this.ws.onclose = (e) => { this.closed = { code: e.code, reason: e.reason }; };
    const ready = this.wait((m) => m.setupComplete);
    this.send({ setup: { model: `models/${this.t.model}` } });
    await ready;
  }
  send(m) { this.ws.send(JSON.stringify(m)); }
  wait(pred, ms = 20000) { return new Promise((res, rej) => { const h = (m) => { if (pred(m)) { this.handlers = this.handlers.filter((x) => x !== h); res(m); } }; this.handlers.push(h); setTimeout(() => { this.handlers = this.handlers.filter((x) => x !== h); rej(new Error('timeout')); }, ms); }); }
  async streamAudio(pcm, { tailSilenceMs = 1200, onEnd } = {}) {
    const chunk = 3200; // 100 ms at 16 kHz
    for (let i = 0; i < pcm.length; i += chunk) { this.send({ realtimeInput: { audio: { data: pcm.subarray(i, i + chunk).toString('base64'), mimeType: 'audio/pcm;rate=16000' } } }); await sleep(100); }
    onEnd?.();
    const silence = Buffer.alloc(chunk);
    for (let s = 0; s < tailSilenceMs; s += 100) { this.send({ realtimeInput: { audio: { data: silence.toString('base64'), mimeType: 'audio/pcm;rate=16000' } } }); await sleep(100); }
  }
  close() { try { this.ws.close(); } catch { /* closed */ } }
}

const STOCK = { items: [{ code: 'SF5160IC KC', name: 'SANFORD SINGLE BURNER INFRARED COOKER 2200 WATTS', unit: 'PCS', warehouses: [{ warehouse: '01', on_hand: 1240, committed: 40, ordered: 0, available: 1200 }] }], cost_visible: false };

/** One turn: returns timings and transcripts. `sendTurn(ts)` starts the input and calls ts.end() when the user stops speaking. */
async function turn(live, sendTurn, { saveAs } = {}) {
  const r = { first_audio_ms: null, total_ms: null, tool: null, in_text: '', out_text: '', interrupted: false, audio_bytes: 0 };
  const audio = []; let tEnd = null;
  const h = (m) => {
    const sc = m.serverContent;
    if (m.toolCall) {
      r.tool = m.toolCall.functionCalls?.map((f) => `${f.name}(${JSON.stringify(f.args)})`).join(', ');
      live.send({ toolResponse: { functionResponses: m.toolCall.functionCalls.map((f) => ({ id: f.id, name: f.name, response: STOCK })) } });
    }
    if (!sc) return;
    if (sc.inputTranscription?.text) r.in_text += sc.inputTranscription.text;
    if (sc.outputTranscription?.text) r.out_text += sc.outputTranscription.text;
    if (sc.interrupted) r.interrupted = true;
    for (const p of sc.modelTurn?.parts ?? []) if (p.inlineData?.data) {
      const b = Buffer.from(p.inlineData.data, 'base64'); audio.push(b); r.audio_bytes += b.length;
      if (r.first_audio_ms == null && tEnd != null) r.first_audio_ms = Math.round(performance.now() - tEnd);
    }
  };
  live.handlers.push(h);
  const done = live.wait((m) => m.serverContent?.turnComplete, 30000).catch(() => null);
  await sendTurn({ end: () => { tEnd = performance.now(); } });
  await done;
  if (tEnd != null) r.total_ms = Math.round(performance.now() - tEnd);
  live.handlers = live.handlers.filter((x) => x !== h);
  r.pcm = Buffer.concat(audio);
  if (saveAs && r.pcm.length) wavFile(path.join(OUT, saveAs), r.pcm, 24000);
  return r;
}

const EN = ['How many open purchase orders do we have?', 'What is the stock of SF5160IC KC?', 'Which customers owe us the most?', 'What were our net sales this month?',
  'Summarise the receivables ageing.', 'How much do we owe our suppliers?', 'Show the overdue customer invoices.', 'What is the stock of item SF6180SLC LC?',
  'Hello Sana, can you hear me?', 'Thank you, that is all.'];
const ML = ['എത്ര തുറന്ന പർച്ചേസ് ഓർഡറുകൾ ഉണ്ട്?', 'SF5160IC KC ന്റെ സ്റ്റോക്ക് എത്ര?', 'ഏറ്റവും കൂടുതൽ പണം തരാനുള്ള ഉപഭോക്താക്കൾ ആരൊക്കെ?', 'ഈ മാസത്തെ മൊത്തം വിൽപ്പന എത്ര?',
  'സ്വീകാര്യ തുകകളുടെ കാലപ്പഴക്കം ചുരുക്കി പറയുക.', 'വിതരണക്കാർക്ക് നമ്മൾ എത്ര കൊടുക്കാനുണ്ട്?', 'കുടിശ്ശികയുള്ള ഉപഭോക്തൃ ഇൻവോയ്സുകൾ കാണിക്കുക.', 'SF6180SLC LC എന്ന ഇനത്തിന്റെ സ്റ്റോക്ക് എത്ര?',
  'ഹലോ സന, കേൾക്കാമോ?', 'നന്ദി, അത്രമതി.'];

const rows = [];
const log = (r) => { rows.push(r); console.log(`${r.set} ${String(r.n).padStart(2)} first audio ${String(r.first_audio_ms).padStart(5)} ms · total ${String(r.total_ms).padStart(5)} · tool ${r.tool ?? '-'} · in "${(r.in_text || '').slice(0, 50)}" · out "${(r.out_text || '').slice(0, 70)}"`); };

// 1. English, spoken (10 turns, one session)
{
  const live = new Live(await token('en')); await live.open();
  for (const [i, q] of EN.entries()) {
    const pcm = speak(q);
    const r = await turn(live, (ts) => live.streamAudio(pcm, { onEnd: ts.end }), { saveAs: i < 2 ? `en-${i + 1}.wav` : undefined });
    log({ set: 'en-speech', n: i + 1, q, ...r, pcm: undefined });
  }
  live.close();
}
// 2. Malayalam, text in, Malayalam speech out (10 turns, one session)
const mlAudio = [];
{
  const live = new Live(await token('ml')); await live.open();
  for (const [i, q] of ML.entries()) {
    const r = await turn(live, async (ts) => { ts.end(); live.send({ clientContent: { turns: [{ role: 'user', parts: [{ text: q }] }], turnComplete: true } }); }, { saveAs: i < 4 ? `ml-${i + 1}.wav` : undefined });
    if (i < 3) mlAudio.push({ q, pcm: r.pcm, said: r.out_text });
    log({ set: 'ml-text', n: i + 1, q, ...r, pcm: undefined });
  }
  live.close();
}
// 3. Malayalam understanding: Sana's own Malayalam audio fed back as speech input (3 turns)
{
  const live = new Live(await token('ml')); await live.open();
  for (const [i, a] of mlAudio.entries()) {
    const pcm = resample24to16(a.pcm);
    const r = await turn(live, (ts) => live.streamAudio(pcm, { onEnd: ts.end }));
    log({ set: 'ml-speech-loopback', n: i + 1, q: a.said, ...r, pcm: undefined });
  }
  live.close();
}
// 4. Interruption: start a long answer, talk over it after the first audio, expect `interrupted`
{
  const live = new Live(await token('en')); await live.open();
  const t = { interrupted_after_ms: null, first_audio_ms: null };
  let t0 = null, tTalk = null;
  live.handlers.push((m) => {
    if (m.serverContent?.modelTurn && t.first_audio_ms == null) t.first_audio_ms = Math.round(performance.now() - t0);
    if (m.serverContent?.interrupted && t.interrupted_after_ms == null && tTalk) t.interrupted_after_ms = Math.round(performance.now() - tTalk);
  });
  t0 = performance.now();
  live.send({ clientContent: { turns: [{ role: 'user', parts: [{ text: 'Please explain in detail, in about eight sentences, how receivables ageing works and why it matters.' }] }], turnComplete: true } });
  await live.wait((m) => m.serverContent?.modelTurn, 15000).catch(() => null);
  await sleep(1500);
  tTalk = performance.now();
  const pcm = speak('Sorry Sana, stop. What is the stock of SF5160IC KC?');
  const after = turn(live, (ts) => live.streamAudio(pcm, { onEnd: ts.end }));
  const r2 = await after;
  log({ set: 'interrupt', n: 1, q: 'talk over a long answer', first_audio_ms: r2.first_audio_ms, total_ms: r2.total_ms, tool: r2.tool, in_text: r2.in_text, out_text: r2.out_text, interrupted: t.interrupted_after_ms != null, interrupted_after_ms: t.interrupted_after_ms });
  live.close();
}

const sum = (set) => { const s = rows.filter((r) => r.set === set); return { n: s.length, first_audio_p50: pct(s.map((r) => r.first_audio_ms), 50), first_audio_p90: pct(s.map((r) => r.first_audio_ms), 90), total_p50: pct(s.map((r) => r.total_ms), 50), tool_turns: s.filter((r) => r.tool).length }; };
const summary = { model: MODEL ?? 'default', at: new Date().toISOString(), en_speech: sum('en-speech'), ml_text: sum('ml-text'), ml_loopback: sum('ml-speech-loopback'), interrupt: rows.find((r) => r.set === 'interrupt') };
fs.writeFileSync(path.join(OUT, `live-probe-${Date.now()}.json`), JSON.stringify({ summary, rows }, null, 1));
console.log('\n' + JSON.stringify(summary, null, 1));


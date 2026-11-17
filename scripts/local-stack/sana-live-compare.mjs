// Sana Live · model comparison on the same Malayalam turns (S5 pre-M2). LOCAL script, real Gemini Live API.
// 1. The reference voice: gemini-3.1-flash-live-preview is asked to read each Malayalam question aloud word for word (its audio is
//    kept, 24 kHz → 16 kHz). That audio is the same input for every model, so the comparison is fair.
// 2. Each model under test gets those clips as speech in one session: first audio (from the end of the clip), what it heard
//    (input transcription), which tool it called with which item code, what it said; its answers are saved as WAV for listening.
// Tokens come from the TEMPORARY function sana-live-probe (service key). The tool result is canned (the comparison is about voice,
// hearing and codes, not data).
//   SUPABASE_URL=… SUPABASE_SECRET_KEY=… node scripts/local-stack/sana-live-compare.mjs --models gemini-3.1-flash-live-preview,gemini-2.5-flash-native-audio-latest
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const OUT = opt('--out', path.join(os.homedir(), 'erp-work/s5/compare'));
fs.mkdirSync(OUT, { recursive: true });
const MODELS = opt('--models', 'gemini-3.1-flash-live-preview,gemini-2.5-flash-native-audio-latest').split(',');
const REF = 'gemini-3.1-flash-live-preview';
const SB = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SECRET_KEY;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => { const v = xs.filter((x) => x != null).sort((a, b) => a - b); return v.length ? Math.round(v[Math.min(v.length - 1, Math.ceil(p / 100 * v.length) - 1)]) : null; };

const TURNS = [
  { text: 'SF5160IC KC എന്ന ഐറ്റത്തിന്റെ സ്റ്റോക്ക് എത്രയുണ്ട്?', code: 'SF5160IC KC' },
  { text: 'SF6180SLC LC ന്റെ സ്റ്റോക്ക് പറയാമോ?', code: 'SF6180SLC LC' },
  { text: 'SF2665SL LC എന്ന ലൈറ്റ് സ്റ്റോക്കിൽ ഉണ്ടോ?', code: 'SF2665SL LC' },
  { text: 'ഇന്നത്തെ ദിവസം എങ്ങനെയുണ്ട്? ഒരു വാചകത്തിൽ പറയൂ.', code: null },
  { text: 'സ്റ്റോക്ക് കുറവുള്ള ഐറ്റങ്ങളെക്കുറിച്ച് നമുക്ക് എന്ത് ചെയ്യാം? ചുരുക്കി പറയൂ.', code: null },
  { text: 'SF5160IC KC യുടെ ലഭ്യമായ എണ്ണം മാത്രം പറയൂ.', code: 'SF5160IC KC' },
];
const norm = (c) => String(c ?? '').toUpperCase().replace(/[\s\-_.]/g, '');

async function token(model, language = 'ml') {
  const r = await fetch(`${SB}/functions/v1/sana-live-probe`, { method: 'POST', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': 'application/json' }, body: JSON.stringify({ language, model }) });
  const j = await r.json(); if (!j.token) throw new Error(`token ${model}: ${JSON.stringify(j)}`); return j;
}
function wavFile(file, pcm, rate) {
  const h = Buffer.alloc(44); h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  fs.writeFileSync(file, Buffer.concat([h, pcm]));
}
function resample24to16(pcm) {
  const n = Math.floor(pcm.length / 2), m = Math.floor(n * 2 / 3), out = Buffer.alloc(m * 2);
  for (let j = 0; j < m; j++) { const x = j * 1.5, i = Math.floor(x), f = x - i; const a = pcm.readInt16LE(i * 2), b = i + 1 < n ? pcm.readInt16LE((i + 1) * 2) : a; out.writeInt16LE(Math.round(a + (b - a) * f), j * 2); }
  return out;
}
const STOCK = (q) => ({ items: [{ code: norm(q) === norm('SF5160IC KC') ? 'SF5160IC KC' : String(q), name: 'SANFORD ITEM', unit: 'PCS', warehouses: [{ warehouse: '01', on_hand: 1240, committed: 40, ordered: 0, available: 1200 }] }], cost_visible: false });

class Live {
  constructor(t) { this.t = t; this.handlers = []; }
  async open() {
    this.ws = new WebSocket(`${this.t.ws}?access_token=${encodeURIComponent(this.t.token)}`);
    this.ws.onmessage = async (e) => { const raw = typeof e.data === 'string' ? e.data : Buffer.from(await e.data.arrayBuffer()).toString(); const m = JSON.parse(raw); for (const h of [...this.handlers]) h(m); };
    await new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = () => rej(new Error('ws error')); });
    this.ws.onclose = (e) => { this.closed = `${e.code} ${e.reason}`; };
    const ready = this.wait((m) => m.setupComplete, 15000);
    this.send({ setup: { model: `models/${this.t.model}` } });
    await ready;
  }
  send(m) { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(m)); }
  wait(pred, ms = 30000) { return new Promise((res, rej) => { const h = (m) => { if (pred(m)) { this.handlers = this.handlers.filter((x) => x !== h); res(m); } }; this.handlers.push(h); setTimeout(() => { this.handlers = this.handlers.filter((x) => x !== h); rej(new Error(`timeout (${this.closed ?? 'open'})`)); }, ms); }); }
  close() { try { this.ws.close(); } catch { /* closed */ } }
}

// one turn: input = text or 16 kHz speech; returns audio, transcripts, tool calls, first audio
async function turn(live, input) {
  const r = { first_audio_ms: null, in_text: '', out_text: '', tools: [], audio: [] };
  let tEnd = null;
  const h = (m) => {
    if (m.toolCall) for (const f of m.toolCall.functionCalls ?? []) { r.tools.push({ name: f.name, args: f.args }); live.send({ toolResponse: { functionResponses: [{ id: f.id, name: f.name, response: STOCK(f.args?.query) }] } }); }
    const sc = m.serverContent; if (!sc) return;
    if (sc.inputTranscription?.text) r.in_text += sc.inputTranscription.text;
    if (sc.outputTranscription?.text) r.out_text += sc.outputTranscription.text;
    for (const p of sc.modelTurn?.parts ?? []) if (p.inlineData?.data) { r.audio.push(Buffer.from(p.inlineData.data, 'base64')); if (r.first_audio_ms == null && tEnd != null) r.first_audio_ms = Math.round(performance.now() - tEnd); }
  };
  live.handlers.push(h);
  const done = live.wait((m) => m.serverContent?.turnComplete, 40000).catch((e) => { r.error = e.message; });
  if (typeof input === 'string') { tEnd = performance.now(); live.send({ clientContent: { turns: [{ role: 'user', parts: [{ text: input }] }], turnComplete: true } }); }
  else {
    const chunk = 3200;
    for (let i = 0; i < input.length; i += chunk) { live.send({ realtimeInput: { audio: { data: input.subarray(i, i + chunk).toString('base64'), mimeType: 'audio/pcm;rate=16000' } } }); await sleep(100); }
    tEnd = performance.now();
    const silence = Buffer.alloc(chunk).toString('base64');
    for (let s = 0; s < 1500; s += 100) { live.send({ realtimeInput: { audio: { data: silence, mimeType: 'audio/pcm;rate=16000' } } }); await sleep(100); }
  }
  await done;
  live.handlers = live.handlers.filter((x) => x !== h);
  r.pcm = Buffer.concat(r.audio); delete r.audio;
  await sleep(800);
  return r;
}

// 1. reference clips
const clips = [];
{
  const live = new Live(await token(REF)); await live.open();
  for (const [i, T] of TURNS.entries()) {
    const r = await turn(live, `ഈ വാചകം മാത്രം, ഒരു മാറ്റവുമില്ലാതെ, സാധാരണ വേഗത്തിൽ ഉറക്കെ വായിക്കുക. വേറൊന്നും പറയരുത്, ടൂൾ ഉപയോഗിക്കരുത്: "${T.text}"`);
    clips.push({ ...T, said: r.out_text, pcm16: resample24to16(r.pcm) });
    wavFile(path.join(OUT, `input-${i + 1}.wav`), r.pcm, 24000);
    console.log(`clip ${i + 1}: "${r.out_text.slice(0, 80)}"`);
  }
  live.close();
}
// 2. models under test
const results = {};
for (const model of MODELS) {
  const rows = [];
  try {
    const live = new Live(await token(model)); await live.open();
    for (const [i, c] of clips.entries()) {
      const r = await turn(live, c.pcm16);
      const codeHeard = c.code ? norm(r.in_text).includes(norm(c.code)) : null;
      const codeTool = c.code ? r.tools.some((t) => norm(t.args?.query) === norm(c.code)) : null;
      if (r.pcm.length) wavFile(path.join(OUT, `${model}-${i + 1}.wav`), r.pcm, 24000);
      const ml = (r.out_text.match(/[\u0D00-\u0D7F]/g) ?? []).length, all = (r.out_text.match(/\p{L}/gu) ?? []).length;
      rows.push({ n: i + 1, first_audio_ms: r.first_audio_ms, heard: r.in_text, code: c.code, code_heard: codeHeard, code_in_tool: codeTool, tools: r.tools, said: r.out_text, ml_share: all ? Math.round(100 * ml / all) : null, error: r.error });
      console.log(`${model} ${i + 1}: first audio ${r.first_audio_ms} ms · tool ${r.tools.map((t) => JSON.stringify(t.args)).join(' ') || '-'} · heard "${r.in_text.slice(0, 50)}" · said "${r.out_text.slice(0, 60)}"`);
    }
    live.close();
  } catch (e) { rows.push({ error: e.message }); console.log(model, 'ERROR', e.message); }
  const ok = rows.filter((r) => !r.error);
  results[model] = { rows, first_audio_p50: pct(ok.map((r) => r.first_audio_ms), 50), first_audio_p90: pct(ok.map((r) => r.first_audio_ms), 90),
    code_tool: `${ok.filter((r) => r.code_in_tool).length}/${ok.filter((r) => r.code).length}`, code_heard: `${ok.filter((r) => r.code_heard).length}/${ok.filter((r) => r.code).length}`,
    ml_share_avg: Math.round(ok.reduce((s, r) => s + (r.ml_share ?? 0), 0) / Math.max(1, ok.length)) };
}
fs.writeFileSync(path.join(OUT, `compare-${Date.now()}.json`), JSON.stringify({ clips: clips.map(({ pcm16, ...c }) => c), results }, null, 1));
for (const [m, r] of Object.entries(results)) console.log(`\n${m}: first audio p50 ${r.first_audio_p50} / p90 ${r.first_audio_p90} ms · item code in tool call ${r.code_tool} · code in transcript ${r.code_heard} · Malayalam letters in answers ${r.ml_share_avg} %`);


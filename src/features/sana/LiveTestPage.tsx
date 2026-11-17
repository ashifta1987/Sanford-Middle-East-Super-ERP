import { useEffect, useRef, useState } from 'react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { supabase, SUPABASE_URL } from '@/lib/supabase';

/**
 * S5 · Sana Live — hidden test page (/sana/live-test). M2: any Sana user with voice on (the token function checks profile,
 * company, Sana/voice switches, daily limits and the Live-minutes cap on the server). Talk continuously with the Gemini Live API
 * through a single-use ephemeral token whose setup is locked server-side: the role's own lookups (the same list as Ask) and the
 * transcription pinned to the session language. Every lookup runs through sana-live-tool against the server-side session.
 * Each turn is logged like a typed turn (via 'live'); End closes the session. No audio is stored. English labels: test harness.
 *
 * First audio is measured from the moment you stopped speaking (the last microphone frame above the speech threshold) to the
 * first audio chunk from Sana; for typed test turns, from the moment the text was sent.
 */
type Line = { who: 'you' | 'sana' | 'note'; text: string; ms?: number | null; tool?: string; unverified?: boolean; otherScript?: boolean };
const LANGS: Array<[string, string]> = [['en', 'English'], ['ml', 'Malayalam'], ['ar', 'Arabic'], ['hi', 'Hindi'], ['ta', 'Tamil']];
const WORKLET_URL = '/sana-mic-worklet.js';   // same origin: passes script-src 'self'
const SETUP_TIMEOUT_MS = 10_000;
// letters of the session language's script: an input transcript without any is flagged (the server pins the language; this shows a miss)
const SCRIPT: Record<string, RegExp> = { ml: /[\u0D00-\u0D7F]/, ar: /[\u0600-\u06FF]/, hi: /[\u0900-\u097F]/, ta: /[\u0B80-\u0BFF]/ };
const TOOL_LABEL: Record<string, string> = {
  find_records: 'search', get_document: 'documents', list_documents: 'document lists', sales_summary: 'sales', purchase_summary: 'purchases',
  inventory_summary: 'inventory', record_counts: 'counts', get_partner: 'customers/suppliers', get_stock: 'stock', receivables: 'receivables',
  payables: 'payables', finance_summary: 'finance', banking: 'banking', alerts: 'alerts', my_approvals: 'approvals', my_employee_record: 'my HR record', people: 'people (HR)',
};

const b64 = (bytes: Uint8Array) => { let s = ''; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };

async function callFn(name: string, body: unknown) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, { method: 'POST', body: JSON.stringify(body),
    headers: { Authorization: `Bearer ${data.session?.access_token ?? ''}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json' } });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((j as { error?: string }).error ?? `HTTP ${res.status}`);
  return j as Record<string, unknown>;
}

export function LiveTestPage() {
  const { profile } = useAuth();
  const { company: selected } = useCompany();
  // "All companies" (GRP) is not a company Sana can answer for: use the user's home company, else ask to pick one
  const company = selected && selected !== 'GRP' ? selected : (profile?.user?.company_code ?? null);
  const allowed = Boolean(profile?.user);
  const [lang, setLang] = useState('en');
  const [state, setState] = useState<'idle' | 'connecting' | 'live' | 'ended' | 'error'>('idle');
  const [error, setError] = useState<string | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [model, setModel] = useState('');
  const [typed, setTyped] = useState('');
  const [stats, setStats] = useState<number[]>([]);
  const [tools, setTools] = useState<string[] | null>(null);
  const [left, setLeft] = useState<number | null>(null);
  const r = useRef<{ ws?: WebSocket; mic?: AudioContext; out?: AudioContext; stream?: MediaStream; nextAt: number; sources: Set<AudioBufferSourceNode>;
    lastSpeech: number; tEnd: number | null; first: number | null; tStart: number; you: string; sana: string; tools: string[]; conv: string | null; session: string }>({
    nextAt: 0, sources: new Set(), lastSpeech: 0, tEnd: null, first: null, tStart: 0, you: '', sana: '', tools: [], conv: null, session: '' });
  const add = (l: Line) => setLines((x) => [...x, l]);

  const stopPlayback = () => { for (const s of r.current.sources) { try { s.stop(); } catch { /* ended */ } } r.current.sources.clear(); r.current.nextAt = 0; };
  const play = (pcm: Uint8Array) => {
    const ctx = r.current.out!; const n = Math.floor(pcm.length / 2); const v = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
    const buf = ctx.createBuffer(1, Math.max(1, n), 24000); const ch = buf.getChannelData(0);
    for (let i = 0; i < n; i++) ch[i] = v.getInt16(i * 2, true) / 0x8000;
    const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination);
    const at = Math.max(ctx.currentTime + 0.02, r.current.nextAt); src.start(at); r.current.nextAt = at + buf.duration;
    r.current.sources.add(src); src.onended = () => r.current.sources.delete(src);
  };

  async function endTurn() {
    const c = r.current; const you = c.you.trim(), sana = c.sana.trim();
    const ms = c.first; const total = c.tEnd != null ? Math.round(performance.now() - c.tEnd) : null;
    c.you = ''; c.sana = ''; c.first = null; const tools = c.tools; c.tools = []; c.tEnd = null;
    if (!you && !sana) return;
    if (ms != null) setStats((s) => [...s, ms]);
    try {
      const j = await callFn('sana-live-tool', { action: 'log_turn', live_session_id: c.session, conversation_id: c.conv, user_text: you, sana_text: sana, tools,
        timings: { ms_first_audio: ms, ms_total: total }, device: window.matchMedia?.('(pointer: coarse)').matches ? 'phone' : 'desktop' });
      c.conv = String(j.conversation_id ?? c.conv ?? '') || null;
      setLines((x) => x.map((l, i) => (i === x.length - 1 && l.who === 'sana' ? { ...l, unverified: Boolean(j.unverified) } : l)));
    } catch (e) { add({ who: 'note', text: `log failed: ${(e as Error).message}` }); }
  }

  function endSession(reason: string) {   // once per session; the server caps the seconds at the token expiry anyway
    const sid = r.current.session; if (!sid) return; r.current.session = '';
    void callFn('sana-live-tool', { action: 'end', live_session_id: sid, reason }).catch(() => {});
  }
  function fail(msg: string) { setError(msg); setState('error'); stopMic(); stopPlayback(); endSession('error'); try { r.current.ws?.close(); } catch { /* closed */ } }
  async function start() {
    if (!company) { fail('Pick a company first.'); return; }
    setError(null); setState('connecting'); setLines([]); setStats([]);
    // 1. microphone permission first, so the browser prompt comes before anything connects
    try { await startMic(); } catch (e) {
      const name = (e as { name?: string }).name;
      fail(name === 'NotAllowedError' ? 'Microphone permission was refused. Allow the microphone for this site and try again.' : `Microphone could not start: ${(e as Error).message}`);
      return;
    }
    try {
      const t = await callFn('sana-live-token', { company, language: lang });
      setModel(String(t.model)); r.current.session = String(t.live_session_id); r.current.conv = null;
      setTools((t.tools as string[]) ?? []); setLeft(Number(t.seconds_left ?? 0));
      const out = new AudioContext({ sampleRate: 24000 }); r.current.out = out;
      let ready = false;
      const ws = new WebSocket(`${t.ws}?access_token=${encodeURIComponent(String(t.token))}`); r.current.ws = ws;
      const setupTimer = setTimeout(() => fail('Sana Live did not answer within 10 seconds. Check the connection and try again.'), SETUP_TIMEOUT_MS);
      ws.onerror = () => { clearTimeout(setupTimer); fail('Could not connect to Sana Live (the connection was blocked or dropped).'); };
      ws.onclose = (e) => { clearTimeout(setupTimer);
        if (!ready) { fail(`Sana Live refused the connection (${e.code}${e.reason ? ': ' + e.reason : ''}). Try again.`); return; }   // closed before setupComplete: an error, not an end
        setState((st) => (st === 'error' ? st : 'ended')); add({ who: 'note', text: `session ended (${e.code}${e.reason ? ': ' + e.reason : ''})` }); stopMic(); endSession('user'); };
      ws.onmessage = async (e) => {
        const m = JSON.parse(typeof e.data === 'string' ? e.data : await (e.data as Blob).text());
        const c = r.current;
        if (m.setupComplete) { ready = true; clearTimeout(setupTimer); setState('live'); add({ who: 'note', text: `connected · ${t.model} · tools: ${(t.tools as string[]).join(', ') || 'none'}` }); return; }
        if (m.toolCall) {
          for (const f of m.toolCall.functionCalls ?? []) {
            c.tools.push(f.name); add({ who: 'note', text: `looking up ${f.name}(${JSON.stringify(f.args)})`, tool: f.name });
            const res = await callFn('sana-live-tool', { action: 'tool', live_session_id: c.session, tool: f.name, args: f.args }).catch((err) => ({ result: { error: (err as Error).message } }));
            ws.send(JSON.stringify({ toolResponse: { functionResponses: [{ id: f.id, name: f.name, response: res.result ?? res }] } }));
          }
        }
        const sc = m.serverContent; if (!sc) return;
        if (sc.interrupted) { stopPlayback(); add({ who: 'note', text: 'interrupted' }); }
        if (sc.inputTranscription?.text) c.you += sc.inputTranscription.text;
        if (sc.outputTranscription?.text) c.sana += sc.outputTranscription.text;
        for (const p of sc.modelTurn?.parts ?? []) if (p.inlineData?.data) {
          if (c.first == null) { const from = c.tEnd ?? c.lastSpeech; c.first = from ? Math.round(performance.now() - from) : null; if (c.tEnd == null) c.tEnd = c.lastSpeech || performance.now(); }
          play(unb64(p.inlineData.data));
        }
        if (sc.turnComplete) {
          if (c.you.trim()) add({ who: 'you', text: c.you.trim(), otherScript: SCRIPT[lang] ? !SCRIPT[lang].test(c.you) : false });
          if (c.sana.trim()) add({ who: 'sana', text: c.sana.trim(), ms: c.first });
          void endTurn();
        }
      };
      ws.onopen = () => ws.send(JSON.stringify({ setup: { model: `models/${t.model}` } }));   // the token's locked setup applies
    } catch (e) { fail((e as Error).message); }
  }
  async function startMic() {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
    const ctx = new AudioContext({ sampleRate: 16000 });
    await ctx.audioWorklet.addModule(WORKLET_URL);
    const node = new AudioWorkletNode(ctx, 'sana-mic'); ctx.createMediaStreamSource(stream).connect(node);
    let pending: Float32Array[] = []; let count = 0;
    node.port.onmessage = (ev) => {
      const f = ev.data as Float32Array; pending.push(f); count += f.length;
      let e = 0; for (let i = 0; i < f.length; i++) e += f[i] * f[i];
      if (Math.sqrt(e / f.length) > 0.02) { r.current.lastSpeech = performance.now(); if (r.current.sources.size) { /* the server detects barge-in; local playback stops on `interrupted` */ } }
      if (count >= 1600) {   // 100 ms
        const all = new Int16Array(count); let o = 0;
        for (const p of pending) for (let i = 0; i < p.length; i++) all[o++] = Math.max(-1, Math.min(1, p[i])) * 0x7fff;
        pending = []; count = 0;
        r.current.ws?.readyState === WebSocket.OPEN && r.current.ws.send(JSON.stringify({ realtimeInput: { audio: { data: b64(new Uint8Array(all.buffer)), mimeType: 'audio/pcm;rate=16000' } } }));
      }
    };
    r.current.mic = ctx; r.current.stream = stream;
  }
  function stopMic() { r.current.stream?.getTracks().forEach((t) => t.stop()); void r.current.mic?.close().catch(() => {}); r.current.mic = undefined; }
  function stop() { stopMic(); stopPlayback(); endSession('user'); r.current.ws?.close(); }
  function sendTyped() {
    if (!typed.trim() || r.current.ws?.readyState !== WebSocket.OPEN) return;
    r.current.tEnd = performance.now(); r.current.you = typed.trim();
    r.current.ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text: typed.trim() }] }], turnComplete: true } })); setTyped('');
  }
  useEffect(() => () => stop(), []); // eslint-disable-line react-hooks/exhaustive-deps

  if (!allowed) return <p className="p-6 text-sm text-muted">Sana Live needs a Southfield profile.</p>;
  const p = (q: number) => { const v = [...stats].sort((a, b) => a - b); return v.length ? v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)] : null; };
  return (
    <div className="mx-auto max-w-3xl space-y-4 p-6" data-testid="sana-live-test">
      <h1 className="text-xl font-semibold">Sana Live · test (M2)</h1>
      {error && <p role="alert" data-testid="sana-live-error" className="rounded-btn border border-crit-fg/30 bg-crit-bg px-3 py-2 text-sm text-crit-fg">{error}</p>}
      <p className="text-sm text-muted">Company {company ?? '—'}{selected === 'GRP' && company ? ' (your home company; "All companies" is not used here)' : ''} · {model || 'model chosen on connect'} · first audio p50 {p(0.5) ?? '—'} ms / p90 {p(0.9) ?? '—'} ms ({stats.length} turns)</p>
      <p data-testid="sana-live-tools" className="rounded-btn border border-line bg-surface px-3 py-2 text-sm">
        {tools == null ? 'Your role\'s lookups are shown when you start.'
          : tools.length ? `This role has: ${tools.map((x) => TOOL_LABEL[x] ?? x).join(', ')}.`
            : 'This role has no Sana lookups (for example Administration/IT only): Sana can talk, but cannot look up company figures.'}
        {left != null && ` · Live minutes left today: ${Math.floor(left / 60)}.`}
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <select value={lang} onChange={(e) => setLang(e.target.value)} disabled={state === 'live' || state === 'connecting'} className="min-h-[40px] rounded-btn border border-line px-2">
          {LANGS.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
        </select>
        {state !== 'live'
          ? <button type="button" onClick={() => void start()} disabled={state === 'connecting'} className="min-h-[40px] rounded-btn bg-primary px-4 font-semibold text-white">{state === 'connecting' ? 'Connecting…' : state === 'error' ? 'Try again' : 'Start talking'}</button>
          : <button type="button" onClick={stop} className="min-h-[40px] rounded-btn border border-line px-4">End</button>}
        <input value={typed} onChange={(e) => setTyped(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') sendTyped(); }} placeholder="or type a test turn" className="min-h-[40px] flex-1 rounded-btn border border-line px-3" />
      </div>
      <ul className="space-y-2">
        {lines.map((l, i) => (
          <li key={i} className={l.who === 'you' ? 'text-end' : ''}>
            <span dir="auto" lang={l.who === 'note' ? 'en' : lang} className={l.who === 'note' ? 'text-xs text-muted' : `inline-block rounded-[14px] px-3 py-2 text-[15px] ${l.who === 'you' ? 'bg-primary text-white' : 'border border-line bg-surface'}`}>
              {l.text}{l.ms != null && <span className="ms-2 text-xs opacity-70">{l.ms} ms</span>}{l.unverified && <span className="ms-2 text-xs text-warn-fg">unverified</span>}{l.otherScript && <span className="ms-2 text-xs opacity-70">(transcribed in another script)</span>}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}


import { supabase, SUPABASE_URL } from '@/lib/supabase';
import { primeAudio, PcmStreamPlayer, stopAllSpeech } from './speechQueue';

/**
 * S5 · M3 — Sana Live in the panel: one continuous voice conversation with the Gemini Live API.
 *
 * 1. sana-live-token (Edge Function) checks the user exactly like Ask and returns a single-use ephemeral token whose whole setup
 *    (model, system prompt, the role's lookups, audio, transcription pinned to the session language) is locked server-side.
 * 2. The browser opens the socket straight to Gemini with that token and sends only {setup:{model}}; the API key never reaches it.
 * 3. Microphone: 16 kHz 16-bit PCM from an AudioWorklet (public/sana-mic-worklet.js), 100 ms chunks. Sana's audio (24 kHz PCM)
 *    plays through speechQueue's PcmStreamPlayer; when the Live API says `interrupted` (the user talked over Sana) playback stops.
 * 4. Every lookup goes to sana-live-tool (session + role checked again, the same RPC as Ask with the user's JWT, masked result).
 * 5. After each turn: sana-live-tool log_turn writes the transcript like a typed turn (via 'live'), with timings, and returns the
 *    flags (unverified figure, stock without a quantity, wrong currency, wrong script) for the transcript line.
 * End: the button, 60 s of silence (nobody speaks, Sana says nothing), the daily minutes cap / token expiry, or the tab hidden for
 * more than 30 s. The session is ended on the server once (sana-live-tool end). No audio is stored anywhere.
 */
export type LiveState = 'idle' | 'connecting' | 'listening' | 'speaking' | 'looking' | 'ended' | 'error';
export type LiveEndReason = 'user' | 'silence' | 'cap' | 'hidden' | 'expired' | 'error';
export interface LiveSource { label: string; link: string }
export interface LiveTurnLogged { conversationId: string | null; messageId: number | null; unverified: boolean; noQuantity: boolean; wrongCurrency: string | null; script: boolean }
export interface LiveCallbacks {
  onState: (s: LiveState) => void;
  /** the user's words so far in this turn (input transcription, in the session language's script) */
  onUserText: (turn: number, text: string) => void;
  /** Sana's words so far in this turn (output transcription) */
  onSanaText: (turn: number, text: string) => void;
  onTool: (turn: number, name: string) => void;
  onSources: (turn: number, sources: LiveSource[]) => void;
  onTurnDone: (turn: number, r: { firstAudioMs: number | null }) => void;
  onLogged: (turn: number, r: LiveTurnLogged) => void;
  onEnd: (reason: LiveEndReason, message?: string) => void;
  onInfo?: (i: { model: string; tools: string[]; secondsLeft: number; company: string }) => void;
}
export const SILENCE_END_MS = 60_000;
export const HIDDEN_END_MS = 30_000;
const SETUP_TIMEOUT_MS = 10_000;
/** local e2e only (Vite dev build): shorter silence / hidden limits from localStorage, so the end rules can be tested quickly */
const devMs = (key: string, d: number) => { if (!import.meta.env.DEV) return d; try { return Number(localStorage.getItem(key)) || d; } catch { return d; } };
const SPEECH_RMS = 0.02;

/** AudioWorklet + WebSocket + getUserMedia: without them the panel keeps only the push-to-talk microphone. */
export function liveSupported(): boolean {
  try {
    return typeof window !== 'undefined' && 'WebSocket' in window && !!navigator.mediaDevices?.getUserMedia
      && typeof AudioWorkletNode !== 'undefined' && 'audioWorklet' in (window.AudioContext ?? Object).prototype;
  } catch { return false; }
}

async function callFn(name: string, body: unknown): Promise<Record<string, unknown>> {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, { method: 'POST', body: JSON.stringify(body),
    headers: { Authorization: `Bearer ${data.session?.access_token ?? ''}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json' } });
  const j = await res.json().catch(() => ({})) as Record<string, unknown>;
  if (!res.ok) throw Object.assign(new Error(String(j.error ?? `HTTP ${res.status}`)), { status: res.status });
  return j;
}
const b64 = (bytes: Uint8Array) => { let s = ''; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };
/** links in tool results (same rule as Ask's collectSources: internal paths only), at most 6 */
export function sourcesOf(result: unknown): LiveSource[] {
  const out: LiveSource[] = []; const seen = new Set<string>();
  const walk = (o: unknown, depth: number) => {
    if (!o || typeof o !== 'object' || depth > 4 || out.length >= 6) return;
    if (Array.isArray(o)) { o.forEach((x) => walk(x, depth + 1)); return; }
    const r = o as Record<string, unknown>;
    for (const key of ['link', 'list_link']) {
      const link = r[key];
      if (typeof link === 'string' && /^\/[A-Za-z0-9_\-/?=&.%]*$/.test(link) && !seen.has(link)) {
        seen.add(link);
        const label = key === 'list_link' ? 'Open list' : String(r.number ?? r.code ?? r.name ?? link.split('/').pop() ?? link).slice(0, 40);
        out.push({ label, link });
      }
    }
    for (const k of Object.keys(r)) if (typeof r[k] === 'object') walk(r[k], depth + 1);
  };
  walk(result, 0);
  return out;
}

export class SanaLiveSession {
  private ws?: WebSocket;
  private mic?: AudioContext;
  private stream?: MediaStream;
  private player = new PcmStreamPlayer();
  private sid = '';
  private conv: string | null = null;
  private turn = 0;
  private you = ''; private sana = ''; private tools: string[] = []; private currencies = new Set<string>(); private sources: LiveSource[] = [];
  private lastSpeech = 0; private lastActivity = 0; private speechEnd: number | null = null; private firstAudio: number | null = null;
  private timers: ReturnType<typeof setInterval>[] = [];
  private hiddenAt: number | null = null;
  private ended = false;
  private state: LiveState = 'idle';
  private onVis = () => this.visibility();

  constructor(private cb: LiveCallbacks, private opts: { company: string | null; language: string }) {}

  private set(s: LiveState) { if (this.state !== s) { this.state = s; this.cb.onState(s); } }

  async start() {
    this.set('connecting');
    primeAudio(); stopAllSpeech();
    // 1. microphone permission first, so the browser's prompt comes before anything connects
    try { await this.startMic(); } catch (e) {
      const name = (e as { name?: string }).name;
      return this.fail(name === 'NotAllowedError' ? 'mic-denied' : 'mic-failed');
    }
    let t: Record<string, unknown>;
    try {
      t = await callFn('sana-live-token', { company: this.opts.company, language: this.opts.language === 'auto' ? 'en' : this.opts.language });
    } catch (e) {
      const status = (e as { status?: number }).status;
      return this.fail(status === 429 ? 'cap' : 'token', (e as Error).message, status === 429 ? 'cap' : 'error');
    }
    this.sid = String(t.live_session_id);
    this.cb.onInfo?.({ model: String(t.model), tools: (t.tools as string[]) ?? [], secondsLeft: Number(t.seconds_left ?? 0), company: String(t.company ?? '') });
    const expiresAt = Date.parse(String(t.expires_at ?? '')) || Date.now() + 10 * 60_000;
    let ready = false;
    const ws = new WebSocket(`${String(t.ws)}?access_token=${encodeURIComponent(String(t.token))}`); this.ws = ws;
    const setupTimer = setTimeout(() => { if (!ready) this.fail('setup'); }, SETUP_TIMEOUT_MS);
    ws.onerror = () => { if (!ready) { clearTimeout(setupTimer); this.fail('socket'); } };
    ws.onclose = (e) => {
      clearTimeout(setupTimer);
      if (this.ended) return;
      if (!ready) { this.fail('socket', `${e.code}${e.reason ? ': ' + e.reason : ''}`); return; }
      this.end(Date.now() >= expiresAt - 2000 ? 'cap' : 'expired');   // the token ran out (minutes cap or 10 min) or Gemini closed
    };
    ws.onopen = () => ws.send(JSON.stringify({ setup: { model: `models/${String(t.model)}` } }));   // the token's locked setup applies
    ws.onmessage = async (ev) => {
      const m = JSON.parse(typeof ev.data === 'string' ? ev.data : await (ev.data as Blob).text());
      if (m.setupComplete) {
        ready = true; clearTimeout(setupTimer); this.lastActivity = Date.now(); this.set('listening');
        this.timers.push(setInterval(() => this.tick(expiresAt), 1000));
        document.addEventListener('visibilitychange', this.onVis);
        return;
      }
      if (m.toolCall) { await this.toolCall(m.toolCall.functionCalls ?? []); return; }
      const sc = m.serverContent; if (!sc) return;
      if (sc.interrupted) { this.player.stop(); this.set('listening'); }
      if (sc.inputTranscription?.text) { this.you += sc.inputTranscription.text; this.lastActivity = Date.now(); this.cb.onUserText(this.turn, this.you.trim()); }
      if (sc.outputTranscription?.text) { this.sana += sc.outputTranscription.text; this.cb.onSanaText(this.turn, this.sana.trim()); }
      for (const p of sc.modelTurn?.parts ?? []) if (p.inlineData?.data) {
        if (this.firstAudio == null) { const from = this.speechEnd ?? this.lastSpeech; this.firstAudio = from ? Math.round(performance.now() - from) : null; }
        this.player.push(unb64(p.inlineData.data), 24000);
        this.lastActivity = Date.now();
        this.set('speaking');
      }
      if (sc.turnComplete) this.finishTurn();
    };
  }

  private async toolCall(calls: Array<{ id: string; name: string; args?: Record<string, unknown> }>) {
    this.set('looking');
    this.speechEnd ??= this.lastSpeech || performance.now();
    const responses = [];
    for (const f of calls) {
      this.tools.push(f.name); this.cb.onTool(this.turn, f.name);
      let result: unknown;
      try { result = (await callFn('sana-live-tool', { action: 'tool', live_session_id: this.sid, tool: f.name, args: f.args ?? {} })).result; }
      catch (e) { result = { error: (e as Error).message }; }
      const text = JSON.stringify(result ?? {});
      for (const c of text.matchAll(/"currency":"([A-Z]{3})"/g)) this.currencies.add(c[1]);
      const src = sourcesOf(result); if (src.length) { this.sources = [...this.sources, ...src].slice(0, 6); this.cb.onSources(this.turn, this.sources); }
      responses.push({ id: f.id, name: f.name, response: (result ?? {}) as Record<string, unknown> });
    }
    this.lastActivity = Date.now();
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ toolResponse: { functionResponses: responses } }));
  }

  private finishTurn() {
    const turn = this.turn, you = this.you.trim(), sana = this.sana.trim(), tools = this.tools, ms = this.firstAudio, currencies = [...this.currencies];
    this.turn++; this.you = ''; this.sana = ''; this.tools = []; this.currencies = new Set(); this.sources = []; this.firstAudio = null; this.speechEnd = null;
    this.lastActivity = Date.now();
    this.cb.onTurnDone(turn, { firstAudioMs: ms });
    this.player.whenIdle(() => { if (!this.ended && this.state === 'speaking') this.set('listening'); });
    if (!you && !sana) return;
    void callFn('sana-live-tool', { action: 'log_turn', live_session_id: this.sid, conversation_id: this.conv, user_text: you, sana_text: sana, tools, currencies,
      timings: { ms_first_audio: ms, ms_total: ms }, device: window.matchMedia?.('(pointer: coarse)').matches ? 'phone' : 'desktop' })
      .then((j) => {
        this.conv = (j.conversation_id as string | undefined) ?? this.conv;
        this.cb.onLogged(turn, { conversationId: this.conv, messageId: (j.message_id as number | undefined) ?? null, unverified: Boolean(j.unverified),
          noQuantity: Boolean(j.no_quantity), wrongCurrency: (j.wrong_currency as string | null) ?? null, script: Boolean(j.script) });
      })
      .catch(() => { /* the turn stays on screen; the session row still records the minutes */ });
  }

  private async startMic() {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
    const ctx = new AudioContext({ sampleRate: 16000 });
    await ctx.audioWorklet.addModule('/sana-mic-worklet.js');   // same origin: passes script-src 'self'
    const node = new AudioWorkletNode(ctx, 'sana-mic'); ctx.createMediaStreamSource(stream).connect(node);
    let pending: Float32Array[] = []; let count = 0;
    node.port.onmessage = (ev) => {
      const f = ev.data as Float32Array; pending.push(f); count += f.length;
      let e = 0; for (let i = 0; i < f.length; i++) e += f[i] * f[i];
      if (Math.sqrt(e / f.length) > SPEECH_RMS) { this.lastSpeech = performance.now(); this.lastActivity = Date.now(); }
      if (count >= 1600) {   // 100 ms
        const all = new Int16Array(count); let o = 0;
        for (const p of pending) for (let i = 0; i < p.length; i++) all[o++] = Math.max(-1, Math.min(1, p[i])) * 0x7fff;
        pending = []; count = 0;
        if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ realtimeInput: { audio: { data: b64(new Uint8Array(all.buffer)), mimeType: 'audio/pcm;rate=16000' } } }));
      }
    };
    this.mic = ctx; this.stream = stream;
  }

  private tick(expiresAt: number) {
    if (this.ended) return;
    if (Date.now() >= expiresAt) return this.end('cap');
    if (this.state !== 'looking' && !this.player.playing && Date.now() - this.lastActivity > devMs('sana-live-test-silence-ms', SILENCE_END_MS)) return this.end('silence');
    if (this.hiddenAt != null && Date.now() - this.hiddenAt > devMs('sana-live-test-hidden-ms', HIDDEN_END_MS)) return this.end('hidden');
  }
  private visibility() { this.hiddenAt = document.visibilityState === 'hidden' ? (this.hiddenAt ?? Date.now()) : null; }

  private fail(code: string, detail?: string, reason: LiveEndReason = 'error') {
    if (this.ended) return;
    this.cleanup(reason);
    this.set('error');
    this.cb.onEnd(reason, detail ? `${code}|${detail}` : code);
  }
  /** End the session (button, silence, cap, hidden). Safe to call more than once. */
  end(reason: LiveEndReason = 'user') {
    if (this.ended) return;
    if (this.you.trim() || this.sana.trim()) this.finishTurn();
    this.cleanup(reason);
    this.set('ended');
    this.cb.onEnd(reason);
  }
  private cleanup(reason: LiveEndReason) {
    this.ended = true;
    this.timers.forEach(clearInterval); this.timers = [];
    document.removeEventListener('visibilitychange', this.onVis);
    this.player.stop();
    this.stream?.getTracks().forEach((t) => t.stop());
    void this.mic?.close().catch(() => {});
    try { this.ws?.close(); } catch { /* closed */ }
    if (this.sid) void callFn('sana-live-tool', { action: 'end', live_session_id: this.sid, reason }).catch(() => {});
  }
}

import { supabase, SUPABASE_URL } from '@/lib/supabase';
import i18n from '@/lib/i18n';
import { SentenceSplitter, split } from './sentences';
import { languageLabel, speechLocale, voiceFor } from './voice';

/**
 * S4 · step 2: read an answer aloud sentence by sentence while it is still streaming.
 *
 * Each finished piece (sentences.ts) is sent to sana-voice at once, in order, while the next is still being written; the audio
 * comes back as raw 16-bit PCM and is played with the Web Audio API, each buffer scheduled at the previous one's end time, so
 * pieces play back to back with no gap. Requests run in parallel; playback keeps the order.
 *
 * Engines: 'gemini' (sana-voice, the company's voice mode is "provider") or 'device' (speechSynthesis). On a phone that has a
 * system voice for the answer language, answers under 200 characters use the device voice (instant, no network) and longer ones
 * Gemini; the user can force Gemini in the panel. Companies on voice mode "browser" always use the device voice, as before.
 * Which engine spoke is reported through onEngine (the panel marks the bubble; Gemini calls are also counted in
 * erp.sana_voice_use). Nothing is stored: audio lives in memory until it has played.
 */
export type VoiceEngine = 'gemini' | 'device';
export interface SpeakerOpts {
  providerMode: boolean;          // company voice mode 'provider'
  forceGemini: boolean;           // panel setting
  company: string | null;
  language: string;               // the answer language ('auto' until meta/done tells us)
  uiLanguage: string;
  onStart?: () => void;
  onEnd?: () => void;
  onEngine?: (e: VoiceEngine) => void;
  onError?: (message: string) => void;
  /** ms from `t0` to the first sound (for the timing table) */
  onFirstAudio?: (ms: number) => void;
  t0?: number;
}
export const SHORT_ANSWER = 200;
const SENTINEL_LEAD = 0.03;   // seconds between "now" and the first buffer, so it is never scheduled in the past

let ctx: AudioContext | null = null;
let current: SentenceSpeaker | null = null;
const audioCtx = () => {
  if (!ctx) {
    const C = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    ctx = new C();
  }
  if (ctx.state === 'suspended') void ctx.resume();
  return ctx;
};
/** Call from a click/tap (send, microphone): browsers only allow sound after a gesture, and this unlocks it early. */
export function primeAudio() { try { audioCtx(); } catch { /* no Web Audio: device voice only */ } }
/** Stop whatever Sana is saying and drop the queue (new message, stop button, panel closed). */
export function stopAllSpeech() { current?.stop(); current = null; }

const isPhone = () => typeof window !== 'undefined' && window.matchMedia?.('(pointer: coarse)').matches === true;
const langOf = (text: string, asked: string) => {
  if (asked && asked !== 'auto') return asked;
  if (/[ഀ-ൿ]/.test(text)) return 'ml';
  if (/[؀-ۿ]/.test(text)) return 'ar';
  if (/[ऀ-ॿ]/.test(text)) return 'hi';
  return 'en';
};

function pcmToBuffer(c: AudioContext, bytes: ArrayBuffer, rate: number): AudioBuffer {
  const n = Math.floor(bytes.byteLength / 2);
  const view = new DataView(bytes);
  const buf = c.createBuffer(1, Math.max(1, n), rate);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < n; i++) ch[i] = view.getInt16(i * 2, true) / 0x8000;
  return buf;
}

export class SentenceSpeaker {
  private split = new SentenceSplitter();
  private o: SpeakerOpts;
  private engine: VoiceEngine | null = null;
  private held: string[] = [];          // pieces waiting for the engine decision (phone, short answers)
  private heldChars = 0;
  private stopped = false;
  private ac = new AbortController();
  private chain: Promise<void> = Promise.resolve();
  private nextAt = 0;
  private sources = new Set<AudioBufferSourceNode>();
  private pending = 0;                  // pieces queued but not finished playing
  private finished = false;
  private started = false;
  private lang: string;
  private gen = 0;                      // bumped by reset(): late callbacks from the old queue are ignored

  constructor(o: SpeakerOpts) {
    stopAllSpeech();
    current = this;
    this.o = o;
    this.lang = o.language;
  }
  setLanguage(l: string | undefined) { if (l && l !== 'auto') this.lang = l; }

  /** The whole streamed text so far. */
  push(full: string) { if (!this.stopped) this.queue(this.split.push(full)); }

  /** The final reply (after 'done'). Says what is left; a replaced reply (refusal) restarts with the final text. */
  finish(final: string, language?: string) {
    if (this.stopped) return;
    this.setLanguage(language);
    const r = this.split.finish(final);
    if (r.restart) { this.reset(); }
    this.finished = true;
    this.queue(r.pieces);
    if (!this.engine) this.decide(true);
    this.maybeEnd();
  }

  /** Read a whole stored answer (the Listen button). */
  speakAll(text: string, language?: string) { this.setLanguage(language); this.finished = true; this.queue(split(text)); if (!this.engine) this.decide(true); this.maybeEnd(); }

  stop() {
    if (this.stopped) return;
    this.stopped = true;
    this.ac.abort();
    for (const s of this.sources) { try { s.stop(); } catch { /* already ended */ } }
    this.sources.clear();
    if (this.engine === 'device' && 'speechSynthesis' in window) window.speechSynthesis.cancel();
    if (current === this) current = null;
    this.o.onEnd?.();
  }

  private reset() {
    for (const s of this.sources) { try { s.stop(); } catch { /* ended */ } }
    this.sources.clear();
    if (this.engine === 'device' && 'speechSynthesis' in window) window.speechSynthesis.cancel();
    this.ac.abort(); this.ac = new AbortController();
    this.gen++; this.chain = Promise.resolve(); this.nextAt = 0; this.pending = 0; this.held = []; this.heldChars = 0;
  }

  private locale() { return speechLocale(this.lang, this.o.uiLanguage); }

  /** Pick the engine. Before the answer is complete, a phone with a device voice waits until it knows the answer is short. */
  private decide(final: boolean) {
    const deviceVoice = voiceFor(this.locale());
    if (!this.o.providerMode) this.engine = 'device';
    else if (this.o.forceGemini || !isPhone() || !deviceVoice) this.engine = 'gemini';
    else if (this.heldChars >= SHORT_ANSWER) this.engine = 'gemini';
    else if (final) this.engine = 'device';
    else return;
    this.o.onEngine?.(this.engine);
    const held = this.held; this.held = []; this.heldChars = 0;
    held.forEach((p) => this.play(p));
  }

  private queue(pieces: string[]) {
    for (const p of pieces) {
      if (this.stopped) return;
      if (!this.engine) {
        this.lang = langOf(p, this.lang);
        this.held.push(p); this.heldChars += p.length;
        this.decide(false);
      } else this.play(p);
    }
  }

  private began() {
    if (this.started) return;
    this.started = true;
    this.o.onStart?.();
    if (this.o.t0 != null) this.o.onFirstAudio?.(performance.now() - this.o.t0);
  }
  private maybeEnd() { if (this.finished && this.pending === 0 && !this.stopped) { if (current === this) current = null; this.stopped = true; this.o.onEnd?.(); } }
  private pieceDone(gen: number) { if (gen !== this.gen) return; this.pending--; this.maybeEnd(); }

  private play(piece: string) {
    this.pending++;
    const gen = this.gen;
    if (this.engine === 'device') return this.playDevice(piece);
    // Gemini: the request starts now; playback waits for the pieces before it (chain)
    const audio = this.fetchPiece(piece);
    this.chain = this.chain.then(async () => {
      let buf: AudioBuffer;
      try { buf = await audio; } catch (e) {
        if (this.stopped || gen !== this.gen || (e as Error).name === 'AbortError') return;
        // provider failed for this piece: the device voice says the rest when it can, else the panel shows why
        if (voiceFor(this.locale())) { this.engine = 'device'; this.o.onEngine?.('device'); this.playDevice(piece); return; }
        this.o.onError?.((e as Error).message); this.stop(); return;
      }
      if (this.stopped || gen !== this.gen) return;
      const c = audioCtx();
      const src = c.createBufferSource();
      src.buffer = buf; src.connect(c.destination);
      const at = Math.max(c.currentTime + SENTINEL_LEAD, this.nextAt);
      src.start(at);
      this.nextAt = at + buf.duration;
      this.sources.add(src);
      if (!this.started) setTimeout(() => this.began(), Math.max(0, (at - c.currentTime) * 1000));
      src.onended = () => { this.sources.delete(src); this.pieceDone(gen); };
    });
  }

  private async fetchPiece(text: string): Promise<AudioBuffer> {
    const { data } = await supabase.auth.getSession();
    const token = data.session?.access_token;
    if (!token) throw new Error(i18n.t('sana.err.signin'));
    const res = await fetch(`${SUPABASE_URL}/functions/v1/sana-voice`, {
      method: 'POST', signal: this.ac.signal,
      headers: { Authorization: `Bearer ${token}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'tts', text, language: this.lang || 'auto', company: this.o.company, format: 'pcm16' }),
    });
    if (!res.ok) {
      const j = await res.json().catch(() => ({})) as { error?: string };
      throw new Error(j.error || i18n.t('sana.err.generic'));
    }
    const bytes = await res.arrayBuffer();
    const c = audioCtx();
    // an older sana-voice answers WAV whatever was asked: decode it the usual way
    if (res.headers.get('x-sana-format') !== 'pcm16') return c.decodeAudioData(bytes);
    return pcmToBuffer(c, bytes, Number(res.headers.get('x-sana-rate')) || 24000);
  }

  private playDevice(piece: string) {
    const gen = this.gen;
    const voice = voiceFor(this.locale());
    if (!voice || !('speechSynthesis' in window)) {
      this.pending--;
      this.o.onError?.('speechSynthesis' in window ? i18n.t('sana.noVoice', { language: languageLabel(this.lang) }) : i18n.t('sana.noSpeech'));
      this.stop(); return;
    }
    const u = new SpeechSynthesisUtterance(piece);
    u.lang = voice.lang || this.locale(); u.voice = voice; u.rate = 1;
    u.onstart = () => this.began();
    u.onend = () => this.pieceDone(gen);
    u.onerror = () => this.pieceDone(gen);
    window.speechSynthesis.speak(u);   // the system queues utterances: no gap, no cancel between pieces
  }
}

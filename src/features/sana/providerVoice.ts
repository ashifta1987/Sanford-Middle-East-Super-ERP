import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase, SUPABASE_URL } from '@/lib/supabase';
import i18n from '@/lib/i18n';
import type { MicError } from './voice';

/**
 * S2 · provider voice (the company's voice mode is "provider"): the microphone is recorded in the browser (MediaRecorder),
 * converted to 16 kHz mono WAV and sent once to the sana-voice Edge Function, which has Gemini transcribe it; answers are
 * read aloud from the WAV that Gemini's TTS model returns. Audio is never stored — not here, not on the server.
 */
export class VoiceError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}

async function callVoice(body: Record<string, unknown>): Promise<Response> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new VoiceError(i18n.t('sana.err.signin'), 401);
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/sana-voice`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new VoiceError(i18n.t('sana.err.network'), 0);
  }
  if (!res.ok) {
    const j = await res.json().catch(() => ({})) as { error?: string };
    throw new VoiceError(j.error || i18n.t('sana.err.generic'), res.status);
  }
  return res;
}

const toBase64 = (bytes: Uint8Array) => {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};
function wav16(samples: Float32Array, rate: number): Uint8Array {
  const out = new Uint8Array(44 + samples.length * 2);
  const v = new DataView(out.buffer);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) out[o + i] = s.charCodeAt(i); };
  str(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE'); str(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true); v.setUint16(34, 16, true); str(36, 'data'); v.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, samples[i])) * 0x7fff, true);
  return out;
}
/** Recording → 16 kHz mono WAV (a format every provider accepts, ~32 kB a second). Falls back to the recording as it is. */
async function toWav(blob: Blob, seconds: number): Promise<{ audio: string; mime: string; seconds: number }> {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    const ctx = new Ctx();
    const decoded = await ctx.decodeAudioData(await blob.arrayBuffer());
    void ctx.close();
    const rate = 16000;
    const off = new OfflineAudioContext(1, Math.max(1, Math.ceil(decoded.duration * rate)), rate);
    const src = off.createBufferSource();
    src.buffer = decoded; src.connect(off.destination); src.start();
    const rendered = await off.startRendering();
    return { audio: toBase64(wav16(rendered.getChannelData(0), rate)), mime: 'audio/wav', seconds: decoded.duration };
  } catch {
    return { audio: toBase64(new Uint8Array(await blob.arrayBuffer())), mime: (blob.type || 'audio/webm').split(';')[0], seconds };
  }
}

const MAX_SECONDS = 30;

/** Push-to-talk through the provider. Same shape as useSpeechInput, plus `transcribing` and the server's message. */
export function useProviderSpeechInput(onFinal: (text: string, language: string) => void, opts: () => { language: string; company: string | null }) {
  const supported = typeof window !== 'undefined' && Boolean(navigator.mediaDevices?.getUserMedia) && typeof MediaRecorder !== 'undefined';
  const [listening, setListening] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const [error, setError] = useState<MicError | null>(null);
  const [errorText, setErrorText] = useState<string | null>(null);
  const rec = useRef<MediaRecorder | null>(null);
  const discard = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const cb = useRef({ onFinal, opts });
  cb.current = { onFinal, opts };

  const stop = useCallback(() => { if (rec.current?.state === 'recording') rec.current.stop(); }, []);
  const start = useCallback(async (_locale?: string) => {
    if (!supported) { setError('unsupported'); return; }
    setError(null); setErrorText(null);
    let stream: MediaStream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch (e) {
      setError((e as { name?: string }).name === 'NotAllowedError' ? 'not-allowed' : 'other'); return;
    }
    const chunks: Blob[] = [];
    const r = new MediaRecorder(stream);
    const began = Date.now();
    r.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
    r.onstop = async () => {
      stream.getTracks().forEach((t) => t.stop());
      if (discard.current) { discard.current = false; rec.current = null; setListening(false); return; }   // unmounted: nothing is sent
      if (timer.current) clearTimeout(timer.current);
      setListening(false);
      rec.current = null;
      const blob = new Blob(chunks, { type: r.mimeType || 'audio/webm' });
      if (!blob.size) { setError('no-speech'); return; }
      setTranscribing(true);
      try {
        const o = cb.current.opts();
        const wav = await toWav(blob, (Date.now() - began) / 1000);
        const res = await callVoice({ mode: 'stt', ...wav, language: o.language, company: o.company });
        const j = await res.json() as { text: string; language: string };
        if (j.text) cb.current.onFinal(j.text, j.language); else setError('no-speech');
      } catch (e) {
        const err = e as VoiceError;
        if (err.status === 422) setError('no-speech');
        else { setError('other'); setErrorText(err.message); }
      } finally { setTranscribing(false); }
    };
    rec.current = r;
    r.start();
    setListening(true);
    timer.current = setTimeout(() => stop(), MAX_SECONDS * 1000);
  }, [supported, stop]);

  useEffect(() => () => { if (rec.current?.state === 'recording') { discard.current = true; rec.current.stop(); } }, []);
  return { supported, listening, transcribing, interim: '', error, errorText, start, stop, clearError: () => { setError(null); setErrorText(null); } };
}

let current: HTMLAudioElement | null = null;
/** Reads an answer aloud with the provider's TTS (WAV from sana-voice). Resolves when playback starts. */
export async function speakProvider(text: string, language: string | undefined, company: string | null, onEnd?: () => void): Promise<void> {
  stopProviderAudio();
  const res = await callVoice({ mode: 'tts', text, language: language ?? 'auto', company });
  const url = URL.createObjectURL(await res.blob());
  const a = new Audio(url);
  const done = () => { URL.revokeObjectURL(url); if (current === a) current = null; onEnd?.(); };
  a.onended = done; a.onerror = done;
  current = a;
  await a.play();
}
export const stopProviderAudio = () => { const a = current; if (a) { a.pause(); a.dispatchEvent(new Event('ended')); current = null; } };

import { useCallback, useEffect, useRef, useState } from 'react';

/** Languages Sana understands by voice and text. English and Malayalam come first: Sanford's priority languages (11 Nov 2026). `speech` is the browser speech-recognition / speech-synthesis locale. */
export const SANA_LANGUAGES: Array<{ code: string; label: string; speech: string; dir: 'ltr' | 'rtl' }> = [
  { code: 'auto', label: 'Auto', speech: '', dir: 'ltr' },
  { code: 'en', label: 'English', speech: 'en-US', dir: 'ltr' },
  { code: 'ml', label: 'മലയാളം', speech: 'ml-IN', dir: 'ltr' },
  { code: 'ar', label: 'العربية', speech: 'ar-AE', dir: 'rtl' },
  { code: 'hi', label: 'हिन्दी', speech: 'hi-IN', dir: 'ltr' },
  { code: 'ur', label: 'اردو', speech: 'ur-PK', dir: 'rtl' },
  { code: 'ta', label: 'தமிழ்', speech: 'ta-IN', dir: 'ltr' },
  { code: 'bn', label: 'বাংলা', speech: 'bn-IN', dir: 'ltr' },
  { code: 'tl', label: 'Filipino', speech: 'fil-PH', dir: 'ltr' },
  { code: 'zh', label: '中文', speech: 'zh-CN', dir: 'ltr' },
  { code: 'fr', label: 'Français', speech: 'fr-FR', dir: 'ltr' },
  { code: 'ru', label: 'Русский', speech: 'ru-RU', dir: 'ltr' },
];
export const speechLocale = (code: string, uiLang: string) =>
  SANA_LANGUAGES.find((l) => l.code === code)?.speech || (uiLang === 'ar' ? 'ar-AE' : 'en-US');

// Minimal typing for the Web Speech API (not in TypeScript's DOM lib everywhere).
interface RecognitionResult { isFinal: boolean; 0: { transcript: string } }
interface RecognitionEvent { resultIndex: number; results: ArrayLike<RecognitionResult> }
interface Recognition {
  lang: string; interimResults: boolean; continuous: boolean; maxAlternatives: number;
  start(): void; stop(): void; abort(): void;
  onresult: ((e: RecognitionEvent) => void) | null;
  onerror: ((e: { error: string }) => void) | null;
  onend: (() => void) | null;
}
type RecognitionCtor = new () => Recognition;
const getCtor = (): RecognitionCtor | undefined =>
  typeof window === 'undefined' ? undefined : ((window as unknown as { SpeechRecognition?: RecognitionCtor; webkitSpeechRecognition?: RecognitionCtor }).SpeechRecognition
    ?? (window as unknown as { webkitSpeechRecognition?: RecognitionCtor }).webkitSpeechRecognition);

export type MicError = 'not-allowed' | 'no-speech' | 'network' | 'unsupported' | 'other';

/** Push-to-talk speech recognition. The browser does the listening (Chrome/Edge/Safari); audio is not stored by Southfield. */
export function useSpeechInput(onFinal: (text: string) => void) {
  const ctor = getCtor();
  const rec = useRef<Recognition | null>(null);
  const [listening, setListening] = useState(false);
  const [interim, setInterim] = useState('');
  const [error, setError] = useState<MicError | null>(null);
  const finalRef = useRef('');
  const onFinalRef = useRef(onFinal);
  onFinalRef.current = onFinal;

  const stop = useCallback(() => { rec.current?.stop(); }, []);
  const start = useCallback((locale: string) => {
    if (!ctor) { setError('unsupported'); return; }
    rec.current?.abort();
    const r = new ctor();
    r.lang = locale; r.interimResults = true; r.continuous = false; r.maxAlternatives = 1;
    finalRef.current = '';
    r.onresult = (e) => {
      let text = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const res = e.results[i];
        if (res.isFinal) finalRef.current += res[0].transcript; else text += res[0].transcript;
      }
      setInterim(finalRef.current + text);
    };
    r.onerror = (e) => setError(e.error === 'not-allowed' || e.error === 'service-not-allowed' ? 'not-allowed' : e.error === 'no-speech' ? 'no-speech' : e.error === 'network' ? 'network' : 'other');
    r.onend = () => {
      setListening(false);
      const said = finalRef.current.trim();
      setInterim('');
      if (said) onFinalRef.current(said);
    };
    setError(null);
    setListening(true);
    try { r.start(); rec.current = r; } catch { setListening(false); setError('other'); }
  }, [ctor]);

  useEffect(() => () => rec.current?.abort(), []);
  return { supported: Boolean(ctor), listening, interim, error, start, stop, clearError: () => setError(null) };
}

/** The system voice for a locale (exact, then same language). Null = this device cannot speak the language. */
export function voiceFor(locale: string): SpeechSynthesisVoice | null {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return null;
  const voices = window.speechSynthesis.getVoices();
  const base = locale.split('-')[0].toLowerCase();
  const alt = base === 'tl' ? 'fil' : base === 'fil' ? 'tl' : base;
  return voices.find((v) => v.lang.toLowerCase() === locale.toLowerCase())
    ?? voices.find((v) => { const b = v.lang.toLowerCase().split(/[-_]/)[0]; return b === base || b === alt; }) ?? null;
}
/** Voices load asynchronously in most browsers; this re-renders once they are there. */
export function useVoicesReady() {
  const [n, setN] = useState(() => (typeof window !== 'undefined' && 'speechSynthesis' in window ? window.speechSynthesis.getVoices().length : 0));
  useEffect(() => {
    if (typeof window === 'undefined' || !('speechSynthesis' in window)) return;
    const on = () => setN(window.speechSynthesis.getVoices().length);
    window.speechSynthesis.addEventListener?.('voiceschanged', on);
    return () => window.speechSynthesis.removeEventListener?.('voiceschanged', on);
  }, []);
  return n;
}

export type SpeakResult = 'ok' | 'no-voice' | 'unsupported';
/**
 * Read an answer aloud with the system voice for the answer's language. When the device has no voice for it (common for
 * Malayalam and Urdu) nothing is spoken — never the wrong accent — and 'no-voice' is returned so the panel can say so.
 */
export function speak(text: string, locale: string, onEnd?: () => void): SpeakResult {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return 'unsupported';
  const voice = voiceFor(locale);
  if (!voice) return 'no-voice';
  window.speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text.replace(/[*_#`>|]/g, ''));
  u.lang = voice.lang || locale;
  u.voice = voice;
  u.rate = 1;
  if (onEnd) { u.onend = onEnd; u.onerror = onEnd; }
  window.speechSynthesis.speak(u);
  return 'ok';
}
export const stopSpeaking = () => { if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.cancel(); };
/** Language label for a speech locale or Sana code (for "No voice for ‹language› on this device"). */
export const languageLabel = (codeOrLocale: string) => {
  const c = codeOrLocale.split('-')[0];
  return SANA_LANGUAGES.find((l) => l.code === c || l.speech === codeOrLocale || l.speech.split('-')[0] === c)?.label ?? codeOrLocale;
};

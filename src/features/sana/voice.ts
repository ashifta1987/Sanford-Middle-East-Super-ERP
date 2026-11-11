import { useCallback, useEffect, useRef, useState } from 'react';

/** Languages Sana understands by voice and text. `speech` is the browser speech-recognition / speech-synthesis locale. */
export const SANA_LANGUAGES: Array<{ code: string; label: string; speech: string; dir: 'ltr' | 'rtl' }> = [
  { code: 'auto', label: 'Auto', speech: '', dir: 'ltr' },
  { code: 'en', label: 'English', speech: 'en-US', dir: 'ltr' },
  { code: 'ar', label: 'العربية', speech: 'ar-AE', dir: 'rtl' },
  { code: 'hi', label: 'हिन्दी', speech: 'hi-IN', dir: 'ltr' },
  { code: 'ur', label: 'اردو', speech: 'ur-PK', dir: 'rtl' },
  { code: 'ml', label: 'മലയാളം', speech: 'ml-IN', dir: 'ltr' },
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

/** Read an answer aloud with the best matching system voice. Returns false when the browser cannot speak. */
export function speak(text: string, locale: string, onEnd?: () => void): boolean {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return false;
  window.speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text.replace(/[*_#`>|]/g, ''));
  u.lang = locale;
  const voices = window.speechSynthesis.getVoices();
  const base = locale.split('-')[0];
  u.voice = voices.find((v) => v.lang === locale) ?? voices.find((v) => v.lang.startsWith(base)) ?? null;
  u.rate = 1;
  if (onEnd) { u.onend = onEnd; u.onerror = onEnd; }
  window.speechSynthesis.speak(u);
  return true;
}
export const stopSpeaking = () => { if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.cancel(); };

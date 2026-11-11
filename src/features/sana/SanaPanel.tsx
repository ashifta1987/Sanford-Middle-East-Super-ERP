import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ArrowUp, Lock, Mic, MicOff, Plus, ShieldCheck, Square, Volume2, VolumeX, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { SanaMark } from './SanaMark';
import { sanaSuggestions, useSana, type SanaMessage } from './SanaProvider';
import { SANA_LANGUAGES, speak, speechLocale, stopSpeaking, useSpeechInput } from './voice';

function Bubble({ m, onSpeak, speaking }: { m: SanaMessage; onSpeak: (m: SanaMessage) => void; speaking: boolean }) {
  const { t } = useTranslation();
  const { setOpen } = useSana();
  if (m.role === 'user') {
    return (
      <div className="flex justify-end">
        <p dir="auto" className="max-w-[85%] whitespace-pre-wrap rounded-[18px] rounded-ee-md bg-primary px-4 py-2.5 text-[15px] text-white">
          {m.via === 'voice' && <Mic className="me-1.5 inline h-3.5 w-3.5 opacity-80" aria-label={t('sana.byVoice')} />}{m.text}
        </p>
      </div>
    );
  }
  return (
    <div className="flex items-start gap-2.5">
      <SanaMark className="mt-1 h-7 w-7" />
      <div className="min-w-0 max-w-[88%]">
        <div dir="auto" className={clsx('whitespace-pre-wrap rounded-[18px] rounded-ss-md border px-4 py-2.5 text-[15px] leading-relaxed',
          m.error ? 'border-crit-fg/30 bg-crit-bg text-crit-fg' : m.denied ? 'border-line bg-neutral-bg text-ink' : 'border-line bg-surface text-ink')} role={m.error ? 'alert' : undefined}>
          {m.denied && <Lock className="me-1.5 inline h-3.5 w-3.5 text-muted" aria-label={t('sana.deniedLabel')} />}
          {m.text}
        </div>
        {!!m.sources?.length && (
          <div className="mt-2 flex flex-wrap gap-1.5" aria-label={t('sana.sources')}>
            {m.sources.map((s) => (
              <Link key={s.link} to={s.link} onClick={() => { if (window.innerWidth < 640) setOpen(false); }}
                className="inline-flex min-h-[32px] items-center rounded-full border border-primary-line bg-primary-soft px-3 text-[13px] font-medium text-primary-text hover:border-primary">
                {s.label === 'Open list' ? t('sana.openList') : s.label}
              </Link>
            ))}
          </div>
        )}
        {!m.error && (
          <button type="button" onClick={() => onSpeak(m)} className="mt-1 inline-flex min-h-[32px] items-center gap-1 rounded-btn px-1.5 text-[12px] text-muted hover:text-ink">
            {speaking ? <Square className="h-3.5 w-3.5" aria-hidden /> : <Volume2 className="h-3.5 w-3.5" aria-hidden />} {speaking ? t('sana.stop') : t('sana.listen')}
          </button>
        )}
      </div>
    </div>
  );
}

/** The Sana assistant: a side panel on desktop, a full-screen sheet on phones. Text and voice, many languages. */
export function SanaPanel() {
  const { t, i18n } = useTranslation();
  const { profile } = useAuth();
  const s = useSana();
  const [text, setText] = useState('');
  const [speakingId, setSpeakingId] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const locale = speechLocale(s.language, i18n.language);
  const mic = useSpeechInput((said) => { void send(said, 'voice'); });
  const first = profile?.user?.display_name?.split(/\s+/)[0] ?? '';

  async function send(q: string, via: 'text' | 'voice' = 'text') {
    if (!q.trim()) return;
    setText('');
    const reply = await s.ask(q, via);
    if (reply && !reply.error && s.autoSpeak && via === 'voice') playSpeech(reply);
  }
  function playSpeech(m: SanaMessage) {
    if (speakingId === m.id) { stopSpeaking(); setSpeakingId(null); return; }
    const loc = m.language ? speechLocale(m.language, i18n.language) : locale;
    if (speak(m.text, loc, () => setSpeakingId(null))) setSpeakingId(m.id);
  }
  function onSubmit(e: FormEvent) { e.preventDefault(); void send(text); }

  useEffect(() => { listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' }); }, [s.messages.length, s.busy]);
  useEffect(() => { if (s.open) setTimeout(() => inputRef.current?.focus(), 50); else { stopSpeaking(); mic.stop(); } }, [s.open]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!s.open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') s.setOpen(false); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [s.open, s]);

  if (!s.open) return null;
  const suggestions = sanaSuggestions(profile?.modules ?? []);
  const micMsg = mic.error === 'not-allowed' ? t('sana.mic.denied') : mic.error === 'unsupported' ? t('sana.mic.unsupported')
    : mic.error === 'no-speech' ? t('sana.mic.noSpeech') : mic.error ? t('sana.mic.failed') : null;

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/30 sm:bg-black/20" onClick={() => s.setOpen(false)} aria-hidden />
      <aside role="dialog" aria-modal="true" aria-labelledby="sana-title"
        className="fixed inset-0 z-50 flex flex-col bg-page shadow-2xl sm:inset-y-0 sm:end-0 sm:start-auto sm:w-[440px] sm:border-s sm:border-line">
        {/* Header */}
        <header className="flex items-center gap-3 bg-brand-navy px-4 py-3 text-white">
          <SanaMark className="h-9 w-9" />
          <div className="min-w-0 flex-1">
            <h2 id="sana-title" className="font-display text-[19px] font-bold leading-none tracking-[0.02em]">SANA</h2>
            <p className="mt-1 truncate text-[12px] text-white/70">{t('sana.fullName')}</p>
          </div>
          <label className="sr-only" htmlFor="sana-lang">{t('sana.language')}</label>
          <select id="sana-lang" value={s.language} onChange={(e) => s.setLanguage(e.target.value)}
            className="min-h-[36px] max-w-[110px] rounded-btn border border-white/20 bg-white/10 px-2 text-[13px] text-white [&>option]:text-ink">
            {SANA_LANGUAGES.map((l) => <option key={l.code} value={l.code}>{l.code === 'auto' ? t('sana.autoLang') : l.label}</option>)}
          </select>
          <button type="button" onClick={() => s.setAutoSpeak(!s.autoSpeak)} aria-pressed={s.autoSpeak}
            className="grid h-9 w-9 place-items-center rounded-btn hover:bg-white/10" title={s.autoSpeak ? t('sana.autoSpeakOn') : t('sana.autoSpeakOff')} aria-label={t('sana.autoSpeak')}>
            {s.autoSpeak ? <Volume2 className="h-5 w-5" aria-hidden /> : <VolumeX className="h-5 w-5" aria-hidden />}
          </button>
          <button type="button" onClick={() => { stopSpeaking(); s.newChat(); }} className="grid h-9 w-9 place-items-center rounded-btn hover:bg-white/10" title={t('sana.newChat')} aria-label={t('sana.newChat')}>
            <Plus className="h-5 w-5" aria-hidden />
          </button>
          <button type="button" onClick={() => s.setOpen(false)} className="grid h-9 w-9 place-items-center rounded-btn hover:bg-white/10" aria-label={t('sana.close')}>
            <X className="h-5 w-5" aria-hidden />
          </button>
        </header>

        {/* Messages */}
        <div ref={listRef} className="flex-1 space-y-4 overflow-y-auto px-4 py-5" aria-live="polite">
          {s.messages.length === 0 && (
            <div className="pt-4 text-center">
              <SanaMark className="mx-auto h-16 w-16" />
              <p className="mt-4 font-display text-[22px] font-semibold text-ink">{first ? t('sana.hello', { name: first }) : t('sana.helloNoName')}</p>
              <p className="mx-auto mt-1 max-w-[320px] text-[14px] text-muted">{t('sana.intro')}</p>
              <div className="mt-6 flex flex-col gap-2">
                {suggestions.map((k) => (
                  <button key={k} type="button" onClick={() => void send(t(k))}
                    className="min-h-[44px] rounded-[14px] border border-line bg-surface px-4 text-start text-[14px] text-ink hover:border-primary-line hover:bg-primary-soft">
                    {t(k)}
                  </button>
                ))}
              </div>
            </div>
          )}
          {s.messages.map((m) => <Bubble key={m.id} m={m} speaking={speakingId === m.id} onSpeak={playSpeech} />)}
          {s.busy && (
            <div className="flex items-center gap-2.5" aria-label={t('sana.thinking')}>
              <SanaMark className="h-7 w-7" />
              <span className="inline-flex gap-1 rounded-full border border-line bg-surface px-4 py-3">
                {[0, 1, 2].map((i) => <span key={i} className="h-2 w-2 animate-bounce rounded-full bg-primary" style={{ animationDelay: `${i * 120}ms` }} />)}
              </span>
            </div>
          )}
          {s.mode === 'basic' && s.messages.length > 0 && (
            <p className="rounded-btn border border-warn-fg/30 bg-warn-bg px-3 py-2 text-[12px] text-warn-fg">{t('sana.basicMode')}</p>
          )}
        </div>

        {/* Composer */}
        <form onSubmit={onSubmit} className="border-t border-line bg-surface px-3 pb-3 pt-2">
          {(mic.listening || mic.interim) && (
            <p dir="auto" className="mb-2 flex items-center gap-2 rounded-btn bg-primary-soft px-3 py-2 text-[14px] text-primary-text" aria-live="assertive">
              <span className="relative flex h-2.5 w-2.5"><span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand-coral opacity-75" /><span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-brand-coral" /></span>
              {mic.interim || t('sana.listening')}
            </p>
          )}
          {micMsg && <p role="alert" className="mb-2 text-[13px] text-crit-fg">{micMsg}</p>}
          <div className="flex items-end gap-2">
            <label htmlFor="sana-input" className="sr-only">{t('sana.placeholder')}</label>
            <textarea id="sana-input" ref={inputRef} rows={1} dir="auto" value={text} maxLength={2000}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(text); } }}
              placeholder={t('sana.placeholder')}
              className="max-h-32 min-h-[48px] flex-1 resize-none rounded-[14px] border border-line-strong bg-page px-4 py-3 text-[15px] text-ink outline-none placeholder:text-muted focus:border-primary" />
            <button type="button" onClick={() => (mic.listening ? mic.stop() : (stopSpeaking(), mic.start(locale)))} disabled={s.busy}
              aria-pressed={mic.listening} aria-label={mic.listening ? t('sana.stopListening') : t('sana.speak')} title={mic.supported ? (mic.listening ? t('sana.stopListening') : t('sana.speak')) : t('sana.mic.unsupported')}
              className={clsx('grid h-12 w-12 shrink-0 place-items-center rounded-full border transition',
                mic.listening ? 'border-brand-coral bg-brand-coral text-white' : 'border-line-strong bg-surface text-ink hover:border-primary hover:text-primary', !mic.supported && 'opacity-50')}>
              {mic.supported ? <Mic className="h-5 w-5" aria-hidden /> : <MicOff className="h-5 w-5" aria-hidden />}
            </button>
            <button type="submit" disabled={s.busy || !text.trim()} aria-label={t('sana.send')}
              className="grid h-12 w-12 shrink-0 place-items-center rounded-full bg-primary text-white transition hover:bg-primary-hover disabled:bg-neutral-bg disabled:text-muted">
              <ArrowUp className="h-5 w-5" aria-hidden />
            </button>
          </div>
          <p className="mt-2 flex items-start gap-1.5 text-[11.5px] leading-snug text-muted">
            <ShieldCheck className="mt-px h-3.5 w-3.5 shrink-0 text-brand-teal" aria-hidden />
            {t('sana.privacy')}
          </p>
        </form>
      </aside>
    </>
  );
}

/** Floating Sana button on phones (the top bar has the button on larger screens). */
export function SanaFab() {
  const { t } = useTranslation();
  const s = useSana();
  if (s.open) return null;
  return (
    <button type="button" onClick={() => s.setOpen(true)} aria-label={t('sana.ask')}
      className="fixed bottom-5 end-5 z-30 grid h-14 w-14 place-items-center rounded-full bg-surface shadow-[0_6px_24px_rgba(1,39,70,0.25)] ring-1 ring-line sm:hidden">
      <SanaMark className="h-9 w-9" />
    </button>
  );
}

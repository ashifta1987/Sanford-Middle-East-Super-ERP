import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, ArrowUp, History, Lock, MessageSquare, Mic, MicOff, Plus, ShieldCheck, Square, ThumbsDown, ThumbsUp, Trash2, Volume2, VolumeX, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { errorMessage } from '@/lib/format';
import { SanaMark } from './SanaMark';
import { sanaContextSuggestions, sanaSuggestions, useSana, useSanaHistory, type SanaContext, type SanaMessage } from './SanaProvider';
import { SANA_LANGUAGES, languageLabel, speak, speechLocale, stopSpeaking, useSpeechInput, useVoicesReady } from './voice';

const fmtWhen = (iso: string, lang: string) => new Date(iso).toLocaleString(lang === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', numberingSystem: 'latn' });

export function contextLabel(c: SanaContext, t: TFunction) {
  if (c.label) return c.label;
  if (c.type === 'document') return `${c.kind ? t(`erp.doc.${c.kind}`) : t('sana.ctx.document')} ${c.number ?? ''}`.trim();
  return `${c.code ?? ''}`;
}

function Bubble({ m, onSpeak, speaking, voiceNote }: { m: SanaMessage; onSpeak: (m: SanaMessage) => void; speaking: boolean; voiceNote: string | null }) {
  const { t } = useTranslation();
  const s = useSana();
  const [fbErr, setFbErr] = useState<string | null>(null);
  if (m.role === 'user') {
    return (
      <div className="flex justify-end" data-testid="sana-user-msg">
        <p dir="auto" className="max-w-[85%] whitespace-pre-wrap rounded-[18px] rounded-ee-md bg-primary px-4 py-2.5 text-[15px] text-white">
          {m.via === 'voice' && <Mic className="me-1.5 inline h-3.5 w-3.5 opacity-80" aria-label={t('sana.byVoice')} />}{m.text}
        </p>
      </div>
    );
  }
  const vote = async (v: 1 | -1) => { setFbErr(null); try { await s.feedback(m, v); } catch (e) { setFbErr(errorMessage(e)); } };
  return (
    <div className="flex items-start gap-2.5" data-testid={m.denied ? 'sana-refusal' : m.error ? 'sana-error' : 'sana-answer'}>
      <SanaMark className="mt-1 h-7 w-7" />
      <div className="min-w-0 max-w-[88%]">
        <div dir="auto" className={clsx('whitespace-pre-wrap rounded-[18px] rounded-ss-md border px-4 py-2.5 text-[15px] leading-relaxed',
          m.error ? 'border-crit-fg/30 bg-crit-bg text-crit-fg' : m.denied ? 'border-line bg-neutral-bg text-ink' : 'border-line bg-surface text-ink')} role={m.error ? 'alert' : undefined}>
          {m.denied && <Lock className="me-1.5 inline h-3.5 w-3.5 text-muted" aria-label={t('sana.deniedLabel')} />}
          {m.error && <AlertTriangle className="me-1.5 inline h-3.5 w-3.5" aria-hidden />}
          {m.text}
          {m.streaming && <span className="ms-0.5 inline-block h-4 w-1.5 animate-pulse bg-primary align-middle motion-reduce:animate-none" aria-hidden />}
        </div>
        {!!m.sources?.length && (
          <div className="mt-2 flex flex-wrap gap-1.5" aria-label={t('sana.sources')}>
            {m.sources.map((src) => (
              <Link key={src.link} to={src.link} onClick={() => { if (window.innerWidth < 640) s.setOpen(false); }}
                className="inline-flex min-h-[32px] items-center rounded-full border border-primary-line bg-primary-soft px-3 text-[13px] font-medium text-primary-text hover:border-primary">
                {src.label === 'Open list' ? t('sana.openList') : src.label}
              </Link>
            ))}
          </div>
        )}
        {!m.error && !m.streaming && (
          <div className="mt-1 flex flex-wrap items-center gap-1">
            {s.status?.voice_enabled !== false && (
              <button type="button" onClick={() => onSpeak(m)} className="inline-flex min-h-[32px] items-center gap-1 rounded-btn px-1.5 text-[12px] text-muted hover:text-ink">
                {speaking ? <Square className="h-3.5 w-3.5" aria-hidden /> : <Volume2 className="h-3.5 w-3.5" aria-hidden />} {speaking ? t('sana.stop') : t('sana.listen')}
              </button>
            )}
            {m.messageId && (
              <>
                <button type="button" onClick={() => void vote(1)} aria-pressed={m.feedback === 1} aria-label={t('sana.fb.up')} title={t('sana.fb.up')} data-testid="sana-fb-up"
                  className={clsx('grid h-8 w-8 place-items-center rounded-btn hover:bg-surface-2', m.feedback === 1 ? 'text-ok-fg' : 'text-muted')}>
                  <ThumbsUp className={clsx('h-3.5 w-3.5', m.feedback === 1 && 'fill-current')} aria-hidden />
                </button>
                <button type="button" onClick={() => void vote(-1)} aria-pressed={m.feedback === -1} aria-label={t('sana.fb.down')} title={t('sana.fb.down')} data-testid="sana-fb-down"
                  className={clsx('grid h-8 w-8 place-items-center rounded-btn hover:bg-surface-2', m.feedback === -1 ? 'text-crit-fg' : 'text-muted')}>
                  <ThumbsDown className={clsx('h-3.5 w-3.5', m.feedback === -1 && 'fill-current')} aria-hidden />
                </button>
              </>
            )}
            {m.fallback && <span className="text-[11.5px] text-warn-fg">{t('sana.fallback')}</span>}
          </div>
        )}
        {voiceNote && <p className="mt-1 text-[12.5px] text-warn-fg" role="status" data-testid="sana-no-voice">{voiceNote}</p>}
        {fbErr && <p className="mt-1 text-[12.5px] text-crit-fg" role="alert">{fbErr}</p>}
      </div>
    </div>
  );
}

function HistoryView({ onOpen }: { onOpen: () => void }) {
  const { t, i18n } = useTranslation();
  const s = useSana();
  const h = useSanaHistory(true);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  return (
    <div className="flex-1 overflow-y-auto px-4 py-4" data-testid="sana-history">
      <h3 className="mb-3 text-[13px] font-semibold uppercase tracking-[0.08em] text-muted">{t('sana.history.title')}</h3>
      {err && <p role="alert" className="mb-3 rounded-btn border border-crit-fg/30 bg-crit-bg px-3 py-2 text-[13px] text-crit-fg">{err}</p>}
      {h.isLoading ? <p className="text-[14px] text-muted">{t('app.loading')}</p>
        : h.error ? <p role="alert" className="text-[14px] text-crit-fg">{errorMessage(h.error)}</p>
        : !h.data?.length ? (
          <div className="pt-8 text-center">
            <MessageSquare className="mx-auto h-8 w-8 text-muted" aria-hidden />
            <p className="mt-3 font-semibold text-ink">{t('sana.history.empty')}</p>
            <p className="mt-1 text-[13px] text-muted">{t('sana.history.emptyBody')}</p>
          </div>
        ) : (
          <ul className="space-y-2">
            {h.data.map((c) => (
              <li key={c.conversation_id} className={clsx('rounded-[14px] border bg-surface p-3', s.conversationId === c.conversation_id ? 'border-primary-line' : 'border-line')} data-testid="sana-history-item">
                {confirm === c.conversation_id ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="flex-1 text-[14px] text-ink">{t('sana.history.confirm')}</p>
                    <button type="button" className="min-h-[36px] rounded-btn bg-crit-fg px-3 text-[13px] font-semibold text-white" data-testid="sana-history-confirm"
                      onClick={async () => { setErr(null); try { await s.deleteConversation(c.conversation_id); } catch (e) { setErr(errorMessage(e)); } setConfirm(null); }}>
                      {t('sana.history.delete')}
                    </button>
                    <button type="button" className="min-h-[36px] rounded-btn border border-line px-3 text-[13px]" onClick={() => setConfirm(null)}>{t('app.cancel')}</button>
                  </div>
                ) : (
                  <div className="flex items-start gap-2">
                    <button type="button" className="min-w-0 flex-1 text-start" onClick={async () => { setErr(null); try { await s.loadConversation(c.conversation_id); onOpen(); } catch (e) { setErr(errorMessage(e)); } }}>
                      <span dir="auto" className="block truncate text-[14px] font-medium text-ink">{c.title || t('sana.history.untitled')}</span>
                      <span className="mt-0.5 block text-[12px] text-muted">{fmtWhen(c.last_at, i18n.language)} · {c.company ?? '—'} · {t('sana.history.messages', { count: c.messages })}</span>
                    </button>
                    <button type="button" onClick={() => setConfirm(c.conversation_id)} aria-label={t('sana.history.deleteNamed', { title: c.title })} title={t('sana.history.delete')}
                      className="grid h-9 w-9 shrink-0 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg" data-testid="sana-history-delete">
                      <Trash2 className="h-4 w-4" aria-hidden />
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
    </div>
  );
}

/** The Sana assistant: a side panel on desktop, a full-screen sheet on phones. Text and voice, many languages. */
export function SanaPanel() {
  const { t, i18n } = useTranslation();
  const { profile } = useAuth();
  const s = useSana();
  const [text, setText] = useState('');
  const [view, setView] = useState<'chat' | 'history'>('chat');
  const [speakingId, setSpeakingId] = useState<string | null>(null);
  const [voiceNote, setVoiceNote] = useState<{ id: string; text: string } | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const panelRef = useRef<HTMLElement>(null);
  const opener = useRef<HTMLElement | null>(null);
  useVoicesReady();
  const locale = speechLocale(s.language, i18n.language);
  const mic = useSpeechInput((said) => { void send(said, 'voice'); });
  const first = profile?.user?.display_name?.split(/\s+/)[0] ?? '';
  const voiceOn = s.status?.voice_enabled !== false;
  const off = s.status && !s.status.enabled;
  const langs = SANA_LANGUAGES.filter((l) => l.code === 'auto' || !s.status?.languages || s.status.languages.includes(l.code));

  async function send(q: string, via: 'text' | 'voice' = 'text') {
    if (!q.trim()) return;
    setText(''); setView('chat');
    const reply = await s.ask(q, via);
    if (reply && !reply.error && s.autoSpeak && via === 'voice') playSpeech(reply);
  }
  function playSpeech(m: SanaMessage) {
    setVoiceNote(null);
    if (speakingId === m.id) { stopSpeaking(); setSpeakingId(null); return; }
    const loc = m.language ? speechLocale(m.language, i18n.language) : locale;
    const r = speak(m.text, loc, () => setSpeakingId(null));
    if (r === 'ok') setSpeakingId(m.id);
    else setVoiceNote({ id: m.id, text: r === 'no-voice' ? t('sana.noVoice', { language: languageLabel(m.language ?? loc) }) : t('sana.noSpeech') });
  }
  function onSubmit(e: FormEvent) { e.preventDefault(); void send(text); }

  useEffect(() => { listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' }); }, [s.messages, s.busy]);
  useEffect(() => {
    if (s.open) {
      opener.current = document.activeElement as HTMLElement | null;
      setTimeout(() => inputRef.current?.focus(), 50);
    } else {
      stopSpeaking(); mic.stop(); setView('chat');
      opener.current?.focus?.();   // focus returns to the button that opened Sana
    }
  }, [s.open]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!s.open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') s.setOpen(false); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [s.open, s]);
  // Focus trap: Tab stays inside the dialog.
  function onKeyDown(e: ReactKeyboardEvent) {
    if (e.key !== 'Tab' || !panelRef.current) return;
    const f = Array.from(panelRef.current.querySelectorAll<HTMLElement>('a[href], button:not([disabled]), textarea:not([disabled]), select, input, [tabindex]:not([tabindex="-1"])')).filter((x) => x.offsetParent !== null);
    if (!f.length) return;
    const firstEl = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === firstEl) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); firstEl.focus(); }
  }

  if (!s.open) return null;
  const suggestions = s.context ? sanaContextSuggestions(s.context) : sanaSuggestions(profile?.modules ?? []);
  const micMsg = mic.error === 'not-allowed' ? t('sana.mic.denied') : mic.error === 'unsupported' ? t('sana.mic.unsupported') : mic.error === 'no-speech' ? t('sana.mic.noSpeech') : mic.error ? t('sana.mic.other') : null;
  const left = s.status?.daily_limit != null && s.status.used != null ? Math.max(s.status.daily_limit - s.status.used, 0) : null;

  return (
    <>
      <div className="fixed inset-0 z-40 hidden bg-black/30 sm:block" onClick={() => s.setOpen(false)} aria-hidden />
      <aside ref={panelRef} role="dialog" aria-modal="true" aria-labelledby="sana-title" onKeyDown={onKeyDown}
        className="fixed inset-0 z-50 flex flex-col bg-page shadow-2xl sm:inset-y-0 sm:end-0 sm:start-auto sm:w-[440px] sm:border-s sm:border-line motion-safe:animate-[sana-in_180ms_ease-out]">
        {/* Header */}
        <header className="flex items-center gap-2 bg-brand-navy px-3 py-3 text-white sm:gap-3 sm:px-4">
          <SanaMark className="h-9 w-9" />
          <div className="min-w-0 flex-1">
            <h2 id="sana-title" className="font-display text-[19px] font-bold leading-none tracking-[0.02em]">SANA</h2>
            <p className="mt-1 truncate text-[12px] text-white/70">{t('sana.fullName')}</p>
          </div>
          <label className="sr-only" htmlFor="sana-lang">{t('sana.language')}</label>
          <select id="sana-lang" value={s.language} onChange={(e) => s.setLanguage(e.target.value)}
            className="min-h-[40px] max-w-[96px] rounded-btn border border-white/20 bg-white/10 px-1.5 text-[13px] text-white [&>option]:text-ink">
            {langs.map((l) => <option key={l.code} value={l.code}>{l.code === 'auto' ? t('sana.autoLang') : l.label}</option>)}
          </select>
          {voiceOn && (
            <button type="button" onClick={() => s.setAutoSpeak(!s.autoSpeak)} aria-pressed={s.autoSpeak}
              className="grid h-10 w-10 place-items-center rounded-btn hover:bg-white/10" title={s.autoSpeak ? t('sana.autoSpeakOn') : t('sana.autoSpeakOff')} aria-label={t('sana.autoSpeak')}>
              {s.autoSpeak ? <Volume2 className="h-5 w-5" aria-hidden /> : <VolumeX className="h-5 w-5" aria-hidden />}
            </button>
          )}
          <button type="button" onClick={() => setView(view === 'history' ? 'chat' : 'history')} aria-pressed={view === 'history'} id="sana-history-btn"
            className="grid h-10 w-10 place-items-center rounded-btn hover:bg-white/10" title={t('sana.history.title')} aria-label={t('sana.history.title')}>
            {view === 'history' ? <ArrowLeft className="h-5 w-5 rtl:rotate-180" aria-hidden /> : <History className="h-5 w-5" aria-hidden />}
          </button>
          <button type="button" onClick={() => { stopSpeaking(); s.newChat(); setView('chat'); }} className="grid h-10 w-10 place-items-center rounded-btn hover:bg-white/10" title={t('sana.newChat')} aria-label={t('sana.newChat')}>
            <Plus className="h-5 w-5" aria-hidden />
          </button>
          <button type="button" onClick={() => s.setOpen(false)} className="grid h-10 w-10 place-items-center rounded-btn hover:bg-white/10" aria-label={t('sana.close')}>
            <X className="h-5 w-5" aria-hidden />
          </button>
        </header>

        {s.context && view === 'chat' && (
          <div className="flex items-center gap-2 border-b border-line bg-surface px-4 py-2 text-[13px]" data-testid="sana-context">
            <span className="text-muted">{t('sana.ctx.about')}</span>
            <span dir="auto" className="min-w-0 flex-1 truncate font-medium text-ink">{contextLabel(s.context, t)}</span>
            <button type="button" onClick={() => s.setContext(null)} className="grid h-8 w-8 place-items-center rounded-btn text-muted hover:bg-surface-2" aria-label={t('sana.ctx.clear')} title={t('sana.ctx.clear')}>
              <X className="h-4 w-4" aria-hidden />
            </button>
          </div>
        )}

        {view === 'history' ? <HistoryView onOpen={() => setView('chat')} /> : (
          /* Messages */
          <div ref={listRef} className="flex-1 space-y-4 overflow-y-auto px-4 py-5" aria-live="polite" aria-busy={s.busy}>
            {off && (
              <p role="status" className="rounded-btn border border-warn-fg/30 bg-warn-bg px-3 py-2 text-[13px] text-warn-fg" data-testid="sana-off">{t('sana.off', { company: s.status?.company ?? '' })}</p>
            )}
            {s.messages.length === 0 && (
              <div className="pt-4 text-center">
                <SanaMark className="mx-auto h-16 w-16" />
                <p className="mt-4 font-display text-[22px] font-semibold text-ink">{first ? t('sana.hello', { name: first }) : t('sana.helloNoName')}</p>
                <p className="mx-auto mt-1 max-w-[320px] text-[14px] text-muted">{s.context ? t('sana.ctx.intro') : t('sana.intro')}</p>
                <div className="mt-6 flex flex-col gap-2">
                  {suggestions.map((k) => (
                    <button key={k} type="button" onClick={() => void send(t(k))} disabled={off || s.busy}
                      className="min-h-[44px] rounded-[14px] border border-line bg-surface px-4 text-start text-[14px] text-ink hover:border-primary-line hover:bg-primary-soft disabled:opacity-60">
                      {t(k)}
                    </button>
                  ))}
                </div>
              </div>
            )}
            {s.messages.map((m) => <Bubble key={m.id} m={m} speaking={speakingId === m.id} onSpeak={playSpeech} voiceNote={voiceNote?.id === m.id ? voiceNote.text : null} />)}
            {s.busy && !s.messages.some((m) => m.streaming) && (
              <div className="flex items-center gap-2.5" role="status" aria-label={t('sana.thinking')}>
                <SanaMark className="h-7 w-7" />
                <span className="inline-flex gap-1 rounded-full border border-line bg-surface px-4 py-3">
                  {[0, 1, 2].map((i) => <span key={i} className="h-2 w-2 animate-bounce rounded-full bg-primary motion-reduce:animate-none" style={{ animationDelay: `${i * 120}ms` }} />)}
                </span>
              </div>
            )}
            {s.mode === 'basic' && s.messages.length > 0 && (
              <p className="rounded-btn border border-warn-fg/30 bg-warn-bg px-3 py-2 text-[12px] text-warn-fg" data-testid="sana-basic">{t('sana.basicMode')}</p>
            )}
          </div>
        )}

        {/* Composer */}
        <form onSubmit={onSubmit} className="border-t border-line bg-surface px-3 pb-3 pt-2">
          {(mic.listening || mic.interim) && (
            <p dir="auto" className="mb-2 flex items-center gap-2 rounded-btn bg-primary-soft px-3 py-2 text-[14px] text-primary-text" aria-live="assertive" data-testid="sana-listening">
              <span className="relative flex h-2.5 w-2.5"><span className="absolute inline-flex h-full w-full rounded-full bg-brand-coral opacity-75 motion-safe:animate-ping" /><span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-brand-coral" /></span>
              {mic.interim || t('sana.listening')}
            </p>
          )}
          {micMsg && <p role="alert" className="mb-2 text-[13px] text-crit-fg" data-testid="sana-mic-msg">{micMsg}</p>}
          <div className="flex items-end gap-2">
            <label htmlFor="sana-input" className="sr-only">{t('sana.placeholder')}</label>
            <textarea id="sana-input" ref={inputRef} rows={1} dir="auto" value={text} maxLength={2000} disabled={off}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(text); } }}
              placeholder={t('sana.placeholder')}
              className="max-h-32 min-h-[48px] flex-1 resize-none rounded-[14px] border border-line-strong bg-page px-4 py-3 text-[15px] text-ink outline-none placeholder:text-muted focus:border-primary" />
            <button type="button" onClick={() => (mic.listening ? mic.stop() : (stopSpeaking(), mic.start(locale)))} disabled={s.busy || off || !voiceOn} data-testid="sana-mic"
              aria-pressed={mic.listening} aria-label={mic.listening ? t('sana.stopListening') : t('sana.speak')}
              title={!voiceOn ? t('sana.voiceOff') : mic.supported ? (mic.listening ? t('sana.stopListening') : t('sana.speak')) : t('sana.mic.unsupported')}
              className={clsx('grid h-12 w-12 shrink-0 place-items-center rounded-full border transition',
                mic.listening ? 'border-brand-coral bg-brand-coral text-white' : 'border-line-strong bg-surface text-ink hover:border-primary hover:text-primary', (!mic.supported || !voiceOn) && 'opacity-50')}>
              {mic.supported && voiceOn ? <Mic className="h-5 w-5" aria-hidden /> : <MicOff className="h-5 w-5" aria-hidden />}
            </button>
            <button type="submit" disabled={s.busy || !text.trim() || off} aria-label={t('sana.send')}
              className="grid h-12 w-12 shrink-0 place-items-center rounded-full bg-primary text-white transition hover:bg-primary-hover disabled:bg-neutral-bg disabled:text-muted">
              <ArrowUp className="h-5 w-5" aria-hidden />
            </button>
          </div>
          <p className="mt-2 flex items-start gap-1.5 text-[11.5px] leading-snug text-muted">
            <ShieldCheck className="mt-px h-3.5 w-3.5 shrink-0 text-brand-teal" aria-hidden />
            <span>{t('sana.privacy')}{left != null && left <= 20 ? ` ${t('sana.left', { count: left })}` : ''}</span>
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
    <button type="button" onClick={() => s.setOpen(true)} aria-label={t('sana.ask')} data-testid="sana-fab"
      className="fixed bottom-5 end-5 z-30 grid h-14 w-14 place-items-center rounded-full bg-surface shadow-[0_6px_24px_rgba(1,39,70,0.25)] ring-1 ring-line sm:hidden">
      <SanaMark className="h-9 w-9" />
    </button>
  );
}

/** "Ask Sana about this" on document, partner and item pages (secondary button with the Sana mark). */
export function AskSanaAbout({ context, className, variant = 'button' }: { context: SanaContext; className?: string; variant?: 'button' | 'card' }) {
  const { t } = useTranslation();
  const s = useSana();
  const btn = (
    <button type="button" onClick={() => s.openWith({ context })} data-testid="ask-sana-about"
      className={clsx('inline-flex min-h-[44px] items-center justify-center gap-2 rounded-btn border border-primary-line bg-primary-soft px-4 text-sm font-semibold text-primary-text hover:border-primary', variant === 'card' && 'w-full', className)}>
      <SanaMark className="h-5 w-5" /> {t('sana.askAbout')}
    </button>
  );
  if (variant === 'button') return btn;
  return (
    <section className="card p-5" aria-labelledby="ask-sana-h">
      <h2 id="ask-sana-h" className="mb-1 text-[15px] font-semibold">{t('sana.askAboutTitle')}</h2>
      <p className="mb-3 text-[13px] text-muted">{t('sana.askAboutBody')}</p>
      {btn}
    </section>
  );
}

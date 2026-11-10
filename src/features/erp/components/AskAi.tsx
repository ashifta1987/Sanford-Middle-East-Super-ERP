import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, ArrowRight, Bot, Lock, Sparkles, X } from 'lucide-react';
import { useCompany } from '@/layout/CompanyContext';
import { useAuth } from '@/auth/AuthProvider';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { SectionCard } from './ui';
import { AiNotConfigured, LOCAL_RESPONDER, askAi, useAiStatus, type AiAnswer, type AiRef } from '../ai';

interface OpenOpts { ref?: AiRef | null; label?: string; question?: string; company?: string }
const Ctx = createContext<{ open: (o?: OpenOpts) => void }>({ open: () => {} });
export const useAskAi = () => useContext(Ctx);

/** Ask AI panel for the whole app (top bar button, document cards, Reports › Ask AI for a Report). */
export function AskAiProvider({ children }: { children: ReactNode }) {
  const [opts, setOpts] = useState<OpenOpts | null>(null);
  const open = useCallback((o?: OpenOpts) => setOpts(o ?? {}), []);
  return (
    <Ctx.Provider value={{ open }}>
      {children}
      {opts && <AskAiPanel key={JSON.stringify(opts)} opts={opts} onClose={() => setOpts(null)} />}
    </Ctx.Provider>
  );
}

function AskAiPanel({ opts, onClose }: { opts: OpenOpts; onClose: () => void }) {
  const { t } = useTranslation();
  const { company: topCompany } = useCompany();
  const { profile } = useAuth();
  const company = opts.company ?? (topCompany === 'GRP' ? null : topCompany);
  const status = useAiStatus(company);
  const [q, setQ] = useState(opts.question ?? '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [notConfigured, setNotConfigured] = useState(false);
  const [ans, setAns] = useState<AiAnswer | null>(null);
  const boxRef = useRef<HTMLTextAreaElement>(null);
  const opener = useRef<Element | null>(null);
  const qid = useId();

  useEffect(() => {
    opener.current = document.activeElement;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('keydown', onKey); (opener.current as HTMLElement | null)?.focus?.(); };
  }, [onClose]);
  useEffect(() => { if (status.data?.configured) boxRef.current?.focus(); }, [status.data?.configured]);

  async function submit() {
    if (!company || !q.trim()) return;
    setBusy(true); setErr(null); setAns(null);
    try {
      setAns(await askAi(company, q.trim(), opts.ref));
      status.refetch();
    } catch (e) {
      if (e instanceof AiNotConfigured) setNotConfigured(true);
      else setErr(errorMessage(e));
    } finally { setBusy(false); }
  }

  const S = status.data;
  const off = notConfigured || (S && !S.configured);
  const isTest = ans?.responder === LOCAL_RESPONDER;

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-black/40" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <section role="dialog" aria-modal="true" aria-labelledby="ai-title" data-testid="ai-panel"
        className="flex h-full w-full flex-col overflow-y-auto border-s border-line bg-surface shadow-card sm:max-w-[460px]">
        <header className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-line bg-surface px-5 py-3">
          <h2 id="ai-title" className="inline-flex items-center gap-2 text-[15px] font-semibold"><Sparkles className="h-4 w-4 text-primary" aria-hidden />{t('ai.title')}</h2>
          <button type="button" onClick={onClose} aria-label={t('ai.close')} className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-page">
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>
        <div className="space-y-4 p-5">
          <p className="text-sm text-muted">{company ? t('ai.forCompany', { company }) : null}{opts.label ? ` · ${opts.label}` : ''}</p>
          {!company ? (
            <p className="rounded-btn border border-line bg-surface-2 p-4 text-sm" data-testid="ai-pick-company">{t('ai.pickCompany')}</p>
          ) : status.isLoading ? (
            <p className="text-sm text-muted">{t('app.loading')}</p>
          ) : status.error ? (
            <p role="alert" className="flex items-start gap-2 rounded-btn border border-crit-fg/30 bg-crit-bg p-3 text-sm text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{errorMessage(status.error)}</p>
          ) : off ? (
            <div className="rounded-card border border-line bg-surface-2 p-5" data-testid="ai-not-configured">
              <p className="flex items-center gap-2 font-semibold"><Bot className="h-5 w-5 text-muted" aria-hidden />{t('ai.notConfigured')}</p>
              <p className="mt-2 text-sm text-ink-2">{t('ai.notConfiguredBody', { company })}</p>
              {S?.can_setup && <Link to="/admin/ai-assistant" onClick={onClose} className="mt-3 inline-flex min-h-[44px] items-center gap-1 text-sm font-medium text-primary hover:underline">{t('ai.openSettings')} <ArrowRight className="h-4 w-4 rtl:rotate-180" aria-hidden /></Link>}
            </div>
          ) : (
            <>
              {S && S.tools.length > 0 && (
                <p className="text-xs text-muted">{t('ai.canAsk')} {S.tools.filter((x) => x !== 'document').map((x) => t(`ai.tool.${x}`)).join(' · ')}</p>
              )}
              <form onSubmit={(e) => { e.preventDefault(); submit(); }} className="space-y-3">
                <label htmlFor={qid} className="block text-xs font-medium text-muted">{t('ai.question')}</label>
                <textarea id={qid} ref={boxRef} rows={3} dir="auto" maxLength={500} value={q} onChange={(e) => setQ(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); } }}
                  placeholder={t('ai.placeholder')} className="input py-2 text-[15px]" data-testid="ai-question" />
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-xs text-muted">{S?.remaining != null ? t('ai.remaining', { n: S.remaining }) : ''}</span>
                  <Button variant="primary" type="submit" id="ai-ask" disabled={busy || !q.trim()}>{busy ? t('ai.asking') : t('ai.ask')}</Button>
                </div>
              </form>
              {err && <p role="alert" className="flex items-start gap-2 rounded-btn border border-crit-fg/30 bg-crit-bg p-3 text-sm text-crit-fg" data-testid="ai-error"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto">{err}</span></p>}
              {ans && (
                <div className="space-y-4" data-testid="ai-answer">
                  <div className={clsx('rounded-card border p-4', isTest ? 'border-warn-fg/40 bg-warn-bg' : 'border-primary-line bg-primary-soft')}>
                    <p className="mb-2 flex flex-wrap items-center gap-2">
                      <span className={clsx('pill', isTest ? 'pill-warning' : 'pill-info')} data-testid="ai-responder">{isTest ? t('ai.testResponder') : t('ai.aiAnswer', { provider: ans.responder })}</span>
                    </p>
                    {isTest && <p className="mb-2 text-xs text-warn-fg" data-testid="ai-test-note">{t('ai.testNote')}</p>}
                    <p dir="auto" className={clsx('whitespace-pre-line text-[14px]', isTest ? 'text-ink' : 'text-primary-text')} data-testid="ai-answer-text">{ans.answer}</p>
                    {!isTest && <p className="mt-2 text-xs text-muted">{t('ai.checkSources')}</p>}
                  </div>
                  <div>
                    <h3 className="eyebrow mb-2">{t('ai.dataUsed')}</h3>
                    <ul className="space-y-1.5 text-sm" data-testid="ai-tools">
                      {ans.tools.length === 0 && <li className="text-muted">{t('ai.noTools')}</li>}
                      {ans.tools.map((x) => (
                        <li key={x.tool} className="flex items-start gap-2" data-tool={x.tool} data-status={x.status}>
                          {x.status === 'ok' ? <span className="pill pill-ok shrink-0">{t('ai.read')}</span> : <span className="pill pill-neutral shrink-0"><Lock className="me-1 h-3 w-3" aria-hidden />{t('ai.notUsed')}</span>}
                          <span><span className="font-medium">{t(`ai.tool.${x.tool}`)}</span>{x.status !== 'ok' && x.message ? <span className="block text-xs text-muted" dir="auto">{x.message}</span> : null}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                  {ans.sources.length > 0 && (
                    <div>
                      <h3 className="eyebrow mb-2">{t('ai.sources', { n: ans.sources.length })}</h3>
                      <ul className="divide-y divide-line rounded-card border border-line" data-testid="ai-sources">
                        {ans.sources.map((s) => (
                          <li key={s.link}><Link to={s.link} onClick={onClose} className="flex min-h-[44px] items-center justify-between gap-2 px-3 py-2 text-sm hover:bg-surface-2">
                            <span dir="auto" className="min-w-0 truncate text-primary">{s.label}</span><ArrowRight className="h-4 w-4 shrink-0 text-muted rtl:rotate-180" aria-hidden /></Link></li>
                        ))}
                      </ul>
                    </div>
                  )}
                </div>
              )}
            </>
          )}
          <p className="border-t border-line pt-3 text-xs text-muted">{t('ai.foot', { name: profile?.user?.display_name ?? '' })}</p>
        </div>
      </section>
    </div>
  );
}

/** "Ask AI about this order" on document pages. */
export function AskAiDocCard({ company, obj, entry, title, label }: { company: string; obj: number; entry?: number | null; title: string; label: string }) {
  const { t } = useTranslation();
  const { open } = useAskAi();
  return (
    <SectionCard title={<span className="inline-flex items-center gap-2"><Sparkles className="h-4 w-4" aria-hidden />{title}</span>}>
      <div className="space-y-3 p-5">
        <p className="text-sm text-muted">{entry ? t('ai.docBody') : t('ai.docSaveFirst')}</p>
        {entry ? (
          <Button variant="secondary" id="ai-doc-ask" className="w-full" icon={<Sparkles className="h-4 w-4" aria-hidden />}
            onClick={() => open({ company, ref: { obj_type: obj, doc_entry: entry }, label, question: t('ai.docQuestion') })}>{title}</Button>
        ) : null}
      </div>
    </SectionCard>
  );
}

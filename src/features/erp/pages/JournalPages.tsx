import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, ArrowLeft, Check, CircleCheck, CircleX, FileText, Plus, Trash2, Undo2, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { errorMessage } from '@/lib/format';
import i18n from '@/lib/i18n';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey } from '../modules';
import type { Row } from '../api';
import {
  jeCancel, jeChecks, jeDecide, jeReverse, jeSave, jeSubmit, round2, searchAccounts, todayIso, useJeDraftInfo, useJeSetup,
  type AccountHit, type JeDraftInfo, type JeEval, type JeHeaderInput, type JeLineInput, type JeState, type JournalInfo,
} from '../journal';
import { ApprovalStageNote } from '../components/ApprovalStageNote';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

// ---------- Shared pieces ----------
const STATE_TONE: Record<JeState, string> = {
  draft: 'pill-neutral', pending_approval: 'pill-warning', posted: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-crit',
};
export function JeStatePill({ state }: { state: JeState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', STATE_TONE[state])}>{t(`je.state.${state}`)}</span>;
}
const fmtWhen = (iso: string | null | undefined) =>
  !iso ? '—' : new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
const num = (s: string) => (s.trim() === '' ? 0 : Number(s) || 0);

function JeHeader({ title, pills, sub, actions, onBack }: { title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; onBack?: (e: React.MouseEvent) => void }) {
  const { t } = useTranslation();
  const m = moduleByKey('financials')!;
  return (
    <header className="mb-4">
      <Link to="/financials/journals" onClick={onBack} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('je.back')}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/financials'], [t('erp.page.journals'), '/financials/journals'], [title, undefined]]} />
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <h1 dir="auto" className="flex flex-wrap items-center gap-3 text-[26px] font-semibold leading-tight sm:text-[28px]">{title} {pills}</h1>
          {sub && <p dir="auto" className="mt-1 text-[15px] text-muted">{sub}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-start gap-2">{actions}</div>}
      </div>
    </header>
  );
}

function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{text}</p>;
}
function useFlash() {
  const loc = useLocation();
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  useEffect(() => { if (flash) { const h = setTimeout(() => setFlash(null), 6000); return () => clearTimeout(h); } }, [flash]);
  return [flash, setFlash] as const;
}

function DcTotals({ debit, credit, currency }: { debit: number; credit: number; currency: string }) {
  const { t } = useTranslation();
  const diff = round2(debit - credit);
  return (
    <dl className="num ms-auto grid w-full max-w-xs grid-cols-2 gap-x-6 gap-y-1 border-t border-line p-5 text-[15px] sm:border-t-0" aria-live="polite">
      <dt className="text-muted">{t('je.totalDebit')}</dt><dd className="text-end" data-testid="je-debit">{fmtMoney(debit)}</dd>
      <dt className="text-muted">{t('je.totalCredit')}</dt><dd className="text-end" data-testid="je-credit">{fmtMoney(credit)}</dd>
      <dt className={clsx('text-[17px] font-semibold', diff !== 0 && 'text-crit-fg')}>{t('je.difference', { cur: currency })}</dt>
      <dd className={clsx('text-end text-[17px] font-semibold', diff !== 0 ? 'text-crit-fg' : 'text-ok-fg')} data-testid="je-diff">{fmtMoney(diff)}</dd>
    </dl>
  );
}

function ActivityCard({ items }: { items: Array<{ at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }> }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('je.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('je.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="je-activity">
          {items.map((a, i) => {
            const det = (a.detail ?? {}) as R;
            const key = a.action === 'journal_submit' ? (det.result === 'posted' ? 'submitPosted' : 'submitPending') : a.action;
            const tone = /approve|post|reversed/.test(a.action) ? 'bg-ok-fg' : /reject|cancel/.test(a.action) ? 'bg-crit-fg' : 'bg-primary';
            return (
              <li key={i} className="flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', tone)} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{a.actor_name.startsWith('system:') ? t('je.activity.system') : a.actor_name}</span> {t(`je.activity.${key}`, { defaultValue: a.action, n: det.reversed_by ?? det.trans_id ?? '' })}</p>
                  {(det.reason || det.note) && <p dir="auto" className="text-ink-2">“{String(det.reason ?? det.note)}”</p>}
                  <p className="num text-xs text-muted">{fmtWhen(a.at)}</p>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </SectionCard>
  );
}

// ---------- Form (new / edit draft) ----------
interface FormLine extends JeLineInput { key: string; text: string }
let lineSeq = 0;
const newLine = (): FormLine => ({ key: `j${++lineSeq}`, acct_code: '', debit: '', credit: '', memo: '', text: '' });
interface FormInitial { id: number; header: JeHeaderInput; lines: FormLine[] }

export function JournalNewPage() {
  return <RequireModule module="financials"><JournalForm /></RequireModule>;
}

function JournalForm({ company: fixedCompany, initial, info }: { company?: string; initial?: FormInitial; info?: JeDraftInfo }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const { canWrite, readOnlyReason } = useModuleLevel('financials');
  const companies = profile?.companies ?? [];
  const [company, setCompany] = useState<string>(fixedCompany ?? (top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? ''));
  const setup = useJeSetup(company || null);
  const [id, setId] = useState<number | null>(initial?.id ?? null);
  const [header, setHeader] = useState<JeHeaderInput>(initial?.header ?? { ref_date: todayIso(), due_date: '', memo: '', ref1: '' });
  const [lines, setLines] = useState<FormLine[]>(initial?.lines.length ? initial.lines : [newLine(), newLine()]);
  const [removed, setRemoved] = useState<{ line: FormLine; index: number } | null>(null);
  const [reason, setReason] = useState('');
  const [reasonErr, setReasonErr] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [attempted, setAttempted] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [busy, setBusy] = useState<'save' | 'post' | null>(null);
  const [preview, setPreview] = useState<JeEval | null>(null);
  const currency = setup.data?.currency ?? companies.find((c) => c.company_code === company)?.currency ?? '';

  useEffect(() => {
    if (!dirty) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', h);
    return () => window.removeEventListener('beforeunload', h);
  }, [dirty]);

  const setH = (patch: Partial<JeHeaderInput>) => { setHeader((h) => ({ ...h, ...patch })); setDirty(true); };
  const setL = (key: string, patch: Partial<FormLine>) => { setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l))); setDirty(true); };
  const filled = lines.filter((l) => l.acct_code || l.debit.trim() || l.credit.trim() || l.memo.trim());
  const debit = round2(filled.reduce((s, l) => s + num(l.debit), 0));
  const credit = round2(filled.reduce((s, l) => s + num(l.credit), 0));
  const diff = round2(debit - credit);

  // Live check against the server rules (debounced). The server is the authority; this only previews.
  const previewKey = JSON.stringify([company, header, filled.map(({ acct_code, debit: d, credit: c }) => [acct_code, d, c])]);
  useEffect(() => {
    if (!company || !filled.length) { setPreview(null); return; }
    let live = true;
    const h = setTimeout(() => { jeChecks(company, header, filled).then((r) => { if (live) setPreview(r); }).catch(() => { if (live) setPreview(null); }); }, 450);
    return () => { live = false; clearTimeout(h); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey]);

  const problems = attempted ? preview?.errors ?? [] : [];
  const lineIndex = (l: FormLine) => filled.indexOf(l) + 1;
  const lineProblems = (l: FormLine) => problems.filter((p) => p.line != null && p.line === lineIndex(l));
  const periodMsg = preview?.errors.find((p) => p.field === 'period')?.message;
  const checks = preview && !preview.errors.length ? preview.checks : [];
  const needsApproval = checks.length > 0;

  function addLine(focus = true) {
    const l = newLine();
    setLines((ls) => [...ls, l]);
    setDirty(true);
    if (focus) setTimeout(() => document.getElementById(`jl-${l.key}-acct`)?.focus(), 30);
  }
  function removeLine(key: string) {
    const index = lines.findIndex((l) => l.key === key);
    if (index < 0) return;
    setRemoved({ line: lines[index], index });
    setLines((ls) => (ls.length === 1 ? [newLine()] : ls.filter((l) => l.key !== key)));
    setDirty(true);
  }
  function undoRemove() {
    if (!removed) return;
    setLines((ls) => { const next = [...ls]; next.splice(removed.index, 0, removed.line); return next; });
    setRemoved(null);
  }
  const enterAdds = (e: React.KeyboardEvent) => { if (e.key === 'Enter') { e.preventDefault(); addLine(); } };
  const back = (e: React.MouseEvent) => { if (dirty && !window.confirm(t('je.leave'))) e.preventDefault(); };

  async function save(post: boolean) {
    setAttempted(true); setServerError(null); setReasonErr(null);
    if (post && needsApproval && !reason.trim()) { setReasonErr(t('je.reasonNeeded')); document.getElementById('je-reason')?.focus(); return; }
    setBusy(post ? 'post' : 'save');
    try {
      const res = await jeSave(company, id, header, filled);
      setId(res.draft_id);
      qc.removeQueries({ queryKey: ['je-draft', company, res.draft_id] });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      if (!post) { setDirty(false); nav(`/financials/journals/drafts/${company}/${res.draft_id}`, { state: { flash: t('je.flash.saved') } }); return; }
      const s = await jeSubmit(company, res.draft_id, reason.trim() || null);
      setDirty(false);
      qc.invalidateQueries({ queryKey: ['approval-inbox'] });
      if (s.state === 'posted' && s.trans_id) nav(`/financials/journals/${company}/${s.trans_id}`, { state: { flash: t('je.flash.posted', { n: s.trans_id }) } });
      else nav(`/financials/journals/drafts/${company}/${res.draft_id}`, { state: { flash: t('je.flash.pending', { names: [...new Set(checks.map((c) => c.approver_name))].join(', ') }) } });
    } catch (e) {
      setServerError(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally {
      setBusy(null);
    }
  }

  const blocked = !canWrite ? readOnlyReason : undefined;
  const postReason = blocked ?? (debit === 0 && credit === 0 ? t('je.emptyReason') : diff !== 0 ? t('je.diffReason', { diff: fmtMoney(Math.abs(diff), currency) }) : undefined);
  const title = id ? t('je.titleDraft', { n: id }) : t('je.titleNew');
  const lastRej = [...(info?.approvals ?? [])].reverse().find((a) => a.decision === 'rejected');

  const acctOpts = async (q: string): Promise<Array<ComboOption<AccountHit>>> => (await searchAccounts(company, q)).map((a) => ({
    value: a.acct_code, label: `${a.format_code || a.acct_code} · ${a.name}`, data: a,
    meta: [a.acct_code, a.frozen ? t('je.frozen') : null, a.is_control ? t('je.control') : null].filter(Boolean).join(' · '),
  }));

  return (
    <div>
      <JeHeader title={title} onBack={back} pills={<><JeStatePill state={info?.state === 'rejected' ? 'rejected' : 'draft'} /><span className="pill pill-info">Super ERP</span></>}
        sub={t('je.subNew')} />

      {(serverError || problems.length > 0) && (
        <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-crit-fg">
          <p className="flex items-start gap-2 font-semibold"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="je-error">{serverError ?? t('je.fixProblems')}</span></p>
          {problems.length > 0 && (
            <ul className="mt-2 list-disc space-y-1 ps-8 text-sm">
              {problems.map((p, i) => (
                <li key={i}><a className="underline" href={`#${p.line ? `jl-${filled[p.line - 1]?.key}-${p.field === 'acct_code' ? 'acct' : 'debit'}` : p.field === 'period' ? 'je-ref_date' : `je-${p.field}`}`}>{p.message}</a></li>
              ))}
            </ul>
          )}
        </div>
      )}

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              {!fixedCompany && companies.length > 1 && !id && (
                <label className="block text-xs font-medium text-muted">{t('je.company')}
                  <select id="je-company" className="input mt-1 text-[15px] text-ink" value={company} onChange={(e) => { setCompany(e.target.value); setLines([newLine(), newLine()]); setDirty(true); }}>
                    {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
                  </select>
                </label>
              )}
              <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
                <input id="je-ref_date" type="date" className="input num mt-1 text-[15px] text-ink" value={header.ref_date} onChange={(e) => setH({ ref_date: e.target.value })}
                  aria-invalid={Boolean(periodMsg)} aria-describedby={periodMsg ? 'je-period-msg' : undefined} />
                {periodMsg && <span id="je-period-msg" className="mt-1 flex items-start gap-1 text-crit-fg"><AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden />{periodMsg}</span>}
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.dueDate')}
                <input id="je-due_date" type="date" className="input num mt-1 text-[15px] text-ink" value={header.due_date} onChange={(e) => setH({ due_date: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.ref')}
                <input id="je-ref1" className="input mt-1 text-[15px] text-ink" dir="auto" value={header.ref1} onChange={(e) => setH({ ref1: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted sm:col-span-2">{t('erp.col.remarks')}
                <input id="je-memo" className="input mt-1 text-[15px] text-ink" dir="auto" value={header.memo} placeholder={t('je.memoPh')} onChange={(e) => setH({ memo: e.target.value })} />
              </label>
            </div>
          </SectionCard>

          <SectionCard title={t('erp.section.lines')} right={<span className="text-sm text-muted max-sm:hidden">{t('je.enterAdds')}</span>}>
            <ul className="divide-y divide-line">
              {lines.map((l, i) => {
                const lp = lineProblems(l);
                return (
                  <li key={l.key} data-testid="je-line" className={clsx('px-4 py-3', lp.length > 0 && 'bg-crit-bg/40')}>
                    <div className="grid grid-cols-2 items-end gap-3 md:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)_132px_132px_44px]">
                      <div className="col-span-2 min-w-0 md:col-span-1">
                        <Combobox<AccountHit> id={`jl-${l.key}-acct`} label={t('je.accountN', { n: i + 1 })} text={l.text}
                          onText={(s) => setL(l.key, { text: s, ...(l.acct_code ? { acct_code: '' } : {}) })}
                          search={acctOpts} placeholder={t('je.accountPh')} noMatch={t('je.noAccount')}
                          onSelect={(o) => setL(l.key, { acct_code: o.value, text: o.label })} />
                      </div>
                      <label className="col-span-2 block text-xs font-medium text-muted md:col-span-1">{t('je.lineMemo')}
                        <input id={`jl-${l.key}-memo`} dir="auto" className="input mt-1 text-[15px] text-ink" value={l.memo} onChange={(e) => setL(l.key, { memo: e.target.value })} onKeyDown={enterAdds} />
                      </label>
                      <label className="block text-xs font-medium text-muted">{t('erp.col.debit')}
                        <input id={`jl-${l.key}-debit`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.debit}
                          onChange={(e) => setL(l.key, { debit: e.target.value, ...(e.target.value.trim() ? { credit: '' } : {}) })} onKeyDown={enterAdds} />
                      </label>
                      <label className="block text-xs font-medium text-muted">{t('erp.col.credit')}
                        <input id={`jl-${l.key}-credit`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.credit}
                          onChange={(e) => setL(l.key, { credit: e.target.value, ...(e.target.value.trim() ? { debit: '' } : {}) })} onKeyDown={enterAdds} />
                      </label>
                      <div className="col-span-2 flex min-h-[44px] items-center justify-end md:col-span-1">
                        <button type="button" onClick={() => removeLine(l.key)} aria-label={t('je.removeLine', { n: i + 1 })} className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg">
                          <Trash2 className="h-4 w-4" aria-hidden />
                        </button>
                      </div>
                    </div>
                    {lp.map((p, k) => <p key={k} className="mt-1 flex items-start gap-1 text-[13px] text-crit-fg"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{p.message}</p>)}
                  </li>
                );
              })}
            </ul>
            <div className="flex flex-col gap-3 border-t border-line sm:flex-row sm:items-start sm:justify-between">
              <div className="flex flex-wrap items-center gap-2 p-4">
                <Button variant="secondary" onClick={() => addLine()} id="je-add-line"><Plus className="h-4 w-4" aria-hidden /> {t('je.addLine')}</Button>
                {removed && <span className="text-sm text-muted" role="status">{t('je.lineRemoved')} <button type="button" className="font-medium text-primary underline" onClick={undoRemove}>{t('je.undo')}</button></span>}
              </div>
              <DcTotals debit={debit} credit={credit} currency={currency} />
            </div>
          </SectionCard>
        </div>

        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('je.postTitle')}>
            <div className="space-y-3 p-5">
              {!filled.length ? <p className="text-sm text-muted">{t('je.previewEmpty')}</p>
                : !preview ? <p className="text-sm text-muted">{t('je.checking')}</p>
                : preview.errors.length ? <p className="text-sm text-muted" data-testid="je-preview">{t('je.previewErrors', { count: preview.errors.length })}</p>
                : needsApproval ? (
                  <div data-testid="je-preview" className="rounded-btn border border-warn-fg/30 bg-warn-bg p-3 text-sm text-warn-fg">
                    <p className="font-semibold">{t('je.needsApproval')}</p>
                    {checks.map((c, k) => <p key={k} dir="auto" className="mt-1">{c.message}</p>)}
                    <ul className="mt-1 list-disc space-y-0.5 ps-5">{[...new Set(checks.map((c) => c.approver_name))].map((n) => <li key={n}>{t('je.approver', { name: n })}</li>)}</ul>
                  </div>
                ) : <p data-testid="je-preview" className="flex items-center gap-2 rounded-btn bg-ok-bg p-3 text-sm font-medium text-ok-fg"><Check className="h-4 w-4" aria-hidden />{t('je.postsNow')}</p>}
              {needsApproval && (
                <label className="block text-xs font-medium text-muted">{t('je.reason')} <span className="text-crit-fg">*</span>
                  <textarea id="je-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} placeholder={t('je.reasonPh')}
                    onChange={(e) => { setReason(e.target.value); setReasonErr(null); }} aria-invalid={Boolean(reasonErr)} aria-describedby={reasonErr ? 'je-reason-err' : undefined} />
                  {reasonErr && <span id="je-reason-err" className="mt-1 block text-crit-fg">{reasonErr}</span>}
                </label>
              )}
              <div className="flex flex-col gap-2">
                <Button variant="primary" id="je-post" className="w-full" onClick={() => save(true)} disabled={Boolean(postReason) || busy !== null || !company} disabledReason={postReason}>
                  {busy === 'post' ? t('je.posting') : needsApproval ? t('je.submitForApproval') : t('je.post')}
                </Button>
                <Button variant="secondary" id="je-save" className="w-full" onClick={() => save(false)} disabled={Boolean(blocked) || busy !== null || !company || !filled.length}>
                  {busy === 'save' ? t('je.saving') : t('je.saveDraft')}
                </Button>
                <Link to={id ? `/financials/journals/drafts/${company}/${id}` : '/financials/journals'} onClick={back} className="inline-flex min-h-[44px] items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('je.cancelEdit')}</Link>
              </div>
            </div>
          </SectionCard>
          {lastRej && info?.state === 'rejected' && (
            <section className="card border-crit-fg/40 p-5 text-sm" data-testid="je-rejected-card">
              <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('je.rejectedBy', { name: lastRej.decided_by_name ?? '—', when: fmtWhen(lastRej.decided_at) })}</p>
              {lastRej.note && <blockquote dir="auto" className="mt-2 border-s-4 border-line-strong ps-3 italic text-ink-2">“{lastRej.note}”</blockquote>}
              <p className="mt-2 text-muted">{t('je.fixAndResubmit')}</p>
            </section>
          )}
          {setup.data?.my_limit != null && <p className="px-1 text-sm text-muted">{t('je.myLimit', { amount: fmtMoney(setup.data.my_limit, currency) })}</p>}
        </aside>
      </div>
    </div>
  );
}

// ---------- Draft page (edit when allowed, otherwise read-only with approval) ----------
export function JournalDraftPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const did = Number(id);
  const q = useJeDraftInfo(company, did);
  let body: ReactNode;
  if (q.isLoading) body = <PageLoading />;
  else if (q.error) body = <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>;
  else if (!q.data) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  else if (q.data.can_edit) {
    const d = q.data;
    body = <JournalForm key={`${d.draft_id}-${d.state}`} company={company} info={d} initial={{
      id: d.draft_id,
      header: { ref_date: d.ref_date ?? todayIso(), due_date: d.due_date ?? '', memo: d.memo ?? '', ref1: d.ref1 ?? '' },
      lines: d.lines.map((l) => ({ key: `j${++lineSeq}`, acct_code: l.acct_code ?? '', text: l.acct_code ? `${l.acct_code} · ${l.acct_name ?? ''}` : '',
        debit: Number(l.debit) ? String(Number(l.debit)) : '', credit: Number(l.credit) ? String(Number(l.credit)) : '', memo: l.memo ?? '' })),
    }} />;
  } else body = <JournalDraftView info={q.data} onChanged={() => q.refetch()} />;
  if (q.isLoading || q.error || !q.data) return <RequireModule module="financials"><JeHeader title={t('je.titleDraft', { n: id })} />{body}</RequireModule>;
  return <RequireModule module="financials">{body}</RequireModule>;
}

function JournalDraftView({ info, onChanged }: { info: JeDraftInfo; onChanged: () => void }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const [cancelOpen, setCancelOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const cur = info.currency ?? '';
  const debit = round2(info.lines.reduce((s, l) => s + Number(l.debit), 0));
  const credit = round2(info.lines.reduce((s, l) => s + Number(l.credit), 0));
  const refresh = (msg?: string) => {
    if (msg) setFlash(msg);
    qc.invalidateQueries({ queryKey: ['approval-inbox'] });
    qc.invalidateQueries({ queryKey: ['erp-list'] });
    onChanged();
  };
  async function cancel() {
    setErr(null);
    if (!note.trim()) { setErr(t('je.cancelNoteNeeded')); return; }
    setBusy(true);
    try { await jeCancel(info.company_code, info.draft_id, note.trim()); setCancelOpen(false); refresh(t('je.flash.cancelled')); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <div>
      <JeHeader title={t('je.titleDraft', { n: info.draft_id })} pills={<><JeStatePill state={info.state} /><span className="pill pill-info">Super ERP</span><LiveBadge live /></>}
        sub={[info.memo, info.created_by_name, t('je.createdAt', { when: fmtWhen(info.created_at) })].filter(Boolean).join(' · ')}
        actions={<>
          {info.trans_id && <Link to={`/financials/journals/${info.company_code}/${info.trans_id}`} id="je-open-posted" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover"><FileText className="h-4 w-4" aria-hidden />{t('je.openPosted', { n: info.trans_id })}</Link>}
          {info.can_cancel && <Button variant="danger" id="je-cancel" onClick={() => { setCancelOpen(true); setErr(null); }}>{t('je.cancelJournal')}</Button>}
        </>} />
      <Flash text={flash} />
      <Dialog open={cancelOpen} title={t('je.cancelTitle', { n: info.draft_id })} onClose={() => setCancelOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setCancelOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="je-cancel-confirm" disabled={busy} onClick={cancel}>{t('je.cancelJournal')}</Button></>}>
        <label className="block text-xs font-medium text-muted">{t('je.note')} <span className="text-crit-fg">*</span>
          <textarea id="je-cancel-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
      </Dialog>
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[[t('erp.col.postingDate'), fmtDay(info.ref_date)], [t('erp.col.dueDate'), fmtDay(info.due_date)], [t('erp.col.ref'), info.ref1],
              [t('erp.col.remarks'), info.memo], [t('erp.col.total'), fmtMoney(info.total, cur)], [t('erp.col.source'), 'Super ERP']]} />
          </SectionCard>
          <SectionCard title={t('erp.section.lines')}>
            <div className="overflow-x-auto">
              <table className="w-full text-[14px] sm:min-w-[560px]">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.account')}</th>
                  <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('je.lineMemo')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.debit')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.credit')}</th>
                </tr></thead>
                <tbody>
                  {info.lines.map((l) => (
                    <tr key={l.line_num} className="border-t border-line align-top">
                      <td className="px-4 py-2.5"><div className="font-mono text-[13px]">{l.acct_code ?? '—'}</div><div dir="auto" className="text-xs text-muted">{l.acct_name}</div></td>
                      <td dir="auto" className="px-4 py-2.5 max-sm:hidden">{l.memo}</td>
                      <td className="num px-4 py-2.5 text-end">{Number(l.debit) ? fmtMoney(l.debit) : ''}</td>
                      <td className="num px-4 py-2.5 text-end">{Number(l.credit) ? fmtMoney(l.credit) : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="flex justify-end"><DcTotals debit={debit} credit={credit} currency={cur} /></div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <JeApprovalPanel info={info} onDone={refresh} />
          <ActivityCard items={info.activity} />
        </aside>
      </div>
    </div>
  );
}

function JeApprovalPanel({ info, onDone }: { info: JeDraftInfo; onDone: (msg: string) => void }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejOpen, setRejOpen] = useState(false);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const current = info.approvals.filter((a) => a.current);
  const mine = current.filter((a) => a.mine);
  const myLast = [...info.approvals].reverse().find((a) => a.decided_by_me && a.decision);
  const lastRej = [...info.approvals].reverse().find((a) => a.decision === 'rejected');
  const lastOk = [...info.approvals].reverse().find((a) => a.decision === 'approved');

  async function decide(decision: 'approved' | 'rejected') {
    setErr(null);
    if (decision === 'rejected' && !note.trim()) { setNoteErr(t('je.rejectNoteNeeded')); return; }
    setBusy(true);
    try {
      const r = await jeDecide(info.company_code, info.draft_id, decision, decision === 'rejected' ? note.trim() : null);
      setRejOpen(false);
      onDone(decision === 'rejected' ? t('je.flash.rejected') : r.state === 'posted' ? t('je.flash.approvedPosted', { n: r.trans_id }) : t('je.flash.stepApproved'));
    } catch (e) {
      const m = errorMessage(e);
      if (decision === 'rejected') setNoteErr(m); else setErr(m);
    } finally { setBusy(false); }
  }

  if (info.can_decide) {
    return (
      <section className="card overflow-hidden border-warn-fg/40" data-testid="je-approval-card">
        <div className="border-b border-line bg-warn-bg px-5 py-3"><h2 className="text-[15px] font-semibold text-warn-fg">{t('je.approvalNeeded')}</h2></div>
        <div className="space-y-3 p-5">
          {err && <p role="alert" className="flex items-start gap-2 text-sm text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="je-decide-error">{err}</span></p>}
          {mine.map((a) => (
            <div key={a.approval_id}>
              <p className="text-sm font-semibold">{t('so.rule.journal_amount')}</p>
              <ul className="mt-1 space-y-0.5 text-[13px] text-ink-2">{(a.detail?.checks ?? []).map((c, k) => <li key={k} dir="auto">{t('je.checkOther', { total: fmtMoney(c.value, info.currency ?? ''), limit: fmtMoney(c.limit, info.currency ?? ''), name: info.submitted_by_name ?? '—' })}</li>)}</ul>
            </div>
          ))}
          <p className="text-sm text-muted">{t('je.requested', { name: info.submitted_by_name ?? '—', when: fmtWhen(info.submitted_at) })}</p>
          {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 text-[15px] italic text-ink-2">“{info.reason}”</blockquote>}
          <div className="flex flex-col gap-2 pt-1">
            <Button variant="success" id="je-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('je.approveAndPost')}</Button>
            <Button variant="danger" id="je-reject" className="w-full" disabled={busy} onClick={() => { setRejOpen(true); setNoteErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('je.reject')}</Button>
          </div>
        </div>
        <Dialog open={rejOpen} title={t('je.rejectTitle', { n: info.draft_id })} onClose={() => setRejOpen(false)}
          footer={<><Button variant="secondary" onClick={() => setRejOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="je-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('je.reject')}</Button></>}>
          <label className="block text-xs font-medium text-muted">{t('je.rejectNote')} <span className="text-crit-fg">*</span>
            <textarea id="je-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note}
              onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} aria-invalid={Boolean(noteErr)} aria-describedby={noteErr ? 'je-reject-err' : undefined} />
          </label>
          {noteErr && <p id="je-reject-err" role="alert" className="text-sm text-crit-fg">{noteErr}</p>}
        </Dialog>
      </section>
    );
  }
  if (myLast && info.state !== 'pending_approval') {
    const ok = myLast.decision === 'approved';
    return (
      <section data-testid="je-decided-card" className={clsx('card p-5', ok ? 'border-ok-fg/40 bg-ok-bg text-ok-fg' : 'border-crit-fg/40 bg-crit-bg text-crit-fg')}>
        <p className="flex items-center gap-2 font-semibold">{ok ? <CircleCheck className="h-5 w-5" aria-hidden /> : <CircleX className="h-5 w-5" aria-hidden />}
          {t(ok ? 'je.approvedByYou' : 'je.rejectedByYou', { when: fmtWhen(myLast.decided_at) })}</p>
        {myLast.note && <p dir="auto" className="mt-2 text-sm">“{myLast.note}”</p>}
      </section>
    );
  }
  return (
    <SectionCard title={t('je.status')}>
      <div className="space-y-2 p-5 text-sm" data-testid="je-status-card">
        {info.state === 'draft' && <p className="text-muted">{t('je.statusDraft')}</p>}
        {info.state === 'pending_approval' && (
          <>
            <p className="font-semibold text-warn-fg">{t('je.waitingFor', { names: [...new Set(current.map((a) => a.approver_position_name))].join(', ') })}</p>
            <ApprovalStageNote items={current} />
            {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{info.reason}”</blockquote>}
            {info.is_submitter && <p className="text-muted">{t('je.youCantApprove')}</p>}
          </>
        )}
        {info.state === 'posted' && <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />
          {lastOk ? t('je.approvedBy', { name: lastOk.decided_by_name ?? '—', when: fmtWhen(lastOk.decided_at) }) : t('je.postedAt', { when: fmtWhen(info.posted_at) })}</p>}
        {info.state === 'rejected' && lastRej && (
          <>
            <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('je.rejectedBy', { name: lastRej.decided_by_name ?? '—', when: fmtWhen(lastRej.decided_at) })}</p>
            {lastRej.note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{lastRej.note}”</blockquote>}
          </>
        )}
        {info.state === 'cancelled' && (
          <>
            <p className="font-semibold text-crit-fg">{t('je.cancelledAt', { when: fmtWhen(info.cancelled_at) })}</p>
            {info.cancel_note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{info.cancel_note}”</blockquote>}
          </>
        )}
      </div>
    </SectionCard>
  );
}

// ---------- Drafts and approvals list ----------
export function JournalDraftsPage() {
  const { t } = useTranslation();
  const m = moduleByKey('financials')!;
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'journal_draft_list', table: 'journal_draft_list',
    select: 'company_code,draft_id,ref_date,memo,ref1,state,total,currency,created_at,trans_id',
    searchCols: ['memo', 'ref1'], numberSearchCols: ['draft_id', 'trans_id'], searchLabel: t('je.searchDrafts'),
    filters: [{ key: 'state', label: t('erp.col.status'), options: (['draft', 'pending_approval', 'rejected', 'posted', 'cancelled'] as const).map((s) => [s, t(`je.state.${s}`)]) }],
    defaultSort: { col: 'created_at', asc: false },
    rowKey: (r) => `${r.company_code}|${r.draft_id}`,
    rowLink: (r) => `/financials/journals/drafts/${r.company_code}/${r.draft_id}`,
    emptyTitle: t('je.draftsEmpty'), emptyBody: t('je.draftsEmptyBody'),
    columns: [
      { key: 'draft_id', header: t('je.col.draft'), mono: true },
      { key: 'ref_date', header: t('erp.col.postingDate'), cell: (r) => fmtDay(r.ref_date), csv: (r) => r.ref_date },
      { key: 'memo', header: t('erp.col.remarks') },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <JeStatePill state={r.state} />, csv: (r) => r.state },
      { key: 'trans_id', header: t('je.col.journal'), mono: true, hideBelow: 'md' },
      { key: 'total', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total, r.currency) },
    ],
  }), [t]);
  return (
    <RequireModule module="financials">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/financials'], [t('erp.page.journals'), '/financials/journals'], [t('je.drafts'), undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{t('je.drafts')} <LiveBadge live /></span>} desc={t('je.draftsDesc')} actions={<NewJournalAction />} />
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

/** "+ New journal entry": a link for full Financials, disabled with the read-only reason otherwise (A1). */
export function NewJournalAction() {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('financials');
  if (!canWrite) return <Button variant="primary" disabled id="new-financials" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.journal')}</Button>;
  return (
    <Link to="/financials/journals/new" id="new-journal" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">
      <Plus className="h-4 w-4" aria-hidden /> {t('erp.new.journal')}
    </Link>
  );
}
export function DraftsLink() {
  const { t } = useTranslation();
  return <Link to="/financials/journals/drafts" id="je-drafts-link" className="inline-flex min-h-[44px] items-center rounded-btn border border-line bg-surface px-4 text-[15px] font-medium text-ink hover:bg-page">{t('je.drafts')}</Link>;
}

// ---------- Journal page: reverse ----------
export function ReverseAction({ company, je, info, onDone }: { company: string; je: R; info: JournalInfo | null | undefined; onDone: (trans: number) => void }) {
  const { t } = useTranslation();
  const { readOnlyReason } = useModuleLevel('financials');
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(todayIso() < String(je.ref_date) ? String(je.ref_date) : todayIso());
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (!info) return null;
  if (!info.can_reverse) {
    const why = info.reverse_block === 'read_only' ? readOnlyReason : info.reverse_block ?? undefined;
    return <Button variant="secondary" id="je-reverse" disabled disabledReason={why} icon={<Undo2 className="h-4 w-4" aria-hidden />}>{t('je.reverse')}</Button>;
  }
  async function go() {
    setErr(null);
    if (!reason.trim()) { setErr(t('je.reverseReasonNeeded')); return; }
    setBusy(true);
    try { const r = await jeReverse(company, Number(je.trans_id), date, reason.trim()); setOpen(false); onDone(r.trans_id); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      <Button variant="danger" id="je-reverse" onClick={() => { setOpen(true); setErr(null); }} icon={<Undo2 className="h-4 w-4" aria-hidden />}>{t('je.reverse')}</Button>
      <Dialog open={open} title={t('je.reverseTitle', { n: je.number })} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="je-reverse-confirm" disabled={busy} onClick={go}>{t('je.reverse')}</Button></>}>
        <p className="text-sm text-ink-2">{t('je.reverseBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('je.reverseDate')} <span className="text-crit-fg">*</span>
          <input id="je-reverse-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} min={String(je.ref_date)} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="block text-xs font-medium text-muted">{t('je.reverseReason')} <span className="text-crit-fg">*</span>
          <textarea id="je-reverse-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg" data-testid="je-reverse-error">{err}</p>}
      </Dialog>
    </>
  );
}

import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, Check, CircleCheck, CircleX, Lock, Pencil, Plus, Trash2, X } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import i18n from '@/lib/i18n';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { SeriesPicker } from '../components/SeriesPicker';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey, type ModuleKey } from '../modules';
import type { Row } from '../api';
import { FormError, fmtWhen, sourceName, useDefaultCompany } from './BankingPages';
import {
  bpBankSave, bpChangeCancel, bpChangeDecide, bpChecks, bpSave, itemChecks, itemSave, searchSuppliers, useBpInfo, useItemInfo, useMdSetup,
  type Address, type BankAccount, type BpEval, type BpInfo, type BpKind, type BpRequest, type Contact, type FieldError, type HistoryRow, type ItemEval,
} from '../masterData';
import { ApprovalStageNote } from '../components/ApprovalStageNote';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn px-4 text-[15px] font-medium';
const primaryLink = `${linkBtn} bg-primary text-white hover:bg-primary-hover`;
const secondaryLink = `${linkBtn} border border-line bg-surface text-ink hover:bg-page`;
const labelCls = 'block text-xs font-medium text-muted';
const inputCls = 'input mt-1 text-[15px] text-ink';
const errOf = (errs: FieldError[] | undefined, f: string) => errs?.find((e) => e.field === f && e.line === undefined)?.message;
const errLine = (errs: FieldError[] | undefined, f: string, i: number) => errs?.filter((e) => e.field === f && e.line === i).map((e) => e.message);
const nn = (s: unknown) => (typeof s === 'string' ? (s.trim() === '' ? null : s.trim()) : s ?? null);

// ---------- Shared pieces ----------
function MdHeader({ module, listTo, listLabel, title, pills, sub, actions }: {
  module: ModuleKey; listTo: string; listLabel: string; title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode;
}) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  return (
    <header className="mb-4">
      <Link to={listTo} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {listLabel}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], [listLabel, listTo], [title, undefined]]} />
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

function FieldMsg({ id, message }: { id: string; message?: string }) {
  if (!message) return null;
  return <p id={`${id}-err`} role="alert" dir="auto" className="mt-1 flex items-start gap-1 text-[13px] text-crit-fg" data-testid="md-field-error"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{message}</p>;
}
function TextField({ id, label, value, onChange, error, required, type = 'text', dir, help, list, inputMode, placeholder }: {
  id: string; label: string; value: string; onChange: (v: string) => void; error?: string; required?: boolean; type?: string; dir?: 'rtl' | 'ltr' | 'auto';
  help?: string; list?: string; inputMode?: 'numeric' | 'decimal' | 'tel' | 'email'; placeholder?: string;
}) {
  return (
    <label className={labelCls} htmlFor={id}>
      {label}{required && <span className="text-crit-fg"> *</span>}
      <input id={id} type={type} dir={dir ?? 'auto'} list={list} inputMode={inputMode} placeholder={placeholder} value={value}
        onChange={(e) => onChange(e.target.value)} aria-invalid={Boolean(error)} aria-describedby={error ? `${id}-err` : undefined}
        className={clsx(inputCls, inputMode === 'decimal' || inputMode === 'numeric' ? 'num' : '', error && 'border-crit-fg')} />
      {help && !error && <span className="mt-1 block text-[12px] font-normal text-muted">{help}</span>}
      <FieldMsg id={id} message={error} />
    </label>
  );
}
function SelectField({ id, label, value, onChange, options, error, required, empty }: {
  id: string; label: string; value: string; onChange: (v: string) => void; options: Array<[string, string]>; error?: string; required?: boolean; empty?: string;
}) {
  return (
    <label className={labelCls} htmlFor={id}>
      {label}{required && <span className="text-crit-fg"> *</span>}
      <select id={id} value={value} onChange={(e) => onChange(e.target.value)} aria-invalid={Boolean(error)} aria-describedby={error ? `${id}-err` : undefined}
        className={clsx(inputCls, error && 'border-crit-fg')}>
        <option value="">{empty ?? '—'}</option>
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
      <FieldMsg id={id} message={error} />
    </label>
  );
}

/** Problems summary at the top of the form; each links to its field (spec §4.4 validation). */
function ErrorSummary({ errors, prefix }: { errors: FieldError[]; prefix: string }) {
  const { t } = useTranslation();
  if (!errors.length) return null;
  return (
    <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-crit-fg" data-testid="md-error-summary">
      <p className="font-semibold">{t('md.fixProblems', { count: errors.length })}</p>
      <ul className="mt-2 list-disc space-y-1 ps-5 text-sm">
        {errors.map((e, i) => (
          <li key={i}><a className="underline" href={`#${prefix}-${e.field}${e.line !== undefined ? `-${e.line}` : ''}`}
            onClick={(ev) => { ev.preventDefault(); document.getElementById(`${prefix}-${e.field}${e.line !== undefined ? `-${e.line}` : ''}`)?.focus(); }} dir="auto">{e.message}</a></li>
        ))}
      </ul>
    </div>
  );
}

function useLeaveGuard(dirty: boolean) {
  useEffect(() => {
    if (!dirty) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', h);
    return () => window.removeEventListener('beforeunload', h);
  }, [dirty]);
}

/** Possible-duplicate confirmation: lists the matches and needs a reason (logged in the audit log). */
function DuplicateDialog({ open, onClose, rows, onConfirm, busy, error }: {
  open: boolean; onClose: () => void; rows: Array<{ code: string; name: string; why: string; to: string }>; onConfirm: (reason: string) => void; busy: boolean; error: string | null;
}) {
  const { t } = useTranslation();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { if (open) { setReason(''); setErr(null); } }, [open]);
  return (
    <Dialog open={open} title={t('md.dup.title')} onClose={onClose}
      footer={<>
        <Button variant="secondary" onClick={onClose}>{t('md.dup.back')}</Button>
        <Button variant="primary" id="md-dup-confirm" disabled={busy} onClick={() => (reason.trim() ? onConfirm(reason.trim()) : setErr(t('md.dup.reasonNeeded')))}>{t('md.dup.saveAnyway')}</Button>
      </>}>
      <p className="text-sm text-ink-2">{t('md.dup.body')}</p>
      <ul className="divide-y divide-line rounded-btn border border-line" data-testid="md-dup-list">
        {rows.map((r) => (
          <li key={r.code} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
            <span dir="auto"><a href={r.to} target="_blank" rel="noreferrer" className="font-mono text-[13px] text-primary hover:underline">{r.code}</a> · {r.name}</span>
            <span className="pill pill-warning">{r.why}</span>
          </li>
        ))}
      </ul>
      <label className={labelCls} htmlFor="md-dup-reason">{t('md.dup.reason')} <span className="text-crit-fg">*</span>
        <textarea id="md-dup-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} onChange={(e) => { setReason(e.target.value); setErr(null); }} />
      </label>
      {(err || error) && <p role="alert" dir="auto" className="text-sm text-crit-fg">{err ?? error}</p>}
    </Dialog>
  );
}

function HistoryCard({ rows, testId }: { rows: HistoryRow[]; testId: string }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('md.history.title')}>
      {rows.length === 0 ? <p className="p-5 text-sm text-muted">{t('so.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid={testId}>
          {rows.slice(0, 30).map((h, i) => {
            const d = (h.detail ?? {}) as R;
            const changed = d.changed && typeof d.changed === 'object' ? Object.keys(d.changed) : [];
            return (
              <li key={i} className="flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', /approve|change$|create/.test(h.action) ? 'bg-ok-fg' : /reject|cancel/.test(h.action) ? 'bg-crit-fg' : 'bg-primary')} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{h.actor_name}</span>{' '}
                    {t(`md.history.${h.action}`, { defaultValue: h.action.replace(/_/g, ' '), from: d.from === null || d.from === undefined ? t('md.none') : fmtMoney(d.from), to: d.to === null || d.to === undefined ? t('md.none') : fmtMoney(d.to), change: d.change ?? '' })}</p>
                  {changed.length > 0 && <p className="text-ink-2">{t('md.history.fields', { list: changed.map((k) => t(`md.f.${k}`, { defaultValue: k })).join(', ') })}</p>}
                  {(d.reason || d.note) && <p dir="auto" className="text-ink-2">“{String(d.reason ?? d.note)}”</p>}
                  <p className="num text-xs text-muted">{fmtWhen(h.at)}</p>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </SectionCard>
  );
}

// ---------- Business partner form (new / edit) ----------
interface BpForm {
  kind: BpKind; name: string; foreign_name: string; group_code: string; currency: string; trn: string; phone: string; mobile: string; email: string;
  payment_terms: string; price_list: string; slp_code: string; credit_limit: string; city: string; country: string; active: boolean;
}
const emptyBp = (kind: BpKind, cur: string, country: string): BpForm => ({
  kind, name: '', foreign_name: '', group_code: '', currency: cur, trn: '', phone: '', mobile: '', email: '', payment_terms: '', price_list: '',
  slp_code: '', credit_limit: '', city: '', country, active: true,
});
const s = (v: unknown) => (v === null || v === undefined ? '' : String(v));

export function NewBpAction() {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('bp');
  if (!canWrite) return <Button variant="primary" disabled id="bp-new" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.bp')}</Button>;
  return <Link to="/bp/new" id="bp-new" className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.bp')}</Link>;
}

export function BpFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [sp] = useSearchParams();
  const params = useParams();
  const defCompany = useDefaultCompany();
  const company = mode === 'edit' ? params.company ?? '' : defCompany;
  const code = mode === 'edit' ? params.code ?? '' : '';
  const setup = useMdSetup(company);
  const info = useBpInfo(mode === 'edit' ? company : '', code);
  const S = setup.data;
  const [f, setF] = useState<BpForm | null>(null);
  const [series, setSeries] = useState<number | null>(null);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [addresses, setAddresses] = useState<Address[]>([]);
  const [reason, setReason] = useState('');
  const [ev, setEv] = useState<BpEval | null>(null);
  const [tried, setTried] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formErr, setFormErr] = useState<string | null>(null);
  const [dupOpen, setDupOpen] = useState(false);
  useLeaveGuard(dirty && !busy);

  useEffect(() => {
    if (f || !S) return;
    if (mode === 'new') {
      const k = (['customer', 'supplier', 'lead'] as const).find((x) => x === sp.get('kind')) ?? 'customer';
      setF(emptyBp(k, S.company_currency, S.company_country));
    } else if (info.data) {
      const p = info.data.partner;
      setF({ kind: p.kind, name: s(p.name), foreign_name: s(p.foreign_name), group_code: s(p.group_code), currency: s(p.currency), trn: s(p.trn), phone: s(p.phone),
        mobile: s(p.mobile), email: s(p.email), payment_terms: s(p.payment_terms), price_list: s(p.price_list), slp_code: s(p.slp_code),
        credit_limit: p.credit_limit === null || p.credit_limit === undefined ? '' : String(Number(p.credit_limit)), city: s(p.city), country: s(p.country), active: p.active !== false });
      setContacts(info.data.contacts.map(({ name, role, phone, mobile, email, is_default }) => ({ name, role, phone, mobile, email, is_default })));
      setAddresses(info.data.addresses);
    }
  }, [S, info.data, f, mode, sp]);

  const payload = useMemo(() => {
    if (!f) return null;
    const o: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(f)) o[k] = typeof v === 'boolean' ? v : nn(v);
    if (mode === 'edit') o.card_code = code;
    o.contacts = contacts.map((c) => ({ ...c, name: c.name ?? '' }));
    o.addresses = addresses;
    return o;
  }, [f, contacts, addresses, mode, code]);

  // live checks (duplicates, approvals, problems): 500 ms after the last change
  useEffect(() => {
    if (!payload || !company) return;
    const h = setTimeout(() => { bpChecks(company, payload).then(setEv).catch(() => undefined); }, 500);
    return () => clearTimeout(h);
  }, [payload, company]);

  const set = <K extends keyof BpForm>(k: K, v: BpForm[K]) => { setF((x) => (x ? { ...x, [k]: v } : x)); setDirty(true); };
  const errs = tried ? ev?.errors ?? [] : [];
  const req = (k: string) => Boolean(S?.bp_required.includes(k));
  const back = mode === 'edit' ? `/bp/${company}/${encodeURIComponent(code)}` : '/bp';
  const title = mode === 'edit' ? t('md.bp.editTitle', { code }) : t('md.bp.newTitle', { kind: t(`erp.kind.${f?.kind ?? 'customer'}`) });

  async function save(dupReason: string | null) {
    if (!payload) return;
    setTried(true); setFormErr(null); setBusy(true);
    try {
      const fresh = await bpChecks(company, payload);
      setEv(fresh);
      if (fresh.errors.length) { setFormErr(t('md.fixFirst')); return; }
      if (fresh.duplicates.length && !dupReason) { setDupOpen(true); return; }
      const res = await bpSave(company, payload, dupReason, nn(reason) as string | null, mode === 'new' ? series : null);
      setDirty(false); setDupOpen(false);
      qc.invalidateQueries({ queryKey: ['bp-info', company] });
      qc.invalidateQueries({ queryKey: ['bp', company] });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['md-setup', company] });
      const flash = res.credit_request
        ? t(res.created ? 'md.bp.flashCreatedPending' : 'md.bp.flashSavedPending', { code: res.card_code, names: res.credit_request.approvers.map((a) => a.approver_name).join(', ') })
        : t(res.created ? 'md.bp.flashCreated' : 'md.bp.flashSaved', { code: res.card_code });
      nav(`/bp/${company}/${encodeURIComponent(res.card_code)}`, { state: { flash } });
    } catch (e) {
      setFormErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  let body: ReactNode = null;
  if (setup.isLoading || (mode === 'edit' && info.isLoading)) body = <PageLoading />;
  else if (setup.error || info.error) body = <div className="card"><ErrorState error={setup.error ?? info.error} onRetry={() => { setup.refetch(); info.refetch(); }} /></div>;
  else if (mode === 'edit' && !info.data) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  else if (mode === 'edit' && info.data && !info.data.can_edit) body = <ReadOnlyNotice reason={info.data.edit_reason} back={back} />;
  else if (mode === 'new' && S && !Object.values(S.can_write_bp).some(Boolean)) body = <ReadOnlyNotice reason={t('erp.readOnly', { module: 'Business Partners' })} back={back} />;
  else if (f && S) {
    const kindOpts = mode === 'new' ? (['customer', 'supplier', 'lead'] as const).filter((k) => S.can_write_bp[k])
      : f.kind === 'lead' || info.data?.partner.kind === 'lead' ? (['lead', 'customer'] as const) : [f.kind];
    const groups = S.bp_groups.filter((g) => !g.kind || g.kind === (f.kind === 'supplier' ? 'S' : 'C'));
    const creditChanged = mode === 'new' ? Number(f.credit_limit || 0) > 0 : (nn(f.credit_limit) === null ? null : Number(f.credit_limit)) !== (info.data?.partner.credit_limit === null ? null : Number(info.data?.partner.credit_limit));
    const dups = ev?.duplicates ?? [];
    body = (
      <>
        <FormError message={formErr} />
        <ErrorSummary errors={errs} prefix="bp" />
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
          <div className="min-w-0 space-y-5">
            <SectionCard title={t('erp.section.general')}>
              <div className="space-y-4 p-5">
                <fieldset>
                  <legend className={labelCls}>{t('erp.col.type')} <span className="text-crit-fg">*</span></legend>
                  <div className="mt-1 flex flex-wrap gap-2" role="radiogroup">
                    {kindOpts.map((k) => (
                      <label key={k} className={clsx('inline-flex min-h-[44px] cursor-pointer items-center gap-2 rounded-btn border px-4 text-[15px]', f.kind === k ? 'border-primary bg-primary-soft text-primary-text' : 'border-line bg-surface')}>
                        <input type="radio" name="bp-kind" id={`bp-kind-${k}`} className="sr-only" checked={f.kind === k} onChange={() => { set('kind', k); if (mode === 'new') set('group_code', ''); }} />
                        {t(`erp.kind.${k}`)}
                      </label>
                    ))}
                  </div>
                  <FieldMsg id="bp-kind" message={errOf(errs, 'kind')} />
                </fieldset>
                {mode === 'new' && <SeriesPicker key={f.kind} company={company} obj={f.kind === 'supplier' ? 2002 : f.kind === 'lead' ? 2003 : 2001} value={series} onChange={setSeries} className="max-w-sm" />}
                <div className="grid gap-4 sm:grid-cols-2">
                  <TextField id="bp-name" label={t('md.f.name')} required value={f.name} onChange={(v) => set('name', v)} error={errOf(errs, 'name')} />
                  <TextField id="bp-foreign_name" label={t('md.f.foreign_name')} dir="rtl" required={req('foreign_name')} value={f.foreign_name} onChange={(v) => set('foreign_name', v)} error={errOf(errs, 'foreign_name')} />
                  <SelectField id="bp-group_code" label={t('md.f.group_code')} required={req('group_code')} value={f.group_code} onChange={(v) => set('group_code', v)}
                    options={groups.map((g) => [String(g.code), g.name])} error={errOf(errs, 'group_code')} />
                  <SelectField id="bp-currency" label={t('md.f.currency')} required value={f.currency} onChange={(v) => set('currency', v)}
                    options={S.currencies.map((c) => [c, c])} error={errOf(errs, 'currency')} />
                  <TextField id="bp-country" label={t('md.f.country')} required={req('country')} value={f.country} onChange={(v) => set('country', v.toUpperCase())} error={errOf(errs, 'country')} help={t('md.help.country')} />
                  <TextField id="bp-city" label={t('md.f.city')} required={req('city')} value={f.city} onChange={(v) => set('city', v)} error={errOf(errs, 'city')} />
                  <TextField id="bp-trn" label={t('md.f.trn')} required={req('trn')} inputMode="numeric" value={f.trn} onChange={(v) => set('trn', v)} error={errOf(errs, 'trn')}
                    help={f.country === 'AE' ? t('md.help.trn') : undefined} />
                  <TextField id="bp-email" label={t('md.f.email')} type="email" inputMode="email" required={req('email')} value={f.email} onChange={(v) => set('email', v)} error={errOf(errs, 'email')} />
                  <TextField id="bp-phone" label={t('md.f.phone')} type="tel" inputMode="tel" required={req('phone')} value={f.phone} onChange={(v) => set('phone', v)} error={errOf(errs, 'phone')} />
                  <TextField id="bp-mobile" label={t('md.f.mobile')} type="tel" inputMode="tel" required={req('mobile')} value={f.mobile} onChange={(v) => set('mobile', v)} error={errOf(errs, 'mobile')} />
                </div>
                {mode === 'edit' && (
                  <label className="inline-flex min-h-[44px] items-center gap-2 text-[15px]">
                    <input type="checkbox" id="bp-active" checked={f.active} onChange={(e) => set('active', e.target.checked)} className="h-4 w-4" /> {t('md.f.active')}
                  </label>
                )}
              </div>
            </SectionCard>

            <SectionCard title={t('md.bp.terms')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                <SelectField id="bp-payment_terms" label={t('md.f.payment_terms')} required={req('payment_terms')} value={f.payment_terms} onChange={(v) => set('payment_terms', v)}
                  options={S.payment_terms.map((p) => [String(p.code), p.name])} error={errOf(errs, 'payment_terms')} />
                <SelectField id="bp-price_list" label={t('md.f.price_list')} required={req('price_list')} value={f.price_list} onChange={(v) => set('price_list', v)}
                  options={S.price_lists.map((p) => [String(p.code), p.name])} error={errOf(errs, 'price_list')} />
                <SelectField id="bp-slp_code" label={t('md.f.slp_code')} required={req('slp_code')} value={f.slp_code} onChange={(v) => set('slp_code', v)}
                  options={S.salespeople.map((p) => [String(p.code), p.name])} error={errOf(errs, 'slp_code')} />
                <div>
                  <TextField id="bp-credit_limit" label={`${t('md.f.credit_limit')} (${f.currency || S.company_currency})`} inputMode="decimal" required={req('credit_limit')}
                    value={f.credit_limit} onChange={(v) => set('credit_limit', v)} error={errOf(errs, 'credit_limit')} />
                  {creditChanged && (ev?.approvals.length ?? 0) > 0 && (
                    <p className="mt-1 flex items-start gap-1.5 text-[13px] text-warn-fg" data-testid="bp-credit-note"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
                      <span dir="auto">{mode === 'new' ? t('md.bp.creditNoteNew', { names: ev!.approvals.map((a) => a.approver_name).join(', ') }) : t('md.bp.creditNote', { names: ev!.approvals.map((a) => a.approver_name).join(', ') })}</span></p>
                  )}
                </div>
                {creditChanged && (ev?.approvals.length ?? 0) > 0 && (
                  <label className={clsx(labelCls, 'sm:col-span-2')} htmlFor="bp-reason">{t('md.bp.creditReason')}
                    <textarea id="bp-reason" rows={2} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
                  </label>
                )}
              </div>
            </SectionCard>

            <ContactsEditor rows={contacts} errs={errs} required={req('contacts')} onChange={(r) => { setContacts(r); setDirty(true); }} />
            <AddressesEditor rows={addresses} errs={errs} required={req('addresses')} onChange={(r) => { setAddresses(r); setDirty(true); }} />
          </div>

          <aside className="space-y-5">
            <section className="card p-5" data-testid="bp-save-card">
              <h2 className="text-[15px] font-semibold">{t('md.onSave')}</h2>
              <ul className="mt-3 space-y-2 text-sm">
                {mode === 'new' && <li>{t('md.bp.codeNext', { code: S.numbering?.[f.kind] ?? '—' })}</li>}
                {(ev?.approvals ?? []).map((a, i) => <li key={i} dir="auto" className="flex items-start gap-1.5 text-warn-fg"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{a.message}</li>)}
                {ev && !ev.approvals.length && <li className="text-ok-fg">{t('md.bp.noApproval')}</li>}
              </ul>
              {dups.length > 0 && (
                <div className="mt-4 rounded-btn border border-warn-fg/40 bg-warn-bg p-3 text-sm text-warn-fg" data-testid="bp-dup-warning">
                  <p className="font-semibold">{t('md.dup.found', { count: dups.length })}</p>
                  <ul className="mt-1 space-y-1">{dups.map((d) => <li key={d.card_code} dir="auto"><span className="font-mono text-[13px]">{d.card_code}</span> · {d.name} — {t(`md.dup.match.${d.match}`)}</li>)}</ul>
                </div>
              )}
              <div className="mt-5 flex flex-col gap-2">
                <Button variant="primary" id="bp-save" disabled={busy} onClick={() => save(null)}>{mode === 'new' ? t('md.bp.create') : t('md.save')}</Button>
                <Link to={back} className={clsx(secondaryLink, 'justify-center')}>{t('md.cancel')}</Link>
              </div>
            </section>
          </aside>
        </div>
        <DuplicateDialog open={dupOpen} onClose={() => setDupOpen(false)} busy={busy} error={dupOpen ? formErr : null} onConfirm={(r) => save(r)}
          rows={dups.map((d) => ({ code: d.card_code, name: d.name, why: t(`md.dup.match.${d.match}`), to: `/bp/${company}/${encodeURIComponent(d.card_code)}` }))} />
      </>
    );
  }
  return (
    <RequireModule module="bp">
      <MdHeader module="bp" listTo={back} listLabel={mode === 'edit' ? code : t('erp.page.bp')} title={title} pills={<LiveBadge live />}
        sub={mode === 'new' ? t('md.bp.newSub') : info.data?.partner.name} />
      {body}
    </RequireModule>
  );
}

function ReadOnlyNotice({ reason, back }: { reason: string | null; back: string }) {
  const { t } = useTranslation();
  return (
    <div className="card mx-auto mt-6 max-w-lg p-8 text-center" role="alert" data-testid="md-readonly">
      <Lock className="mx-auto h-10 w-10 text-muted" aria-hidden />
      <p dir="auto" className="mt-3 text-[15px] text-ink-2">{reason}</p>
      <Link to={back} className={clsx(secondaryLink, 'mt-5')}>{t('md.back')}</Link>
    </div>
  );
}

function ContactsEditor({ rows, onChange, errs, required }: { rows: Contact[]; onChange: (r: Contact[]) => void; errs: FieldError[]; required: boolean }) {
  const { t } = useTranslation();
  const upd = (i: number, k: keyof Contact, v: unknown) => onChange(rows.map((r, j) => (j === i ? { ...r, [k]: v } : k === 'is_default' && v ? { ...r, is_default: false } : r)));
  return (
    <SectionCard title={<>{t('md.bp.contacts')}{required && <span className="text-crit-fg"> *</span>}</>}
      right={<Button variant="ghost" id="bp-add-contact" onClick={() => onChange([...rows, { name: '', is_default: rows.length === 0 }])}><Plus className="h-4 w-4" aria-hidden />{t('md.bp.addContact')}</Button>}>
      <div className="space-y-4 p-5">
        <FieldMsg id="bp-contacts" message={errOf(errs, 'contacts')} />
        {rows.length === 0 && <p className="text-sm text-muted">{t('md.bp.noContacts')}</p>}
        {rows.map((c, i) => (
          <div key={i} className="rounded-btn border border-line p-3" data-testid="bp-contact-row">
            <div className="grid gap-3 sm:grid-cols-3">
              <TextField id={`bp-contacts-${i}`} label={t('md.f.contact_name')} required value={s(c.name)} onChange={(v) => upd(i, 'name', v)} />
              <TextField id={`bp-contact-role-${i}`} label={t('md.f.role')} value={s(c.role)} onChange={(v) => upd(i, 'role', v)} />
              <TextField id={`bp-contact-email-${i}`} label={t('md.f.email')} type="email" value={s(c.email)} onChange={(v) => upd(i, 'email', v)} />
              <TextField id={`bp-contact-phone-${i}`} label={t('md.f.phone')} type="tel" value={s(c.phone)} onChange={(v) => upd(i, 'phone', v)} />
              <TextField id={`bp-contact-mobile-${i}`} label={t('md.f.mobile')} type="tel" value={s(c.mobile)} onChange={(v) => upd(i, 'mobile', v)} />
              <div className="flex items-end justify-between gap-2">
                <label className="inline-flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" checked={Boolean(c.is_default)} onChange={(e) => upd(i, 'is_default', e.target.checked)} className="h-4 w-4" /> {t('md.f.is_default')}</label>
                <Button variant="ghost" aria-label={t('md.remove')} onClick={() => onChange(rows.filter((_, j) => j !== i))}><Trash2 className="h-4 w-4" aria-hidden /></Button>
              </div>
            </div>
            {(errLine(errs, 'contacts', i) ?? []).map((m, k) => <FieldMsg key={k} id={`bp-contact-${i}-${k}`} message={m} />)}
          </div>
        ))}
      </div>
    </SectionCard>
  );
}

function AddressesEditor({ rows, onChange, errs, required }: { rows: Address[]; onChange: (r: Address[]) => void; errs: FieldError[]; required: boolean }) {
  const { t } = useTranslation();
  const upd = (i: number, k: keyof Address, v: unknown) => onChange(rows.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  return (
    <SectionCard title={<>{t('md.bp.addresses')}{required && <span className="text-crit-fg"> *</span>}</>}
      right={<Button variant="ghost" id="bp-add-address" onClick={() => onChange([...rows, { address_name: '', kind: rows.some((r) => r.kind === 'B') ? 'S' : 'B' }])}><Plus className="h-4 w-4" aria-hidden />{t('md.bp.addAddress')}</Button>}>
      <div className="space-y-4 p-5">
        <FieldMsg id="bp-addresses" message={errOf(errs, 'addresses')} />
        {rows.length === 0 && <p className="text-sm text-muted">{t('md.bp.noAddresses')}</p>}
        {rows.map((a, i) => (
          <div key={i} className="rounded-btn border border-line p-3" data-testid="bp-address-row">
            <div className="grid gap-3 sm:grid-cols-3">
              <TextField id={`bp-addresses-${i}`} label={t('md.f.address_name')} required value={s(a.address_name)} onChange={(v) => upd(i, 'address_name', v)} />
              <SelectField id={`bp-address-kind-${i}`} label={t('md.f.address_kind')} required value={a.kind} onChange={(v) => upd(i, 'kind', v)} options={[['B', t('md.billTo')], ['S', t('md.shipTo')]]} />
              <TextField id={`bp-address-street-${i}`} label={t('md.f.street')} value={s(a.street)} onChange={(v) => upd(i, 'street', v)} />
              <TextField id={`bp-address-building-${i}`} label={t('md.f.building')} value={s(a.building)} onChange={(v) => upd(i, 'building', v)} />
              <TextField id={`bp-address-city-${i}`} label={t('md.f.city')} value={s(a.city)} onChange={(v) => upd(i, 'city', v)} />
              <div className="flex items-end gap-2">
                <div className="flex-1"><TextField id={`bp-address-country-${i}`} label={t('md.f.country')} value={s(a.country)} onChange={(v) => upd(i, 'country', v.toUpperCase())} /></div>
                <Button variant="ghost" aria-label={t('md.remove')} onClick={() => onChange(rows.filter((_, j) => j !== i))}><Trash2 className="h-4 w-4" aria-hidden /></Button>
              </div>
            </div>
            {(errLine(errs, 'addresses', i) ?? []).map((m, k) => <FieldMsg key={k} id={`bp-address-${i}-${k}`} message={m} />)}
          </div>
        ))}
      </div>
    </SectionCard>
  );
}

// ---------- Business partner page extras (edit button, requests with approval, contacts, addresses, bank, history) ----------
export function BpEditAction({ company, code }: { company: string; code: string }) {
  const { t } = useTranslation();
  const info = useBpInfo(company, code);
  if (!info.data) return null;
  if (!info.data.can_edit) return <Button variant="secondary" disabled id="bp-edit" disabledReason={info.data.edit_reason ?? undefined}><Pencil className="h-4 w-4" aria-hidden /> {t('md.edit')}</Button>;
  return <Link to={`/bp/${company}/${encodeURIComponent(code)}/edit`} id="bp-edit" className={secondaryLink}><Pencil className="h-4 w-4" aria-hidden /> {t('md.edit')}</Link>;
}

export function BpDetailExtras({ company, code, onFlash }: { company: string; code: string; onFlash: (s: string) => void }) {
  const { t } = useTranslation();
  const info = useBpInfo(company, code);
  const I = info.data;
  if (info.isLoading) return null;
  if (info.error) return <div className="card"><ErrorState error={info.error} onRetry={() => info.refetch()} /></div>;
  if (!I) return null;
  return (
    <div className="space-y-5">
      <RequestsCard info={I} company={company} code={code} onFlash={onFlash} />
      <div className="grid gap-5 lg:grid-cols-2">
        <SectionCard title={t('md.bp.contacts')}>
          {I.contacts.length === 0 ? <p className="p-5 text-sm text-muted">{t('md.bp.noContacts')}</p> : (
            <ul className="divide-y divide-line" data-testid="bp-contacts">
              {I.contacts.map((c) => (
                <li key={c.contact_id} className="px-5 py-3 text-sm">
                  <p className="font-medium" dir="auto">{c.name} {c.is_default && <span className="pill pill-info ms-1">{t('md.f.is_default')}</span>}</p>
                  <p className="text-muted" dir="auto">{[c.role, c.mobile ?? c.phone, c.email].filter(Boolean).join(' · ')}</p>
                </li>
              ))}
            </ul>
          )}
        </SectionCard>
        <SectionCard title={t('md.bp.addresses')}>
          {I.addresses.length === 0 ? <p className="p-5 text-sm text-muted">{t('md.bp.noAddresses')}</p> : (
            <ul className="divide-y divide-line" data-testid="bp-addresses">
              {I.addresses.map((a) => (
                <li key={`${a.kind}-${a.address_name}`} className="px-5 py-3 text-sm">
                  <p className="font-medium" dir="auto">{a.address_name} <span className="pill pill-neutral ms-1">{a.kind === 'B' ? t('md.billTo') : t('md.shipTo')}</span></p>
                  <p className="text-muted" dir="auto">{[a.street, a.block, a.building, a.city, a.state, a.zip, a.country].filter(Boolean).join(', ') || '—'}</p>
                </li>
              ))}
            </ul>
          )}
        </SectionCard>
      </div>
      {I.bank_accounts !== null && <BankCard info={I} company={company} code={code} onFlash={onFlash} />}
      <HistoryCard rows={I.history} testId="bp-history" />
    </div>
  );
}

function requestText(r: BpRequest, cur: string) {
  const t = i18n.t.bind(i18n);
  if (r.kind === 'credit_limit') {
    const from = r.before?.credit_limit; const to = r.after?.credit_limit;
    return t('md.req.credit', { from: from === null || from === undefined ? t('md.none') : fmtMoney(from, cur), to: to === null || to === undefined ? t('md.none') : fmtMoney(to, cur) });
  }
  if (!r.after) return t('md.req.bankHidden');
  const a = r.after as R;
  return t(r.bp_bank_id && r.state === 'pending_approval' ? 'md.req.bankChange' : 'md.req.bank', { bank: a.bank_name, acc: a.iban ?? a.account_no ?? '' });
}

function RequestsCard({ info, company, code, onFlash }: { info: BpInfo; company: string; code: string; onFlash: (s: string) => void }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [rej, setRej] = useState<BpRequest | null>(null);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const cur = info.partner.currency ?? '';
  if (!info.requests.length) return null;
  async function act(r: BpRequest, fn: () => Promise<{ state: string }>) {
    setBusy(r.request_id); setErr(null);
    try {
      const res = await fn();
      qc.invalidateQueries({ queryKey: ['bp-info', company, code] });
      qc.invalidateQueries({ queryKey: ['bp', company, code] });
      qc.invalidateQueries({ queryKey: ['inbox'] });
      qc.invalidateQueries({ queryKey: ['approval-inbox'] });
      onFlash(t(`md.req.flash.${res.state}`, { what: requestText(r, cur) }));
      setRej(null);
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(null); }
  }
  return (
    <SectionCard title={t('md.req.title')}>
      {err && <p role="alert" dir="auto" className="mx-5 mt-4 rounded-btn border border-crit-fg/30 bg-crit-bg p-3 text-sm text-crit-fg" data-testid="bp-req-error">{err}</p>}
      <ul className="divide-y divide-line" data-testid="bp-requests">
        {info.requests.map((r) => {
          const current = r.approvals.filter((a) => a.current);
          const mine = current.some((a) => a.mine) && !r.requested_by_me;
          const lastDecided = [...r.approvals].reverse().find((a) => a.decision);
          return (
            <li key={r.request_id} className={clsx('px-5 py-4 text-sm', r.state === 'pending_approval' && 'bg-warn-bg/40')} data-testid={`bp-request-${r.request_id}`}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0 space-y-1">
                  <p className="font-medium" dir="auto">{requestText(r, cur)}</p>
                  <p className="text-muted">{t('so.approval.requested', { name: r.requested_by_name ?? '—', when: fmtWhen(r.requested_at) })}</p>
                  {r.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{r.reason}”</blockquote>}
                  {r.state === 'pending_approval' && <p className="font-medium text-warn-fg">{t('so.approval.waitingFor', { names: [...new Set(current.map((a) => a.approver_position_name))].join(', ') })}</p>}
                  {r.state === 'pending_approval' && <ApprovalStageNote items={current} />}
                  {r.state === 'pending_approval' && r.requested_by_me && <p className="text-muted">{t('md.req.youCantApprove')}</p>}
                  {r.state !== 'pending_approval' && (
                    <p className={clsx('flex items-center gap-1.5 font-medium', r.state === 'approved' ? 'text-ok-fg' : 'text-crit-fg')}>
                      {r.state === 'approved' ? <CircleCheck className="h-4 w-4" aria-hidden /> : <CircleX className="h-4 w-4" aria-hidden />}
                      {t(`md.req.state.${r.state}`, { name: r.decided_by_name ?? lastDecided?.decided_by_name ?? '—', when: fmtWhen(r.decided_at) })}
                    </p>
                  )}
                  {r.note && r.state !== 'pending_approval' && <p dir="auto" className="text-ink-2">“{r.note}”</p>}
                </div>
                <span className={clsx('pill', r.state === 'approved' ? 'pill-ok' : r.state === 'pending_approval' ? 'pill-warning' : r.state === 'rejected' ? 'pill-crit' : 'pill-neutral')}>{t(`md.req.pill.${r.state}`)}</span>
              </div>
              {r.state === 'pending_approval' && (
                <div className="mt-3 flex flex-wrap gap-2">
                  {mine && <Button variant="success" id={`bp-approve-${r.request_id}`} disabled={busy !== null} icon={<Check className="h-4 w-4" aria-hidden />}
                    onClick={() => act(r, () => bpChangeDecide(company, r.request_id, 'approved', null))}>{t('md.req.approve')}</Button>}
                  {mine && <Button variant="danger" id={`bp-reject-${r.request_id}`} disabled={busy !== null} icon={<X className="h-4 w-4" aria-hidden />}
                    onClick={() => { setRej(r); setNote(''); setNoteErr(null); }}>{t('so.approval.reject')}</Button>}
                  {(r.requested_by_me || info.can_edit) && !mine && <Button variant="secondary" id={`bp-withdraw-${r.request_id}`} disabled={busy !== null}
                    onClick={() => act(r, () => bpChangeCancel(company, r.request_id, null))}>{t('md.req.withdraw')}</Button>}
                </div>
              )}
            </li>
          );
        })}
      </ul>
      <Dialog open={Boolean(rej)} title={t('md.req.rejectTitle', { code })} onClose={() => setRej(null)}
        footer={<>
          <Button variant="secondary" onClick={() => setRej(null)}>{t('so.keep')}</Button>
          <Button variant="danger" id="bp-reject-confirm" disabled={busy !== null} onClick={() => (note.trim() ? act(rej!, () => bpChangeDecide(company, rej!.request_id, 'rejected', note.trim())) : setNoteErr(t('inv.rejectNoteNeeded')))}>{t('so.approval.reject')}</Button>
        </>}>
        <label className={labelCls} htmlFor="bp-reject-note">{t('so.approval.rejectNote')} <span className="text-crit-fg">*</span>
          <textarea id="bp-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} />
        </label>
        {noteErr && <p role="alert" className="text-sm text-crit-fg">{noteErr}</p>}
      </Dialog>
    </SectionCard>
  );
}

function BankCard({ info, company, code, onFlash }: { info: BpInfo; company: string; code: string; onFlash: (s: string) => void }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [edit, setEdit] = useState<BankAccount | 'new' | null>(null);
  const [f, setF] = useState({ bank_name: '', account_no: '', iban: '', swift: '', holder: '', reason: '' });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const rows = info.bank_accounts ?? [];
  const open = (row: BankAccount | 'new') => {
    setEdit(row); setErr(null);
    setF(row === 'new' ? { bank_name: '', account_no: '', iban: '', swift: '', holder: info.partner.name ?? '', reason: '' }
      : { bank_name: row.bank_name, account_no: row.account_no ?? '', iban: row.iban ?? '', swift: row.swift ?? '', holder: row.holder ?? '', reason: '' });
  };
  async function save() {
    setBusy(true); setErr(null);
    try {
      const res = await bpBankSave(company, code, { ...(edit !== 'new' && edit ? { bp_bank_id: edit.bp_bank_id } : {}), ...f });
      qc.invalidateQueries({ queryKey: ['bp-info', company, code] });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      setEdit(null);
      onFlash(res.state === 'pending_approval' ? t('md.bank.pending', { code }) : t('md.bank.saved', { code }));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <SectionCard title={t('md.bank.title')} right={info.can_bank && !edit ? <Button variant="ghost" id="bp-bank-add" onClick={() => open('new')}><Plus className="h-4 w-4" aria-hidden />{t('md.bank.add')}</Button> : undefined}>
      {info.last_bank_change && <p className="mx-5 mt-4 flex items-start gap-1.5 text-[13px] text-warn-fg"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{t('md.bank.lastChange', { when: fmtDay(info.last_bank_change) })}</p>}
      {rows.length === 0 && !edit ? <p className="p-5 text-sm text-muted">{t('md.bank.none')}</p> : (
        <ul className="divide-y divide-line" data-testid="bp-bank-list">
          {rows.map((b) => (
            <li key={b.bp_bank_id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm">
              <div className="min-w-0">
                <p className="font-medium" dir="auto">{b.bank_name} {!b.active && <span className="pill pill-neutral ms-1">{t('erp.status.inactive')}</span>}</p>
                <p className="font-mono text-[13px] text-ink-2">{b.iban ?? b.account_no}{b.swift ? ` · ${b.swift}` : ''}</p>
                <p className="text-xs text-muted" dir="auto">{b.holder} · {sourceName(b.source)}</p>
              </div>
              {info.can_bank && b.source !== 'sap' && !edit && <Button variant="secondary" onClick={() => open(b)}>{t('md.bank.change')}</Button>}
            </li>
          ))}
        </ul>
      )}
      {edit && (
        <div className="border-t border-line p-5" data-testid="bp-bank-form">
          {err && <p role="alert" dir="auto" className="mb-3 text-sm text-crit-fg" data-testid="bp-bank-error">{err}</p>}
          <div className="grid gap-3 sm:grid-cols-2">
            <TextField id="bpb-bank" label={t('md.bank.bank')} required value={f.bank_name} onChange={(v) => setF({ ...f, bank_name: v })} />
            <TextField id="bpb-holder" label={t('md.bank.holder')} value={f.holder} onChange={(v) => setF({ ...f, holder: v })} />
            <TextField id="bpb-iban" label="IBAN" value={f.iban} onChange={(v) => setF({ ...f, iban: v })} />
            <TextField id="bpb-acc" label={t('md.bank.account')} value={f.account_no} onChange={(v) => setF({ ...f, account_no: v })} />
            <TextField id="bpb-swift" label="SWIFT" value={f.swift} onChange={(v) => setF({ ...f, swift: v })} />
            {info.bank_needs_approval && <TextField id="bpb-reason" label={t('md.bank.reason')} value={f.reason} onChange={(v) => setF({ ...f, reason: v })} />}
          </div>
          <p className="mt-3 text-[13px] text-muted">{info.bank_needs_approval ? t('md.bank.needsApproval') : t('md.bank.appliesNow')}</p>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button variant="primary" id="bpb-save" disabled={busy} onClick={save}>{info.bank_needs_approval ? t('md.bank.send') : t('md.bank.save')}</Button>
            <Button variant="secondary" onClick={() => setEdit(null)}>{t('md.cancel')}</Button>
          </div>
        </div>
      )}
    </SectionCard>
  );
}

// ---------- Items ----------
export function NewItemAction() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const setup = useMdSetup(company);
  const { readOnlyReason } = useModuleLevel('inventory');
  if (!setup.data?.can_write_items) {
    return <Button variant="primary" disabled id="item-new" disabledReason={setup.data ? readOnlyReason ?? t('md.item.readOnly') : undefined}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.item')}</Button>;
  }
  return <Link to="/items/new" id="item-new" className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.item')}</Link>;
}
export function ItemEditAction({ company, code }: { company: string; code: string }) {
  const { t } = useTranslation();
  const info = useItemInfo(company, code);
  if (!info.data) return null;
  if (!info.data.can_edit) return <Button variant="secondary" disabled id="item-edit" disabledReason={info.data.edit_reason ?? undefined}><Pencil className="h-4 w-4" aria-hidden /> {t('md.edit')}</Button>;
  return <Link to={`/items/${company}/${encodeURIComponent(code)}/edit`} id="item-edit" className={secondaryLink}><Pencil className="h-4 w-4" aria-hidden /> {t('md.edit')}</Link>;
}
export function ItemChangesCard({ company, code }: { company: string; code: string }) {
  const info = useItemInfo(company, code);
  if (!info.data) return null;
  return <HistoryCard rows={info.data.history} testId="item-changes" />;
}

interface ItemForm {
  item_code: string; name: string; foreign_name: string; group_code: string; firm_code: string; barcode: string; hs_code: string; moq: string;
  pcs_20gp: string; pcs_40gp: string; pcs_40hq: string; sourcing_type: string; preferred_supplier: string; supplier_part_no: string; tax_code: string;
  sales_uom: string; purchase_uom: string; inventory_uom: string; is_stock: boolean; is_sold: boolean; is_bought: boolean; tracking: 'none' | 'batch' | 'serial'; active: boolean;
}
const emptyItem = (): ItemForm => ({
  item_code: '', name: '', foreign_name: '', group_code: '', firm_code: '', barcode: '', hs_code: '', moq: '', pcs_20gp: '', pcs_40gp: '', pcs_40hq: '',
  sourcing_type: '', preferred_supplier: '', supplier_part_no: '', tax_code: '', sales_uom: '', purchase_uom: '', inventory_uom: '',
  is_stock: true, is_sold: true, is_bought: true, tracking: 'none', active: true,
});

export function ItemFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const defCompany = useDefaultCompany();
  const company = mode === 'edit' ? params.company ?? '' : defCompany;
  const code = mode === 'edit' ? params.code ?? '' : '';
  const setup = useMdSetup(company);
  const info = useItemInfo(mode === 'edit' ? company : '', code);
  const S = setup.data;
  const [f, setF] = useState<ItemForm | null>(null);
  const [itemSeries, setItemSeries] = useState<number | null>(null);
  const [supText, setSupText] = useState('');
  const [ev, setEv] = useState<ItemEval | null>(null);
  const [tried, setTried] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formErr, setFormErr] = useState<string | null>(null);
  const [dupOpen, setDupOpen] = useState(false);
  const first = useRef(true);
  useLeaveGuard(dirty && !busy);

  useEffect(() => {
    if (f || !S) return;
    if (mode === 'new') setF(emptyItem());
    else if (info.data) {
      const i = info.data.item;
      setF({ item_code: i.item_code, name: s(i.name), foreign_name: s(i.foreign_name), group_code: s(i.group_code), firm_code: s(i.firm_code), barcode: s(i.barcode),
        hs_code: s(i.hs_code), moq: i.moq === null ? '' : String(Number(i.moq)), pcs_20gp: s(i.pcs_20gp), pcs_40gp: s(i.pcs_40gp), pcs_40hq: s(i.pcs_40hq),
        sourcing_type: s(i.sourcing_type), preferred_supplier: s(i.preferred_supplier), supplier_part_no: s(i.supplier_part_no), tax_code: s(i.tax_code),
        sales_uom: s(i.sales_uom), purchase_uom: s(i.purchase_uom), inventory_uom: s(i.inventory_uom), is_stock: i.is_stock !== false, is_sold: i.is_sold !== false,
        is_bought: i.is_bought !== false, tracking: i.serial_managed ? 'serial' : i.batch_managed ? 'batch' : 'none', active: i.active !== false });
      setSupText(i.preferred_supplier ? `${i.preferred_supplier} · ${i.supplier_name ?? ''}` : '');
    }
  }, [S, info.data, f, mode]);

  const payload = useMemo(() => {
    if (!f) return null;
    const { tracking, ...rest } = f;
    const o: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(rest)) o[k] = typeof v === 'boolean' ? v : nn(v);
    o.batch_managed = tracking === 'batch'; o.serial_managed = tracking === 'serial';
    if (mode === 'edit') { o.edit = true; o.item_code = code; }
    return o;
  }, [f, mode, code]);
  useEffect(() => {
    if (!payload || !company) return;
    if (first.current) { first.current = false; }
    const h = setTimeout(() => { itemChecks(company, payload).then(setEv).catch(() => undefined); }, 500);
    return () => clearTimeout(h);
  }, [payload, company]);

  const set = <K extends keyof ItemForm>(k: K, v: ItemForm[K]) => { setF((x) => (x ? { ...x, [k]: v } : x)); setDirty(true); };
  // B1: with an item code series, a new item may leave the code empty and take the next code.
  const autoCode = mode === 'new' && itemSeries !== null && !f?.item_code;
  const errs = (tried ? ev?.errors ?? [] : []).filter((e) => !(autoCode && e.field === 'item_code'));
  const req = (k: string) => Boolean(S?.item_required.includes(k));
  const back = mode === 'edit' ? `/items/${company}/${encodeURIComponent(code)}` : '/items';

  async function save(dupReason: string | null) {
    if (!payload) return;
    setTried(true); setFormErr(null); setBusy(true);
    try {
      const fresh = await itemChecks(company, payload);
      setEv(fresh);
      if (fresh.errors.filter((e) => !(autoCode && e.field === 'item_code')).length) { setFormErr(t('md.fixFirst')); return; }
      if (fresh.duplicates.length && !dupReason) { setDupOpen(true); return; }
      const res = await itemSave(company, payload, dupReason, autoCode ? itemSeries : null);
      setDirty(false); setDupOpen(false);
      qc.invalidateQueries({ queryKey: ['item-info', company] });
      qc.invalidateQueries({ queryKey: ['item', company] });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      nav(`/items/${company}/${encodeURIComponent(res.item_code)}`, { state: { flash: t(res.created ? 'md.item.flashCreated' : 'md.item.flashSaved', { code: res.item_code }) } });
    } catch (e) { setFormErr(errorMessage(e)); } finally { setBusy(false); }
  }

  let body: ReactNode = null;
  if (setup.isLoading || (mode === 'edit' && info.isLoading)) body = <PageLoading />;
  else if (setup.error || info.error) body = <div className="card"><ErrorState error={setup.error ?? info.error} onRetry={() => { setup.refetch(); info.refetch(); }} /></div>;
  else if (mode === 'edit' && !info.data) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  else if (mode === 'edit' && info.data && !info.data.can_edit) body = <ReadOnlyNotice reason={info.data.edit_reason} back={back} />;
  else if (mode === 'new' && S && !S.can_write_items) body = <ReadOnlyNotice reason={t('md.item.readOnly')} back={back} />;
  else if (f && S) {
    const uomList = 'md-uoms';
    const supSearch = async (q: string): Promise<Array<ComboOption<string>>> =>
      (await searchSuppliers(company, q)).map((x) => ({ value: x.card_code, label: `${x.card_code} · ${x.name}`, data: x.card_code, meta: <span className="text-xs text-muted">{x.currency}</span> }));
    body = (
      <>
        <FormError message={formErr} />
        <ErrorSummary errors={errs} prefix="it" />
        <datalist id={uomList}>{S.uoms.map((u) => <option key={u} value={u} />)}</datalist>
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
          <div className="min-w-0 space-y-5">
            <SectionCard title={t('erp.section.general')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                {mode === 'new' && <SeriesPicker company={company} obj={4} value={itemSeries} onChange={setItemSeries} hideWhenNone label={t('num.pick.itemLabel')} id="it-series" />}
                {mode === 'new'
                  ? <TextField id="it-item_code" label={t('md.f.item_code')} required={!autoCode} value={f.item_code} onChange={(v) => set('item_code', v.toUpperCase())} error={errOf(errs, 'item_code')} help={itemSeries !== null ? t('num.pick.itemHelp') : t('md.help.itemCode')} />
                  : <div className={labelCls}>{t('md.f.item_code')}<p className="mt-2 font-mono text-[15px] text-ink">{f.item_code}</p></div>}
                <TextField id="it-name" label={t('md.f.item_name')} required value={f.name} onChange={(v) => set('name', v)} error={errOf(errs, 'name')} />
                <TextField id="it-foreign_name" label={t('md.f.foreign_name')} dir="rtl" required={req('foreign_name')} value={f.foreign_name} onChange={(v) => set('foreign_name', v)} error={errOf(errs, 'foreign_name')} />
                <SelectField id="it-group_code" label={t('md.f.item_group')} required={req('group_code')} value={f.group_code} onChange={(v) => set('group_code', v)}
                  options={S.item_groups.map((g) => [String(g.code), g.name])} error={errOf(errs, 'group_code')} />
                {S.brands.length > 0 && <SelectField id="it-firm_code" label={t('md.f.firm_code')} required={req('firm_code')} value={f.firm_code} onChange={(v) => set('firm_code', v)}
                  options={S.brands.map((g) => [String(g.code), g.name])} error={errOf(errs, 'firm_code')} />}
                <TextField id="it-barcode" label={t('md.f.barcode')} required={req('barcode')} value={f.barcode} onChange={(v) => set('barcode', v)} error={errOf(errs, 'barcode')} help={t('md.help.barcode')} />
                <TextField id="it-hs_code" label={t('md.f.hs_code')} required={req('hs_code')} value={f.hs_code} onChange={(v) => set('hs_code', v)} error={errOf(errs, 'hs_code')} help={t('md.help.hs')} />
                <SelectField id="it-tax_code" label={t('md.f.tax_code')} required={req('tax_code')} value={f.tax_code} onChange={(v) => set('tax_code', v)}
                  options={S.tax_codes.map((c) => [c.code, `${c.code} · ${c.name}`])} error={errOf(errs, 'tax_code')} />
              </div>
            </SectionCard>
            <SectionCard title={t('md.item.units')}>
              <div className="grid gap-4 p-5 sm:grid-cols-3">
                <TextField id="it-inventory_uom" label={t('md.f.inventory_uom')} list={uomList} required={req('inventory_uom')} value={f.inventory_uom} onChange={(v) => set('inventory_uom', v.toUpperCase())} error={errOf(errs, 'inventory_uom')} />
                <TextField id="it-sales_uom" label={t('md.f.sales_uom')} list={uomList} required={req('sales_uom')} value={f.sales_uom} onChange={(v) => set('sales_uom', v.toUpperCase())} error={errOf(errs, 'sales_uom')} />
                <TextField id="it-purchase_uom" label={t('md.f.purchase_uom')} list={uomList} required={req('purchase_uom')} value={f.purchase_uom} onChange={(v) => set('purchase_uom', v.toUpperCase())} error={errOf(errs, 'purchase_uom')} />
                <TextField id="it-moq" label={t('md.f.moq')} inputMode="decimal" required={req('moq')} value={f.moq} onChange={(v) => set('moq', v)} error={errOf(errs, 'moq')} />
                <TextField id="it-pcs_20gp" label={t('md.f.pcs_20gp')} inputMode="numeric" value={f.pcs_20gp} onChange={(v) => set('pcs_20gp', v)} error={errOf(errs, 'pcs_20gp')} />
                <TextField id="it-pcs_40gp" label={t('md.f.pcs_40gp')} inputMode="numeric" value={f.pcs_40gp} onChange={(v) => set('pcs_40gp', v)} error={errOf(errs, 'pcs_40gp')} />
                <TextField id="it-pcs_40hq" label={t('md.f.pcs_40hq')} inputMode="numeric" value={f.pcs_40hq} onChange={(v) => set('pcs_40hq', v)} error={errOf(errs, 'pcs_40hq')} />
              </div>
            </SectionCard>
            <SectionCard title={t('md.item.sourcing')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                <SelectField id="it-sourcing_type" label={t('md.f.sourcing_type')} required={req('sourcing_type')} value={f.sourcing_type} onChange={(v) => set('sourcing_type', v)}
                  options={S.sourcing_types.map((x) => [x, x])} error={errOf(errs, 'sourcing_type')} />
                <div>
                  <Combobox id="it-preferred_supplier" label={t('md.f.preferred_supplier')} text={supText} required={req('preferred_supplier')}
                    onText={(v) => { setSupText(v); if (!v.trim()) set('preferred_supplier', ''); }} onSelect={(o) => { setSupText(o.label); set('preferred_supplier', o.value); }}
                    search={supSearch} error={errOf(errs, 'preferred_supplier')} />
                </div>
                <TextField id="it-supplier_part_no" label={t('md.f.supplier_part_no')} required={req('supplier_part_no')} value={f.supplier_part_no} onChange={(v) => set('supplier_part_no', v)} error={errOf(errs, 'supplier_part_no')} />
              </div>
            </SectionCard>
            <SectionCard title={t('md.item.flags')}>
              <div className="space-y-4 p-5">
                <div className="flex flex-wrap gap-4">
                  {(['is_stock', 'is_sold', 'is_bought'] as const).map((k) => (
                    <label key={k} className="inline-flex min-h-[44px] items-center gap-2 text-[15px]"><input type="checkbox" id={`it-${k}`} checked={f[k]} onChange={(e) => set(k, e.target.checked)} className="h-4 w-4" /> {t(`md.f.${k}`)}</label>
                  ))}
                  {mode === 'edit' && <label className="inline-flex min-h-[44px] items-center gap-2 text-[15px]"><input type="checkbox" id="it-active" checked={f.active} onChange={(e) => set('active', e.target.checked)} className="h-4 w-4" /> {t('md.f.active')}</label>}
                </div>
                <FieldMsg id="it-is_stock" message={errOf(errs, 'is_stock')} />
                <fieldset>
                  <legend className={labelCls}>{t('md.f.tracking')}</legend>
                  <div className="mt-1 flex flex-wrap gap-2">
                    {(['none', 'batch', 'serial'] as const).map((k) => (
                      <label key={k} className={clsx('inline-flex min-h-[44px] cursor-pointer items-center gap-2 rounded-btn border px-4 text-[15px]', f.tracking === k ? 'border-primary bg-primary-soft text-primary-text' : 'border-line bg-surface')}>
                        <input type="radio" name="it-tracking" id={`it-tracking-${k}`} className="sr-only" checked={f.tracking === k} onChange={() => set('tracking', k)} />{t(`md.tracking.${k}`)}
                      </label>
                    ))}
                  </div>
                  <FieldMsg id="it-batch_managed" message={errOf(errs, 'batch_managed') ?? errOf(errs, 'serial_managed')} />
                </fieldset>
              </div>
            </SectionCard>
          </div>
          <aside className="space-y-5">
            <section className="card p-5" data-testid="item-save-card">
              <h2 className="text-[15px] font-semibold">{t('md.onSave')}</h2>
              <p className="mt-2 text-sm text-ink-2">{mode === 'new' ? t('md.item.saveNew') : t('md.item.saveEdit')}</p>
              {(ev?.duplicates.length ?? 0) > 0 && (
                <div className="mt-4 rounded-btn border border-warn-fg/40 bg-warn-bg p-3 text-sm text-warn-fg" data-testid="item-dup-warning">
                  <p className="font-semibold">{t('md.dup.foundItem')}</p>
                  <ul className="mt-1 space-y-1">{ev!.duplicates.map((d) => <li key={d.item_code} dir="auto"><span className="font-mono text-[13px]">{d.item_code}</span> · {d.name}</li>)}</ul>
                </div>
              )}
              <div className="mt-5 flex flex-col gap-2">
                <Button variant="primary" id="item-save" disabled={busy} onClick={() => save(null)}>{mode === 'new' ? t('md.item.create') : t('md.save')}</Button>
                <Link to={back} className={clsx(secondaryLink, 'justify-center')}>{t('md.cancel')}</Link>
              </div>
            </section>
          </aside>
        </div>
        <DuplicateDialog open={dupOpen} onClose={() => setDupOpen(false)} busy={busy} error={dupOpen ? formErr : null} onConfirm={(r) => save(r)}
          rows={(ev?.duplicates ?? []).map((d) => ({ code: d.item_code, name: d.name, why: t('md.dup.match.supplier_part_no'), to: `/items/${company}/${encodeURIComponent(d.item_code)}` }))} />
      </>
    );
  }
  return (
    <RequireModule module="inventory">
      <MdHeader module="inventory" listTo={back} listLabel={mode === 'edit' ? code : t('erp.page.items')} title={mode === 'edit' ? t('md.item.editTitle', { code }) : t('md.item.newTitle')}
        pills={<LiveBadge live />} sub={mode === 'new' ? t('md.item.newSub') : info.data?.item.name} />
      {body}
    </RequireModule>
  );
}

// ---------- Lists: Trademark Master (read-only, as migrated) and partner change requests ----------
function ListFrame({ module, title, desc, children, note }: { module: ModuleKey; title: string; desc: string; children: ReactNode; note?: ReactNode }) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  return (
    <RequireModule module={module}>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], [title, undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} />
      {note}
      {children}
    </RequireModule>
  );
}

export function TrademarksPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'trademark', table: 'trademark', select: 'company_code,code,trademark_no,description,class,country,valid_from,valid_to',
    searchCols: ['code', 'trademark_no', 'description', 'country'], searchLabel: t('md.tm.search'),
    defaultSort: { col: 'code', asc: true }, rowKey: (r) => `${r.company_code}|${r.code}`,
    columns: [
      { key: 'code', header: t('erp.col.code'), mono: true },
      { key: 'trademark_no', header: t('md.tm.no'), mono: true, hideBelow: 'sm' },
      { key: 'description', header: t('erp.col.description'), cell: (r) => <span dir="auto">{r.description ?? '—'}</span> },
      { key: 'class', header: t('md.tm.class'), align: 'end', hideBelow: 'md' },
      { key: 'country', header: t('md.f.country'), hideBelow: 'md' },
      { key: 'valid_to', header: t('md.tm.validTo'), cell: (r) => <span className={r.valid_to && r.valid_to < new Date().toISOString().slice(0, 10) ? 'font-semibold text-crit-fg' : ''}>{fmtDay(r.valid_to)}</span> },
    ],
    emptyTitle: t('md.tm.empty'), emptyBody: t('md.tm.emptyBody'),
  }), [t]);
  return (
    <ListFrame module="bp" title={t('md.tm.title')} desc={t('md.tm.desc')}
      note={<p className="mb-4 rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-ink-2" data-testid="tm-note">{t('md.tm.note')}</p>}>
      <ListScreen config={cfg} />
    </ListFrame>
  );
}

export function BpChangesPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'bp_change_request_list', table: 'bp_change_request_list',
    select: 'company_code,request_id,card_code,card_name,kind,state,after,before,currency,requested_at,requested_by_name,decided_by_name,decided_at',
    searchCols: ['card_code', 'card_name', 'requested_by_name'], searchLabel: t('erp.search.bp'),
    filters: [
      { key: 'kind', label: t('md.req.kind'), options: [['credit_limit', t('md.req.kinds.credit_limit')], ['bank', t('md.req.kinds.bank')]] },
      { key: 'state', label: t('erp.col.status'), options: (['pending_approval', 'approved', 'rejected', 'cancelled'] as const).map((s2) => [s2, t(`md.req.pill.${s2}`)]) },
    ],
    defaultSort: { col: 'requested_at', asc: false }, rowKey: (r) => `${r.company_code}|${r.request_id}`,
    rowLink: (r) => `/bp/${r.company_code}/${encodeURIComponent(r.card_code)}`,
    columns: [
      { key: 'card_code', header: t('erp.col.code'), mono: true },
      { key: 'card_name', header: t('erp.col.name'), cell: (r) => <span dir="auto">{r.card_name}</span> },
      { key: 'kind', header: t('md.req.kind'), cell: (r) => t(`md.req.kinds.${r.kind}`) },
      { key: 'after', header: t('md.req.newValue'), sortable: false, align: 'end',
        cell: (r) => (r.kind === 'credit_limit' ? fmtMoney(r.after?.credit_limit, r.currency) : <span className="font-mono text-[13px]">{r.after?.iban ?? r.after?.account_no ?? '—'}</span>),
        csv: (r) => (r.kind === 'credit_limit' ? r.after?.credit_limit : r.after?.iban ?? r.after?.account_no) },
      { key: 'requested_by_name', header: t('md.req.requestedBy'), hideBelow: 'md' },
      { key: 'requested_at', header: t('erp.col.date'), hideBelow: 'sm', cell: (r) => fmtWhen(r.requested_at) },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <span className={clsx('pill', r.state === 'approved' ? 'pill-ok' : r.state === 'pending_approval' ? 'pill-warning' : r.state === 'rejected' ? 'pill-crit' : 'pill-neutral')}>{t(`md.req.pill.${r.state}`)}</span>, csv: (r) => r.state },
    ],
    emptyTitle: t('md.req.empty'),
  }), [t]);
  return <ListFrame module="bp" title={t('md.req.listTitle')} desc={t('md.req.listDesc')}><ListScreen config={cfg} /></ListFrame>;
}


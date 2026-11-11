import { useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Check, KeyRound, Pencil, Plus, Save, Send, Trash2, Upload, X } from 'lucide-react';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { Fields, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { Dialog } from '../components/Dialog';
import { todayIso } from '../journal';
import {
  adminSettingSave, sanaSave, companyCancel, companyDecide, companySubmit, fxImport, fxSave, parseRatesCsv, ruleDelete, ruleSave,
  uploadLogo, useSanaConfig, useSanaSetup, useCompanyInfo, useFxSetup, useTemplates,
  type ApprovalRule, type FxRow, type LimitKind, type Profile, type RuleSpec,
} from '../admin';
import { AdminFrame, AuditCard, CompanyPicker, ErrorBox, Flash, ReadOnlyNote, useAdminCompany } from './AdminPages';
import { ApprovalStageNote } from '../components/ApprovalStageNote';
import { SystemCurrencyCard } from './ConversionPages';
import { SANA_LANGUAGES } from '@/features/sana/voice';

const OBJ_LABEL: Record<number, string> = {
  17: 'Sales Order', 22: 'Purchase Order', 46: 'Outgoing Payment', 30: 'Journal Entry', 59: 'Goods Receipt', 60: 'Goods Issue',
  1470000065: 'Inventory Counting', 2: 'Business Partner', 14: 'A/R Credit Memo',
};

// ---------- Approval templates ----------
interface RuleForm { rule_id: number | null; rule_code: string; obj_type: number; position_code: string; limit_value: string; approver_position: string; step: string; active: boolean; note: string }

export function ApprovalTemplatesPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useTemplates(company);
  const [form, setForm] = useState<RuleForm | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [delFor, setDelFor] = useState<ApprovalRule | null>(null);
  const canWrite = Boolean(q.data?.can_write);
  const cur = q.data?.currency ?? '';

  const fmtLimit = (kind: LimitKind, v: number | null) =>
    v === null ? '—' : kind === 'pct' || kind === 'pct_any' ? `${Number(v)}%` : kind === 'days' ? t('adm.tpl.days', { n: Number(v) }) : fmtMoney(v, cur);
  const startNew = (s: RuleSpec) => { setErr(null); setForm({ rule_id: null, rule_code: s.rule_code, obj_type: s.obj_types[0], position_code: '', limit_value: '', approver_position: '', step: '1', active: true, note: '' }); };
  const startEdit = (r: ApprovalRule) => { setErr(null); setForm({ rule_id: r.rule_id, rule_code: r.rule_code, obj_type: r.obj_type, position_code: r.position_code ?? '', limit_value: r.limit_value === null ? '' : String(Number(r.limit_value)), approver_position: r.approver_position, step: String(r.step), active: r.active, note: r.note ?? '' }); };

  async function save() {
    if (!form) return;
    setErr(null); setFlash(null); setBusy(true);
    try {
      await ruleSave(company, { ...form, position_code: form.position_code || null, limit_value: form.limit_value || null, step: Number(form.step) || 1 });
      setFlash(form.rule_id ? t('adm.tpl.changed') : t('adm.tpl.added'));
      setForm(null);
      await qc.invalidateQueries({ queryKey: ['adm-templates', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function del() {
    if (!delFor) return;
    setErr(null); setBusy(true);
    try {
      await ruleDelete(company, delFor.rule_id);
      setFlash(t('adm.tpl.deleted'));
      setDelFor(null); setForm(null);
      await qc.invalidateQueries({ queryKey: ['adm-templates', company] });
    } catch (e) { setErr(errorMessage(e)); setDelFor(null); } finally { setBusy(false); }
  }

  const editor = (s: RuleSpec) => form && form.rule_code === s.rule_code && (
    <div className="space-y-3 border-b border-line bg-surface-2 p-5" data-testid="adm-rule-form">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {s.obj_types.length > 1 && (
          <label className="block text-xs font-medium text-muted">{t('adm.tpl.document')}
            <select id="adm-r-obj" className="input mt-1 text-[15px] text-ink" value={form.obj_type} onChange={(e) => setForm({ ...form, obj_type: Number(e.target.value) })}>
              {s.obj_types.map((o) => <option key={o} value={o}>{OBJ_LABEL[o] ?? o}</option>)}
            </select>
          </label>
        )}
        <label className="block text-xs font-medium text-muted">{t('adm.tpl.requester')}
          <select id="adm-r-pos" className="input mt-1 text-[15px] text-ink" value={form.position_code} onChange={(e) => setForm({ ...form, position_code: e.target.value })}>
            <option value="">{s.position_required ? t('adm.choose') : t('adm.tpl.everyone')}</option>
            {(q.data?.positions ?? []).map((p) => <option key={p.position_code} value={p.position_code}>{p.name}</option>)}
          </select>
        </label>
        {s.limit_kind !== 'none' && (
          <label className="block text-xs font-medium text-muted">{t(`adm.tpl.limit.${s.limit_kind}`, { cur })}
            <input id="adm-r-limit" inputMode="decimal" className="input num mt-1 text-[15px] text-ink" value={form.limit_value} onChange={(e) => setForm({ ...form, limit_value: e.target.value })} />
          </label>
        )}
        <label className="block text-xs font-medium text-muted">{t('adm.tpl.approver')}
          <select id="adm-r-appr" className="input mt-1 text-[15px] text-ink" value={form.approver_position} onChange={(e) => setForm({ ...form, approver_position: e.target.value })}>
            <option value="">{t('adm.choose')}</option>
            {(q.data?.positions ?? []).map((p) => <option key={p.position_code} value={p.position_code}>{p.name}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium text-muted">{t('adm.tpl.step')}
          <input id="adm-r-step" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" value={form.step} onChange={(e) => setForm({ ...form, step: e.target.value })} />
        </label>
        <label className="block text-xs font-medium text-muted sm:col-span-2">{t('adm.tpl.note')}
          <input id="adm-r-note" dir="auto" className="input mt-1 text-[15px] text-ink" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
        </label>
        <label className="inline-flex min-h-[44px] items-center gap-2 self-end text-sm">
          <input type="checkbox" className="h-4 w-4" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} />{t('adm.tpl.activeLabel')}
        </label>
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        {form.rule_id && <Button variant="danger" disabled={busy} onClick={() => setDelFor(q.data?.rules.find((r) => r.rule_id === form.rule_id) ?? null)} icon={<Trash2 className="h-4 w-4" aria-hidden />}>{t('adm.delete')}</Button>}
        <Button variant="ghost" onClick={() => setForm(null)} icon={<X className="h-4 w-4" aria-hidden />}>{t('fs.cancel')}</Button>
        <Button variant="primary" id="adm-r-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('adm.tpl.saveRule')}</Button>
      </div>
    </div>
  );

  return (
    <AdminFrame title={t('adm.tpl.title')} desc={t('adm.tpl.desc')} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      {q.data && <p className="mb-4 rounded-btn border border-info-fg/20 bg-info-bg px-4 py-3 text-sm text-info-fg" data-testid="adm-tpl-note">{t('adm.tpl.newOnly', { count: q.data.pending })}</p>}
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="space-y-5">
          {(q.data?.catalogue ?? []).map((s) => {
            const rows = (q.data?.rules ?? []).filter((r) => r.rule_code === s.rule_code);
            return (
              <SectionCard key={s.rule_code} title={<span>{t(`so.rule.${s.rule_code}`)} <span className="ms-2 text-xs font-normal text-muted">{s.obj_types.map((o) => OBJ_LABEL[o] ?? o).join(', ')}</span></span>}
                right={canWrite ? <Button variant="ghost" className="min-h-[40px] px-3 text-sm" id={`adm-add-${s.rule_code}`} onClick={() => startNew(s)} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('adm.tpl.add')}</Button> : undefined}>
                <p className="border-b border-line px-5 py-3 text-sm text-ink-2">{t(`adm.tpl.cond.${s.rule_code}`)}</p>
                {editor(s)}
                {rows.length === 0 ? <p className="px-5 py-4 text-sm text-muted">{t('adm.tpl.none')}</p> : (
                  <div className="relative overflow-x-auto">
                    <table className="w-full text-[14px]" data-testid="adm-rules" data-rule={s.rule_code}>
                      <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                        <th scope="col" className="px-4 py-2 text-start">{t('adm.tpl.requester')}</th>
                        {s.limit_kind !== 'none' && <th scope="col" className="px-4 py-2 text-end">{t('adm.tpl.limitCol')}</th>}
                        <th scope="col" className="px-4 py-2 text-start">{t('adm.tpl.approver')}</th>
                        <th scope="col" className="px-4 py-2 text-end max-sm:hidden">{t('adm.tpl.step')}</th>
                        <th scope="col" className="px-4 py-2 text-start">{t('erp.col.status')}</th>
                        {canWrite && <th scope="col" className="px-4 py-2"><span className="sr-only">{t('fs.per.actions')}</span></th>}
                      </tr></thead>
                      <tbody>
                        {rows.map((r) => (
                          <tr key={r.rule_id} className="border-t border-line" data-testid="adm-rule-row">
                            <td className="px-4 py-2" dir="auto">{r.position_name ?? t('adm.tpl.everyone')}{s.obj_types.length > 1 && <span className="ms-1 text-xs text-muted">· {OBJ_LABEL[r.obj_type]}</span>}</td>
                            {s.limit_kind !== 'none' && <td className="num px-4 py-2 text-end">{fmtLimit(s.limit_kind, r.limit_value)}</td>}
                            <td className="px-4 py-2" dir="auto">{r.approver_name}</td>
                            <td className="num px-4 py-2 text-end max-sm:hidden">{r.step}</td>
                            <td className="px-4 py-2"><span className={clsx('pill', r.active ? 'pill-ok' : 'pill-neutral')}>{r.active ? t('adm.users.active') : t('adm.users.inactive')}</span>
                              {r.note?.startsWith('SAMPLE') && <span className="ms-1 pill pill-warning">{t('erp.sampleData')}</span>}</td>
                            {canWrite && <td className="px-4 py-2 text-end"><Button variant="ghost" className="min-h-[40px] px-3 text-sm" onClick={() => startEdit(r)} icon={<Pencil className="h-4 w-4" aria-hidden />}>{t('adm.edit')}</Button></td>}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </SectionCard>
            );
          })}
          <SectionCard title={t('adm.tpl.leaveTitle')}>
            <div className="p-5 text-sm text-ink-2">
              <p>{q.data?.leave?.long_leave_days ? t('adm.tpl.leaveBody', { n: Number(q.data.leave.long_leave_days), hr: q.data.leave.hr_approver_position ?? '—', owner: q.data.leave.owner_position ?? '—' }) : t('adm.tpl.leaveNone')}</p>
              <Link to="/hr/setup" className="mt-2 inline-block text-primary hover:underline">{t('adm.tpl.leaveLink')}</Link>
            </div>
          </SectionCard>
          <AuditCard objects={['approval_rule']} />
        </div>
      )}
      <Dialog open={Boolean(delFor)} title={t('adm.tpl.deleteTitle')} onClose={() => setDelFor(null)}
        footer={<><Button variant="secondary" onClick={() => setDelFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="adm-r-delete-confirm" disabled={busy} onClick={del}>{t('adm.delete')}</Button></>}>
        <p className="text-sm text-ink-2">{t('adm.tpl.deleteBody')}</p>
      </Dialog>
    </AdminFrame>
  );
}

// ---------- Company details ----------
const PROFILE_FIELDS: Array<keyof Profile> = ['legal_name', 'trading_name', 'tax_id', 'licence_no', 'address', 'phone', 'email', 'fiscal_year_start', 'logo_path'];

export function CompanyDetailsPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useCompanyInfo(company);
  const [form, setForm] = useState<Partial<Record<keyof Profile, string>>>({});
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const [owner, setOwner] = useState<string | null>(null);
  const [curText, setCurText] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejecting, setRejecting] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const info = q.data;
  const canWrite = Boolean(info?.can_write);
  const val = (k: keyof Profile) => form[k] ?? (info?.profile[k] === null || info?.profile[k] === undefined ? '' : String(info.profile[k]));
  const dirty = Object.keys(form).some((k) => (form[k as keyof Profile] ?? '') !== (info?.profile[k as keyof Profile] === null ? '' : String(info?.profile[k as keyof Profile] ?? '')));
  const posQ = useQuery({ queryKey: ['adm-pos-list'], queryFn: async () => {
    const { data, error } = await erp().from('position').select('position_code,name').order('name');
    if (error) throw new ApiError(error);
    return data as Array<{ position_code: string; name: string }>;
  } });

  async function run(fn: () => Promise<unknown>, msg: string) {
    setErr(null); setFlash(null); setBusy(true);
    // B3: a rejection that the stage still needs more of leaves the request waiting
    try { const r = await fn() as { state?: string } | null; setFlash(msg === t('adm.co.rejected') && r?.state === 'pending_approval' ? t('apr.flash.rejectionRecorded') : msg); await qc.invalidateQueries({ queryKey: ['adm-company', company] }); return true; } catch (e) { setErr(errorMessage(e)); return false; } finally { setBusy(false); }
  }
  async function submit() {
    const changes: Record<string, string> = {};
    for (const k of Object.keys(form) as Array<keyof Profile>) changes[k] = form[k] ?? '';
    if (await run(() => companySubmit(company, changes, reason), t('adm.co.sent', { pos: info?.setting.owner_position_name ?? '' }))) { setForm({}); setReason(''); }
  }
  async function pickLogo(file: File | undefined) {
    if (!file) return;
    setErr(null);
    try { setForm({ ...form, logo_path: await uploadLogo(company, file) }); } catch (e) { setErr(t('adm.co.logoFailed', { msg: errorMessage(e) })); }
  }

  return (
    <AdminFrame title={t('adm.co.title')} desc={t('adm.co.desc')} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : info && (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
          <div className="min-w-0 space-y-5">
            {info.pending && (
              <SectionCard title={t('adm.co.pendingTitle')} className="border-warn-fg/40">
                <div className="space-y-3 p-5 text-sm" data-testid="adm-co-pending">
                  <p>{t('adm.co.pendingBy', { name: info.pending.requested_by_name ?? '—', when: fmtDate(info.pending.requested_at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }), pos: info.pending.approver_position ?? '—' })}</p>
                  <ApprovalStageNote items={(info.pending.approvals ?? []).filter((a) => a.current)} />
                  {info.pending.reason && <p className="italic text-ink-2" dir="auto">“{info.pending.reason}”</p>}
                  <ul className="divide-y divide-line rounded-btn border border-line">
                    {PROFILE_FIELDS.filter((k) => String(info.pending!.before[k] ?? '') !== String(info.pending!.after[k] ?? '')).map((k) => (
                      <li key={k} className="grid gap-1 px-4 py-2 sm:grid-cols-[160px_minmax(0,1fr)]">
                        <span className="text-xs font-medium text-muted">{t(`adm.co.f.${k}`)}</span>
                        <span dir="auto"><span className="text-muted line-through">{String(info.pending!.before[k] ?? '—')}</span> → <b>{String(info.pending!.after[k] ?? '—')}</b></span>
                      </li>
                    ))}
                  </ul>
                  {info.pending.can_decide && (
                    rejecting ? (
                      <div className="space-y-2">
                        <label className="block text-xs font-medium text-muted">{t('adm.co.rejectNote')}
                          <textarea id="adm-co-note" dir="auto" className="input mt-1 min-h-[80px] text-[15px] text-ink" value={note} onChange={(e) => setNote(e.target.value)} />
                        </label>
                        <div className="flex flex-wrap gap-2"><Button variant="danger" id="adm-co-reject-confirm" disabled={busy} onClick={() => run(() => companyDecide(company, info.pending!.request_id, 'rejected', note), t('adm.co.rejected'))}>{t('adm.co.reject')}</Button>
                          <Button variant="ghost" onClick={() => setRejecting(false)}>{t('fs.cancel')}</Button></div>
                      </div>
                    ) : (
                      <div className="flex flex-wrap gap-2">
                        <Button variant="success" id="adm-co-approve" disabled={busy} onClick={() => run(() => companyDecide(company, info.pending!.request_id, 'approved', ''), t('adm.co.approved'))} icon={<Check className="h-4 w-4" aria-hidden />}>{t('adm.co.approve')}</Button>
                        <Button variant="danger" id="adm-co-reject" disabled={busy} onClick={() => setRejecting(true)}>{t('adm.co.reject')}</Button>
                      </div>
                    )
                  )}
                  {!info.pending.can_decide && canWrite && <Button variant="secondary" id="adm-co-withdraw" disabled={busy} onClick={() => run(() => companyCancel(company, info.pending!.request_id), t('adm.co.withdrawn'))}>{t('adm.co.withdraw')}</Button>}
                </div>
              </SectionCard>
            )}
            <SectionCard title={t('adm.co.print')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                {PROFILE_FIELDS.filter((k) => k !== 'logo_path').map((k) => (
                  <label key={k} className={clsx('block text-xs font-medium text-muted', k === 'address' && 'sm:col-span-2')}>{t(`adm.co.f.${k}`)}
                    {k === 'fiscal_year_start' ? (
                      <select id={`adm-co-${k}`} className="input mt-1 text-[15px] text-ink" disabled={!canWrite || Boolean(info.pending)} value={val(k)} onChange={(e) => setForm({ ...form, [k]: e.target.value })}>
                        <option value="">—</option>{Array.from({ length: 12 }, (_, i) => <option key={i + 1} value={String(i + 1)}>{new Intl.DateTimeFormat('en-GB', { month: 'long' }).format(new Date(2026, i, 1))}</option>)}
                      </select>
                    ) : k === 'address' ? (
                      <textarea id={`adm-co-${k}`} dir="auto" className="input mt-1 min-h-[72px] text-[15px] text-ink" disabled={!canWrite || Boolean(info.pending)} value={val(k)} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
                    ) : (
                      <input id={`adm-co-${k}`} dir={['tax_id', 'phone', 'email', 'licence_no'].includes(k) ? 'ltr' : 'auto'} className="input mt-1 text-[15px] text-ink" disabled={!canWrite || Boolean(info.pending)} value={val(k)} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
                    )}
                  </label>
                ))}
                <div className="text-xs font-medium text-muted sm:col-span-2">{t('adm.co.f.logo_path')}
                  <div className="mt-1 flex flex-wrap items-center gap-3">
                    <span className="font-mono text-[13px] text-ink" dir="ltr">{val('logo_path') || t('adm.co.noLogo')}</span>
                    {canWrite && !info.pending && <><input ref={fileRef} type="file" accept="image/png,image/jpeg,image/svg+xml" className="hidden" onChange={(e) => pickLogo(e.target.files?.[0])} />
                      <Button variant="secondary" className="min-h-[40px] text-sm" onClick={() => fileRef.current?.click()} icon={<Upload className="h-4 w-4" aria-hidden />}>{t('adm.co.uploadLogo')}</Button></>}
                  </div>
                </div>
              </div>
              {canWrite && !info.pending && (
                <div className="space-y-3 border-t border-line p-5">
                  <label className="block text-xs font-medium text-muted">{t('adm.co.reason')}
                    <input id="adm-co-reason" dir="auto" className="input mt-1 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
                  </label>
                  <div className="flex flex-wrap items-center justify-end gap-3">
                    <span className="text-sm text-muted">{info.setting.owner_position ? t('adm.co.willAsk', { pos: info.setting.owner_position_name }) : t('adm.co.noOwner')}</span>
                    <Button variant="primary" id="adm-co-submit" disabled={busy || !dirty} disabledReason={!dirty ? t('adm.co.noChange') : undefined} onClick={submit} icon={<Send className="h-4 w-4" aria-hidden />}>{t('adm.co.submit')}</Button>
                  </div>
                </div>
              )}
            </SectionCard>
            <SectionCard title={t('adm.co.history')}>
              {info.history.length === 0 ? <p className="p-5 text-sm text-muted">{t('adm.co.noHistory')}</p> : (
                <ul className="divide-y divide-line" data-testid="adm-co-history">
                  {info.history.map((h) => (
                    <li key={h.request_id} className="px-5 py-3 text-sm">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <span className={clsx('pill', h.state === 'approved' ? 'pill-ok' : h.state === 'rejected' ? 'pill-crit' : 'pill-neutral')}>{t(`adm.co.state.${h.state}`)}</span>
                        <span className="num text-xs text-muted">{fmtDay(h.requested_at)}</span>
                      </div>
                      <div className="mt-1 text-xs text-muted" dir="auto">{h.requested_by_name}{h.decided_by_name ? ` → ${h.decided_by_name}` : ''}{h.note ? ` · “${h.note}”` : ''}</div>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </div>
          <aside className="space-y-5">
            <SectionCard title={t('adm.co.fromSap')}>
              <div className="p-5"><Fields items={[
                [t('adm.co.code'), <span className="font-mono">{info.company.company_code}</span>], [t('adm.co.country'), info.company.country],
                [t('adm.co.currency'), info.company.currency], [t('adm.co.licenceType'), info.company.licence_type],
              ]} /></div>
            </SectionCard>
            <SectionCard title={t('adm.co.settings')}>
              <div className="space-y-3 p-5">
                <label className="block text-xs font-medium text-muted">{t('adm.co.owner')}
                  <select id="adm-co-owner" className="input mt-1 text-[15px] text-ink" disabled={!canWrite} value={owner ?? info.setting.owner_position ?? ''} onChange={(e) => setOwner(e.target.value)}>
                    <option value="">{t('adm.co.notSet')}</option>
                    {(posQ.data ?? []).map((p) => <option key={p.position_code} value={p.position_code}>{p.name}</option>)}
                  </select>
                </label>
                <label className="block text-xs font-medium text-muted">{t('adm.co.currencies')}
                  <input id="adm-co-currencies" dir="ltr" className="input mt-1 font-mono text-[15px] uppercase text-ink" disabled={!canWrite} value={curText ?? info.setting.fx_currencies.join(', ')} onChange={(e) => setCurText(e.target.value)} />
                </label>
                {canWrite && <Button variant="secondary" id="adm-co-settings-save" className="w-full" disabled={busy}
                  onClick={() => run(() => adminSettingSave(company, { owner_position: owner ?? info.setting.owner_position, fx_currencies: (curText ?? info.setting.fx_currencies.join(',')).split(/[\s,;]+/).filter(Boolean) }), t('adm.co.settingsSaved'))}>{t('adm.co.saveSettings')}</Button>}
              </div>
            </SectionCard>
            <SystemCurrencyCard company={company} />
            <AuditCard objects={['company_details', 'admin_setting', 'company']} />
          </aside>
        </div>
      )}
    </AdminFrame>
  );
}

// ---------- Exchange rates ----------
export function ExchangeRatesPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const setup = useFxSetup(company);
  const rows = useQuery({
    queryKey: ['adm-fx', company], enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('fx_rate_list').select('*').eq('company_code', company).order('rate_date', { ascending: false }).limit(400);
      if (error) throw new ApiError(error);
      return (data ?? []) as FxRow[];
    },
  });
  const [date, setDate] = useState(todayIso());
  const [cur, setCur] = useState('');
  const [rate, setRate] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [rowErrs, setRowErrs] = useState<Array<{ row: number; message: string }>>([]);
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const currencies = setup.data?.currencies ?? [];
  const byDate = useMemo(() => {
    const m = new Map<string, Record<string, FxRow>>();
    for (const r of rows.data ?? []) { const d = m.get(r.rate_date) ?? {}; d[r.currency] = r; m.set(r.rate_date, d); }
    return [...m.entries()].slice(0, 60);
  }, [rows.data]);
  const canWrite = Boolean(setup.data?.can_write);
  const refresh = () => qc.invalidateQueries({ queryKey: ['adm-fx', company] });

  async function save() {
    setErr(null); setFlash(null); setRowErrs([]); setBusy(true);
    try {
      await fxSave(company, date, cur || currencies[0], Number(rate.replace(/,/g, '')));
      setFlash(t('adm.fx.saved', { cur: cur || currencies[0], date: fmtDay(date) }));
      setRate('');
      await refresh();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function importFile(file: File | undefined) {
    if (!file) return;
    setErr(null); setFlash(null); setRowErrs([]); setBusy(true);
    try {
      const parsed = parseRatesCsv(await file.text());
      const r = await fxImport(company, parsed);
      if (r.errors.length) { setRowErrs(r.errors); setErr(t('adm.fx.importErrors', { count: r.errors.length })); } else { setFlash(t('adm.fx.imported', { count: r.saved })); await refresh(); }
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); if (fileRef.current) fileRef.current.value = ''; }
  }

  return (
    <AdminFrame module="financials" title={t('adm.fx.title')} desc={t('adm.fx.desc', { cur: setup.data?.currency ?? '' })} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      {rowErrs.length > 0 && <ul className="mb-4 space-y-1 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-sm text-crit-fg" data-testid="adm-fx-rowerrs">{rowErrs.map((e) => <li key={e.row}>{t('adm.fx.row', { n: e.row })}: {e.message}</li>)}</ul>}
      {setup.error ? <div className="card"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div> : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <SectionCard title={t('adm.fx.table')}>
            {rows.isLoading || setup.isLoading ? <SkeletonRows rows={6} /> : rows.error ? <ErrorState error={rows.error} onRetry={() => rows.refetch()} /> : byDate.length === 0 ? (
              <EmptyState title={t('adm.fx.empty')} body={t('adm.fx.emptyBody')} />
            ) : (
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="adm-fx-table">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('adm.fx.date')}</th>
                    {currencies.map((c) => <th key={c} scope="col" className="px-4 py-2.5 text-end">{c} → {setup.data?.currency}</th>)}
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('adm.fx.by')}</th>
                  </tr></thead>
                  <tbody>
                    {byDate.map(([d, m]) => {
                      const any = Object.values(m)[0];
                      return (
                        <tr key={d} className="border-t border-line" data-testid="adm-fx-row" data-date={d}>
                          <td className="num px-4 py-2">{fmtDay(d)}</td>
                          {currencies.map((c) => <td key={c} className="num px-4 py-2 text-end">{m[c] ? <>{Number(m[c].rate).toFixed(4)}{m[c].source === 'sap' && <span className="ms-1 text-[11px] text-muted">SAP</span>}</> : <span className="text-muted">—</span>}</td>)}
                          <td className="px-4 py-2 text-xs text-muted max-md:hidden" dir="auto">{any?.source === 'sap' ? 'SAP Business One' : `${any?.entered_by_name ?? ''}${any?.source === 'import' ? ` · ${t('adm.fx.importedTag')}` : ''}`}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </SectionCard>
          <aside className="space-y-5">
            {canWrite ? (
              <SectionCard title={t('adm.fx.enter')}>
                <div className="space-y-3 p-5">
                  <label className="block text-xs font-medium text-muted">{t('adm.fx.date')}
                    <input id="adm-fx-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('adm.fx.currency')}
                    <select id="adm-fx-cur" className="input mt-1 text-[15px] text-ink" value={cur || currencies[0] || ''} onChange={(e) => setCur(e.target.value)}>
                      {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                    </select>
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('adm.fx.rate', { cur: setup.data?.currency ?? '', fc: cur || currencies[0] || '' })}
                    <input id="adm-fx-rate" inputMode="decimal" className="input num mt-1 text-[15px] text-ink" value={rate} onChange={(e) => setRate(e.target.value)} placeholder="3.6725" />
                  </label>
                  <Button variant="primary" id="adm-fx-save" className="w-full" disabled={busy || !rate} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('adm.fx.save')}</Button>
                </div>
                <div className="space-y-2 border-t border-line p-5">
                  <p className="text-sm text-ink-2">{t('adm.fx.importBody')}</p>
                  <input ref={fileRef} id="adm-fx-file" type="file" accept=".csv,text/csv" className="hidden" onChange={(e) => importFile(e.target.files?.[0])} />
                  <Button variant="secondary" className="w-full" disabled={busy} onClick={() => fileRef.current?.click()} icon={<Upload className="h-4 w-4" aria-hidden />}>{t('adm.fx.import')}</Button>
                </div>
              </SectionCard>
            ) : setup.data && <ReadOnlyNote show />}
            <SectionCard title={t('adm.fx.rulesTitle')}><ul className="list-disc space-y-2 p-5 ps-9 text-sm text-ink-2"><li>{t('adm.fx.rule1')}</li><li>{t('adm.fx.rule2')}</li><li>{t('adm.fx.rule3')}</li></ul></SectionCard>
          </aside>
        </div>
      )}
    </AdminFrame>
  );
}

// ---------- Add-Ons › AI Assistant (Sana) ----------
// U0+S1: Sana replaced A11's "Ask AI". One screen: on/off, voice, daily limit, languages, and usage as counts only.
// S2: voice mode per company (browser | provider) and a read-only card of what the sana function runs on (provider, models,
// key configured yes/no — from the admin-only config action; there is no key and no field for one anywhere in this UI).
export function AiAssistantPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useSanaSetup(company);
  const cfg = useSanaConfig(company);
  const [f, setF] = useState<Record<string, unknown>>({});
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const s = q.data?.settings;
  const canWrite = Boolean(q.data?.can_edit);
  const v = <T,>(k: string, d: T): T => (k in f ? f[k] : (s as unknown as Record<string, unknown> | undefined)?.[k] ?? d) as T;
  const langs = v<string[]>('languages', []);
  const tot = q.data?.usage.total_30_days;
  const pct = (a: number, b: number) => (b ? `${Math.round((100 * a) / b)} %` : '—');

  async function save() {
    setErr(null); setFlash(null); setBusy(true);
    try {
      const body = { ...f };
      if ('daily_limit' in body) body.daily_limit = body.daily_limit === '' ? null : body.daily_limit;
      const r = await sanaSave(company, body);
      setFlash(r.enabled ? t('adm.ai.savedOn') : t('adm.ai.savedOff'));
      setF({});
      await qc.invalidateQueries({ queryKey: ['adm-sana', company] });
      await qc.invalidateQueries({ queryKey: ['sana-status'] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }

  return (
    <AdminFrame title={t('adm.ai.title')} desc={t('adm.ai.desc')} actions={<CompanyPicker {...sc} />}
      crumbs={[[t('adm.ai.addons'), undefined], [t('adm.ai.title'), undefined]]}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : q.data && (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="min-w-0 space-y-5">
            <SectionCard title={t('adm.ai.general')} right={<span className={clsx('pill', v('enabled', true) ? 'pill-ok' : 'pill-neutral')} data-testid="adm-ai-state">{v('enabled', true) ? t('adm.ai.on') : t('adm.ai.off')}</span>}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                <label className="inline-flex min-h-[44px] items-center gap-2 text-sm sm:col-span-2">
                  <input id="adm-ai-enabled" type="checkbox" className="h-4 w-4" disabled={!canWrite} checked={v('enabled', true)} onChange={(e) => setF({ ...f, enabled: e.target.checked })} />{t('adm.ai.enabledLabel', { company })}
                </label>
                <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                  <input id="adm-ai-voice" type="checkbox" className="h-4 w-4" disabled={!canWrite} checked={v('voice_enabled', true)} onChange={(e) => setF({ ...f, voice_enabled: e.target.checked })} />{t('adm.ai.voiceLabel')}
                </label>
                <label className="block text-xs font-medium text-muted">{t('adm.ai.dailyLimit')}
                  <input id="adm-ai-limit" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" disabled={!canWrite} value={String(v<number | string>('daily_limit', 200))}
                    onChange={(e) => setF({ ...f, daily_limit: e.target.value === '' ? '' : Number(e.target.value.replace(/\D/g, '')) })} />
                  <span className="mt-1 block font-normal">{t('adm.ai.dailyLimitHint')}</span>
                </label>
                <fieldset className="sm:col-span-2" data-testid="adm-ai-voice-mode">
                  <legend className="text-xs font-medium text-muted">{t('adm.ai.voiceMode')}</legend>
                  <div className="mt-2 grid gap-2 sm:grid-cols-2">
                    {(['browser', 'provider'] as const).map((m) => (
                      <label key={m} className={clsx('flex min-h-[44px] cursor-pointer items-start gap-2.5 rounded-btn border px-3 py-2.5 text-sm', v('voice_mode', 'browser') === m ? 'border-primary bg-primary-soft' : 'border-line')}>
                        <input id={`adm-ai-voice-mode-${m}`} type="radio" name="adm-ai-voice-mode" className="mt-0.5 h-4 w-4" disabled={!canWrite} checked={v('voice_mode', 'browser') === m}
                          onChange={() => setF({ ...f, voice_mode: m })} />
                        <span><span className="block font-medium text-ink">{t(`adm.ai.vm.${m}`)}</span><span className="mt-0.5 block text-xs text-muted">{t(`adm.ai.vm.${m}Hint`)}</span></span>
                      </label>
                    ))}
                  </div>
                </fieldset>
              </div>
            </SectionCard>
            <SectionCard title={t('adm.ai.languages', { n: langs.length })}>
              <div className="flex flex-wrap gap-2 p-5" data-testid="adm-ai-langs">
                {[...q.data.all_languages].sort((a, b) => SANA_LANGUAGES.findIndex((x) => x.code === a) - SANA_LANGUAGES.findIndex((x) => x.code === b)).map((l) => (
                  <label key={l} className="inline-flex min-h-[40px] items-center gap-2 rounded-btn border border-line px-3 text-sm">
                    <input type="checkbox" className="h-4 w-4" data-lang={l} disabled={!canWrite} checked={langs.includes(l)}
                      onChange={(e) => setF({ ...f, languages: e.target.checked ? [...langs, l] : langs.filter((x) => x !== l) })} />
                    <span dir="auto">{SANA_LANGUAGES.find((x) => x.code === l)?.label ?? l}</span>
                  </label>
                ))}
              </div>
            </SectionCard>
            <SectionCard title={t('adm.ai.days')}>
              {q.data.usage.days.length === 0 ? <EmptyState title={t('adm.ai.noUsage')} body={t('adm.ai.noUsageBody')} /> : (
                <div className="relative overflow-x-auto">
                  <table className="w-full min-w-[480px] text-[14px]" data-testid="adm-ai-days">
                    <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                      <th className="px-4 py-2.5 text-start">{t('adm.ai.col.day')}</th><th className="px-4 py-2.5 text-end">{t('adm.ai.col.questions')}</th>
                      <th className="px-4 py-2.5 text-end">{t('adm.ai.col.refused')}</th><th className="px-4 py-2.5 text-end">{t('adm.ai.col.voice')}</th><th className="px-4 py-2.5 text-end">{t('adm.ai.col.users')}</th>
                    </tr></thead>
                    <tbody className="[&>tr]:border-t [&>tr]:border-line [&_td]:px-4 [&_td]:py-2.5">
                      {q.data.usage.days.slice(0, 14).map((d) => (
                        <tr key={d.day}><td>{fmtDay(d.day)}</td><td className="num text-end">{d.questions}</td><td className="num text-end">{d.refused}</td><td className="num text-end">{d.voice}</td><td className="num text-end">{d.users}</td></tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </SectionCard>
            {canWrite && <div className="flex justify-end"><Button variant="primary" id="adm-ai-save" disabled={busy || Object.keys(f).length === 0} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('adm.save')}</Button></div>}
          </div>
          <aside className="space-y-5">
            <SectionCard title={t('adm.ai.usage')}>
              <dl className="grid grid-cols-2 gap-x-4 gap-y-3 p-5 text-sm" data-testid="adm-ai-usage">
                <dt className="text-muted">{t('adm.ai.col.questions')}</dt><dd className="num text-end text-lg font-semibold">{tot?.questions ?? 0}</dd>
                <dt className="text-muted">{t('adm.ai.refusalRate')}</dt><dd className="num text-end">{pct(tot?.refused ?? 0, tot?.questions ?? 0)}</dd>
                <dt className="text-muted">{t('adm.ai.voiceShare')}</dt><dd className="num text-end">{pct(tot?.voice ?? 0, tot?.questions ?? 0)}</dd>
                <dt className="text-muted">{t('adm.ai.voiceCalls')}</dt><dd className="num text-end" data-testid="adm-ai-voice-calls">{tot?.voice_calls ?? 0}</dd>
                <dt className="text-muted">{t('adm.ai.col.users')}</dt><dd className="num text-end">{tot?.users ?? 0}</dd>
                <dt className="text-muted">{t('adm.ai.feedback')}</dt><dd className="num text-end" data-testid="adm-ai-feedback">👍 {q.data.usage.feedback.up} · 👎 {q.data.usage.feedback.down}</dd>
              </dl>
              <p className="border-t border-line px-5 py-3 text-xs text-muted">{t('adm.ai.usageBody')}</p>
            </SectionCard>
            <SectionCard title={t('adm.ai.keyTitle')} right={cfg.data?.local_mock ? <span className="pill pill-warning" data-testid="adm-ai-mock">{t('adm.ai.prov.mock')}</span> : undefined}>
              <div className="space-y-3 p-5 text-sm text-ink-2" data-testid="adm-ai-key">
                {cfg.isLoading ? <SkeletonRows rows={4} /> : cfg.error ? (
                  <p className="text-warn-fg" role="status" data-testid="adm-ai-prov-error">{t('adm.ai.prov.unavailable')}</p>
                ) : cfg.data && (
                  <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2" data-testid="adm-ai-provider">
                    <dt className="text-muted">{t('adm.ai.prov.provider')}</dt><dd className="text-end font-medium text-ink" data-testid="adm-ai-prov-name">{t(`adm.ai.prov.${cfg.data.provider}`)}</dd>
                    <dt className="text-muted">{t('adm.ai.prov.model')}</dt><dd className="truncate text-end font-mono text-[12.5px]" dir="ltr" data-testid="adm-ai-prov-model">{cfg.data.model}</dd>
                    <dt className="text-muted">{t('adm.ai.prov.stt')}</dt><dd className="truncate text-end font-mono text-[12.5px]" dir="ltr" data-testid="adm-ai-prov-stt">{cfg.data.voice.stt_model}</dd>
                    <dt className="text-muted">{t('adm.ai.prov.tts')}</dt><dd className="truncate text-end font-mono text-[12.5px]" dir="ltr" data-testid="adm-ai-prov-tts">{cfg.data.voice.tts_model} · {cfg.data.voice.tts_voice}</dd>
                    <dt className="text-muted">{t('adm.ai.prov.key')}</dt>
                    <dd className="text-end"><span className={clsx('pill', cfg.data.key_configured ? 'pill-ok' : 'pill-neutral')} data-testid="adm-ai-prov-key">{cfg.data.key_configured ? t('adm.ai.prov.yes') : t('adm.ai.prov.no')}</span></dd>
                    <dt className="text-muted">{t('adm.ai.prov.fallbackKey')}</dt>
                    <dd className="text-end"><span className={clsx('pill', cfg.data.fallback.key_configured ? 'pill-ok' : 'pill-neutral')}>{cfg.data.fallback.key_configured ? t('adm.ai.prov.yes') : t('adm.ai.prov.no')}</span></dd>
                  </dl>
                )}
                <p className="flex items-center gap-2 font-medium text-ink"><KeyRound className="h-4 w-4" aria-hidden />{cfg.data ? (cfg.data.mode === 'ai' ? t('adm.ai.prov.modeAi') : t('adm.ai.prov.modeBasic')) : (tot?.ai ?? 0) > 0 ? t('adm.ai.modeAi') : t('adm.ai.modeBasic')}</p>
                <p>{t('adm.ai.prov.body')}</p>
                <code className="block rounded-btn bg-surface-2 px-3 py-2 text-[12px]" dir="ltr">supabase secrets set SANA_PROVIDER=gemini SANA_MODEL=gemini-2.5-flash</code>
                {(tot?.fallback ?? 0) > 0 && <p className="text-warn-fg">{t('adm.ai.fallbacks', { count: tot?.fallback ?? 0 })}</p>}
              </div>
            </SectionCard>
            <SectionCard title={t('adm.ai.neverTitle')}><ul className="list-disc space-y-2 p-5 ps-9 text-sm text-ink-2"><li>{t('adm.ai.never1')}</li><li>{t('adm.ai.never2')}</li><li>{t('adm.ai.never3')}</li><li>{t('adm.ai.never4')}</li></ul></SectionCard>
            <AuditCard objects={['sana_settings', 'ai_setting']} />
          </aside>
        </div>
      )}
    </AdminFrame>
  );
}

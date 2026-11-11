import { useEffect, useMemo, useState } from 'react';
import { Link, useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ArrowDown, ArrowUp, History, Pencil, Plus, Power, Save, Trash2, X } from 'lucide-react';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { SectionCard, fmtMoney } from '../components/ui';
import { Dialog } from '../components/Dialog';
import {
  OPS, requestLink, stageDelete, stageSave, templateDelete, templateSave, templateSetActive, useApprovalSetup, useStatusReport, useTemplateHistory,
  type ApprovalSetup, type Condition, type Kind, type Op, type Person, type ReportStatus, type Stage, type Template, type TrailStep,
} from '../approvals';
import { AdminFrame, AuditCard, CompanyPicker, ErrorBox, Flash, ReadOnlyNote, useAdminCompany } from './AdminPages';

const DATE_TIME = { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' } as const;

/** Approval Stages · Approval Templates · Approval Status Report (Administration › Approval Process). */
export function ProcessTabs({ company }: { company: string }) {
  const { t } = useTranslation();
  const here = useLocation().pathname;
  const tabs: Array<[string, string]> = [['/admin/approvals/stages', t('apr.tab.stages')], ['/admin/approvals/templates', t('apr.tab.templates')], ['/admin/approvals/report', t('apr.tab.report')],
    ['/admin/approvals/substitutes', t('apr.tab.substitutes')]];
  return (
    <nav aria-label={t('apr.process')} className="mb-5 flex flex-wrap gap-2 border-b border-line">
      {tabs.map(([to, label]) => (
        <Link key={to} to={`${to}?company=${company}`} aria-current={here.startsWith(to) ? 'page' : undefined}
          className={clsx('-mb-px inline-flex min-h-[44px] items-center border-b-2 px-3 text-[15px] font-medium',
            here.startsWith(to) ? 'border-primary text-primary' : 'border-transparent text-muted hover:text-ink')}>{label}</Link>
      ))}
    </nav>
  );
}

const personKey = (p: Person) => p.position_code ? `p:${p.position_code}` : `u:${p.user_id}`;

/** Positions and users, added from two lists and removed with ×. Empty = "everyone" for originators. */
function PeoplePicker({ id, value, onChange, setup, disabled, emptyText }: {
  id: string; value: Person[]; onChange: (v: Person[]) => void; setup: ApprovalSetup; disabled?: boolean; emptyText: string;
}) {
  const { t } = useTranslation();
  const name = (p: Person) => p.position_code ? setup.positions.find((x) => x.position_code === p.position_code)?.name ?? p.position_code
    : setup.users.find((x) => x.user_id === p.user_id)?.display_name ?? p.name ?? p.user_id;
  const has = (p: Person) => value.some((v) => personKey(v) === personKey(p));
  return (
    <div className="space-y-2">
      <ul className="flex min-h-[44px] flex-wrap items-center gap-2" data-testid={`${id}-list`}>
        {value.length === 0 && <li className="text-sm text-muted">{emptyText}</li>}
        {value.map((p) => (
          <li key={personKey(p)} className="inline-flex items-center gap-1 rounded-full border border-line bg-surface-2 py-1 pe-1 ps-3 text-sm">
            <span className="text-xs text-muted">{p.position_code ? t('apr.position') : t('apr.user')}</span>
            <span dir="auto" className="font-medium">{name(p)}</span>
            {!disabled && (
              <button type="button" className="inline-flex h-8 w-8 items-center justify-center rounded-full hover:bg-page" aria-label={t('apr.remove', { name: name(p) })}
                onClick={() => onChange(value.filter((v) => personKey(v) !== personKey(p)))}><X className="h-4 w-4" aria-hidden /></button>
            )}
          </li>
        ))}
      </ul>
      {!disabled && (
        <div className="grid gap-2 sm:grid-cols-2">
          <label className="block text-xs font-medium text-muted">{t('apr.addPosition')}
            <select id={`${id}-pos`} className="input mt-1 text-[15px] text-ink" value=""
              onChange={(e) => { const p = { position_code: e.target.value, user_id: null }; if (e.target.value && !has(p)) onChange([...value, p]); }}>
              <option value="">{t('adm.choose')}</option>
              {setup.positions.map((p) => <option key={p.position_code} value={p.position_code} disabled={has({ position_code: p.position_code, user_id: null })}>{p.name}</option>)}
            </select>
          </label>
          <label className="block text-xs font-medium text-muted">{t('apr.addUser')}
            <select id={`${id}-user`} className="input mt-1 text-[15px] text-ink" value=""
              onChange={(e) => { const p = { position_code: null, user_id: e.target.value }; if (e.target.value && !has(p)) onChange([...value, p]); }}>
              <option value="">{t('adm.choose')}</option>
              {setup.users.map((u) => <option key={u.user_id} value={u.user_id} disabled={has({ position_code: null, user_id: u.user_id })}>{u.display_name}</option>)}
            </select>
          </label>
        </div>
      )}
    </div>
  );
}

function ActivePill({ active }: { active: boolean }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', active ? 'pill-ok' : 'pill-neutral')}>{active ? t('adm.users.active') : t('adm.users.inactive')}</span>;
}
function SourcePill({ source }: { source: string }) {
  const { t } = useTranslation();
  if (source === 'erp') return null;
  return <span className={clsx('pill', source === 'sample' ? 'pill-warning' : 'pill-neutral')}>{source === 'sample' ? t('erp.sampleData') : t('apr.migrated')}</span>;
}

// ---------- Approval Stages ----------
interface StageForm { stage_id: number | null; name: string; description: string; required_approvals: string; required_rejections: string; active: boolean; authorizers: Person[] }

export function ApprovalStagesPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useApprovalSetup(company);
  const [form, setForm] = useState<StageForm | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [delFor, setDelFor] = useState<Stage | null>(null);
  const setup = q.data;
  const canWrite = Boolean(setup?.can_write);

  const start = (s?: Stage) => {
    setErr(null); setFlash(null);
    setForm(s ? { stage_id: s.stage_id, name: s.name, description: s.description ?? '', required_approvals: String(s.required_approvals), required_rejections: String(s.required_rejections), active: s.active, authorizers: s.authorizers }
      : { stage_id: null, name: '', description: '', required_approvals: '1', required_rejections: '1', active: true, authorizers: [] });
  };
  async function save() {
    if (!form) return;
    setErr(null); setFlash(null); setBusy(true);
    try {
      const r = await stageSave(company, { ...form, authorizers: form.authorizers.map((p) => ({ position_code: p.position_code, user_id: p.user_id })) });
      setFlash(form.stage_id ? (r.pending > 0 ? t('apr.st.changedPending', { n: r.pending }) : t('apr.st.changed')) : t('apr.st.added'));
      setForm(null);
      await qc.invalidateQueries({ queryKey: ['apr-setup', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function del() {
    if (!delFor) return;
    setBusy(true); setErr(null);
    try { await stageDelete(company, delFor.stage_id); setFlash(t('apr.st.deleted')); setForm(null); await qc.invalidateQueries({ queryKey: ['apr-setup', company] }); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); setDelFor(null); }
  }

  return (
    <AdminFrame title={t('apr.st.title')} desc={t('apr.st.desc')} crumbs={[[t('apr.process'), '/admin/approvals/templates'], [t('apr.st.title'), undefined]]}
      actions={<div className="flex flex-wrap items-end gap-2"><CompanyPicker {...sc} />{canWrite && <Button variant="primary" id="apr-st-new" onClick={() => start()} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('apr.st.new')}</Button>}</div>}>
      <ProcessTabs company={company} />
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(setup && !canWrite)} />
      <p className="mb-4 rounded-btn border border-info-fg/20 bg-info-bg px-4 py-3 text-sm text-info-fg" data-testid="apr-st-rule">{t('apr.st.liveRule')}</p>
      {form && setup && (
        <SectionCard title={form.stage_id ? t('apr.st.editTitle', { name: form.name }) : t('apr.st.new')} className="mb-5">
          <div className="space-y-4 p-5" data-testid="apr-stage-form">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <label className="block text-xs font-medium text-muted sm:col-span-2">{t('apr.st.name')}
                <input id="apr-st-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('apr.st.approvals')}
                <input id="apr-st-app" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" value={form.required_approvals} onChange={(e) => setForm({ ...form, required_approvals: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('apr.st.rejections')}
                <input id="apr-st-rej" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" value={form.required_rejections} onChange={(e) => setForm({ ...form, required_rejections: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted sm:col-span-3">{t('apr.st.description')}
                <input id="apr-st-desc" dir="auto" className="input mt-1 text-[15px] text-ink" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
              </label>
              <label className="inline-flex min-h-[44px] items-center gap-2 self-end text-sm">
                <input id="apr-st-active" type="checkbox" className="h-4 w-4" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} />{t('adm.tpl.activeLabel')}
              </label>
            </div>
            <div>
              <h3 className="mb-1 text-sm font-semibold">{t('apr.st.authorizers')}</h3>
              <PeoplePicker id="apr-auth" value={form.authorizers} onChange={(v) => setForm({ ...form, authorizers: v })} setup={setup} emptyText={t('apr.st.noAuthorizer')} />
            </div>
            <div className="flex flex-wrap justify-end gap-2">
              {form.stage_id && <Button variant="danger" disabled={busy} onClick={() => setDelFor(setup.stages.find((s) => s.stage_id === form.stage_id) ?? null)} icon={<Trash2 className="h-4 w-4" aria-hidden />}>{t('adm.delete')}</Button>}
              <Button variant="ghost" onClick={() => setForm(null)} icon={<X className="h-4 w-4" aria-hidden />}>{t('fs.cancel')}</Button>
              <Button variant="primary" id="apr-st-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('apr.st.save')}</Button>
            </div>
          </div>
        </SectionCard>
      )}
      {q.isLoading ? <div className="card"><SkeletonRows rows={6} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : setup && (
        <div className="min-w-0 space-y-5">
          <div className="card min-w-0 max-w-full overflow-hidden">
            {setup.stages.length === 0 ? <EmptyState title={t('apr.st.none')} body={t('apr.st.noneBody')} /> : (
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="apr-stages">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.st.name')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.st.authorizers')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('apr.st.needCol')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('apr.st.usedIn')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('apr.waiting')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                    {canWrite && <th scope="col" className="px-4 py-2.5"><span className="sr-only">{t('fs.per.actions')}</span></th>}
                  </tr></thead>
                  <tbody>
                    {setup.stages.map((s) => (
                      <tr key={s.stage_id} className="border-t border-line align-top" data-testid="apr-stage-row" data-name={s.name}>
                        <td className="px-4 py-2.5"><div dir="auto" className="font-medium">{s.name}</div>{s.description && <div dir="auto" className="text-xs text-muted">{s.description}</div>}</td>
                        <td className="px-4 py-2.5" dir="auto">{s.authorizers.map((a) => a.name).join(', ') || <span className="text-muted">{t('apr.st.ownerFallback', { pos: setup.owner_position_name ?? '—' })}</span>}
                          {s.people < s.required_approvals && <div className="mt-1 text-xs text-warn-fg">{t('apr.st.short', { n: s.people })}</div>}</td>
                        <td className="num px-4 py-2.5 text-end">{t('apr.st.need', { a: s.required_approvals, r: s.required_rejections })}</td>
                        <td className="px-4 py-2.5 text-ink-2 max-md:hidden" dir="auto">{s.templates.join(', ') || '—'}</td>
                        <td className="num px-4 py-2.5 text-end max-sm:hidden">{s.pending}</td>
                        <td className="px-4 py-2.5"><ActivePill active={s.active} /> <SourcePill source={s.source} /></td>
                        {canWrite && <td className="px-4 py-2.5 text-end"><Button variant="ghost" className="min-h-[40px] px-3 text-sm" onClick={() => start(s)} icon={<Pencil className="h-4 w-4" aria-hidden />}>{t('adm.edit')}</Button></td>}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
          <AuditCard objects={['approval_stage']} />
        </div>
      )}
      <Dialog open={Boolean(delFor)} title={t('apr.st.deleteTitle')} onClose={() => setDelFor(null)}
        footer={<><Button variant="secondary" onClick={() => setDelFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="apr-st-delete-confirm" disabled={busy} onClick={del}>{t('adm.delete')}</Button></>}>
        <p className="text-sm text-ink-2">{t('apr.st.deleteBody', { name: delFor?.name ?? '' })}</p>
      </Dialog>
    </AdminFrame>
  );
}

// ---------- Approval Templates ----------
function useCondText() {
  const { t } = useTranslation();
  return (c: Condition, cur: string) => {
    const unit = (v: number | string | null) => v === null || v === '' ? '' : String(Number(v));
    const val = (v: number | string | null) => c.field === 'amount' || c.field === 'doc_total' || c.field === 'credit_over' || c.field === 'variance_value' ? fmtMoney(v, cur)
      : c.field === 'days_since_change' ? t('adm.tpl.days', { n: Number(v) }) : `${unit(v)}%`;
    return `${t(`apr.field.${c.field}`)} ${t(`apr.op.${c.op}`)} ${val(c.value1)}${c.op === 'between' || c.op === 'not_between' ? ` ${t('apr.and')} ${val(c.value2)}` : ''}`;
  };
}

export function ApprovalTemplatesListPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useApprovalSetup(company);
  const [sp, setSp] = useSearchParams();
  const loc = useLocation();
  const fKind = sp.get('kind') ?? '';
  const fState = sp.get('state') ?? 'all';
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [busy, setBusy] = useState(false);
  const condText = useCondText();
  const setup = q.data;
  const canWrite = Boolean(setup?.can_write);
  const rows = (setup?.templates ?? []).filter((x) => (!fKind || x.kind === fKind) && (fState === 'all' || (fState === 'active') === x.active));
  const setF = (k: string, v: string) => { const n = new URLSearchParams(sp); if (v) n.set(k, v); else n.delete(k); setSp(n, { replace: true }); };

  async function toggle(x: Template) {
    setErr(null); setFlash(null); setBusy(true);
    try {
      const r = await templateSetActive(company, x.template_id, !x.active);
      setFlash(r.active ? t('apr.tpl.activated', { name: x.name }) : t('apr.tpl.deactivated', { name: x.name, n: r.pending }));
      await qc.invalidateQueries({ queryKey: ['apr-setup', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }

  return (
    <AdminFrame title={t('apr.tpl.title')} desc={t('apr.tpl.desc')} crumbs={[[t('apr.process'), '/admin/approvals/templates'], [t('apr.tpl.title'), undefined]]}
      actions={<div className="flex flex-wrap items-end gap-2"><CompanyPicker {...sc} />{canWrite && <Link id="apr-tpl-new" to={`/admin/approvals/templates/new?company=${company}`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-primary bg-primary px-4 font-medium text-white hover:bg-primary-hover"><Plus className="h-4 w-4" aria-hidden />{t('apr.tpl.new')}</Link>}</div>}>
      <ProcessTabs company={company} />
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(setup && !canWrite)} />
      <p className="mb-4 rounded-btn border border-info-fg/20 bg-info-bg px-4 py-3 text-sm text-info-fg" data-testid="apr-tpl-rule">{t('apr.tpl.rule')}</p>
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : setup && (
        <div className="min-w-0 space-y-5">
          <div className="flex flex-wrap items-end gap-3">
            <label className="block text-xs font-medium text-muted">{t('apr.tpl.document')}
              <select id="apr-f-kind" className="input mt-1 min-w-[240px] text-[15px] text-ink" value={fKind} onChange={(e) => setF('kind', e.target.value)}>
                <option value="">{t('apr.allDocuments')}</option>
                {setup.kinds.filter((k) => !k.built_in).map((k) => <option key={k.kind} value={k.kind}>{t(`apr.kind.${k.kind}`)}</option>)}
              </select>
            </label>
            <label className="block text-xs font-medium text-muted">{t('erp.col.status')}
              <select id="apr-f-state" className="input mt-1 text-[15px] text-ink" value={fState} onChange={(e) => setF('state', e.target.value === 'all' ? '' : e.target.value)}>
                <option value="all">{t('apr.all')}</option><option value="active">{t('adm.users.active')}</option><option value="inactive">{t('adm.users.inactive')}</option>
              </select>
            </label>
          </div>
          <div className="card min-w-0 max-w-full overflow-hidden">
            {rows.length === 0 ? <EmptyState title={t('apr.tpl.none')} body={t('apr.tpl.noneBody')} /> : (
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="apr-templates">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.tpl.name')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('apr.tpl.originators')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.tpl.stages')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-lg:hidden">{t('apr.tpl.conditions')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                    {canWrite && <th scope="col" className="px-4 py-2.5"><span className="sr-only">{t('fs.per.actions')}</span></th>}
                  </tr></thead>
                  <tbody>
                    {rows.map((x) => (
                      <tr key={x.template_id} className="border-t border-line align-top" data-testid="apr-tpl-row" data-name={x.name}>
                        <td className="px-4 py-2.5">
                          <Link to={`/admin/approvals/templates/${x.template_id}?company=${company}`} dir="auto" className="font-medium text-primary hover:underline">{x.name}</Link>
                          <div className="text-xs text-muted">{t(`apr.kind.${x.kind}`)}{x.obj_type === 59 ? ` · ${t('inbox.kind.goods_receipt')}` : x.obj_type === 60 ? ` · ${t('inbox.kind.goods_issue')}` : ''} · {t('apr.version', { n: x.version })}</div>
                        </td>
                        <td className="px-4 py-2.5 max-md:hidden" dir="auto">{x.originators.length ? x.originators.map((o) => o.name).join(', ') : <span className="text-muted">{t('apr.everyone')}</span>}</td>
                        <td className="px-4 py-2.5" dir="auto">{x.stages.map((s) => s.name).join(' → ')}</td>
                        <td className="px-4 py-2.5 text-ink-2 max-lg:hidden">{x.conditions.length ? x.conditions.map((c) => condText(c, setup.currency)).join(` ${t('apr.and')} `) : <span className="text-muted">{t('apr.always')}</span>}</td>
                        <td className="px-4 py-2.5"><ActivePill active={x.active} /> <SourcePill source={x.source} />
                          {x.pending > 0 && <div className="mt-1 text-xs text-warn-fg">{t('apr.nWaiting', { n: x.pending })}</div>}</td>
                        {canWrite && (
                          <td className="px-4 py-2.5 text-end">
                            <Button variant="ghost" id={`apr-toggle-${x.template_id}`} className="min-h-[40px] px-3 text-sm" disabled={busy} onClick={() => toggle(x)} icon={<Power className="h-4 w-4" aria-hidden />}>
                              {x.active ? t('apr.tpl.deactivate') : t('apr.tpl.activate')}</Button>
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
          <SectionCard title={t('apr.tpl.leaveTitle')}>
            <div className="p-5 text-sm text-ink-2" data-testid="apr-leave">
              <p>{setup.leave ? t('apr.tpl.leaveBody', { n: setup.leave.long_leave_days ?? '—', hr: setup.leave.hr_approver_name ?? '—', owner: setup.leave.owner_name ?? '—' }) : t('adm.tpl.leaveNone')}</p>
              <Link to="/hr/setup" className="mt-2 inline-block text-primary hover:underline">{t('adm.tpl.leaveLink')}</Link>
            </div>
          </SectionCard>
          <p className="text-sm text-muted"><Link to={`/admin/approval-rules?company=${company}`} className="text-primary hover:underline">{t('apr.tpl.legacyLink')}</Link></p>
          <AuditCard objects={['approval_template']} />
        </div>
      )}
    </AdminFrame>
  );
}

interface TplForm { name: string; description: string; kind: string; obj_type: number; active: boolean; originators: Person[]; stages: number[]; conditions: Array<{ field: string; op: Op; value1: string; value2: string }> }

export function ApprovalTemplateFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const nav = useNavigate();
  const { id } = useParams();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useApprovalSetup(company);
  const setup = q.data;
  const tid = mode === 'edit' ? Number(id) : null;
  const hist = useTemplateHistory(company, tid);
  const existing = setup?.templates.find((x) => x.template_id === tid);
  const [form, setForm] = useState<TplForm | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [delOpen, setDelOpen] = useState(false);
  const condText = useCondText();
  const canWrite = Boolean(setup?.can_write);

  useEffect(() => {
    if (!setup || form) return;
    if (mode === 'new') {
      const k = setup.kinds.find((x) => !x.built_in)!;
      setForm({ name: '', description: '', kind: k.kind, obj_type: k.obj_types[0], active: true, originators: [], stages: [], conditions: [] });
    } else if (existing) {
      setForm({ name: existing.name, description: existing.description ?? '', kind: existing.kind, obj_type: existing.obj_type, active: existing.active,
        originators: existing.originators, stages: existing.stages.map((s) => s.stage_id),
        conditions: existing.conditions.map((c) => ({ field: c.field, op: c.op, value1: String(Number(c.value1)), value2: c.value2 === null ? '' : String(Number(c.value2)) })) });
    }
  }, [setup, existing, form, mode]);

  const kind: Kind | undefined = setup?.kinds.find((k) => k.kind === form?.kind);
  const stageName = (sid: number) => setup?.stages.find((s) => s.stage_id === sid)?.name ?? String(sid);
  const move = (i: number, d: number) => { if (!form) return; const s = [...form.stages]; const [x] = s.splice(i, 1); s.splice(i + d, 0, x); setForm({ ...form, stages: s }); };

  async function save() {
    if (!form) return;
    setErr(null); setBusy(true);
    try {
      const r = await templateSave(company, {
        template_id: tid, name: form.name, description: form.description, kind: form.kind, obj_type: form.obj_type, active: form.active,
        originators: form.originators.map((p) => ({ position_code: p.position_code, user_id: p.user_id })), stages: form.stages,
        conditions: form.conditions.map((c) => ({ field: c.field, op: c.op, value1: c.value1, value2: c.op === 'between' || c.op === 'not_between' ? c.value2 : null })),
      });
      await qc.invalidateQueries({ queryKey: ['apr-setup', company] });
      await qc.invalidateQueries({ queryKey: ['apr-history', company] });
      nav(`/admin/approvals/templates?company=${company}`, { state: { flash: t(tid ? 'apr.tpl.saved' : 'apr.tpl.created', { name: form.name, v: r.version }) } });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function del() {
    if (!tid) return;
    setBusy(true); setErr(null);
    try { await templateDelete(company, tid); await qc.invalidateQueries({ queryKey: ['apr-setup', company] }); nav(`/admin/approvals/templates?company=${company}`); }
    catch (e) { setErr(errorMessage(e)); setDelOpen(false); } finally { setBusy(false); }
  }

  const title = mode === 'new' ? t('apr.tpl.new') : existing?.name ?? t('apr.tpl.title');
  return (
    <AdminFrame title={title} desc={t('apr.tpl.formDesc')} crumbs={[[t('apr.process'), '/admin/approvals/templates'], [t('apr.tpl.title'), `/admin/approvals/templates?company=${company}`], [title, undefined]]}>
      <ProcessTabs company={company} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(setup && !canWrite)} />
      {q.isLoading || (!form && !q.error && (mode === 'new' || existing)) ? <div className="card"><SkeletonRows rows={8} /></div>
        : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
        : !form || !setup ? <div className="card"><EmptyState title={t('apr.tpl.notFound')} /></div> : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="min-w-0 space-y-5">
            {existing && existing.pending > 0 && <p className="rounded-btn border border-warn-fg/30 bg-warn-bg px-4 py-3 text-sm text-warn-fg" data-testid="apr-tpl-pending">{t('apr.tpl.pendingNote', { n: existing.pending })}</p>}
            {existing?.legacy_sync && <p className="rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-ink-2">{t('apr.tpl.legacyNote')}</p>}
            <SectionCard title={t('apr.tpl.general')}>
              <div className="grid gap-3 p-5 sm:grid-cols-2">
                <label className="block text-xs font-medium text-muted sm:col-span-2">{t('apr.tpl.name')}
                  <input id="apr-t-name" dir="auto" disabled={!canWrite} className="input mt-1 text-[15px] text-ink" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
                </label>
                <label className="block text-xs font-medium text-muted sm:col-span-2">{t('apr.st.description')}
                  <input id="apr-t-desc" dir="auto" disabled={!canWrite} className="input mt-1 text-[15px] text-ink" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('apr.tpl.document')}
                  <select id="apr-t-kind" disabled={!canWrite || mode === 'edit'} className="input mt-1 text-[15px] text-ink" value={form.kind}
                    onChange={(e) => { const k = setup.kinds.find((x) => x.kind === e.target.value)!; setForm({ ...form, kind: k.kind, obj_type: k.obj_types[0], conditions: [] }); }}>
                    {setup.kinds.filter((k) => !k.built_in).map((k) => <option key={k.kind} value={k.kind}>{t(`apr.kind.${k.kind}`)}</option>)}
                  </select>
                </label>
                {kind && kind.obj_types.length > 1 && (
                  <label className="block text-xs font-medium text-muted">{t('apr.tpl.docType')}
                    <select id="apr-t-obj" disabled={!canWrite} className="input mt-1 text-[15px] text-ink" value={form.obj_type} onChange={(e) => setForm({ ...form, obj_type: Number(e.target.value) })}>
                      {kind.obj_types.map((o) => <option key={o} value={o}>{o === 59 ? t('inbox.kind.goods_receipt') : o === 60 ? t('inbox.kind.goods_issue') : o}</option>)}
                    </select>
                  </label>
                )}
                <label className="inline-flex min-h-[44px] items-center gap-2 self-end text-sm">
                  <input id="apr-t-active" type="checkbox" disabled={!canWrite} className="h-4 w-4" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} />{t('adm.tpl.activeLabel')}
                </label>
              </div>
            </SectionCard>
            <SectionCard title={t('apr.tpl.originators')}>
              <div className="p-5">
                <p className="mb-2 text-sm text-ink-2">{t('apr.tpl.originatorsHelp')}</p>
                <PeoplePicker id="apr-orig" value={form.originators} onChange={(v) => setForm({ ...form, originators: v })} setup={setup} disabled={!canWrite} emptyText={t('apr.everyone')} />
              </div>
            </SectionCard>
            <SectionCard title={t('apr.tpl.stages')}>
              <div className="space-y-3 p-5">
                <ol className="space-y-2" data-testid="apr-t-stages">
                  {form.stages.length === 0 && <li className="text-sm text-muted">{t('apr.tpl.noStage')}</li>}
                  {form.stages.map((sid, i) => (
                    <li key={sid} className="flex flex-wrap items-center gap-2 rounded-btn border border-line px-3 py-2">
                      <span className="pill pill-neutral num">{i + 1}</span>
                      <span dir="auto" className="min-w-0 flex-1 font-medium">{stageName(sid)}</span>
                      <span dir="auto" className="text-xs text-muted">{setup.stages.find((s) => s.stage_id === sid)?.authorizers.map((a) => a.name).join(', ')}</span>
                      {canWrite && <>
                        <Button variant="ghost" className="min-h-[40px] px-2" disabled={i === 0} aria-label={t('apr.up')} onClick={() => move(i, -1)} icon={<ArrowUp className="h-4 w-4" aria-hidden />} />
                        <Button variant="ghost" className="min-h-[40px] px-2" disabled={i === form.stages.length - 1} aria-label={t('apr.down')} onClick={() => move(i, 1)} icon={<ArrowDown className="h-4 w-4" aria-hidden />} />
                        <Button variant="ghost" className="min-h-[40px] px-2" aria-label={t('apr.remove', { name: stageName(sid) })} onClick={() => setForm({ ...form, stages: form.stages.filter((x) => x !== sid) })} icon={<X className="h-4 w-4" aria-hidden />} />
                      </>}
                    </li>
                  ))}
                </ol>
                {canWrite && (
                  <label className="block max-w-md text-xs font-medium text-muted">{t('apr.tpl.addStage')}
                    <select id="apr-t-addstage" className="input mt-1 text-[15px] text-ink" value="" onChange={(e) => { const v = Number(e.target.value); if (v && !form.stages.includes(v)) setForm({ ...form, stages: [...form.stages, v] }); }}>
                      <option value="">{t('adm.choose')}</option>
                      {setup.stages.filter((s) => s.active && !form.stages.includes(s.stage_id)).map((s) => <option key={s.stage_id} value={s.stage_id}>{s.name}</option>)}
                    </select>
                  </label>
                )}
                <p className="text-xs text-muted"><Link to={`/admin/approvals/stages?company=${company}`} className="text-primary hover:underline">{t('apr.tpl.manageStages')}</Link></p>
              </div>
            </SectionCard>
            <SectionCard title={t('apr.tpl.conditions')}>
              <div className="space-y-3 p-5">
                {kind && kind.fields.length === 0 ? <p className="text-sm text-ink-2">{t('apr.tpl.noFields')}</p> : (
                  <>
                    <p className="text-sm text-ink-2">{t('apr.tpl.conditionsHelp')}</p>
                    {form.conditions.map((c, i) => {
                      const set = (p: Partial<TplForm['conditions'][number]>) => setForm({ ...form, conditions: form.conditions.map((x, j) => (j === i ? { ...x, ...p } : x)) });
                      const two = c.op === 'between' || c.op === 'not_between';
                      return (
                        <div key={i} className="grid items-end gap-2 sm:grid-cols-[1.4fr_1fr_1fr_1fr_auto]" data-testid="apr-cond-row">
                          <label className="block text-xs font-medium text-muted">{t('apr.tpl.field')}
                            <select id={`apr-c-field-${i}`} disabled={!canWrite} className="input mt-1 text-[15px] text-ink" value={c.field} onChange={(e) => set({ field: e.target.value })}>
                              {kind?.fields.map((f) => <option key={f.field} value={f.field}>{t(`apr.field.${f.field}`)}{f.line ? ` (${t('apr.perLine')})` : ''}</option>)}
                            </select>
                          </label>
                          <label className="block text-xs font-medium text-muted">{t('apr.tpl.operator')}
                            <select id={`apr-c-op-${i}`} disabled={!canWrite} className="input mt-1 text-[15px] text-ink" value={c.op} onChange={(e) => set({ op: e.target.value as Op })}>
                              {OPS.map((o) => <option key={o} value={o}>{t(`apr.opLong.${o}`)}</option>)}
                            </select>
                          </label>
                          <label className="block text-xs font-medium text-muted">{two ? t('apr.from') : t('apr.value')}
                            <input id={`apr-c-v1-${i}`} disabled={!canWrite} inputMode="decimal" className="input num mt-1 text-[15px] text-ink" value={c.value1} onChange={(e) => set({ value1: e.target.value })} />
                          </label>
                          <label className={clsx('block text-xs font-medium text-muted', !two && 'invisible')}>{t('apr.to')}
                            <input id={`apr-c-v2-${i}`} disabled={!canWrite || !two} inputMode="decimal" className="input num mt-1 text-[15px] text-ink" value={c.value2} onChange={(e) => set({ value2: e.target.value })} />
                          </label>
                          {canWrite && <Button variant="ghost" className="min-h-[44px] px-2" aria-label={t('apr.removeCond')} onClick={() => setForm({ ...form, conditions: form.conditions.filter((_, j) => j !== i) })} icon={<Trash2 className="h-4 w-4" aria-hidden />} />}
                        </div>
                      );
                    })}
                    {form.conditions.length === 0 && <p className="text-sm text-muted" data-testid="apr-always">{t('apr.alwaysLong')}</p>}
                    {canWrite && kind && (
                      <Button variant="secondary" id="apr-c-add" className="min-h-[40px] text-sm" icon={<Plus className="h-4 w-4" aria-hidden />}
                        onClick={() => setForm({ ...form, conditions: [...form.conditions, { field: kind.primary_field ?? kind.fields[0].field, op: kind.primary_op ?? 'gt', value1: '', value2: '' }] })}>{t('apr.tpl.addCond')}</Button>
                    )}
                  </>
                )}
              </div>
            </SectionCard>
            {canWrite && (
              <div className="flex flex-wrap justify-end gap-2">
                {mode === 'edit' && existing && existing.used === 0 && !existing.legacy_sync && existing.source !== 'migrated' && (
                  <Button variant="danger" disabled={busy} onClick={() => setDelOpen(true)} icon={<Trash2 className="h-4 w-4" aria-hidden />}>{t('adm.delete')}</Button>
                )}
                <Link to={`/admin/approvals/templates?company=${company}`} className="inline-flex min-h-[44px] items-center rounded-btn px-4 font-medium hover:bg-page">{t('fs.cancel')}</Link>
                <Button variant="primary" id="apr-t-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('apr.tpl.save')}</Button>
              </div>
            )}
          </div>
          <aside className="space-y-5">
            <SectionCard title={t('apr.tpl.summary')}>
              <div className="space-y-2 p-5 text-sm" data-testid="apr-summary">
                <p>{t(`apr.kind.${form.kind}`)}</p>
                <p className="text-ink-2">{form.originators.length ? t('apr.tpl.sumFrom', { who: form.originators.map((o) => o.name ?? setup.positions.find((p) => p.position_code === o.position_code)?.name ?? setup.users.find((u) => u.user_id === o.user_id)?.display_name).join(', ') }) : t('apr.tpl.sumEveryone')}</p>
                <p className="text-ink-2">{form.conditions.length ? form.conditions.map((c) => condText({ ...c, value2: c.value2 || null }, setup.currency)).join(` ${t('apr.and')} `) : t('apr.always')}</p>
                <p className="text-ink-2" dir="auto">{form.stages.map(stageName).join(' → ') || '—'}</p>
              </div>
            </SectionCard>
            {mode === 'edit' && (
              <SectionCard title={<span className="inline-flex items-center gap-2"><History className="h-4 w-4" aria-hidden />{t('apr.tpl.history')}</span>}>
                {hist.isLoading ? <SkeletonRows rows={3} /> : (
                  <ol className="divide-y divide-line text-sm" data-testid="apr-history">
                    {(hist.data ?? []).map((v) => (
                      <li key={v.version} className="px-5 py-3">
                        <div className="flex flex-wrap items-center gap-2"><span className="pill pill-neutral num">{t('apr.version', { n: v.version })}</span><span className="font-medium">{t(`apr.action.${v.action}`, { defaultValue: v.action })}</span><ActivePill active={v.active} /></div>
                        <div className="mt-1 text-xs text-muted">{v.changed_by_name} · {fmtDate(v.changed_at, DATE_TIME)}</div>
                        <div className="mt-1 text-xs text-ink-2" dir="auto">{v.snapshot.stages.map((s) => s.name).join(' → ')}{v.snapshot.conditions.length ? ` · ${v.snapshot.conditions.map((c) => condText(c, setup.currency)).join(` ${t('apr.and')} `)}` : ''}</div>
                      </li>
                    ))}
                  </ol>
                )}
              </SectionCard>
            )}
          </aside>
        </div>
      )}
      <Dialog open={delOpen} title={t('apr.tpl.deleteTitle')} onClose={() => setDelOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setDelOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="apr-t-delete-confirm" disabled={busy} onClick={del}>{t('adm.delete')}</Button></>}>
        <p className="text-sm text-ink-2">{t('apr.tpl.deleteBody')}</p>
      </Dialog>
    </AdminFrame>
  );
}

// ---------- Approval Status Report ----------
function TrailList({ steps }: { steps: TrailStep[] }) {
  const { t } = useTranslation();
  return (
    <ol className="space-y-1 text-xs" data-testid="apr-trail">
      {steps.map((s) => (
        <li key={s.approval_id} className={clsx(s.superseded && !s.decision && 'text-muted line-through')}>
          <span className="font-medium">{t('apr.stepOf', { n: s.step })}</span> · <span dir="auto">{s.stage_name}</span> · <span dir="auto">{s.template_name}</span>
          {' · '}{s.decision ? <span className={clsx('pill', s.decision === 'approved' ? 'pill-ok' : 'pill-crit')}>{t(`erp.status.${s.decision}`)}</span>
            : s.current ? <span className="pill pill-warning">{t('apr.votes', { a: s.approvals, n: s.need_approvals })}</span> : null}
          {s.votes.length > 0 && <span className="text-muted" dir="auto"> · {s.votes.map((v) => `${v.user_name}${v.on_behalf_of_name ? ` ${t('apr.sub.forName', { name: v.on_behalf_of_name })}` : ''} (${t(`erp.status.${v.decision}`)})`).join(', ')}</span>}
        </li>
      ))}
    </ol>
  );
}

export function ApprovalStatusReportPage() {
  const { t } = useTranslation();
  const sc = useAdminCompany();
  const { company } = sc;
  const setupQ = useApprovalSetup(company);
  const [sp, setSp] = useSearchParams();
  const filter = useMemo(() => {
    const f: Record<string, string> = {};
    for (const k of ['status', 'kind', 'template_id', 'from', 'to']) { const v = sp.get(k); if (v) f[k] = v; }
    if (!f.status) f.status = sp.get('view') === 'decided' ? 'approved' : 'pending';
    return f;
  }, [sp]);
  const q = useStatusReport(company, filter);
  const setF = (k: string, v: string) => { const n = new URLSearchParams(sp); n.delete('view'); if (v) n.set(k, v); else n.delete(k); setSp(n, { replace: true }); };
  const KINDS = ['sales_order', 'sales_quotation', 'sales_doc_request', 'journal', 'payment', 'purchase_order', 'goods_receipt', 'goods_issue', 'inventory_count', 'bp_change', 'company_details', 'leave'];
  return (
    <AdminFrame title={t('apr.rep.title')} desc={t('apr.rep.desc')} crumbs={[[t('apr.process'), '/admin/approvals/templates'], [t('apr.rep.title'), undefined]]} actions={<CompanyPicker {...sc} />}>
      <ProcessTabs company={company} />
      <div className="mb-4 flex min-w-0 flex-wrap items-end gap-3">
        <label className="block text-xs font-medium text-muted">{t('erp.col.status')}
          <select id="apr-r-status" className="input mt-1 text-[15px] text-ink" value={filter.status} onChange={(e) => setF('status', e.target.value)}>
            {(['pending', 'approved', 'rejected', 'cancelled', 'all'] as ReportStatus[]).map((s) => <option key={s} value={s}>{t(`apr.rep.status.${s}`)}{s !== 'all' && q.data ? ` (${q.data.counts[s]})` : ''}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium text-muted">{t('apr.tpl.document')}
          <select id="apr-r-kind" className="input mt-1 text-[15px] text-ink" value={filter.kind ?? ''} onChange={(e) => setF('kind', e.target.value)}>
            <option value="">{t('apr.allDocuments')}</option>
            {KINDS.map((k) => <option key={k} value={k}>{t(`inbox.kind.${k}`)}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium text-muted">{t('apr.tpl.title')}
          <select id="apr-r-tpl" className="input mt-1 max-w-[260px] text-[15px] text-ink" value={filter.template_id ?? ''} onChange={(e) => setF('template_id', e.target.value)}>
            <option value="">{t('apr.all')}</option>
            {(setupQ.data?.templates ?? []).map((x) => <option key={x.template_id} value={x.template_id}>{x.name}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium text-muted">{t('apr.from')}
          <input id="apr-r-from" type="date" className="input mt-1 text-[15px] text-ink" value={filter.from ?? ''} onChange={(e) => setF('from', e.target.value)} />
        </label>
        <label className="block text-xs font-medium text-muted">{t('apr.to')}
          <input id="apr-r-to" type="date" className="input mt-1 text-[15px] text-ink" value={filter.to ?? ''} onChange={(e) => setF('to', e.target.value)} />
        </label>
      </div>
      <div className="card min-w-0 max-w-full overflow-hidden">
        {q.isLoading ? <SkeletonRows rows={6} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !q.data?.rows.length ? (
          <EmptyState title={t('apr.rep.none')} body={t('apr.rep.noneBody')} />
        ) : (
          <div className="relative overflow-x-auto">
            <table className="w-full text-[14px]" data-testid="apr-report">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('inbox.col.document')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('apr.rep.template')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('inbox.col.requester')}</th>
                <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('inbox.col.amount')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>
                {q.data.rows.map((r) => (
                  <tr key={`${r.object}:${r.object_ref}`} className="border-t border-line align-top" data-testid="apr-report-row" data-kind={r.kind}>
                    <td className="px-4 py-2.5">
                      <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={requestLink(r)}>{r.doc_no}</Link>
                      <div dir="auto" className="text-xs text-muted">{t(r.rule_code === 'incoming_payment' ? 'inbox.kind.payment_in' : `inbox.kind.${r.kind}`)}{r.card_code ? ` · ${r.card_code}` : ''} {r.card_name ?? ''}</div>
                    </td>
                    <td className="px-4 py-2.5">
                      <div dir="auto">{r.templates}</div>
                      <details className="mt-1"><summary className="cursor-pointer text-xs text-primary">{t('apr.rep.trail', { n: r.steps })}</summary><div className="mt-1"><TrailList steps={r.trail} /></div></details>
                    </td>
                    <td className="px-4 py-2.5 max-md:hidden">{r.requested_by_name ?? '—'}<div className="text-xs text-muted">{fmtDate(r.requested_at, DATE_TIME)}</div></td>
                    <td className="num px-4 py-2.5 text-end max-sm:hidden">{r.total === null ? '—' : r.kind === 'leave' ? t('hr.nDays', { n: r.total }) : fmtMoney(r.total, r.currency)}</td>
                    <td className="px-4 py-2.5">
                      <span className={clsx('pill', r.status === 'approved' ? 'pill-ok' : r.status === 'pending' ? 'pill-warning' : r.status === 'rejected' ? 'pill-crit' : 'pill-neutral')}>{t(`apr.rep.status.${r.status}`, { defaultValue: r.status })}</span>
                      {r.status === 'pending' && (
                        <div className="mt-1 text-xs text-ink-2" data-testid="apr-report-stage">
                          <div dir="auto">{t('apr.rep.atStage', { n: r.current_step, of: r.steps, stage: r.current_stage ?? '—' })}</div>
                          <div dir="auto" className="text-muted">{t('apr.rep.who', { who: r.current_who ?? '—' })} · {t('apr.rep.days', { n: r.waiting_days ?? 0 })}</div>
                        </div>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </AdminFrame>
  );
}

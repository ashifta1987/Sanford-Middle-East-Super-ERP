import { useMemo, useState } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Building2, Check, Pencil, Plus, Save, Trash2, X } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { SectionCard, fmtDay } from '../components/ui';
import { Dialog } from '../components/Dialog';
import {
  companySave, seriesDelete, seriesSave, useCompanies, useNumbering, userDefaultSave,
  type CompanyRow, type DocSeries, type DocType, type SeriesInput,
} from '../numbering';
import { AdminFrame, AuditCard, CompanyPicker, ErrorBox, Flash, ReadOnlyNote, useAdminCompany } from './AdminPages';

const MODULE_ORDER = ['sales', 'purchase', 'banking', 'finance', 'inventory', 'bp', 'hr', 'production', 'service'];
const emptySeries = (obj: number): SeriesInput => ({
  series_id: null, obj_type: obj, name: '', prefix: '', first_num: '1', next_num: '1', last_num: '', pad: '5', period_from: '', period_to: '',
  branch_id: '', whs_code: '', locked: false, is_default: false, remarks: '',
});
const toInput = (s: DocSeries): SeriesInput => ({
  series_id: s.series_id, obj_type: s.obj_type, name: s.name, prefix: s.prefix, first_num: String(s.first_num), next_num: String(s.next_num),
  last_num: s.last_num === null ? '' : String(s.last_num), pad: String(s.pad), period_from: s.period_from ?? '', period_to: s.period_to ?? '',
  branch_id: s.branch_id === null ? '' : String(s.branch_id), whs_code: s.whs_code ?? '', locked: s.locked, is_default: s.is_default, remarks: s.remarks ?? '',
});

// ---------- Administration › System Initialization › Document Numbering ----------
export function DocNumberingPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useNumbering(company);
  const [obj, setObj] = useState<number | null>(null);
  const [form, setForm] = useState<SeriesInput | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [delFor, setDelFor] = useState<DocSeries | null>(null);
  const canWrite = Boolean(q.data?.can_write);
  const types = useMemo(() => q.data?.types ?? [], [q.data]);
  const current: DocType | undefined = types.find((x) => x.obj_type === obj) ?? types[0];
  const groups = useMemo(() => MODULE_ORDER.map((m) => [m, types.filter((x) => x.module === m)] as const).filter(([, l]) => l.length), [types]);
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['adm-numbering', company] }), qc.invalidateQueries({ queryKey: ['series-options'] })]);

  const open = (d: DocType) => {
    setErr(null); setObj(d.obj_type);
    const def = d.series.find((s) => s.is_default);
    setForm(canWrite ? (def ? toInput(def) : emptySeries(d.obj_type)) : null);
  };
  async function save() {
    if (!form || !current) return;
    setErr(null); setFlash(null); setBusy(true);
    try {
      const r = await seriesSave(company, { ...form, obj_type: current.obj_type });
      setFlash(t('num.saved', { doc: current.label, name: r.name, ex: r.example ?? '—' }));
      setForm(null);
      await refresh();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function del() {
    if (!delFor) return;
    setErr(null); setBusy(true);
    try {
      await seriesDelete(company, delFor.series_id);
      setFlash(t('num.deleted', { name: delFor.name }));
      setDelFor(null); setForm(null);
      await refresh();
    } catch (e) { setErr(errorMessage(e)); setDelFor(null); } finally { setBusy(false); }
  }
  async function setUserDefault(user: string, series: string) {
    if (!current) return;
    setErr(null); setFlash(null);
    try {
      await userDefaultSave(company, user, current.obj_type, series ? Number(series) : null);
      setFlash(t('num.ud.saved', { doc: current.label }));
      await refresh();
    } catch (e) { setErr(errorMessage(e)); }
  }
  const f = form;
  const input = (key: keyof SeriesInput, label: string, props: Record<string, unknown> = {}) => f && (
    <label className="block text-xs font-medium text-muted">{label}
      <input id={`adm-n-${key.replace('_num', '').replace('_', '-')}`} className="input mt-1 text-[15px] text-ink" value={String(f[key] ?? '')}
        onChange={(e) => setForm({ ...f, [key]: e.target.value })} {...props} />
    </label>
  );

  return (
    <AdminFrame title={t('num.title')} desc={t('num.desc')} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={10} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="grid gap-5 xl:grid-cols-[340px_minmax(0,1fr)]">
          <SectionCard title={t('num.types')}>
            <div className="max-h-[70vh] overflow-y-auto" data-testid="num-types">
              {groups.map(([m, list]) => (
                <div key={m}>
                  <p className="bg-surface-2 px-4 py-1.5 text-xs font-semibold uppercase tracking-wide text-muted">{t(`adm.mod.${m}`, { defaultValue: m })}</p>
                  <ul>
                    {list.map((d) => {
                      const def = d.series.find((s) => s.is_default);
                      const on = current?.obj_type === d.obj_type;
                      return (
                        <li key={d.obj_type} data-testid="adm-series-row" data-obj={d.obj_type} className={clsx('border-t border-line', on && 'bg-primary/5')}>
                          <button type="button" id={`num-type-${d.obj_type}`} onClick={() => open(d)} aria-current={on ? 'true' : undefined}
                            className="flex min-h-[48px] w-full items-center justify-between gap-3 px-4 py-2 text-start hover:bg-page">
                            <span className="min-w-0">
                              <span className="block truncate text-[14px] font-medium" dir="ltr">{d.label}</span>
                              <span className="block font-mono text-[12px] text-muted" dir="ltr">{def ? def.example ?? def.prefix : d.used ? t('num.notSet') : t('num.notUsed')}</span>
                            </span>
                            <span className={clsx('pill shrink-0', d.series.length ? 'pill-info' : d.used ? 'pill-warning' : 'pill-neutral')}>
                              {t('num.nSeries', { count: d.series.length })}
                            </span>
                          </button>
                        </li>
                      );
                    })}
                  </ul>
                </div>
              ))}
            </div>
          </SectionCard>

          <div className="min-w-0 space-y-5">
            {current && (
              <SectionCard title={<span dir="ltr">{current.label} <span className="ms-2 text-xs font-normal text-muted">{t('num.objType', { n: current.obj_type })}</span></span>}
                right={canWrite ? <Button variant="ghost" className="min-h-[40px] px-3 text-sm" id="num-new" onClick={() => { setErr(null); setForm(emptySeries(current.obj_type)); }} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('num.new')}</Button> : undefined}>
                {!current.used && <p className="border-b border-line bg-info-bg px-5 py-2.5 text-sm text-info-fg">{t('num.notUsedNote')}</p>}
                {current.series.length === 0 ? <EmptyState title={t('num.noSeries')} body={t('num.noSeriesBody')} /> : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-[14px]" data-testid="num-series">
                      <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                        <th scope="col" className="px-4 py-2.5 text-start">{t('num.f.name')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start">{t('num.f.prefix')}</th>
                        <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('num.f.first')}</th>
                        <th scope="col" className="px-4 py-2.5 text-end">{t('num.f.next')}</th>
                        <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('num.f.last')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start max-lg:hidden">{t('num.f.period')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start max-lg:hidden">{t('num.f.whs')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                        {canWrite && <th scope="col" className="px-4 py-2.5"><span className="sr-only">{t('fs.per.actions')}</span></th>}
                      </tr></thead>
                      <tbody>
                        {current.series.map((s) => (
                          <tr key={s.series_id} className="border-t border-line" data-testid="num-series-row" data-series={s.series_id}>
                            <td className="px-4 py-2" dir="auto">{s.name}{s.remarks && <span className="block text-xs text-muted">{s.remarks}</span>}</td>
                            <td className="whitespace-nowrap px-4 py-2 font-mono text-[13px]" dir="ltr">{s.prefix}</td>
                            <td className="num px-4 py-2 text-end max-md:hidden">{s.first_num}</td>
                            <td className="num whitespace-nowrap px-4 py-2 text-end"><span className="font-mono text-[13px]" dir="ltr">{s.example ?? t('num.full')}</span></td>
                            <td className="num px-4 py-2 text-end max-md:hidden">{s.last_num ?? '—'}</td>
                            <td className="px-4 py-2 text-[13px] max-lg:hidden">{s.period_from || s.period_to ? `${s.period_from ? fmtDay(s.period_from) : '…'} – ${s.period_to ? fmtDay(s.period_to) : '…'}` : '—'}</td>
                            <td className="px-4 py-2 max-lg:hidden">{s.whs_code ?? '—'}{s.branch_id !== null && <span className="ms-1 text-xs text-muted">· {t('num.branchN', { n: s.branch_id })}</span>}</td>
                            <td className="px-4 py-2">
                              <span className="flex flex-wrap gap-1">
                                {s.is_default && <span className="pill pill-ok">{t('num.default')}</span>}
                                {s.locked && <span className="pill pill-neutral">{t('num.locked')}</span>}
                                {s.left === 0 && <span className="pill pill-crit">{t('num.full')}</span>}
                                {s.users > 0 && <span className="pill pill-info">{t('num.nUsers', { count: s.users })}</span>}
                              </span>
                            </td>
                            {canWrite && <td className="px-4 py-2 text-end"><Button variant="ghost" className="min-h-[40px] px-3 text-sm" disabled={busy} onClick={() => { setErr(null); setForm(toInput(s)); }} icon={<Pencil className="h-4 w-4" aria-hidden />}>{t('adm.edit')}</Button></td>}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
                {f && (
                  <div className="space-y-3 border-t border-line bg-surface-2 p-5" data-testid="num-form">
                    <p className="text-sm font-semibold">{f.series_id ? t('num.editTitle', { name: f.name }) : t('num.newTitle', { doc: current.label })}</p>
                    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                      {input('name', t('num.f.name'), { dir: 'auto', maxLength: 40 })}
                      {input('prefix', t('num.f.prefix'), { dir: 'ltr', maxLength: 20, className: 'input mt-1 font-mono text-sm text-ink' })}
                      {input('first_num', t('num.f.first'), { inputMode: 'numeric' })}
                      {input('next_num', t('num.f.next'), { inputMode: 'numeric' })}
                      {input('last_num', t('num.f.lastOpt'), { inputMode: 'numeric' })}
                      {input('pad', t('num.f.pad'), { inputMode: 'numeric' })}
                      {input('period_from', t('num.f.from'), { type: 'date' })}
                      {input('period_to', t('num.f.to'), { type: 'date' })}
                      <label className="block text-xs font-medium text-muted">{t('num.f.whs')}
                        <select id="adm-n-whs" className="input mt-1 text-[15px] text-ink" value={f.whs_code} onChange={(e) => setForm({ ...f, whs_code: e.target.value })}>
                          <option value="">{t('num.any')}</option>
                          {(q.data?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
                        </select>
                      </label>
                      <label className="block text-xs font-medium text-muted">{t('num.f.branch')}
                        <select id="adm-n-branch" className="input mt-1 text-[15px] text-ink" value={f.branch_id} onChange={(e) => setForm({ ...f, branch_id: e.target.value })}>
                          <option value="">{t('num.any')}</option>
                          {(q.data?.branches ?? []).map((b) => <option key={b.id} value={b.id}>{b.id} · {b.name}</option>)}
                        </select>
                      </label>
                      <label className="block text-xs font-medium text-muted sm:col-span-2">{t('num.f.remarks')}
                        <input id="adm-n-remarks" dir="auto" className="input mt-1 text-[15px] text-ink" value={f.remarks} onChange={(e) => setForm({ ...f, remarks: e.target.value })} />
                      </label>
                      <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                        <input id="adm-n-default" type="checkbox" className="h-4 w-4" checked={f.is_default} onChange={(e) => setForm({ ...f, is_default: e.target.checked, locked: e.target.checked ? false : f.locked })} />{t('num.f.default')}
                      </label>
                      <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                        <input id="adm-n-locked" type="checkbox" className="h-4 w-4" checked={f.locked} disabled={f.is_default} onChange={(e) => setForm({ ...f, locked: e.target.checked })} />{t('num.f.locked')}
                      </label>
                    </div>
                    <p className="text-xs text-muted">{t('num.preview')}: <span className="font-mono" dir="ltr" data-testid="num-preview">{f.prefix}{(f.next_num || '').padStart(Number(f.pad) || 0, '0')}</span></p>
                    <div className="flex flex-wrap justify-end gap-2">
                      {f.series_id && !f.is_default && <Button variant="danger" disabled={busy} id="adm-n-delete" onClick={() => setDelFor(current.series.find((s) => s.series_id === f.series_id) ?? null)} icon={<Trash2 className="h-4 w-4" aria-hidden />}>{t('adm.delete')}</Button>}
                      <Button variant="ghost" onClick={() => setForm(null)} icon={<X className="h-4 w-4" aria-hidden />}>{t('fs.cancel')}</Button>
                      <Button variant="primary" id="adm-n-save" disabled={busy} onClick={save} icon={<Check className="h-4 w-4" aria-hidden />}>{t('num.saveSeries')}</Button>
                    </div>
                  </div>
                )}
              </SectionCard>
            )}

            {current && current.series.length > 0 && (
              <SectionCard title={t('num.ud.title', { doc: current.label })}>
                <p className="border-b border-line px-5 py-3 text-sm text-ink-2">{t('num.ud.body')}</p>
                {(q.data?.users ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">{t('num.ud.none')}</p> : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-[14px]" data-testid="num-user-defaults">
                      <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                        <th scope="col" className="px-4 py-2.5 text-start">{t('num.ud.user')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('num.ud.position')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start">{t('num.ud.series')}</th>
                      </tr></thead>
                      <tbody>
                        {(q.data?.users ?? []).map((u) => {
                          const mine = q.data?.user_defaults.find((d) => d.user_id === u.user_id && d.obj_type === current.obj_type)?.series_id;
                          return (
                            <tr key={u.user_id} className="border-t border-line" data-testid="num-ud-row">
                              <td className="px-4 py-2" dir="auto">{u.display_name}<span className="block text-xs text-muted" dir="ltr">{u.email}</span></td>
                              <td className="px-4 py-2 max-sm:hidden" dir="auto">{u.position_name}</td>
                              <td className="px-4 py-2">
                                <select id={`num-ud-${u.user_id}`} aria-label={t('num.ud.seriesFor', { name: u.display_name })} className="input min-h-[40px] py-0 text-sm text-ink" disabled={!canWrite}
                                  value={mine ?? ''} onChange={(e) => setUserDefault(u.user_id, e.target.value)}>
                                  <option value="">{t('num.ud.companyDefault')}</option>
                                  {current.series.filter((s) => !s.locked || s.series_id === mine).map((s) => <option key={s.series_id} value={s.series_id}>{s.name} · {s.prefix}</option>)}
                                </select>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </SectionCard>
            )}

            <div className="grid gap-5 lg:grid-cols-2">
              <SectionCard title={t('num.rulesTitle')}>
                <ul className="list-disc space-y-2 p-5 ps-9 text-sm text-ink-2">
                  {[1, 2, 3, 4, 5, 6].map((n) => <li key={n}>{t(`num.rule${n}`)}</li>)}
                </ul>
              </SectionCard>
              <AuditCard objects={['number_series']} />
            </div>
          </div>
        </div>
      )}
      <Dialog open={Boolean(delFor)} title={t('num.deleteTitle', { name: delFor?.name ?? '' })} onClose={() => setDelFor(null)}
        footer={<><Button variant="secondary" onClick={() => setDelFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="adm-n-delete-confirm" disabled={busy} onClick={del}>{t('adm.delete')}</Button></>}>
        <p className="text-sm text-ink-2">{t('num.deleteBody')}</p>
      </Dialog>
    </AdminFrame>
  );
}

// ---------- Administration › Choose/Create Company ----------
export function CompaniesPage() {
  const { t } = useTranslation();
  const q = useCompanies();
  const loc = useLocation();
  const flash = (loc.state as { flash?: string } | null)?.flash ?? null;
  const canWrite = Boolean(q.data?.can_write);
  return (
    <AdminFrame title={t('cmp.title')} desc={t('cmp.desc')}
      actions={canWrite ? <Link to="/admin/companies/new" id="cmp-new" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-primary bg-primary px-4 font-medium text-white hover:bg-primary-hover"><Plus className="h-4 w-4" aria-hidden />{t('cmp.new')}</Link> : undefined}>
      <Flash text={flash} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      <SectionCard title={t('cmp.list')}>
        {q.isLoading ? <SkeletonRows rows={5} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !(q.data?.companies ?? []).length ? <EmptyState title={t('cmp.none')} body={t('cmp.noneBody')} /> : (
          <div className="overflow-x-auto">
            <table className="w-full text-[14px]" data-testid="cmp-list">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('cmp.f.code')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('cmp.f.legal_name')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('cmp.f.country')} · {t('cmp.f.currency')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-lg:hidden">{t('cmp.f.licence_type')}</th>
                <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('cmp.users')}</th>
                <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('cmp.series')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>
                {(q.data?.companies ?? []).map((c) => (
                  <tr key={c.company_code} className="border-t border-line" data-testid="cmp-row" data-code={c.company_code}>
                    <td className="px-4 py-2 font-mono text-[13px]"><Link className="font-medium text-primary hover:underline" to={`/admin/companies/${c.company_code}`}>{c.company_code}</Link></td>
                    <td className="px-4 py-2" dir="auto">{c.legal_name}<span className="block text-xs text-muted" dir="auto">{c.short_name}</span></td>
                    <td className="px-4 py-2 max-md:hidden">{c.country} · {c.currency}</td>
                    <td className="px-4 py-2 max-lg:hidden">{c.licence_type ? t(`cmp.lic.${c.licence_type}`) : <span className="text-muted">{t('cmp.lic.tbc')}</span>}</td>
                    <td className="num px-4 py-2 text-end max-sm:hidden">{c.users}</td>
                    <td className="num px-4 py-2 text-end max-sm:hidden">{c.series}</td>
                    <td className="px-4 py-2"><span className="flex flex-wrap gap-1">
                      {c.live ? <span className="pill pill-ok">{t('cmp.live')}</span> : <span className="pill pill-info">{t('cmp.notLive')}</span>}
                      {!c.active && <span className="pill pill-neutral">{t('adm.users.inactive')}</span>}
                      {!c.in_register && <span className="pill pill-warning">{t('cmp.noRegister')}</span>}
                    </span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>
      <p className="mt-4 text-sm text-muted">{t('cmp.note')}</p>
    </AdminFrame>
  );
}

const LIC = ['', 'free_zone', 'mainland', 'foreign'];
export function CompanyFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const { code } = useParams();
  const nav = useNavigate();
  const qc = useQueryClient();
  const q = useCompanies();
  const row: CompanyRow | undefined = mode === 'edit' ? q.data?.companies.find((c) => c.company_code === code) : undefined;
  const [v, setV] = useState<Record<string, string | boolean> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const canWrite = Boolean(q.data?.can_write);
  const val = v ?? (row ? {
    company_code: row.company_code, legal_name: row.legal_name, short_name: row.short_name, country: row.country, currency: row.currency,
    licence_type: row.licence_type ?? '', licence_authority: row.licence_authority ?? '', tax_id: row.tax_id ?? '', sap_schema: row.sap_schema ?? '', active: row.active,
  } : { company_code: '', legal_name: '', short_name: '', country: 'AE', currency: 'AED', licence_type: '', licence_authority: '', tax_id: '', sap_schema: '', active: true });
  const set = (k: string, x: string | boolean) => setV({ ...val, [k]: x });

  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await companySave({ ...val, edit: mode === 'edit' });
      await Promise.all([qc.invalidateQueries({ queryKey: ['adm-companies'] }), qc.invalidateQueries({ queryKey: ['profile'] })]);
      if (mode === 'new') setDone(r.company_code); else nav('/admin/companies', { state: { flash: t('cmp.saved', { code: r.company_code }) } });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const field = (k: string, label: string, props: Record<string, unknown> = {}) => (
    <label className="block text-xs font-medium text-muted">{label}
      <input id={`cmp-${k}`} className="input mt-1 text-[15px] text-ink" value={String(val[k] ?? '')} disabled={!canWrite} onChange={(e) => set(k, e.target.value)} {...props} />
    </label>
  );
  const title = mode === 'new' ? t('cmp.newTitle') : t('cmp.editTitle', { code });
  if (mode === 'edit' && q.data && !row) return <AdminFrame title={title} desc={t('cmp.desc')}><ErrorBox text={t('cmp.notFound', { code })} /></AdminFrame>;
  return (
    <AdminFrame title={title} desc={mode === 'new' ? t('cmp.newDesc') : t('cmp.editDesc')} crumbs={[[t('cmp.title'), '/admin/companies'], [title, undefined]]}>
      <ErrorBox text={err} />
      {done ? (
        <SectionCard title={t('cmp.created', { code: done })}>
          <div className="space-y-3 p-5 text-sm text-ink-2" data-testid="cmp-created">
            <p>{t('cmp.createdBody', { code: done })}</p>
            <ul className="list-disc space-y-1 ps-5">
              <li><Link className="text-primary hover:underline" to={`/admin/numbering?company=${done}`}>{t('cmp.next.numbering')}</Link></li>
              <li><Link className="text-primary hover:underline" to="/admin/users">{t('cmp.next.users')}</Link></li>
              <li><Link className="text-primary hover:underline" to={`/admin/go-live/${done}`}>{t('cmp.next.golive')}</Link></li>
              <li><Link className="text-primary hover:underline" to="/backoffice/migration">{t('cmp.next.migration')}</Link></li>
            </ul>
          </div>
        </SectionCard>
      ) : q.isLoading ? <div className="card"><SkeletonRows rows={6} /></div> : (
        <SectionCard title={<span className="inline-flex items-center gap-2"><Building2 className="h-4 w-4" aria-hidden />{t('cmp.basics')}</span>}>
          <div className="grid gap-4 p-5 sm:grid-cols-2 lg:grid-cols-3" data-testid="cmp-form">
            {field('company_code', t('cmp.f.code'), { dir: 'ltr', maxLength: 8, disabled: mode === 'edit' || !canWrite, className: 'input mt-1 font-mono text-[15px] uppercase text-ink' })}
            {field('legal_name', t('cmp.f.legal_name'), { dir: 'auto', maxLength: 200 })}
            {field('short_name', t('cmp.f.short_name'), { dir: 'auto', maxLength: 60 })}
            {field('country', t('cmp.f.country'), { dir: 'ltr', maxLength: 2, className: 'input mt-1 uppercase text-[15px] text-ink' })}
            {field('currency', t('cmp.f.currency'), { dir: 'ltr', maxLength: 3, className: 'input mt-1 uppercase text-[15px] text-ink', disabled: !canWrite || Boolean(row?.has_documents) })}
            <label className="block text-xs font-medium text-muted">{t('cmp.f.licence_type')}
              <select id="cmp-licence_type" className="input mt-1 text-[15px] text-ink" disabled={!canWrite} value={String(val.licence_type)} onChange={(e) => set('licence_type', e.target.value)}>
                {LIC.map((l) => <option key={l} value={l}>{l ? t(`cmp.lic.${l}`) : t('cmp.lic.tbc')}</option>)}
              </select>
            </label>
            {field('licence_authority', t('cmp.f.licence_authority'), { dir: 'auto' })}
            {field('tax_id', t('cmp.f.tax_id'), { dir: 'ltr', inputMode: 'numeric' })}
            {field('sap_schema', t('cmp.f.sap_schema'), { dir: 'ltr' })}
            <label className="inline-flex min-h-[44px] items-center gap-2 self-end text-sm">
              <input id="cmp-active" type="checkbox" className="h-4 w-4" disabled={!canWrite} checked={Boolean(val.active)} onChange={(e) => set('active', e.target.checked)} />{t('cmp.f.active')}
            </label>
          </div>
          {row?.has_documents && <p className="border-t border-line px-5 py-3 text-sm text-muted">{t('cmp.currencyFixed')}</p>}
          <p className="border-t border-line px-5 py-3 text-sm text-muted">{t('cmp.printNote')} <Link className="text-primary hover:underline" to={`/admin/company?company=${code ?? ''}`}>{t('cmp.printLink')}</Link></p>
          {canWrite && (
            <div className="flex flex-wrap justify-end gap-2 border-t border-line p-4">
              <Link to="/admin/companies" className="inline-flex min-h-[44px] items-center rounded-btn px-4 text-sm hover:bg-page">{t('fs.cancel')}</Link>
              <Button variant="primary" id="cmp-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{mode === 'new' ? t('cmp.create') : t('adm.save')}</Button>
            </div>
          )}
        </SectionCard>
      )}
    </AdminFrame>
  );
}

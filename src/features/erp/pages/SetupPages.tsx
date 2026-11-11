import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, CircleCheck, Plus, Save, Undo2, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { moduleByKey, type ModuleKey } from '../modules';
import { searchAccounts, type AccountHit } from '../journal';
import {
  GL_TABS, binSave, glOverrideSave, glSave, itemGroupSave, keyId, lcTypeSave, reasonSave, resourceSave, useAbsorptionAcct, useGlSetup,
  useItemGroupSetup, useLcSetup, useProdSetup, useReasons, useWarehouseSetup, warehouseSave, warehouseSeriesSet, whsBinsSet,
  type AcctRow, type CtxKey, type DocTypeSeries, type GlKey, type GlOverride, type GlTab, type LcMethod, type Resource, type Warehouse,
} from '../setup';

// ---------------------------------------------------------------- shared pieces
/** The company a setup screen works on: the top-bar company, or the user's home company when "all companies" is selected. */
function useSetupCompany() {
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const companies = profile?.companies ?? [];
  const [picked, setPicked] = useState<string | null>(null);
  const company = picked ?? (top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? '');
  return { company, setCompany: setPicked, companies };
}
type SetupCo = ReturnType<typeof useSetupCompany>;

function CompanyPick({ sc }: { sc: SetupCo }) {
  const { t } = useTranslation();
  if (sc.companies.length <= 1) return null;
  return (
    <label className="flex flex-col gap-1 text-xs font-medium text-muted">{t('je.company')}
      <select id="stp-company" className="input min-h-[40px] py-0 text-sm text-ink" value={sc.company} onChange={(e) => sc.setCompany(e.target.value)}>
        {sc.companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
      </select>
    </label>
  );
}

function SetupTitle({ module, title, desc, actions, parent, section }: {
  module: ModuleKey; title: string; desc?: string; actions?: ReactNode; parent?: [string, string]; section?: string;
}) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  const crumbs: Array<[string, string | undefined]> = [[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${module}`], [section ?? t('stp.setup'), undefined]];
  if (parent) crumbs.push(parent);
  crumbs.push([title, undefined]);
  return (
    <PageTitle crumbs={crumbs}
      eyebrow={section ?? t('stp.setup')} title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
  );
}

export function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4 shrink-0" aria-hidden /><span data-testid="stp-flash">{text}</span></p>;
}
export function ErrorBox({ text }: { text: string | null }) {
  if (!text) return null;
  return <div role="alert" className="mb-4 flex items-start gap-2 rounded-card border border-crit-fg/30 bg-crit-bg p-4 font-semibold text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="stp-error">{text}</span></div>;
}
function Note({ children, tone = 'muted', testId }: { children: ReactNode; tone?: 'muted' | 'warn'; testId?: string }) {
  return <p data-testid={testId} className={clsx('mb-4 rounded-btn px-4 py-3 text-sm', tone === 'warn' ? 'border border-warn-fg/30 bg-warn-bg text-warn-fg' : 'bg-surface-2 text-ink-2')}>{children}</p>;
}
function useFlashState() {
  const [flash, setFlash] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { if (flash) { const h = setTimeout(() => setFlash(null), 8000); return () => clearTimeout(h); } }, [flash]);
  return { flash, setFlash, err, setErr };
}

/** Account search (postable, not frozen) with a clear button. value null = empty (the next level applies). */
function AccountField({ id, company, value, name, placeholder, disabled, label, onChange }: {
  id: string; company: string; value: string | null; name?: string | null; placeholder?: string; disabled?: boolean; label: string;
  onChange: (acct: string | null, name: string | null) => void;
}) {
  const { t } = useTranslation();
  const shown = value ? `${value}${name ? ` · ${name}` : ''}` : '';
  const [text, setText] = useState(shown);
  useEffect(() => { setText(shown); }, [shown]);
  if (disabled) {
    return value ? <span className="block min-w-0 truncate"><span className="font-mono text-[14px]">{value}</span> <span dir="auto" className="text-ink-2">{name ? `· ${name}` : ''}</span></span>
      : <span className="text-sm text-muted">{placeholder ?? t('fs.gl.notSet')}</span>;
  }
  const opts = async (s: string): Promise<Array<ComboOption<AccountHit>>> => (await searchAccounts(company, s)).filter((a) => !a.frozen).map((a) => ({
    value: a.acct_code, label: `${a.format_code || a.acct_code} · ${a.name}`, data: a, meta: a.is_control ? `${a.acct_code} · ${t('stp.control')}` : a.acct_code,
  }));
  return (
    <div className="flex min-w-0 items-end gap-1">
      <Combobox<AccountHit> id={id} label={label} className="min-w-0 flex-1 [&>label]:sr-only" text={text} onText={setText} search={opts}
        placeholder={placeholder ?? t('je.accountPh')} noMatch={t('je.noAccount')} onSelect={(o) => { setText(`${o.value} · ${o.data?.name ?? ''}`); onChange(o.value, o.data?.name ?? null); }} />
      {value && <Button variant="ghost" className="min-h-[44px] px-2" aria-label={t('stp.clearAcct', { label })} id={`${id}-clear`} onClick={() => { setText(''); onChange(null, null); }} icon={<X className="h-4 w-4" aria-hidden />} />}
    </div>
  );
}

function Tabs<T extends string>({ id, tabs, value, onChange, label }: { id: string; tabs: Array<[T, string, number?]>; value: T; onChange: (t: T) => void; label: string }) {
  return (
    <div role="tablist" aria-label={label} className="mb-5 flex gap-1 overflow-x-auto border-b border-line" id={id}>
      {tabs.map(([k, l, n]) => (
        <button key={k} type="button" role="tab" id={`${id}-${k}`} aria-selected={value === k} onClick={() => onChange(k)}
          className={clsx('-mb-px inline-flex min-h-[44px] shrink-0 items-center gap-2 whitespace-nowrap border-b-2 px-3 text-sm font-medium',
            value === k ? 'border-primary text-primary-text' : 'border-transparent text-ink-2 hover:text-ink')}>
          {l}{n ? <span className="pill pill-warning">{n}</span> : null}
        </button>
      ))}
    </div>
  );
}

const sourceLabel = (s: string | null | undefined, t: (k: string) => string) => (s === 'sap' ? 'SAP Business One' : s === 'sample' ? t('erp.sampleData') : s ? 'Southfield' : '');

// ---------------------------------------------------------------- C2 · G/L Account Determination
export function GlAccountDeterminationPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useSetupCompany();
  const { company } = sc;
  const q = useGlSetup(company);
  const [sp, setSp] = useSearchParams();
  const tab = (GL_TABS as readonly string[]).includes(sp.get('tab') ?? '') ? (sp.get('tab') as GlTab) : 'sales';
  const [draft, setDraft] = useState<Record<string, { acct: string | null; name: string | null }>>({});
  const [busy, setBusy] = useState(false);
  const fs = useFlashState();
  useEffect(() => { setDraft({}); }, [company]);
  const keys = q.data?.keys ?? [];
  const canWrite = Boolean(q.data?.can_write);
  const changed = Object.keys(draft).filter((id) => (draft[id].acct ?? null) !== (keys.find((k) => keyId(k) === id)?.acct_code ?? null));
  const missingIn = (tb: GlTab) => keys.filter((k) => k.tab === tb && k.used_in && !k.acct_code).length;
  const missing = keys.filter((k) => k.used_in && !k.acct_code).length;

  async function save() {
    fs.setErr(null); fs.setFlash(null); setBusy(true);
    try {
      const rows: AcctRow[] = changed.map((id) => { const k = keys.find((x) => keyId(x) === id)!; return { area: k.area, posting_key: k.posting_key, acct_code: draft[id].acct }; });
      const r = await glSave(company, rows);
      setDraft({});
      fs.setFlash(t('stp.gl.saved', { count: r.changed }));
      await qc.invalidateQueries({ queryKey: ['gl-setup', company] });
    } catch (e) { fs.setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }

  return (
    <RequireModule module="financials">
      <SetupTitle module="financials" section={t('fs.setup')} title={t('fs.gl.title')} desc={t('stp.gl.desc')} actions={<CompanyPick sc={sc} />} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err ?? (q.error ? errorMessage(q.error) : null)} />
      {q.data && !canWrite && <Note>{t('stp.readOnlyFin')}</Note>}
      {q.data && missing > 0 && <Note tone="warn" testId="gld-missing">{t('fs.gl.missing', { count: missing, company })}</Note>}
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.data && (
        <>
          <Tabs<GlTab> id="gld-tab" label={t('fs.gl.title')} value={tab} onChange={(v) => setSp((p) => { p.set('tab', v); return p; }, { replace: true })}
            tabs={GL_TABS.map((tb) => [tb, t(`stp.gl.tab.${tb}`), missingIn(tb)])} />
          <SectionCard title={t(`stp.gl.tab.${tab}`)} right={canWrite ? (
            <div className="flex flex-wrap items-center gap-2">
              {changed.length > 0 && <Button variant="ghost" id="gld-discard" onClick={() => setDraft({})} icon={<Undo2 className="h-4 w-4" aria-hidden />}>{t('stp.discard')}</Button>}
              <Button variant="primary" id="gld-save" disabled={busy || changed.length === 0} disabledReason={changed.length === 0 ? t('stp.nothingChanged') : undefined}
                onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{changed.length ? t('stp.saveChanges', { count: changed.length }) : t('stp.save')}</Button>
            </div>
          ) : undefined}>
            <div className="relative overflow-x-auto">
              <table className="w-full min-w-[640px] text-[14px] md:min-w-0" data-testid="gld-table">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('stp.gl.key')}</th>
                  <th scope="col" className="w-[44%] px-4 py-2.5 text-start">{t('erp.col.account')}</th>
                  <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('stp.gl.levels')}</th>
                </tr></thead>
                <tbody>
                  {keys.filter((k) => k.tab === tab).map((k) => {
                    const id = keyId(k);
                    const d = draft[id];
                    const val = d ? d.acct : k.acct_code;
                    const nm = d ? d.name : k.acct_name;
                    const sap = k.source === 'sap';
                    const dirty = changed.includes(id);
                    return (
                      <tr key={id} data-testid="gld-row" data-key={id} className={clsx('border-t border-line align-top', dirty && 'bg-primary-soft/40')}>
                        <td className="px-4 py-3">
                          <div className="font-medium">{k.label}</div>
                          <div className="text-xs text-muted">{k.used_in ? t('stp.gl.usedIn', { where: k.used_in }) : t('stp.gl.notUsed')}</div>
                          {k.store && <div className="text-xs text-muted">{t(`stp.gl.store.${k.store.split('.')[0]}`)}</div>}
                        </td>
                        <td className="px-4 py-3">
                          <AccountField id={`gld-${k.area}-${k.posting_key}`} company={company} value={val} name={nm} label={k.label}
                            disabled={!canWrite || sap} placeholder={t('fs.gl.notSet')} onChange={(a, n) => setDraft((x) => ({ ...x, [id]: { acct: a, name: n } }))} />
                          <div className="mt-1 flex flex-wrap gap-2 text-xs text-muted">
                            {!val && !dirty && <span className="pill pill-warning">{t('fs.gl.notSet')}</span>}
                            {sap ? t('fs.gl.sapReadOnly') : sourceLabel(k.source, t)}
                            {dirty && <span className="font-medium text-primary-text">{t('stp.unsaved')}</span>}
                          </div>
                        </td>
                        <td className="px-4 py-3 text-sm max-md:hidden">
                          {k.ctx ? (k.overrides > 0 ? <span className="pill pill-info">{t('stp.gl.overrides', { count: k.overrides })}</span>
                            : <span className="text-muted">{t('stp.gl.ctxNone')}</span>) : <span className="text-muted">{t('stp.gl.companyOnly')}</span>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </SectionCard>
          <OverridePanel company={company} keys={keys} data={q.data} canWrite={canWrite} onSaved={(m) => { fs.setFlash(m); qc.invalidateQueries({ queryKey: ['gl-setup', company] }); }} onError={fs.setErr} />
          <p className="mt-4 text-sm text-muted">{t('stp.gl.note')}</p>
        </>
      )}
    </RequireModule>
  );
}

/** Accounts per item group or warehouse (keys that allow it). Empty = the next level (warehouse → item group → company). */
function OverridePanel({ company, keys, data, canWrite, onSaved, onError }: {
  company: string; keys: GlKey[]; data: NonNullable<ReturnType<typeof useGlSetup>['data']>; canWrite: boolean; onSaved: (m: string) => void; onError: (m: string | null) => void;
}) {
  const { t } = useTranslation();
  const [level, setLevel] = useState<'group' | 'warehouse'>('group');
  const [ref, setRef] = useState('');
  const refs = level === 'group' ? data.groups.map((g) => [String(g.group_code), `${g.group_code} · ${g.name}`]) : data.warehouses.map((w) => [w.whs_code, `${w.whs_code} · ${w.name}`]);
  const rows: GlOverride[] = level === 'group' ? data.group_rows.filter((r) => String(r.group_code) === ref) : data.warehouse_rows.filter((r) => r.whs_code === ref);
  const ctxKeys: CtxKey[] = keys.filter((k) => k.ctx).map((k) => ({ area: k.area, posting_key: k.posting_key, label: k.label, tab: k.tab, default_acct: k.acct_code }));
  return (
    <SectionCard className="mt-5" title={t('stp.ov.title')}>
      <div className="grid gap-4 p-5 sm:grid-cols-[200px_minmax(0,1fr)]">
        <label className="block text-xs font-medium text-muted">{t('stp.ov.level')}
          <select id="gld-ov-level" className="input mt-1 text-[15px] text-ink" value={level} onChange={(e) => { setLevel(e.target.value as 'group' | 'warehouse'); setRef(''); }}>
            <option value="group">{t('stp.ov.group')}</option><option value="warehouse">{t('stp.ov.warehouse')}</option>
          </select>
        </label>
        <label className="block text-xs font-medium text-muted">{level === 'group' ? t('stp.ov.group') : t('stp.ov.warehouse')}
          <select id="gld-ov-ref" className="input mt-1 text-[15px] text-ink" value={ref} onChange={(e) => setRef(e.target.value)}>
            <option value="">{t('stp.ov.choose')}</option>
            {refs.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
        </label>
      </div>
      <p className="border-t border-line px-5 py-3 text-sm text-muted">{t('stp.ov.body')}</p>
      {ref && <OverrideGrid key={`${level}-${ref}`} company={company} level={level} refCode={ref} keys={ctxKeys} rows={rows} canWrite={canWrite} onSaved={onSaved} onError={onError} />}
    </SectionCard>
  );
}

function OverrideGrid({ company, level, refCode, keys, rows, canWrite, onSaved, onError, idPrefix = 'gld-ov' }: {
  company: string; level: 'group' | 'warehouse'; refCode: string; keys: CtxKey[]; rows: GlOverride[]; canWrite: boolean;
  onSaved: (m: string) => void; onError: (m: string | null) => void; idPrefix?: string;
}) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState<Record<string, { acct: string | null; name: string | null }>>({});
  const [busy, setBusy] = useState(false);
  const cur = (id: string) => rows.find((r) => keyId(r) === id);
  const changed = Object.keys(draft).filter((id) => (draft[id].acct ?? null) !== (cur(id)?.acct_code ?? null));
  async function save() {
    onError(null); setBusy(true);
    try {
      const r = await glOverrideSave(company, level, refCode, changed.map((id) => { const [area, posting_key] = id.split('/'); return { area, posting_key, acct_code: draft[id].acct }; }));
      setDraft({});
      onSaved(t('stp.ov.saved', { count: r.changed, ref: refCode }));
    } catch (e) { onError(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const tabs = [...new Set(keys.map((k) => k.tab))];
  return (
    <div className="border-t border-line">
      <div className="relative overflow-x-auto">
        <table className="w-full min-w-[640px] text-[14px] md:min-w-0" data-testid={`${idPrefix}-table`}>
          <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
            <th scope="col" className="px-4 py-2.5 text-start">{t('stp.gl.key')}</th>
            <th scope="col" className="w-[50%] px-4 py-2.5 text-start">{t('erp.col.account')}</th>
          </tr></thead>
          <tbody>
            {tabs.map((tb) => [
              <tr key={`h-${tb}`} className="border-t border-line bg-surface-2/50"><th scope="colgroup" colSpan={2} className="px-4 py-1.5 text-start text-xs font-semibold text-muted">{t(`stp.gl.tab.${tb}`)}</th></tr>,
              ...keys.filter((k) => k.tab === tb).map((k) => {
                const id = keyId(k);
                const d = draft[id];
                const o = cur(id);
                return (
                  <tr key={id} data-testid={`${idPrefix}-row`} data-key={id} className={clsx('border-t border-line align-top', changed.includes(id) && 'bg-primary-soft/40')}>
                    <td className="px-4 py-3"><div className="font-medium">{k.label}</div></td>
                    <td className="px-4 py-3">
                      <AccountField id={`${idPrefix}-${k.area}-${k.posting_key}`} company={company} label={k.label} disabled={!canWrite}
                        value={d ? d.acct : o?.acct_code ?? null} name={d ? d.name : o?.acct_name ?? null}
                        placeholder={k.default_acct ? t('stp.ov.default', { acct: k.default_acct }) : t('stp.ov.defaultNone')}
                        onChange={(a, n) => setDraft((x) => ({ ...x, [id]: { acct: a, name: n } }))} />
                    </td>
                  </tr>
                );
              }),
            ])}
          </tbody>
        </table>
      </div>
      {canWrite && (
        <div className="flex flex-wrap justify-end gap-2 border-t border-line p-4">
          {changed.length > 0 && <Button variant="ghost" onClick={() => setDraft({})} icon={<Undo2 className="h-4 w-4" aria-hidden />}>{t('stp.discard')}</Button>}
          <Button variant="primary" id={`${idPrefix}-save`} disabled={busy || changed.length === 0} disabledReason={changed.length === 0 ? t('stp.nothingChanged') : undefined}
            onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{changed.length ? t('stp.saveChanges', { count: changed.length }) : t('stp.save')}</Button>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- C5 · Warehouses
export function WarehousesPage() {
  const { t } = useTranslation();
  const sc = useSetupCompany();
  const q = useWarehouseSetup(sc.company);
  return (
    <RequireModule module="inventory">
      <SetupTitle module="inventory" title={t('stp.whs.title')} desc={t('stp.whs.desc')} actions={
        <div className="flex flex-wrap items-end gap-3"><CompanyPick sc={sc} />
          {q.data?.can_write && <Link id="whs-new" to={`/inventory/warehouses/${sc.company}/new`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover"><Plus className="h-4 w-4" aria-hidden />{t('stp.whs.new')}</Link>}
        </div>} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={5} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="card relative overflow-x-auto">
          <table className="w-full text-[14px]" data-testid="whs-list">
            <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.whs.code')}</th>
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.name')}</th>
              <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('stp.whs.city')}</th>
              <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('stp.whs.bins')}</th>
              <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
            </tr></thead>
            <tbody>
              {q.data!.warehouses.map((w) => (
                <tr key={w.whs_code} className="border-t border-line hover:bg-surface-2" data-whs={w.whs_code}>
                  <td className="px-4 py-2.5"><Link className="font-mono text-[13px] text-primary hover:underline" to={`/inventory/warehouses/${sc.company}/${w.whs_code}`}>{w.whs_code}</Link></td>
                  <td dir="auto" className="px-4 py-2.5">{w.name}<div className="text-xs text-muted">{w.origin === 'erp' ? 'Southfield' : t('stp.fromSap')}</div></td>
                  <td dir="auto" className="px-4 py-2.5 max-sm:hidden">{w.city ?? '—'}</td>
                  <td className="px-4 py-2.5 max-md:hidden">{w.bins_enabled ? t('stp.whs.binsOn', { count: w.bins.length }) : t('erp.no')}</td>
                  <td className="px-4 py-2.5"><span className={clsx('pill', !w.active ? 'pill-neutral' : w.locked ? 'pill-warning' : 'pill-ok')}>{!w.active ? t('stp.inactive') : w.locked ? t('stp.locked') : t('stp.active')}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
          {q.data!.warehouses.length === 0 && <EmptyState title={t('stp.whs.empty')} body={t('stp.whs.emptyBody')} />}
        </div>
      )}
    </RequireModule>
  );
}

type WhsTab = 'general' | 'accounting' | 'bins' | 'numbering';
export function WarehousePage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { company = '', code = '' } = useParams();
  const isNew = code === 'new';
  const q = useWarehouseSetup(company);
  const fs = useFlashState();
  const [tab, setTab] = useState<WhsTab>('general');
  const w = q.data?.warehouses.find((x) => x.whs_code === code);
  const refresh = (m: string) => { fs.setFlash(m); fs.setErr(null); qc.invalidateQueries({ queryKey: ['whs-setup', company] }); };
  if (q.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  const S = q.data;
  const title = isNew ? t('stp.whs.new') : w ? `${w.whs_code} · ${w.name}` : code;
  return (
    <RequireModule module="inventory">
      <SetupTitle module="inventory" parent={[t('stp.whs.title'), '/inventory/warehouses']} title={title} desc={isNew ? t('stp.whs.newDesc') : undefined} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err ?? (q.error ? errorMessage(q.error) : null)} />
      {!isNew && !w && S ? <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div> : S && (
        <>
          {!isNew && <Tabs<WhsTab> id="whs-tab" label={title} value={tab} onChange={setTab}
            tabs={[['general', t('stp.whs.tab.general')], ['accounting', t('stp.whs.tab.accounting')], ['bins', t('stp.whs.tab.bins')], ['numbering', t('stp.whs.tab.numbering')]]} />}
          {(isNew || tab === 'general') && (
            <WhsGeneral key={code} company={company} w={w} canWrite={S.can_write} onSaved={(c, created) => {
              if (created) { qc.invalidateQueries({ queryKey: ['whs-setup', company] }); nav(`/inventory/warehouses/${company}/${c}`, { replace: true }); fs.setFlash(t('stp.whs.created', { code: c })); }
              else refresh(t('stp.whs.saved', { code: c }));
            }} onError={fs.setErr} />
          )}
          {!isNew && w && tab === 'accounting' && (S.can_read_finance ? (
            <SectionCard title={t('stp.whs.tab.accounting')}>
              <p className="px-5 py-3 text-sm text-muted">{t('stp.whs.acctBody')}</p>
              <OverrideGrid company={company} level="warehouse" refCode={w.whs_code} idPrefix="whs-acct" keys={S.keys} canWrite={S.can_finance}
                rows={[...w.accounts, ...(w.stock_acct ? [{ area: 'inventory', posting_key: 'inventory', acct_code: w.stock_acct, acct_name: null }] : [])]}
                onSaved={refresh} onError={fs.setErr} />
            </SectionCard>
          ) : <Note testId="whs-acct-hidden">{t('stp.needFinance')}</Note>)}
          {!isNew && w && tab === 'bins' && <WhsBins company={company} w={w} canWrite={S.can_write} onSaved={refresh} onError={fs.setErr} />}
          {!isNew && w && tab === 'numbering' && <WhsNumbering company={company} w={w} docTypes={S.doc_types} canWrite={S.can_series} onSaved={refresh} onError={fs.setErr} />}
        </>
      )}
    </RequireModule>
  );
}

function Field({ label, children, wide }: { label: string; children: ReactNode; wide?: boolean }) {
  return <label className={clsx('block text-xs font-medium text-muted', wide && 'sm:col-span-2')}>{label}{children}</label>;
}

function WhsGeneral({ company, w, canWrite, onSaved, onError }: {
  company: string; w: Warehouse | undefined;
  canWrite: boolean; onSaved: (code: string, created: boolean) => void; onError: (m: string | null) => void;
}) {
  const { t } = useTranslation();
  const editable = canWrite && (!w || w.origin === 'erp');
  const [f, setF] = useState({ whs_code: w?.whs_code ?? '', name: w?.name ?? '', city: w?.city ?? '', country: w?.country ?? '', branch_id: w?.branch_id != null ? String(w.branch_id) : '',
    classification: w?.classification ?? '', is_free_zone: Boolean(w?.is_free_zone), locked: Boolean(w?.locked), active: w?.active ?? true });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f, v: string | boolean) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    onError(null); setBusy(true);
    try { const r = await warehouseSave(company, { ...f, edit: Boolean(w) }); onSaved(r.whs_code, r.created); }
    catch (e) { onError(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const inp = (k: 'whs_code' | 'name' | 'city' | 'country' | 'branch_id' | 'classification', label: string, extra?: { mono?: boolean; disabled?: boolean; inputMode?: 'numeric' }) => (
    <Field label={label}>
      <input id={`whs-${k}`} dir={extra?.mono ? 'ltr' : 'auto'} inputMode={extra?.inputMode} disabled={!editable || extra?.disabled}
        className={clsx('input mt-1 text-[15px] text-ink', extra?.mono && 'font-mono')} value={f[k]} onChange={(e) => set(k, e.target.value)} />
    </Field>
  );
  return (
    <SectionCard title={t('stp.whs.tab.general')}>
      {w && w.origin !== 'erp' && <p className="border-b border-line px-5 py-3 text-sm text-muted" data-testid="whs-sap-note">{t('stp.whs.sapNote', { company })}</p>}
      <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 lg:grid-cols-3">
        {inp('whs_code', t('stp.whs.code'), { mono: true, disabled: Boolean(w) })}
        {inp('name', t('stp.name'))}
        {inp('city', t('stp.whs.city'))}
        {inp('country', t('stp.whs.country'), { mono: true })}
        {inp('branch_id', t('stp.whs.branch'), { inputMode: 'numeric' })}
        {inp('classification', t('stp.whs.classification'))}
        {(['is_free_zone', 'locked', 'active'] as const).map((k) => (
          <label key={k} className="inline-flex min-h-[44px] items-center gap-2 text-sm">
            <input type="checkbox" id={`whs-${k}`} className="h-5 w-5" disabled={!editable} checked={f[k]} onChange={(e) => set(k, e.target.checked)} />{t(`stp.whs.${k}`)}
          </label>
        ))}
      </div>
      {editable && <div className="flex justify-end border-t border-line p-4"><Button variant="primary" id="whs-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{w ? t('stp.save') : t('stp.whs.create')}</Button></div>}
    </SectionCard>
  );
}

function WhsBins({ company, w, canWrite, onSaved, onError }: { company: string; w: Warehouse; canWrite: boolean; onSaved: (m: string) => void; onError: (m: string | null) => void }) {
  const { t } = useTranslation();
  const [nb, setNb] = useState({ bin_code: '', name: '' });
  const run = async (f: () => Promise<unknown>, m: string) => { onError(null); try { await f(); onSaved(m); } catch (e) { onError(errorMessage(e)); } };
  return (
    <SectionCard title={t('stp.whs.tab.bins')} right={
      <label className="inline-flex min-h-[40px] items-center gap-2 text-sm"><input type="checkbox" id="whs-bins-on" className="h-5 w-5" disabled={!canWrite} checked={w.bins_enabled}
        onChange={(e) => run(() => whsBinsSet(company, w.whs_code, e.target.checked), e.target.checked ? t('stp.whs.binsOnFlash') : t('stp.whs.binsOffFlash'))} />{t('stp.whs.binsSwitch')}</label>}>
      {!w.bins_enabled && w.bins.length === 0 ? <p className="p-5 text-sm text-muted">{t('stp.whs.binsOffBody')}</p> : (
        <div className="relative overflow-x-auto">
          <table className="w-full text-[14px]" data-testid="whs-bins">
            <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.whs.bin')}</th><th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('stp.name')}</th>
              <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.qty')}</th><th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
            </tr></thead>
            <tbody>{w.bins.map((b) => (
              <tr key={b.bin_code} className="border-t border-line">
                <td className="px-4 py-2 font-mono text-[13px]">{b.bin_code}</td><td dir="auto" className="px-4 py-2 max-sm:hidden">{b.name ?? '—'}</td>
                <td className="num px-4 py-2 text-end">{Number(b.qty)}</td>
                <td className="px-4 py-2"><label className="inline-flex min-h-[40px] items-center gap-2"><input type="checkbox" className="h-5 w-5" disabled={!canWrite} checked={b.active} aria-label={t('stp.whs.binActive', { bin: b.bin_code })}
                  onChange={(e) => run(() => binSave(company, { bin_code: b.bin_code, whs_code: w.whs_code, active: e.target.checked }), t('stp.whs.binSaved', { bin: b.bin_code }))} />{b.active ? t('stp.active') : t('stp.inactive')}</label></td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
      {canWrite && w.bins_enabled && (
        <div className="grid grid-cols-1 gap-3 border-t border-line p-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
          <Field label={t('stp.whs.bin')}><input id="whs-bin-code" dir="ltr" className="input mt-1 font-mono text-[15px] text-ink" value={nb.bin_code} placeholder={`${w.whs_code}-A-01-L1`} onChange={(e) => setNb({ ...nb, bin_code: e.target.value })} /></Field>
          <Field label={t('stp.name')}><input id="whs-bin-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={nb.name} onChange={(e) => setNb({ ...nb, name: e.target.value })} /></Field>
          <Button variant="secondary" id="whs-bin-add" disabled={!nb.bin_code.trim()} onClick={() => run(async () => { await binSave(company, { ...nb, whs_code: w.whs_code }); setNb({ bin_code: '', name: '' }); }, t('stp.whs.binSaved', { bin: nb.bin_code.toUpperCase() }))}
            icon={<Plus className="h-4 w-4" aria-hidden />}>{t('stp.whs.addBin')}</Button>
        </div>
      )}
    </SectionCard>
  );
}

function WhsNumbering({ company, w, docTypes, canWrite, onSaved, onError }: {
  company: string; w: Warehouse; docTypes: DocTypeSeries[];
  canWrite: boolean; onSaved: (m: string) => void; onError: (m: string | null) => void;
}) {
  const { t } = useTranslation();
  async function set(obj: number, label: string, v: string) {
    onError(null);
    try { await warehouseSeriesSet(company, w.whs_code, obj, v ? Number(v) : null); onSaved(v ? t('stp.whs.seriesSet', { doc: label }) : t('stp.whs.seriesCleared', { doc: label })); }
    catch (e) { onError(errorMessage(e)); }
  }
  return (
    <SectionCard title={t('stp.whs.tab.numbering')}>
      <p className="px-5 py-3 text-sm text-muted">{t('stp.whs.numBody')}</p>
      <div className="relative overflow-x-auto border-t border-line">
        <table className="w-full text-[14px]" data-testid="whs-series">
          <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
            <th scope="col" className="px-4 py-2.5 text-start">{t('stp.whs.docType')}</th><th scope="col" className="w-[55%] px-4 py-2.5 text-start">{t('stp.whs.defaultSeries')}</th>
          </tr></thead>
          <tbody>{docTypes.map((d) => {
            const cur = w.series.find((s) => s.obj_type === d.obj_type);
            const usable = d.series.filter((s) => !s.locked && (!s.whs_code || s.whs_code === w.whs_code));
            return (
              <tr key={d.obj_type} className="border-t border-line" data-obj={d.obj_type}>
                <td className="px-4 py-2">{d.label}</td>
                <td className="px-4 py-2">
                  <select id={`whs-ser-${d.obj_type}`} aria-label={t('stp.whs.defaultFor', { doc: d.label })} className="input min-h-[40px] py-0 text-sm text-ink" disabled={!canWrite || d.series.length === 0}
                    value={cur ? String(cur.series_id) : ''} onChange={(e) => set(d.obj_type, d.label, e.target.value)}>
                    <option value="">{d.series.length === 0 ? t('stp.whs.noSeries') : t('stp.whs.companyDefault')}</option>
                    {usable.map((s) => <option key={s.series_id} value={s.series_id}>{s.name} · {s.prefix}{s.is_default ? ` (${t('stp.whs.isDefault')})` : ''}</option>)}
                    {cur && !usable.some((s) => s.series_id === cur.series_id) && <option value={cur.series_id}>{cur.name ?? cur.series_id} · {t('stp.locked')}</option>}
                  </select>
                </td>
              </tr>
            );
          })}</tbody>
        </table>
      </div>
    </SectionCard>
  );
}

// ---------------------------------------------------------------- C6 · Item groups
export function ItemGroupsPage() {
  const { t } = useTranslation();
  const sc = useSetupCompany();
  const q = useItemGroupSetup(sc.company);
  return (
    <RequireModule module="inventory">
      <SetupTitle module="inventory" title={t('stp.ig.title')} desc={t('stp.ig.desc')} actions={
        <div className="flex flex-wrap items-end gap-3"><CompanyPick sc={sc} />
          {q.data?.can_write && <Link id="ig-new" to={`/inventory/item-groups/${sc.company}/new`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover"><Plus className="h-4 w-4" aria-hidden />{t('stp.ig.new')}</Link>}
        </div>} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={5} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="card relative overflow-x-auto">
          <table className="w-full text-[14px]" data-testid="ig-list">
            <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.ig.code')}</th><th scope="col" className="px-4 py-2.5 text-start">{t('stp.name')}</th>
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.ig.method')}</th><th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('stp.ig.warranty')}</th>
              <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('stp.ig.items')}</th>
            </tr></thead>
            <tbody>{q.data!.groups.map((g) => (
              <tr key={g.group_code} className="border-t border-line hover:bg-surface-2" data-group={g.group_code}>
                <td className="px-4 py-2.5"><Link className="font-mono text-[13px] text-primary hover:underline" to={`/inventory/item-groups/${sc.company}/${g.group_code}`}>{g.group_code}</Link></td>
                <td dir="auto" className="px-4 py-2.5">{g.name}<div className="text-xs text-muted">{g.origin === 'erp' ? 'Southfield' : t('stp.fromSap')}</div></td>
                <td className="px-4 py-2.5"><span className={clsx('pill', g.manage_method === 'none' ? 'pill-neutral' : 'pill-info')}>{t(`stp.ig.m.${g.manage_method}`)}</span></td>
                <td className="num px-4 py-2.5 text-end max-sm:hidden">{g.warranty_months ? t('stp.ig.months', { count: g.warranty_months }) : '—'}</td>
                <td className="num px-4 py-2.5 text-end max-md:hidden">{g.items}</td>
              </tr>
            ))}</tbody>
          </table>
          {q.data!.groups.length === 0 && <EmptyState title={t('stp.ig.empty')} body={t('stp.ig.emptyBody')} />}
        </div>
      )}
    </RequireModule>
  );
}

export function ItemGroupPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { company = '', code = '' } = useParams();
  const isNew = code === 'new';
  const q = useItemGroupSetup(company);
  const fs = useFlashState();
  const [tab, setTab] = useState<'general' | 'accounting'>('general');
  const g = q.data?.groups.find((x) => String(x.group_code) === code);
  const [f, setF] = useState<{ name: string; manage_method: string; warranty_months: string } | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (q.data && f === null) setF({ name: g?.name ?? '', manage_method: g?.manage_method ?? 'none', warranty_months: g?.warranty_months ? String(g.warranty_months) : '' }); }, [q.data, g, f]);
  if (q.isLoading || !f) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  const S = q.data!;
  const canW = S.can_write;
  const nameEditable = canW && (isNew || g?.origin === 'erp');
  const title = isNew ? t('stp.ig.new') : g ? `${g.group_code} · ${g.name}` : code;
  async function save() {
    fs.setErr(null); setBusy(true);
    try {
      const r = await itemGroupSave(company, { ...(isNew ? {} : { group_code: g!.group_code }), ...(nameEditable ? { name: f!.name } : {}), manage_method: f!.manage_method, warranty_months: f!.warranty_months });
      await qc.invalidateQueries({ queryKey: ['ig-setup', company] });
      if (r.created) { nav(`/inventory/item-groups/${company}/${r.group_code}`, { replace: true }); setF(null); }
      fs.setFlash(r.created ? t('stp.ig.created', { name: f!.name }) : t('stp.ig.saved'));
    } catch (e) { fs.setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const refresh = (m: string) => { fs.setFlash(m); fs.setErr(null); qc.invalidateQueries({ queryKey: ['ig-setup', company] }); };
  return (
    <RequireModule module="inventory">
      <SetupTitle module="inventory" parent={[t('stp.ig.title'), '/inventory/item-groups']} title={title} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err} />
      {!isNew && !g ? <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div> : (
        <>
          {!isNew && <Tabs id="ig-tab" label={title} value={tab} onChange={setTab} tabs={[['general', t('stp.whs.tab.general')], ['accounting', t('stp.whs.tab.accounting')]]} />}
          {(isNew || tab === 'general') && (
            <SectionCard title={t('stp.whs.tab.general')}>
              {g && g.origin !== 'erp' && <p className="border-b border-line px-5 py-3 text-sm text-muted">{t('stp.ig.sapNote', { company })}</p>}
              <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-3">
                <Field label={t('stp.name')}><input id="ig-name" dir="auto" disabled={!nameEditable} className="input mt-1 text-[15px] text-ink" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
                <Field label={t('stp.ig.method')}>
                  <select id="ig-method" disabled={!canW} className="input mt-1 text-[15px] text-ink" value={f.manage_method} onChange={(e) => setF({ ...f, manage_method: e.target.value })}>
                    {(['none', 'batch', 'serial'] as const).map((m) => <option key={m} value={m}>{t(`stp.ig.m.${m}`)}</option>)}
                  </select>
                </Field>
                <Field label={t('stp.ig.warrantyMonths')}><input id="ig-warranty" inputMode="numeric" disabled={!canW} className="input num mt-1 text-[15px] text-ink" value={f.warranty_months} placeholder={t('stp.ig.noWarranty')} onChange={(e) => setF({ ...f, warranty_months: e.target.value })} /></Field>
              </div>
              <p className="px-5 pb-4 text-sm text-muted">{t('stp.ig.methodBody')}</p>
              {canW && <div className="flex justify-end border-t border-line p-4"><Button variant="primary" id="ig-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{isNew ? t('stp.ig.create') : t('stp.save')}</Button></div>}
            </SectionCard>
          )}
          {!isNew && g && tab === 'accounting' && (S.can_read_finance ? (
            <SectionCard title={t('stp.whs.tab.accounting')}>
              <p className="px-5 py-3 text-sm text-muted">{t('stp.ig.acctBody')}</p>
              <OverrideGrid company={company} level="group" refCode={String(g.group_code)} idPrefix="ig-acct" keys={S.keys} rows={g.accounts} canWrite={S.can_finance} onSaved={refresh} onError={fs.setErr} />
            </SectionCard>
          ) : <Note>{t('stp.needFinance')}</Note>)}
        </>
      )}
    </RequireModule>
  );
}

// ---------------------------------------------------------------- GR/GI reasons
export function ReasonsPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useSetupCompany();
  const { company } = sc;
  const q = useReasons(company);
  const fs = useFlashState();
  const { profile } = useAuth();
  const canW = (profile?.levels?.finance ?? null) === 'full';
  const [nr, setNr] = useState({ code: '', name: '', direction: 'out', gl_key: '', acct_code: null as string | null });
  const keyOpts = (q.data?.keys ?? []).filter((k) => ['inventory', 'service', 'production', 'general'].includes(k.tab));
  const keyLabel = (a: string | null, k: string | null) => (q.data?.keys ?? []).find((x) => x.area === a && x.posting_key === k)?.label ?? '—';
  async function save(r: Record<string, unknown>, msg: string) {
    fs.setErr(null);
    try { await reasonSave(company, r); fs.setFlash(msg); await qc.invalidateQueries({ queryKey: ['reasons', company] }); return true; }
    catch (e) { fs.setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); return false; }
  }
  return (
    <RequireModule module="inventory">
      <SetupTitle module="inventory" title={t('stp.rs.title')} desc={t('stp.rs.desc')} actions={<CompanyPick sc={sc} />} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err ?? (q.error ? errorMessage(q.error) : null)} />
      {!canW && <Note>{t('stp.rs.readOnly')}</Note>}
      <SectionCard title={t('stp.rs.list')}>
        {q.isLoading ? <SkeletonRows rows={5} /> : (
          <div className="relative overflow-x-auto">
            <table className="w-full min-w-[640px] text-[14px] md:min-w-0" data-testid="rs-table">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('stp.rs.reason')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('stp.rs.direction')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('stp.rs.glKey')}</th>
                <th scope="col" className="w-[30%] px-4 py-2.5 text-start">{t('stp.rs.acct')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>{(q.data?.reasons ?? []).map((r) => (
                <tr key={r.code} className="border-t border-line align-top" data-reason={r.code}>
                  <td className="px-4 py-2.5"><span className="font-mono text-[13px]">{r.code}</span><div dir="auto">{r.name}</div></td>
                  <td className="px-4 py-2.5 max-sm:hidden">{t(`stp.rs.dir.${r.direction}`)}</td>
                  <td className="px-4 py-2.5">
                    {canW ? (
                      <select id={`rs-key-${r.code}`} aria-label={t('stp.rs.glKeyFor', { code: r.code })} className="input min-h-[40px] py-0 text-sm text-ink" value={r.gl_key ? `${r.gl_area}/${r.gl_key}` : ''}
                        onChange={(e) => save({ code: r.code, name: r.name, direction: r.direction, acct_code: r.acct_code ?? '', active: r.active, gl_key: e.target.value }, t('stp.rs.saved', { code: r.code }))}>
                        <option value="">{t('stp.rs.noKey')}</option>
                        {keyOpts.map((k) => <option key={`${k.area}/${k.posting_key}`} value={`${k.area}/${k.posting_key}`}>{t(`stp.gl.tab.${k.tab}`)} · {k.label}</option>)}
                      </select>
                    ) : keyLabel(r.gl_area, r.gl_key)}
                  </td>
                  <td className="px-4 py-2.5">
                    <AccountField id={`rs-acct-${r.code}`} company={company} label={t('stp.rs.acctFor', { code: r.code })} disabled={!canW} value={r.acct_code} placeholder={r.gl_key ? t('stp.rs.fromKey') : t('fs.gl.notSet')}
                      onChange={(a) => save({ code: r.code, name: r.name, direction: r.direction, acct_code: a ?? '', active: r.active }, t('stp.rs.saved', { code: r.code }))} />
                  </td>
                  <td className="px-4 py-2.5 max-md:hidden">
                    <label className="inline-flex min-h-[40px] items-center gap-2 text-sm"><input type="checkbox" className="h-5 w-5" disabled={!canW} checked={r.active} aria-label={t('stp.rs.activeFor', { code: r.code })}
                      onChange={(e) => save({ code: r.code, name: r.name, direction: r.direction, acct_code: r.acct_code ?? '', active: e.target.checked }, t('stp.rs.saved', { code: r.code }))} />{r.active ? t('stp.active') : t('stp.inactive')}</label>
                  </td>
                </tr>
              ))}</tbody>
            </table>
            {(q.data?.reasons ?? []).length === 0 && <EmptyState title={t('stp.rs.empty')} body={t('stp.rs.emptyBody')} />}
          </div>
        )}
        {canW && (
          <div className="grid grid-cols-1 gap-3 border-t border-line p-4 sm:grid-cols-2 lg:grid-cols-[120px_1fr_140px_1fr_auto] lg:items-end">
            <Field label={t('stp.rs.code')}><input id="rs-new-code" dir="ltr" className="input mt-1 font-mono text-[15px] text-ink" value={nr.code} onChange={(e) => setNr({ ...nr, code: e.target.value })} /></Field>
            <Field label={t('stp.name')}><input id="rs-new-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={nr.name} onChange={(e) => setNr({ ...nr, name: e.target.value })} /></Field>
            <Field label={t('stp.rs.direction')}>
              <select id="rs-new-dir" className="input mt-1 text-[15px] text-ink" value={nr.direction} onChange={(e) => setNr({ ...nr, direction: e.target.value })}>
                {(['out', 'in', 'both'] as const).map((d) => <option key={d} value={d}>{t(`stp.rs.dir.${d}`)}</option>)}
              </select>
            </Field>
            <Field label={t('stp.rs.glKey')}>
              <select id="rs-new-key" className="input mt-1 text-[15px] text-ink" value={nr.gl_key} onChange={(e) => setNr({ ...nr, gl_key: e.target.value })}>
                <option value="">{t('stp.rs.noKey')}</option>
                {keyOpts.map((k) => <option key={`${k.area}/${k.posting_key}`} value={`${k.area}/${k.posting_key}`}>{t(`stp.gl.tab.${k.tab}`)} · {k.label}</option>)}
              </select>
            </Field>
            <Button variant="secondary" id="rs-add" disabled={!nr.code.trim() || !nr.name.trim()} icon={<Plus className="h-4 w-4" aria-hidden />}
              onClick={async () => { if (await save({ ...nr, acct_code: '' }, t('stp.rs.added', { code: nr.code.toUpperCase() }))) setNr({ code: '', name: '', direction: 'out', gl_key: '', acct_code: null }); }}>{t('stp.rs.add')}</Button>
          </div>
        )}
      </SectionCard>
      <p className="mt-4 text-sm text-muted">{t('stp.rs.note')}</p>
    </RequireModule>
  );
}

// ---------------------------------------------------------------- C4 · Landed cost types
const LC_METHODS: LcMethod[] = ['qty', 'weight', 'cbm', 'value', 'equal'];
export function LandedCostTypesPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useSetupCompany();
  const { company } = sc;
  const q = useLcSetup(company);
  const fs = useFlashState();
  const [nc, setNc] = useState({ code: '', name: '', split_method: 'value' as LcMethod });
  const S = q.data;
  async function save(c: Record<string, unknown>, msg: string) {
    fs.setErr(null);
    try { await lcTypeSave(company, c); fs.setFlash(msg); await qc.invalidateQueries({ queryKey: ['lc-setup', company] }); return true; }
    catch (e) { fs.setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); return false; }
  }
  return (
    <RequireModule module="purchasing">
      <SetupTitle module="purchasing" title={t('stp.lc.title')} desc={t('stp.lc.desc')} actions={<CompanyPick sc={sc} />} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err ?? (q.error ? errorMessage(q.error) : null)} />
      {S && <Note>{t('stp.lc.accounts', { clearing: S.clearing_acct ?? t('fs.gl.notSet'), pd: S.price_difference_acct ?? t('fs.gl.notSet') })}</Note>}
      <SectionCard title={t('stp.lc.types')}>
        {q.isLoading ? <SkeletonRows rows={5} /> : S && (
          <div className="relative overflow-x-auto">
            <table className="w-full min-w-[640px] text-[14px] md:min-w-0" data-testid="lc-table">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('stp.lc.type')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('stp.lc.method')}</th>
                <th scope="col" className="w-[34%] px-4 py-2.5 text-start">{t('stp.lc.acct')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>{S.codes.map((c) => {
                const ro = !S.can_write || c.source === 'sap';
                const base = { code: c.code, name: c.name, split_method: c.split_method, active: c.active };
                return (
                  <tr key={c.code} className="border-t border-line align-top" data-lc={c.code}>
                    <td className="px-4 py-2.5"><span className="font-mono text-[13px]">{c.code}</span><div dir="auto">{c.name}</div><div className="text-xs text-muted">{sourceLabel(c.source, t)}</div></td>
                    <td className="px-4 py-2.5">
                      <select id={`lc-method-${c.code}`} aria-label={t('stp.lc.methodFor', { code: c.code })} disabled={ro} className="input min-h-[40px] py-0 text-sm text-ink" value={c.split_method}
                        onChange={(e) => save({ ...base, split_method: e.target.value }, t('stp.lc.saved', { code: c.code }))}>
                        {LC_METHODS.map((m) => <option key={m} value={m}>{t(`stp.lc.m.${m}`)}</option>)}
                      </select>
                    </td>
                    <td className="px-4 py-2.5">
                      <AccountField id={`lc-acct-${c.code}`} company={company} label={t('stp.lc.acctFor', { code: c.code })} disabled={ro || !S.can_finance} value={c.acct_code} name={c.acct_name}
                        placeholder={t('stp.lc.clearing', { acct: S.clearing_acct ?? '—' })} onChange={(a) => save({ ...base, acct_code: a ?? '' }, t('stp.lc.saved', { code: c.code }))} />
                    </td>
                    <td className="px-4 py-2.5 max-md:hidden">
                      <label className="inline-flex min-h-[40px] items-center gap-2 text-sm"><input type="checkbox" className="h-5 w-5" disabled={ro} checked={c.active} aria-label={t('stp.lc.activeFor', { code: c.code })}
                        onChange={(e) => save({ ...base, active: e.target.checked }, t('stp.lc.saved', { code: c.code }))} />{c.active ? t('stp.active') : t('stp.inactive')}</label>
                    </td>
                  </tr>
                );
              })}</tbody>
            </table>
            {S.codes.length === 0 && <EmptyState title={t('stp.lc.empty')} body={t('stp.lc.emptyBody')} />}
          </div>
        )}
        {S?.can_write && (
          <div className="grid grid-cols-1 gap-3 border-t border-line p-4 sm:grid-cols-[140px_1fr_200px_auto] sm:items-end">
            <Field label={t('stp.rs.code')}><input id="lc-new-code" dir="ltr" className="input mt-1 font-mono text-[15px] text-ink" value={nc.code} onChange={(e) => setNc({ ...nc, code: e.target.value })} /></Field>
            <Field label={t('stp.name')}><input id="lc-new-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={nc.name} onChange={(e) => setNc({ ...nc, name: e.target.value })} /></Field>
            <Field label={t('stp.lc.method')}>
              <select id="lc-new-method" className="input mt-1 text-[15px] text-ink" value={nc.split_method} onChange={(e) => setNc({ ...nc, split_method: e.target.value as LcMethod })}>
                {LC_METHODS.map((m) => <option key={m} value={m}>{t(`stp.lc.m.${m}`)}</option>)}
              </select>
            </Field>
            <Button variant="secondary" id="lc-add" disabled={!nc.code.trim() || !nc.name.trim()} icon={<Plus className="h-4 w-4" aria-hidden />}
              onClick={async () => { if (await save(nc, t('stp.lc.added', { code: nc.code.toUpperCase() }))) setNc({ code: '', name: '', split_method: 'value' }); }}>{t('stp.lc.add')}</Button>
          </div>
        )}
      </SectionCard>
      <p className="mt-4 text-sm text-muted">{t('stp.lc.note')}</p>
    </RequireModule>
  );
}

// ---------------------------------------------------------------- C7 · Production resources
export function ResourcesPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useSetupCompany();
  const { company } = sc;
  const q = useProdSetup(company);
  const absorb = useAbsorptionAcct(company);
  const fs = useFlashState();
  const [edit, setEdit] = useState<(Resource & { isNew?: boolean }) | null>(null);
  const S = q.data;
  const rows = useMemo(() => (S?.resources ?? []).filter((r) => r.kind !== 'mould'), [S]);
  const moulds = (S?.resources ?? []).length - rows.length;
  return (
    <RequireModule module="production">
      <SetupTitle module="production" title={t('stp.res.title')} desc={t('stp.res.desc')} actions={
        <div className="flex flex-wrap items-end gap-3"><CompanyPick sc={sc} />
          {S?.can_write && <Button variant="primary" id="res-new" onClick={() => setEdit({ code: '', name: '', kind: 'machine', unit: 'hour', unit_cost: 0, acct_code: null, active: true, isNew: true })} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('stp.res.new')}</Button>}
        </div>} />
      <Flash text={fs.flash} />
      <ErrorBox text={fs.err ?? (q.error ? errorMessage(q.error) : null)} />
      <Note>{absorb.data ? t('stp.res.absorb', { acct: absorb.data }) : t('stp.res.absorbNone')}</Note>
      {edit && <ResourceForm company={company} r={edit} canFinance={Boolean(S?.can_finance)} absorb={absorb.data ?? null} currency={S?.currency ?? ''}
        onClose={() => setEdit(null)} onSaved={(m) => { setEdit(null); fs.setFlash(m); fs.setErr(null); qc.invalidateQueries({ queryKey: ['prod-setup-b3', company] }); }} />}
      <div className="card relative overflow-x-auto">
        {q.isLoading ? <SkeletonRows rows={4} /> : (
          <table className="w-full text-[14px]" data-testid="res-table">
            <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
              <th scope="col" className="px-4 py-2.5 text-start">{t('stp.res.resource')}</th>
              <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('stp.res.kind')}</th>
              <th scope="col" className="px-4 py-2.5 text-end">{t('stp.res.rate')}</th>
              <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('stp.res.acct')}</th>
              <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('erp.col.status')}</th>
            </tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.code} className="border-t border-line hover:bg-surface-2" data-res={r.code}>
                <td className="px-4 py-2.5">
                  {S?.can_write ? <button type="button" className="font-mono text-[13px] text-primary hover:underline" id={`res-edit-${r.code}`} onClick={() => setEdit(r)}>{r.code}</button> : <span className="font-mono text-[13px]">{r.code}</span>}
                  <div dir="auto">{r.name}</div>
                </td>
                <td className="px-4 py-2.5 max-sm:hidden">{t(`stp.res.k.${r.kind}`)}</td>
                <td className="num px-4 py-2.5 text-end">{Number(r.unit_cost).toFixed(2)} {S?.currency} / {t(`stp.res.u.${r.unit}`)}</td>
                <td className="px-4 py-2.5 max-md:hidden">{r.acct_code ? <span className="font-mono text-[13px]">{r.acct_code}</span> : <span className="text-muted">{t('stp.res.viaAbsorb')}</span>}</td>
                <td className="px-4 py-2.5 max-sm:hidden"><span className={clsx('pill', r.active ? 'pill-ok' : 'pill-neutral')}>{r.active ? t('stp.active') : t('stp.inactive')}</span></td>
              </tr>
            ))}</tbody>
          </table>
        )}
        {!q.isLoading && rows.length === 0 && <EmptyState title={t('stp.res.empty')} body={t('stp.res.emptyBody')} />}
      </div>
      <p className="mt-4 text-sm text-muted">{t('stp.res.note', { count: moulds })} <Link className="text-primary hover:underline" to="/production/moulds">{t('stp.res.moulds')}</Link></p>
    </RequireModule>
  );
}

function ResourceForm({ company, r, canFinance, absorb, currency, onClose, onSaved }: {
  company: string; r: Resource & { isNew?: boolean }; canFinance: boolean; absorb: string | null; currency: string; onClose: () => void; onSaved: (m: string) => void;
}) {
  const { t } = useTranslation();
  const [f, setF] = useState({ res_code: r.code, name: r.name, kind: r.kind, unit: r.unit, unit_cost: String(r.unit_cost ?? 0), acct_code: r.acct_code, active: r.active });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function save() {
    setErr(null); setBusy(true);
    try { await resourceSave(company, { ...f, acct_code: f.acct_code ?? '', edit: !r.isNew }); onSaved(r.isNew ? t('stp.res.created', { code: f.res_code.toUpperCase() }) : t('stp.res.saved', { code: f.res_code })); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <SectionCard className="mb-5" title={r.isNew ? t('stp.res.new') : t('stp.res.editTitle', { code: r.code })}>
      <div className="p-5"><ErrorBox text={err} />
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <Field label={t('stp.res.code')}><input id="res-code" dir="ltr" disabled={!r.isNew} className="input mt-1 font-mono text-[15px] text-ink" value={f.res_code} onChange={(e) => setF({ ...f, res_code: e.target.value })} /></Field>
          <Field label={t('stp.name')}><input id="res-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <Field label={t('stp.res.kind')}>
            <select id="res-kind" className="input mt-1 text-[15px] text-ink" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as Resource['kind'] })}>
              {(['machine', 'labour', 'other'] as const).map((k) => <option key={k} value={k}>{t(`stp.res.k.${k}`)}</option>)}
            </select>
          </Field>
          <Field label={t('stp.res.unit')}>
            <select id="res-unit" className="input mt-1 text-[15px] text-ink" value={f.unit} onChange={(e) => setF({ ...f, unit: e.target.value as Resource['unit'] })}>
              {(['hour', 'unit'] as const).map((u) => <option key={u} value={u}>{t(`stp.res.u.${u}`)}</option>)}
            </select>
          </Field>
          <Field label={t('stp.res.rateLabel', { unit: t(`stp.res.u.${f.unit}`), cur: currency })}><input id="res-rate" inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={f.unit_cost} onChange={(e) => setF({ ...f, unit_cost: e.target.value })} /></Field>
          <div className="min-w-0">
            <span className="mb-1 block text-xs font-medium text-muted">{t('stp.res.acct')}</span>
            <AccountField id="res-acct" company={company} label={t('stp.res.acct')} disabled={!canFinance} value={f.acct_code}
              placeholder={absorb ? t('stp.res.viaAbsorbAcct', { acct: absorb }) : t('fs.gl.notSet')} onChange={(a) => setF({ ...f, acct_code: a })} />
          </div>
          <label className="inline-flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" id="res-active" className="h-5 w-5" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} />{t('stp.active')}</label>
        </div>
      </div>
      <div className="flex justify-end gap-2 border-t border-line p-4">
        <Button variant="ghost" onClick={onClose}>{t('fs.cancel')}</Button>
        <Button variant="primary" id="res-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('stp.save')}</Button>
      </div>
    </SectionCard>
  );
}

/** Links to the B3 setup windows (on the existing Inventory / Purchasing setup pages). */
export function SetupLinks({ links }: { links: Array<[string, string, string]> }) {
  return (
    <div className="mb-5 flex flex-wrap gap-2" data-testid="stp-links">
      {links.map(([to, label, id]) => <Link key={to} id={id} to={to} className="inline-flex min-h-[40px] items-center rounded-btn border border-line bg-surface px-3 text-sm font-medium hover:bg-page">{label}</Link>)}
    </div>
  );
}

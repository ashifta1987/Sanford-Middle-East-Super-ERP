import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { RefreshCw } from 'lucide-react';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { KeyNumber } from '../components/KeyNumber';
import { StatusPill, type Tone } from '../components/StatusPill';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { useAuth } from '@/auth/AuthProvider';
import { errorMessage, fmtDate, fmtInt } from '@/lib/format';
import { CF_PAGE, useCfList, useCfMutations, useCfSetup, type CfDecision, type CfFilter, type CustomField } from '../more';

const decTone: Record<CfDecision, Tone> = { mapped: 'ok', raw_only: 'neutral', drop: 'warning' };
type Action = { kind: 'mapped' | 'raw_only' | 'drop' | 'approve' | 'reject' };
const keyOf = (r: CustomField) => `${r.table_name}|${r.field_name}`;

/** A12 · Custom-field register: one line per U_ field and @ table, mapped / SAP copy only / drop (owner approves drops). */
export function CustomFieldsPage() {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const [params, setParams] = useSearchParams();
  const companies = profile?.companies ?? [];
  const company = params.get('company') ?? companies[0]?.company_code ?? '';
  const setup = useCfSetup(company || undefined);
  const [f, setF] = useState<CfFilter>({ search: '', table: '', decision: '', unused: false, page: 0 });
  const [searchText, setSearchText] = useState('');
  const list = useCfList(setup.data ? company : undefined, f);
  const m = useCfMutations(company);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [action, setAction] = useState<Action | null>(null);
  const [flash, setFlash] = useState<string | null>(null);

  useEffect(() => { const h = setTimeout(() => setF((x) => ({ ...x, search: searchText, page: 0 })), 300); return () => clearTimeout(h); }, [searchText]);
  useEffect(() => { setSel(new Set()); }, [company, f]);

  const rows = useMemo(() => list.data?.rows ?? [], [list.data]);
  const selected = rows.filter((r) => sel.has(keyOf(r)));
  const items = selected.map((r) => ({ table: r.table_name, field: r.field_name }));
  const s = setup.data?.summary;
  const pending = selected.filter((r) => r.decision === 'drop' && r.drop_state === 'pending');
  const busy = m.decide.isPending || m.drop.isPending;
  const err = m.decide.error ?? m.drop.error;

  if (!company) return <EmptyState title={t('migration.fields.noCompany')} />;
  if (setup.isLoading) return <PageLoading />;

  function run(note: string) {
    if (!action) return;
    const n = items.length;
    const onSuccess = () => { setAction(null); setSel(new Set()); setFlash(t(`migration.fields.done.${action.kind}`, { n })); };
    if (action.kind === 'approve' || action.kind === 'reject') {
      m.drop.mutate({ items: pending.map((r) => ({ table: r.table_name, field: r.field_name })), approve: action.kind === 'approve', note: note || null }, { onSuccess });
    } else {
      m.decide.mutate({ items, decision: action.kind, target: action.kind === 'mapped' ? note : null, note: action.kind === 'mapped' ? null : note || null }, { onSuccess });
    }
  }

  const toggleAll = () => setSel(sel.size === rows.length ? new Set() : new Set(rows.map(keyOf)));
  const pages = Math.max(1, Math.ceil((list.data?.count ?? 0) / CF_PAGE));

  return (
    <div className="space-y-6">
      <PageHeader
        crumb={t('migration.fields.crumb')}
        title={t('migration.fields.title', { code: company })}
        subtitle={t('migration.fields.subtitle')}
        right={
          <div className="w-full sm:w-[320px]">
            <label htmlFor="cf-company" className="mb-1 block text-sm text-muted">{t('top.company')}</label>
            <select id="cf-company" className="input" value={company} onChange={(e) => setParams({ company: e.target.value })}>
              {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.legal_name}</option>)}
            </select>
          </div>
        }
      />
      {setup.error ? <ErrorState error={setup.error} onRetry={() => setup.refetch()} /> : (
        <>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <KeyNumber label={t('migration.fields.kTotal')} value={fmtInt(s?.total ?? 0)} note={t('migration.fields.kTotalNote', { fields: fmtInt(s?.fields ?? 0), tables: fmtInt(s?.tables ?? 0) })} />
            <KeyNumber label={t('migration.fields.kMapped')} value={fmtInt(s?.mapped ?? 0)} tone="ok" note={t('migration.fields.kMappedNote')} />
            <KeyNumber label={t('migration.fields.kRaw')} value={fmtInt(s?.raw_only ?? 0)} note={t('migration.fields.kRawNote', { n: fmtInt(s?.unused ?? 0) })} />
            <KeyNumber label={t('migration.fields.kDrop')} value={fmtInt(s?.drop_pending ?? 0)} tone={s?.drop_pending ? 'warning' : 'neutral'}
              note={t('migration.fields.kDropNote', { n: fmtInt(s?.drop_approved ?? 0), owner: setup.data?.owner_position ?? '—' })} />
          </div>

          {flash && <p role="status" className="card bg-ok-bg p-4 text-ok-fg">{flash}</p>}
          {m.build.error && <p role="alert" className="card bg-crit-bg p-4 text-crit-fg">{errorMessage(m.build.error)}</p>}

          <Card
            title={t('migration.fields.listTitle')}
            actions={
              <div className="flex flex-wrap items-center gap-3">
                <span className="text-sm text-muted">
                  {setup.data?.built_at ? t('migration.fields.built', { when: fmtDate(setup.data.built_at), source: setup.data.dict_source ?? '' }) : t('migration.fields.notBuilt')}
                </span>
                {setup.data?.can_edit && (
                  <Button icon={<RefreshCw className="h-4 w-4" aria-hidden />} disabled={m.build.isPending}
                    onClick={() => m.build.mutate(undefined, { onSuccess: (n) => setFlash(t('migration.fields.rebuilt', { n })) })}>
                    {m.build.isPending ? t('migration.fields.building') : t('migration.fields.rebuild')}
                  </Button>
                )}
              </div>
            }
          >
            <div className="grid gap-3 border-b border-line p-4 sm:grid-cols-2 lg:grid-cols-[minmax(0,1fr)_200px_200px_auto]">
              <div>
                <label htmlFor="cf-search" className="mb-1 block text-sm text-muted">{t('migration.fields.search')}</label>
                <input id="cf-search" className="input" value={searchText} onChange={(e) => setSearchText(e.target.value)} placeholder={t('migration.fields.searchPh')} />
              </div>
              <div>
                <label htmlFor="cf-table" className="mb-1 block text-sm text-muted">{t('migration.fields.colTable')}</label>
                <select id="cf-table" className="input" value={f.table} onChange={(e) => setF((x) => ({ ...x, table: e.target.value, page: 0 }))}>
                  <option value="">{t('migration.fields.all')}</option>
                  {(setup.data?.tables ?? []).map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
              </div>
              <div>
                <label htmlFor="cf-dec" className="mb-1 block text-sm text-muted">{t('migration.fields.colDecision')}</label>
                <select id="cf-dec" className="input" value={f.decision} onChange={(e) => setF((x) => ({ ...x, decision: e.target.value as CfFilter['decision'], page: 0 }))}>
                  <option value="">{t('migration.fields.all')}</option>
                  <option value="mapped">{t('migration.fields.dec.mapped')}</option>
                  <option value="raw_only">{t('migration.fields.dec.raw_only')}</option>
                  <option value="drop">{t('migration.fields.dec.drop')}</option>
                  <option value="drop_pending">{t('migration.fields.dropPending')}</option>
                </select>
              </div>
              <label className="flex min-h-[44px] items-center gap-2 self-end text-sm">
                <input type="checkbox" className="h-5 w-5" checked={f.unused} onChange={(e) => setF((x) => ({ ...x, unused: e.target.checked, page: 0 }))} />
                {t('migration.fields.unusedOnly')}
              </label>
            </div>

            {selected.length > 0 && (
              <div className="flex flex-wrap items-center gap-2 border-b border-line bg-primary-soft px-4 py-3" aria-live="polite">
                <span className="me-2 text-sm font-medium text-primary-text">{t('migration.fields.selected', { n: selected.length })}</span>
                {setup.data?.can_edit && (
                  <>
                    <Button className="min-h-[40px] px-3 text-sm" onClick={() => setAction({ kind: 'mapped' })} disabled={selected.length !== 1}>{t('migration.fields.actMap')}</Button>
                    <Button className="min-h-[40px] px-3 text-sm" onClick={() => setAction({ kind: 'raw_only' })}>{t('migration.fields.actRaw')}</Button>
                    <Button className="min-h-[40px] px-3 text-sm" onClick={() => setAction({ kind: 'drop' })}>{t('migration.fields.actDrop')}</Button>
                  </>
                )}
                {setup.data?.can_approve_drop && pending.length > 0 && (
                  <>
                    <Button variant="success" className="min-h-[40px] px-3 text-sm" onClick={() => setAction({ kind: 'approve' })}>{t('migration.fields.actApprove', { n: pending.length })}</Button>
                    <Button variant="danger" className="min-h-[40px] px-3 text-sm" onClick={() => setAction({ kind: 'reject' })}>{t('migration.fields.actReject')}</Button>
                  </>
                )}
              </div>
            )}

            {list.isLoading ? <SkeletonRows rows={6} /> : list.error ? <ErrorState error={list.error} onRetry={() => list.refetch()} /> : (
              <DataTable
                caption={t('migration.fields.listTitle')}
                rows={rows}
                rowKey={keyOf}
                minWidth={860}
                empty={<EmptyState body={s?.total ? t('migration.fields.noMatch') : t('migration.fields.empty')} />}
                columns={[
                  { key: 'sel', header: <input type="checkbox" className="h-5 w-5" aria-label={t('migration.fields.selectAll')} checked={rows.length > 0 && sel.size === rows.length} onChange={toggleAll} />,
                    cell: (r) => <input type="checkbox" className="h-5 w-5" aria-label={`${r.table_name} ${r.field_name}`} checked={sel.has(keyOf(r))}
                      onChange={() => setSel((x) => { const n = new Set(x); if (n.has(keyOf(r))) n.delete(keyOf(r)); else n.add(keyOf(r)); return n; })} /> },
                  { key: 't', header: t('migration.fields.colTable'), mono: true, cell: (r) => r.table_name },
                  { key: 'f', header: t('migration.fields.colField'), mono: true, cell: (r) => (r.kind === 'table' ? <span className="font-sans italic text-muted">{t('migration.fields.wholeTable')}</span> : r.field_name) },
                  { key: 'd', header: t('migration.fields.colDesc'), cell: (r) => <span dir="auto">{r.description ?? '—'}{r.field_type ? <span className="ms-1 text-xs text-muted">{r.field_type}</span> : null}</span> },
                  { key: 'u', header: t('migration.fields.colUsed'), align: 'end', cell: (r) => (!r.in_raw ? <span className="text-muted">{t('migration.fields.notInCopy')}</span>
                    : <span title={r.last_used ? t('migration.fields.lastUsed', { when: fmtDate(r.last_used) }) : undefined}>{fmtInt(r.rows_used ?? 0)} / {fmtInt(r.total_rows ?? 0)}</span>) },
                  { key: 'dec', header: t('migration.fields.colDecision'), cell: (r) => (
                    <span className="flex flex-wrap items-center gap-1">
                      <StatusPill tone={decTone[r.decision]}>{t(`migration.fields.dec.${r.decision}`)}</StatusPill>
                      {r.drop_state && <StatusPill tone={r.drop_state === 'approved' ? 'ok' : r.drop_state === 'rejected' ? 'critical' : 'warning'}>{t(`migration.fields.drop.${r.drop_state}`)}</StatusPill>}
                      {!r.decided_by && <span className="text-xs text-muted">{t('migration.fields.auto')}</span>}
                    </span>) },
                  { key: 'tg', header: t('migration.fields.colTarget'), mono: true, cell: (r) => r.target ?? '—' },
                ]}
              />
            )}
            {pages > 1 && (
              <div className="flex items-center justify-between gap-2 border-t border-line px-4 py-3 text-sm">
                <span className="text-muted">{t('migration.fields.page', { a: f.page + 1, b: pages, n: fmtInt(list.data?.count ?? 0) })}</span>
                <div className="flex gap-2">
                  <Button className="min-h-[40px] px-3 text-sm" disabled={f.page === 0} onClick={() => setF((x) => ({ ...x, page: x.page - 1 }))}>{t('migration.fields.prev')}</Button>
                  <Button className="min-h-[40px] px-3 text-sm" disabled={f.page + 1 >= pages} onClick={() => setF((x) => ({ ...x, page: x.page + 1 }))}>{t('migration.fields.next')}</Button>
                </div>
              </div>
            )}
          </Card>
          <p className="text-sm text-muted">{t('migration.fields.footnote')}</p>
        </>
      )}

      <ConfirmDialog
        open={!!action}
        title={action ? t(`migration.fields.dlg.${action.kind}`, { n: action.kind === 'approve' || action.kind === 'reject' ? pending.length : selected.length }) : ''}
        body={action ? <span className="font-mono text-sm">{(action.kind === 'approve' || action.kind === 'reject' ? pending : selected).slice(0, 8).map((r) => `${r.table_name}.${r.field_name || '*'}`).join(', ')}</span> : null}
        tone={action?.kind === 'reject' || action?.kind === 'drop' ? 'danger' : 'primary'}
        confirmLabel={action ? t(`migration.fields.ok.${action.kind}`) : undefined}
        noteLabel={action?.kind === 'mapped' ? t('migration.fields.targetLabel') : action?.kind === 'reject' ? t('migration.fields.reasonLabel') : t('migration.fields.noteLabel')}
        noteRequired={action?.kind === 'mapped' || action?.kind === 'reject'}
        busy={busy}
        error={err ? errorMessage(err) : null}
        onConfirm={run}
        onClose={() => { setAction(null); m.decide.reset(); m.drop.reset(); }}
      />
    </div>
  );
}

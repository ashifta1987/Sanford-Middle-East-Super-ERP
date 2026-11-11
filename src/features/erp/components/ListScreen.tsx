import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Download, Search, X } from 'lucide-react';
import { useCompany } from '@/layout/CompanyContext';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { errorMessage, fmtInt } from '@/lib/format';
import { exportCsv, useErpList, useOptions, type FilterValue, type ListRequest, type Row } from '../api';

export interface ListColumn<T extends Row> {
  key: string;
  header: string;
  cell?: (r: T) => ReactNode;
  csv?: (r: T) => unknown;
  align?: 'end';
  mono?: boolean;
  sortable?: boolean;
  /** hide below this breakpoint to keep phones readable */
  hideBelow?: 'sm' | 'md' | 'lg';
}
export interface ListFilter {
  key: string;
  label: string;
  options?: Array<[string, string]>;
  /** load options from a code table */
  from?: { table: string; value: string; label: string };
  /** filter value type sent to the database */
  type?: 'text' | 'number' | 'boolean';
}
export interface ListConfig<T extends Row> {
  id: string;
  table: string;
  select: string;
  searchCols: string[];
  numberSearchCols?: string[];
  searchLabel: string;
  columns: ListColumn<T>[];
  filters?: ListFilter[];
  fixed?: Record<string, FilterValue>;
  defaultSort: { col: string; asc: boolean };
  rowKey: (r: T) => string;
  rowLink?: (r: T) => string;
  enrich?: (rows: T[]) => Promise<T[]>;
  pageSize?: number;
  emptyTitle?: string;
  emptyBody?: string;
}

const hideCls = { sm: 'max-sm:hidden', md: 'max-md:hidden', lg: 'max-lg:hidden' } as const;

function FilterSelect({ f, value, onChange, company }: { f: ListFilter; value: string; onChange: (v: string) => void; company: string }) {
  const { t } = useTranslation();
  const opts = useOptions(f.from?.table ?? '', f.from?.value ?? '', f.from?.label ?? '', company);
  const list = f.options ?? (f.from ? opts.data ?? [] : []);
  return (
    <label className="flex min-w-[150px] flex-col gap-1 text-xs font-medium text-muted">
      {f.label}
      <select value={value} onChange={(e) => onChange(e.target.value)} className="input min-h-[40px] py-0 text-sm">
        <option value="">{t('erp.list.all')}</option>
        {list.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </label>
  );
}

/** Generic list: server-side search, filters, sort, paging and CSV export. State lives in the URL so Back works. */
export function ListScreen<T extends Row>({ config, toolbar }: { config: ListConfig<T>; toolbar?: ReactNode }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const { company } = useCompany();
  const [sp, setSp] = useSearchParams();
  const q = sp.get('q') ?? '';
  const [draft, setDraft] = useState(q);
  const page = Math.max(0, Number(sp.get('page') ?? 0) || 0);
  const sortCol = sp.get('sort') ?? config.defaultSort.col;
  const asc = sp.has('sort') ? sp.get('dir') === 'asc' : config.defaultSort.asc;
  const pageSize = config.pageSize ?? 25;
  const [exporting, setExporting] = useState<string | null>(null);

  useEffect(() => setDraft(q), [q]);
  // Debounced search: typing updates the URL 300 ms after the last key.
  useEffect(() => {
    if (draft === q) return;
    const h = setTimeout(() => update({ q: draft || null, page: null }), 300);
    return () => clearTimeout(h);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft]);

  function update(changes: Record<string, string | null>) {
    const next = new URLSearchParams(sp);
    for (const [k, v] of Object.entries(changes)) (v === null || v === '' ? next.delete(k) : next.set(k, v));
    setSp(next, { replace: true });
  }

  const filterValues = useMemo(() => {
    const out: Record<string, FilterValue | ''> = { ...(config.fixed ?? {}) };
    for (const f of config.filters ?? []) {
      const raw = sp.get(`f_${f.key}`) ?? '';
      out[f.key] = raw === '' ? '' : f.type === 'number' ? Number(raw) : f.type === 'boolean' ? raw === 'true' : raw;
    }
    return out;
  }, [sp, config.filters, config.fixed]);

  const req: ListRequest = {
    table: config.table, select: config.select, searchCols: config.searchCols, numberSearchCols: config.numberSearchCols,
    q, filters: filterValues, order: { col: sortCol, asc }, page, pageSize, company,
  };
  const list = useErpList<T>(config.id, req, config.enrich);
  const count = list.data?.count ?? 0;
  const pages = Math.max(1, Math.ceil(count / pageSize));
  const activeFilters = (config.filters ?? []).filter((f) => sp.get(`f_${f.key}`));

  function sortBy(col: string) {
    if (col === sortCol) update({ sort: col, dir: asc ? 'desc' : 'asc', page: null });
    else update({ sort: col, dir: 'asc', page: null });
  }

  async function onExport() {
    setExporting(t('erp.list.exporting'));
    try {
      const n = await exportCsv(req, config.columns.map((c) => ({ key: c.key, header: c.header, csv: c.csv as ((r: Row) => unknown) | undefined })), config.id);
      setExporting(t('erp.list.exported', { count: n }));
    } catch (e) {
      setExporting(errorMessage(e));
    }
    setTimeout(() => setExporting(null), 4000);
  }

  return (
    <div className="card overflow-hidden">
      <div className="flex flex-wrap items-end gap-3 border-b border-line p-4">
        <label className="flex min-w-[220px] flex-1 flex-col gap-1 text-xs font-medium text-muted">
          {t('erp.list.search')}
          <span className="relative">
            <Search className="pointer-events-none absolute start-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" aria-hidden />
            <input
              type="search"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') update({ q: draft || null, page: null }); }}
              placeholder={config.searchLabel}
              className="input min-h-[40px] ps-9 text-sm"
            />
          </span>
        </label>
        {(config.filters ?? []).map((f) => (
          <FilterSelect key={f.key} f={f} company={company} value={sp.get(`f_${f.key}`) ?? ''} onChange={(v) => update({ [`f_${f.key}`]: v || null, page: null })} />
        ))}
        <div className="ms-auto flex items-center gap-2">
          {toolbar}
          <Button variant="secondary" onClick={onExport} disabled={!count || Boolean(exporting)}>
            <Download className="h-4 w-4" aria-hidden /> {t('erp.list.export')}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-2 text-sm text-muted" aria-live="polite">
        <span>
          {list.isLoading ? t('app.loading') : t('erp.list.count', { count, n: fmtInt(count) })}
          {list.isFetching && !list.isLoading && <span className="ms-2">· {t('erp.list.updating')}</span>}
        </span>
        <span className="flex flex-wrap items-center gap-2">
          {exporting && <span className="text-ink-2">{exporting}</span>}
          {(q || activeFilters.length > 0) && (
            <button type="button" className="inline-flex items-center gap-1 rounded-btn px-2 py-1 text-primary hover:bg-primary-soft"
              onClick={() => { setDraft(''); const next = new URLSearchParams(); if (sp.get('sort')) { next.set('sort', sortCol); next.set('dir', asc ? 'asc' : 'desc'); } setSp(next, { replace: true }); }}>
              <X className="h-3.5 w-3.5" aria-hidden /> {t('erp.list.clear')}
            </button>
          )}
        </span>
      </div>

      {list.isLoading ? <SkeletonRows rows={8} /> : list.error ? <ErrorState error={list.error} onRetry={() => list.refetch()} /> : !list.data?.rows.length ? (
        <EmptyState title={q || activeFilters.length ? t('erp.list.noMatch') : config.emptyTitle ?? t('erp.list.empty')} body={q || activeFilters.length ? t('erp.list.noMatchBody') : config.emptyBody} />
      ) : (
        <div className="relative overflow-x-auto">
          <table className="w-full border-collapse text-[14px] sm:min-w-[640px]">
            <thead>
              <tr className="border-y border-line bg-surface-2 text-start text-xs font-semibold uppercase tracking-wide text-muted">
                {config.columns.map((c) => {
                  const sortable = c.sortable !== false;
                  const active = sortCol === c.key;
                  return (
                    <th key={c.key} scope="col" aria-sort={active ? (asc ? 'ascending' : 'descending') : undefined}
                      className={clsx('px-4 py-2.5 text-start font-semibold', c.align === 'end' && 'text-end', c.hideBelow && hideCls[c.hideBelow])}>
                      {sortable ? (
                        <button type="button" onClick={() => sortBy(c.key)} className={clsx('inline-flex items-center gap-1 uppercase hover:text-ink', active && 'text-ink')}>
                          {c.header}
                          {active && (asc ? <ArrowUp className="h-3 w-3" aria-hidden /> : <ArrowDown className="h-3 w-3" aria-hidden />)}
                        </button>
                      ) : c.header}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {list.data.rows.map((r) => {
                const link = config.rowLink?.(r);
                return (
                  <tr key={config.rowKey(r)}
                    className={clsx('border-b border-line last:border-0', link && 'cursor-pointer hover:bg-surface-2')}
                    onClick={link ? (e) => { if (!(e.target as HTMLElement).closest('a,button')) nav(link); } : undefined}>
                    {config.columns.map((c, i) => (
                      <td key={c.key} className={clsx('px-4 py-2.5 align-middle', c.align === 'end' && 'num text-end', c.mono && 'font-mono text-[13px]', c.hideBelow && hideCls[c.hideBelow])}>
                        {i === 0 && link
                          ? <a href={link} onClick={(e) => { e.preventDefault(); nav(link); }} className="font-medium text-primary hover:underline">{c.cell ? c.cell(r) : String(r[c.key] ?? '—')}</a>
                          : c.cell ? c.cell(r) : (r[c.key] === null || r[c.key] === undefined || r[c.key] === '' ? <span className="text-muted">—</span> : String(r[c.key]))}
                      </td>
                    ))}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {count > pageSize && (
        <div className="flex items-center justify-between gap-2 border-t border-line px-4 py-3 text-sm">
          <span className="text-muted">{t('erp.list.page', { page: page + 1, pages })}</span>
          <div className="flex gap-2">
            <Button variant="secondary" disabled={page === 0} onClick={() => update({ page: String(page - 1) })} aria-label={t('erp.list.prev')}>
              <ChevronLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> <span className="max-sm:hidden">{t('erp.list.prev')}</span>
            </Button>
            <Button variant="secondary" disabled={page + 1 >= pages} onClick={() => update({ page: String(page + 1) })} aria-label={t('erp.list.next')}>
              <span className="max-sm:hidden">{t('erp.list.next')}</span> <ChevronRight className="h-4 w-4 rtl:rotate-180" aria-hidden />
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

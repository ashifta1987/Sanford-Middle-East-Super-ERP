import { useQuery, keepPreviousData } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';

export type Row = Record<string, unknown>;
export type FilterValue = string | number | boolean;

export interface ListRequest {
  table: string;
  select: string;
  /** columns searched with ilike (text columns only) */
  searchCols?: string[];
  /** integer columns matched exactly when the search text is a number */
  numberSearchCols?: string[];
  q?: string;
  /** equality filters; '' / undefined = not filtered */
  filters?: Record<string, FilterValue | undefined | ''>;
  order: { col: string; asc: boolean };
  page: number;
  pageSize: number;
  /** selected company in the top bar; 'GRP' = all companies the user may see (RLS decides) */
  company: string;
}

/** Remove characters that have meaning inside a PostgREST or() filter. */
const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();

export function buildQuery(r: ListRequest, opts: { count?: boolean } = {}) {
  let qb = erp().from(r.table).select(r.select, opts.count ? { count: 'exact' } : undefined);
  if (r.company && r.company !== 'GRP') qb = qb.eq('company_code', r.company);
  for (const [k, v] of Object.entries(r.filters ?? {})) {
    if (v === '' || v === undefined) continue;
    qb = qb.eq(k, v as string);
  }
  const q = clean(r.q ?? '');
  if (q) {
    const parts = (r.searchCols ?? []).map((c) => `${c}.ilike.*${q}*`);
    if (/^\d{1,9}$/.test(q)) for (const c of r.numberSearchCols ?? []) parts.push(`${c}.eq.${q}`);
    if (parts.length) qb = qb.or(parts.join(','));
  }
  return qb.order(r.order.col, { ascending: r.order.asc, nullsFirst: false });
}

export function useErpList<T extends Row>(key: string, r: ListRequest, enrich?: (rows: T[]) => Promise<T[]>) {
  return useQuery({
    queryKey: ['erp-list', key, r],
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const from = r.page * r.pageSize;
      const { data, error, count } = await buildQuery(r, { count: true }).range(from, from + r.pageSize - 1);
      if (error) throw new ApiError(error);
      const rows = (data ?? []) as unknown as T[];
      return { rows: enrich ? await enrich(rows) : rows, count: count ?? 0 };
    },
  });
}

/** Options for a filter drop-down, read from a code table (e.g. item groups). */
export function useOptions(table: string, value: string, label: string, company: string) {
  return useQuery({
    queryKey: ['erp-options', table, value, label, company],
    staleTime: 5 * 60_000,
    queryFn: async () => {
      let qb = erp().from(table).select(`company_code,${value},${label}`);
      if (company !== 'GRP') qb = qb.eq('company_code', company);
      const { data, error } = await qb.order(label).limit(500);
      if (error) throw new ApiError(error);
      const seen = new Map<string, string>();
      for (const r of (data ?? []) as unknown as Row[]) seen.set(String(r[value]), String(r[label] ?? r[value]));
      return [...seen.entries()];
    },
  });
}

export async function rpc<T>(fn: string, args: Record<string, unknown>) {
  const { data, error } = await erp().rpc(fn, args);
  if (error) throw new ApiError(error);
  return data as T;
}

/** Download up to 5,000 rows of the current list as CSV (same filters and sort as the screen). */
export async function exportCsv(r: ListRequest, columns: Array<{ key: string; header: string; csv?: (row: Row) => unknown }>, name: string) {
  const { data, error } = await buildQuery(r).range(0, 4999);
  if (error) throw new ApiError(error);
  const esc = (v: unknown) => {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const rows = (data ?? []) as unknown as Row[];
  const lines = [columns.map((c) => esc(c.header)).join(','), ...rows.map((row) => columns.map((c) => esc(c.csv ? c.csv(row) : row[c.key])).join(','))];
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${name}-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return rows.length;
}

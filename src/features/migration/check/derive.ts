// Pure helpers for B8: group migration_review rows into areas, finance rows, stock by warehouse, issues.

import type { IssueDetail, MigrationReviewRow } from '@/lib/database.types';
import type { Tone } from '../components/StatusPill';

export const AREAS = ['structure', 'row_counts', 'orphans', 'app_tables', 'finance', 'stock', 'hr'] as const;
/** A12 · reconciliation checks 5.3, 5.5-5.10 and the other checks added by 27_migration_more.sql (shown when the run has them). */
export const MORE_AREAS = ['inventory_gl', 'partners', 'open_orders', 'vat', 'intercompany', 'payroll', 'attachments', 'opening',
  'duplicates', 'custom_fields', 'coexistence'] as const;
export type Area = (typeof AREAS)[number] | (typeof MORE_AREAS)[number];

export const FINANCE_ROWS = [
  'journal lines: debit minus credit',
  'account group assets',
  'account group liabilities',
  'account group equity',
  'account group revenue',
  'account group expenses',
  'account group other / no group',
  'open A/R (invoices + down payments - credit notes)',
  'open A/P (invoices + down payments - credit notes)',
];

export const n = (v: unknown) => (v === null || v === undefined || v === '' ? null : Number(v));

/** Show a value exactly as returned (no rounding): thousands separators, at least 2 decimals for money. */
export function money(v: unknown): string {
  if (v === null || v === undefined || v === '') return '—';
  const s = String(v);
  const neg = s.startsWith('-');
  const [int, dec = ''] = (neg ? s.slice(1) : s).split('.');
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '-' : ''}${grouped}.${dec.padEnd(2, '0')}`;
}
export function qty(v: unknown): string {
  if (v === null || v === undefined || v === '') return '—';
  const [int, dec] = String(v).split('.');
  const neg = int.startsWith('-');
  const g = (neg ? int.slice(1) : int).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '-' : ''}${g}${dec && Number(dec) !== 0 ? '.' + dec : ''}`;
}

export const issueDetail = (r: MigrationReviewRow): IssueDetail =>
  (r.detail && typeof r.detail === 'object' ? (r.detail as IssueDetail) : { detail: typeof r.detail === 'string' ? r.detail : null });

export interface AreaSummary { area: Area; tone: Tone; pill: string; detail: string; total: number; failed: number }

export function summarise(args: {
  t: (k: string, o?: Record<string, unknown>) => string;
  checks: MigrationReviewRow[];
  issues: MigrationReviewRow[];
}): AreaSummary[] {
  const { t, checks, issues } = args;
  const fmt = (x: number | null) => (x == null ? '—' : x.toLocaleString('en-US'));
  const present = MORE_AREAS.filter((a) => checks.some((c) => c.area === a));
  return ([...AREAS, ...present] as Area[]).map((area) => {
    const cs = checks.filter((c) => c.area === area);
    const failed = cs.filter((c) => c.ok === false);
    const openCrit = issues.some((i) => i.area === area && i.status === 'open' && i.severity === 'critical');
    const accepted = issues.filter((i) => i.area === area && i.status === 'accepted').length;
    const notes = issues.filter((i) => i.area === area && i.status === 'open' && i.severity === 'warning').length;
    if (!cs.length) return { area, tone: 'neutral' as Tone, pill: t('migration.check.notRun'), detail: t('migration.check.areaDetail.none'), total: 0, failed: 0 };

    let tone: Tone = 'ok';
    let pill = t('migration.check.match');
    if (area === 'app_tables') pill = t('migration.check.nOfM', { a: cs.length - failed.length, b: cs.length });
    if (openCrit || (failed.length && !accepted)) { tone = 'critical'; pill = t('migration.check.differs', { n: failed.length || 1 }); }
    else if (failed.length || notes) { tone = 'warning'; pill = t('migration.check.noteN', { n: Math.max(failed.length, notes) }); }

    const by = (name: string) => cs.find((c) => c.name === name);
    let detail = '';
    switch (area) {
      case 'structure': {
        const tables = by('tables in field list');
        const det = (tables?.detail ?? {}) as { fields?: number };
        const diff = (n(by('missing columns (in SAP, not in sap schema)')?.raw_value) ?? 0) + (n(by('type mismatches')?.raw_value) ?? 0);
        detail = t('migration.check.areaDetail.structure', { tables: fmt(n(tables?.raw_value)), fields: fmt(n(det.fields)), diff });
        break;
      }
      case 'row_counts': {
        const tbl = cs.filter((c) => !c.name.startsWith('tables skipped'));
        detail = t('migration.check.areaDetail.row_counts', { ok: fmt(tbl.filter((c) => c.ok).length), total: fmt(tbl.length) });
        break;
      }
      case 'orphans': {
        const all = by('orphan rows over all links');
        const links = (all?.detail as { links?: number } | null)?.links;
        detail = t('migration.check.areaDetail.orphans', { links: fmt(n(links)), broken: fmt(n(all?.raw_value) ?? 0) });
        break;
      }
      case 'app_tables': detail = t('migration.check.areaDetail.app_tables'); break;
      case 'finance': detail = t('migration.check.areaDetail.finance', { failed: failed.length }); break;
      case 'stock': {
        const q = by('on hand qty, all warehouses');
        detail = t('migration.check.areaDetail.stock', { qty: qty(q?.raw_value), whs: cs.filter((c) => c.name.startsWith('on hand qty ') && !c.name.includes(',')).length });
        break;
      }
      case 'hr': detail = t('migration.check.areaDetail.hr', { n: fmt(n(by('employees')?.raw_value)), active: fmt(n(by('active employees')?.raw_value)) }); break;
      default: {
        const skipped = cs.filter((c) => (c.detail as { skipped?: boolean } | null)?.skipped).length;
        detail = skipped === cs.length ? t('migration.check.areaDetail.skipped')
          : t('migration.check.areaDetail.more', { total: cs.length - skipped, failed: failed.length, skipped });
      }
    }
    return { area, tone, pill, detail, total: cs.length, failed: failed.length };
  });
}

export interface WarehouseRow { whs: string; qtySap: unknown; qtyApp: unknown; valSap: unknown; valApp: unknown; ok: boolean }

export function stockRows(checks: MigrationReviewRow[]): { rows: WarehouseRow[]; total: WarehouseRow | null } {
  const stock = checks.filter((c) => c.area === 'stock');
  const map = new Map<string, WarehouseRow>();
  for (const c of stock) {
    const m = c.name.match(/^on hand (qty|value) (.+)$/);
    if (!m || m[2] === ', all warehouses' || m[2].startsWith(', ')) continue;
    const w = ((c.detail as { warehouse?: string } | null)?.warehouse) ?? m[2];
    const row = map.get(w) ?? { whs: w, qtySap: null, qtyApp: null, valSap: null, valApp: null, ok: true };
    if (m[1] === 'qty') { row.qtySap = c.raw_value; row.qtyApp = c.app_value; } else { row.valSap = c.raw_value; row.valApp = c.app_value; }
    row.ok = row.ok && c.ok !== false;
    map.set(w, row);
  }
  const tq = stock.find((c) => c.name === 'on hand qty, all warehouses');
  const tv = stock.find((c) => c.name === 'on hand value, all warehouses');
  const total = tq || tv ? { whs: '', qtySap: tq?.raw_value, qtyApp: tq?.app_value, valSap: tv?.raw_value, valApp: tv?.app_value, ok: tq?.ok !== false && tv?.ok !== false } : null;
  return { rows: [...map.values()].sort((a, b) => a.whs.localeCompare(b.whs)), total };
}


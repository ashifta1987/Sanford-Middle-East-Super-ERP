// Pure helpers for B6: merge analyses, derive the checklist / found facts / points to fix from
// the local analysis (before the worker) and from migration_review + migration_file (after).

import type { Analysis, FileFacts } from './classify';
import { structureSummary } from './classify';
import type { MigrationFile, MigrationReviewRow } from '@/lib/database.types';
import { safeKey } from './ResumableUpload';

export function mergeAnalysis(a: Analysis | null, b: Analysis): Analysis {
  if (!a) return b;
  const byPath = new Map<string, FileFacts>();
  for (const f of [...a.files, ...b.files]) byPath.set(f.path, f);
  const files = [...byPath.values()];
  const has = {
    columns: a.has.columns || b.has.columns,
    constraints: a.has.constraints || b.has.constraints,
    rowCounts: a.has.rowCounts || b.has.rowCounts,
    fieldList: a.has.fieldList || b.has.fieldList,
    data: a.has.data || b.has.data,
  };
  const hasArchive = a.hasArchive || b.hasArchive;
  return {
    files,
    dataTables: a.dataTables + b.dataTables,
    dataFiles: a.dataFiles + b.dataFiles,
    dataBytes: a.dataBytes + b.dataBytes,
    hasArchive,
    has,
    structureOnly: !has.data && !hasArchive && has.fieldList,
    totalBytes: a.totalBytes + b.totalBytes,
  };
}

/** What the worker found about the files (migration_file), folded into the same shape as the local analysis. */
export function hasFromWorker(files: MigrationFile[] | undefined) {
  if (!files?.length) return null;
  const k = (kind: MigrationFile['kind']) => files.some((f) => f.kind === kind && f.status !== 'error');
  return {
    columns: k('columns_csv'),
    constraints: k('constraints_csv'),
    rowCounts: k('row_counts_csv'),
    fieldList: k('structure_xlsx') || k('structure_csv'),
    data: files.some((f) => f.kind === 'data_csv'),
  };
}

const num = (v: unknown) => (v === null || v === undefined || v === '' ? null : Number(v));

export interface Found {
  fromWorker: boolean;
  tablesInSap: number | null;
  tablesInErp: number | null;
  leftOut: number | null;
  fieldsCompared: number | null;
  fieldsMissing: number | null;
  typeDiff: number | null;
  itemFields: number | null;
  itemUserFields: number | null;
  repaired: Record<string, number>;
  pct: number | null;
}

export function found(review: MigrationReviewRow[] | undefined, analysis: Analysis | null): Found | null {
  const local = structureSummary(analysis);
  const checks = (review ?? []).filter((r) => r.item === 'check' && r.area === 'structure');
  const byName = (s: string) => checks.find((c) => c.name.startsWith(s));
  const tables = byName('tables in field list');
  if (tables) {
    const detail = (tables.detail ?? {}) as { fields?: number };
    const missing = num(byName('missing columns')?.raw_value) ?? 0;
    const mismatch = num(byName('type mismatches')?.raw_value) ?? 0;
    const fields = num(detail.fields) ?? num(byName('fields of matched tables')?.sap_value);
    const rep = (byName('table names repaired')?.detail ?? {}) as Record<string, number>;
    return {
      fromWorker: true,
      tablesInSap: num(tables.sap_value),
      tablesInErp: num(tables.raw_value),
      leftOut: num(byName('tables not in sap schema')?.sap_value),
      fieldsCompared: fields,
      fieldsMissing: missing,
      typeDiff: mismatch,
      itemFields: local?.itemFields ?? null,
      itemUserFields: local?.itemUserFields ?? null,
      repaired: Object.keys(rep).length ? rep : local?.repaired ?? {},
      pct: fields ? (missing + mismatch === 0 ? 100 : Math.floor(1000 * (1 - (missing + mismatch) / fields)) / 10) : null,
    };
  }
  if (!local) return null;
  return {
    fromWorker: false,
    tablesInSap: local.tables,
    tablesInErp: null,
    leftOut: null,
    fieldsCompared: local.fields,
    fieldsMissing: null,
    typeDiff: null,
    itemFields: local.itemFields,
    itemUserFields: local.itemUserFields,
    repaired: local.repaired,
    pct: null,
  };
}

/** migration_review issue detail is jsonb { detail, table, note, resolved_at } (a plain string is accepted too). */
export function issueText(d: unknown): string | null {
  if (d == null) return null;
  if (typeof d === 'string') return d;
  return ((d as { detail?: string | null }).detail ?? null) || null;
}

export type PointTone = 'blocker' | 'sendCsv' | 'fix' | 'info';
export interface Point { key: string; tone: PointTone; title: string; detail?: string | null }

export function points(args: {
  t: (k: string, o?: Record<string, unknown>) => string;
  review: MigrationReviewRow[] | undefined;
  has: Analysis['has'] | null;
  hasArchive: boolean;
  found: Found | null;
  anyFiles: boolean;
}): Point[] {
  const { t, review, has, hasArchive, found: f, anyFiles } = args;
  const out: Point[] = [];
  if (anyFiles && has && !has.data && !hasArchive) {
    out.push({ key: 'noRecords', tone: 'blocker', title: t('migration.upload.noRecords'), detail: t('migration.upload.noRecordsNote') });
  }
  const rep = f?.repaired ?? {};
  const repNames = Object.keys(rep);
  if (repNames.length) {
    out.push({
      key: 'excel', tone: 'sendCsv', title: t('migration.upload.excelRenamed'),
      detail: t('migration.upload.excelRenamedNote', { names: repNames.join(', '), n: Object.values(rep).reduce((a, b) => a + b, 0) }),
    });
  }
  for (const r of review ?? []) {
    if (r.item !== 'issue' || r.status !== 'open') continue;
    if (/^Structure only, no data rows/.test(r.name)) continue; // shown as the "No records" blocker
    const left = r.name.match(/^(\d+) tables in the field list are not in the sap schema/);
    if (left) {
      out.push({ key: `i${r.id}`, tone: 'info', title: t('migration.upload.leftOutTitle', { n: Number(left[1]).toLocaleString('en-US') }), detail: issueText(r.detail) });
      continue;
    }
    out.push({
      key: `i${r.id}`,
      tone: r.severity === 'critical' ? 'blocker' : r.severity === 'warning' ? 'fix' : 'info',
      title: r.name,
      detail: issueText(r.detail),
    });
  }
  if (has?.data && !has.constraints) {
    out.push({ key: 'noConstraints', tone: 'info', title: t('migration.upload.noConstraints'), detail: t('migration.upload.noConstraintsNote') });
  }
  const order: Record<PointTone, number> = { blocker: 0, sendCsv: 1, fix: 2, info: 3 };
  return out.sort((a, b) => order[a.tone] - order[b.tone]);
}

/** Received table rows: control files and field lists one by one; the table folders as one summary row. */
export interface ReceivedRow { key: string; file: string; readAs: string; rows: number | null; size: number | null; result: { tone: 'ok' | 'info' | 'neutral' | 'critical' | 'warning'; label: string } }

export function receivedRows(args: {
  t: (k: string, o?: Record<string, unknown>) => string;
  analysis: Analysis | null;
  workerFiles: MigrationFile[] | undefined;
  progress: Record<string, { state: string }> | undefined;
}): ReceivedRow[] {
  const { t, analysis, workerFiles, progress } = args;
  const facts = new Map((analysis?.files ?? []).map((f) => [safeKey(f.path), f]));
  const readAsLabel = (f?: FileFacts, kind?: string, name?: string) => {
    if (f) {
      const label = f.readAs.table
        ? (f.readAs.key === 'labelsOf' && f.readAs.table === 'OITM'
          ? t('migration.upload.tables.itemShort')
          : TABLE_KEY[f.readAs.table] ? t(`migration.upload.tables.${TABLE_KEY[f.readAs.table]}`) : f.readAs.table)
        : '';
      return t(`migration.upload.readAs.${f.readAs.key}`, { label });
    }
    // no local analysis (another browser): best guess from the worker's kind and the file name
    const stem = (name ?? '').replace(/\.(xlsx|xlsm|csv)$/i, '').replace(/[_\W].*$/, '').toUpperCase();
    const label = TABLE_KEY[stem] ? t(`migration.upload.tables.${stem === 'OITM' && kind === 'other' ? 'itemShort' : TABLE_KEY[stem]}`) : stem;
    if ((kind === 'structure_xlsx' || kind === 'structure_csv') && TABLE_KEY[stem]) return t('migration.upload.readAs.fieldsOf', { label });
    if (kind === 'other' && /\.xlsx?$/i.test(name ?? '')) {
      if (TABLE_KEY[stem]) return t('migration.upload.readAs.labelsOf', { label });
      if (/^table/i.test(name ?? '')) return t('migration.upload.readAs.tableNames', { label: '' });
    }
    const k = { columns_csv: 'columns', constraints_csv: 'constraints', row_counts_csv: 'rowCounts', structure_xlsx: 'fieldListAll', structure_csv: 'fieldListAll' }[kind ?? ''] ?? 'other';
    return t(`migration.upload.readAs.${k}`, { label: '' });
  };

  const rows: ReceivedRow[] = [];
  if (workerFiles?.length) {
    const data = workerFiles.filter((f) => f.kind === 'data_csv' || f.kind === 'create_sql');
    for (const wf of workerFiles) {
      if (wf.kind === 'data_csv' || wf.kind === 'create_sql') continue;
      const f = facts.get(wf.path) ?? [...facts.values()].find((x) => wf.path.endsWith(safeKey(x.path)));
      const isXlsx = /\.xlsx?$/i.test(wf.path);
      const result: ReceivedRow['result'] =
        wf.status === 'error' ? { tone: 'critical', label: t('migration.upload.result.error') }
        : wf.kind === 'structure_xlsx' || wf.kind === 'structure_csv' ? { tone: 'ok', label: t('migration.upload.result.structureOk') }
        : wf.kind === 'other' && isXlsx ? { tone: 'info', label: t('migration.upload.result.labels') }
        : wf.status === 'ok' ? { tone: 'ok', label: t('migration.upload.result.ok') }
        : { tone: 'neutral', label: t(`migration.upload.result.${wf.status}`) };
      rows.push({ key: wf.path, file: wf.path.split('/').pop()!, readAs: readAsLabel(f, wf.kind, wf.path.split('/').pop()), rows: f?.rows ?? null, size: wf.bytes, result });
    }
    if (data.length) {
      const tables = new Set(data.map((d) => d.table_name)).size;
      const skipped = new Set(data.filter((d) => d.status === 'skipped').map((d) => d.table_name)).size;
      rows.unshift({
        key: '__data', file: t('migration.upload.readAs.dataFolder'),
        readAs: t('migration.upload.dataSummary', { tables, files: data.filter((d) => d.kind === 'data_csv').length, size: '' }).replace(/ · $/, ''),
        rows: null, size: data.reduce((a, d) => a + (d.bytes ?? 0), 0),
        result: skipped ? { tone: 'warning', label: `${skipped} ${t('migration.upload.result.skipped')}` } : { tone: 'ok', label: t('migration.upload.result.ok') },
      });
    }
    return rows;
  }
  // before the worker: the local analysis + upload progress
  const state = (path: string): ReceivedRow['result'] => {
    const s = progress?.[path]?.state;
    if (s === 'done') return { tone: 'ok', label: t('migration.upload.result.done') };
    if (s === 'error') return { tone: 'critical', label: t('migration.upload.result.failed') };
    if (s === 'uploading') return { tone: 'info', label: t('migration.upload.result.uploading') };
    return { tone: 'neutral', label: t('migration.upload.result.waiting') };
  };
  if (analysis?.dataTables) {
    rows.push({
      key: '__data', file: t('migration.upload.readAs.dataFolder'),
      readAs: t('migration.upload.dataSummary', { tables: analysis.dataTables, files: analysis.dataFiles, size: '' }).replace(/ · $/, ''),
      rows: null, size: analysis.dataBytes, result: { tone: 'neutral', label: '' },
    });
  }
  for (const f of analysis?.files ?? []) {
    rows.push({ key: f.path, file: f.path.split('/').pop()!, readAs: readAsLabel(f), rows: f.rows ?? null, size: f.size, result: state(f.path) });
  }
  return rows;
}

export const TABLE_KEY: Record<string, string> = {
  OITM: 'item', OITB: 'itemGroup', OITW: 'stockWarehouse', ITM1: 'itemPrice', OUGP: 'unitGroup', UGP1: 'unitGroupLine',
  OCRD: 'businessPartner', OACT: 'account', OINV: 'arInvoice', OPCH: 'apInvoice', OJDT: 'journal', JDT1: 'journalLine', OWHS: 'warehouse', OHEM: 'employee',
};


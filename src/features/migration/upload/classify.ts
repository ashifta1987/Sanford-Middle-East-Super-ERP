// Client-side look at the chosen files, before anything is uploaded.
// Mirrors the worker's classification (migration_worker.py: sniff_csv, sniff_xlsx, struct_header, DATA_FILE)
// so the checklist and the Start button are right before the worker has seen the files.
// The worker re-checks everything after submit; this is only for the screen.

export type LocalKind =
  | 'data_csv' | 'create_sql' | 'columns_csv' | 'constraints_csv' | 'row_counts_csv'
  | 'structure_xlsx' | 'structure_csv' | 'archive' | 'labels' | 'table_names' | 'other';

export interface PickedFile {
  file: File;
  /** path relative to the chosen folder (keeps the top folder name), or the file name */
  path: string;
}

export interface FileFacts {
  path: string;
  size: number;
  kind: LocalKind;
  /** human description key + optional table, e.g. readAs.fieldsOf + OITM */
  readAs: { key: string; table?: string };
  rows?: number;
  /** structure lists: distinct tables, fields, OITM fields, OITM user fields, Excel-date table names repaired */
  structure?: { tables: number; fields: number; itemFields: number; itemUserFields: number; repaired: Record<string, number> };
}

export interface Analysis {
  files: FileFacts[];
  dataTables: number;
  dataFiles: number;
  dataBytes: number;
  hasArchive: boolean;
  has: { columns: boolean; constraints: boolean; rowCounts: boolean; fieldList: boolean; data: boolean };
  /** only field lists / labels, no data → structure_only run */
  structureOnly: boolean;
  totalBytes: number;
}

const DATA_FILE = /^data(\.csv(\.\d+)?)?$/;
const ARCHIVE = /\.(zip|tar|tar\.gz|tgz)$/i;
const norm = (h: unknown) => String(h ?? '').toLowerCase().replace(/[^a-z]/g, '');
const STRUCT_COLS: Record<string, string> = {
  tablename: 'table', fieldname: 'field', columnname: 'field', datatype: 'type', length: 'length', allownulls: 'nulls', nullable: 'nulls',
};

function structHeader(row: unknown[]): Record<string, number> | null {
  const idx: Record<string, number> = {};
  row.forEach((h, i) => {
    const k = STRUCT_COLS[norm(h)];
    if (k && !(k in idx)) idx[k] = i;
  });
  return idx.table !== undefined && idx.field !== undefined && idx.type !== undefined ? idx : null;
}

function sniffCsvHeader(line: string): LocalKind {
  const h = new Set(line.replace(/^\uFEFF/, '').split(',').map((x) => norm(x.replace(/"/g, ''))));
  if (h.has('tablename') && h.has('recordcount')) return 'row_counts_csv';
  if (h.has('tablename') && h.has('position') && h.has('columnname')) return 'columns_csv';
  if (h.has('tablename') && h.has('constraintname') && h.has('columnname')) return 'constraints_csv';
  if (structHeader([...line.split(',').map((x) => x.replace(/"/g, ''))])) return 'structure_csv';
  return 'other';
}

/** Excel turns names like AUG1 into a date (1 Aug). Undo it the way the worker does. */
const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
function tableName(v: unknown): { name: string; repaired: boolean } {
  if (v instanceof Date) return { name: `${MONTHS[v.getMonth()]}${v.getDate()}`, repaired: true };
  return { name: String(v ?? '').trim(), repaired: false };
}

/** Plain names for common SAP tables, for the "Read as" column. */
export const TABLE_LABELS: Record<string, string> = {
  OITM: 'item', OITB: 'itemGroup', OITW: 'stockWarehouse', ITM1: 'itemPrice', OUGP: 'unitGroup', UGP1: 'unitGroupLine',
  OCRD: 'businessPartner', OACT: 'account', OINV: 'arInvoice', OPCH: 'apInvoice', OJDT: 'journal', JDT1: 'journalLine', OWHS: 'warehouse', OHEM: 'employee',
};

async function analyseXlsx(f: PickedFile): Promise<FileFacts> {
  const XLSX = await import('xlsx');
  const buf = await f.file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array', cellDates: true, dense: true });
  const ws = wb.Sheets[wb.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json<unknown[]>(ws, { header: 1, raw: true, blankrows: false });
  const head = rows[0] ?? [];
  const body = rows.slice(1);
  const idx = structHeader(head);
  const base: Omit<FileFacts, 'kind' | 'readAs'> = { path: f.path, size: f.file.size, rows: body.length };

  if (idx) {
    const tables = new Set<string>();
    const repaired: Record<string, number> = {};
    let itemFields = 0, itemUserFields = 0;
    for (const r of body) {
      const { name, repaired: rep } = tableName(r[idx.table]);
      if (!name) continue;
      tables.add(name);
      if (rep) repaired[name] = (repaired[name] ?? 0) + 1;
      if (name.toUpperCase() === 'OITM') {
        itemFields++;
        if (String(r[idx.field] ?? '').startsWith('U_')) itemUserFields++;
      }
    }
    const one = tables.size === 1 ? [...tables][0] : undefined;
    return {
      ...base,
      kind: 'structure_xlsx',
      readAs: one ? { key: 'fieldsOf', table: one } : { key: 'fieldListAll' },
      structure: { tables: tables.size, fields: body.length, itemFields, itemUserFields, repaired },
    };
  }
  // not a field list: table-name lists or field label sheets (the worker ignores them)
  const h = head.map(norm);
  const hasTable = h.includes('tablename') || h.includes('table');
  const hasField = h.some((x) => x.includes('field') || x.includes('column') || x.includes('alias'));
  if (hasTable && !hasField) return { ...base, kind: 'table_names', readAs: { key: 'tableNames' } };
  const stem = f.file.name.replace(/\.(xlsx|xlsm)$/i, '').replace(/[_\W].*$/, '').toUpperCase();
  return { ...base, kind: 'labels', readAs: { key: 'labelsOf', table: stem } };
}

async function firstLine(file: File) {
  const text = await file.slice(0, 8192).text();
  return text.split(/\r?\n/)[0] ?? '';
}

async function countLines(file: File): Promise<number | undefined> {
  if (file.size > 50 * 1024 * 1024) return undefined; // don't read huge control files just for a count
  const t = await file.text();
  return Math.max(0, t.split(/\r?\n/).filter(Boolean).length - 1);
}

export async function analyse(picked: PickedFile[]): Promise<Analysis> {
  // folders that hold a create.sql are table folders of the HANA export
  const dirOf = (p: string) => p.slice(0, Math.max(0, p.lastIndexOf('/')));
  const tableDirs = new Set(picked.filter((p) => p.file.name === 'create.sql').map((p) => dirOf(p.path)));

  const files: FileFacts[] = [];
  let dataFiles = 0, dataBytes = 0;
  const dataTables = new Set<string>();

  for (const p of picked) {
    const name = p.file.name;
    const inTable = tableDirs.has(dirOf(p.path));
    if (inTable) {
      if (name === 'create.sql') continue;
      if (DATA_FILE.test(name)) { dataFiles++; dataBytes += p.file.size; dataTables.add(dirOf(p.path)); }
      continue; // table folders are summarised, not listed file by file
    }
    if (ARCHIVE.test(name)) { files.push({ path: p.path, size: p.file.size, kind: 'archive', readAs: { key: 'archive' } }); continue; }
    const low = name.toLowerCase();
    if (low.endsWith('.csv')) {
      const kind = sniffCsvHeader(await firstLine(p.file));
      const rows = kind === 'other' ? undefined : await countLines(p.file);
      const key = { row_counts_csv: 'rowCounts', columns_csv: 'columns', constraints_csv: 'constraints', structure_csv: 'fieldListAll' }[kind as string] ?? 'other';
      files.push({ path: p.path, size: p.file.size, kind, readAs: { key }, rows });
      continue;
    }
    if (low.endsWith('.xlsx') || low.endsWith('.xlsm')) {
      try { files.push(await analyseXlsx(p)); } catch { files.push({ path: p.path, size: p.file.size, kind: 'other', readAs: { key: 'unreadable' } }); }
      continue;
    }
    files.push({ path: p.path, size: p.file.size, kind: 'other', readAs: { key: 'other' } });
  }

  const hasArchive = files.some((f) => f.kind === 'archive');
  const has = {
    columns: files.some((f) => f.kind === 'columns_csv'),
    constraints: files.some((f) => f.kind === 'constraints_csv'),
    rowCounts: files.some((f) => f.kind === 'row_counts_csv'),
    fieldList: files.some((f) => f.kind === 'structure_xlsx' || f.kind === 'structure_csv'),
    data: dataFiles > 0,
  };
  return {
    files,
    dataTables: dataTables.size,
    dataFiles,
    dataBytes,
    hasArchive,
    has,
    structureOnly: !has.data && !hasArchive && has.fieldList,
    totalBytes: picked.reduce((a, p) => a + p.file.size, 0),
  };
}

/** Combined structure facts over every field list in the upload (the biggest list wins for table/field totals). */
export function structureSummary(a: Analysis | null) {
  const lists = (a?.files ?? []).filter((f) => f.structure);
  if (!lists.length) return null;
  const main = lists.reduce((x, y) => (y.structure!.fields > x.structure!.fields ? y : x));
  const itemList = lists.find((f) => f.readAs.table === 'OITM' || f.path.toUpperCase().includes('OITM__V')) ?? main;
  const repaired: Record<string, number> = {};
  for (const l of lists) for (const [k, v] of Object.entries(l.structure!.repaired)) repaired[k] = Math.max(repaired[k] ?? 0, v);
  return {
    tables: main.structure!.tables,
    fields: main.structure!.fields,
    itemFields: itemList.structure!.itemFields || main.structure!.itemFields,
    itemUserFields: itemList.structure!.itemUserFields || main.structure!.itemUserFields,
    repaired,
  };
}

"""Load one company's SAP HANA export into the raw "sap" schema.

    pip install "psycopg[binary]"
    python load_company.py --company AE01 --export /data/AE01_SBO_SANFORD \
        --columns /data/AE01_SBO_SANFORD/columns.csv --counts /data/AE01_SBO_SANFORD/row_counts.csv \
        --dsn "postgresql://postgres:<password>@db.<project>.supabase.co:5432/postgres"

Per table in the export (a folder holding create.sql and the data file data.csv, data.csv.1 ...):
  1. Column order comes from columns.csv (query 1 of 05_hana_export.sql: TABLE_NAME, POSITION, COLUMN_NAME),
     or, if that is not given, from the export's own create.sql. The CSV has no header.
  2. COPY into a temporary all-text table, so no row is rejected on the way in.
  3. One transaction: delete that company's rows, insert with each value cast to the sap column type
     (binary columns are read as hex), company_code stamped on every row.
  4. Log to sap._load_log: rows loaded vs row_counts.csv, and any column the export and the sap table
     do not share ('column_mismatch' - the table is loaded, but check it).
Only data.csv / data.csv.N / data are read; data.ctl, data.info and create.sql are ignored.
Before the first real load, run it on one export folder and check a table with long text (NCLOB)
and one with binary columns: their file layout depends on the HANA version.
Use the direct connection or the session pooler (port 5432), not the transaction pooler.

The migration worker (migration_worker.py) imports this file and uses the Loader class in two phases:
stage every table first (company data untouched if any file is unreadable), then cast them.
"""
import argparse, codecs, csv, glob, os, re, sys, time, uuid
from collections import defaultdict
import psycopg
from psycopg import sql

DATA_FILE = re.compile(r'^data(\.csv(\.\d+)?)?$')
CR_MARK = '\x1f'      # a bare carriage return inside a value travels through COPY as U+001F and is restored when cast
TEXT_TYPES = ('text', 'character', 'char', 'bpchar', 'varchar', 'character varying')


def has_rows(files):
    """False when every data file of a table is empty (0 bytes or only whitespace), so the table is skipped."""
    for f in files:
        try:
            if os.path.getsize(f) > 2:
                return True
            if open(f, 'rb').read().strip():
                return True
        except OSError:
            return True
    return False


def create_sql_columns(ddl):
    m = re.search(r'CREATE\s+(?:COLUMN\s+|ROW\s+)?TABLE\s+"[^"]+"\."([^"]+)"\s*\((.*)\)', ddl, re.S | re.I)
    if not m:
        return None, []
    body = re.split(r',\s*(?:CONSTRAINT\s+"[^"]+"\s+)?PRIMARY\s+KEY', m.group(2), flags=re.I)[0]
    # a column definition is a quoted name followed by a type word (any type: NVARCHAR, NCHAR, FLOAT, SMALLDECIMAL...)
    return m.group(1), re.findall(r'(?:^|,)\s*"([^"]+)"\s+[A-Za-z]', body)


def export_tables(root):
    for create in glob.glob(os.path.join(root, '**', 'create.sql'), recursive=True):
        folder = os.path.dirname(create)
        name, cols = create_sql_columns(open(create, encoding='utf-8', errors='replace').read())
        if not name:
            continue
        files = sorted((f for f in os.listdir(folder) if DATA_FILE.match(f)), key=lambda f: (len(f), f))
        yield name, cols, [os.path.join(folder, f) for f in files]


def read_counts(path):
    expected = {}
    if path:
        with open(path, newline='', encoding='utf-8-sig') as fh:
            for r in csv.DictReader(fh):
                expected[r['TABLE_NAME']] = int(float(r['RECORD_COUNT']))
    return expected


def read_columns(path):
    order = defaultdict(list)
    if path:
        with open(path, newline='', encoding='utf-8-sig') as fh:
            for r in csv.DictReader(fh):
                order[r['TABLE_NAME']].append((int(float(r['POSITION'])), r['COLUMN_NAME']))
    return order


def sap_coltypes(con):
    coltypes = defaultdict(dict)
    for t, c, ty in con.execute("""select c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
                                     from pg_attribute a join pg_class c on c.oid = a.attrelid
                                    where c.relnamespace = 'sap'::regnamespace and c.relkind = 'r'
                                      and a.attnum > 0 and not a.attisdropped"""):
        coltypes[t][c] = ty
    return coltypes


class Loader:
    """Loads one company's export. con must be an autocommit connection (the same session for stage and cast)."""

    def __init__(self, con, company, export, columns=None, counts=None, tables=None, run_id=None):
        self.con, self.company, self.export = con, company, export
        self.expected = read_counts(counts)
        self.order = read_columns(columns)
        self.only = set(tables) if tables else None
        self.run = run_id or uuid.uuid4()
        if not con.execute('select 1 from sap._company where company_code = %s', [company]).fetchone():
            raise SystemExit('company %s is not in sap._company - add it first' % company)
        self.coltypes = sap_coltypes(con)
        self.staged = {}          # table -> (temp table name, rows)
        self.stage_seconds = self.cast_seconds = 0.0

    def plan(self):
        """[(name, cols, files)] for every table in the export (filtered by --tables)."""
        out = []
        for name, ddl_cols, files in export_tables(self.export):
            if self.only and name not in self.only:
                continue
            cols = [c for _, c in sorted(self.order[name])] if self.order.get(name) else ddl_cols
            out.append((name, cols, files))
        return out

    def log(self, name, status, loaded=None, msg=None, expected=None):
        self.con.execute('insert into sap._load_log (run_id, company_code, table_name, rows_expected, rows_loaded, status, message) '
                         'values (%s,%s,%s,%s,%s,%s,%s)',
                         [self.run, self.company, name, self.expected.get(name) if expected is None else expected, loaded, status, msg])

    def precheck(self, name, files):
        """None if the table can be loaded, else the reason it is skipped (already logged)."""
        if name not in self.coltypes:
            self.log(name, 'skipped', msg='table not in the sap schema (working table or view)')
            return 'not in sap schema'
        if not files:
            self.log(name, 'skipped', msg='no data file in the export')
            return 'no data file'
        return None

    def _copy(self, tmp, ncols, files, on_commit_drop):
        """Fast path: Postgres COPY (csv) over a lightly cleaned stream. Returns rows staged.
        Sets self._last_cr = number of bare carriage returns kept inside values (restored as CR when cast)."""
        self.con.execute(sql.SQL('create temp table {} ({}){}').format(
            sql.Identifier(tmp), sql.SQL(', ').join(sql.SQL('{} text').format(sql.Identifier('c%d' % i)) for i in range(ncols)),
            sql.SQL(' on commit drop' if on_commit_drop else '')))
        cr = 0
        with self.con.cursor() as cur:
            for f in files:
                # HANA's EXPORT ... AS CSV escapes a quote inside a quoted text with a backslash (6\" RICE BOWL) and a
                # backslash as \\ - not by doubling it - so COPY must use escape '\'.
                with cur.copy(sql.SQL("copy {} from stdin (format csv, delimiter ',', quote '\"', escape '\\', null '')").format(sql.Identifier(tmp))) as cp:
                    # Invalid UTF-8 (a few bytes in ODRF / OQUT ...) is replaced with U+FFFD instead of failing the table;
                    # the incremental decoder keeps multi-byte characters that span a chunk boundary.
                    dec = codecs.getincrementaldecoder('utf-8')(errors='replace')
                    carry = ''
                    with open(f, 'rb') as fh:
                        while True:
                            chunk = fh.read(1 << 20)
                            text = carry + dec.decode(chunk, final=not chunk)
                            # keep a trailing CR for the next chunk so a CRLF split across chunks is still seen as one
                            carry = text[-1:] if chunk and text.endswith('\r') else ''
                            if carry:
                                text = text[:-1]
                            # CRLF row endings become LF; a bare CR inside a value (DRF1) is kept as part of the value:
                            # COPY rejects it raw, so it travels as U+001F and is turned back into CR when cast.
                            text = text.replace('\r\n', '\n')
                            n = text.count('\r')
                            if n:
                                cr += n
                                text = text.replace('\r', CR_MARK)
                            if text:
                                cp.write(text.encode('utf-8'))
                            if not chunk:
                                break
        self._last_cr = cr
        return self.con.execute(sql.SQL('select count(*) from {}').format(sql.Identifier(tmp))).fetchone()[0]

    def _copy_tolerant(self, tmp, ncols, files):
        """Fallback when COPY rejects a file: parse it in Python and repair what COPY cannot.
        A row cut short by a bare line break inside a field is joined with the next line (the break stays in the value);
        a row that still has too many fields is skipped. Returns (rows, joined_rows, skipped_rows)."""
        self.con.execute(sql.SQL('create temp table {} ({})').format(
            sql.Identifier(tmp), sql.SQL(', ').join(sql.SQL('{} text').format(sql.Identifier('c%d' % i)) for i in range(ncols))))
        csv.field_size_limit(1 << 30)
        rows = joined = skipped = 0
        with self.con.cursor() as cur:
            for f in files:
                with cur.copy(sql.SQL('copy {} from stdin').format(sql.Identifier(tmp))) as cp:
                    with open(f, 'r', encoding='utf-8', errors='replace', newline='') as fh:
                        pending = None
                        for rec in csv.reader(fh, delimiter=',', quotechar='"', escapechar='\\', doublequote=False, strict=False):
                            if pending is not None:          # continue a row that was cut by a bare CR/LF
                                pending[-1] = pending[-1] + '\n' + (rec[0] if rec else '')
                                pending.extend(rec[1:])
                                rec, pending = pending, None
                                joined += 1
                            if len(rec) < ncols:
                                pending = rec
                                continue
                            if len(rec) > ncols:
                                skipped += 1
                                continue
                            cp.write_row([v if v != '' else None for v in rec])
                            rows += 1
                        if pending is not None:
                            skipped += 1
        return rows, joined, skipped

    def _insert(self, name, cols, tmp, restore_cr=False):
        target = self.coltypes[name]
        extra = [c for c in cols if c not in target]
        missing = [c for c in target if c not in cols and c not in ('company_code', '_row_id')]
        use = [c for c in cols if c in target]
        idx = {c: i for i, c in enumerate(cols)}

        def cast(c):
            ref = sql.Identifier('c%d' % idx[c])
            if target[c] == 'bytea':
                return sql.SQL("decode(nullif({}, ''), 'hex')").format(ref)
            if restore_cr and target[c].split('(')[0] in TEXT_TYPES:
                return sql.SQL("replace({}, chr(31), chr(13))::{}").format(ref, sql.SQL(target[c]))
            if restore_cr:      # a non-text column never keeps a CR
                return sql.SQL("nullif(replace({}, chr(31), ''), '')::{}").format(ref, sql.SQL(target[c]))
            return sql.SQL('{}::{}').format(ref, sql.SQL(target[c]))
        self.con.execute(sql.SQL('set local sap.company = {}').format(sql.Literal(self.company)))
        self.con.execute(sql.SQL('delete from sap.{} where company_code = %s').format(sql.Identifier(name)), [self.company])
        n = self.con.execute(sql.SQL('insert into sap.{} (company_code, {}) select %s, {} from {}').format(
            sql.Identifier(name), sql.SQL(', ').join(map(sql.Identifier, use)), sql.SQL(', ').join(cast(c) for c in use),
            sql.Identifier(tmp)), [self.company]).rowcount
        return n, extra, missing

    def _finish(self, name, n, extra, missing):
        exp = self.expected.get(name)
        if extra or missing:
            status = 'column_mismatch'
        elif exp is not None and exp != n:
            status = 'count_mismatch'
        else:
            status = 'loaded'
        msg = '; '.join(x for x in [
            ('in export, not in sap table: ' + ', '.join(extra)) if extra else '',
            ('in sap table, not in export: ' + ', '.join(missing)) if missing else '',
            ('expected %s rows' % exp) if exp is not None and exp != n else ''] if x) or None
        self.log(name, status, n, msg)
        return status

    # ---- one pass per table (the command line) ----
    def load_one(self, name, cols, files):
        """Stage and cast one table in one transaction. Returns (ok, rows)."""
        if self.precheck(name, files):
            return None, 0
        try:
            with self.con.transaction():
                self._copy('_stage', len(cols), files, True)
                n, extra, missing = self._insert(name, cols, '_stage')
            self._finish(name, n, extra, missing)
            return True, n
        except Exception as e:  # keep going; the log says what failed
            self.log(name, 'failed', msg=str(e)[:900])
            return False, 0

    # ---- the migration worker: one table at a time inside the run's transaction, in batches ----
    def load_table(self, name, cols, files):
        """Stage one table into a temp table, cast it into sap.<name> (replacing this company's rows) and release the
        temp table straight away, all inside the caller's transaction (savepoints keep a failure to this table).
        Returns dict(status, rows, cr, joined, skipped, error). Never raises for data problems."""
        self._stg_seq = getattr(self, '_stg_seq', 0) + 1
        tmp = '_stg_%d' % self._stg_seq
        out = {'status': 'failed', 'rows': 0, 'cr': 0, 'joined': 0, 'skipped': 0, 'error': None, 'path': 'copy'}
        t = time.monotonic()
        staged = False
        try:
            try:                                            # fast path: COPY
                with self.con.transaction():
                    self._copy(tmp, len(cols), files, False)
                out['cr'] = self._last_cr
                staged = True
            except Exception as e:                          # tolerant path: Python csv, repair split rows
                out['path'], first = 'tolerant', str(e).splitlines()[0][:200]
                try:
                    with self.con.transaction():
                        _, out['joined'], out['skipped'] = self._copy_tolerant(tmp, len(cols), files)
                    staged = True
                    out['error'] = 'COPY rejected the file (%s); loaded with the tolerant parser' % first
                except Exception as e2:
                    out['error'] = 'could not read: %s / tolerant parser: %s' % (first, str(e2).splitlines()[0][:200])
            self.stage_seconds += time.monotonic() - t
            if not staged:
                self.log(name, 'failed', msg=out['error'][:900])
                return out
            t = time.monotonic()
            try:
                with self.con.transaction():
                    n, extra, missing = self._insert(name, cols, tmp, restore_cr=out['cr'] > 0)
                out['rows'] = n
                out['status'] = self._finish(name, n, extra, missing)
            except Exception as e:
                out['error'] = 'cast failed: %s' % str(e).splitlines()[0][:300]
                self.log(name, 'failed', msg=out['error'][:900])
            self.cast_seconds += time.monotonic() - t
            return out
        finally:
            # created in this transaction, so TRUNCATE gives the space back at once (DROP alone would hold it to commit)
            try:
                if staged:
                    self.con.execute(sql.SQL('truncate {}').format(sql.Identifier(tmp)))
                self.con.execute(sql.SQL('drop table if exists {}').format(sql.Identifier(tmp)))
            except Exception:
                pass

    def drop_leftovers(self):
        """Drop every _stg_* temp table this session still has (start of a run, after a failure)."""
        n = 0
        for (t,) in self.con.execute("""select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                         where n.oid = pg_my_temp_schema() and c.relname like '\\_stg\\_%'""").fetchall():
            self.con.execute(sql.SQL('drop table if exists {}').format(sql.Identifier(t)))
            n += 1
        return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--company', required=True, help='company_code, must exist in sap._company')
    ap.add_argument('--export', required=True, help='folder of the HANA EXPORT ... AS CSV for that company')
    ap.add_argument('--dsn', required=True)
    ap.add_argument('--columns', help='columns.csv from 05 query 1 (TABLE_NAME, POSITION, COLUMN_NAME) - preferred column order')
    ap.add_argument('--counts', help='row_counts.csv from 05 query 4 (TABLE_NAME, RECORD_COUNT)')
    ap.add_argument('--tables', help='comma list to load only these tables')
    a = ap.parse_args()

    with psycopg.connect(a.dsn, autocommit=True) as con:
        ld = Loader(con, a.company, a.export, a.columns, a.counts, a.tables.split(',') if a.tables else None)
        ok = bad = 0
        for name, cols, files in ld.plan():
            r, _ = ld.load_one(name, cols, files)
            if r is True:
                ok += 1
            elif r is False:
                bad += 1
        print('run %s: %d tables loaded, %d failed. See sap._load_log.' % (ld.run, ok, bad))


if __name__ == '__main__':
    main()

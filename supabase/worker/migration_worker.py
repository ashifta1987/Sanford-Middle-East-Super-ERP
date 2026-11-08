"""Migration console worker: rebuilds one company from an uploaded SAP HANA export and cross-checks the system.

    pip install "psycopg[binary]" openpyxl
    # process queued runs forever (the UI queues them with erp.migration_submit)
    python migration_worker.py --dsn "$DB" --source storage --poll
    # process one run
    python migration_worker.py --dsn "$DB" --run <run_id> --source local --folder /data/SA01_export
    # no UI: create a run and process it (company must be in sap._company)
    python migration_worker.py --dsn "$DB" --new SA01 --kind full --source local --folder /data/SA01_export

--source storage downloads every object under the run's storage_prefix from the Supabase Storage bucket
"sap-exports" (env SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY; Storage REST API). --source local uses --folder.
.zip / .tar / .tar.gz / .tgz files in the upload are unpacked first.

Steps (each one written to erp.migration_step with timing and rows): validate, stage, cast, clean_02, orphans_03,
links_04, real_keys, security_06, app_sync, check_sync, check_deleted, cross_check. The run ends in needs_review.
Failure safety: stage only fills session temp tables. Everything from cast to cross_check (04z, the company's rows,
02, 04, the app sync as one transaction via erp.migration_sync_company, the checks) is ONE database transaction,
committed at the end. A failure - or "Stop run" (erp.migration_cancel on a running run, checked between steps) -
rolls it back, so the company keeps exactly its previous raw rows, links and app rows; the run becomes failed
(critical issue) or cancelled (info issue). Progress is written on a second connection, so it survives the rollback.
Needs max_locks_per_transaction raised (about 38,000 locks for 3,656 links; see README).
Only the run's company is touched: the loader replaces that company's rows; 02 is run for that company only;
for kind 'full' the company's rows in tables missing from the export are removed. Links (04z/04) are global,
so one rebuild runs at a time (advisory lock). A structure-only upload (an Excel/CSV field list with Table Name,
Field Name, Data Type, Length, Allow Nulls) is compared with the sap schema and the run ends in needs_review
with an info issue; no data is touched.
The DSN must be the database owner (postgres) on the direct connection or session pooler: the worker loads
the sap schema and drops/adds links.
"""
import argparse, csv, datetime, io, json, os, re, shutil, socket, sys, tarfile, tempfile, time, traceback, urllib.parse, urllib.request, uuid, zipfile
import psycopg
from psycopg import sql

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import load_company  # noqa: E402

BUCKET = 'sap-exports'
LOCK_KEY = 7212026          # pg_advisory_lock: one rebuild at a time (links are global)
DATA_STEPS = ['validate', 'stage', 'cast', 'clean_02', 'orphans_03', 'links_04', 'real_keys', 'security_06',
              'app_sync', 'check_sync', 'check_deleted', 'cross_check']
TX_STEPS = DATA_STEPS[2:]   # one database transaction: committed only after cross_check, rolled back on failure or stop
RUN_STATUS = {'validate': 'validating', 'stage': 'loading', 'cast': 'loading', 'clean_02': 'rebuilding', 'orphans_03': 'rebuilding',
              'links_04': 'rebuilding', 'real_keys': 'rebuilding', 'security_06': 'rebuilding', 'app_sync': 'rebuilding',
              'check_sync': 'checking', 'check_deleted': 'checking', 'cross_check': 'checking'}
MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']


class StepError(Exception):
    pass


class StopRun(Exception):
    """Stop requested from the console (erp.migration_cancel on a running run)."""


# ---------------------------------------------------------------- structure (field list) comparison
def _norm(h):
    return re.sub(r'[^a-z]', '', str(h or '').lower())


STRUCT_COLS = {'tablename': 'table', 'fieldname': 'field', 'columnname': 'field', 'datatype': 'type', 'length': 'length',
               'allownulls': 'nulls', 'nullable': 'nulls'}


def struct_header(row):
    """Index of table/field/type/length/nulls columns if this header row is a field list, else None."""
    idx = {}
    for i, h in enumerate(row):
        k = STRUCT_COLS.get(_norm(h))
        if k and k not in idx:
            idx[k] = i
    return idx if {'table', 'field', 'type'} <= set(idx) else None


def table_name(v):
    """Undo Excel's date conversion of table names such as AUG1 (-> 1 Aug). Returns (name, repaired)."""
    if isinstance(v, (datetime.datetime, datetime.date)):
        return MONTHS[v.month - 1] + str(v.day), True
    if isinstance(v, (int, float)) and not isinstance(v, bool) and 1 <= v < 80000:     # an Excel date serial
        d = datetime.date(1899, 12, 30) + datetime.timedelta(days=int(v))
        return MONTHS[d.month - 1] + str(d.day), True
    s = str(v).strip()
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})(?:[ T]00:00(?::00)?)?$', s)                  # 2026-08-01
    if m:
        return MONTHS[int(m.group(2)) - 1] + str(int(m.group(3))), True
    m = re.match(r'^(\d{1,2})[- ]([A-Za-z]{3})(?:[- ]\d{2,4})?$', s)                    # 1-Aug, 01-Aug-26
    if m and m.group(2).upper() in MONTHS:
        return m.group(2).upper() + str(int(m.group(1))), True
    return s, False


def read_field_list(path):
    """Rows (table, field, type, length, allow_nulls) from an .xlsx or .csv field list, plus repaired names."""
    rows, repaired = [], {}
    if path.lower().endswith(('.xlsx', '.xlsm')):
        import openpyxl
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        it = (r for ws in wb.worksheets[:1] for r in ws.iter_rows(values_only=True))
    else:
        fh = open(path, newline='', encoding='utf-8-sig', errors='replace')
        it = csv.reader(fh)
    idx = None
    for r in it:
        if idx is None:
            idx = struct_header(r)
            continue
        if not r or r[idx['table']] in (None, '') or r[idx['field']] in (None, ''):
            continue
        t, fixed = table_name(r[idx['table']])
        if fixed:
            repaired[t] = repaired.get(t, 0) + 1
        g = lambda k: r[idx[k]] if k in idx and idx[k] < len(r) else None
        nul = g('nulls')
        nul = None if nul is None else str(nul).strip().upper() in ('TRUE', 'YES', 'Y', '1')
        ln = g('length')
        try:
            ln = int(float(ln)) if ln not in (None, '') else None
        except ValueError:
            ln = None
        rows.append((t, str(r[idx['field']]).strip(), str(g('type') or '').strip().upper(), ln, nul))
    return rows, repaired


def hana_family(t, ln):
    t = t.split('(')[0].strip()
    if t in ('NVARCHAR', 'VARCHAR', 'NCHAR', 'CHAR', 'ALPHANUM', 'SHORTTEXT'):
        return 'varchar', ln
    if t in ('DECIMAL', 'SMALLDECIMAL'):
        return 'numeric', ln if t == 'DECIMAL' else None
    return {'INTEGER': ('integer', None), 'INT': ('integer', None), 'SMALLINT': ('smallint', None), 'TINYINT': ('smallint', None),
            'BIGINT': ('bigint', None), 'DOUBLE': ('double precision', None), 'REAL': ('real', None), 'FLOAT': ('double precision', None),
            'TIMESTAMP': ('timestamp', None), 'SECONDDATE': ('timestamp', None), 'LONGDATE': ('timestamp', None), 'DATE': ('date', None),
            'TIME': ('time', None), 'NCLOB': ('text', None), 'CLOB': ('text', None), 'TEXT': ('text', None), 'BLOB': ('bytea', None),
            'VARBINARY': ('bytea', None), 'BINARY': ('bytea', None), 'BOOLEAN': ('boolean', None)}.get(t, (t.lower(), None))


def pg_family(t):
    m = re.match(r'^(character varying|varchar|character|char)\((\d+)\)', t)
    if m:
        return 'varchar', int(m.group(2))
    m = re.match(r'^numeric\((\d+),\d+\)', t)
    if m:
        return 'numeric', int(m.group(1))
    t = t.split(' without time zone')[0]
    return {'character varying': 'varchar', 'timestamp': 'timestamp'}.get(t, t), None


def compare_structure(con, rows):
    """Compare a field list with the sap schema. Returns a dict of counts and samples."""
    cols, nullable = {}, {}
    for t, c, ty, nn in con.execute("""select c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
                                         from pg_attribute a join pg_class c on c.oid = a.attrelid
                                        where c.relnamespace = 'sap'::regnamespace and c.relkind = 'r' and c.relname !~ '^_'
                                          and a.attnum > 0 and not a.attisdropped"""):
        if c in ('company_code', '_row_id'):
            continue
        cols.setdefault(t, {})[c] = ty
        nullable[(t, c)] = not nn
    file_tables = {}
    for t, f, ty, ln, nul in rows:
        file_tables.setdefault(t, {})[f] = (ty, ln, nul)
    matched = [t for t in file_tables if t in cols]
    not_in_sap = sorted(t for t in file_tables if t not in cols)
    missing, mism, nulls, extra = [], [], [], []
    fields = 0
    for t in matched:
        for f, (ty, ln, nul) in file_tables[t].items():
            fields += 1
            if f not in cols[t]:
                missing.append('%s.%s' % (t, f)); continue
            hf, hl = hana_family(ty, ln)
            pf, pl = pg_family(cols[t][f])
            if hf != pf or (hf == 'varchar' and hl and pl and hl != pl) or (hf == 'numeric' and hl and pl and hl != pl):
                mism.append('%s.%s: SAP %s(%s) vs sap %s' % (t, f, ty, ln, cols[t][f]))
            if nul is not None and nul != nullable[(t, f)]:
                nulls.append('%s.%s' % (t, f))
        extra += ['%s.%s' % (t, c) for c in cols[t] if c not in file_tables[t]]
    return dict(file_tables=len(file_tables), file_fields=len(rows), matched_tables=len(matched), matched_fields=fields,
                not_in_sap=not_in_sap, sap_not_in_file=sorted(t for t in cols if t not in file_tables),
                missing=missing, mismatch=mism, nullability=nulls, extra=extra)


# ---------------------------------------------------------------- uploads
def safe_extract(path, dest):
    os.makedirs(dest, exist_ok=True)
    root = os.path.realpath(dest)
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for m in z.infolist():
                target = os.path.realpath(os.path.join(dest, m.filename))
                if not target.startswith(root + os.sep) and target != root:
                    raise StepError('unsafe path in archive %s: %s' % (os.path.basename(path), m.filename))
            z.extractall(dest)
    else:
        with tarfile.open(path) as tf:
            tf.extractall(dest, filter='data')


def storage_download(prefix, dest):
    """Download every object under prefix in bucket sap-exports (Supabase Storage REST API). Returns file count."""
    base = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    if not base or not key:
        raise StepError('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for --source storage')
    hdr = {'Authorization': 'Bearer ' + key, 'apikey': key}
    prefix = prefix.strip('/')
    n = 0

    def listing(p):
        off = 0
        while True:
            body = json.dumps({'prefix': p, 'limit': 1000, 'offset': off, 'sortBy': {'column': 'name', 'order': 'asc'}}).encode()
            req = urllib.request.Request('%s/storage/v1/object/list/%s' % (base, BUCKET), data=body, method='POST',
                                         headers=dict(hdr, **{'Content-Type': 'application/json'}))
            with urllib.request.urlopen(req, timeout=120) as r:
                items = json.load(r)
            yield from items
            if len(items) < 1000:
                return
            off += 1000

    def walk(p):
        nonlocal n
        for it in listing(p):
            name = it['name']
            if '..' in name.split('/') or name.startswith('/'):
                raise StepError('unsafe object name %r' % name)
            full = (p + '/' + name) if p else name
            if it.get('id') is None:                      # a folder
                walk(full)
                continue
            rel = full[len(prefix):].lstrip('/')
            out = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            req = urllib.request.Request('%s/storage/v1/object/%s/%s' % (base, BUCKET, urllib.parse.quote(full)), headers=hdr)
            with urllib.request.urlopen(req, timeout=600) as r, open(out, 'wb') as fh:
                while chunk := r.read(1 << 20):
                    fh.write(chunk)
            n += 1
    walk(prefix)
    return n


def sniff_csv(path):
    try:
        with open(path, newline='', encoding='utf-8-sig', errors='replace') as fh:
            head = next(csv.reader(fh), [])
    except Exception:
        return 'other'
    h = {_norm(x) for x in head}
    if {'tablename', 'recordcount'} <= h:
        return 'row_counts_csv'
    if {'tablename', 'position', 'columnname'} <= h:
        return 'columns_csv'
    if {'tablename', 'constraintname', 'columnname'} <= h:
        return 'constraints_csv'
    if struct_header(head):
        return 'structure_csv'
    return 'other'


def sniff_xlsx(path):
    try:
        import openpyxl
        wb = openpyxl.load_workbook(path, read_only=True)
        head = next(wb.worksheets[0].iter_rows(values_only=True, max_row=1), ())
        return 'structure_xlsx' if struct_header(head) else 'other'
    except Exception:
        return 'other'


# ---------------------------------------------------------------- the run
class Run:
    """con: the data session (staging temp tables, then ONE transaction from cast to cross_check).
    bk: a second autocommit session for progress (status, steps, files, issues), so the console sees progress and
    failures even while the data transaction is open or after it was rolled back."""

    def __init__(self, con, bk, run_id, args):
        self.con, self.bk, self.run_id, self.a = con, bk, run_id, args
        r = bk.execute('select company_code, kind, storage_prefix from erp.migration_run where run_id = %s', [run_id]).fetchone()
        if not r:
            raise SystemExit('run %s not found' % run_id)
        self.company, self.kind, self.prefix = r
        self.scripts = args.scripts or HERE
        self.files = {}               # kind -> [paths]
        self.in_tx = False
        self.skips = []               # (table, message) logged to sap._load_log inside the transaction
        self.orphan_links = set()
        self.loader = None
        self.plan = []

    # --- bookkeeping
    def set_status(self, status, **kw):
        sets = [sql.SQL('status = %s')] + [sql.SQL('{} = %s').format(sql.Identifier(k)) for k in kw]
        self.bk.execute(sql.SQL('update erp.migration_run set {} where run_id = %s').format(sql.SQL(', ').join(sets)),
                         [status, *kw.values(), self.run_id])

    def issue(self, severity, area, key, title, detail=None, table=None):
        self.bk.execute('select erp.migration_add_issue(%s,%s,%s,%s,%s,%s,%s,%s)',
                         [self.run_id, self.company, severity, area, key, title, detail, table])

    def check(self, area, name, sap=None, raw=None, app=None, ok=True, detail=None):
        diff = (raw - sap) if sap is not None and raw is not None else None
        self.bk.execute('insert into erp.migration_check (run_id, company_code, area, check_name, sap_value, raw_value, app_value, difference, ok, detail) '
                         'values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)',
                         [self.run_id, self.company, area, name, sap, raw, app, diff, ok, json.dumps(detail) if detail is not None else None])

    def init_steps(self, codes):
        self.bk.execute('delete from erp.migration_step where run_id = %s', [self.run_id])
        with self.bk.cursor() as cur:
            cur.executemany('insert into erp.migration_step (run_id, step_no, code) values (%s,%s,%s)',
                            [(self.run_id, i + 1, c) for i, c in enumerate(codes)])

    def step(self, code, fn):
        if code in RUN_STATUS:
            self.set_status(RUN_STATUS[code])
        self.bk.execute("update erp.migration_step set status = 'running', started_at = clock_timestamp() where run_id = %s and code = %s", [self.run_id, code])
        t = time.monotonic()
        try:
            res = fn()
        except Exception as e:
            msg = '%s: %s' % (type(e).__name__, str(e).strip()[:1500])
            self.bk.execute("update erp.migration_step set status = 'failed', finished_at = clock_timestamp(), message = %s where run_id = %s and code = %s",
                             [msg, self.run_id, code])
            raise StepError('%s failed - %s' % (code, msg)) from e
        status, rows, msg = res if isinstance(res, tuple) else ('ok', res, None)
        self.bk.execute('update erp.migration_step set status = %s, rows = %s, finished_at = clock_timestamp(), message = %s where run_id = %s and code = %s',
                         [status, rows, msg, self.run_id, code])
        print('  %-14s %-8s rows=%-8s %5.1fs  %s' % (code, status, rows, time.monotonic() - t, (msg or '')[:150]), flush=True)
        return status

    def script(self, name):
        p = os.path.join(self.scripts, name)
        if not os.path.exists(p):
            raise StepError('%s not found in %s' % (name, self.scripts))
        return open(p, encoding='utf-8').read()

    # --- main
    def stop_requested(self):
        return self.bk.execute('select stop_requested_at from erp.migration_run where run_id = %s', [self.run_id]).fetchone()[0] is not None

    def guard(self, next_step):
        if self.stop_requested():
            raise StopRun(next_step)

    def now(self):
        return datetime.datetime.now(datetime.timezone.utc)

    def execute(self, folder):
        self.root = folder
        self.bk.execute("update erp.migration_run set status = 'validating', started_at = now(), finished_at = null, worker = %s where run_id = %s",
                        ['%s:%d' % (socket.gethostname(), os.getpid()), self.run_id])
        self.init_steps(DATA_STEPS)
        print('run %s  company %s  kind %s  folder %s' % (self.run_id, self.company, self.kind, folder), flush=True)
        locked = False
        try:
            self.guard('validate')
            self.step('validate', self.validate)
            self.guard('stage')
            if self.structure_only:
                self.bk.execute("update erp.migration_step set status = 'skipped', message = 'structure-only upload: no data loaded' "
                                "where run_id = %s and status = 'pending'", [self.run_id])
                self.set_status('needs_review', finished_at=self.now())
                print('run %s: needs_review (structure only)' % self.run_id)
                return 'needs_review'
            self.con.execute('select pg_advisory_lock(%s)', [LOCK_KEY])
            locked = True
            self.step('stage', self.s_stage)          # temp tables only: nothing of the company changes here
            # From here to cross_check everything is ONE transaction (links, raw rows, 02, 04, app sync, checks).
            self.con.autocommit = False
            self.in_tx = True
            self.con.execute('select 1')
            for code in TX_STEPS:
                self.guard(code)
                self.step(code, getattr(self, 's_' + code))
            self.locks = self.con.execute('select count(*) from pg_locks where pid = pg_backend_pid()').fetchone()[0]
            if os.environ.get('MIG_DEBUG_LOCKS'):
                print(self.con.execute("""select l.mode, c.relkind, count(*) from pg_locks l left join pg_class c on c.oid = l.relation
                                           where l.pid = pg_backend_pid() group by 1, 2 order by 3 desc""").fetchall())
            # commit unless a stop came in; the row lock makes migration_cancel wait for this decision
            with self.bk.transaction():
                if self.bk.execute('select stop_requested_at from erp.migration_run where run_id = %s for no key update',
                                   [self.run_id]).fetchone()[0] is not None:
                    raise StopRun('commit')
                self.con.commit()
                self.in_tx = False
                self.con.autocommit = True
                self.bk.execute("update erp.migration_run set status = 'needs_review', finished_at = now() where run_id = %s", [self.run_id])
            st = self.bk.execute("select count(*) filter (where severity = 'critical'), count(*) filter (where severity = 'warning'), "
                                 "count(*) filter (where severity = 'info') from erp.migration_issue where run_id = %s and status = 'open'",
                                 [self.run_id]).fetchone()
            print('run %s: needs_review - committed (%d locks held at commit) - open issues: %d critical, %d warning, %d info'
                  % (self.run_id, self.locks, *st))
            return 'needs_review'
        except StopRun as e:
            note = self.roll_back()
            who = self.bk.execute('select stop_requested_by, stop_requested_at from erp.migration_run where run_id = %s', [self.run_id]).fetchone()
            self.bk.execute("update erp.migration_step set status = 'skipped', message = 'stopped on request' where run_id = %s and status in ('pending', 'running')", [self.run_id])
            self.issue('info', 'worker', 'run_stopped', 'Run stopped on request before step %s' % e.args[0],
                       'Stop requested by %s at %s. %s' % (who[0] or 'the console', who[1], note))
            self.set_status('cancelled', finished_at=self.now())
            print('run %s: CANCELLED before %s - %s' % (self.run_id, e.args[0], note))
            return 'cancelled'
        except Exception as e:
            note = self.roll_back()
            self.bk.execute("update erp.migration_step set status = 'skipped' where run_id = %s and status in ('pending', 'running')", [self.run_id])
            msg = str(e) if isinstance(e, StepError) else traceback.format_exc()[-1500:]
            self.issue('critical', 'worker', 'run_failed', 'Run failed: ' + str(e)[:180], msg + ' ' + note)
            self.set_status('failed', finished_at=self.now())
            print('run %s: FAILED - %s %s' % (self.run_id, e, note))
            return 'failed'
        finally:
            if self.in_tx:
                self.roll_back()
            self.drop_staging()
            if locked:
                self.con.execute('select pg_advisory_unlock(%s)', [LOCK_KEY])

    def roll_back(self):
        """Undo everything the run did to the database (raw rows, links, 02, app layer, checks)."""
        if not self.in_tx:
            return '%s was not changed (the run stopped before any company data was written).' % self.company
        self.con.rollback()
        self.con.autocommit = True
        self.in_tx = False
        self.bk.execute("update erp.migration_step set message = concat_ws(' ', message, '[rolled back]') "
                        "where run_id = %s and code = any(%s) and status in ('ok', 'warning', 'failed')", [self.run_id, TX_STEPS])
        return '%s is exactly as before the run: the transaction holding its new rows, links and app sync was rolled back.' % self.company

    def drop_staging(self):
        if self.loader:
            for tmp, _ in self.loader.staged.values():
                try:
                    self.con.execute(sql.SQL('drop table if exists {}').format(sql.Identifier(tmp)))
                except psycopg.Error:
                    pass

    # --- steps
    def validate(self):
        con = self.con
        # unpack archives
        for dirpath, _, names in list(os.walk(self.root)):
            for n in names:
                if n.lower().endswith(('.zip', '.tar', '.tar.gz', '.tgz')):
                    safe_extract(os.path.join(dirpath, n), os.path.join(dirpath, '_unpacked_' + re.sub(r'\W', '_', n)))
        sap_tables = {r[0] for r in con.execute("select relname from pg_class where relnamespace = 'sap'::regnamespace and relkind = 'r'")}
        recs = []
        for dirpath, _, names in os.walk(self.root):
            has_create = 'create.sql' in names
            tname = None
            if has_create:
                tname, _ = load_company.create_sql_columns(open(os.path.join(dirpath, 'create.sql'), encoding='utf-8', errors='replace').read())
            for n in sorted(names):
                p = os.path.join(dirpath, n)
                rel = os.path.relpath(p, self.root)
                low = n.lower()
                kind, table, status, msg = 'other', None, 'ok', None
                if low.endswith(('.zip', '.tar', '.tar.gz', '.tgz')):
                    status, msg = 'ignored', 'archive - unpacked'
                elif has_create and n == 'create.sql':
                    kind, table = 'create_sql', tname
                elif has_create and load_company.DATA_FILE.match(n):
                    kind, table = 'data_csv', tname
                elif has_create:
                    status, msg = 'ignored', 'not read by the loader'
                elif low.endswith('.csv'):
                    kind = sniff_csv(p)
                elif low.endswith(('.xlsx', '.xlsm')):
                    kind = sniff_xlsx(p)
                if kind in ('data_csv', 'create_sql') and table and table not in sap_tables:
                    status, msg = 'skipped', 'table not in the sap schema (working table or view)'
                if kind == 'other' and status == 'ok':
                    status = 'ignored'
                recs.append((self.run_id, rel, kind, os.path.getsize(p), table, status, msg))
                self.files.setdefault(kind, []).append(p)
        self.bk.execute('delete from erp.migration_file where run_id = %s', [self.run_id])
        with self.bk.cursor() as cur:
            cur.executemany('insert into erp.migration_file (run_id, path, kind, bytes, table_name, status, message) values (%s,%s,%s,%s,%s,%s,%s)', recs)
        for k in self.files:
            self.files[k].sort(key=lambda p: (p.count(os.sep), p))
        data = self.files.get('data_csv', [])
        struct = self.files.get('structure_xlsx', []) + self.files.get('structure_csv', [])
        self.structure_only = self.kind == 'structure_only' or (not data and bool(struct))
        notes = []
        if struct:
            notes.append(self.structure_check(struct[0]))
        if self.structure_only:
            if not struct:
                raise StepError('structure-only run but no field list (Table Name, Field Name, Data Type ...) in the upload')
            self.issue('info', 'structure', 'structure_only', 'Structure only, no data rows',
                       'The upload is a field list (%s), not a data export. It was compared with the sap schema; no company data was touched.'
                       % os.path.basename(struct[0]))
            if self.kind != 'structure_only':
                self.bk.execute("update erp.migration_run set kind = 'structure_only', notes = concat_ws(' | ', notes, %s::text) where run_id = %s",
                            ['uploaded as %s, detected as structure only' % self.kind, self.run_id])
            return ('ok', len(recs), '; '.join(notes))
        if not data:
            raise StepError('no data files (create.sql + data.csv folders) and no field list in the upload')
        for k in ('row_counts_csv', 'columns_csv', 'constraints_csv'):
            if len(self.files.get(k, [])) > 1:
                self.issue('warning', 'load', 'many:' + k, 'More than one %s in the upload' % k, 'Using ' + os.path.relpath(self.files[k][0], self.root))
        if not self.files.get('row_counts_csv'):
            self.issue('warning', 'load', 'no_row_counts', 'No row_counts.csv (05 query 4) - loaded rows cannot be checked against SAP')
        if not self.files.get('columns_csv'):
            self.issue('info', 'load', 'no_columns', 'No columns.csv (05 query 1) - column order taken from each create.sql')
        first = lambda k: self.files[k][0] if self.files.get(k) else None
        self.loader = load_company.Loader(con, self.company, self.root, first('columns_csv'), first('row_counts_csv'), run_id=self.run_id)
        self.plan = self.loader.plan()
        notes.insert(0, '%d files, %d tables with data' % (len(recs), len(self.plan)))
        return ('ok', len(recs), '; '.join(notes))

    def structure_check(self, path):
        rows, repaired = read_field_list(path)
        r = compare_structure(self.con, rows)
        base = os.path.basename(path)
        self.check('structure', 'tables in field list', sap=r['file_tables'], raw=r['matched_tables'], ok=True,
                   detail={'file': base, 'fields': r['file_fields'], 'not_in_sap_schema': len(r['not_in_sap'])})
        self.check('structure', 'fields of matched tables', sap=r['matched_fields'], raw=r['matched_fields'] - len(r['missing']), ok=not r['missing'])
        self.check('structure', 'missing columns (in SAP, not in sap schema)', sap=0, raw=len(r['missing']), ok=not r['missing'], detail={'sample': r['missing'][:200]})
        self.check('structure', 'type mismatches', sap=0, raw=len(r['mismatch']), ok=not r['mismatch'], detail={'sample': r['mismatch'][:200]})
        self.check('structure', 'nullability differences', sap=0, raw=len(r['nullability']), ok=not r['nullability'], detail={'sample': r['nullability'][:200]})
        self.check('structure', 'sap columns not in field list', sap=0, raw=len(r['extra']), ok=True, detail={'sample': r['extra'][:200]})
        self.check('structure', 'tables not in sap schema (skipped on load)', sap=len(r['not_in_sap']), raw=0, ok=True, detail={'tables': r['not_in_sap']})
        self.check('structure', 'sap tables not in field list', sap=0, raw=len(r['sap_not_in_file']), ok=True, detail={'tables': r['sap_not_in_file'][:500]})
        self.check('structure', 'table names repaired (Excel dates)', sap=sum(repaired.values()), raw=sum(repaired.values()), ok=True, detail=repaired)
        if r['missing']:
            self.issue('warning', 'structure', 'missing_columns', '%d SAP columns are not in the sap schema' % len(r['missing']), ', '.join(r['missing'][:50]))
        if r['mismatch']:
            self.issue('warning', 'structure', 'type_mismatch', '%d columns have a different type' % len(r['mismatch']), '; '.join(r['mismatch'][:30]))
        if r['not_in_sap']:
            self.issue('info', 'structure', 'tables_not_in_schema', '%d tables in the field list are not in the sap schema' % len(r['not_in_sap']),
                       'Skipped on load (SAP working/report tables, unused HR add-on set): ' + ', '.join(r['not_in_sap'][:40]) + ' ...')
        return ('structure %s: %d tables / %d fields, %d matched, %d not in sap schema, %d missing columns, %d type mismatches, %d table names repaired'
                % (base, r['file_tables'], r['file_fields'], r['matched_tables'], len(r['not_in_sap']), len(r['missing']), len(r['mismatch']), sum(repaired.values())))

    def s_stage(self):
        ld, staged, skipped, failed = self.loader, 0, 0, []
        self.to_cast = []
        for name, cols, files in self.plan:
            if name not in ld.coltypes:
                self.skips.append((name, 'table not in the sap schema (working table or view)', None)); skipped += 1; continue
            if not files:
                self.skips.append((name, 'no data file in the export', None)); skipped += 1; continue
            try:
                staged += ld.stage(name, cols, files)
                self.to_cast.append((name, cols))
            except Exception as e:
                failed.append('%s (%s)' % (name, str(e).splitlines()[0][:160]))
        if self.kind == 'full':      # tables SAP counted but the export does not contain
            have = {n for n, _, _ in self.plan}
            for t, n in ld.expected.items():
                if n > 0 and t not in have and t in ld.coltypes:
                    self.skips.append((t, 'listed in row_counts.csv with %d rows but not in the export' % n, 0))
        if failed:
            raise StepError('%d table(s) could not be read: %s' % (len(failed), '; '.join(failed[:10])))
        # tables already holding this company's rows, found outside the run's transaction (one short lock each),
        # so a 'full' reload clears only those instead of touching all 3,250 tables inside it
        self.company_tables = set()
        if self.kind == 'full':
            for (t,) in self.con.execute("select relname from pg_class where relnamespace = 'sap'::regnamespace and relkind = 'r' and relname !~ '^_' order by 1").fetchall():
                if self.con.execute(sql.SQL('select exists (select 1 from sap.{} where company_code = %s)').format(sql.Identifier(t)), [self.company]).fetchone()[0]:
                    self.company_tables.add(t)
        return ('ok', staged, '%d tables staged, %d skipped (not in sap schema or no data file), %.1fs' % (len(self.to_cast), skipped, ld.stage_seconds))

    def fk_names(self):
        return re.findall(r'^ALTER TABLE sap\."([^"]+)" DROP CONSTRAINT IF EXISTS "([^"]+)";$', self.script('04z_drop_foreign_keys.sql'), re.M)

    def s_cast(self):
        con, ld = self.con, self.loader
        names = {c for _, c in self.fk_names()}
        existing = con.execute("select count(*) from pg_constraint where contype = 'f' and connamespace = 'sap'::regnamespace and conname = any(%s)", [list(names)]).fetchone()[0]
        if existing:      # BEGIN/COMMIT removed: the drop is part of the run's transaction
            con.execute('\n'.join(l for l in self.script('04z_drop_foreign_keys.sql').splitlines() if l.strip().upper() not in ('BEGIN;', 'COMMIT;')))
        for t, msg, loaded in self.skips:
            ld.log(t, 'skipped', loaded=loaded, msg=msg)
        removed = 0
        if self.kind == 'full':      # the export is the whole company: clear its rows in every other table
            keep = {n for n, _ in self.to_cast}
            for t in sorted(self.company_tables - keep):
                removed += con.execute(sql.SQL('delete from sap.{} where company_code = %s').format(sql.Identifier(t)), [self.company]).rowcount
        rows, st = 0, {}
        for name, cols in self.to_cast:
            s, n = ld.cast(name, cols)
            rows += n
            st[s] = st.get(s, 0) + 1
        msg = '%s; %d links dropped (04z); %d stale rows removed from tables not in the export; %.1fs' % (
            ', '.join('%d %s' % (v, k) for k, v in sorted(st.items())), existing, removed, ld.cast_seconds)
        if st.get('failed'):
            bad = [r[0] + ': ' + (r[1] or '')[:160] for r in con.execute("select table_name, message from sap._load_log where run_id = %s and status = 'failed'", [self.run_id])]
            raise StepError('%d table(s) failed to cast: %s' % (st['failed'], '; '.join(bad[:10])))
        return ('warning' if st.get('count_mismatch') or st.get('column_mismatch') else 'ok', rows, msg)

    def s_clean_02(self):
        n = 0
        lit = sql.Literal(self.company).as_string(self.con)
        with self.con.transaction():
            for line in self.script('02_clean_blank_keys.sql').splitlines():
                if not line.startswith('UPDATE sap.'):
                    continue
                alias = 'c.' if re.match(r'^UPDATE sap\."[^"]+" c SET', line) else ''
                stmt = line.rstrip(';').replace(' WHERE ', ' WHERE %scompany_code = %s AND (' % (alias, lit), 1) + ')'
                n += self.con.execute(stmt).rowcount
        return ('ok', n, 'blank links and SAP -1 values set to NULL for %s only' % self.company)

    def refresh_links(self):
        links = re.findall(r'^ALTER TABLE sap\."([^"]+)" ADD CONSTRAINT "([^"]+)" FOREIGN KEY \("company_code", "([^"]+)"\) REFERENCES sap\."([^"]+)" \("company_code", "([^"]+)"\) NOT VALID;$',
                           self.script('04_foreign_keys.sql'), re.M)
        with self.con.transaction():
            self.con.execute('create table if not exists sap._link (child_table text not null, constraint_name text not null, child_column text not null, '
                             'parent_table text not null, parent_column text not null, primary key (child_table, constraint_name))')
            self.con.execute('delete from sap._link')
            with self.con.cursor() as cur:
                cur.executemany('insert into sap._link values (%s,%s,%s,%s,%s)', links)
        return len(links)

    def s_orphans_03(self):
        nlinks = self.refresh_links()
        rows = self.con.execute('select link, child_table, rows, sample from erp.migration_orphans(%s)', [self.company]).fetchall()
        self.orphan_links = {r[0] for r in rows}
        total = sum(r[2] for r in rows)
        if not rows:
            return ('ok', 0, '%d links checked for %s, no orphans' % (nlinks, self.company))
        return ('warning', total, '%d orphan rows on %d links (critical issues in cross_check; those links stay NOT VALID): %s'
                % (total, len(rows), '; '.join('%s [%s]' % (r[0], ', '.join(r[3] or [])) for r in rows[:10])))

    def add_links(self):
        con = self.con
        text = self.script('04_foreign_keys.sql')
        have = {(t, c) for t, c in con.execute("select conrelid::regclass::text, conname from pg_constraint where contype = 'f' and connamespace = 'sap'::regnamespace")}
        adds, idx, vals = [], [], []
        for line in text.splitlines():
            m = re.match(r'^ALTER TABLE (sap\."[^"]+") (ADD|VALIDATE) CONSTRAINT "([^"]+)"', line)
            if m and m.group(2) == 'ADD':
                if (m.group(1), m.group(3)) not in have and (m.group(1).replace('"', ''), m.group(3)) not in have:
                    adds.append(line)
            elif m:
                vals.append((line, m.group(1), m.group(3)))
            elif line.startswith('CREATE INDEX'):
                idx.append(line)
        with con.transaction():
            if adds or idx:
                con.execute('\n'.join(adds + idx))
        # links of this company with orphans cannot validate: leave them NOT VALID
        orphan_cons = {r[0] for r in con.execute('select constraint_name from sap._link l where format(%s, l.child_table, l.child_column, l.parent_table, l.parent_column) = any(%s)',
                                                ['%s.%s -> %s.%s', list(self.orphan_links)])} if self.orphan_links else set()
        valid = {c for (c,) in con.execute("select conname from pg_constraint where contype = 'f' and connamespace = 'sap'::regnamespace and convalidated")}
        todo = [(l, t, c) for l, t, c in vals if c not in valid and c not in orphan_cons]
        left = sorted(orphan_cons)
        try:
            with con.transaction():
                if todo:
                    con.execute('\n'.join(l for l, _, _ in todo))
        except psycopg.Error:
            for l, t, c in todo:
                try:
                    with con.transaction():
                        con.execute(l)
                except psycopg.Error:
                    left.append(c)
        n = con.execute("select count(*) from pg_constraint where contype = 'f' and connamespace = 'sap'::regnamespace and convalidated").fetchone()[0]
        return n, left

    def s_links_04(self):
        validated, left = self.add_links()
        if left:
            return ('warning', validated, '%d links validated; %d left NOT VALID because of orphan rows: %s' % (validated, len(left), ', '.join(left[:20])))
        return ('ok', validated, '%d links validated' % validated)

    def s_real_keys(self):
        files = self.files.get('constraints_csv')
        if not files:
            return ('skipped', None, 'no constraints.csv (05 query 2) in the upload')
        real = {}
        with open(files[0], newline='', encoding='utf-8-sig') as fh:
            for r in csv.DictReader(fh):
                if r['IS_PRIMARY_KEY'].upper() == 'TRUE':
                    real.setdefault(r['TABLE_NAME'], []).append((int(float(r['POSITION'])), r['COLUMN_NAME']))
        cur = {}
        for t, cols in self.con.execute("""select c.relname, array_agg(a.attname order by k.ord) from pg_constraint x join pg_class c on c.oid = x.conrelid
                                             cross join unnest(x.conkey) with ordinality k(att, ord) join pg_attribute a on a.attrelid = c.oid and a.attnum = k.att
                                            where x.contype = 'p' and c.relnamespace = 'sap'::regnamespace group by 1"""):
            cur[t] = [c for c in cols if c != 'company_code']
        diff = [t for t, cols in real.items() if t in cur and cur[t] != ['_row_id'] and [c for _, c in sorted(cols)] != cur[t]]
        self.check('structure', 'primary keys differing from SAP (constraints.csv)', sap=0, raw=len(diff), ok=not diff, detail={'tables': diff[:300]})
        if diff:
            self.issue('warning', 'structure', 'real_keys', '%d tables use a key that differs from SAP\'s' % len(diff),
                       'Run apply_keys.py with this constraints.csv and 07_real_keys.sql (affects every company), then reload. Tables: ' + ', '.join(diff[:40]))
            return ('warning', len(real), '%d tables compared, %d keys differ (not changed automatically)' % (len(real), len(diff)))
        return ('ok', len(real), '%d tables compared, all keys match' % len(real))

    def security_state(self):
        return self.con.execute("""select (select count(*) from pg_class where relnamespace = 'sap'::regnamespace and relkind = 'r' and not relrowsecurity),
                                          (select count(*) from pg_class where relnamespace = 'sap'::regnamespace and relkind = 'r'),
                                          has_schema_privilege('anon', 'sap', 'USAGE') or has_schema_privilege('authenticated', 'sap', 'USAGE')""").fetchone()

    def s_security_06(self):
        open_, total, exposed = self.security_state()
        ran = ''
        if open_ or exposed:
            self.con.execute('\n'.join(l for l in self.script('06_security.sql').splitlines() if l.strip().upper() not in ('BEGIN;', 'COMMIT;')))
            for (t,) in self.con.execute("select relname from pg_class where relnamespace = 'sap'::regnamespace and relkind = 'r' and not relrowsecurity").fetchall():
                self.con.execute(sql.SQL('alter table sap.{} enable row level security').format(sql.Identifier(t)))
            ran = '06_security.sql applied; '
            open_, total, exposed = self.security_state()
        if open_ or exposed:
            raise StepError('raw layer still open: %d tables without RLS, API roles have schema usage: %s' % (open_, exposed))
        return ('ok', total, ran + '%d raw tables with RLS, sap schema closed to anon/authenticated' % total)

    def s_app_sync(self):
        before = self.con.execute('select coalesce(max(sync_id), 0) from erp.sync_log').fetchone()[0]
        self.con.execute('select erp.migration_sync_company(%s)', [self.company])   # all 83 steps inside the run's transaction
        n, steps, err = self.con.execute('select coalesce(sum(rows_written), 0), count(*), string_agg(error, \'; \') from erp.sync_log where company_code = %s and sync_id > %s',
                                         [self.company, before]).fetchone()
        if err:
            raise StepError('sync errors: ' + err)
        return ('ok', n, '%d sync steps, %d rows written' % (steps, n))

    def s_check_sync(self):
        rows = self.con.execute('select check_name, sap_value, erp_value, ok from erp.check_sync(%s)', [self.company]).fetchall()
        bad = [r for r in rows if not r[3]]
        return ('warning' if bad else 'ok', len(rows), '%d checks, %d not ok%s' % (len(rows), len(bad), (': ' + '; '.join('%s raw %s app %s' % r[:3] for r in bad)) if bad else ''))

    def s_check_deleted(self):
        rows = self.con.execute('select what, rows from erp.check_deleted(%s)', [self.company]).fetchall()
        n = sum(r[1] for r in rows)
        return ('warning' if n else 'ok', n, ('; '.join('%s %d' % r for r in rows)) if rows else 'no app rows missing from SAP')

    def s_cross_check(self):
        c, checks, failed, crit, warn, info = self.con.execute('select * from erp.migration_cross_check(NULL, %s)', [self.run_id]).fetchone()
        return ('warning' if failed or crit else 'ok', checks,
                '%d companies cross-checked: %d checks, %d failed; open issues %d critical, %d warning, %d info' % (c, checks, failed, crit, warn, info))


def claim(con, run_id=None):
    """Take one queued run (or the given one). Returns its run_id or None."""
    with con.transaction():
        if run_id:
            r = con.execute("select run_id, status from erp.migration_run where run_id = %s for update", [run_id]).fetchone()
            if not r:
                raise SystemExit('run %s not found' % run_id)
            if r[1] not in ('queued', 'uploading'):
                raise SystemExit('run %s is %s - only a queued run is processed' % (run_id, r[1]))
        else:
            r = con.execute("select run_id from erp.migration_run where status = 'queued' order by created_at for update skip locked limit 1").fetchone()
            if not r:
                return None
        con.execute("update erp.migration_run set status = 'validating', started_at = now() where run_id = %s", [r[0]])
        return r[0]


def process(con, bk, run_id, a):
    run = Run(con, bk, run_id, a)
    if a.source == 'local':
        if not a.folder or not os.path.isdir(a.folder):
            raise SystemExit('--folder must be an existing folder for --source local')
        return run.execute(os.path.abspath(a.folder))
    work = tempfile.mkdtemp(prefix='mig_%s_' % str(run_id)[:8], dir=a.workdir)
    try:
        n = storage_download(run.prefix or '%s/%s' % (run.company, run_id), work)
        print('downloaded %d objects from %s/%s' % (n, BUCKET, run.prefix))
    except Exception as e:
        run.init_steps(DATA_STEPS)
        run.bk.execute("update erp.migration_step set status = 'failed', message = %s where run_id = %s and code = 'validate'", ['download: %s' % e, run_id])
        run.issue('critical', 'worker', 'download', 'Could not download the upload from Storage', str(e))
        run.set_status('failed', finished_at=datetime.datetime.now(datetime.timezone.utc))
        shutil.rmtree(work, ignore_errors=True)
        return 'failed'
    try:
        return run.execute(work)
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--dsn', required=True, help='database owner connection (direct or session pooler)')
    ap.add_argument('--source', choices=['local', 'storage'], default='storage')
    ap.add_argument('--folder', help='--source local: folder holding the upload')
    ap.add_argument('--run', help='process this run once')
    ap.add_argument('--new', metavar='COMPANY', help='create a run for COMPANY (no UI) and process it')
    ap.add_argument('--kind', default='full', choices=['full', 'tables', 'structure_only'], help='with --new')
    ap.add_argument('--notes', help='with --new')
    ap.add_argument('--poll', action='store_true', help='keep polling for queued runs')
    ap.add_argument('--interval', type=int, default=30, help='seconds between polls')
    ap.add_argument('--scripts', help='folder of 02/03/04/04z/06 (default: next to this file)')
    ap.add_argument('--workdir', help='--source storage: where downloads go (default: system temp)')
    ap.add_argument('--keep', action='store_true', help='--source storage: keep the downloaded files after the run')
    a = ap.parse_args()
    with psycopg.connect(a.dsn, autocommit=True) as con, psycopg.connect(a.dsn, autocommit=True) as bk:
        for c in (con, bk):
            c.execute('set statement_timeout = 0')
            c.execute('set idle_in_transaction_session_timeout = 0')
        if a.new:
            rid = con.execute("insert into erp.migration_run (company_code, kind, status, notes) values (%s, %s, 'queued', %s) returning run_id",
                              [a.new, a.kind, a.notes]).fetchone()[0]
            con.execute("update erp.migration_run set storage_prefix = company_code || '/' || run_id || '/' where run_id = %s", [rid])
            a.run = str(rid)
        if a.run:
            rid = claim(con, a.run)
            st = process(con, bk, rid, a)
            print(rid, st)
            sys.exit({'failed': 2, 'cancelled': 3}.get(st, 0))
        while True:
            rid = claim(con)
            if rid:
                process(con, bk, rid, a)
            elif not a.poll:
                print('no queued run')
                return
            else:
                time.sleep(a.interval)


if __name__ == '__main__':
    main()

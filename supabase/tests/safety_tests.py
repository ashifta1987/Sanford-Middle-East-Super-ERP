"""Failure safety, Stop run, and SAP report figures. Run after rebuild.sh (and optionally mc_tests.py):
    python3 mctest/safety_tests.py "host=localhost user=postgres password=pg dbname=mc_rebuild"
"""
import csv, json, os, shutil, subprocess, sys, time
import psycopg

B = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = os.path.join(B, 'mctest')
sys.path.insert(0, os.path.join(B, 'out'))
import load_company  # noqa: E402

DSN = sys.argv[1]
U = {k: '00000000-0000-0000-0000-00000000000%d' % i for i, k in enumerate(['fin', 'hr', 'merch', 'admin', 'business', 'it', 'admin_ae01'], 1)}
results = []
con = psycopg.connect(DSN, autocommit=True)
SRC = os.path.join(T, 'testexp', 'SA01')


def ok(name, cond, info=''):
    results.append((name, bool(cond)))
    print('%-4s %-78s %s' % ('PASS' if cond else 'FAIL', name, info), flush=True)


def as_user(user, q, params=None):
    with psycopg.connect(DSN) as c:
        try:
            c.execute('set local role authenticated')
            c.execute("select set_config('request.jwt.claims', %s, true)", [json.dumps({'sub': U[user]})])
            cur = c.execute(q, params)
            r = cur.fetchall() if cur.description else None
            c.commit()
            return r
        except psycopg.Error as e:
            return 'ERROR: ' + str(e).splitlines()[0]


def state(co):
    """Everything that must not change: raw rows per table (count + hash), app rows, check_sync, load log, links."""
    raw = {}
    for (t,) in con.execute("select relname from pg_class where relnamespace='sap'::regnamespace and relkind='r' and relname !~ '^_' order by 1").fetchall():
        n, h = con.execute('select count(*), md5(coalesce(string_agg(x::text, \'|\' order by x::text), \'\')) from sap."%s" x where company_code = %%s' % t, [co]).fetchone()
        if n:
            raw[t] = (n, h)
    app = {}
    for (t,) in con.execute("""select c.relname from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attname = 'company_code'
                                where c.relnamespace = 'erp'::regnamespace and c.relkind = 'r' and c.relname !~ '^(migration_|sync_log|audit_log)' order by 1""").fetchall():
        app[t] = con.execute('select count(*), md5(coalesce(string_agg(x::text, \'|\' order by x::text), \'\')) from erp."%s" x where company_code = %%s' % t, [co]).fetchone()
    chk = con.execute('select check_name, sap_value, erp_value, ok from erp.check_sync(%s) order by 1', [co]).fetchall()
    log = con.execute('select count(*) from sap._load_log where company_code = %s', [co]).fetchone()[0]
    links = con.execute("select count(*) filter (where convalidated), count(*) from pg_constraint where contype='f' and connamespace='sap'::regnamespace").fetchone()
    return dict(raw=raw, app=app, check_sync=chk, load_log=log, links=links)


def worker(*args, wait=True):
    cmd = [sys.executable, os.path.join(B, 'out', 'migration_worker.py'), '--dsn', DSN, *args]
    if not wait:
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(p.stdout[-2500:], p.stderr[-1500:])
    return p


def last_run(note):
    return con.execute('select run_id, status from erp.migration_run where notes = %s order by created_at desc limit 1', [note]).fetchone()


def copy_export(name):
    d = os.path.join(T, 'safety', name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(SRC, d)
    return d


def table_csv(folder, table):
    for name, cols, files in load_company.export_tables(folder):
        if name == table:
            return cols if not os.path.exists(os.path.join(folder, 'columns.csv')) else \
                [c for _, c in sorted(load_company.read_columns(os.path.join(folder, 'columns.csv'))[table])], files[0]


def edit(folder, table, column, fn, row=None):
    cols, f = table_csv(folder, table)
    rows = list(csv.reader(open(f, newline='', encoding='utf-8')))
    i = cols.index(column)
    for k, r in enumerate(rows):
        if row is None or k == row:
            r[i] = fn(r[i])
    with open(f, 'w', newline='', encoding='utf-8') as fh:
        csv.writer(fh, quoting=csv.QUOTE_MINIMAL).writerows(rows)


def summary(st):
    return 'SA01 raw %d tables/%d rows, app %d rows, check_sync %s, load log %d, links %d/%d' % (
        len(st['raw']), sum(v[0] for v in st['raw'].values()), sum(v[0] for v in st['app'].values()),
        ','.join(str(r[2]) for r in st['check_sync']), st['load_log'], *st['links'])


shutil.rmtree(os.path.join(T, 'safety'), ignore_errors=True)
before = state('SA01')
ae = state('AE01')
print('before:', summary(before))

# ---------------------------------------------------------------- 1a. bad CSV that cannot be read (stage)
d = copy_export('stage_bad')
edit(d, 'OITW', 'OnHand', lambda v: '1234')
cols, f = table_csv(d, 'OSLP')
open(f, 'a', encoding='utf-8').write('"unterminated,quote\n')
worker('--new', 'SA01', '--source', 'local', '--folder', d, '--notes', 'safety stage')
rid, st = last_run('safety stage')
ok('1a stage failure (unreadable CSV): run failed', st == 'failed', st)
ok('1a SA01 raw, app, check_sync, load log, links unchanged', state('SA01') == before)

# ---------------------------------------------------------------- 1b. failure mid-load: cast error after other tables replaced
d = copy_export('cast_bad')
order = [n for n, _, _ in load_company.export_tables(d)]
last = order[-1] if order[-1] != 'OITW' else order[-2]
edit(d, 'OITW', 'OnHand', lambda v: '1234')                      # cast earlier/later; would change stock if kept
edit(d, 'JDT1', 'Debit', lambda v: v, row=None)
cols, f = table_csv(d, last)
lines = open(f, encoding='utf-8').read().splitlines(keepends=True)
open(f, 'a', encoding='utf-8').write(lines[0])                   # duplicate key in the last table cast -> cast fails
p = worker('--new', 'SA01', '--source', 'local', '--folder', d, '--notes', 'safety cast')
rid, st = last_run('safety cast')
steps = dict(con.execute('select code, status from erp.migration_step where run_id=%s', [rid]).fetchall())
ok('1b mid-load failure (duplicate key in %s, cast as table %d of %d): run failed at cast' % (last, order.index(last) + 1, len(order)),
   st == 'failed' and steps['cast'] == 'failed', (st, steps['cast']))
now = state('SA01')
ok('1b SA01 raw, app, check_sync, load log, links unchanged', now == before, summary(now))
iss = con.execute("select severity, title, detail from erp.migration_issue where run_id=%s and issue_key='run_failed'", [rid]).fetchone()
ok('1b failure is a critical issue that says the company was rolled back', iss and iss[0] == 'critical' and 'exactly as before' in iss[2], iss[1] if iss else None)

# ---------------------------------------------------------------- 1c. failure mid-app-sync (after raw replaced, 02, 04 done)
d = copy_export('sync_bad')
edit(d, 'OITW', 'OnHand', lambda v: '1234')                      # synced by sync_stock_balances (step 22) before the failure
edit(d, 'JDT1', 'Account', lambda v: 'ZZZZ', row=0)              # no such account: erp.journal_line FK fails in sync_journal_lines
worker('--new', 'SA01', '--source', 'local', '--folder', d, '--notes', 'safety sync')
rid, st = last_run('safety sync')
steps = dict(con.execute('select code, status from erp.migration_step where run_id=%s', [rid]).fetchall())
ok('1c mid-app-sync failure: cast..security ok, app_sync failed', st == 'failed' and steps['app_sync'] == 'failed' and steps['links_04'] == 'warning',
   {k: steps[k] for k in ('cast', 'links_04', 'app_sync', 'check_sync')})
now = state('SA01')
ok('1c SA01 raw, app (incl. stock synced before the error), check_sync, load log, links unchanged', now == before, summary(now))
ok('1c AE01 unchanged', state('AE01') == ae)

# ---------------------------------------------------------------- 2. Stop a running run
r = as_user('admin', "select erp.migration_request('SA01', 'full', 'stop test upload')")
rid0 = r[0][0]
ok('2 cancel while uploading: cancelled at once', as_user('admin', 'select erp.migration_cancel(%s)', [rid0]) == [('cancelled',)])
d = copy_export('stop')
edit(d, 'OITW', 'OnHand', lambda v: '1234')
started = con.execute('select now()').fetchone()[0]
p = worker('--new', 'SA01', '--source', 'local', '--folder', d, '--notes', 'safety stop', wait=False)
rid = None
t0 = time.time()
while time.time() - t0 < 60:
    r = con.execute("select r.run_id, s.status from erp.migration_run r join erp.migration_step s on s.run_id = r.run_id and s.code = 'cast' "
                    "where r.notes = 'safety stop' and r.created_at >= %s order by r.created_at desc limit 1", [started]).fetchone()
    if r and r[1] == 'ok':
        rid = r[0]; break
    time.sleep(0.05)
res = as_user('admin', 'select erp.migration_cancel(%s)', [rid])
ok('2 "Stop run" on a running run (after cast) returns stop_requested', res == [('stop_requested',)], res)
with psycopg.connect(DSN, autocommit=True) as c2:            # while the run is open: never a half-loaded company
    c2.execute("set lock_timeout = '300ms'")
    try:
        mid = c2.execute('select count(*) from sap."OITW" where company_code = %s and "OnHand" = 1234', ['SA01']).fetchone()[0]
    except psycopg.errors.LockNotAvailable:
        mid = 'waits for the run (locked)'
    app_mid = c2.execute("select count(*) from erp.stock_balance where company_code = 'SA01' and on_hand = 1234").fetchone()[0]
ok('2 while the run is open others never see the new rows (raw: %s, app: %s)' % (mid, app_mid), mid in (0, 'waits for the run (locked)') and app_mid == 0)
out = p.communicate(timeout=120)[0]
print(out[-1500:])
rr = con.execute('select status, stop_requested_at is not null, stop_requested_by from erp.migration_run where run_id=%s', [rid]).fetchone()
ok('2 run marked cancelled, stop recorded with the user', rr[0] == 'cancelled' and rr[1] and str(rr[2]) == U['admin'], rr)
steps = con.execute('select code, status from erp.migration_step where run_id=%s order by step_no', [rid]).fetchall()
ok('2 stopped between steps: later steps skipped', any(s == 'skipped' for _, s in steps) and dict(steps)['cast'] == 'ok', steps)
iss = con.execute("select severity, title, detail from erp.migration_issue where run_id=%s and issue_key='run_stopped'", [rid]).fetchone()
ok('2 info issue for the stop', iss and iss[0] == 'info', iss[1] if iss else None)
now = state('SA01')
ok('2 SA01 raw, app, check_sync, load log, links unchanged after the stop', now == before, summary(now))
res = as_user('admin', 'select erp.migration_cancel(%s)', [rid])
ok('2 cancelling a finished run is refused', isinstance(res, str) and 'can be cancelled' in res, res)
ok('2 AE01 unchanged', state('AE01') == ae)

# ---------------------------------------------------------------- 3. SAP report figures
worker('--new', 'SA01', '--source', 'local', '--folder', SRC, '--notes', 'report figures')
rid, st = last_run('report figures')
ok('3 clean run ends needs_review', st == 'needs_review', st)
groups = dict(con.execute("select check_name, raw_value from erp.migration_check where run_id=%s and company_code='SA01' and check_name like 'account group %%'", [rid]).fetchall())
ok('3 account group totals (debit - credit): assets 105, liabilities -805, equity 0, revenue -100, expenses 800',
   {k: float(v) for k, v in groups.items()} == {'account group assets': 105, 'account group liabilities': -805, 'account group equity': 0,
                                                 'account group revenue': -100, 'account group expenses': 800}, groups)
miss = con.execute("select count(*) from erp.migration_issue where run_id=%s and status='open' and severity='warning' and title like 'Finance has not entered%%'", [rid]).fetchone()[0]
ok('3 8 warnings "Finance has not entered the SAP report figure" (run company only)', miss == 8, miss)
figs = [('finance', 'account group assets', 105), ('finance', 'account group liabilities', -805), ('finance', 'account group equity', 0),
        ('finance', 'account group revenue', -100), ('finance', 'account group expenses', 800),
        ('finance', 'open A/R (invoices + down payments - credit notes)', 105), ('stock', 'on hand value, all warehouses', 29630)]
for area, name, v in figs:
    as_user('fin', 'select * from erp.migration_set_report_figure(%s, %s, %s, %s, %s, %s)', [rid, 'SA01', area, name, v, 'SAP B1 report 08.11.2026'])
r = as_user('fin', 'select * from erp.migration_set_report_figure(%s, %s, %s, %s, %s, %s)',
            [rid, 'SA01', 'finance', 'open A/P (invoices + down payments - credit notes)', 545, 'SAP B1 aging 08.11.2026'])
ok('3 finance enters 8 figures; A/P 545 vs 540 reported not ok', isinstance(r, list) and r[0][4] is False, r)
crit = con.execute("select title from erp.migration_issue where run_id=%s and status='open' and severity='critical'", [rid]).fetchall()
ok('3 the A/P difference opens a critical issue', crit == [('SA01: SAP report figure differs - open A/P (invoices + down payments - credit notes)',)], crit)
miss = con.execute("select count(*) from erp.migration_issue where run_id=%s and status='open' and title like 'Finance has not entered%%'", [rid]).fetchone()[0]
ok('3 missing-figure warnings closed once entered', miss == 0, miss)
r = as_user('fin', "select erp.migration_sign(%s, 'finance', 'approved', null)", [rid])
ok('3 finance sign-off refused while the report differs', isinstance(r, str) and 'critical' in r, r)
r = as_user('merch', 'select * from erp.migration_set_report_figure(%s, %s, %s, %s, %s, %s)', [rid, 'SA01', 'finance', 'account group assets', 1, 'x'])
ok('3 a merchandiser cannot enter report figures', isinstance(r, str) and 'only finance' in r, r)
r = as_user('fin', 'select * from erp.migration_set_report_figure(%s, %s, %s, %s, %s, %s)', [rid, 'SA01', 'finance', 'no such check', 1, 'x'])
ok('3 unknown check name refused', isinstance(r, str) and 'has no check' in r, r)
r = as_user('fin', 'select count(*) from erp.migration_report_figure')
ok('3 finance cannot read the figure table directly (admin only); sees figures via migration_review', r == [(0,)], r)
r = as_user('admin', 'select * from erp.migration_set_report_figure(%s, %s, %s, %s, %s, %s)',
            [rid, 'SA01', 'finance', 'open A/P (invoices + down payments - credit notes)', 540, 'SAP B1 aging 08.11.2026, corrected'])
ok('3 admin corrects A/P to 540 -> ok', isinstance(r, list) and r[0][4] is True, r)
crit = con.execute("select count(*) from erp.migration_issue where run_id=%s and status='open' and severity='critical'", [rid]).fetchone()[0]
ok('3 critical issue closed', crit == 0, crit)
raw_app = con.execute("select raw_value, app_value from erp.migration_check where run_id=%s and check_name like 'open A/P%%' and company_code='SA01'", [rid]).fetchone()
ok('3 raw/app values untouched by the figure (540 / 540)', tuple(map(float, raw_app)) == (540, 540), raw_app)
con.execute('select * from erp.migration_cross_check(NULL, %s)', [rid])        # a re-run of the cross-check
kept = con.execute("select count(*) from erp.migration_check where run_id=%s and report_value is not null", [rid]).fetchone()[0]
opn = con.execute("select count(*) filter (where severity='critical'), count(*) filter (where title like 'Finance has not%%') from erp.migration_issue where run_id=%s and status='open'", [rid]).fetchone()
ok('3 figures survive a re-run of the cross-check (8 compared), no issue re-opened', kept == 8 and opn == (0, 0), (kept, opn))
rv = as_user('fin', "select name, report_value, raw_value, app_value, report_ok, report_required from erp.migration_review(%s, 'finance') where item = 'check' and report_required", [rid])
ok('3 finance sees report_value next to raw and app in migration_review (7 finance headline checks)', isinstance(rv, list) and len(rv) == 7 and all(x[4] for x in rv), rv[:2] if isinstance(rv, list) else rv)
stt = as_user('fin', 'select report_figures, report_missing from erp.migration_status(%s) limit 1', [rid])
ok('3 migration_status counts figures entered / missing', stt == [(8, 0)], stt)
r = as_user('fin', "select erp.migration_sign(%s, 'finance', 'approved', 'TB, aging and stock agree with SAP')", [rid])
ok('3 finance signs once the report figures agree', r == [('needs_review',)], r)

print('\n%d passed, %d failed' % (sum(r[1] for r in results), sum(not r[1] for r in results)))
sys.exit(0 if all(r[1] for r in results) else 1)

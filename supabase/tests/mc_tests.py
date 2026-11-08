"""Migration console tests (b) broken upload + sign-off, (c) structure-only upload, (d) RLS, then a clean reload.
Run after mctest/rebuild.sh and test (a):  python3 mctest/mc_tests.py "host=localhost user=postgres password=pg dbname=mc_rebuild"
"""
import json, os, shutil, subprocess, sys
import psycopg

B = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = os.path.join(B, 'mctest')
DSN = sys.argv[1]
XLSX = '/mnt/user-data/attachments/b8128d69-9c25-5ac1-bf8e-19ca71e39a75/e4fb193a-Table_With_Field.xlsx'
U = {k: '00000000-0000-0000-0000-00000000000%d' % i for i, k in enumerate(['fin', 'hr', 'merch', 'admin', 'business', 'it', 'admin_ae01'], 1)}
results = []
con = psycopg.connect(DSN, autocommit=True)


def ok(name, cond, info=''):
    results.append((name, bool(cond), info))
    print('%-4s %-70s %s' % ('PASS' if cond else 'FAIL', name, info), flush=True)


def as_user(user, q, params=None, fetch=True):
    """Run q as an app user (role authenticated + JWT sub) or as anon (user=None). Returns rows or the error text."""
    with psycopg.connect(DSN) as c:
        try:
            if user:
                c.execute('set local role authenticated')
                c.execute("select set_config('request.jwt.claims', %s, true)", [json.dumps({'sub': U[user]})])
            else:
                c.execute('set local role anon')
            cur = c.execute(q, params)
            r = cur.fetchall() if fetch and cur.description else None
            c.commit()
            return r
        except psycopg.Error as e:
            return 'ERROR: ' + str(e).splitlines()[0]


def fingerprint(co):
    tabs = [r[0] for r in con.execute("select relname from pg_class where relnamespace='sap'::regnamespace and relkind='r' and relname !~ '^_' order by 1")]
    parts = []
    for t in tabs:
        r = con.execute('select count(*), md5(coalesce(string_agg(x::text, \'|\' order by x::text), \'\')) from sap."%s" x where company_code = %%s' % t, [co]).fetchone()
        if r[0]:
            parts.append('%s:%s:%s' % (t, r[0], r[1]))
    erp = con.execute("select md5(string_agg(x::text, '|' order by x::text)) from (select * from erp.journal_line where company_code=%s) x", [co]).fetchone()[0]
    return len(parts), sum(int(p.split(':')[1]) for p in parts), hash('\n'.join(parts) + erp)


def worker(*args):
    p = subprocess.run([sys.executable, os.path.join(B, 'out', 'migration_worker.py'), '--dsn', DSN, *args], capture_output=True, text=True)
    print(p.stdout[-3000:], p.stderr[-2000:])
    return p


def issues(run, status='open'):
    return con.execute('select severity, area, title from erp.migration_issue where run_id=%s and status=%s order by severity, area, title', [run, status]).fetchall()


ae0 = fingerprint('AE01')
print('AE01 fingerprint before: %d tables, %d rows' % ae0[:2])

# ------------------------------------------------------------------ (b) broken upload through the UI path
broken = os.path.join(T, 'broken', 'SA01')
shutil.rmtree(os.path.join(T, 'broken'), ignore_errors=True)
shutil.copytree(os.path.join(T, 'testexp', 'SA01'), broken)
jdt1 = os.path.join(broken, 'index', 'SBO_SANFORD_KSA', 'JD', 'JDT1', 'data.csv')
lines = open(jdt1, encoding='utf-8').read().splitlines(keepends=True)
open(jdt1, 'w', encoding='utf-8').writelines(lines[:-1])            # delete one journal line (row_counts.csv still says 6)
inv1 = os.path.join(broken, 'index', 'SBO_SANFORD_KSA', 'IN', 'INV1', 'data.csv')
s = open(inv1, encoding='utf-8').read()
open(inv1, 'w', encoding='utf-8').write(s.replace('SF-RC18', 'SF-GHOST', 1))   # an invoice line pointing at an item SA01 does not have

rid = as_user('admin', "select erp.migration_request('SA01', 'full', 'test b: broken upload')")
ok('(b) admin migration_request returns run_id', isinstance(rid, list), rid)
rid = rid[0][0]
st = as_user('admin', 'select erp.migration_submit(%s)', [rid])
ok('(b) admin migration_submit -> queued', st == [('queued',)], st)
dup = as_user('admin', "select erp.migration_request('SA01', 'full', 'second')")
ok('(b) second request for a company with a queued run refused', isinstance(dup, str) and 'in progress' in dup, dup)
p = worker('--run', str(rid), '--source', 'local', '--folder', broken)
run_status = con.execute('select status from erp.migration_run where run_id=%s', [rid]).fetchone()[0]
ok('(b) broken run ends needs_review', run_status == 'needs_review', run_status)
steps = con.execute('select code, status, rows from erp.migration_step where run_id=%s order by step_no', [rid]).fetchall()
print('    steps:', ', '.join('%s=%s' % (c, s) for c, s, _ in steps))
crit = issues(rid)
print('    open issues:'); [print('      ', i) for i in crit]
ok('(b) row count mismatch issue (JDT1 5 vs 6)', any(a == 'row_counts' and 'JDT1' in t and sv == 'critical' for sv, a, t in crit))
ok('(b) orphan issue (INV1.ItemCode -> OITM)', any(a == 'orphans' and 'INV1' in t and sv == 'critical' for sv, a, t in crit))
ok('(b) unbalanced journal issue', any(a == 'finance' and 'balance' in t for sv, a, t in crit))
nv = con.execute("select conname from pg_constraint where contype='f' and connamespace='sap'::regnamespace and not convalidated").fetchall()
ok('(b) only the orphan link left NOT VALID', nv == [('inv1_itemcode_fkey',)], nv)
ok('(b) AE01 untouched by the SA01 rebuild', fingerprint('AE01') == ae0)
ae_checks = con.execute("select count(*), count(*) filter (where not ok) from erp.migration_check where run_id=%s and company_code='AE01'", [rid]).fetchone()
ok('(b) cross-check covered AE01 too, all ok', ae_checks[0] > 0 and ae_checks[1] == 0, ae_checks)

r = as_user('fin', "select erp.migration_sign(%s, 'finance', 'approved', 'looks fine')", [rid])
ok('(b) finance sign-off refused while critical issues open', isinstance(r, str) and 'critical issue' in r, r)

# ------------------------------------------------------------------ (d) RLS
r = as_user(None, 'select count(*) from erp.migration_run')
ok('(d) anon cannot read migration_run', isinstance(r, str) and 'permission denied' in r, r)
r = as_user(None, "select erp.migration_request('SA01', 'full', null)")
ok('(d) anon cannot call migration_request', isinstance(r, str) and 'permission denied' in r, r)
for t in ['migration_run', 'migration_file', 'migration_step', 'migration_check', 'migration_issue', 'migration_signoff']:
    r = as_user('fin', 'select count(*) from erp.%s' % t)
    ok('(d) finance (non-admin) reads 0 rows of %s' % t, r == [(0,)], r)
r = as_user('merch', 'select count(*) from erp.migration_issue')
ok('(d) merchandiser reads 0 migration issues', r == [(0,)], r)
r = as_user('admin', 'select count(*) from erp.migration_run')
ok('(d) admin reads migration runs', isinstance(r, list) and r[0][0] >= 2, r)
r = as_user('admin_ae01', "select count(*) from erp.migration_run where company_code='SA01'")
ok('(d) admin limited to AE01 sees no SA01 runs', r == [(0,)], r)
r = as_user('admin_ae01', "select erp.migration_request('SA01', 'full', null)")
ok('(d) admin limited to AE01 cannot start an SA01 run', isinstance(r, str) and 'not in your company list' in r, r)
for f, q in [('migration_cross_check', "select * from erp.migration_cross_check('SA01', %s)"), ('migration_orphans', "select * from erp.migration_orphans('SA01')"),
             ('migration_add_issue', "select erp.migration_add_issue(%s, 'SA01', 'info', 'x', 'x', 'x')")]:
    for u in ('fin', 'admin'):
        r = as_user(u, q, [rid] if '%s' in q else None)
        ok('(d) %s cannot call worker-only %s' % (u, f), isinstance(r, str) and 'permission denied' in r, r)
r = as_user('fin', "insert into erp.migration_run (company_code, kind) values ('SA01', 'full')")
ok('(d) finance cannot insert a run directly', isinstance(r, str) and 'permission denied' in r, r)
r = as_user('admin', "insert into erp.migration_run (company_code, kind) values ('SA01', 'full')")
ok('(d) admin cannot insert a run directly either (function only)', isinstance(r, str) and 'permission denied' in r, r)
r = as_user('admin', "update erp.migration_issue set status = 'fixed'")
ok('(d) admin cannot update issues directly', isinstance(r, str) and 'permission denied' in r, r)
r = as_user('fin', "select erp.migration_request('SA01', 'full', null)")
ok('(d) finance cannot start a run', isinstance(r, str) and 'only admin' in r, r)
iid = con.execute("select issue_id from erp.migration_issue where run_id=%s and severity='critical' limit 1", [rid]).fetchone()[0]
r = as_user('fin', "select erp.migration_resolve_issue(%s, 'accepted', 'fine')", [iid])
ok('(d) finance cannot resolve issues', isinstance(r, str) and 'only admin' in r, r)
r = as_user('fin', 'select step_code, step_status, critical_open from erp.migration_status(%s)', [rid])
ok('(d) finance (sign-off role) can read migration_status', isinstance(r, list) and len(r) == 12, r[:1] if isinstance(r, list) else r)
r = as_user('merch', 'select * from erp.migration_status(%s)', [rid])
ok('(d) merchandiser cannot read migration_status', isinstance(r, str) and 'not found' in r, r)
r = as_user('fin', "select count(*) from erp.migration_review(%s, 'finance')", [rid])
ok('(d) finance can read the review list of a run that needs review', isinstance(r, list) and r[0][0] > 0, r)
r = as_user('fin', "select erp.migration_sign(%s, 'it', 'approved', null)", [rid])
ok('(d) finance cannot sign as it', isinstance(r, str) and 'cannot sign off as it' in r, r)
r = as_user('admin', "select erp.migration_resolve_issue(%s, 'accepted', '')", [iid])
ok('(d) accepting a critical issue without a note refused', isinstance(r, str) and 'needs a note' in r, r)

# resolve and sign
for (i,) in con.execute("select issue_id from erp.migration_issue where run_id=%s and status='open' and severity='critical'", [rid]).fetchall():
    as_user('admin', "select erp.migration_resolve_issue(%s, 'accepted', 'test data broken on purpose')", [i])
left = con.execute("select count(*) from erp.migration_issue where run_id=%s and status='open' and severity='critical'", [rid]).fetchone()[0]
ok('(d) admin resolved every critical issue', left == 0, left)
r = as_user('fin', "select erp.migration_sign(%s, 'finance', 'approved', 'TB reviewed')", [rid])
ok('(d) finance signs finance once issues are resolved', r == [('needs_review',)], r)
r = as_user('business', "select erp.migration_sign(%s, 'finance', 'approved', null)", [rid])
ok('(d) business cannot sign as finance', isinstance(r, str) and 'cannot sign off as finance' in r, r)
r = as_user('it', "select erp.migration_sign(%s, 'it', 'approved', null)", [rid])
ok('(d) IT signs it', r == [('needs_review',)], r)
r = as_user('business', "select erp.migration_sign(%s, 'business', 'approved', null)", [rid])
ok('(d) business signs business -> signed_off', r == [('signed_off',)], r)
r = as_user('admin', "select erp.migration_resolve_issue(%s, 'open', 'reopen')", [iid])
ok('(d) issues frozen after sign-off', isinstance(r, str) and 'signed off' in r, r)
n = con.execute("select count(*) filter (where object = 'migration_run'), count(*) filter (where object = 'migration_issue') from erp.audit_log "
                "where (object = 'migration_run' and object_ref = %s) or (object = 'migration_issue' and object_ref in "
                "(select issue_id::text from erp.migration_issue where run_id = %s))", [str(rid), rid]).fetchone()
nres = con.execute("select count(*) from erp.migration_issue where run_id=%s and status='accepted'", [rid]).fetchone()[0]
ok('(d) request, submit, 3 sign-offs and every issue decision (%d) are in erp.audit_log' % nres, n == (5, nres), n)

# ------------------------------------------------------------------ (c) structure-only upload with the real field list
sdir = os.path.join(T, 'structure_upload')
shutil.rmtree(sdir, ignore_errors=True)
os.makedirs(sdir)
os.symlink(XLSX, os.path.join(sdir, 'Table_With_Field.xlsx'))
logs0 = con.execute('select count(*) from sap._load_log').fetchone()[0]
sa0 = fingerprint('SA01')
p = worker('--new', 'SA01', '--kind', 'full', '--source', 'local', '--folder', sdir, '--notes', 'test c: field list uploaded as full')
srid = con.execute("select run_id from erp.migration_run where notes like 'test c%%' order by created_at desc limit 1").fetchone()[0]
run = con.execute('select status, kind from erp.migration_run where run_id=%s', [srid]).fetchone()
ok('(c) structure upload ends needs_review, detected as structure_only', run == ('needs_review', 'structure_only'), run)
ch = {r[0]: r[1:] for r in con.execute("select check_name, sap_value, raw_value, ok from erp.migration_check where run_id=%s and area='structure'", [srid])}
for k, v in ch.items():
    print('    %-48s sap=%-8s raw=%-8s ok=%s' % (k, *v))
ok('(c) 3,691 tables / 3,250 matched', ch['tables in field list'][:2] == (3691, 3250), ch['tables in field list'])
ok('(c) 441 tables not in sap schema', ch['tables not in sap schema (skipped on load)'][0] == 441)
ok('(c) 0 missing columns', ch['missing columns (in SAP, not in sap schema)'][1] == 0)
ok('(c) 0 type mismatches', ch['type mismatches'][1] == 0)
ok('(c) AUG1 repaired from an Excel date (9 fields)', ch['table names repaired (Excel dates)'][0] == 9)
fl = con.execute("select kind, count(*) from erp.migration_file where run_id=%s group by 1", [srid]).fetchall()
ok('(c) file classified as structure_xlsx', fl == [('structure_xlsx', 1)], fl)
inf = issues(srid)
ok('(c) info issue "Structure only, no data rows"', ('info', 'structure', 'Structure only, no data rows') in inf, inf)
ok('(c) no critical issue', not any(i[0] == 'critical' for i in inf))
sk = con.execute("select count(*) filter (where status='skipped'), count(*) from erp.migration_step where run_id=%s", [srid]).fetchone()
ok('(c) every data step skipped', sk == (11, 12), sk)
ok('(c) no data touched (load log, SA01 and AE01 unchanged)',
   con.execute('select count(*) from sap._load_log').fetchone()[0] == logs0 and fingerprint('SA01') == sa0 and fingerprint('AE01') == ae0)

# ------------------------------------------------------------------ clean reload restores SA01
p = worker('--new', 'SA01', '--kind', 'full', '--source', 'local', '--folder', os.path.join(T, 'testexp', 'SA01'), '--notes', 'recovery reload')
crid = con.execute("select run_id from erp.migration_run where notes = 'recovery reload' order by created_at desc limit 1").fetchone()[0]
st = con.execute("select status, (select count(*) from erp.migration_step where run_id=%s and status not in ('ok','skipped')), "
                 "(select count(*) from erp.migration_issue where run_id=%s and status='open' and issue_key not like 'report_missing:%%') "
                 "from erp.migration_run where run_id=%s", [crid, crid, crid]).fetchone()
ok('clean reload after the broken one: needs_review, all steps ok, 0 open issues besides the SAP report figures to enter', st == ('needs_review', 0, 0), st)
nv = con.execute("select count(*) filter (where convalidated), count(*) from pg_constraint where contype='f' and connamespace='sap'::regnamespace").fetchone()
ok('all links validated again', nv[0] == nv[1], nv)
ok('AE01 still untouched', fingerprint('AE01') == ae0)

print('\n%d passed, %d failed' % (sum(r[1] for r in results), sum(not r[1] for r in results)))
sys.exit(0 if all(r[1] for r in results) else 1)

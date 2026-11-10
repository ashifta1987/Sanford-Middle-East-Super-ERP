"""A12 end-to-end test on the test exports (supabase/tests/testexp and broken). LOCAL ONLY - never the live project.

    <venv>/bin/python supabase/tests/a12_testexp_e2e.py "host=127.0.0.1 port=5433 user=postgres" <base.txt> [result file]

Builds a scratch database erp_a12mig next to erp_local (same Postgres), applies base.txt + 27_migration_more.sql, creates
the raw tables of the test exports from their own create.sql (HANA types -> Postgres), loads AE01 and SA01 with
load_company.py, runs the app sync steps those tables feed, then the console's cross-check (erp.migration_cross_check_all)
and A12's checks, the custom-field register, the coexistence guard against the real sync functions, the broken
export, the attachment copy job of the worker (read-only source, local destination) and the opening-balances loader.
The full raw SAP DDL (3,253 tables, sanford-db-install.zip) is not in the repo: tables the exports do not contain are
created empty (LIKE OINV / INV1) only where the 13/11 checks name them.
"""
import csv, glob, hashlib, json, os, re, stat, subprocess, sys, tempfile, uuid
import psycopg
from psycopg import sql

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BASE = sys.argv[1]
BASE_LIST = sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, 'a12_testexp_result.txt')
DB = 'erp_a12mig'
DSN = BASE + ' dbname=' + DB
PY = sys.executable
lines, fails = [], 0


def say(s=''):
    print(s, flush=True)
    lines.append(s)


def check(ok, name, detail=''):
    global fails
    if not ok:
        fails += 1
    say('%s %-70s %s' % ('PASS' if ok else 'FAIL', name, str(detail)[:200]))


HANA = {'INTEGER': 'integer', 'INT': 'integer', 'SMALLINT': 'smallint', 'TINYINT': 'smallint', 'BIGINT': 'bigint', 'DOUBLE': 'double precision',
        'REAL': 'real', 'NCLOB': 'text', 'CLOB': 'text', 'TEXT': 'text', 'BLOB': 'bytea', 'VARBINARY': 'bytea', 'TIMESTAMP': 'timestamp',
        'SECONDDATE': 'timestamp', 'DATE': 'date', 'TIME': 'time'}


def pg_type(t):
    m = re.match(r'(N?VARCHAR|N?CHAR|ALPHANUM|SHORTTEXT)\((\d+)\)', t, re.I)
    if m:
        return 'varchar(%s)' % m.group(2)
    m = re.match(r'(SMALL)?DECIMAL\((\d+),\s*(\d+)\)', t, re.I)
    if m:
        return 'numeric(%s,%s)' % (m.group(2), m.group(3))
    return HANA.get(t.split('(')[0].upper(), 'text')


def ddl_columns(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    m = re.search(r'TABLE\s+"[^"]+"\."([^"]+)"\s*\((.*)\)', txt, re.S)
    return m.group(1), re.findall(r'"([^"]+)"\s+([A-Z]+(?:\(\d+(?:,\s*\d+)?\))?)', m.group(2))


def main():
    admin = psycopg.connect(BASE + ' dbname=postgres', autocommit=True)
    admin.execute('DROP DATABASE IF EXISTS %s WITH (FORCE)' % DB)
    admin.execute('CREATE DATABASE %s' % DB)
    con = psycopg.connect(DSN, autocommit=True)
    con.execute("""
      CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text);
      CREATE SCHEMA IF NOT EXISTS storage; CREATE SCHEMA IF NOT EXISTS sap;
      CREATE TABLE IF NOT EXISTS sap._company (company_code varchar(8) PRIMARY KEY, sap_schema text, legal_name text, country text, currency text, licence_type text, in_scope boolean DEFAULT true);
      CREATE TABLE IF NOT EXISTS sap._load_log (load_id bigserial PRIMARY KEY, run_id uuid, company_code varchar(8), table_name text, status text,
             rows_expected bigint, rows_loaded bigint, message text, loaded_at timestamptz DEFAULT now());
      CREATE TABLE IF NOT EXISTS storage.buckets (id text PRIMARY KEY, name text, public boolean DEFAULT false, file_size_limit bigint, allowed_mime_types text[]);
      CREATE TABLE IF NOT EXISTS storage.objects (id uuid DEFAULT gen_random_uuid() PRIMARY KEY, bucket_id text, name text, owner uuid, metadata jsonb);
      ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
      CREATE OR REPLACE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT string_to_array(name, '/') $$;
      DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') THEN CREATE PUBLICATION supabase_realtime; END IF; END $$;""")
    files = open(BASE_LIST).read().split() + ['supabase/sql/27_migration_more.sql']
    for f in files:
        con.execute('SET check_function_bodies = off')
        con.execute(open(os.path.join(REPO, f), encoding='utf-8').read())
    say('== %s: %d SQL files applied' % (DB, len(files)))
    con.execute("INSERT INTO sap._company VALUES ('AE01','SBO_SANFORD','Sanford Middle East DWC L.L.C','AE','AED','free_zone',true),"
                "('SA01','SBO_SANFORD_KSA','Sanford Japan Electronics Trading Company','SA','SAR','foreign',true) ON CONFLICT DO NOTHING")

    # raw tables from the exports' own create.sql
    cols = {}
    for p in sorted(glob.glob(os.path.join(HERE, 'testexp', '*', 'index', '*', '*', '*', 'create.sql'))):
        t, cs = ddl_columns(p)
        d = cols.setdefault(t, {})
        for c, ty in cs:
            d.setdefault(c, pg_type(ty))
    for t, d in cols.items():
        con.execute(sql.SQL('CREATE TABLE sap.{} (company_code varchar(8) NOT NULL, {})').format(
            sql.Identifier(t), sql.SQL(', ').join(sql.SQL('{} {}').format(sql.Identifier(c), sql.SQL(ty)) for c, ty in d.items())))
    say('== %d raw tables created from testexp create.sql' % len(cols))
    # tables the 11/13 checks name but the exports do not contain: empty, same layout as OINV / INV1
    names = set()
    for fn in ('erp.check_deleted(varchar)', 'erp.check_sync(varchar)', 'erp.migration_cross_check(varchar, uuid)'):
        src = con.execute('select prosrc from pg_proc where oid = %s::regprocedure', [fn]).fetchone()[0]
        names |= set(re.findall(r'sap\."([A-Z0-9@_]+)"', src))
    heads = {'OQUT', 'ORDR', 'ODLN', 'ORDN', 'OINV', 'ORIN', 'ODPI', 'OPRQ', 'OPQT', 'OPOR', 'OPDN', 'ORPD', 'OPCH', 'ORPC', 'ODPO', 'OWTQ', 'OWTR', 'OIGN', 'OIGE'}
    made = []
    for t in sorted(names - set(cols)):
        like = 'OINV' if t in heads else None
        if like:
            con.execute(sql.SQL('CREATE TABLE sap.{} (LIKE sap."OINV")').format(sql.Identifier(t)))
            made.append(t)
    say('== empty stand-ins (LIKE OINV): %s; still missing: %s' % (', '.join(made), ', '.join(sorted(names - set(cols) - set(made))) or '-'))
    con.execute("INSERT INTO sap._link VALUES ('INV1', 'inv1_item', 'ItemCode', 'OITM', 'ItemCode') ON CONFLICT DO NOTHING")

    def load(co, folder):
        r = subprocess.run([PY, os.path.join(REPO, 'supabase', 'worker', 'load_company.py'), '--company', co, '--export', folder,
                            '--columns', os.path.join(folder, 'columns.csv'), '--counts', os.path.join(folder, 'row_counts.csv'), '--dsn', DSN],
                           capture_output=True, text=True)
        return r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1:] if (r.stdout + r.stderr).strip() else []

    for co in ('AE01', 'SA01'):
        rc, tail = load(co, os.path.join(HERE, 'testexp', co))
        st = dict(con.execute('select status, count(*) from sap._load_log where company_code = %s group by 1', [co]).fetchall())
        check(rc == 0 and st.get('loaded', 0) >= 24 and not st.get('failed'), 'load_company %s (testexp)' % co, st)

    # app layer: run the sync steps (in sync_company order) whose raw tables exist; erp.sync on
    proc = con.execute("select prosrc from pg_proc where oid = 'erp.sync_company(varchar)'::regprocedure").fetchone()[0]
    steps = re.findall(r'erp\.(sync_[a-z0-9_]+)\(p_company\)', proc)
    con.execute("INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema) "
                "SELECT company_code, legal_name, legal_name, country, currency, licence_type, sap_schema FROM sap._company ON CONFLICT DO NOTHING")
    # coexistence: a Super ERP partner that uses SAP's code C0001 in AE01 before the sync
    con.execute("INSERT INTO erp.business_partner (company_code, card_code, kind, name, source) VALUES ('AE01', 'C0001', 'customer', 'Created in Super ERP', 'erp')")

    def sync(co):
        ok, bad = [], []
        with con.transaction():
            con.execute("select set_config('erp.sync', 'on', true)")
            for s in steps:
                try:
                    with con.transaction():
                        con.execute(sql.SQL('select erp.{}(%s)').format(sql.Identifier(s)), [co])
                    ok.append(s)
                except psycopg.Error as e:
                    bad.append(s)
        return ok, bad
    for co in ('AE01', 'SA01'):
        ok, bad = sync(co)
        say('   %s: %d sync steps ran, %d need tables outside the test export' % (co, len(ok), len(bad)))
    check(all(s in ok for s in ('sync_special_prices', 'sync_special_price_periods', 'sync_discount_groups', 'sync_discount_group_lines')),
          'special-price steps run (0 rows: OSPP/SPP1/OEDG/EDG1 not in the export)')
    r = con.execute("select name, source from erp.business_partner where company_code = 'AE01' and card_code = 'C0001'").fetchone()
    check(r == ('Created in Super ERP', 'erp'), 'real erp.sync_business_partners does not overwrite a Super ERP partner', r)
    check(con.execute("select count(*) from erp.sync_conflict where company_code = 'AE01' and table_name = 'business_partner' and row_key = 'C0001'").fetchone()[0] == 1,
          'the skipped SAP row is logged in sync_conflict')
    check(con.execute("select count(*) from erp.business_partner where company_code = 'AE01' and source = 'sap'").fetchone()[0] >= 1,
          'other SAP partners still synced')

    # the console's cross-check + A12 checks on the good export
    run = str(uuid.uuid4())
    con.execute("insert into erp.migration_run (run_id, company_code, kind, status) values (%s, 'AE01', 'full', 'checking')", [run])
    with con.transaction():
        con.execute('select erp._cf_build(%s)', ['AE01'])
        res = con.execute('select * from erp.migration_cross_check_all(NULL, %s)', [run]).fetchone()
    say('== cross_check_all on testexp: companies %s, checks %s, failed %s, open issues %s critical / %s warning / %s info' % res)
    areas = dict(con.execute("select area, count(*) from erp.migration_check where run_id = %s group by 1", [run]).fetchall())
    check(all(a in areas for a in ('inventory_gl', 'partners', 'open_orders', 'vat', 'intercompany', 'payroll', 'duplicates', 'coexistence',
                                   'attachments', 'custom_fields', 'finance', 'stock', 'hr', 'row_counts')),
          'every check area written (13 + A12)', sorted(areas))
    for a, k, name in con.execute("select area, severity, title from erp.migration_issue where run_id = %s and status = 'open' and company_code = 'AE01' "
                                  "and area in ('inventory_gl','partners','open_orders','vat','intercompany','payroll','coexistence','attachments') order by 1, 2", [run]):
        say('     finding %-13s %-8s %s' % (a, k, name[:120]))
    check(con.execute("select count(*) from erp.migration_issue where run_id = %s and issue_key = 'coexist:AE01:business_partner' and status = 'open'", [run]).fetchone()[0] == 1,
          'cross-check reports the SAP partner not applied (coexistence warning)')
    reg = dict(con.execute("select decision, count(*) from erp.custom_field_register where company_code = 'AE01' group by 1").fetchall())
    mapped = con.execute("select target from erp.custom_field_register where company_code = 'AE01' and table_name = 'OCRD' and field_name = 'U_SFID'").fetchone()
    check(reg.get('mapped', 0) > 10 and reg.get('raw_only', 0) > 0 and mapped == ('erp.business_partner.salesforce_id',),
          'register from the sap schema: U_ fields and @ tables, mapping read from the sync code', reg)

    # attachments: ATC1 is not in the export -> add a fixture table, run the worker job (read-only source, local destination)
    tmp = tempfile.mkdtemp(prefix='a12att_')
    src_dir, out_dir = os.path.join(tmp, 'sap_attachments'), os.path.join(tmp, 'storage')
    os.makedirs(src_dir)
    body = b'%PDF-1.4 test attachment for A12 (fixture)\n' * 20
    with open(os.path.join(src_dir, 'contract.pdf'), 'wb') as fh:
        fh.write(body)
    os.chmod(os.path.join(src_dir, 'contract.pdf'), 0o444)
    os.chmod(src_dir, 0o555)
    before = os.stat(os.path.join(src_dir, 'contract.pdf'))
    con.execute('CREATE TABLE sap."ATC1" (company_code varchar(8), "AbsEntry" integer, "Line" integer, "srcPath" text, "trgtPath" text, "FileName" text, "FileExt" text)')
    con.execute("""INSERT INTO sap."ATC1" VALUES ('AE01', 1, 1, NULL, 'C:\\SAP\\Attachments', 'contract', 'pdf'), ('AE01', 1, 2, NULL, 'C:\\SAP\\Attachments', 'scan', 'jpg')""")
    doc = con.execute("""UPDATE sap."OINV" SET "AtcEntry" = 1 WHERE company_code = 'AE01' RETURNING "DocEntry" """).fetchone()[0]
    con.execute("update erp.migration_run set status = 'needs_review' where run_id = %s", [run])
    r = subprocess.run([PY, os.path.join(REPO, 'supabase', 'worker', 'migration_worker.py'), '--dsn', DSN, '--attachments-only', run,
                        '--attachments-root', src_dir, '--attachments-map', 'C:\\SAP\\Attachments=' + src_dir, '--attachments-dest', 'local:' + out_dir],
                       capture_output=True, text=True)
    say('   worker: ' + ' | '.join((r.stdout + r.stderr).strip().splitlines()[-2:]))
    rows = con.execute('select line, status, bytes, sha256, storage_path from erp.migration_attachment where run_id = %s order by line', [run]).fetchall()
    check(r.returncode == 0 and len(rows) == 2, 'attachment job ran for both ATC1 rows', rows)
    check(rows and rows[0][1] == 'copied' and rows[0][2] == len(body) and rows[0][3] == hashlib.sha256(body).hexdigest()
          and rows[0][4] == 'AE01/13/%s/contract.pdf' % doc, 'copied file: size and SHA-256 recorded, path <company>/<obj_type>/<doc_entry>/<name>', rows[:1])
    check(os.path.isfile(os.path.join(out_dir, 'AE01', '13', str(doc), 'contract.pdf')), 'file copied to the destination')
    check(len(rows) > 1 and rows[1][1] == 'missing', 'missing file recorded as missing', rows[1:])
    iss = con.execute("select severity, detail from erp.migration_issue where run_id = %s and issue_key = 'att_missing:AE01' and status = 'open'", [run]).fetchone()
    check(iss is not None and iss[0] == 'critical' and 'scan.jpg' in (iss[1] or ''), 'the attachment job reports the missing file (critical issue)', iss)
    after = os.stat(os.path.join(src_dir, 'contract.pdf'))
    check(after.st_mtime == before.st_mtime and stat.S_IMODE(after.st_mode) == 0o444 and sorted(os.listdir(src_dir)) == ['contract.pdf'],
          'SAP folder untouched (read-only folder, same mtime, nothing added)')
    step = con.execute("select status, message from erp.migration_step where run_id = %s and code = 'attachments'", [run]).fetchone()
    check(step is not None and step[0] == 'warning', 'attachments step recorded on the run', step)
    os.chmod(src_dir, 0o755)

    # opening-balances-only on AE01
    acct = con.execute("select max(\"RefDate\")::date from sap.\"JDT1\" where company_code = 'AE01'").fetchone()[0]
    con.execute("insert into erp.account (company_code, acct_code, name, postable, source) values ('AE01', '3990', 'Opening clearing (test)', true, 'sap') on conflict do nothing")
    con.execute("insert into erp.migration_setting (company_code, opening_date, opening_clearing_acct) values ('AE01', %s, '3990') on conflict (company_code) do update set opening_date = excluded.opening_date, opening_clearing_acct = excluded.opening_clearing_acct", [acct])
    orun = str(uuid.uuid4())
    con.execute("insert into erp.migration_run (run_id, company_code, kind, status) values (%s, 'AE01', 'opening_only', 'checking')", [orun])
    with con.transaction():
        o = con.execute('select erp.migration_opening_apply(%s, %s)', ['AE01', orun]).fetchone()[0]
        res = con.execute('select * from erp.migration_cross_check_all(NULL, %s)', [orun]).fetchone()
    say('   opening: %s' % json.dumps(o, default=str))
    check(float(o['debit']) == float(o['credit']) and con.execute("select count(*) from erp.journal_entry where company_code = 'AE01'").fetchone()[0] == 1,
          'opening loader: one balanced opening journal for AE01')
    tb = con.execute("select count(*) from erp.migration_check where run_id = %s and company_code = 'AE01' and area = 'finance' and check_name like 'trial balance%%'", [orun]).fetchone()[0]
    op = con.execute("select count(*) from erp.migration_check where run_id = %s and company_code = 'AE01' and area = 'opening'", [orun]).fetchone()[0]
    check(tb == 0 and op >= 6, 'opening_only run: history trial-balance checks replaced by the opening checks', (tb, op))
    say('== opening_only cross-check: companies %s, checks %s, failed %s, open issues %s critical / %s warning / %s info' % res)

    # broken export (SA01): the load and the checks must catch it
    rc, tail = load('SA01', os.path.join(HERE, 'broken', 'SA01'))
    st = con.execute("select table_name, status, rows_loaded, rows_expected, message from sap._load_log where company_code = 'SA01' "
                     "and load_id > (select max(load_id) - 200 from sap._load_log) and status <> 'loaded' order by load_id desc limit 10").fetchall()
    say('   broken SA01 load rc=%s, not loaded: %s' % (rc, st[:5]))
    brun = str(uuid.uuid4())
    con.execute("insert into erp.migration_run (run_id, company_code, kind, status) values (%s, 'SA01', 'full', 'checking')", [brun])
    with con.transaction():
        res = con.execute('select * from erp.migration_cross_check_all(%s, %s)', ['SA01', brun]).fetchone()
    say('== broken SA01 cross-check: companies %s, checks %s, failed %s, open issues %s critical / %s warning / %s info' % res)
    crit = con.execute("select title from erp.migration_issue where run_id = %s and status = 'open' and severity = 'critical' order by 1 limit 8", [brun]).fetchall()
    for (t,) in crit:
        say('     critical: ' + t[:130])
    check(rc != 0 or st or res[3] > 0, 'broken export caught (load errors or critical issues)', res)

    say()
    say('TOTAL %d passed, %d failed' % (sum(1 for l in lines if l.startswith('PASS')), fails))
    open(OUT, 'w').write('\n'.join(lines) + '\n')
    con.close()
    admin.execute('DROP DATABASE IF EXISTS %s WITH (FORCE)' % DB)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()

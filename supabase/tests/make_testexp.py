"""Build HANA-style export folders (one per company) from seed.sql, for the rebuild and migration-console tests.

    python mctest/make_testexp.py "host=localhost user=postgres password=pg" mctest/testexp

Creates a scratch database mc_seed, runs 00/01a/01b + seed.sql + a few extra rows (A/P invoice, second
warehouse), then writes for AE01 and SA01:
    <out>/<CO>/index/<SAP_SCHEMA>/<2 chars>/<TABLE>/create.sql + data.csv (no header, HANA column order)
    <out>/<CO>/columns.csv  (TABLE_NAME, POSITION, COLUMN_NAME)   <out>/<CO>/row_counts.csv (TABLE_NAME, RECORD_COUNT)
HANA column order is simulated by reversing the sap column order, so columns.csv is needed to load correctly.
"""
import csv, os, re, subprocess, sys
import psycopg
from psycopg import sql

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_SQL = os.path.join(HERE, '..', 'out')
SEED = os.path.join(HERE, '..', 'seed.sql')
base_dsn, target = sys.argv[1], sys.argv[2]

ddl = open(os.path.join(OUT_SQL, '01a_sap_standard.sql')).read() + open(os.path.join(OUT_SQL, '01b_addon_udt.sql')).read()
nn, ty = {}, {}
for name, body in re.findall(r'CREATE TABLE IF NOT EXISTS sap\."([^"]+)" \((.*?)\n\);', ddl, re.S):
    nn[name], ty[name] = [], {}
    for line in body.split('\n'):
        m = re.match(r'\s+"([^"]+)"\s+(\S+)', line)
        if not m or m.group(1) in ('company_code', '_row_id'):
            continue
        ty[name][m.group(1)] = m.group(2).rstrip(',')
        if 'NOT NULL' in line:
            nn[name].append(m.group(1))


def lit(t, v):
    if v is None:
        return 'NULL'
    if t.startswith(('varchar', 'text', 'char', 'timestamp', 'date')):
        return "'%s'" % str(v).replace("'", "''")
    return str(v)


def filler(t):
    if t.startswith(('varchar', 'char', 'text')):
        return 'N'
    if t.startswith('timestamp') or t == 'date':
        return '2026-01-01'
    return 0


extra = []


def ins(co, t, **v):
    cols = dict(v)
    for c in nn[t]:
        cols.setdefault(c, filler(ty[t][c]))
    extra.append('INSERT INTO sap."%s" (company_code,%s) VALUES (\'%s\',%s);' % (
        t, ','.join('"%s"' % c for c in cols), co, ','.join(lit(ty[t][c], x) for c, x in cols.items())))


for co in ('AE01', 'SA01'):
    ins(co, 'OACT', AcctCode='2000', AcctName='Trade payables', Postable='Y', LocManTran='Y', FormatCode='2000')
    ins(co, 'OACT', AcctCode='5000', AcctName='Cost of sales', Postable='Y', LocManTran='N', FormatCode='5000')
    ins(co, 'OWHS', WhsCode='02', WhsName='Transit', BPLid=1)
    ins(co, 'OITW', ItemCode='SF-RC18', WhsCode='02', OnHand=150 if co == 'AE01' else 40, IsCommited=0, OnOrder=0, AvgPrice=32)
    ins(co, 'OPCH', DocEntry=1, DocNum=2001, Series=1, CANCELED='N', DocStatus='O', DocDate='2026-11-03', DocDueDate='2027-01-03',
        CardCode='S0001', CardName='Foshan Kitchen Appliances', DocCur='AED', DocRate=1, DocTotal=840, VatSum=40, PaidToDate=300, BPLId=1)
    ins(co, 'PCH1', DocEntry=1, LineNum=0, ItemCode='SF-RC18', Dscription='Rice cooker 1.8 L', Quantity=25, OpenQty=0, Price=32,
        LineTotal=800, VatSum=40, WhsCode='02', AcctCode='5000', BaseType=-1, LineStatus='O')
    ins(co, 'OJDT', TransId=12, Number=12, RefDate='2026-11-03', TransType='18', BaseRef='2001', LocTotal=840, Memo='A/P invoice 2001')
    for i, (a, sn, dr, cr) in enumerate([('5000', '5000', 800, 0), ('2100', '2100', 40, 0), ('2000', 'S0001', 0, 840)]):
        ins(co, 'JDT1', TransId=12, Line_ID=i, Account=a, ShortName=sn, Debit=dr, Credit=cr, RefDate='2026-11-03')
    ins(co, 'OHEM', empID=8, firstName='Finance', lastName='Eight', U_ALTEMPID='F-08', startDate='2023-01-01', Active='Y')

# SAP account groups (OACT.GroupMask): 1 assets, 2 liabilities, 4 revenue, 5 cost of sales
extra.append("""UPDATE sap."OACT" SET "GroupMask" = CASE "AcctCode" WHEN '1100' THEN 1 WHEN '1010' THEN 1 WHEN '2000' THEN 2
               WHEN '2100' THEN 2 WHEN '4000' THEN 4 WHEN '5000' THEN 5 END;""")

HANA = {'integer': 'INTEGER', 'smallint': 'SMALLINT', 'bigint': 'BIGINT', 'text': 'NCLOB', 'bytea': 'BLOB',
        'timestamp': 'TIMESTAMP', 'date': 'DATE', 'double precision': 'DOUBLE'}


def hana_type(t):
    m = re.match(r'(?:varchar|character varying)\((\d+)\)', t)
    if m:
        return 'NVARCHAR(%s)' % m.group(1)
    m = re.match(r'numeric\((\d+),(\d+)\)', t)
    if m:
        return 'DECIMAL(%s,%s)' % m.groups()
    return HANA.get(t.split(' without')[0], 'NVARCHAR(254)')


def main():
    admin = psycopg.connect(base_dsn + ' dbname=postgres', autocommit=True)
    admin.execute('DROP DATABASE IF EXISTS mc_seed WITH (FORCE)')
    admin.execute('CREATE DATABASE mc_seed')
    env = dict(os.environ, PGPASSWORD=re.search(r'password=(\S+)', base_dsn).group(1))
    conn = re.sub(r'password=\S+', '', base_dsn) + ' dbname=mc_seed'
    for f in ('00_setup.sql', '01a_sap_standard.sql', '01b_addon_udt.sql'):
        subprocess.run(['psql', conn, '-q', '-v', 'ON_ERROR_STOP=1', '-f', os.path.join(OUT_SQL, f)], check=True, env=env, stdout=subprocess.DEVNULL)
    subprocess.run(['psql', conn, '-q', '-v', 'ON_ERROR_STOP=1', '-f', SEED], check=True, env=env, stdout=subprocess.DEVNULL)
    with psycopg.connect(base_dsn + ' dbname=mc_seed', autocommit=True) as con:
        for s in extra:
            con.execute(s)
        schemas = dict(con.execute('select company_code, sap_schema from sap._company').fetchall())
        tables = [r[0] for r in con.execute("select relname from pg_class where relnamespace='sap'::regnamespace and relkind='r' and relname not like '\\_%' order by 1")]
        coltypes = {}
        for t, c, typ in con.execute("""select c.relname, a.attname, format_type(a.atttypid, a.atttypmod) from pg_attribute a
                                         join pg_class c on c.oid=a.attrelid where c.relnamespace='sap'::regnamespace and c.relkind='r'
                                          and a.attnum>0 and not a.attisdropped order by c.relname, a.attnum"""):
            if c not in ('company_code', '_row_id'):
                coltypes.setdefault(t, []).append((c, typ))
        for co, schema in schemas.items():
            root = os.path.join(target, co)
            counts, columns = [], []
            for t in tables:
                n = con.execute(sql.SQL('select count(*) from sap.{} where company_code=%s').format(sql.Identifier(t)), [co]).fetchone()[0]
                if not n:
                    continue
                cols = list(reversed(coltypes[t]))           # "HANA order" differs from the sap definition
                folder = os.path.join(root, 'index', schema, t[:2], t)
                os.makedirs(folder, exist_ok=True)
                body = ', '.join('"%s" %s%s' % (c, hana_type(typ), '') for c, typ in cols)
                open(os.path.join(folder, 'create.sql'), 'w').write(
                    'CREATE COLUMN TABLE "%s"."%s" (%s) UNLOAD PRIORITY 5 AUTO MERGE' % (schema, t, body))
                sel = sql.SQL(', ').join(sql.SQL("encode({}, 'hex')").format(sql.Identifier(c)) if typ == 'bytea' else sql.Identifier(c) for c, typ in cols)
                with open(os.path.join(folder, 'data.csv'), 'wb') as fh, con.cursor() as cur:
                    with cur.copy(sql.SQL('copy (select {} from sap.{} where company_code = {}) to stdout (format csv)').format(
                            sel, sql.Identifier(t), sql.Literal(co))) as cp:
                        for chunk in cp:
                            fh.write(chunk)
                counts.append((t, n))
                columns += [(t, i + 1, c) for i, (c, _) in enumerate(cols)]
            with open(os.path.join(root, 'row_counts.csv'), 'w', newline='') as fh:
                w = csv.writer(fh); w.writerow(['TABLE_NAME', 'RECORD_COUNT']); w.writerows(counts)
            with open(os.path.join(root, 'columns.csv'), 'w', newline='') as fh:
                w = csv.writer(fh); w.writerow(['TABLE_NAME', 'POSITION', 'COLUMN_NAME']); w.writerows(columns)
            print(co, len(counts), 'tables', sum(n for _, n in counts), 'rows')
    admin.execute('DROP DATABASE IF EXISTS mc_seed WITH (FORCE)')


if __name__ == '__main__':
    main()

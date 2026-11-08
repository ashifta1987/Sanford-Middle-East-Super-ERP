"""--source storage against a local mock of the Supabase Storage REST API (list + download), with the SA01 export
uploaded as one zip plus a loose row_counts.csv in a sub-folder. Not a test of real Supabase.
    python3 mctest/storage_mock_test.py "host=localhost user=postgres password=pg dbname=mc_rebuild"
"""
import http.server, io, json, os, subprocess, sys, threading, zipfile
import psycopg

B = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DSN = sys.argv[1]
src = os.path.join(B, 'mctest', 'testexp', 'SA01')
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as z:
    for d, _, fs in os.walk(os.path.join(src, 'index')):
        for f in fs:
            z.write(os.path.join(d, f), os.path.relpath(os.path.join(d, f), src))
    z.write(os.path.join(src, 'columns.csv'), 'columns.csv')
con = psycopg.connect(DSN, autocommit=True)
rid = con.execute("insert into erp.migration_run (company_code, kind, status, notes) values ('SA01', 'full', 'queued', 'storage mock') returning run_id").fetchone()[0]
prefix = 'SA01/%s' % rid
con.execute('update erp.migration_run set storage_prefix = %s where run_id = %s', [prefix + '/', rid])
objects = {prefix + '/export.zip': buf.getvalue(), prefix + '/meta/row_counts.csv': open(os.path.join(src, 'row_counts.csv'), 'rb').read()}
seen = []


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        assert self.headers['Authorization'] == 'Bearer test-key' and self.headers['apikey'] == 'test-key'
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        p = body['prefix'].strip('/') + '/'
        seen.append('list ' + p)
        names = {}
        for k in objects:
            if k.startswith(p):
                rest = k[len(p):]
                names[rest.split('/')[0]] = None if '/' in rest else 1
        out = [{'name': n, 'id': (None if v is None else 'x')} for n, v in sorted(names.items())][body['offset']:body['offset'] + body['limit']]
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', len(data)); self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        key = self.path.split('/storage/v1/object/sap-exports/', 1)[1]
        from urllib.parse import unquote
        data = objects[unquote(key)]
        seen.append('get ' + unquote(key))
        self.send_response(200); self.send_header('Content-Length', len(data)); self.end_headers()
        self.wfile.write(data)


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
env = dict(os.environ, SUPABASE_URL='http://127.0.0.1:%d' % srv.server_port, SUPABASE_SERVICE_ROLE_KEY='test-key', NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
p = subprocess.run([sys.executable, os.path.join(B, 'out', 'migration_worker.py'), '--dsn', DSN, '--source', 'storage',
                    '--workdir', os.path.join(B, 'mctest')], env=env, capture_output=True, text=True)
print(p.stdout[-2500:], p.stderr[-1500:])
print('requests:', seen)
st = con.execute("select status, (select count(*) from erp.migration_file where run_id=%s and kind='data_csv'), "
                 "(select count(*) from erp.migration_issue where run_id=%s and status='open' and issue_key not like 'report_missing:%%') from erp.migration_run where run_id=%s", [rid, rid, rid]).fetchone()
good = st[0] == 'needs_review' and st[1] == 24 and st[2] == 0
print('PASS' if good else 'FAIL', 'storage mock: status %s, %d data files, %d open issues' % st)
sys.exit(0 if good else 1)

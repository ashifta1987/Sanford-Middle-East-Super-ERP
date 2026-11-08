// P1 access checks against the live database. Every test row is rolled back. Usage: node scripts/test-access.mjs
import postgres from 'postgres';
import { readFileSync } from 'node:fs';
const url = readFileSync(new URL('../.env.db', import.meta.url),'utf8').match(/^DATABASE_URL=(.*)$/m)[1].trim();
const sql = postgres(url, { ssl: 'require', max: 1, onnotice: () => {} });
const res = (n, ok, d = '') => console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${d ? ' · ' + d : ''}`);
const asUser = async (uid, fn) => sql.begin(async (tx) => {
  await tx.unsafe(`select set_config('request.jwt.claims', '{"sub":"${uid}","role":"authenticated"}', true)`);
  await tx.unsafe('set local role authenticated');
  const r = await fn(tx); throw { rollback: true, r };
}).catch((e) => { if (e.rollback) return e.r; throw e; });
const A = '00000000-0000-4000-8000-0000000000a1', N = '00000000-0000-4000-8000-0000000000b2', F = '00000000-0000-4000-8000-0000000000c3', C = '00000000-0000-4000-8000-0000000000d4';
try {
  await sql.begin(async (tx) => {
    // throwaway test users (rolled back at the end)
    await tx`insert into erp.position values ('T_SALES','test sales','{sales_rep}',null) on conflict do nothing`;
    for (const [u, p] of [[A, 'IT_ADMIN'], [N, 'T_SALES'], [F, 'CHIEF_ACC'], [C, 'GROUP_CFO']]) {
      await tx`insert into erp.app_user (user_id, company_code, display_name, position_code) values (${u}, 'AE01', ${'test ' + p}, ${p})`;
      await tx`insert into erp.user_company select ${u}, company_code from erp.company`;
    }
    const as = async (uid, q) => { await tx.unsafe(`select set_config('request.jwt.claims', '{"sub":"${uid}","role":"authenticated"}', true)`); await tx.unsafe('set local role authenticated'); try { return await tx.unsafe(`savepoint s; ${q}`); } finally { await tx.unsafe('rollback to savepoint s; reset role'); } };
    const tryq = async (uid, q) => { try { const r = await as(uid, q); return { ok: true, r }; } catch (e) { await tx.unsafe('rollback to savepoint s; reset role').catch(()=>{}); return { ok: false, code: e.code, msg: e.message }; } };

    let r = await tryq(A, 'select count(*)::int n from erp.migration_company_overview'); res('admin sees overview rows', r.ok && r.r.at(-1)?.[0]?.n === 4 || r.ok && JSON.stringify(r.r).includes('"n":4'), JSON.stringify(r.r?.at?.(-1) ?? r.msg));
    r = await tryq(N, 'select count(*)::int n from erp.migration_company_overview'); res('non-admin sees 0 rows', r.ok && JSON.stringify(r.r).includes('"n":0'), JSON.stringify(r.r?.at?.(-1) ?? r.msg));
    await tx.unsafe('savepoint s; set local role anon');
    try { await tx.unsafe('select * from erp.migration_company_overview'); res('anonymous denied', false); } catch (e) { res('anonymous denied', e.code === '42501', e.message); }
    await tx.unsafe('rollback to savepoint s; reset role');
    r = await tryq(N, `insert into storage.objects (bucket_id, name, owner) values ('sap-exports', 'AE01/x/test.csv', '${N}')`); res('non-admin upload refused', !r.ok, r.msg ?? 'inserted!');
    r = await tryq(A, `insert into storage.objects (bucket_id, name, owner) values ('sap-exports', 'AE01/x/test.csv', '${A}')`); res('admin upload allowed (policy)', r.ok, r.msg ?? '');
    // a run, not signed off
    const [{ run }] = await tx`insert into erp.migration_run (company_code, kind, status) values ('AE01', 'full', 'needs_review') returning run_id as run`;
    r = await tryq(C, `select erp.company_go_live('AE01', '${run}')`); res('go-live refused before signed_off', !r.ok, r.msg);
    await tx`update erp.migration_run set status = 'signed_off' where run_id = ${run}`;
    r = await tryq(F, `select erp.company_go_live('AE01', '${run}')`); res('go-live refused for non-CFO', !r.ok, r.msg);
    r = await tryq(C, `select erp.company_go_live('AE01', '${run}')`); res('CFO go-live on signed_off run', r.ok, r.msg ?? '');
    r = await tryq(C, `select erp.company_go_live('AE01', '${run}'); select erp.company_go_live('AE01', '${run}')`); res('second go-live refused', !r.ok && /already live/.test(r.msg), r.msg);
    const pub = await tx`select tablename from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'erp' order by 1`;
    res('realtime publication', pub.length === 4, pub.map((p) => p.tablename).join(', '));
    throw { rollback: true };
  });
} catch (e) { if (!e.rollback) console.error('ERROR', e.message); }
await sql.end();

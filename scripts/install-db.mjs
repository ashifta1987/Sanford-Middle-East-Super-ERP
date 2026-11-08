#!/usr/bin/env node
// Sanford ERP · one-command database install for Supabase.
//
// 1. Create a file `.env.db` in the repo root (it is git-ignored) with:
//      DATABASE_URL=postgresql://postgres:<password>@db.xhsfkbbcejgwvqxpqdgq.supabase.co:5432/postgres
//      SUPABASE_URL=https://xhsfkbbcejgwvqxpqdgq.supabase.co
//      SUPABASE_SECRET_KEY=sb_secret_...            (only needed for --admin)
// 2. node scripts/install-db.mjs                     install 00 → 13 + 14 (skips what is already installed)
//    node scripts/install-db.mjs --admin you@x.com   also create the first admin login (prints a temporary password)
//
// SQL comes from the sanford-db-install package (unzipped into _inbox/sanford-erp-backend, never committed)
// and this repo's supabase/sql/14_*.sql. Run order = supabase/tests/rebuild.sh (README run order).

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import postgres from 'postgres';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const env = Object.fromEntries(
  (existsSync(join(root, '.env.db')) ? readFileSync(join(root, '.env.db'), 'utf8') : '')
    .split(/\r?\n/).filter((l) => /^\s*[A-Z_]+=/.test(l)).map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, '')]; }),
);
const DATABASE_URL = process.env.DATABASE_URL ?? env.DATABASE_URL;
const SUPABASE_URL = process.env.SUPABASE_URL ?? env.SUPABASE_URL ?? 'https://xhsfkbbcejgwvqxpqdgq.supabase.co';
const SECRET = process.env.SUPABASE_SECRET_KEY ?? env.SUPABASE_SECRET_KEY;
if (!DATABASE_URL) { console.error('DATABASE_URL missing: put it in .env.db (see the top of this file).'); process.exit(1); }
if (/pooler\.supabase\.com:6543/.test(DATABASE_URL)) { console.error('Use the DIRECT connection (port 5432), not the transaction pooler.'); process.exit(1); }

const DBI = join(root, '_inbox', 'sanford-erp-backend');
const SQL14 = join(root, 'supabase', 'sql');
const args = process.argv.slice(2);
const adminEmail = args.includes('--admin') ? args[args.indexOf('--admin') + 1] : null;

// Phase 1: the four UAE companies (AE01 parent + AE02-AE04). The others (SA01, QA01, QA02, KW01, BH01, OM01, IN01, IN02)
// are added later: append them here and re-run - existing rows are left as they are.
const COMPANIES = [
  ['AE01', 'SBO_SANFORD', 'Sanford Middle East DWC L.L.C', 'AE', 'AED', 'free_zone'],
  ['AE02', 'SBO_ATMM', 'A.T.M.M. Electronics', 'AE', 'AED', 'mainland'],
  ['AE03', 'SBO_ABDMOH', 'Abdulla Mohamed Home Appliances', 'AE', 'AED', 'mainland'],
  ['AE04', 'SBO_IZAAN', 'Izaan General Trading', 'AE', 'AED', 'mainland'],
];

const sql = postgres(DATABASE_URL, { ssl: 'require', max: 1, onnotice: () => {}, connect_timeout: 30, idle_timeout: 0 });
const t0 = Date.now();
const log = (s) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0).padStart(4)}s] ${s}`);

// Split a SQL script into statements (respects quotes, "identifiers", line and block comments, $tag$ bodies).
function splitSql(text) {
  const out = [];
  let start = 0, i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i], d = text[i + 1];
    if (c === '-' && d === '-') { const e = text.indexOf('\n', i); i = e < 0 ? n : e + 1; continue; }
    if (c === '/' && d === '*') { const e = text.indexOf('*/', i + 2); i = e < 0 ? n : e + 2; continue; }
    if (c === "'" || c === '"') { i++; while (i < n) { if (text[i] === c) { if (text[i + 1] === c) { i += 2; continue; } break; } i++; } i++; continue; }
    if (c === '$') {
      const m = /^\$[A-Za-z_]*\$/.exec(text.slice(i, i + 64));
      if (m) { const e = text.indexOf(m[0], i + m[0].length); i = e < 0 ? n : e + m[0].length; continue; }
    }
    if (c === ';') { const st = text.slice(start, i + 1).trim(); if (st.replace(/;$/, '').trim()) out.push(st); start = i + 1; }
    i++;
  }
  const tail = text.slice(start).trim();
  if (tail && !/^(--[^\n]*\n?\s*)*$/.test(tail)) out.push(tail);
  return out;
}

// Large files run in batches (each its own transaction) so creating 3,000+ tables never needs more locks than the
// database allows. Every finished batch is recorded in public._sanford_install, so a re-run continues where it stopped.
const BATCH = 40;
async function runFile(label, path, { always = false } = {}) {
  const step = label.split(' ')[0];
  if (!always && (await sql`select 1 from public._sanford_install where step = ${step}`).length) { log(`skip  ${label} (already installed)`); return; }
  if (!existsSync(path)) throw new Error(`${path} not found - unzip sanford-db-install.zip into _inbox/`);
  const t = Date.now();
  const stmts = splitSql(readFileSync(path, 'utf8'));
  const batches = Math.ceil(stmts.length / BATCH);
  log(`run   ${label} · ${stmts.length} statements …`);
  for (let b = 0; b < batches; b++) {
    const key = `${step}#${b}`;
    if (!always && (await sql`select 1 from public._sanford_install where step = ${key}`).length) continue;
    const chunk = stmts.slice(b * BATCH, (b + 1) * BATCH).join('\n');
    try {
      await sql.unsafe(chunk);
    } catch (e) {
      throw new Error(`${label}, batch ${b + 1}/${batches}: ${e.message}\n  near: ${chunk.slice(0, 200).replace(/\s+/g, ' ')}`);
    }
    if (!always) await sql`insert into public._sanford_install (step) values (${key}) on conflict do nothing`;
    if (batches > 10 && (b + 1) % Math.ceil(batches / 10) === 0) log(`      ${label} ${b + 1}/${batches}`);
  }
  await sql`insert into public._sanford_install (step) values (${step}) on conflict (step) do update set at = now()`;
  log(`ok    ${label} (${((Date.now() - t) / 1000).toFixed(1)} s)`);
}

try {
  const [{ v }] = await sql`select version() as v`;
  log(`connected · ${v.split(',')[0]}`);
  const [{ locks }] = await sql`select current_setting('max_locks_per_transaction')::int as locks`;
  await sql`create table if not exists public._sanford_install (step text primary key, at timestamptz not null default now())`;
  await sql`alter table public._sanford_install enable row level security`;
  log(`max_locks_per_transaction = ${locks}${locks < 2048 ? '  (raise to 2048 before the first real load, see docs/setup.md)' : ''}`);

  await runFile('00_setup', join(DBI, '00_setup.sql'));
  await runFile('01a_sap_standard (3,000+ tables)', join(DBI, '01a_sap_standard.sql'));
  await runFile('01b_addon_udt', join(DBI, '01b_addon_udt.sql'));
  for (const c of COMPANIES) {
    await sql`insert into sap._company (company_code, sap_schema, legal_name, country, currency, licence_type) values (${c[0]}, ${c[1]}, ${c[2]}, ${c[3]}, ${c[4]}, ${c[5]}) on conflict do nothing`;
  }
  log(`ok    company register (${COMPANIES.length} companies)`);
  await runFile('02_clean_blank_keys', join(DBI, '02_clean_blank_keys.sql'));
  await runFile('03_orphan_check', join(DBI, '03_orphan_check.sql'));
  await runFile('04_foreign_keys (3,656 links)', join(DBI, '04_foreign_keys.sql'));
  await runFile('06_security', join(DBI, '06_security.sql'));
  await runFile('10_erp_schema', join(DBI, '10_erp_schema.sql'));
  await runFile('11_erp_sync', join(DBI, '11_erp_sync.sql'));
  await runFile('12_erp_security', join(DBI, '12_erp_security.sql'));
  await runFile('13_migration_console', join(DBI, '13_migration_console.sql'), { always: true });
  await runFile('14_realtime', join(SQL14, '14_realtime.sql'), { always: true });
  await runFile('14_console_views', join(SQL14, '14_console_views.sql'), { always: true });

  // erp.company rows (what erp.sync_company writes first) so users can be given companies before the first load
  await sql`insert into erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema, is_parent)
            select company_code, legal_name, legal_name, country, currency, licence_type, sap_schema, company_code = 'AE01' from sap._company
            on conflict (company_code) do nothing`;
  await sql`insert into erp.position (position_code, name, module_access) values
            ('IT_ADMIN', 'IT migration lead', '{admin,it}'),
            ('CHIEF_ACC', 'Chief Accountant', '{finance}'),
            ('GROUP_CFO', 'Group CFO', '{business}')
            on conflict (position_code) do nothing`;
  log('ok    positions IT_ADMIN, CHIEF_ACC, GROUP_CFO');

  if (adminEmail) {
    if (!SECRET) throw new Error('SUPABASE_SECRET_KEY missing in .env.db (needed to create the login)');
    const password = randomBytes(12).toString('base64url');
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: 'POST',
      headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: adminEmail, password, email_confirm: true }),
    });
    const body = await res.json();
    let uid = body.id;
    if (!res.ok) {
      if (!/already/i.test(JSON.stringify(body))) throw new Error(`create user: ${JSON.stringify(body)}`);
      const [u] = await sql`select id from auth.users where email = ${adminEmail}`;
      uid = u.id;
      log(`login ${adminEmail} already exists - giving it admin access`);
    } else {
      log(`login ${adminEmail} created · temporary password: ${password}`);
    }
    await sql`insert into erp.app_user (user_id, company_code, display_name, email, position_code)
              values (${uid}, 'AE01', ${adminEmail.split('@')[0]}, ${adminEmail}, 'IT_ADMIN')
              on conflict (user_id) do update set position_code = 'IT_ADMIN', active = true`;
    await sql`insert into erp.user_company (user_id, company_code) select ${uid}, company_code from erp.company on conflict do nothing`;
    log('ok    admin access to every company');
  }

  const [s] = await sql`select (select count(*) from pg_tables where schemaname = 'sap') as sap_tables,
                               (select count(*) from pg_tables where schemaname = 'erp') as erp_tables,
                               (select count(*) from pg_constraint where contype = 'f' and connamespace = 'sap'::regnamespace) as links`;
  log(`done  · sap tables ${s.sap_tables} · erp tables ${s.erp_tables} · links ${s.links}`);
  console.log('\nNext: Supabase › Settings › API › Exposed schemas: add "erp" (keep "sap" out). Then sign in at https://sanford-super-erp.vercel.app');
} catch (e) {
  console.error(`\nFAILED: ${e.message}${e.position ? ` (at character ${e.position})` : ''}`);
  process.exitCode = 1;
} finally {
  await sql.end({ timeout: 5 });
}

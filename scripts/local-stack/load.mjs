// LOCAL / CI ONLY. Applies repo SQL files to a local Postgres and prints the rows they return (test suites print
// PASS/FAIL rows). Refuses any host that is not this machine, so it can never touch Supabase.
//
//   node scripts/local-stack/load.mjs <repo-relative files...>
//   FRESH=1 node scripts/local-stack/load.mjs @scripts/local-stack/sql-order.txt
//
// Env: PGHOST (127.0.0.1) PGPORT (5433) PGUSER (postgres) PGPASSWORD PGDATABASE (erp_local).
// FRESH=1 drops and recreates the database with stand-ins for what Supabase provides (auth, storage, sap._company,
// sap._load_log, the supabase_realtime publication and the anon / authenticated / service_role roles).
import postgres from 'postgres';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const host = process.env.PGHOST || '127.0.0.1';
if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
  console.error(`Refusing to run against ${host}: this loader is for the local stack and CI only.`);
  process.exit(2);
}
const db = process.env.PGDATABASE || 'erp_local';
if (!/^[a-z_][a-z0-9_]*$/.test(db)) { console.error('PGDATABASE must be a plain name.'); process.exit(2); }
const conn = { host, port: Number(process.env.PGPORT || 5433), user: process.env.PGUSER || 'postgres', password: process.env.PGPASSWORD, onnotice: () => {} };
// "@list.txt" expands to the files listed in it (one per line, # comments allowed).
const files = process.argv.slice(2).flatMap((a) => a.startsWith('@')
  ? fs.readFileSync(path.join(REPO, a.slice(1)), 'utf8').split(/\r?\n/).map((l) => l.replace(/#.*/, '').trim()).filter(Boolean)
  : [a]);

if (process.env.FRESH) {
  const admin = postgres({ ...conn, database: 'postgres', max: 1 });
  await admin.unsafe(`DROP DATABASE IF EXISTS ${db} WITH (FORCE)`);
  await admin.unsafe(`CREATE DATABASE ${db}`);
  await admin.unsafe(`DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator LOGIN PASSWORD 'local' NOINHERIT; END IF;
  END $$; GRANT anon, authenticated, service_role TO authenticator;`);
  await admin.end();
}

const sql = postgres({ ...conn, database: db, max: 1 });
if (process.env.FRESH) {
  await sql.unsafe(`
    CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text);
    CREATE SCHEMA IF NOT EXISTS storage; CREATE SCHEMA IF NOT EXISTS sap;
    CREATE TABLE IF NOT EXISTS sap._company (company_code varchar(8) PRIMARY KEY, legal_name text, country text, currency text, licence_type text, sap_schema text, in_scope boolean DEFAULT true);
    CREATE TABLE IF NOT EXISTS sap._load_log (load_id bigserial PRIMARY KEY, run_id uuid, company_code varchar(8), table_name text, status text, rows_expected bigint, rows_loaded bigint, loaded_at timestamptz DEFAULT now());
    CREATE TABLE IF NOT EXISTS storage.buckets (id text PRIMARY KEY, name text, public boolean DEFAULT false, file_size_limit bigint, allowed_mime_types text[]);
    CREATE TABLE IF NOT EXISTS storage.objects (id uuid DEFAULT gen_random_uuid() PRIMARY KEY, bucket_id text, name text, owner uuid, metadata jsonb);
    ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
    CREATE OR REPLACE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT string_to_array(name, '/') $$;
    DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') THEN CREATE PUBLICATION supabase_realtime; END IF; END $$;`);
}

let failed = 0;
for (const f of files) {
  const text = fs.readFileSync(path.isAbsolute(f) ? f : path.join(REPO, f), 'utf8');
  const t = Date.now();
  try {
    await sql.unsafe('SET check_function_bodies = off');
    const res = await sql.unsafe(text);
    console.log(`OK    ${f} (${Date.now() - t} ms)`);
    const sets = Array.isArray(res[0]) || res.length === 0 ? res : [res];
    for (const rows of sets) for (const row of rows ?? []) if (row && Object.keys(row).length) console.log('      ', Object.values(row).join(' | '));
  } catch (e) {
    failed++;
    console.log(`FAIL  ${f}: ${e.message} ${e.where ?? ''}`);
  }
}
await sql.end();
process.exit(failed ? 1 : 0);

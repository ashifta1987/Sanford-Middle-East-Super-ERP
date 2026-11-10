// Build guard (runs before every `npm run build`, so on Vercel and in CI too).
// The browser bundle may only carry the Supabase URL and the anon (publishable) key. This fails the build when:
//   - any VITE_* variable name looks like a server secret (SERVICE_ROLE, SECRET, PASSWORD, DATABASE_URL, PRIVATE)
//   - VITE_SUPABASE_ANON_KEY is a service-role JWT or a Supabase secret key (sb_secret_…)
//   - VITE_SUPABASE_URL is not https (localhost is allowed for the local stack)
// It checks the process environment and the .env files Vite would load. Values are never printed.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mode = process.env.MODE || (process.env.NODE_ENV === 'development' ? 'development' : 'production');
const files = ['.env', '.env.local', `.env.${mode}`, `.env.${mode}.local`];

const vars = new Map(); // name -> { value, from }
for (const f of files) {
  const p = path.join(root, f);
  if (!fs.existsSync(p)) continue;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m && m[1].startsWith('VITE_')) vars.set(m[1], { value: m[2].replace(/^['"]|['"]$/g, ''), from: f });
  }
}
for (const [k, v] of Object.entries(process.env)) if (k.startsWith('VITE_')) vars.set(k, { value: v ?? '', from: 'environment' });

const problems = [];
const SECRET_NAME = /SERVICE_?ROLE|SECRET|PASSWORD|DATABASE_URL|PRIVATE|ACCESS_TOKEN/i;
for (const [k, { from }] of vars) {
  if (SECRET_NAME.test(k)) problems.push(`${k} (${from}) looks like a server secret. Browser variables (VITE_*) are public; remove it.`);
}

const jwtRole = (token) => {
  const part = token.split('.')[1];
  if (!part) return null;
  try { return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')).role ?? null; } catch { return null; }
};
const key = vars.get('VITE_SUPABASE_ANON_KEY');
if (key) {
  if (/^sb_secret_/.test(key.value)) problems.push(`VITE_SUPABASE_ANON_KEY (${key.from}) is a Supabase secret key. Use the publishable (anon) key.`);
  else if (jwtRole(key.value) === 'service_role') problems.push(`VITE_SUPABASE_ANON_KEY (${key.from}) is a service_role key. Use the anon key.`);
}
const url = vars.get('VITE_SUPABASE_URL');
if (url && url.value && !/^https:\/\//.test(url.value) && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?/.test(url.value)) {
  problems.push(`VITE_SUPABASE_URL (${url.from}) must be an https:// address.`);
}
const unexpected = [...vars.keys()].filter((k) => !['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'].includes(k) && !SECRET_NAME.test(k));
if (unexpected.length) console.warn(`check-env: note, extra browser variables (public in the bundle): ${unexpected.join(', ')}`);

if (problems.length) {
  console.error('check-env: build stopped.\n  - ' + problems.join('\n  - '));
  process.exit(1);
}
console.log(`check-env: ok (${vars.has('VITE_SUPABASE_URL') ? 'URL set' : 'URL not set'}, ${key ? 'anon key set' : 'anon key not set'})`);

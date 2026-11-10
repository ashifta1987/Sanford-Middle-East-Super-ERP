// After `vite build`: fail if the bundle carries a Supabase secret key or a service_role JWT.
// (supabase-js itself contains the text "sb_secret_" as a prefix check, so we look for real key shapes.)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../dist/assets');
const bad = [];
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
  const text = fs.readFileSync(path.join(dir, f), 'utf8');
  if (/sb_secret_[A-Za-z0-9_-]{20,}/.test(text)) bad.push(`${f}: Supabase secret key`);
  for (const jwt of text.match(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/g) ?? []) {
    try {
      const role = JSON.parse(Buffer.from(jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')).role;
      if (role === 'service_role') bad.push(`${f}: service_role JWT`);
    } catch { /* not a JWT */ }
  }
}
if (bad.length) { console.error('check-bundle: secret found in the browser bundle:\n  - ' + bad.join('\n  - ')); process.exit(1); }
console.log('check-bundle: ok (no secret key or service_role token in dist/assets)');

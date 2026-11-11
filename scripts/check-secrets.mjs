// Fail when a diff carries anything key-like (run before every commit; the local pre-commit hook calls it).
//   node scripts/check-secrets.mjs            → scans the staged diff (git diff --cached)
//   node scripts/check-secrets.mjs <ref>      → scans git diff <ref> (e.g. main) — added lines only
// Patterns: Google API keys (Gemini), Anthropic / OpenAI keys, Supabase secret keys, service_role JWTs, private keys, and
// "KEY=value" assignments of the provider secrets with a real-looking value. Placeholders such as "…", "<key>", "$VAR",
// "local-mock" are fine. Never prints the matched value: only the file, line number and the kind of match.
import { execFileSync } from 'node:child_process';

const ref = process.argv[2];
const diff = execFileSync('git', ref ? ['diff', '--unified=0', ref] : ['diff', '--cached', '--unified=0'], { encoding: 'utf8', maxBuffer: 256 << 20 });
const RULES = [
  ['Google API key', /AIza[0-9A-Za-z_-]{30,}/],
  ['Anthropic key', /sk-ant-[A-Za-z0-9_-]{20,}/],
  ['OpenAI-style key', /\bsk-(?:proj-)?[A-Za-z0-9]{32,}/],
  ['Supabase secret key', /sb_secret_[A-Za-z0-9_-]{20,}/],
  ['private key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['provider secret with a value', /\b(GEMINI_API_KEY|GOOGLE_API_KEY|ANTHROPIC_API_KEY|SUPABASE_SERVICE_ROLE_KEY)\s*[:=]\s*["']?(?!local-mock|mock|test|x\b|…|\.\.\.|<|\$|\{|"|'|\)|$)[A-Za-z0-9_\-]{16,}/],
];
const hits = [];
let file = '', line = 0;
for (const l of diff.split('\n')) {
  if (l.startsWith('+++ ')) { file = l.slice(6); continue; }
  const m = l.match(/^@@ -\d+(?:,\d+)? \+(\d+)/);
  if (m) { line = Number(m[1]); continue; }
  if (l.startsWith('+') && !l.startsWith('+++')) {
    for (const [kind, re] of RULES) if (re.test(l)) hits.push(`${file}:${line}  ${kind}`);
    // service_role JWT
    for (const jwt of l.match(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/g) ?? []) {
      try { if (JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).role === 'service_role') hits.push(`${file}:${line}  service_role JWT`); } catch { /* not a JWT */ }
    }
    line++;
  }
}
if (hits.length) { console.error(`check-secrets: key-like text in the diff — remove it before committing:\n  ${hits.join('\n  ')}`); process.exit(1); }
console.log(`check-secrets: ok (no key-like text in ${ref ? `git diff ${ref}` : 'the staged diff'})`);


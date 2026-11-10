// LOCAL / CI ONLY. Fresh rebuild (scripts/local-stack/sql-order.txt) and every phase SQL suite (supabase/tests/a<N>_*.sql),
// then one summary line per suite. Exit code 1 when any check fails or any file fails to load.
//   node scripts/local-stack/run-sql-tests.mjs            (FRESH rebuild first; set NO_REBUILD=1 to skip it)
// Same env as load.mjs (PGHOST must be local).
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const load = (args, env = {}) => spawnSync(process.execPath, [path.join(HERE, 'load.mjs'), ...args], { cwd: REPO, env: { ...process.env, ...env }, encoding: 'utf8', maxBuffer: 64 << 20 });

if (!process.env.NO_REBUILD) {
  const r = load(['@scripts/local-stack/sql-order.txt'], { FRESH: '1' });
  const bad = r.stdout.split('\n').filter((l) => l.startsWith('FAIL'));
  console.log(`rebuild: ${r.stdout.split('\n').filter((l) => l.startsWith('OK')).length} files OK, ${bad.length} failed`);
  bad.forEach((l) => console.log('  ' + l));
  if (r.status !== 0) process.exit(1);
}

// a1_explain.sql is a 1M-row performance probe, not a pass/fail suite.
const suites = fs.readdirSync(path.join(REPO, 'supabase/tests'))
  .filter((f) => /^a\d+_.*\.sql$/.test(f) && f !== 'a1_explain.sql')
  .sort((a, b) => Number(a.match(/^a(\d+)/)[1]) - Number(b.match(/^a(\d+)/)[1]));

let pass = 0, fail = 0, broken = 0;
for (const f of suites) {
  const r = load([`supabase/tests/${f}`]);
  const lines = r.stdout.split('\n').map((l) => l.trim());
  const p = lines.filter((l) => l.startsWith('PASS |')).length;
  const x = lines.filter((l) => l.startsWith('FAIL |'));
  if (r.status !== 0) broken++;
  pass += p; fail += x.length;
  console.log(`${x.length || r.status ? 'FAIL' : 'PASS'}  ${f.padEnd(32)} ${p} passed, ${x.length} failed${r.status ? ' (did not load: ' + (lines.find((l) => l.startsWith('FAIL '))) + ')' : ''}`);
  x.forEach((l) => console.log('        ' + l.slice(0, 300)));
}
console.log(`TOTAL ${suites.length} suites: ${pass} passed, ${fail} failed${broken ? `, ${broken} did not load` : ''}`);
process.exit(fail || broken ? 1 : 0);

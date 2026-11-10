// A12 browser test: SAP migration completion — against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a12-e2e.mjs [outDir]
// Fixture (sample company only, stays on the running DB): ZZ99 in sap._company (in_scope false), one migration run in review
// with A12's checks (erp.migration_more_checks: duplicates, skipped raw checks, register, coexistence), sample register lines,
// sample special prices. Then: cross-check shows the new areas + Reconciliation card → CSV and PDF run report (audited) →
// custom-field register: filter, map (bad target refused, good one saved), propose drop → owner approves, admin cannot →
// sales user refused → Upload: opening-balances load type + settings (bad account refused, saved) → run page lists the
// attachments step → special prices / discounts lists live from the module page → screenshots 1440 / 390, light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a12-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  owner: ['qa.owner@sample.test', 'local-only-5'],
};
async function login(page, who) {
  const [email, password] = USERS[who];
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, acceptDownloads: true, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  return ctx;
}
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

// ---------- fixtures ----------
const RUN = 'a12e2e00-0000-4000-8000-000000000001';
await db.query(`INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema, in_scope)
  VALUES ('ZZ99', 'Sample Trading LLC (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ99_SAMPLE', false) ON CONFLICT (company_code) DO NOTHING`);
await db.query(`DELETE FROM erp.migration_run WHERE run_id = $1`, [RUN]);
await db.query(`DELETE FROM erp.migration_setting WHERE company_code = 'ZZ99'`);
await db.query(`INSERT INTO erp.migration_run (run_id, company_code, kind, status, started_at, finished_at, notes)
  VALUES ($1, 'ZZ99', 'full', 'needs_review', now() - interval '20 minutes', now() - interval '5 minutes', 'A12 e2e fixture (sample company)')`, [RUN]);
const steps = ['validate', 'stage', 'cast', 'clean_02', 'orphans_03', 'links_04', 'real_keys', 'security_06', 'app_sync', 'check_sync', 'check_deleted', 'cross_check', 'attachments'];
for (const [i, c] of steps.entries()) {
  await db.query(`INSERT INTO erp.migration_step (run_id, step_no, code, status, rows, started_at, finished_at, message)
    VALUES ($1, $2::smallint, $3, $4, $5, now() - interval '20 minutes' + make_interval(mins => $2::int), now() - interval '19 minutes' + make_interval(mins => $2::int), $6)`,
  [RUN, i + 1, c, c === 'attachments' ? 'skipped' : 'ok', c === 'attachments' ? null : 10 * (i + 1),
   c === 'attachments' ? 'no SAP attachments folder given (--attachments-root); check 5.10 waits for it' : 'sample fixture']);
}
await db.query(`DELETE FROM erp.custom_field_register WHERE company_code = 'ZZ99'`);
await db.query(`INSERT INTO erp.custom_field_register (company_code, table_name, field_name, kind, description, field_type, decision, target, suggested, rows_used, total_rows, last_used, in_raw, dict_source)
  VALUES ('ZZ99', 'OCRD', 'U_SFID', 'field', 'Salesforce ID (sample line)', 'A(20)', 'mapped', 'erp.business_partner.salesforce_id', 'mapped', 14, 28, current_date - 3, true, 'local e2e fixture'),
         ('ZZ99', 'OCRD', 'U_OLDFLAG', 'field', 'Old flag (sample line)', 'A(1)', 'raw_only', NULL, 'raw_only', 0, 28, NULL, true, 'local e2e fixture'),
         ('ZZ99', 'OITM', 'U_ODM', 'field', 'ODM division (sample line)', 'A(30)', 'raw_only', NULL, 'raw_only', 9, 40, current_date - 10, true, 'local e2e fixture'),
         ('ZZ99', 'OITM', 'U_HSCODE', 'field', 'HS code (sample line)', 'A(20)', 'mapped', 'erp.item.hs_code', 'mapped', 40, 40, current_date - 1, true, 'local e2e fixture'),
         ('ZZ99', '@TRADEMARK', '', 'table', 'Trademark master (sample line)', 'user table', 'mapped', 'erp.trademark', 'mapped', 2, 2, NULL, true, 'local e2e fixture'),
         ('ZZ99', '@OLDSALEDATA', '', 'table', 'Old sale data (sample line)', 'user table', 'raw_only', NULL, 'raw_only', 0, 0, NULL, true, 'local e2e fixture')`);
await db.query(`DELETE FROM erp.special_price_period WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.special_price WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.discount_group WHERE company_code = 'ZZ99'`);
await db.query(`INSERT INTO erp.special_price (company_code, card_code, item_code, price, currency, discount_pct, list_num, valid, valid_from, valid_to, auto_update, source)
  VALUES ('ZZ99', 'C0001', 'SMP-1010', 95.5, 'AED', 5, 1, true, current_date - 30, current_date + 60, false, 'sample'),
         ('ZZ99', 'C0002', 'SMP-1040', 410, 'AED', 0, 1, true, NULL, NULL, false, 'sample')`);
await db.query(`INSERT INTO erp.special_price_period (company_code, card_code, item_code, line_num, from_date, to_date, price, currency, discount_pct, list_num)
  VALUES ('ZZ99', 'C0001', 'SMP-1010', 0, current_date, current_date + 30, 90, 'AED', 10, 1)`);
await db.query(`INSERT INTO erp.discount_group (company_code, abs_entry, kind, obj_type, obj_code, disc_rel, valid, valid_from, valid_to)
  VALUES ('ZZ99', 1, 'A', '-1', NULL, 'L', true, date_trunc('year', current_date), date_trunc('year', current_date) + interval '1 year - 1 day')`);
await db.query(`INSERT INTO erp.discount_group_line (company_code, abs_entry, line_num, obj_type, obj_key, disc_type, discount_pct, up_to)
  VALUES ('ZZ99', 1, 0, 4, 'SMP-1010', 'D', 7.5, 100)`);
await db.query(`SELECT erp.migration_more_checks('ZZ99', $1)`, [RUN]);
const nChecks = Number((await one(`SELECT count(*) n FROM erp.migration_check WHERE run_id = $1`, [RUN])).n);
ok('fixture: A12 checks written for the sample run', nChecks >= 10, `${nChecks} checks`);
const dupPhone = await one(`SELECT count(*) n FROM erp.migration_issue WHERE run_id = $1 AND area = 'duplicates' AND issue_key LIKE 'dup:ZZ99:bp:phone:%' AND severity = 'warning'`, [RUN]);
ok('duplicates: sample partners sharing one phone number found as a warning', Number(dupPhone.n) >= 1);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- 1. cross-check: new areas, reconciliation card, run report ----------
{
  const ctx = await context(browser);
  const p = await ctx.newPage(); watch(p, 'check');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/backoffice/migration/runs/${RUN}/check`); await settle(p);
  ok('cross-check: Reconciliation 5.3–5.10 card shown', await seen(p.getByRole('heading', { name: /Reconciliation 5\.3/ })));
  ok('cross-check: new areas in "At a glance" (Duplicates, Custom fields)', await seen(p.getByText('Duplicates', { exact: true })) && await seen(p.getByText('Custom fields', { exact: true })));
  ok('cross-check: skipped raw checks labelled Skipped', await seen(p.getByText('Skipped', { exact: true })));
  ok('cross-check: duplicate warning listed in the issues', await seen(p.getByText(/share the same phone/)));
  const before = Number((await one(`SELECT count(*) n FROM erp.audit_log WHERE action = 'migration_report' AND object_ref = $1`, [RUN])).n);
  await p.locator('summary', { hasText: 'Download report' }).click();
  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 15000 }), p.getByRole('button', { name: /CSV/ }).click()]);
  const csv = fs.readFileSync(await dl.path(), 'utf8');
  fs.copyFileSync(await dl.path(), `${OUT}/a12-run-report.csv`);
  ok('run report CSV: run, steps, checks, issues, sign-offs, register, attachments', csv.includes(RUN) && ['Steps', 'Checks', 'Issues', 'Sign-offs', 'Custom-field register', 'Attachments'].every((s) => csv.includes(`\r\n${s}\r\n`)), dl.suggestedFilename());
  if (!(await p.locator('details').first().evaluate((d) => d.open))) await p.locator('summary', { hasText: 'Download report' }).click();
  const pdf = await Promise.all([p.waitForEvent('download', { timeout: 45000 }), p.getByRole('button', { name: /PDF/ }).click()]).then(([d]) => d).catch(() => null);
  const pdfErr = pdf ? '' : await p.locator('[role=alert]').first().innerText().catch(() => 'no download event');
  ok('run report PDF downloads', Boolean(pdf && fs.statSync(await pdf.path()).size > 2000), pdf ? pdf.suggestedFilename() : pdfErr);
  const after = Number((await one(`SELECT count(*) n FROM erp.audit_log WHERE action = 'migration_report' AND object_ref = $1`, [RUN])).n);
  ok('report downloads audited (migration_report)', after >= before + 2, `${before} → ${after}`);
  await p.screenshot({ path: `${OUT}/a12-crosscheck-en-light-1440.png`, fullPage: true });

  // ---------- 2. run page lists the attachments step ----------
  await p.goto(`${BASE}/backoffice/migration/runs/${RUN}`); await settle(p);
  ok('run page: "Copy attachments" step listed', await seen(p.getByText('Copy attachments')));

  // ---------- 3. custom-field register as admin ----------
  await p.goto(`${BASE}/backoffice/migration/fields?company=ZZ99`); await settle(p);
  ok('register: six sample lines listed', await seen(p.getByText('U_OLDFLAG')) && (await p.locator('tbody tr').count()) === 6);
  await p.getByLabel('Unused only').check(); await settle(p);
  await p.waitForTimeout(500);
  ok('register: "Unused only" filter', (await p.locator('tbody tr').count()) === 2);
  await p.getByLabel('Unused only').uncheck(); await settle(p);
  await p.locator('#cf-search').fill('ODM'); await p.waitForTimeout(800); await settle(p);
  ok('register: search', (await p.locator('tbody tr').count()) === 1);
  await p.getByLabel('OITM U_ODM').check();
  await p.getByRole('button', { name: 'Map to a column…' }).click();
  await p.locator('dialog[open]').getByLabel('Target column (erp.table.column)').fill('erp.item.nope');
  await p.locator('dialog[open]').getByRole('button', { name: 'Map field' }).click();
  ok('register: unknown target refused with the server message', await seen(p.getByText('Target erp.item.nope does not exist. Use erp.<table>.<column>.')));
  await p.locator('dialog[open]').getByLabel('Target column (erp.table.column)').fill('erp.item.odm_division');
  await p.locator('dialog[open]').getByRole('button', { name: 'Map field' }).click();
  ok('register: field mapped', await seen(p.getByText('Field mapped.')));
  const m = await one(`SELECT decision, target, decided_by FROM erp.custom_field_register WHERE company_code = 'ZZ99' AND field_name = 'U_ODM'`);
  ok('register: saved as mapped by the admin', m.decision === 'mapped' && m.target === 'erp.item.odm_division' && m.decided_by === '00000000-0000-4000-8000-000000000001');
  await p.locator('#cf-search').fill(''); await p.waitForTimeout(800); await settle(p);
  await p.getByLabel('OCRD U_OLDFLAG').check();
  await p.getByRole('button', { name: 'Propose drop' }).click();
  await p.locator('dialog[open]').getByRole('button', { name: 'Propose drop' }).click();
  ok('register: drop proposed', await seen(p.getByText(/proposed for dropping/)));
  ok('register: admin is not offered "Approve drop"', !(await seen(p.getByRole('button', { name: /Approve drop/ }), 1500)));
  await p.screenshot({ path: `${OUT}/a12-fields-admin-en-light-1440.png`, fullPage: true });
  await ctx.close();
}
ok('register: drop waits for the owner', (await one(`SELECT drop_state FROM erp.custom_field_register WHERE company_code = 'ZZ99' AND field_name = 'U_OLDFLAG'`)).drop_state === 'pending');

// ---------- 4. owner approves; sales refused ----------
{
  const ctx = await context(browser);
  const p = await ctx.newPage(); watch(p, 'owner');
  await login(p, 'owner'); await settle(p);
  await p.goto(`${BASE}/backoffice/migration/fields?company=ZZ99`); await settle(p);
  await p.getByLabel('Decision', { exact: true }).selectOption('drop_pending'); await settle(p); await p.waitForTimeout(500);
  await p.getByLabel('OCRD U_OLDFLAG').check();
  ok('owner: no edit actions, only approve / reject', !(await seen(p.getByRole('button', { name: 'Propose drop' }), 1500)) && await seen(p.getByRole('button', { name: /Approve drop/ })));
  await p.getByRole('button', { name: /Approve drop/ }).click();
  await p.locator('dialog[open]').getByRole('button', { name: 'Approve drop' }).click();
  ok('owner: drop approved', await seen(p.getByText(/Drop approved for 1/)));
  await ctx.close();
}
ok('owner approval stored', (await one(`SELECT drop_state, drop_decided_by FROM erp.custom_field_register WHERE company_code = 'ZZ99' AND field_name = 'U_OLDFLAG'`)).drop_decided_by === '00000000-0000-4000-8000-000000000005');
{
  const ctx = await context(browser);
  const p = await ctx.newPage(); watch(p, 'sales');
  await login(p, 'sales'); await settle(p);
  await p.goto(`${BASE}/backoffice/migration/fields?company=ZZ99`); await settle(p);
  ok('sales user: register refused ("You don\'t have access to this")', await seen(p.getByText(/You don.t have access to this/)));
  await ctx.close();
}

// ---------- 5. upload: opening-balances load type and settings ----------
{
  const ctx = await context(browser);
  const p = await ctx.newPage(); watch(p, 'upload');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/backoffice/migration/upload?company=ZZ99`); await settle(p);
  ok('upload: load type choice shown', await seen(p.getByText('Opening balances only', { exact: true })));
  await p.getByLabel(/Opening balances only/).check();
  ok('upload: settings card appears with "Not set"', await seen(p.getByRole('heading', { name: /Opening balances and settings/ })) && await seen(p.getByText('Not set', { exact: true })));
  await p.locator('#os-opening_date').fill('2026-10-31');
  await p.locator('#os-opening_clearing_acct').fill('9999');
  await p.getByRole('button', { name: 'Save settings' }).click();
  ok('upload: unknown clearing account refused', await seen(p.getByText('Account 9999 is not in the chart of accounts of ZZ99.')));
  await p.locator('#os-opening_clearing_acct').fill('3200');
  await p.locator('#os-net_pay_wage_codes').fill('BASIC, HOUSING');
  await p.getByRole('button', { name: 'Save settings' }).click();
  ok('upload: settings saved', await seen(p.getByText('Settings saved.')) && await seen(p.getByText('Ready', { exact: true })));
  const s = await one(`SELECT opening_date::text d, opening_clearing_acct a, net_pay_wage_codes w FROM erp.migration_setting WHERE company_code = 'ZZ99'`);
  ok('upload: settings stored (sample company)', s?.d === '2026-10-31' && s?.a === '3200' && s?.w.join(',') === 'BASIC,HOUSING', JSON.stringify(s));
  await p.screenshot({ path: `${OUT}/a12-upload-opening-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

// ---------- 6. special prices / discounts live ----------
{
  const ctx = await context(browser);
  const p = await ctx.newPage(); watch(p, 'prices');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/inventory/special-prices`); await settle(p);
  ok('special prices list: sample rows with partner name', await seen(p.getByText('North Star Hypermarket')) && await seen(p.getByText('SMP-1040')));
  await p.screenshot({ path: `${OUT}/a12-special-prices-en-light-1440.png`, fullPage: true });
  await p.goto(`${BASE}/inventory/discounts`); await settle(p);
  ok('period and volume discounts list', await seen(p.getByText('All partners')) && await seen(p.getByText('SMP-1010')));
  await p.goto(`${BASE}/m/inventory`); await settle(p);
  await p.getByText('Price Lists', { exact: false }).first().click().catch(() => {});
  await settle(p);
  ok('module page: Special prices and discounts are live links', await seen(p.locator('a[href="/inventory/special-prices"]')) && await seen(p.locator('a[href="/inventory/discounts"]')));
  await ctx.close();
}

// ---------- 7. screenshots: 1440 / 390, light / dark, EN / AR ----------
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'admin'); await settle(page);
  let scrollOk = true;
  for (const [nm, url] of [['crosscheck', `/backoffice/migration/runs/${RUN}/check`], ['fields', '/backoffice/migration/fields?company=ZZ99'], ['upload', '/backoffice/migration/upload?company=ZZ99']]) {
    await page.goto(`${BASE}${url}`); await settle(page);
    await page.waitForTimeout(600);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${nm}`); }
    await page.screenshot({ path: `${OUT}/a12-${nm}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA12 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

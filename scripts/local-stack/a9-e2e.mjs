// A9 browser test: HR and Staff Portal, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a9-e2e.mjs [outDir]
// qa.emp (phone) checks in inside the site area → qa.teamlead checks in outside it (flagged) → qa.emp requests leave → the team lead
// approves from the inbox → qa.hr approves → qa.emp2 can't see it → HR read-only sees no salary → qa.hr: employee pay, gratuity,
// attendance flags, expiry list, new employee → payroll: input, calculate, review, lock, WPS check + SIF download, post → qa.emp opens
// the payslip. Screenshots 1440 / 390, light / dark, EN / AR. Resets today's attendance and earlier e2e leave of the test staff first.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a9-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const uniq = String(Date.now()).slice(-6);

const USERS = {
  hr: ['qa.hr@sample.test', 'local-only-18'],
  hrread: ['qa.hrread@sample.test', 'local-only-19'],
  emp: ['qa.emp@sample.test', 'local-only-20'],
  lead: ['qa.teamlead@sample.test', 'local-only-21'],
  emp2: ['qa.emp2@sample.test', 'local-only-22'],
};
const INSIDE = { latitude: 24.8962, longitude: 55.1612, accuracy: 15 };
const OUTSIDE = { latitude: 25.05, longitude: 55.3, accuracy: 20 };
async function login(page, who) {
  const [email, password] = USERS[who];
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light', geo } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, acceptDownloads: true,
    ...(geo ? { geolocation: geo, permissions: ['geolocation'] } : {}), ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  return ctx;
}
const txt = (loc) => loc.first().innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

// fixtures: today's check-ins and earlier e2e leave of the test staff; a payroll month that is not posted yet
await db.query(`DELETE FROM erp.hr_attendance WHERE company_code = 'ZZ99' AND emp_id IN (6, 7, 3, 8)
                  AND work_date = (now() AT TIME ZONE 'Asia/Dubai')::date`);
await db.query(`DELETE FROM erp.approval WHERE company_code = 'ZZ99' AND object = 'leave'
                  AND object_ref IN (SELECT request_id::text FROM erp.leave_request WHERE company_code = 'ZZ99' AND reason LIKE 'E2E%')`);
await db.query(`DELETE FROM erp.leave_request WHERE company_code = 'ZZ99' AND reason LIKE 'E2E%'`);
let period = null;
for (let m = 8; m >= 1; m--) {
  const p = `2026-${String(m).padStart(2, '0')}`;
  const r = await one(`SELECT state FROM erp.hr_payroll_run WHERE company_code = 'ZZ99' AND period = $1`, [p]);
  if (!r) { period = p; break; }
  if (r.state !== 'posted') { await db.query(`DELETE FROM erp.hr_payroll_run WHERE company_code = 'ZZ99' AND period = $1`, [p]); period = p; break; }
}
await db.query(`DELETE FROM erp.hr_payroll_input WHERE company_code = 'ZZ99' AND period = $1`, [period]);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- 1. qa.emp checks in on the phone, inside the site area ----------
{
  const C = await context(browser, { width: 390, height: 844, geo: INSIDE });
  const p = await C.newPage(); watch(p, 'emp');
  await login(p, 'emp'); await settle(p);
  await p.goto(`${BASE}/portal`); await settle(p);
  await seen(p.locator('[data-testid=portal-profile]'));
  ok('portal: own profile (E0006 Faisal Karim)', (await txt(p.locator('[data-testid=portal-profile]'))).includes('Faisal Karim'));
  ok('portal: shift and the department duties', (await txt(p.locator('[data-testid=portal-shift]'))).includes('Warehouse')
    && (await p.locator('[data-testid=portal-duties] li').count()) === 3);
  ok('portal: annual leave balance shown', (await txt(p.locator('[data-testid=hr-balances]'))).includes('Annual leave'));
  await p.locator('[data-testid=portal-check]').click();
  await seen(p.locator('[data-testid=portal-check-msg]'));
  const m1 = await txt(p.locator('[data-testid=portal-check-msg]'));
  ok('check-in inside the site area: not flagged', m1.startsWith('Checked in at') && !m1.includes('Outside'), m1);
  await seen(p.locator('[data-testid=portal-check]:has-text("Check out")'));
  ok('then the button offers check-out', (await txt(p.locator('[data-testid=portal-check]'))).includes('Check out'));
  ok('portal: no horizontal scroll at 390 px', await noHScroll(p));
  await p.screenshot({ path: `${OUT}/a9-portal-checked-in-en-light-390.png`, fullPage: true });

  // leave request
  await p.locator('[data-testid=leave-type]').selectOption('AL');
  await p.fill('[data-testid=leave-from]', '2026-12-14');
  await p.fill('[data-testid=leave-to]', '2026-12-17');
  await p.fill('[data-testid=leave-reason]', `E2E family visit ${uniq}`);
  await seen(p.locator('[data-testid=leave-preview]'));
  ok('leave form: 4 working days and the approval route', (await txt(p.locator('[data-testid=leave-days]'))) === '4 days'
    && (await txt(p.locator('[data-testid=leave-steps]'))).includes('Ravi Menon → QA · HR officer'), await txt(p.locator('[data-testid=leave-preview]')));
  await p.fill('[data-testid=leave-to]', '2026-12-13');
  await seen(p.locator('[data-testid=hr-field-error]'));
  ok('leave form: last day before first day is explained', (await txt(p.locator('[data-testid=hr-field-error]'))) === "The last day can't be before the first day.");
  await p.fill('[data-testid=leave-to]', '2026-12-17');
  await seen(p.locator('[data-testid=leave-preview]'));
  await p.locator('[data-testid=leave-submit]').click();
  await seen(p.locator('[data-testid=bk-flash]'));
  ok('leave submitted: says who approves', (await txt(p.locator('[data-testid=bk-flash]'))).includes('Sent for approval to Ravi Menon'));
  await C.close();
}
const req = await one(`SELECT request_id FROM erp.leave_request WHERE company_code = 'ZZ99' AND reason = $1`, [`E2E family visit ${uniq}`]);
ok('leave request stored', Boolean(req?.request_id));

// ---------- 2. qa.teamlead checks in outside the area, then approves from the inbox ----------
{
  const C = await context(browser, { geo: OUTSIDE });
  const p = await C.newPage(); watch(p, 'lead');
  await login(p, 'lead'); await settle(p);
  await p.goto(`${BASE}/portal`); await settle(p);
  await p.locator('[data-testid=portal-check]').click();
  await seen(p.locator('[data-testid=portal-check-msg]'));
  const m = await txt(p.locator('[data-testid=portal-check-msg]'));
  ok('check-in outside the site area is flagged with the rule', m.includes('Outside the site area') && m.includes('Check-in outside site area'), m);
  ok('portal: team lead sees a team request waiting', await seen(p.locator('[data-testid=portal-team-waiting]')));
  await p.goto(`${BASE}/approvals`); await settle(p);
  const link = p.locator(`a[href="/hr/leave/ZZ99/${req.request_id}"]`);
  ok('inbox: leave waiting for the manager', await seen(link));
  await link.first().click(); await settle(p);
  await seen(p.locator('[data-testid=leave-approval-card]'));
  await p.screenshot({ path: `${OUT}/a9-leave-approval-en-light-1440.png`, fullPage: true });
  await p.locator('[data-testid=leave-reject]').click();
  await seen(p.locator('[data-testid=bk-error]'));
  ok('rejecting without a note is refused with the reason', (await txt(p.locator('[data-testid=bk-error]'))) === 'Add a note saying why you are rejecting this leave request.');
  await p.locator('[data-testid=leave-approve]').click();
  await seen(p.locator('[data-testid=bk-flash]'));
  ok('manager approves → waits for HR', (await txt(p.locator('[data-testid=leave-approvals]'))).includes('Waiting for approval')
    && !(await p.locator('[data-testid=leave-approval-card]').count()));
  await C.close();
}

// ---------- 3. qa.hr approves; qa.emp2 can't see it ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'hr');
  await login(p, 'hr'); await settle(p);
  await p.goto(`${BASE}/hr/leave/ZZ99/${req.request_id}`); await settle(p);
  await seen(p.locator('[data-testid=leave-approve]'));
  await p.locator('[data-testid=leave-approve]').click();
  await seen(p.locator('[data-testid=bk-flash]'));
  ok('HR approves → Approved', (await txt(p.locator('h1'))).includes('Approved'));
  await C.close();
}
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'emp2');
  await login(p, 'emp2'); await settle(p);
  await p.goto(`${BASE}/hr/leave`); await settle(p);
  await p.locator('table').first().waitFor({ timeout: 10000 }).catch(() => {});
  await p.waitForTimeout(500);
  const body = await txt(p.locator('main'));
  ok('another employee does not see this leave', !body.includes('Faisal Karim'));
  await C.close();
}

// ---------- 4. HR read-only: no salary ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'hrread');
  await login(p, 'hrread'); await settle(p);
  await p.goto(`${BASE}/hr/employees/ZZ99/1`); await settle(p);
  ok('HR read-only: profile without pay (explained)', await seen(p.locator('[data-testid=hr-salary-hidden]')) && (await p.locator('[data-testid=hr-pay]').count()) === 0);
  ok('HR read-only: no New employee action', (await p.goto(`${BASE}/hr/employees`).then(() => settle(p)).then(() => p.locator('[data-testid=hr-new-employee]').count())) === 0);
  await C.close();
}

// ---------- 5. qa.hr: employee, attendance, expiry, new employee, payroll ----------
const C = await context(browser);
const ph = await C.newPage(); watch(ph, 'hr');
await login(ph, 'hr'); await settle(ph);
await ph.goto(`${BASE}/hr/employees/ZZ99/1`); await settle(ph);
await seen(ph.locator('[data-testid=hr-pay]'));
ok('HR full: pay table with monthly total 13,500.00', (await txt(ph.locator('[data-testid=hr-pay]'))).includes('13,500.00 AED'));
ok('HR full: gratuity and air ticket shown, not posted', (await txt(ph.locator('[data-testid=hr-eos]'))).includes('Nothing is posted until approved'));
const audits = await one(`SELECT count(*)::int AS n FROM erp.audit_log WHERE action = 'salary_view' AND actor = '00000000-0000-4000-8000-000000000018' AND object_ref = '1'`);
ok('viewing pay was audited', audits.n >= 1, String(audits.n));
await ph.goto(`${BASE}/hr/attendance?f_outside_site=true`); await settle(ph);
await ph.locator('table').first().waitFor({ timeout: 10000 }).catch(() => {});
ok('attendance list: the outside-site check-in is flagged', (await txt(ph.locator('main'))).includes('Ravi Menon') && (await txt(ph.locator('main'))).includes('Outside site area'));
await ph.goto(`${BASE}/hr/expiry`); await settle(ph);
await ph.locator('table').first().waitFor({ timeout: 10000 }).catch(() => {});
{ const body = await txt(ph.locator('main')); ok('document expiry list with 7 / 30 / 60 day bands', ['Within 7 days', 'Within 30 days', 'Within 60 days', 'Expired'].every((b) => body.includes(b))); }
// new employee
await ph.goto(`${BASE}/hr/employees/new`); await settle(ph);
await ph.locator('[data-testid=hr-f-save]').waitFor({ timeout: 10000 });
await ph.fill('[data-testid=hr-f-first]', 'E2E');
await ph.locator('[data-testid=hr-f-save]').click();
await seen(ph.locator('[data-testid=bk-error]'));
ok('new employee: missing last name explained', (await txt(ph.locator('[data-testid=bk-error]'))) === 'Enter the last name.');
await ph.fill('[data-testid=hr-f-last]', `Joiner ${uniq}`);
await ph.fill('[data-testid=hr-f-dept]', 'Warehouse');
await ph.fill('[data-testid=hr-f-joined]', '2026-11-01');
await ph.locator('[data-testid=hr-f-save]').click();
await ph.waitForURL(/\/hr\/employees\/ZZ99\/\d+$/, { timeout: 10000 }).catch(() => {});
await seen(ph.locator('[data-testid=bk-flash]'));
ok('new employee created with an EMP- code', /Employee EMP-\d{4} created\./.test(await txt(ph.locator('[data-testid=bk-flash]'))));
await ph.screenshot({ path: `${OUT}/a9-employee-new-detail-en-light-1440.png`, fullPage: true });

// payroll
await ph.goto(`${BASE}/hr/payroll`); await settle(ph);
await ph.fill('[data-testid=hr-run-period]', period);
await ph.locator('[data-testid=hr-run-calc]').click();
await ph.waitForURL(/\/hr\/payroll\/ZZ99\/\d+$/, { timeout: 15000 });
await settle(ph);
ok(`payroll ${period} calculated`, (await txt(ph.locator('[data-testid=bk-flash]'))).includes('Calculated for'));
await ph.locator('[data-testid=hr-in-emp]').selectOption('1');
await ph.locator('[data-testid=hr-in-kind]').selectOption('overtime_hours');
await ph.fill('[data-testid=hr-in-value]', '10');
await ph.locator('[data-testid=hr-in-add]').click();
await seen(ph.locator('[data-testid=hr-inputs]'));
await ph.locator('[data-testid=hr-run-review]').click();
await seen(ph.locator('[data-testid=bk-error]'));
ok('review refused until calculated again', (await txt(ph.locator('[data-testid=bk-error]'))).includes('Calculate payroll'));
await ph.locator('[data-testid=hr-run-recalc]').click();
await seen(ph.locator('[data-testid=bk-flash]:has-text("Calculated again")'));
const e1 = await one(`SELECT pe.net FROM erp.hr_payroll_emp pe JOIN erp.hr_payroll_run r USING (run_id) WHERE r.company_code = 'ZZ99' AND r.period = $1 AND pe.emp_id = 1`, [period]);
ok('payroll maths in the browser run: E0001 13,500 + 10 h × 46.875 = 13,968.75', Number(e1?.net) === 13968.75, String(e1?.net));
await ph.locator('[data-testid=hr-run-review]').click();
await seen(ph.locator('[data-testid=hr-run-lock]'));
await ph.locator('[data-testid=hr-run-lock]').click();
await seen(ph.locator('[data-testid=hr-run-post]'));
ok('payroll locked', (await txt(ph.locator('h1'))).includes('Locked'));
await ph.locator('[data-testid=hr-wps-check]').click();
await seen(ph.locator('[data-testid=hr-wps-ok]'));
ok('WPS check passes', (await txt(ph.locator('[data-testid=hr-wps-ok]'))).startsWith('Ready:'));
const [dl] = await Promise.all([ph.waitForEvent('download', { timeout: 10000 }).catch(() => null), ph.locator('[data-testid=hr-wps-download]').click()]);
let sif = '';
if (dl) { const fp = `${OUT}/a9-${dl.suggestedFilename()}`; await dl.saveAs(fp); sif = fs.readFileSync(fp, 'utf8'); }
ok('SIF downloaded: name, EDR rows and SCR control row', Boolean(dl) && /^1000000000099\d{12}\.SIF$/.test(dl.suggestedFilename())
  && /^EDR,\d{14},\d{9},AE\d{21},/m.test(sif) && /^SCR,1000000000099,403520101,/m.test(sif), dl?.suggestedFilename());
await ph.screenshot({ path: `${OUT}/a9-payroll-locked-en-light-1440.png`, fullPage: true });
await ph.locator('[data-testid=hr-run-post]').click();
await seen(ph.locator('[data-testid=hr-run-journal]'));
ok('payroll posted through Financials (journal shown)', (await txt(ph.locator('h1'))).includes('Posted') && (await txt(ph.locator('[data-testid=hr-run-journal]'))).includes('2300'));
const runId = Number(ph.url().split('/').pop());
await C.close();

// ---------- 6. qa.emp opens the payslip ----------
{
  const C2 = await context(browser, { width: 390, height: 844 });
  const p = await C2.newPage(); watch(p, 'emp-payslip');
  await login(p, 'emp'); await settle(p);
  await p.goto(`${BASE}/portal`); await settle(p);
  const link = p.locator(`a[href="/portal/payslip/ZZ99/${runId}"]`);
  ok('portal lists the new payslip', await seen(link));
  await link.first().click(); await settle(p);
  await seen(p.locator('[data-testid=payslip-net]'));
  ok('payslip: own net pay 4,700.00 AED', (await txt(p.locator('[data-testid=payslip-net]'))) === '4,700.00 AED');
  await p.screenshot({ path: `${OUT}/a9-payslip-en-light-390.png`, fullPage: true });
  await p.goto(`${BASE}/portal/payslip/ZZ99/${runId}?emp=1`); await settle(p);
  await seen(p.locator('main [role=alert]'), 20000);
  ok("someone else's payslip is refused (42501 → no access)", (await txt(p.locator('main [role=alert]'))).includes("You don't have access to this"));
  await C2.close();
}

// ---------- 7. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['portal', '/portal'],
  ['leave-list', '/hr/leave'],
  ['leave', `/hr/leave/ZZ99/${req.request_id}`],
  ['employee', '/hr/employees/ZZ99/1'],
  ['attendance', '/hr/attendance'],
  ['expiry', '/hr/expiry'],
  ['payroll', `/hr/payroll/ZZ99/${runId}`],
  ['setup', '/hr/setup'],
];
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'hr'); await settle(page);
  let scrollOk = true;
  for (const [nm, p] of shots) {
    await page.goto(`${BASE}${p}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(600);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${nm}`); }
    await page.screenshot({ path: `${OUT}/a9-${nm}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

// module page shows the HR functions as live
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'module');
  await login(page, 'hr'); await settle(page);
  await page.goto(`${BASE}/m/hr?fn=6`); await settle(page);
  await page.waitForTimeout(500);
  ok('module page: Payroll opens the working screen', await seen(page.locator('a[href="/hr/payroll"]')));
  await page.screenshot({ path: `${OUT}/a9-module-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA9 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

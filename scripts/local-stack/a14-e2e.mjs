// A14 browser test: go-live checklist and system health, against the local stack (Vite :5173 + gateway :54321 + PostgREST +
// Postgres, sample company ZZ99 only).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a14-e2e.mjs [outDir]
// qa.sales can't open the checklist → qa.admin: overview card (step 1 done from a signed-off fixture run) → steps go in order,
// step 2 needs the approval reference, steps 3–5 → qa.owner (CFO, read-only) takes ZZ99 live through the dialog → steps 2–5
// locked, hypercare issue logged and closed, step 7 waits 2 weeks → system health (files, checks, companies) → module page
// shows Implementation Center live. Screenshots 1440 / 390, light / dark, EN / AR. Cleans up the ZZ99 go-live state at the end.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a14-shots';
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
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  return ctx;
}
const txt = (loc) => loc.innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

const RUN = 'a14e2e00-0000-4000-8000-000000000001';
async function cleanup() {
  await db.query("DELETE FROM erp.company_cutover WHERE company_code = 'ZZ99'");
  await db.query("DELETE FROM erp.go_live_issue WHERE company_code = 'ZZ99'");
  await db.query("DELETE FROM erp.go_live_step WHERE company_code = 'ZZ99'");
  await db.query('DELETE FROM erp.migration_run WHERE run_id = $1', [RUN]);
}
// Fixture: a signed-off migration run for ZZ99 (the sign-off flow itself is covered by the console tests).
await db.query(`INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema, in_scope)
                VALUES ('ZZ99', 'Sample Trading LLC (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ99', false) ON CONFLICT DO NOTHING`);
await cleanup();
await db.query(`INSERT INTO erp.migration_run (run_id, company_code, kind, status, created_at, finished_at, notes)
                VALUES ($1, 'ZZ99', 'full', 'signed_off', now() - interval '1 hour', now() - interval '50 minutes', 'a14 e2e fixture')`, [RUN]);
await db.query(`INSERT INTO erp.migration_signoff (run_id, role, signed_by, decision) VALUES
                ($1, 'finance', '00000000-0000-4000-8000-000000000004', 'approved'), ($1, 'it', '00000000-0000-4000-8000-000000000001', 'approved'),
                ($1, 'business', '00000000-0000-4000-8000-000000000005', 'approved')`, [RUN]);
await db.query("UPDATE erp.user_invite SET state = 'cancelled', cancelled_at = now() WHERE company_code = 'ZZ99' AND state IN ('pending', 'sent') AND user_id IS NULL");

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const step = (page, n) => page.locator(`[data-testid=gl-steps] li[data-step="${n}"]`);
const errText = (page) => txt(page.locator('[data-testid=adm-error]'));
async function mark(page, n, { evidence, note } = {}) {
  await page.click(`#gl-mark-${n}`);
  await page.locator('[data-testid=gl-form]').waitFor();
  if (evidence !== undefined) await page.fill('#gl-evidence', evidence);
  if (note !== undefined) await page.fill('#gl-note', note);
  await page.click('#gl-save');
  await settle(page);
  await page.waitForTimeout(300);
}

try {
  // ---------- 1. A sales user can't open the checklist ----------
  {
    const ctx = await context(browser);
    const p = await ctx.newPage(); watch(p, 'sales');
    await login(p, 'sales'); await settle(p);
    await p.goto(`${BASE}/admin/go-live`); await settle(p);
    ok('sales user gets "No access" on the go-live checklist', await seen(p.locator('main [role=alert]', { hasText: 'does not include Administration' })));
    await ctx.close();
  }

  // ---------- 2. Admin works through steps 1–5 ----------
  const actx = await context(browser);
  const ap = await actx.newPage(); watch(ap, 'admin');
  await login(ap, 'admin'); await settle(ap);
  await ap.goto(`${BASE}/admin/go-live`); await settle(ap);
  const card = ap.locator('[data-testid=gl-companies] a[data-company="ZZ99"]');
  ok('overview lists ZZ99 with 1 of 7 steps (signed-off run)', await seen(card) && /1 of 7 steps done/.test(await txt(card)), (await txt(card)).replace(/\s+/g, ' ').slice(0, 120));
  ok('overview links to System health', await seen(ap.locator('#gl-health-link')));
  await ap.screenshot({ path: `${OUT}/a14-overview-before-en-light-1440.png`, fullPage: true });
  await card.click(); await settle(ap);
  ok('checklist opens with 7 steps', await seen(ap.locator('[data-testid=gl-steps] li[data-step="7"]')) && (await ap.locator('[data-testid=gl-steps] li').count()) === 7);
  ok('step 1 is done and shows the 3 sign-offs', (await step(ap, 1).getAttribute('data-done')) === 'true' && /Finance · approved/.test(await txt(step(ap, 1))) && /Business · approved/.test(await txt(step(ap, 1))));
  ok('step 1 and step 6 have no tick buttons', (await ap.locator('#gl-mark-1, #gl-mark-6').count()) === 0);

  await mark(ap, 3);
  ok('steps go in order: step 3 before step 2 is refused with the server message', (await errText(ap)) === "Finish step 2 first: Ashif's written approval to import production data.", await errText(ap));
  await ap.click('#gl-cancel');
  await mark(ap, 2, { evidence: '' });
  ok('step 2 needs the approval reference', (await errText(ap)) === "Add where Ashif's written approval is kept (for example the email date and subject).", await errText(ap));
  await ap.fill('#gl-evidence', 'Email 10 Nov 2026 · "ZZ99 sample go-live approval"');
  await ap.fill('#gl-note', 'Sample company only');
  await ap.click('#gl-save'); await settle(ap); await ap.waitForTimeout(300);
  ok('step 2 marked done with who and the reference', (await step(ap, 2).getAttribute('data-done')) === 'true' && /QA Admin/.test(await txt(step(ap, 2))) && /ZZ99 sample go-live approval/.test(await txt(step(ap, 2))));
  ok('flash names the step', /Step 2 marked done/.test(await txt(ap.locator('[data-testid=adm-flash]'))));
  await mark(ap, 3, { note: 'Department heads signed in on the sample company' });
  await mark(ap, 4, { note: 'Opening trial balance agrees with SAP' });
  await mark(ap, 5, { evidence: '' });
  ok('step 5 needs the backup reference', (await errText(ap)) === 'Add the final backup reference (backup name or time) before marking this step done.', await errText(ap));
  await ap.fill('#gl-evidence', 'SBO_ZZ99_final_2026-11-10.bak');
  await ap.click('#gl-save'); await settle(ap); await ap.waitForTimeout(300);
  ok('steps 2–5 done', (await ap.locator('[data-testid=gl-steps] li[data-done="true"]').count()) === 5);
  // reopen rule on the screen
  await ap.click('#gl-reopen-4');
  await ap.click('#gl-save'); await settle(ap); await ap.waitForTimeout(300);
  ok('reopening needs a reason', (await errText(ap)) === 'Say why this step is being reopened.', await errText(ap));
  await ap.fill('#gl-note', 'check');
  await ap.click('#gl-save'); await settle(ap); await ap.waitForTimeout(300);
  ok('later steps must be reopened first', (await errText(ap)) === 'Reopen step 5 first: it comes after this one.', await errText(ap));
  await ap.click('#gl-cancel');
  ok('Go live button is enabled for the CFO signer once steps 1–5 are done', await ap.locator('#gl-golive').isEnabled());
  await ap.evaluate(() => window.scrollTo(0, 0));
  await ap.screenshot({ path: `${OUT}/a14-checklist-ready-en-light-1440.png`, fullPage: true });

  // ---------- 3. Owner (CFO) takes ZZ99 live ----------
  {
    const ctx = await context(browser);
    const p = await ctx.newPage(); watch(p, 'owner');
    await login(p, 'owner'); await settle(p);
    await p.goto(`${BASE}/admin/go-live/ZZ99`); await settle(p);
    ok('owner sees the checklist read-only (no tick buttons)', await seen(p.locator('[data-testid=adm-readonly]')) && (await p.locator('[id^=gl-mark-], [id^=gl-reopen-]').count()) === 0);
    await p.click('#gl-golive');
    ok('go-live asks for confirmation and says the SAP sync stops', /SAP sync stops/.test(await txt(p.locator('[role=dialog]'))));
    await p.screenshot({ path: `${OUT}/a14-golive-dialog-en-light-1440.png` });
    await p.click('#gl-golive-confirm'); await settle(p); await p.waitForTimeout(400);
    ok('ZZ99 is live: flash and state pill', /ZZ99 is live/.test(await txt(p.locator('[data-testid=adm-flash]'))) && /Live since/.test(await txt(p.locator('[data-testid=gl-state]'))));
    ok('step 6 done, shows who took it live', (await step(p, 6).getAttribute('data-done')) === 'true' && /QA Owner/.test(await txt(step(p, 6))));
    const cut = await one("SELECT go_live_run::text AS run FROM erp.company_cutover WHERE company_code = 'ZZ99'");
    ok('company_cutover recorded with the signed-off run', cut?.run === RUN, cut?.run);
    await ctx.close();
  }

  // ---------- 4. Admin after go-live: locked steps, hypercare issues, step 7 ----------
  await ap.reload(); await settle(ap);
  ok('steps 2–5 can no longer be reopened', (await ap.locator('#gl-reopen-2, #gl-reopen-3, #gl-reopen-4, #gl-reopen-5').count()) === 0);
  await ap.click('#gl-issue-add'); await settle(ap); await ap.waitForTimeout(300);
  ok('an issue needs a title', (await errText(ap)) === 'Describe the issue in a few words.', await errText(ap));
  await ap.fill('#gl-issue-title', 'Invoice print shows the old logo');
  await ap.selectOption('#gl-issue-sev', 'critical');
  await ap.click('#gl-issue-add'); await settle(ap); await ap.waitForTimeout(300);
  ok('issue logged as open and critical', /Invoice print shows the old logo/.test(await txt(ap.locator('[data-testid=gl-issues]'))) && (await ap.locator('[data-testid=gl-issues] li[data-status=open]').count()) === 1);
  await mark(ap, 7, { note: 'done' });
  const until = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric', timeZone: 'Asia/Dubai' }).format(new Date(Date.now() + 14 * 864e5));
  ok('step 7 waits 2 weeks after go-live', (await errText(ap)) === `Hypercare runs for 2 weeks after go-live, until ${until}.`, await errText(ap));
  await ap.click('#gl-cancel');
  await ap.evaluate(() => window.scrollTo(0, 0));
  await ap.screenshot({ path: `${OUT}/a14-checklist-live-en-light-1440.png`, fullPage: true });
  await ap.locator('[data-close-issue]').first().click();
  await ap.fill('#gl-close-note', 'New logo uploaded in Company Details');
  await ap.click('#gl-close-save'); await settle(ap); await ap.waitForTimeout(300);
  ok('issue closed with how it was fixed', (await ap.locator('[data-testid=gl-issues] li[data-status=fixed]').count()) === 1 && /New logo uploaded/.test(await txt(ap.locator('[data-testid=gl-issues]'))));
  ok('activity lists the steps, go-live and issues', (await ap.locator('[data-testid=gl-activity] li').count()) >= 7 && /Company taken live/.test(await txt(ap.locator('[data-testid=gl-activity]'))));
  const audit = await one("SELECT count(*)::int AS n FROM erp.audit_log WHERE company_code = 'ZZ99' AND (action LIKE 'go_live_%' OR action = 'company_go_live') AND at > now() - interval '10 minutes'");
  ok('every change is in the audit log', audit.n >= 7, `${audit.n} rows`);

  // ---------- 5. System health ----------
  await ap.goto(`${BASE}/admin/health`); await settle(ap);
  ok('system health loads with an overall status', await seen(ap.locator('[data-testid=gl-health-status]')), await ap.locator('[data-testid=gl-health-status]').getAttribute('data-status').catch(() => ''));
  // B1 adds 30_numbering_company.sql (18 files).
  // B5 adds 34_open_items.sql (22 files), B6 35_final_items.sql (23 files), U0+S1 36_sana.sql (24 files).
  ok('every SQL file 14–36 is in place', (await ap.locator('[data-testid=gl-health-files] tbody tr').count()) === 24 && !/Missing/.test(await txt(ap.locator('[data-testid=gl-health-files]'))));
  ok('files, RLS, search_path and anon checks pass', (await ap.locator('[data-testid=gl-health-checks] li[data-status=ok]').count()) === 4);
  ok('direct write grants shown as a warning with the explanation', (await ap.locator('[data-testid=gl-health-checks] li[data-key=direct_write_grants][data-status=warn]').count()) === 1);
  ok('companies table shows ZZ99 at 6 of 7', /ZZ99[\s\S]*6 \/ 7/.test(await txt(ap.locator('[data-testid=gl-health-companies]'))));
  await ap.screenshot({ path: `${OUT}/a14-health-en-light-1440.png`, fullPage: true });

  // ---------- 6. Module page ----------
  await ap.goto(`${BASE}/m/administration?fn=3`); await settle(ap); await ap.waitForTimeout(400);
  ok('module page: Implementation Center opens the go-live checklist', await seen(ap.locator('a[href="/admin/go-live"]')));
  await actx.close();

  // ---------- 7. Screenshots ----------
  const shots = [['overview', '/admin/go-live'], ['checklist', '/admin/go-live/ZZ99'], ['health', '/admin/health']];
  for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
    const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
    const page = await ctx.newPage(); watch(page, `shot-${lang}-${theme}-${width}`);
    await login(page, 'admin'); await settle(page);
    for (const [name, path] of shots) {
      await page.goto(`${BASE}${path}`); await settle(page);
      await page.waitForTimeout(400);
      if (width < 640 && theme === 'light') ok(`phone ${lang}: ${name} has no horizontal scroll`, await noHScroll(page));
      await page.screenshot({ path: `${OUT}/a14-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
    }
    await ctx.close();
  }
} finally {
  await cleanup();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA14 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

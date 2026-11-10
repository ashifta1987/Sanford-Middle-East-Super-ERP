// B2 browser test: Administration › Approval Process (Approval Stages, Approval Templates with originators / ordered stages /
// conditions / history, Approval Status Report), the NEW incoming-payment approval with a two-approval stage, the inbox
// showing template and stage, and the moved menu links. Local stack only (Vite :5173 + gateway :54321 + PostgREST + Postgres).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b2-e2e.mjs [outDir]
// Cleans up what it creates (E2E templates and stages). It leaves the posted E2E incoming payments on the running DB.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b2-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
// Strict: on a phone the layout viewport itself must stay at the device width (an escaped element widens innerWidth too).
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && window.innerWidth <= (window.visualViewport?.width ?? window.innerWidth) + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
  fmgr: ['qa.finmgr@sample.test', 'local-only-8'],
  it: ['qa.it@sample.test', 'local-only-23'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
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
const flash = (page) => txt(page.locator('[data-testid=adm-flash]'));
const errText = (page) => txt(page.locator('[data-testid=adm-error]'));
async function pickCombo(page, input, text, optionText) {
  await input.click();
  await input.fill(text);
  const opt = page.locator('[role=listbox] [role=option]', { hasText: optionText }).first();
  await opt.waitFor({ timeout: 10000 });
  await opt.click();
}
const entryFromUrl = (u) => Number(new URL(u).pathname.split('/').pop());

const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
const TPL = 'E2E Incoming over 2,000';
const STAGE = 'E2E Finance pair';
async function cleanup() {
  await db.query(`UPDATE erp.approval SET superseded = true WHERE decision IS NULL AND NOT superseded AND template_id IN (SELECT template_id FROM erp.apr_template WHERE name LIKE 'E2E%')`);
  await db.query(`UPDATE erp.payment_draft SET state = 'cancelled' WHERE state = 'pending_approval' AND reason LIKE 'E2E B2%'`);
  await db.query(`DELETE FROM erp.apr_template WHERE company_code = 'ZZ99' AND name LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.apr_stage WHERE company_code = 'ZZ99' AND name LIKE 'E2E%'`);
}
await cleanup();

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

try {
  // ---------- 1. Approval Stages ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin-stages');
    await login(p, 'admin'); await settle(p);
    await p.goto(`${BASE}/m/administration?fn=7`); await settle(p);
    ok('module page: Approval Process opens the new templates screen', await seen(p.locator('a[href="/admin/approvals/templates"]')));
    await p.goto(`${BASE}/admin/approvals/stages`); await settle(p);
    await seen(p.locator('[data-testid=apr-stages]'));
    ok('stages list shows the stages made from the earlier rules', (await p.locator('[data-testid=apr-stage-row]', { hasText: 'Approval by QA · finance manager' }).count()) === 1);
    ok('the live-authorizer rule is explained on the page', (await txt(p.locator('[data-testid=apr-st-rule]'))).includes('also to requests already waiting'));
    await p.click('#apr-st-new');
    await p.fill('#apr-st-name', STAGE);
    await p.click('#apr-st-save'); await settle(p);
    ok('stage without authorizers refused with the database message', (await errText(p)) === 'Add at least one authorizer (a position or a user).', await errText(p));
    await p.selectOption('#apr-auth-pos', 'QA_FIN_MGR');
    await p.selectOption('#apr-auth-user', { label: 'QA Admin' });
    await p.fill('#apr-st-app', '2');
    await p.fill('#apr-st-desc', 'Finance manager and the admin both approve');
    ok('authorizers shown as chips (position + user)', (await p.locator('[data-testid=apr-auth-list] li').count()) === 2);
    await p.click('#apr-st-save'); await settle(p);
    ok('stage saved', (await flash(p)) === 'Stage added.', await flash(p));
    ok('new stage listed with 2 approvals needed', (await txt(p.locator('[data-testid=apr-stage-row]', { hasText: STAGE }))).includes('2 approve'));
    await p.screenshot({ path: `${OUT}/b2-stages-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 2. Approval Templates: list, form, validation ----------
  let tplId;
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin-templates');
    await login(p, 'admin'); await settle(p);
    await p.goto(`${BASE}/admin/approval-templates`); await settle(p);
    ok('old link /admin/approval-templates opens the new templates screen', p.url().includes('/admin/approvals/templates'));
    await seen(p.locator('[data-testid=apr-templates]'));
    const nTpl = (await one(`SELECT count(*)::int AS n FROM erp.apr_template WHERE company_code = 'ZZ99'`)).n;
    ok('templates list shows every ZZ99 template (the migrated rules and the sample)', nTpl >= 17 && (await p.locator('[data-testid=apr-tpl-row]').count()) === nTpl, String(nTpl));
    ok('bank change template shows its two ordered stages', (await txt(p.locator('[data-testid=apr-tpl-row]', { hasText: 'Supplier bank change' }))).includes('Approval by QA · finance manager → Approval by QA · owner'));
    ok('leave stays built-in and is explained', (await txt(p.locator('[data-testid=apr-leave]'))).includes('HR Setup'));
    await p.selectOption('#apr-f-kind', 'incoming_payment'); await settle(p);
    ok('filter by document: the inactive SAMPLE incoming-payment template', (await p.locator('[data-testid=apr-tpl-row]').count()) === 1 && (await txt(p.locator('[data-testid=apr-tpl-row]'))).includes('Inactive'));
    await p.click('#apr-tpl-new'); await settle(p);
    await seen(p.locator('#apr-t-name'));
    await p.fill('#apr-t-name', TPL);
    await p.selectOption('#apr-t-kind', 'incoming_payment');
    await p.click('#apr-t-save'); await settle(p);
    ok('template without a stage refused', (await errText(p)) === 'Add at least one approval stage.', await errText(p));
    await p.selectOption('#apr-orig-user', { label: 'QA Finance' });
    const stageId = (await one(`SELECT stage_id FROM erp.apr_stage WHERE company_code = 'ZZ99' AND name = $1`, [STAGE])).stage_id;
    await p.selectOption('#apr-t-addstage', String(stageId));
    await p.click('#apr-c-add');
    await p.selectOption('#apr-c-op-0', 'between');
    await p.fill('#apr-c-v1-0', '5000');
    await p.fill('#apr-c-v2-0', '100');
    await p.click('#apr-t-save'); await settle(p);
    ok('"between" with to < from refused', (await errText(p)) === 'For "between", enter a "to" value greater than or equal to the "from" value.', await errText(p));
    await p.selectOption('#apr-c-op-0', 'gt');
    await p.fill('#apr-c-v1-0', '2000');
    ok('summary reads originator, condition and stage', (await txt(p.locator('[data-testid=apr-summary]'))).includes('QA Finance') && (await txt(p.locator('[data-testid=apr-summary]'))).includes(STAGE));
    await p.screenshot({ path: `${OUT}/b2-template-form-en-light-1440.png`, fullPage: true });
    await p.click('#apr-t-save');
    await p.waitForURL(/\/admin\/approvals\/templates\?company=ZZ99$/, { timeout: 15000 }).catch(() => {});
    await settle(p);
    ok('template created (flash on the list)', (await flash(p)).startsWith(`Template ${TPL} created`), await flash(p));
    tplId = (await one(`SELECT template_id FROM erp.apr_template WHERE company_code = 'ZZ99' AND name = $1`, [TPL]))?.template_id;
    ok('template stored with originator, stage and condition', Boolean(tplId) && (await one(`SELECT count(*)::int AS n FROM erp.apr_template_condition WHERE template_id = $1 AND field = 'amount' AND op = 'gt' AND value1 = 2000`, [tplId])).n === 1);
    await C.close();
  }

  // ---------- 3. Incoming payment waits for the template's stage (2 approvals) ----------
  let draft;
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'fin');
    await login(p, 'fin'); await settle(p);
    await p.goto(`${BASE}/banking/payments/in`); await settle(p);
    await p.click('#new-payment-in'); await settle(p);
    await p.locator('h1', { hasText: 'New incoming payment' }).waitFor({ timeout: 15000 }).catch(() => {});
    ok('incoming payment form says payments above 2,000 need approval', (await txt(p.locator('[data-testid=bk-in-approval]'))).includes('above'), await txt(p.locator('[data-testid=bk-in-approval]')));
    await pickCombo(p, p.locator('#bk-bp'), 'C0011', 'C0011');
    const amt = 2500 + Math.floor(Math.random() * 99) / 100;
    await p.fill('#bk-transfer', String(amt));
    await p.selectOption('#bk-transfer-bank', 'BNK-AED');
    await p.waitForTimeout(800);
    await p.click('#bk-submit');
    ok('a reason is required (the template matched)', (await txt(p.locator('#bk-reason-err'))) === 'Add a reason for the approver.');
    await p.fill('#bk-reason', 'E2E B2 large receipt');
    await p.click('#bk-submit');
    await p.waitForURL(/\/banking\/payment-drafts\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    await settle(p);
    draft = entryFromUrl(p.url());
    await p.locator('[data-testid=apr-stage-note]').waitFor({ timeout: 15000 }).catch(() => {});
    ok('incoming payment waits for approval (draft page)', (await txt(p.locator('h1'))).includes('Waiting for approval'), await txt(p.locator('h1')));
    ok('draft page shows template and stage', (await txt(p.locator('[data-testid=apr-stage-note]'))).includes(TPL) && (await txt(p.locator('[data-testid=apr-stage-note]'))).includes(STAGE),
      await txt(p.locator('[data-testid=apr-stage-note]')));
    await C.close();
  }
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'fmgr');
    await login(p, 'fmgr'); await settle(p);
    await p.goto(`${BASE}/approvals`); await settle(p);
    await p.locator('[data-testid=inbox-table]').waitFor({ timeout: 10000 }).catch(() => {});
    const row = p.locator('[data-testid=inbox-table] tr', { hasText: `Payment draft ${draft}` });
    ok('inbox: the payment is waiting for the finance manager', (await row.count()) === 1);
    ok('inbox shows the template and the stage (1 of 1, 0 of 2 approvals)', (await txt(row.locator('[data-testid=inbox-template]'))) === TPL
      && (await txt(row.locator('[data-testid=inbox-stage]'))).includes(STAGE) && (await txt(row.locator('[data-testid=inbox-stage]'))).includes('0 of 2 approvals'), await txt(row));
    ok('inbox names it an incoming payment', (await txt(row)).includes('Incoming payment'));
    await p.screenshot({ path: `${OUT}/b2-inbox-en-light-1440.png`, fullPage: true });
    await row.locator('a').first().click(); await settle(p);
    await p.locator('#bk-approve').waitFor({ timeout: 10000 }).catch(() => {});
    await p.click('#bk-approve');
    await p.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
    await settle(p);
    ok('first approval: still waiting (1 of 2)', (await txt(p.locator('[data-testid=apr-stage-note]'))).includes('1 of 2 approvals'), await txt(p.locator('[data-testid=apr-stage-note]')));
    ok("the same person can't approve twice (no approve button now)", (await p.locator('#bk-approve').count()) === 0);
    await C.close();
  }
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin-approve');
    await login(p, 'admin'); await settle(p);
    await p.goto(`${BASE}/banking/payment-drafts/ZZ99/${draft}`); await settle(p);
    await p.locator('#bk-approve').waitFor({ timeout: 10000 }).catch(() => {});
    await p.click('#bk-approve');
    await p.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('second approval (the admin, a user authorizer): posted', (await txt(p.locator('[data-testid=bk-flash]'))).startsWith('Approved and paid as RC-26-'), await txt(p.locator('[data-testid=bk-flash]')));

    // ---------- 4. Approval Status Report ----------
    await p.goto(`${BASE}/admin/approvals/report?company=ZZ99&status=all&template_id=${tplId}`); await settle(p);
    await seen(p.locator('[data-testid=apr-report]'));
    const r = p.locator('[data-testid=apr-report-row]').first();
    ok('status report: the incoming payment under the template, approved', (await p.locator('[data-testid=apr-report-row]').count()) === 1 && (await txt(r)).includes(TPL) && (await txt(r)).includes('Approved') && (await txt(r)).includes('Incoming payment'), await txt(r));
    await r.locator('summary').click();
    ok('status report trail lists both votes', (await txt(r.locator('[data-testid=apr-trail]'))).includes('QA Finance Manager') && (await txt(r.locator('[data-testid=apr-trail]'))).includes('QA Admin'), await txt(r.locator('[data-testid=apr-trail]')));
    await p.screenshot({ path: `${OUT}/b2-report-en-light-1440.png`, fullPage: true });

    // ---------- 5. Deactivate, history ----------
    await p.goto(`${BASE}/admin/approvals/templates?company=ZZ99`); await settle(p);
    await p.click(`#apr-toggle-${tplId}`); await settle(p);
    ok('template deactivated from the list', (await flash(p)).startsWith(`Template ${TPL} is inactive`), await flash(p));
    await p.goto(`${BASE}/admin/approvals/templates/${tplId}?company=ZZ99`); await settle(p);
    await seen(p.locator('[data-testid=apr-history] li'));
    ok('history shows created and deactivated versions', (await p.locator('[data-testid=apr-history] li').count()) === 2 && (await txt(p.locator('[data-testid=apr-history]'))).includes('Deactivated'));
    await p.goto(`${BASE}/admin/approval-rules?company=ZZ99`); await settle(p);
    ok('earlier rule list still opens (compatibility)', await seen(p.locator('[data-testid=adm-rules]')));
    await C.close();
  }
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'it');
    await login(p, 'it'); await settle(p);
    await p.goto(`${BASE}/admin/approvals/templates?company=ZZ99`); await settle(p);
    ok('IT: templates are read-only (no New template)', await seen(p.locator('[data-testid=adm-readonly]')) && (await p.locator('#apr-tpl-new').count()) === 0);
    await C.close();
  }
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'sales');
    await login(p, 'sales'); await settle(p);
    await p.goto(`${BASE}/admin/approvals/stages`); await settle(p);
    ok("sales user can't open Approval Process", !(await seen(p.locator('[data-testid=apr-stages]'), 3000)));
    await C.close();
  }

  // ---------- 6. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin'); await settle(p);
        for (const [name, url, sel] of [['stages', '/admin/approvals/stages', 'apr-stages'], ['templates', '/admin/approvals/templates', 'apr-templates'],
          ['template', `/admin/approvals/templates/${tplId}`, 'apr-summary'], ['report', '/admin/approvals/report?status=all', 'apr-report']]) {
          await p.goto(`${BASE}${url}`); await settle(p);
          await seen(p.locator(`[data-testid=${sel}]`));
          await p.screenshot({ path: `${OUT}/b2-${name}-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
          if (w === 390) ok(`${name}: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(p));
        }
        if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${w})`, (await p.evaluate(() => document.documentElement.dir)) === 'rtl');
        await C.close();
      }
    }
  }
} catch (e) {
  ok('test run finished without an exception', false, e.stack?.split('\n').slice(0, 3).join(' | '));
} finally {
  await cleanup();
  await browser.close();
  await db.end();
}
ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
const failed = results.filter((r) => !r.pass);
console.log(`\nb2-e2e: ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

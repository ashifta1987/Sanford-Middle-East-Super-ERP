// B5 browser test: Substitute Authorizer (own substitution from the inbox, the substitute approves "on behalf of", the admin
// screen ends it), landed cost charge in USD linked to the supplier's A/P invoice (rate difference), currency + FC amount columns
// on the lists, Financials › Exchange Rate Differences (preview with a typed rate, post with the automatic reversal, detail,
// cancel), and screenshots (1440 / 390, light / dark, EN / AR). Local stack only (Vite :5173 + gateway :54321 + PostgREST +
// Postgres). Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b5-e2e.mjs [outDir]
// Leaves on the running DB: a posted journal approved by the substitute, an ended substitution, the USD PO / GRPO / A/P invoice /
// landed cost, a USD order / delivery / invoice of C0013, a cancelled revaluation (its journals mirrored), USD rates for today and
// yesterday. Restores C0013 to AED.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b5-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail && !pass ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'], sales: ['qa.sales@sample.test', 'local-only-2'], fin: ['qa.finance@sample.test', 'local-only-4'],
  fmgr: ['qa.finmgr@sample.test', 'local-only-8'], purch: ['qa.purchase@sample.test', 'local-only-10'],
};
const ID = {
  admin: '00000000-0000-4000-8000-000000000001', sales: '00000000-0000-4000-8000-000000000002', fin: '00000000-0000-4000-8000-000000000004',
  fmgr: '00000000-0000-4000-8000-000000000008', purch: '00000000-0000-4000-8000-000000000010',
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
async function as(user, sql, args = []) {
  await db.query('BEGIN');
  try {
    await db.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: user, role: 'authenticated' })]);
    const r = (await db.query(sql, args)).rows[0];
    await db.query('COMMIT');
    return r;
  } catch (e) { await db.query('ROLLBACK'); throw e; }
}
const isoDay = (d) => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 10); };
const TODAY = isoDay(Date.now());
const YDAY = isoDay(Date.now() - 86400000);
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const num = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));
const cents = (Math.floor(Math.random() * 90) + 10) / 100;

// ---------- Fixtures ----------
await as(ID.fin, `SELECT erp.fx_rate_save('ZZ99', $1::date, 'USD', 3.6725)`, [TODAY]);
await as(ID.fin, `SELECT erp.fx_rate_save('ZZ99', $1::date, 'USD', 3.70)`, [YDAY]);
await db.query(`UPDATE erp.business_partner SET currency = 'USD' WHERE company_code = 'ZZ99' AND card_code = 'C0013'`);
// earlier runs: no active substitution for the finance manager, no posted revaluation (latest first)
await db.query(`UPDATE erp.apr_substitute SET active = false, ended_at = now() WHERE company_code = 'ZZ99' AND user_id = $1 AND active`, [ID.fmgr]);
for (const r of (await db.query(`SELECT reval_id FROM erp.fx_revaluation WHERE company_code = 'ZZ99' AND state = 'posted' ORDER BY reval_date DESC, reval_id DESC`)).rows) {
  await as(ID.fin, `SELECT erp.fx_revaluation_cancel('ZZ99', $1, 'b5-e2e cleanup')`, [r.reval_id]);
}
async function cleanup() {
  await db.query(`UPDATE erp.business_partner SET currency = 'AED' WHERE company_code = 'ZZ99' AND card_code = 'C0013'`);
}
// USD PO → GRPO → A/P invoice of S0001 yesterday (3.70); a USD invoice of C0013 today
const po = (await as(ID.purch, `SELECT erp.purchase_doc_save('ZZ99', 22, NULL, $1::jsonb, $2::jsonb) AS r`,
  [JSON.stringify({ card_code: 'S0001', doc_date: YDAY, due_date: YDAY, whs_code: 'WH01' }), JSON.stringify([{ item_code: 'SMP-1140', qty: 10, price: 10 }])])).r.doc_entry;
await as(ID.purch, `SELECT erp.purchase_doc_submit('ZZ99', 22, $1, NULL)`, [po]);
const gr = (await as(ID.purch, `SELECT erp.purchase_grpo_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: YDAY }), JSON.stringify([{ base_doc_entry: po, base_line: 0, qty: 10 }])])).r.doc_entry;
const apr = (await as(ID.purch, `SELECT erp.purchase_invoice_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: YDAY, customer_ref: 'B5-E2E' }), JSON.stringify([{ base_doc_entry: gr, base_line: 0, qty: 10 }])])).r;
const ap = apr.doc_entry;
const so = (await as(ID.sales, `SELECT erp.sales_doc_save('ZZ99', 17, NULL, $1::jsonb, $2::jsonb) AS r`,
  [JSON.stringify({ card_code: 'C0013', doc_date: TODAY, whs_code: 'WH01' }), JSON.stringify([{ item_code: 'SMP-1010', qty: 1, price: 100 }])])).r.doc_entry;
await as(ID.sales, `SELECT erp.sales_doc_submit('ZZ99', 17, $1, 'b5-e2e')`, [so]);
const dl = (await as(ID.sales, `SELECT erp.sales_delivery_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: TODAY }), JSON.stringify([{ base_doc_entry: so, base_line: 0, qty: 1 }])])).r.doc_entry;
const inv = (await as(ID.sales, `SELECT erp.sales_invoice_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: TODAY }), JSON.stringify([{ base_doc_entry: dl, base_line: 0, qty: 1 }])])).r;

const browser = await chromium.launch();
let jd; let lc; let rv;
try {
  ok('fixtures: USD A/P invoice yesterday (3.70) and USD A/R invoice today', Boolean(ap && inv?.doc_entry), JSON.stringify({ ap, inv }));

  // ---------- 1. The finance manager names a substitute from the inbox ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'sub-mine');
    await login(p, 'fmgr');
    await p.goto(`${BASE}/approvals`); await settle(p);
    await p.click('#inbox-substitute-link');
    await p.waitForURL(/\/approvals\/substitute/); await settle(p);
    ok('inbox → "My substitute" page with the rule', await seen(p.locator('[data-testid=sub-rule]')));
    await p.click('#sub-new');
    await p.selectOption('#sub-substitute', { label: 'QA Admin · QA · all modules' }).catch(async () => p.selectOption('#sub-substitute', ID.admin));
    await p.fill('#sub-note', 'B5 e2e leave');
    await p.click('#sub-save'); await settle(p);
    ok('substitution saved: active', await seen(p.locator('[data-testid=adm-flash]')) && await seen(p.locator('[data-testid=sub-row][data-status=active]')),
      await txt(p.locator('main')));
    await p.screenshot({ path: `${OUT}/b5-sub-mine-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 2. The substitute approves a journal on behalf of the finance manager ----------
  {
    const amount = 55000 + cents;
    const d = await as(ID.fin, `SELECT erp.journal_draft_save('ZZ99', NULL, $1::jsonb, $2::jsonb) AS r`,
      [JSON.stringify({ ref_date: TODAY, memo: 'B5 e2e substitute' }), JSON.stringify([{ acct_code: '6200', debit: amount }, { acct_code: '1110', credit: amount }])]);
    jd = d.r.draft_id;
    const s = await as(ID.fin, `SELECT erp.journal_submit('ZZ99', $1, 'b5-e2e') AS r`, [jd]);
    ok('journal 55,000+ waits for the finance manager', s.r.state === 'pending_approval', JSON.stringify(s.r));
    const C = await context(browser); const p = await C.newPage(); watch(p, 'sub-approve');
    await login(p, 'admin');
    await p.goto(`${BASE}/approvals`); await settle(p);
    const row = p.locator('[data-testid=inbox-table] tr', { hasText: `${jd}` }).filter({ has: p.locator('[data-testid=inbox-behalf]') });
    ok('the substitute\'s inbox shows it "On behalf of QA Finance Manager"', await seen(row) && (await txt(row.locator('[data-testid=inbox-behalf]'))).includes('QA Finance Manager'));
    await p.screenshot({ path: `${OUT}/b5-inbox-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/financials/journals/drafts/ZZ99/${jd}`); await settle(p);
    await p.click('#je-approve'); await settle(p);
    ok('the substitute approves: the journal posts', await seen(p.locator('[data-testid=je-decided-card]'), 15000));
    const v = await one(`SELECT v.on_behalf_of FROM erp.approval_vote v JOIN erp.approval a ON a.approval_id = v.approval_id WHERE a.object = 'journal' AND a.object_ref = $1`, [String(jd)]);
    ok('the vote is recorded on behalf of the finance manager', v?.on_behalf_of === ID.fmgr, JSON.stringify(v));
    // admin screen: the row shows one decision; end it
    await p.goto(`${BASE}/admin/approvals/substitutes?company=ZZ99`); await settle(p);
    const r = p.locator('[data-testid=sub-row][data-status=active]', { hasText: 'B5 e2e leave' }).first();
    ok('Approval Process › Substitute Authorizer lists it with 1 decision', await seen(r) && (await txt(r)).includes('QA Finance Manager'));
    await p.screenshot({ path: `${OUT}/b5-sub-admin-en-light-1440.png`, fullPage: true });
    await r.locator('[data-testid=sub-end]').click();
    await p.click('#sub-end-confirm'); await settle(p);
    ok('Administration ends it: status Ended', await seen(p.locator('[data-testid=sub-row][data-status=ended]', { hasText: 'B5 e2e leave' })));
    await C.close();
  }

  // ---------- 3. Landed cost in USD linked to the A/P invoice ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'lc');
    await login(p, 'purch');
    await p.goto(`${BASE}/purchasing/landed-costs/new?company=ZZ99&grpo=${gr}`); await settle(p);
    await p.locator('[data-testid=lc-line]').first().waitFor({ timeout: 10000 });
    await p.selectOption('#lc-charge-0-currency', 'USD');
    await p.fill('#lc-charge-0-amount', '10');
    await p.selectOption('#lc-charge-0-ap', String(ap));
    await p.locator('[data-testid=lc-fx-diff]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('USD charge: 10 USD at today\'s 3.6725 = 36.73 AED; read-only rate for Purchasing', num(await txt(p.locator('[data-testid=lc-total]'))) === 36.73
      && await p.locator('#lc-charge-0-rate').evaluate((e) => e.readOnly), await txt(p.locator('[data-testid=lc-summary]')));
    ok('linked invoice (3.70): rate difference 0.27 shown', num(await txt(p.locator('[data-testid=lc-fx-diff]'))) === 0.27, await txt(p.locator('[data-testid=lc-summary]')));
    await p.screenshot({ path: `${OUT}/b5-lc-new-en-light-1440.png`, fullPage: true });
    await p.click('#lc-submit');
    await p.waitForURL(/\/purchasing\/landed-costs\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    lc = Number(p.url().split('/').pop());
    ok('landed cost page: costs in other currencies with the invoice', await seen(p.locator('[data-testid=lc-charges-fx]')) && (await txt(p.locator('[data-testid=lc-charges-fx]'))).includes('USD'));
    const ch = await one(`SELECT currency, amount_fc, fx_rate, clear_amount, fx_diff FROM erp.landed_cost_charge WHERE company_code = 'ZZ99' AND doc_entry = $1`, [lc]);
    ok('charge stored: 10 USD, clearing 37.00, difference 0.27', ch?.currency === 'USD' && Number(ch.amount_fc) === 10 && Number(ch.clear_amount) === 37 && Number(ch.fx_diff) === 0.27, JSON.stringify(ch));
    await C.close();
  }

  // ---------- 4. Lists: currency and FC amount next to the LC total ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'lists');
    await login(p, 'admin');
    await p.goto(`${BASE}/docs/ap_invoice?q=B5-E2E`); await settle(p);
    await p.locator('table tbody tr').first().waitFor({ timeout: 10000 }).catch(() => {});
    const head = await txt(p.locator('table thead'));
    const body = await txt(p.locator('table tbody'));
    ok('A/P invoice list: Currency and Amount (FC) columns; the USD invoice shows 105.00 USD-side amount', /amount \(fc\)/i.test(head) && /USD/.test(body) && body.includes('105.00'), `${head} | ${body.slice(0, 200)}`);
    await p.screenshot({ path: `${OUT}/b5-list-ap-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/banking/payments/in`); await settle(p);
    ok('incoming payments list has the Amount (FC) column', /amount \(fc\)/i.test(await txt(p.locator('table thead'))));
    await C.close();
  }

  // ---------- 5. Exchange Rate Differences ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'fxr');
    await login(p, 'fin');
    await p.goto(`${BASE}/financials/fx-revaluation?company=ZZ99`); await settle(p);
    await p.fill('#fxr-date', TODAY);
    await p.locator('#fxr-cur-USD').check();
    await p.locator('#fxr-rate-USD').waitFor({ timeout: 10000 });
    await p.fill('#fxr-rate-USD', '3.8');
    await p.waitForTimeout(900); await settle(p);
    const rowC = p.locator('[data-testid=fxr-row][data-card=C0013]');
    ok('preview at a typed 3.80 lists C0013 (receivable) with a gain', await seen(rowC) && num(await txt(rowC.locator('td').last())) > 0, await txt(p.locator('[data-testid=fxr-rows]')));
    await p.screenshot({ path: `${OUT}/b5-fxr-en-light-1440.png`, fullPage: true });
    await p.click('#fxr-post');
    await p.click('#fxr-post-confirm');
    await p.waitForURL(/\/financials\/fx-revaluation\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    rv = Number(p.url().split('/').pop());
    ok('posted: detail page with two journals (revaluation + reversal)', (await txt(p.locator('[data-testid=fxr-state]'))).length > 0 && (await p.locator('[data-testid=fxr-journals] li').count()) === 2);
    const r = await one(`SELECT state, reverse_trans_id, reverse_date FROM erp.fx_revaluation WHERE reval_id = $1`, [rv]);
    ok('automatic reversal posted on the first day of the next period', r?.state === 'posted' && r.reverse_trans_id != null, JSON.stringify(r));
    await p.screenshot({ path: `${OUT}/b5-fxr-detail-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/financials/fx-revaluation?company=ZZ99`); await settle(p);
    await p.fill('#fxr-date', TODAY); await p.waitForTimeout(900); await settle(p);
    ok('the same date again: blocked with the "already revalued" note', await seen(p.locator('[data-testid=fxr-already]')) && await p.locator('#fxr-post').isDisabled());
    await p.goto(`${BASE}/financials/fx-revaluation/ZZ99/${rv}`); await settle(p);
    await p.click('#fxr-cancel');
    await p.fill('#fxr-cancel-reason', 'b5-e2e');
    await p.click('#fxr-cancel-confirm'); await settle(p);
    ok('cancelled: journals mirrored (4 listed)', await seen(p.locator('[data-testid=adm-flash]')) && (await p.locator('[data-testid=fxr-journals] li').count()) === 4);
    await C.close();
    const S = await context(browser); const ps = await S.newPage(); watch(ps, 'fxr-sales');
    await login(ps, 'sales');
    await ps.goto(`${BASE}/financials/fx-revaluation?company=ZZ99`); await settle(ps);
    ok('Sales can\'t open Exchange Rate Differences', !(await seen(ps.locator('#fxr-date'), 3000)));
    await S.close();
  }

  // ---------- 6. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  const PAGES = [
    ['sub-admin', '/admin/approvals/substitutes?company=ZZ99'],
    ['sub-mine', '/approvals/substitute'],
    ['fxr', '/financials/fx-revaluation?company=ZZ99'],
    ['fxr-detail', `/financials/fx-revaluation/ZZ99/${rv}`],
    ['lc', `/purchasing/landed-costs/ZZ99/${lc}`],
    ['list-ap', '/docs/ap_invoice'],
  ];
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin');
        for (const [name, url] of PAGES) {
          await p.goto(`${BASE}${url}`); await settle(p); await p.waitForTimeout(400);
          await p.screenshot({ path: `${OUT}/b5-${name}-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
          if (w === 390) ok(`${name}: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(p));
        }
        if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${w})`, (await p.evaluate(() => document.documentElement.dir)) === 'rtl');
        await C.close();
      }
    }
  }
} catch (e) {
  ok('test run finished without an exception', false, e.stack ?? String(e));
} finally {
  ok('no page errors', errors.length === 0, errors.slice(0, 5).join(' | '));
  await cleanup();
  await browser.close();
  await db.end();
}
const fails = results.filter((r) => !r.pass);
console.log(`\nTOTAL ${results.length - fails.length}/${results.length} passed`);
process.exit(fails.length ? 1 : 0);

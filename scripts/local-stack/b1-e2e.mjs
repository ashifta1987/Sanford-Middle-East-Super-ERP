// B1 browser test: pilot company AE05, Choose/Create Company, Document Numbering (several series, user defaults, series
// picker on new documents, gap-free numbers under concurrency) and the decided rule changes, against the local stack
// (Vite :5173 + gateway :54321 + PostgREST + Postgres, sample company ZZ99 + AE05 for qa.it only).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b1-e2e.mjs [outDir]
// Cleans up what it creates (E2E series and user defaults, company ZE2E, the concurrency series). It leaves posted
// documents on the running DB (a service invoice, credit memos, an invoice request), like the earlier phase tests.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b1-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  salesmgr: ['qa.salesmgr@sample.test', 'local-only-7'],
  it: ['qa.it@sample.test', 'local-only-23'],
  purchase: ['qa.purchase@sample.test', 'local-only-10'],
  stock: ['qa.stock@sample.test', 'local-only-13'],
  prod: ['qa.prod@sample.test', 'local-only-24'],
  svc: ['qa.service@sample.test', 'local-only-25'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
};
const UID = { sales: '00000000-0000-4000-8000-000000000002' };
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

const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
const PFX = `SE${Date.now().toString(36).slice(-4).toUpperCase()}-`;
async function cleanup() {
  await db.query(`DELETE FROM erp.series_user_default WHERE series_id IN (SELECT series_id FROM erp.doc_series WHERE name LIKE 'E2E%')`);
  await db.query(`DELETE FROM erp.series_user_default WHERE user_id = $1`, [UID.sales]);
  await db.query(`DELETE FROM erp.doc_series WHERE name LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.user_company WHERE company_code = 'ZE2E'`);
  await db.query(`DELETE FROM sap._company WHERE company_code = 'ZE2E'`);
  await db.query(`DELETE FROM erp.company WHERE company_code = 'ZE2E'`);
}
await cleanup();

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

try {
  // ---------- 0. Gap-free numbering under concurrency (two database sessions) ----------
  {
    const s = await one(`INSERT INTO erp.doc_series (company_code, obj_type, name, prefix, pad) VALUES ('ZZ99', 59, 'E2E concurrency', $1, 4) RETURNING series_id`, [`${PFX}C`]);
    const A = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
    const B = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
    await A.connect(); await B.connect();
    const take = (c) => c.query(`SELECT set_config('erp.series', $1, true), erp._series_take('ZZ99', 59)->>'num' AS n`, [String(s.series_id)]).then((r) => Number(r.rows[0].n));
    await A.query('BEGIN'); await B.query('BEGIN');
    const a1 = await take(A);
    let bDone = false;
    const bP = take(B).then((n) => { bDone = true; return n; });
    await new Promise((r) => setTimeout(r, 600));
    ok('concurrency: a second session waits for the series lock', !bDone);
    await A.query('ROLLBACK');
    const b1 = await bP;
    ok('concurrency: a rolled-back number is given to the next document (no gap)', a1 === 1 && b1 === 1, `${a1} / ${b1}`);
    await B.query('COMMIT');
    await A.query('BEGIN'); await B.query('BEGIN');
    const a2 = await take(A);
    const bP2 = take(B);
    await A.query('COMMIT');
    const b2 = await bP2; await B.query('COMMIT');
    ok('concurrency: committed numbers follow one another, never twice', a2 === 2 && b2 === 3, `${a2} / ${b2}`);
    await A.end(); await B.end();
    await db.query('DELETE FROM erp.doc_series WHERE series_id = $1', [s.series_id]);
  }

  // ---------- 1. AE05 for IT: go-live checklist and companies ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'it');
    await login(p, 'it'); await settle(p);
    await p.goto(`${BASE}/admin/go-live`); await settle(p);
    ok('AE05 shows in the go-live checklist (qa.it)', await seen(p.locator('[data-company=AE05]', { hasText: 'UAE - ATMM GENERAL TRADING LLC' })));
    await p.screenshot({ path: `${OUT}/b1-golive-ae05-it-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/admin/companies`); await settle(p);
    ok('Companies lists AE05 · UAE - ATMM GENERAL TRADING LLC', await seen(p.locator('[data-testid=cmp-row][data-code=AE05]', { hasText: 'UAE - ATMM GENERAL TRADING LLC' })));
    ok('IT is read-only on Companies (no New company)', (await p.locator('#cmp-new').count()) === 0 && await seen(p.locator('[data-testid=adm-readonly]')));
    ok('AE05: licence type "To be confirmed", no series yet', (await txt(p.locator('[data-testid=cmp-row][data-code=AE05]'))).includes('To be confirmed'));
    await p.screenshot({ path: `${OUT}/b1-companies-it-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/admin/numbering?company=AE05`); await settle(p);
    ok('AE05 numbering: every document type "Not set up"', (await p.locator('[data-testid=adm-series-row]').count()) >= 30 && (await txt(p.locator('[data-testid=num-types]'))).includes('Not set up'));
    await C.close();
  }

  // ---------- 2. Admin: create a company, Document Numbering ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin');
    await login(p, 'admin'); await settle(p);
    await p.goto(`${BASE}/m/administration`); await settle(p);
    await p.goto(`${BASE}/admin/companies`); await settle(p);
    await p.click('#cmp-new'); await settle(p);
    await p.fill('#cmp-company_code', 'ZE2E');
    await p.fill('#cmp-legal_name', 'E2E Test Trading LLC (test)');
    await p.fill('#cmp-tax_id', '123');
    await p.click('#cmp-save'); await settle(p);
    ok('company form shows the server message (TRN)', (await errText(p)).includes('A UAE TRN has 15 digits'));
    await p.fill('#cmp-tax_id', '');
    await p.screenshot({ path: `${OUT}/b1-company-new-en-light-1440.png`, fullPage: true });
    await p.click('#cmp-save'); await settle(p);
    ok('company created, next steps shown', await seen(p.locator('[data-testid=cmp-created]', { hasText: 'ZE2E' })));
    const reg = await one(`SELECT (SELECT count(*) FROM sap._company WHERE company_code = 'ZE2E')::int AS r, (SELECT count(*) FROM erp.user_company WHERE company_code = 'ZE2E')::int AS u`);
    ok('new company is in the migration register and the creator has access', reg.r === 1 && reg.u === 1, JSON.stringify(reg));

    await p.goto(`${BASE}/admin/numbering`); await settle(p);
    ok('numbering matrix lists the document types', (await p.locator('[data-testid=adm-series-row]').count()) >= 30);
    await p.click('#num-type-17'); await settle(p);
    ok('choosing Sales Order opens its default series', await seen(p.locator('[data-testid=num-form]')) && (await p.inputValue('#adm-n-prefix')) === 'SO-26-');
    await p.click('#num-new');
    await p.fill('#adm-n-name', 'E2E Dubai showroom');
    await p.fill('#adm-n-prefix', PFX);
    await p.fill('#adm-n-pad', '4');
    await p.fill('#adm-n-last', '50');
    ok('preview shows the next document number', (await txt(p.locator('[data-testid=num-preview]'))) === `${PFX}0001`);
    await p.click('#adm-n-save'); await settle(p);
    ok('series saved (flash names the series)', (await flash(p)).includes('E2E Dubai showroom'), await flash(p));
    ok('the series grid shows two Sales Order series', (await p.locator('[data-testid=num-series-row]').count()) >= 2);
    const sid = (await one(`SELECT series_id FROM erp.doc_series WHERE company_code = 'ZZ99' AND name = 'E2E Dubai showroom'`))?.series_id;
    await p.click('#num-new');
    await p.fill('#adm-n-name', 'E2E clash');
    await p.fill('#adm-n-prefix', 'PO-26-');
    await p.click('#adm-n-save'); await settle(p);
    ok('a prefix of another series is refused with the server message', (await errText(p)).includes('Prefix PO-26- is already used by Purchase Order'));
    await p.click('[data-testid=num-form] button:has-text("Cancel")');
    await p.selectOption(`#num-ud-${UID.sales}`, String(sid)); await settle(p);
    ok('admin sets qa.sales’ default Sales Order series', (await flash(p)).includes('Default series for Sales Order saved') && Boolean(await one('SELECT 1 FROM erp.series_user_default WHERE user_id = $1 AND obj_type = 17 AND series_id = $2', [UID.sales, sid])));
    await p.screenshot({ path: `${OUT}/b1-numbering-en-light-1440.png`, fullPage: true });

    await p.goto(`${BASE}/admin/approval-templates`); await settle(p);
    ok('approval templates: credit memo template with the ZZ99 sample rule', await seen(p.locator('[data-rule=credit_memo_amount] [data-testid=adm-rule-row]')));
    await p.goto(`${BASE}/purchasing/setup`); await settle(p);
    ok('purchasing setup: "QC must pass" is always on', await p.locator('#ps-qc').isChecked().catch(() => false) && await p.locator('#ps-qc').isDisabled().catch(() => false));
    await p.goto(`${BASE}/production/moulds/new`); await settle(p);
    ok('new mould: 50,000 shots, 500,000 rated life, warn at 80 %', (await p.inputValue('#res-maint_every_shots')) === '50000' && (await p.inputValue('#res-rated_life_shots')) === '500000' && (await p.inputValue('#res-warn_pct')) === '80');
    await p.goto(`${BASE}/service/setup`); await settle(p);
    ok('service setup: who may issue spare parts (default: service manager position)', (await txt(p.locator('[data-testid=ss-issuers-rule]'))).includes('service manager position'));
    await p.screenshot({ path: `${OUT}/b1-service-setup-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 3. qa.sales: the picker defaults to the user's series; numbers from it ----------
  let invEntry = null;
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'sales');
    await login(p, 'sales'); await settle(p);
    await p.goto(`${BASE}/docs/sales_order/new`); await settle(p);
    const picker = p.locator('[data-testid=series-picker][data-obj="17"] select');
    await picker.waitFor({ timeout: 10000 }).catch(() => {});
    const opt = await picker.locator('option:checked').innerText().catch(() => '');
    ok('order form: series picker defaults to the user’s series', opt.includes('E2E Dubai showroom') && opt.includes('your default'), opt);
    await pickCombo(p, p.locator('#so-card_code'), 'C0011', 'C0011');
    const line = p.locator('[data-testid=so-line]').nth(0);
    await pickCombo(p, line.locator('input[role=combobox]'), 'SMP-1010', 'SMP-1010');
    await line.locator('input[id$="-qty"]').fill('1');
    await p.screenshot({ path: `${OUT}/b1-order-picker-en-light-1440.png`, fullPage: true });
    await p.click('#so-save');
    await p.waitForURL(/\/docs\/sales_order\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    ok('order numbered from the user’s default series', await seen(p.locator('h1', { hasText: `${PFX}0001` }), 15000), await txt(p.locator('h1')));
    await p.goto(`${BASE}/docs/sales_order/new`); await settle(p);
    await p.locator('[data-testid=series-picker][data-obj="17"] select').selectOption({ label: /Primary/ }).catch(async () => {
      const v = await p.locator('[data-testid=series-picker][data-obj="17"] option', { hasText: 'Primary' }).getAttribute('value');
      await p.locator('[data-testid=series-picker][data-obj="17"] select').selectOption(v);
    });
    await pickCombo(p, p.locator('#so-card_code'), 'C0011', 'C0011');
    const l2 = p.locator('[data-testid=so-line]').nth(0);
    await pickCombo(p, l2.locator('input[role=combobox]'), 'SMP-1010', 'SMP-1010');
    await l2.locator('input[id$="-qty"]').fill('1');
    await p.click('#so-save');
    await p.waitForURL(/\/docs\/sales_order\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    ok('a series picked on the form wins (SO-26-…)', await seen(p.locator('h1', { hasText: /SO-26-\d+/ }), 15000), await txt(p.locator('h1')));

    // Direct service invoice → credit memo above 5,000 AED → request
    await p.goto(`${BASE}/docs/ar_invoice/new?company=ZZ99`); await settle(p);
    await pickCombo(p, p.locator('#sc-card_code'), 'C0011', 'C0011');
    await p.click('#svc-add');
    const sl = p.locator('[data-testid=svc-line]').last();
    await pickCombo(p, sl.locator('input[role=combobox]'), 'SMP-SVC-01', 'SMP-SVC-01');
    await sl.locator('input[id$="-price"]').fill('8000');
    ok('invoice form: series picker for A/R invoices', await seen(p.locator('[data-testid=series-picker][data-obj="13"]')));
    await p.click('#sc-submit');
    await p.waitForURL(/\/docs\/ar_invoice\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    invEntry = Number((p.url().match(/\/(\d+)$/) ?? [])[1]) || null;
    ok('service invoice without a discount is created at once', Boolean(invEntry), p.url());
    await p.goto(`${BASE}/docs/ar_credit_note/new?company=ZZ99&invoice=${invEntry}`); await settle(p);
    await p.fill('#sc-approval-reason', 'Wrong price billed (e2e)');
    await p.click('#sc-submit');
    await p.waitForURL(/\/sales\/requests\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    await settle(p);
    ok('credit memo above the limit goes for approval (request page)', /\/sales\/requests\/ZZ99\/\d+/.test(p.url()) && await seen(p.locator('[role=status]', { hasText: 'Sent for approval' })));
    ok('request shows why it needs approval', (await txt(p.locator('[data-testid=sreq-checks]'))).includes('above the limit of 5,000.00 AED'));
    ok('requester can’t approve, may cancel', (await p.locator('#sreq-approve').count()) === 0 && (await p.locator('#sreq-cancel').count()) === 1);
    await p.screenshot({ path: `${OUT}/b1-request-sales-en-light-1440.png`, fullPage: true });
    var reqUrl = p.url();

    // Service invoice with a discount above the sales-order limit → request
    await p.goto(`${BASE}/docs/ar_invoice/new?company=ZZ99`); await settle(p);
    await pickCombo(p, p.locator('#sc-card_code'), 'C0011', 'C0011');
    await p.click('#svc-add');
    const s2 = p.locator('[data-testid=svc-line]').last();
    await pickCombo(p, s2.locator('input[role=combobox]'), 'SMP-SVC-01', 'SMP-SVC-01');
    await s2.locator('input[id$="-price"]').fill('100');
    await s2.locator('input[id$="-disc"]').fill('15');
    await p.click('#sc-submit');
    await p.waitForURL(/\/sales\/requests\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    await settle(p);
    ok('service invoice above the discount limit goes for approval (same template as orders)', (await txt(p.locator('[data-testid=sreq-checks]'))).includes('Discount 15% is above your limit of 10%'));
    await p.click('#sreq-cancel'); await settle(p);
    ok('requester cancels the invoice request', await seen(p.locator('[data-testid=sreq-state]', { hasText: 'Withdrawn' })));
    await C.close();

    const M = await context(browser);
    const m = await M.newPage(); watch(m, 'salesmgr');
    await login(m, 'salesmgr'); await settle(m);
    await m.goto(`${BASE}/approvals`); await settle(m);
    ok('sales manager’s inbox lists the credit memo request', await seen(m.locator('a', { hasText: /^REQ-\d+$/ })));
    await m.goto(reqUrl); await settle(m);
    await m.click('#sreq-approve'); await settle(m);
    ok('approval creates the credit memo (CN-26-…)', await seen(m.locator('[role=status]', { hasText: /Approved\. CN-26-\d+ is created/ })));
    ok('request links to the created credit memo', await seen(m.locator('a', { hasText: /^CN-26-\d+$/ })));
    await m.screenshot({ path: `${OUT}/b1-request-approved-en-light-1440.png`, fullPage: true });
    await M.close();
  }

  // ---------- 4. The picker is on the other new-document forms ----------
  {
    const forms = [
      ['purchase', '/docs/purchase_order/new', 22], ['stock', '/inventory/goods-receipt/new', 59], ['stock', '/inventory/transfer/new', 67],
      ['fin', '/banking/payments/out/new', 46], ['prod', '/production/orders/new', 202], ['svc', '/service/calls/new', 191], ['admin', '/bp/new', 2001],
    ];
    let last = null; let C = null; let p = null;
    for (const [who, path, obj] of forms) {
      if (who !== last) { if (C) await C.close(); C = await context(browser); p = await C.newPage(); watch(p, who); await login(p, who); await settle(p); last = who; }
      await p.goto(`${BASE}${path}`); await settle(p);
      ok(`series picker on ${path}`, await seen(p.locator(`[data-testid=series-picker][data-obj="${obj}"]`), 12000));
    }
    if (C) await C.close();
  }

  // ---------- 5. a10 numbering flow still works on the new screen (lead codes) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin2');
    await login(p, 'admin'); await settle(p);
    await p.goto(`${BASE}/admin/numbering`); await settle(p);
    const lead = await one(`SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 2003`);
    await p.locator('[data-testid=adm-series-row][data-obj="2003"] button').click();
    await p.fill('#adm-n-next', String(lead.next_num + 1));
    await p.click('#adm-n-save'); await settle(p);
    ok('numbering moves forward (Lead code)', (await flash(p)).includes('Lead code') && (await one(`SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 2003`)).next_num === lead.next_num + 1);
    await p.locator('[data-testid=adm-series-row][data-obj="2003"] button').click();
    await p.fill('#adm-n-next', String(lead.next_num));
    await p.click('#adm-n-save'); await settle(p);
    ok('numbering can’t go back', (await errText(p)).includes('Numbers only move forward'));
    await C.close();
  }

  // ---------- 6. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin'); await settle(p);
        await p.goto(`${BASE}/admin/numbering`); await settle(p);
        await p.click('#num-type-17').catch(() => {}); await settle(p);
        await p.screenshot({ path: `${OUT}/b1-numbering-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
        if (w === 390) ok(`numbering: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(p));
        await p.goto(`${BASE}/admin/companies`); await settle(p);
        await p.screenshot({ path: `${OUT}/b1-companies-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
        if (w === 390) ok(`companies: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(p));
        await p.goto(`${BASE}/admin/companies/ZE2E`); await settle(p);
        await p.screenshot({ path: `${OUT}/b1-company-form-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
        if (lang === 'en' && theme === 'light') {
          await p.goto(`${BASE}/docs/sales_order/new`); await settle(p);
          await p.screenshot({ path: `${OUT}/b1-order-form-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
          if (w === 390) ok('order form with the series picker: no horizontal scroll at 390 px', await noHScroll(p));
        }
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
console.log(`\nb1-e2e: ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

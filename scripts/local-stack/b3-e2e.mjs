// B3 browser test: G/L Account Determination by tab (editable grid, validation message, item group accounts), Warehouses
// (create, tabs, bins, numbering, accounts hidden without Financials), Item Groups, Goods Receipt/Issue Reasons, Landed Cost
// Types, Resources, bank statement import with a saved column mapping + decimal comma + the reference matching rule, and the
// B2 fix (a partial rejection says the document is still waiting). Local stack only (Vite :5173 + gateway :54321 + PostgREST
// + Postgres). Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b3-e2e.mjs [outDir]
// Cleans up what it creates, except the imported E2E statement and the E2E incoming payments (permanent journals).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b3-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail && !pass ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && window.innerWidth <= (window.visualViewport?.width ?? window.innerWidth) + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'], fin: ['qa.finance@sample.test', 'local-only-4'], fmgr: ['qa.finmgr@sample.test', 'local-only-8'],
  purch: ['qa.purchase@sample.test', 'local-only-10'], stock: ['qa.stock@sample.test', 'local-only-13'], prod: ['qa.prod@sample.test', 'local-only-24'],
};
const ID = {
  admin: '00000000-0000-4000-8000-000000000001', fin: '00000000-0000-4000-8000-000000000004', fmgr: '00000000-0000-4000-8000-000000000008',
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
const flash = (page) => txt(page.locator('[data-testid=stp-flash]'));
const errText = (page) => txt(page.locator('[data-testid=stp-error]'));
async function pickCombo(page, input, text, optionText) {
  await input.click();
  await input.fill(text);
  const opt = page.locator('[role=listbox] [role=option]', { hasText: optionText }).first();
  await opt.waitFor({ timeout: 10000 });
  await opt.click();
}
const waitFlash = (page, sel = '[data-testid=stp-flash]') => page.locator(sel).waitFor({ timeout: 10000 }).catch(() => {});

const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
/** Call an API function as a test user (the claims make erp.current_user_id() that user). */
async function as(user, sql, args = []) {
  await db.query('BEGIN');
  try {
    await db.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: user, role: 'authenticated' })]);
    const r = (await db.query(sql, args)).rows[0];
    await db.query('COMMIT');
    return r;
  } catch (e) { await db.query('ROLLBACK'); throw e; }
}
const RND = String(Date.now()).slice(-4);
const WHS = `E2E${RND}`;
async function cleanup() {
  await db.query(`DELETE FROM erp.gl_determination WHERE company_code = 'ZZ99' AND ((area = 'general' AND posting_key = 'rounding') OR (area = 'resources' AND posting_key = 'resource_cost'))`);
  await db.query(`DELETE FROM erp.gl_determination_group WHERE company_code = 'ZZ99'`);
  await db.query(`DELETE FROM erp.gl_determination_whs WHERE company_code = 'ZZ99'`);
  await db.query(`DELETE FROM erp.warehouse_series_default WHERE company_code = 'ZZ99' AND whs_code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.bin_location WHERE company_code = 'ZZ99' AND whs_code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.inventory_reason WHERE company_code = 'ZZ99' AND code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.landed_cost_code WHERE company_code = 'ZZ99' AND code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code LIKE 'E2E%'`);
  await db.query(`DELETE FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = 103`);
  await db.query(`DELETE FROM erp.warranty_rule WHERE company_code = 'ZZ99' AND group_code = 103 AND item_code IS NULL`);
  await db.query(`DELETE FROM erp.bank_statement_format WHERE company_code = 'ZZ99' AND mapping->>'date' = 'Value date'`);
  await db.query(`UPDATE erp.approval SET superseded = true WHERE decision IS NULL AND NOT superseded AND template_id IN (SELECT template_id FROM erp.apr_template WHERE name LIKE 'E2E B3%')`);
  await db.query(`UPDATE erp.payment_draft SET state = 'cancelled' WHERE state = 'pending_approval' AND reason LIKE 'E2E B3%'`);
  await db.query(`DELETE FROM erp.apr_template WHERE company_code = 'ZZ99' AND name LIKE 'E2E B3%'`);
  await db.query(`DELETE FROM erp.apr_stage WHERE company_code = 'ZZ99' AND name LIKE 'E2E B3%'`);
}
await cleanup();

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

try {
  // ---------- 1. G/L Account Determination (Finance) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'fin-gl');
    await login(p, 'fin');
    await p.goto(`${BASE}/financials/gl-determination`); await settle(p);
    await p.locator('[data-testid=gld-table]').waitFor({ timeout: 15000 }).catch(() => {});
    ok('nine SAP tabs: Sales … General', (await p.locator('#gld-tab [role=tab]').count()) === 9 && (await txt(p.locator('#gld-tab'))).includes('Landed costs / price difference'));
    ok('Sales tab lists receivables and revenue with their accounts', (await p.locator('#gld-sales-revenue').inputValue()).startsWith('4100'));
    await p.screenshot({ path: `${OUT}/b3-gl-sales-en-light-1440.png`, fullPage: true });
    await p.click('#gld-tab-general'); await settle(p);
    ok('tab kept in the URL', new URL(p.url()).searchParams.get('tab') === 'general');
    ok('Save is disabled until something changes', await p.locator('#gld-save').isDisabled());
    await pickCombo(p, p.locator('#gld-general-rounding'), '6800', '6800');
    ok('changed row is marked and Save counts it', (await txt(p.locator('#gld-save'))).includes('1 change'));
    await p.click('#gld-save'); await waitFlash(p);
    ok('saved: flash and the account is in the database', /Saved\. 1 account changed/.test(await flash(p))
      && (await one(`SELECT acct_code FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'rounding'`))?.acct_code === '6800', await flash(p));
    await p.click('#gld-tab-sales'); await settle(p);
    await pickCombo(p, p.locator('#gld-sales-revenue'), '1200', '1200');
    await p.click('#gld-save');
    await p.locator('[data-testid=stp-error]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('a control account on Revenue is refused with the server message', (await errText(p)).startsWith('Revenue: Account 1200 · Accounts receivable is a control account'), await errText(p));
    await p.click('#gld-discard'); await p.waitForTimeout(300);
    ok('discard puts the saved account back', (await p.locator('#gld-sales-revenue').inputValue()).startsWith('4100'));
    await p.click('#gld-tab-banking'); await settle(p);
    ok('Banking tab shows the cash account kept in Banking setup', (await p.locator('#gld-banking-cash').inputValue()).startsWith('1105'));
    // item group accounts
    await p.selectOption('#gld-ov-level', 'group');
    await p.selectOption('#gld-ov-ref', '101');
    await p.locator('[data-testid=gld-ov-table]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('item group panel shows the next-level account as a hint', (await p.locator('#gld-ov-inventory-cogs').getAttribute('placeholder')) === 'Next level: 5100');
    await pickCombo(p, p.locator('#gld-ov-inventory-cogs'), '5210', '5210');
    await p.click('#gld-ov-save'); await waitFlash(p);
    ok('item group 101 COGS saved', /Saved 1 account for 101/.test(await flash(p))
      && (await one(`SELECT acct_code FROM erp.gl_determination_group WHERE company_code = 'ZZ99' AND group_code = 101 AND posting_key = 'cogs'`))?.acct_code === '5210', await flash(p));
    await p.click('#gld-tab-inventory'); await settle(p);
    ok('Inventory tab counts the override on COGS', (await txt(p.locator('[data-testid=gld-row][data-key="inventory/cogs"]'))).includes('1 override'));
    await p.screenshot({ path: `${OUT}/b3-gl-inventory-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 2. Warehouses (Inventory user) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'stock-whs');
    await login(p, 'stock');
    await p.goto(`${BASE}/inventory/setup`); await settle(p);
    ok('Inventory Setup links to the new setup windows', await seen(p.locator('#inv-whs-link')) && await seen(p.locator('#inv-ig-link')) && await seen(p.locator('#inv-rs-link')));
    await p.click('#inv-whs-link'); await settle(p);
    await p.locator('[data-testid=whs-list]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('warehouse list shows the ZZ99 warehouses', (await p.locator('[data-testid=whs-list] tbody tr').count()) >= 4);
    await p.click('#whs-new'); await settle(p);
    await p.fill('#whs-whs_code', WHS.toLowerCase());
    await p.fill('#whs-name', 'E2E showroom');
    await p.fill('#whs-city', 'Dubai');
    await p.fill('#whs-country', 'XX1');
    await p.click('#whs-save');
    await p.locator('[data-testid=stp-error]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('bad country refused with the server message', (await errText(p)) === 'Enter the country as a 2-letter code, e.g. AE.', await errText(p));
    await p.fill('#whs-country', 'AE');
    await p.click('#whs-save');
    await p.waitForURL(new RegExp(`/inventory/warehouses/ZZ99/${WHS}$`), { timeout: 15000 }).catch(() => {});
    await waitFlash(p);
    ok('warehouse created (code upper case), page opens on it', (await flash(p)) === `Warehouse ${WHS} created.` && (await one(`SELECT origin FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code = $1`, [WHS]))?.origin === 'erp', await flash(p));
    ok('four tabs: General, Accounting, Bin locations, Numbering', (await p.locator('#whs-tab [role=tab]').count()) === 4);
    await p.click('#whs-tab-accounting');
    ok('Accounting tab: hidden without Financials', await seen(p.locator('[data-testid=whs-acct-hidden]')));
    await p.click('#whs-tab-bins');
    await p.click('#whs-bins-on'); await waitFlash(p); await settle(p);
    await p.locator('#whs-bin-code').waitFor({ timeout: 10000 }).catch(() => {});
    await p.fill('#whs-bin-code', `${WHS}-a-01`);
    await p.click('#whs-bin-add'); await settle(p); await p.waitForTimeout(300);
    ok('bins switched on and a bin added', (await one(`SELECT bins_enabled FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code = $1`, [WHS]))?.bins_enabled === true
      && (await p.locator('[data-testid=whs-bins] tbody tr').count()) === 1);
    await p.click('#whs-tab-numbering');
    await p.locator('[data-testid=whs-series]').waitFor({ timeout: 10000 }).catch(() => {});
    const giOpt = await p.locator('#whs-ser-60 option').nth(1).getAttribute('value');
    await p.selectOption('#whs-ser-60', giOpt);
    await p.locator('[data-testid=stp-flash]', { hasText: 'Default series' }).waitFor({ timeout: 10000 }).catch(() => {});
    ok('default goods issue series set for the warehouse', (await flash(p)) === 'Default series for Goods Issue saved.'
      && Number((await one(`SELECT series_id FROM erp.warehouse_series_default WHERE company_code = 'ZZ99' AND whs_code = $1 AND obj_type = 60`, [WHS]))?.series_id) === Number(giOpt), await flash(p));
    await p.screenshot({ path: `${OUT}/b3-warehouse-numbering-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/inventory/warehouses/ZZ99/WH01`); await settle(p);
    ok('SAP / sample warehouse: general data read-only with the reason', await seen(p.locator('[data-testid=whs-sap-note]')) && await p.locator('#whs-name').isDisabled() && (await p.locator('#whs-save').count()) === 0);
    // Item groups
    await p.goto(`${BASE}/inventory/item-groups/ZZ99/103`); await settle(p);
    await p.locator('#ig-method').waitFor({ timeout: 10000 }).catch(() => {});
    await p.selectOption('#ig-method', 'batch');
    await p.fill('#ig-warranty', '24');
    await p.click('#ig-save'); await waitFlash(p);
    ok('item group 103: batch managed, 24 months warranty', (await flash(p)) === 'Item group saved.'
      && (await one(`SELECT manage_method FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = 103`))?.manage_method === 'batch'
      && (await one(`SELECT months FROM erp.warranty_rule WHERE company_code = 'ZZ99' AND group_code = 103 AND item_code IS NULL`))?.months === 24, await flash(p));
    await p.fill('#ig-warranty', '999'); await p.click('#ig-save');
    await p.locator('[data-testid=stp-error]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('warranty out of range refused', (await errText(p)) === 'Warranty must be a whole number of months between 1 and 240, or empty.', await errText(p));
    await p.goto(`${BASE}/inventory/item-groups`); await settle(p);
    ok('item group list shows method and warranty', (await txt(p.locator('[data-testid=ig-list] tr[data-group="103"]'))).includes('Batches') && (await txt(p.locator('[data-testid=ig-list] tr[data-group="103"]'))).includes('24 months'));
    await p.goto(`${BASE}/inventory/reasons`); await settle(p);
    ok('reasons: inventory alone sees them read-only', (await p.locator('#rs-add').count()) === 0 && (await p.locator('[data-testid=rs-table] tbody tr').count()) >= 4);
    await C.close();
  }

  // ---------- 3. Accounting tab, reasons (Admin = Inventory + Financials) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'admin-setup');
    await login(p, 'admin');
    await p.goto(`${BASE}/inventory/warehouses/ZZ99/WH02`); await settle(p);
    await p.click('#whs-tab-accounting');
    await p.locator('[data-testid=whs-acct-table]').waitFor({ timeout: 10000 }).catch(() => {});
    await pickCombo(p, p.locator('#whs-acct-inventory-cogs'), '5230', '5230');
    await p.click('#whs-acct-save'); await waitFlash(p);
    ok('warehouse Accounting tab: WH02 COGS 5230 saved', (await one(`SELECT acct_code FROM erp.gl_determination_whs WHERE company_code = 'ZZ99' AND whs_code = 'WH02' AND posting_key = 'cogs'`))?.acct_code === '5230', await flash(p));
    await p.screenshot({ path: `${OUT}/b3-warehouse-accounting-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/inventory/reasons`); await settle(p);
    await p.fill('#rs-new-code', 'e2ewo');
    await p.fill('#rs-new-name', 'E2E write-off');
    await p.selectOption('#rs-new-key', 'inventory/write_off');
    await p.click('#rs-add'); await waitFlash(p);
    ok('reason added with a G/L key and no account', (await flash(p)) === 'Reason E2EWO added.'
      && (await one(`SELECT gl_area || '/' || gl_key AS k, acct_code FROM erp.inventory_reason WHERE company_code = 'ZZ99' AND code = 'E2EWO'`))?.k === 'inventory/write_off', await flash(p));
    ok('the reason row says its account comes from the key', (await p.locator('#rs-acct-E2EWO').getAttribute('placeholder')) === 'From the G/L key');
    await p.screenshot({ path: `${OUT}/b3-reasons-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 4. Landed cost types (Purchasing) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'purch-lc');
    await login(p, 'purch');
    await p.goto(`${BASE}/purchasing/setup`); await settle(p);
    await p.click('#pu-lc-types'); await settle(p);
    await p.locator('[data-testid=lc-table]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('landed cost types list the ZZ99 types with five allocation methods', (await p.locator('[data-testid=lc-table] tbody tr').count()) >= 5 && (await p.locator('#lc-new-method option').count()) === 5);
    await p.fill('#lc-new-code', 'e2eport');
    await p.fill('#lc-new-name', 'E2E port handling');
    await p.selectOption('#lc-new-method', 'equal');
    await p.click('#lc-add'); await waitFlash(p);
    ok('type added, split equally', (await flash(p)) === 'Landed cost type E2EPORT added.'
      && (await one(`SELECT split_method FROM erp.landed_cost_code WHERE company_code = 'ZZ99' AND code = 'E2EPORT'`))?.split_method === 'equal', await flash(p));
    ok('purchasing alone can\'t change the account (Financials)', (await p.locator('#lc-acct-E2EPORT').count()) === 0);
    await p.screenshot({ path: `${OUT}/b3-landed-cost-types-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 5. Resources (Production) ----------
  {
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'prod-res');
    await login(p, 'prod');
    await p.goto(`${BASE}/production/resources`); await settle(p);
    await p.locator('[data-testid=res-table]').waitFor({ timeout: 10000 }).catch(() => {});
    await p.click('#res-new');
    await p.fill('#res-code', `e2e-lab-${RND}`);
    await p.fill('#res-name', 'E2E assembly labour');
    await p.selectOption('#res-kind', 'labour');
    await p.fill('#res-rate', '45');
    await p.click('#res-save');
    await p.locator('[data-testid=stp-error]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('hourly resource without account refused while resource absorption is not set', (await errText(p)).includes('has a cost, so it needs the account its cost is credited to'), await errText(p));
    await db.query(`INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source) VALUES ('ZZ99', 'resources', 'resource_cost', '5320', 'erp') ON CONFLICT DO NOTHING`);
    await p.click('#res-save'); await waitFlash(p);
    ok('with resource absorption set, the resource is created at 45 per hour', (await flash(p)) === `Resource E2E-LAB-${RND} created.`
      && Number((await one(`SELECT unit_cost FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = $1`, [`E2E-LAB-${RND}`]))?.unit_cost) === 45, await flash(p));
    ok('the list shows the rate per hour', (await txt(p.locator(`[data-testid=res-table] tr[data-res="E2E-LAB-${RND}"]`))).includes('45.00 AED / hour'));
    await p.screenshot({ path: `${OUT}/b3-resources-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 6. Bank statement: saved mapping, decimal comma, reference rule ----------
  {
    const today = new Date(); const iso = today.toISOString().slice(0, 10);
    const dd = (d) => `${String(d.getDate()).padStart(2, '0')}.${String(d.getMonth() + 1).padStart(2, '0')}.${d.getFullYear()}`;
    const cents = String(Math.floor(Math.random() * 90) + 10);
    const A = `3${RND}.${cents}`; const B = `4${RND}.${cents}`;
    await as(ID.fin, `SELECT erp.payment_submit('ZZ99', 'I', $1::jsonb, '[]'::jsonb, NULL)`, [JSON.stringify({ card_code: 'C0011', doc_date: iso, transfer: A, transfer_bank: 'BNK-AED', transfer_ref: `E2EREF${RND}` })]);
    await as(ID.fin, `SELECT erp.payment_submit('ZZ99', 'I', $1::jsonb, '[]'::jsonb, NULL)`, [JSON.stringify({ card_code: 'C0011', doc_date: iso, transfer: B, transfer_bank: 'BNK-AED', transfer_ref: `E2EOK${RND}` })]);
    const comma = (n) => `"${n.replace('.', ',')}"`;
    const csv = path.join(os.tmpdir(), `b3-statement-${RND}.csv`);
    fs.writeFileSync(csv, ['Value date,Narrative,Cheque/Ref,Debit,Credit',
      `${dd(today)},Transfer in,TT E2EREF${RND},,${comma(A)}`,
      `${dd(today)},Transfer in,OTHER${RND},,${comma(B)}`].join('\n'));
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'fin-stmt');
    await login(p, 'fin');
    await p.goto(`${BASE}/banking/statements`); await settle(p);
    await p.setInputFiles('#imp-file', csv);
    await p.locator('[data-testid=imp-preview]').waitFor({ timeout: 10000 }).catch(() => {});
    await p.selectOption('#imp-format', 'DD.MM.YYYY');
    await p.selectOption('#imp-decimal', ',');
    ok('decimal comma: the preview reads 1.234,56 style amounts', (await txt(p.locator('[data-testid=imp-preview]'))).includes(A) && (await txt(p.locator('[data-testid=imp-preview]'))).includes(iso));
    ok('remember-the-mapping is on by default', await p.locator('#imp-remember').isChecked());
    await p.screenshot({ path: `${OUT}/b3-statement-import-en-light-1440.png`, fullPage: true });
    await p.click('#imp-submit');
    await p.waitForURL(/\/banking\/statements\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
    await settle(p);
    ok('mapping saved for BNK-AED', (await one(`SELECT mapping->>'decimal_sep' AS d FROM erp.bank_statement_format WHERE company_code = 'ZZ99' AND bank_code = 'BNK-AED'`))?.d === ',');
    ok('the page states the matching rule (± 3 days, reference)', (await txt(p.locator('[data-testid=stmt-rule]'))).includes('± 3 days') && (await txt(p.locator('[data-testid=stmt-rule]'))).includes('reference'));
    await p.click('#stmt-auto');
    await p.locator('[data-testid=bk-flash]', { hasText: 'Matched' }).waitFor({ timeout: 10000 }).catch(() => {});
    ok('auto-match: the line whose reference fits matches; the other reference stays for manual matching',
      (await txt(p.locator('[data-testid=bk-flash]'))) === 'Matched 1 lines. 1 still need a match.' && (await txt(p.locator('[data-testid=stmt-count]'))) === '1 of 2 matched', await txt(p.locator('[data-testid=bk-flash]')));
    await p.locator('[data-testid=stmt-activity]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('matching history shows the auto-match and who ran it', (await txt(p.locator('[data-testid=stmt-activity]'))).includes('Auto-match · QA Finance'));
    await p.screenshot({ path: `${OUT}/b3-statement-en-light-1440.png`, fullPage: true });
    await p.goto(`${BASE}/banking/statements`); await settle(p);
    await p.setInputFiles('#imp-file', csv);
    await p.locator('[data-testid=imp-saved]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('next import of this bank uses the saved mapping (date format and decimal comma)', await seen(p.locator('[data-testid=imp-saved]'))
      && (await p.locator('#imp-decimal').inputValue()) === ',' && (await p.locator('#imp-format').inputValue()) === 'DD.MM.YYYY');
    await C.close();
  }

  // ---------- 7. B2 fix: a partial rejection keeps the document waiting ----------
  {
    const st = await as(ID.admin, `SELECT erp.approval_stage_save('ZZ99', $1::jsonb) AS r`, [JSON.stringify({ name: 'E2E B3 two rejections', required_approvals: 1, required_rejections: 2,
      authorizers: [{ position_code: 'QA_FIN_MGR' }, { user_id: ID.admin }] })]);
    const stageId = st.r.stage_id;
    await as(ID.admin, `SELECT erp.approval_template_save('ZZ99', $1::jsonb)`, [JSON.stringify({ name: 'E2E B3 incoming', kind: 'incoming_payment', stages: [stageId],
      originators: [{ user_id: ID.fin }], conditions: [{ field: 'amount', op: 'gt', value1: 5000 }] })]);
    const pay = await as(ID.fin, `SELECT erp.payment_submit('ZZ99', 'I', $1::jsonb, '[]'::jsonb, 'E2E B3 partial rejection') AS r`,
      [JSON.stringify({ card_code: 'C0011', doc_date: new Date().toISOString().slice(0, 10), transfer: `7${RND}.11`, transfer_bank: 'BNK-AED' })]);
    const draft = pay.r.draft_id;
    ok('fixture: the payment waits for the two-rejection stage', pay.r.state === 'pending_approval' && Boolean(draft), JSON.stringify(pay.r));
    const C = await context(browser);
    const p = await C.newPage(); watch(p, 'fmgr-reject');
    await login(p, 'fmgr');
    await p.goto(`${BASE}/banking/payment-drafts/ZZ99/${draft}`); await settle(p);
    await p.locator('#bk-reject').waitFor({ timeout: 10000 }).catch(() => {});
    await p.click('#bk-reject');
    await p.fill('#bk-reject-note', 'E2E: wrong customer');
    await p.click('#bk-reject-confirm');
    await p.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('first of two rejections: the flash says it is still waiting (not "rejected")',
      (await txt(p.locator('[data-testid=bk-flash]'))) === 'Your rejection is recorded. This stage needs more rejections, so the document is still waiting for approval.', await txt(p.locator('[data-testid=bk-flash]')));
    ok('the draft is still waiting in the database', (await one(`SELECT state FROM erp.payment_draft WHERE draft_id = $1`, [draft]))?.state === 'pending_approval');
    await C.close();
  }

  // ---------- 8. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  const PAGES = [
    ['gl-determination', '/financials/gl-determination?tab=inventory', 'admin'],
    ['warehouses', '/inventory/warehouses', 'admin'],
    ['warehouse', '/inventory/warehouses/ZZ99/WH02', 'admin'],
    ['item-groups', '/inventory/item-groups', 'admin'],
    ['reasons', '/inventory/reasons', 'admin'],
    ['landed-cost-types', '/purchasing/landed-cost-types', 'admin'],
    ['resources', '/production/resources', 'admin'],
  ];
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin');
        for (const [name, url] of PAGES) {
          await p.goto(`${BASE}${url}`); await settle(p); await p.waitForTimeout(250);
          await p.screenshot({ path: `${OUT}/b3-${name}-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
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

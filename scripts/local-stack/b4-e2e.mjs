// B4 browser test: multi-currency (USD factory PO → GRPO → A/P invoice → outgoing payment with a Finance rate and a realised
// loss; USD customer order with the converted totals → delivery / invoice → incoming USD payment), the missing-rate message,
// copies keeping the rate, LC totals on document pages, the customer aging currency columns, the item form taking the item
// group's batch method, and screenshots (1440 / 390, light / dark, EN / AR). Local stack only (Vite :5173 + gateway :54321 +
// PostgREST + Postgres). Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b4-e2e.mjs [outDir]
// Leaves on the running DB: the USD documents and payments (permanent journals) and today's / tomorrow-free USD rate for ZZ99.
// Restores the fixtures (C0013 back to AED, item group 101 method).
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b4-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail && !pass ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'], sales: ['qa.sales@sample.test', 'local-only-2'], fin: ['qa.finance@sample.test', 'local-only-4'],
  purch: ['qa.purchase@sample.test', 'local-only-10'],
};
const ID = { sales: '00000000-0000-4000-8000-000000000002', fin: '00000000-0000-4000-8000-000000000004', purch: '00000000-0000-4000-8000-000000000010' };
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
const NORATE = '2031-01-02';   // a date without a USD rate
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const num = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));

// Fixtures: today's USD rate (Finance), a USD customer, item group 101 managed by batch.
await as(ID.fin, `SELECT erp.fx_rate_save('ZZ99', $1::date, 'USD', 3.6725)`, [TODAY]);
await db.query(`DELETE FROM erp.fx_rate_entry WHERE company_code = 'ZZ99' AND rate_date = $1 AND currency = 'USD'`, [NORATE]);
await db.query(`UPDATE erp.business_partner SET currency = 'USD' WHERE company_code = 'ZZ99' AND card_code = 'C0013'`);
const prevMethod = (await one(`SELECT manage_method FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = 101`))?.manage_method ?? null;
await db.query(`INSERT INTO erp.item_group_setting (company_code, group_code, manage_method, origin) VALUES ('ZZ99', 101, 'batch', 'sap')
                ON CONFLICT (company_code, group_code) DO UPDATE SET manage_method = 'batch'`).catch(async () => {
  await db.query(`INSERT INTO erp.item_group_setting (company_code, group_code, manage_method) VALUES ('ZZ99', 101, 'batch') ON CONFLICT (company_code, group_code) DO UPDATE SET manage_method = 'batch'`);
});
async function cleanup() {
  await db.query(`UPDATE erp.business_partner SET currency = 'AED' WHERE company_code = 'ZZ99' AND card_code = 'C0013'`);
  if (prevMethod) await db.query(`UPDATE erp.item_group_setting SET manage_method = $1 WHERE company_code = 'ZZ99' AND group_code = 101`, [prevMethod]);
  else await db.query(`DELETE FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = 101`);
}

const browser = await chromium.launch();
let po; let gr; let ap; let so;
try {
  // ---------- 1. USD purchase order (Purchasing) ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'po');
    await login(p, 'purch');
    await p.goto(`${BASE}/docs/purchase_order/new?company=ZZ99`); await settle(p);
    await pickCombo(p, p.locator('#pu-card_code'), 'S0001', 'S0001');
    await p.locator('#pu-doc_date').fill(NORATE);
    ok('missing rate: the currency field names the currency and the date', await seen(p.locator('[data-testid=cur-no-rate]', { hasText: 'There is no exchange rate for USD on 02 Jan 2031' })),
      await txt(p.locator('[data-testid=cur-no-rate]')));
    await p.locator('#pu-doc_date').fill(TODAY);
    ok('USD supplier: the form is in USD', (await txt(p.locator('[data-testid=cur-currency]'))).includes('USD') || (await p.locator('#pu-currency').inputValue().catch(() => '')) === 'USD');
    ok('Purchasing sees the day\'s rate read-only (3.6725)', await seen(p.locator('[data-testid=cur-rate]', { hasText: '3.6725' })), await txt(p.locator('[data-testid=cur-rate]')));
    await pickCombo(p, p.locator('#pu-line-0-item'), 'SMP-1140', 'SMP-1140');
    await p.locator('#pu-line-0-qty').fill('10');
    await p.locator('#pu-line-0-price').fill('10');
    await p.locator('[data-testid=pu-total-lc]').waitFor({ timeout: 10000 }).catch(() => {});
    const tot = await txt(p.locator('[data-testid=pu-total]'));
    const lc = await txt(p.locator('[data-testid=pu-total-lc]'));
    ok('totals in USD (105.00) with the AED total (385.61)', num(tot) === 105 && lc.includes('385.61') && lc.includes('AED'), `${tot} / ${lc}`);
    await p.screenshot({ path: `${OUT}/b4-po-form-en-light-1440.png`, fullPage: true });
    await p.locator('#pu-submit').click();
    await p.waitForURL(/\/docs\/purchase_order\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    po = Number(p.url().split('/').pop());
    ok('PO page: currency USD at 3.6725 AED and the AED total', await seen(p.locator('main', { hasText: 'USD at 3.6725 AED' })) && await seen(p.locator('[data-testid=pu-total-lc]', { hasText: '385.61' })),
      (await txt(p.locator('main'))).slice(0, 200));
    const d = await one(`SELECT currency, fx_rate, total, total_fc, status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = $1`, [po]);
    ok('stored: USD, 3.6725, 385.61 AED / 105 USD, open', d.currency === 'USD' && Number(d.fx_rate) === 3.6725 && Number(d.total) === 385.61 && Number(d.total_fc) === 105 && d.status === 'open', JSON.stringify(d));

    // ---------- 2. GRPO keeps the PO rate ----------
    await p.goto(`${BASE}/purchasing/grpo/new?company=ZZ99&po=${po}`); await settle(p);
    ok('GRPO form: the PO rate is kept (read-only)', await seen(p.locator('[data-testid=cur-rate]', { hasText: '3.6725' })) && (await txt(p.locator('main'))).includes('Kept from the document'));
    await p.locator('#pu-grpo-submit').click();
    await p.waitForURL(/\/docs\/goods_receipt_po\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    gr = Number(p.url().split('/').pop());
    ok('GRPO page shows USD and the AED total', await seen(p.locator('main', { hasText: 'USD at 3.6725 AED' })) && await seen(p.locator('[data-testid=pu-total-lc]', { hasText: '385.61' })));

    // ---------- 3. A/P invoice (own date's rate) ----------
    await p.goto(`${BASE}/purchasing/ap-invoice/new?company=ZZ99&grpo=${gr}`); await settle(p);
    await p.locator('#pu-ref').fill(`INV-B4-${po}`);
    await p.locator('#pu-ap-submit').click();
    await p.waitForURL(/\/docs\/ap_invoice\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    ap = Number(p.url().split('/').pop());
    ok('A/P invoice page: open 105.00 USD to pay', (await txt(p.locator('[data-testid=pu-open-amount]'))).includes('105.00 USD'), await txt(p.locator('[data-testid=pu-open-amount]')));
    await p.screenshot({ path: `${OUT}/b4-ap-invoice-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 4. Outgoing USD payment (Finance types its own rate → realised loss) ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'pay-out');
    await login(p, 'fin');
    await p.goto(`${BASE}/banking/payments/out/new?company=ZZ99&card=S0001&apply=18:${ap}:105`); await settle(p);
    await p.locator('[data-testid=bk-doc]').first().waitFor({ timeout: 10000 }).catch(() => {});
    ok('payment form: in USD, the USD invoice listed (open 105.00)', (await txt(p.locator('[data-testid=bk-docs]'))).includes('105.00'));
    await p.selectOption('#bk-transfer-bank', 'BNK-AED');
    await p.fill('#bk-transfer-ref', `TT-B4-${ap}`);
    await p.fill('#bk-fx_rate', '3.7');
    ok('Finance may type a rate: AED equivalent 388.50', await seen(p.locator('[data-testid=bk-total-lc]', { hasText: '388.50' })), await txt(p.locator('[data-testid=bk-total-lc]')));
    await p.screenshot({ path: `${OUT}/b4-payment-form-en-light-1440.png`, fullPage: true });
    await p.click('#bk-submit');
    await p.waitForURL(/\/banking\/payments\/out\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    const tot = await txt(p.locator('[data-testid=bk-detail-total]'));
    const fx = await txt(p.locator('[data-testid=bk-detail-fx]'));
    ok('payment page: 105.00 USD, loss 2.89 AED (388.50 − 385.61)', tot.includes('105.00 USD') && fx.includes('2.89') && /loss/i.test(fx), `${tot} / ${fx}`);
    const inv = await one(`SELECT paid, paid_fc FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = $1`, [ap]);
    ok('A/P invoice paid in both currencies', Number(inv.paid) === 385.61 && Number(inv.paid_fc) === 105, JSON.stringify(inv));
    await p.screenshot({ path: `${OUT}/b4-payment-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 5. USD sales order (Sales) ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'so');
    await login(p, 'sales');
    await p.goto(`${BASE}/docs/sales_order/new`); await settle(p);
    await pickCombo(p, p.locator('#so-card_code'), 'C0013', 'C0013');
    const line = p.locator('[data-testid=so-line]').first();
    await pickCombo(p, line.locator('input').first(), 'SMP-1010', 'SMP-1010');
    await line.locator('input[id$="-qty"]').fill('2');
    await line.locator('input[id$="-price"]').fill('50');
    await p.locator('[data-testid=so-total-lc]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('order form: USD total 105.00 and AED 385.61', num(await txt(p.locator('[data-testid=so-total]'))) === 105 && (await txt(p.locator('[data-testid=so-total-lc]'))).includes('385.61'),
      `${await txt(p.locator('[data-testid=so-total]'))} / ${await txt(p.locator('[data-testid=so-total-lc]'))}`);
    await p.screenshot({ path: `${OUT}/b4-so-form-en-light-1440.png`, fullPage: true });
    await p.click('#so-submit');
    await p.waitForURL(/\/docs\/sales_order\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    so = Number(p.url().split('/').pop());
    ok('order page: USD at 3.6725 AED', await seen(p.locator('main', { hasText: 'USD at 3.6725 AED' })));
    await C.close();
  }
  // delivery + invoice through the API (A4 tests cover the forms); then the invoice page and an incoming payment in the browser
  const dl = await as(ID.sales, `SELECT erp.sales_delivery_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: TODAY }), JSON.stringify([{ base_doc_entry: so, base_line: 0, qty: 2 }])]);
  const inv = await as(ID.sales, `SELECT erp.sales_invoice_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: TODAY }), JSON.stringify([{ base_doc_entry: dl.r.doc_entry, base_line: 0, qty: 2 }])]);
  const invEntry = inv.r.doc_entry;
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'pay-in');
    await login(p, 'fin');
    const CA = await context(browser); const pa = await CA.newPage(); watch(pa, 'inv-admin');
    await login(pa, 'admin');
    await pa.goto(`${BASE}/docs/ar_invoice/ZZ99/${invEntry}`); await settle(pa);
    ok('invoice page: 105.00 USD with 385.61 AED', await seen(pa.locator('[data-testid=so-total]', { hasText: '105.00' })) && await seen(pa.locator('[data-testid=so-total-lc]', { hasText: '385.61' })),
      `${await txt(pa.locator('[data-testid=so-total]'))} / ${await txt(pa.locator('[data-testid=so-total-lc]'))}`);
    await pa.screenshot({ path: `${OUT}/b4-invoice-en-light-1440.png`, fullPage: true });
    await pa.goto(`${BASE}/print/ar_invoice/ZZ99/${invEntry}`); await settle(pa);
    ok('print sheet: total in USD, VAT and total also in AED', await seen(pa.locator('[data-testid=print-total]', { hasText: '105.00' })) && await seen(pa.locator('[data-testid=print-total-lc]', { hasText: '385.61' })));
    await CA.close();
    await p.goto(`${BASE}/banking/payments/in/new?company=ZZ99`); await settle(p);
    await pickCombo(p, p.locator('#bk-bp'), 'C0013', 'C0013');
    await p.locator('[data-testid=bk-doc]').first().waitFor({ timeout: 10000 }).catch(() => {});
    ok('incoming payment: the customer\'s USD invoice listed', (await txt(p.locator('[data-testid=bk-docs]'))).includes('105.00'));
    await p.fill('#bk-transfer', '40');
    await p.selectOption('#bk-transfer-bank', 'BNK-AED');
    await p.fill('#bk-transfer-ref', `USD-B4-${invEntry}`);
    // the row of this invoice (earlier runs may leave other open USD invoices of C0013)
    const row = p.locator('[data-testid=bk-doc]', { hasText: inv.r.doc_no });
    await row.locator('input').fill('40');
    await p.click('#bk-submit');
    await p.waitForURL(/\/banking\/payments\/in\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    ok('incoming payment posted: 40.00 USD', (await txt(p.locator('[data-testid=bk-detail-total]'))).includes('40.00 USD'));
    const d = await one(`SELECT paid, paid_fc FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = $1`, [invEntry]);
    ok('invoice part-paid: 40 USD / 146.90 AED', Number(d.paid_fc) === 40 && Number(d.paid) === 146.9, JSON.stringify(d));
    await p.goto(`${BASE}/reports/ar-aging?company=ZZ99&as_of=${TODAY}`); await settle(p);
    await p.locator('table').first().waitFor({ timeout: 10000 }).catch(() => {});
    const rep = await txt(p.locator('main'));
    const agingOpen = await one(`SELECT round(sum(total_fc - coalesce(paid_fc, 0)), 2) AS o FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND card_code = 'C0013' AND status = 'open' AND total_fc IS NOT NULL`);
    ok('customer aging lists C0013 in USD with its open USD amount', rep.includes('C0013') && rep.includes('USD') && rep.includes(Number(agingOpen.o).toFixed(2)), `${agingOpen.o} · ${rep.slice(0, 200)}`);
    await C.close();
  }

  // ---------- 6. Item form: the group's batch method ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'item');
    await login(p, 'admin');
    await p.goto(`${BASE}/items/new`); await settle(p);
    await p.selectOption('#it-group_code', '101');
    ok('item form: choosing group 101 selects batch management', await p.locator('#it-tracking-batch').isChecked() && await seen(p.locator('[data-testid=it-group-method]')));
    await C.close();
  }

  // ---------- 7. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  const PAGES = [
    ['po', `/docs/purchase_order/ZZ99/${po}`, 'purch'],
    ['ap-invoice', `/docs/ap_invoice/ZZ99/${ap}`, 'purch'],
    ['so', `/docs/sales_order/ZZ99/${so}`, 'purch'],
    ['po-new', '/docs/purchase_order/new?company=ZZ99', 'purch'],
  ];
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin');
        for (const [name, url] of PAGES) {
          await p.goto(`${BASE}${url}`); await settle(p); await p.waitForTimeout(300);
          if (name === 'po-new') { await pickCombo(p, p.locator('#pu-card_code'), 'S0001', 'S0001').catch(() => {}); await p.waitForTimeout(400); }
          await p.screenshot({ path: `${OUT}/b4-${name}-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
          if (w === 390) ok(`${name}: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(p));
        }
        const pp = await C.newPage(); watch(pp, `pay-${w}-${theme}-${lang}`);
        const pay = await one(`SELECT doc_entry FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND total_fc IS NOT NULL ORDER BY doc_entry DESC LIMIT 1`);
        await pp.goto(`${BASE}/banking/payments/out/ZZ99/${pay.doc_entry}`); await settle(pp); await pp.waitForTimeout(300);
        await pp.screenshot({ path: `${OUT}/b4-payment-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
        if (w === 390) ok(`payment: no horizontal scroll at 390 px (${theme}, ${lang})`, await noHScroll(pp));
        if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${w})`, (await pp.evaluate(() => document.documentElement.dir)) === 'rtl');
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

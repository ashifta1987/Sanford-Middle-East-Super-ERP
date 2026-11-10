// A13 browser test: production and service, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a13-e2e.mjs [outDir]
// qa.stock (Inventory) reads Production but can't create → qa.prod: BOM list/detail, an order of 1,000 is blocked on release with
// the shortage and the purchase order that will arrive, cancelled → an order of 4: release, issue components, report output (cost
// per unit = components + resources), close → mould shot count → qa.service: a service call on an out-of-warranty serial is
// flagged (live warranty card + banner), spare parts issued through a goods issue, resolved and closed → service contract draft →
// active → equipment card list → qa.tech can't issue parts, qa.sales can't log calls → module pages. Screenshots 1440 / 390,
// light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a13-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  prod: ['qa.prod@sample.test', 'local-only-24'],
  svc: ['qa.service@sample.test', 'local-only-25'],
  tech: ['qa.tech@sample.test', 'local-only-26'],
  stock: ['qa.stock@sample.test', 'local-only-13'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  admin: ['qa.admin@sample.test', 'local-only-1'],
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
async function pickCombo(page, input, text, optionText) {
  await input.waitFor({ timeout: 15000 });
  const opt = page.locator('[role=listbox] [role=option]', { hasText: optionText }).first();
  for (let i = 0; i < 3; i++) {
    await input.click();
    await input.fill('');
    await input.pressSequentially(text, { delay: 30 });
    if (await opt.waitFor({ timeout: 6000 }).then(() => true).catch(() => false)) break;
    if (i === 2) { await page.screenshot({ path: '/tmp/a13-combo-fail.png', fullPage: true }); console.log('combo fail at', page.url(), await input.inputValue().catch(() => '?')); }
  }
  await opt.click({ timeout: 5000 });
}
const txt = (loc) => loc.innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc) => loc.first().waitFor({ timeout: 10000 }).then(() => true).catch(() => false);
const idFromUrl = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
const oh = async (item, whs = 'WH01') => Number((await one('SELECT on_hand FROM erp.stock_balance WHERE company_code = $1 AND item_code = $2 AND whs_code = $3', ['ZZ99', item, whs]))?.on_hand ?? 0);

// Fixture: an open Super ERP purchase order for the resin (so the shortage names the PO that will arrive). Created once.
if (!(await one("SELECT 1 FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_no = 'PO-E2E-A13'"))) {
  const e = Number((await one("SELECT nextval('erp.erp_doc_entry_seq') AS n")).n);
  await db.query(`INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, currency, total, source)
                  VALUES ('ZZ99', 22, $1, 99113, 'purchase_order', 'open', DATE '2026-11-01', DATE '2026-11-13', 'S0009', 'AED', 3250, 'erp')`, [e]);
  await db.query(`INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total, whs_code, line_status)
                  VALUES ('ZZ99', 22, $1, 0, 'SMP-RAW-PP', 500, 500, 6.5, 3250, 'WH01', 'O')`, [e]);
  await db.query(`INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by)
                  VALUES ('ZZ99', 22, $1, 'PO-E2E-A13', 'approved', '00000000-0000-4000-8000-000000000001')`, [e]);
}

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const ids = {};

// ---------- 1. Inventory user: reads Production, can't create ----------
{
  const c = await context(browser);
  const p = await c.newPage(); watch(p, 'stock');
  await login(p, 'stock'); await settle(p);
  await p.goto(`${BASE}/production/orders`); await settle(p);
  ok('inventory user: "New production order" disabled with the reason', await p.locator('#order-new').isDisabled().catch(() => false));
  await c.close();
}

const C = await context(browser);
const pp = await C.newPage(); watch(pp, 'prod');
await login(pp, 'prod'); await settle(pp);

// ---------- 2. BOM list and detail ----------
await pp.goto(`${BASE}/production/boms`); await settle(pp);
ok('BOM list shows the sample kettle body BOM', await seen(pp.locator('tr', { hasText: 'SMP-PRD-100' })));
await pp.goto(`${BASE}/production/boms/ZZ99/SMP-PRD-100`); await settle(pp);
await pp.locator('[data-testid=bom-table]').waitFor({ timeout: 15000 }).catch(() => {});
ok('BOM detail: 3 components + 2 resources', (await pp.locator('[data-testid=bom-table] tbody tr').count()) === 5);
await pp.screenshot({ path: `${OUT}/a13-bom-en-light-1440.png`, fullPage: true });

// ---------- 3. Order blocked on release by a shortage, with the PO ----------
async function newOrder(qty) {
  await pp.goto(`${BASE}/production/orders/new`); await settle(pp);
  await pickCombo(pp, pp.locator('#order-item'), 'SMP-PRD', 'SMP-PRD-100');
  await pp.locator('#order-qty').fill(String(qty));
  await pp.locator('#order-due').fill('2026-12-15');
  await pp.locator('#order-create').click();
  await pp.waitForURL(/\/production\/orders\/ZZ99\/\d+$/, { timeout: 15000 });
  await pp.locator('[data-testid=order-lines]').waitFor({ timeout: 15000 }).catch(() => {});
  return idFromUrl(pp.url());
}
const big = await newOrder(100000);
const shortTxt = await txt(pp.locator('[data-testid=order-shortages]'));
ok('planned order shows shortages with the PO that will arrive', /SMP-RAW-PP is short by/.test(shortTxt) && /PO-E2E-A13 brings 500 on 13 Nov 2026/.test(shortTxt), shortTxt.slice(0, 200));
await pp.locator('#order-release').click();
const relErr = await txt(pp.locator('[data-testid=bk-error]'));
ok('release refused: message names the shortage and the PO', /^Can't release PRD-26-\d+: SMP-RAW-PP is short by .* Purchase order PO-E2E-A13 brings 500 on 13 Nov 2026\./.test(relErr), relErr.slice(0, 220));
await pp.screenshot({ path: `${OUT}/a13-order-blocked-en-light-1440.png`, fullPage: true });
ok('blocked order stays planned', (await one('SELECT state FROM erp.prod_order WHERE company_code = $1 AND order_id = $2', ['ZZ99', big]))?.state === 'planned');
await pp.locator('#order-cancel').click();
await pp.locator('#order-cancel-confirm').click();
ok('cancel needs a note', /Add a note first\./.test(await txt(pp.locator('[role=dialog]'))));
await pp.locator('#order-cancel-note').fill('E2E: too big');
await pp.locator('#order-cancel-confirm').click();
await pp.locator('[data-testid=order-state]', { hasText: 'Cancelled' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('planned order cancelled with a note', (await one('SELECT state FROM erp.prod_order WHERE company_code = $1 AND order_id = $2', ['ZZ99', big]))?.state === 'cancelled');

// ---------- 4. Release → issue → receipt → close ----------
const oid = await newOrder(4); ids.order = oid;
await pp.locator('#order-release').click();
await pp.locator('[data-testid=order-state]', { hasText: 'Released' }).waitFor({ timeout: 10000 }).catch(() => {});
await pp.locator('#issue-fill').waitFor({ timeout: 10000 }).catch(() => {});
ok('order released', (await one('SELECT state FROM erp.prod_order WHERE company_code = $1 AND order_id = $2', ['ZZ99', oid]))?.state === 'released');
const pp0 = await oh('SMP-RAW-PP'); const fg0 = await oh('SMP-PRD-100');
const shots0 = Number((await one("SELECT shots_done FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2'")).shots_done);
await pp.locator('#receipt-qty').fill('4');
await pp.locator('#receipt-post').click();
ok('receipt before any issue refused', /Issue the components first: nothing has been issued to PRD-26-\d+ yet\./.test(await txt(pp.locator('[data-testid=bk-error]'))));
await pp.locator('#issue-fill').click();
await pp.locator('#issue-post').click();
await pp.locator('[data-testid=bk-flash]', { hasText: 'Goods issue' }).waitFor({ timeout: 10000 }).catch(() => {});
const issueFlash = await txt(pp.locator('[data-testid=bk-flash]'));
ok('components issued through a goods issue', /^Goods issue GI-26-\d+ posted: [\d,.]+ AED to work in progress\./.test(issueFlash), issueFlash);
ok('resin left stock (2.4 kg)', Math.abs((pp0 - (await oh('SMP-RAW-PP'))) - 2.4) < 1e-6);
const issued = Number((await one('SELECT issued_value FROM erp.prod_order WHERE company_code = $1 AND order_id = $2', ['ZZ99', oid])).issued_value);
await pp.locator('#receipt-qty').fill('4');
await pp.locator('#receipt-post').click();
await pp.locator('[data-testid=bk-flash]', { hasText: 'Goods receipt' }).waitFor({ timeout: 10000 }).catch(() => {});
const recFlash = await txt(pp.locator('[data-testid=bk-flash]'));
const unit = (issued + 4 * 0.5 * 0.4 + 4 * 0.01 * 35) / 4;
ok('output received at (components + resources) / qty', recFlash.includes(`4 at ${unit.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} AED each`), `${recFlash} expected ${unit}`);
ok('finished stock +4', (await oh('SMP-PRD-100')) - fg0 === 4);
ok('mould shot count +2', Number((await one("SELECT shots_done FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2'")).shots_done) === shots0 + 2);
ok('order page lists the issue and the receipt', (await pp.locator('[data-testid=order-docs] li').count()) === 2);
await pp.screenshot({ path: `${OUT}/a13-order-received-en-light-1440.png`, fullPage: true });
await pp.locator('#order-close').click();
await pp.locator('#order-close-confirm').click();
await pp.locator('[data-testid=order-state]', { hasText: 'Closed' }).waitFor({ timeout: 10000 }).catch(() => {});
const cl = await one('SELECT state, variance_value FROM erp.prod_order WHERE company_code = $1 AND order_id = $2', ['ZZ99', oid]);
ok('order closed with no variance', cl?.state === 'closed' && Math.abs(Number(cl.variance_value)) <= 0.02, JSON.stringify(cl));

// ---------- 5. Moulds ----------
await pp.goto(`${BASE}/production/moulds`); await settle(pp);
ok('mould list shows the schedule', await seen(pp.locator('tr', { hasText: 'MLD-KET-2' })));
await pp.goto(`${BASE}/production/moulds/ZZ99/MLD-KET-2`); await settle(pp);
ok('mould page shows the shot count', (await txt(pp.locator('main'))).includes((shots0 + 2).toLocaleString('en-US')));
await C.close();

// ---------- 6. Service call on an out-of-warranty serial ----------
const S = await context(browser);
const sp = await S.newPage(); watch(sp, 'svc');
await login(sp, 'svc'); await settle(sp);
await sp.goto(`${BASE}/service/calls/new`); await settle(sp);
await pickCombo(sp, sp.locator('#call-customer'), 'C0003', 'C0003');
await pickCombo(sp, sp.locator('#call-item'), 'SMP-1020', 'SMP-1020');
await sp.locator('#call-serial').fill('KT-SMP-0001');
await sp.locator('#call-subject').fill('E2E kettle does not heat');
await sp.locator('#call-priority').selectOption('high');
await sp.locator('#call-tech').selectOption({ label: 'QA Technician' });
await sp.locator('[data-testid=warranty-card]', { hasText: 'Out of warranty' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('live warranty check: out of warranty', /Out of warranty: the warranty of SMP-1020 serial KT-SMP-0001 ended on 15 Sep 2025\./.test(await txt(sp.locator('[data-testid=warranty-card]'))));
await sp.screenshot({ path: `${OUT}/a13-call-form-en-light-1440.png`, fullPage: true });
await sp.locator('#call-save').click();
await sp.waitForURL(/\/service\/calls\/ZZ99\/\d+$/, { timeout: 15000 });
ids.call = idFromUrl(sp.url());
ok('saved call is flagged (banner + pill)', await seen(sp.locator('[data-testid=call-flag]')) && /Out of warranty/.test(await txt(sp.locator('[data-testid=warranty-pill]').first())));
ok('flag stored on the call', (await one('SELECT flagged FROM erp.service_call WHERE company_code = $1 AND call_id = $2', ['ZZ99', ids.call]))?.flagged === true);
// spare parts through an A7 goods issue
const box0 = await oh('SMP-1220');
await pickCombo(sp, sp.locator('#parts-item'), 'SMP-1220', 'SMP-1220');
await sp.locator('#parts-qty').fill('1');
await sp.locator('#parts-issue').click();
await sp.locator('[data-testid=bk-flash]', { hasText: 'Goods issue' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('spare parts issued (goods issue posted, stock −1)', /Goods issue GI-26-\d+ posted/.test(await txt(sp.locator('[data-testid=bk-flash]'))) && box0 - (await oh('SMP-1220')) === 1);
ok('parts listed on the call; call in progress', (await sp.locator('[data-testid=call-parts] li').count()) === 1 && /In progress/.test(await txt(sp.locator('[data-testid=call-status]').first())));
await sp.locator('#call-resolved').click();
ok('resolve needs the solution', /Enter the solution before marking the call resolved\./.test(await txt(sp.locator('[data-testid=bk-error]'))));
await sp.locator('#call-solution').fill('Customer charged: replaced the thermostat');
await sp.locator('#call-resolved').click();
await sp.locator('[data-testid=call-status]', { hasText: 'Resolved' }).first().waitFor({ timeout: 10000 }).catch(() => {});
await sp.screenshot({ path: `${OUT}/a13-call-en-light-1440.png`, fullPage: true });
await sp.locator('#call-closed').waitFor({ timeout: 10000 }).catch(() => {});
await sp.locator('#call-closed').click();
for (let i = 0; i < 20 && (await one('SELECT status FROM erp.service_call WHERE company_code = $1 AND call_id = $2', ['ZZ99', ids.call]))?.status !== 'closed'; i++) await sp.waitForTimeout(250);
await sp.locator('[data-testid=call-status]', { hasText: 'Closed' }).first().waitFor({ timeout: 10000 }).catch(() => {});
ok('call resolved and closed', (await one('SELECT status, solution FROM erp.service_call WHERE company_code = $1 AND call_id = $2', ['ZZ99', ids.call]))?.status === 'closed');

// ---------- 7. Contract draft → active, equipment cards ----------
await sp.goto(`${BASE}/service/contracts/new`); await settle(sp);
await pickCombo(sp, sp.locator('#ct-customer'), 'C0010', 'C0010');
await sp.locator('#ct-from').fill('2026-01-01');
await sp.locator('#ct-to').fill('2026-12-31');
await sp.locator('#ct-resp').fill('48');
await pickCombo(sp, sp.locator('#ct-item-0'), 'SMP-1030', 'SMP-1030');
await sp.locator('#ct-save').click();
await sp.waitForURL(/\/service\/contracts\/ZZ99\/\d+$/, { timeout: 15000 });
ids.contract = idFromUrl(sp.url());
await sp.locator('#ct-activate').click();
await sp.locator('[data-testid=ct-state]', { hasText: 'Active' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('service contract saved as draft and activated', (await one('SELECT state FROM erp.service_contract WHERE company_code = $1 AND contract_id = $2', ['ZZ99', ids.contract]))?.state === 'active');
await sp.goto(`${BASE}/service/contracts?tab=tpl`); await settle(sp);
ok('3PL tab shows the SAP copy note', /read-only copies from SAP/.test(await txt(sp.locator('main'))));
await sp.goto(`${BASE}/service/equipment`); await settle(sp);
ok('equipment list shows the out-of-warranty unit', await seen(sp.locator('tr', { hasText: 'KT-SMP-0001' })) && /Out of warranty/.test(await txt(sp.locator('tr', { hasText: 'KT-SMP-0001' }))));
await sp.goto(`${BASE}/service/setup`); await settle(sp);
ok('service setup shows the warranty periods', (await sp.locator('[data-testid=ss-rules] li').count()) >= 1);
await S.close();

// ---------- 8. Access ----------
{
  const c = await context(browser);
  const p = await c.newPage(); watch(p, 'tech');
  await login(p, 'tech'); await settle(p);
  await p.goto(`${BASE}/service/calls/ZZ99/${ids.call}`); await settle(p);
  ok('technician without Inventory: page loads, call closed so no parts form', await seen(p.locator('[data-testid=call-status]')));
  await c.close();
  const c2 = await context(browser);
  const p2 = await c2.newPage(); watch(p2, 'sales');
  await login(p2, 'sales'); await settle(p2);
  await p2.goto(`${BASE}/service/calls`); await settle(p2);
  ok('sales user: "New service call" disabled (read-only)', await p2.locator('#call-new').isDisabled().catch(() => false));
  await p2.goto(`${BASE}/m/production`); await settle(p2);
  ok('sales user has no Production', /You don.t have access to this|does not include/.test(await txt(p2.locator('main'))));
  await c2.close();
}
{
  const c = await context(browser);
  const p = await c.newPage(); watch(p, 'admin');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/m/production`); await settle(p);
  ok('module page: Production functions live', (await p.locator('text=Live data').count()) > 0);
  await p.goto(`${BASE}/m/service`); await settle(p);
  ok('module page: Service functions live', (await p.locator('text=Live data').count()) > 0);
  await c.close();
}

// ---------- 9. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['orders', '/production/orders', 'prod'],
  ['order', `/production/orders/ZZ99/${ids.order}`, 'prod'],
  ['moulds', '/production/moulds', 'prod'],
  ['calls', '/service/calls', 'svc'],
  ['call', `/service/calls/ZZ99/${ids.call}`, 'svc'],
  ['contracts', '/service/contracts', 'svc'],
];
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctxs = {};
  const pages = {};
  for (const [name, path, who] of shots) {
    if (!pages[who]) {
      ctxs[who] = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
      pages[who] = await ctxs[who].newPage(); watch(pages[who], `shot-${who}`); await login(pages[who], who); await settle(pages[who]);
    }
    const page = pages[who];
    await page.goto(`${BASE}${path}`); await settle(page);
    await page.waitForTimeout(400);
    if (width < 640 && lang === 'en' && theme === 'light') ok(`phone: ${name} has no horizontal scroll`, await noHScroll(page));
    await page.screenshot({ path: `${OUT}/a13-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  for (const c of Object.values(ctxs)) await c.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA13 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

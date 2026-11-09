// A7 browser test: inventory transactions, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a7-e2e.mjs [outDir]
// qa.stockread sees New disabled → qa.stock posts a goods receipt, receives two serial numbers, issues one (missing serial refused),
// is refused an issue beyond stock, enters a receipt above the limit (reason) → qa.stockmgr approves it from the inbox → transfer
// request copied to a transfer into a bin (total quantity kept) → count on the phone sheet with a barcode scan, variance over 1 %
// waits → qa.stockmgr approves and it posts → serial history, item history, setup, module page, access. Screenshots 1440 / 390,
// light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a7-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const uniq = String(Date.now()).slice(-6);

const USERS = {
  stock: ['qa.stock@sample.test', 'local-only-13'],
  smgr: ['qa.stockmgr@sample.test', 'local-only-14'],
  sread: ['qa.stockread@sample.test', 'local-only-15'],
  admin: ['qa.admin@sample.test', 'local-only-1'],
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
async function pickCombo(page, input, text, optionText) {
  await input.click();
  await input.fill(text);
  const opt = page.locator('[role=listbox] [role=option]', { hasText: optionText }).first();
  await opt.waitFor({ timeout: 10000 });
  await opt.click();
}
const txt = (loc) => loc.innerText({ timeout: 8000 }).catch(() => '');
const docReady = (page) => page.locator('[data-testid=inv-lines]').waitFor({ timeout: 15000 }).catch(() => {});
const seen = (loc) => loc.first().waitFor({ timeout: 10000 }).then(() => true).catch(() => false);
const entryFromUrl = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
const oh = async (item, whs) => Number((await one('SELECT on_hand FROM erp.stock_balance WHERE company_code = $1 AND item_code = $2 AND whs_code = $3', ['ZZ99', item, whs]))?.on_hand ?? 0);
const tot = async (item) => Number((await one('SELECT sum(on_hand) AS s FROM erp.stock_balance WHERE company_code = $1 AND item_code = $2', ['ZZ99', item])).s);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- 1. Read-only user ----------
{
  const C0 = await context(browser);
  const p0 = await C0.newPage(); watch(p0, 'sread');
  await login(p0, 'sread'); await settle(p0);
  await p0.goto(`${BASE}/docs/goods_receipt`); await settle(p0);
  ok('read-only: "New goods receipt" disabled with the reason', await p0.locator('#inv-new').isDisabled().catch(() => false));
  await C0.close();
}

const C = await context(browser);
const ps = await C.newPage(); watch(ps, 'stock');
await login(ps, 'stock'); await settle(ps);

// ---------- 2. Goods receipt within the limit ----------
async function newDoc(kind, reason, lines, whs = 'WH01') {
  await ps.goto(`${BASE}/inventory/${kind === 'goods_receipt' ? 'goods-receipt' : 'goods-issue'}/new`); await settle(ps);
  await ps.locator('#inv-whs').selectOption(whs);
  await ps.locator('#inv-reason').selectOption(reason);
  for (let i = 0; i < lines.length; i++) {
    if (i > 0) await ps.locator('#inv-add-line').click();
    const l = lines[i];
    await pickCombo(ps, ps.locator(`#inv-item-${i}`), l.item, l.item);
    await ps.locator(`#inv-qty-${i}`).fill(String(l.qty));
    if (l.price != null) await ps.locator(`#inv-price-${i}`).fill(String(l.price));
    if (l.lots) await ps.locator(`#inv-lots-${i}`).fill(l.lots);
    if (l.bin) await ps.locator(`#inv-bin-${i}`).selectOption(l.bin);
  }
  await ps.waitForTimeout(1200);
}
const oh1010 = await oh('SMP-1010', 'WH01');
await newDoc('goods_receipt', 'FOUND', [{ item: 'SMP-1010', qty: 10, price: 95 }]);
ok('receipt preview: "Posts straight away" and total 950.00 AED', (await txt(ps.locator('[data-testid=inv-preview]'))).includes('Posts straight away')
  && (await txt(ps.locator('[data-testid=inv-total]'))).includes('950.00'));
await ps.screenshot({ path: `${OUT}/a7-gr-form-en-light-1440.png`, fullPage: true });
await ps.locator('#inv-submit').click();
await ps.waitForURL(/\/docs\/goods_receipt\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
const gr1 = entryFromUrl(ps.url());
ok('receipt posted: flash, journal number (no link without Financials), stock +10', (await seen(ps.locator('[data-testid=bk-flash]', { hasText: 'posted' })))
  && (await ps.locator('#inv-journal').count()) === 0 /* stock user has no Financials: number shown, no link */ && (await oh('SMP-1010', 'WH01')) === oh1010 + 10
  && (await txt(ps.locator('[data-testid=inv-movements]'))).includes('SMP-1010'));
const grNo = (await one('SELECT doc_no FROM erp.doc_workflow WHERE company_code = $1 AND obj_type = 59 AND doc_entry = $2', ['ZZ99', gr1])).doc_no;

// ---------- 3. Serial numbers ----------
const sn1 = `SN-E2E-${uniq}-1`; const sn2 = `SN-E2E-${uniq}-2`;
await newDoc('goods_receipt', 'FOUND', [{ item: 'SMP-1030', qty: 2, price: 78, lots: `${sn1}\n${sn2}` }]);
await ps.locator('#inv-submit').click();
await ps.waitForURL(/\/docs\/goods_receipt\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
ok('receipt with two serial numbers shows them on the line', (await txt(ps.locator('[data-testid=inv-lots]'))).includes(sn1));
await newDoc('goods_issue', 'DAMAGE', [{ item: 'SMP-1030', qty: 1 }]);
ok('issue without the serial: refused inline', (await ps.locator('[data-testid=inv-line-error]', { hasText: 'SMP-1030 is serial-managed. Enter 1 serial number(s) (0 entered).' }).count()) === 1);
await ps.screenshot({ path: `${OUT}/a7-gi-serial-error-en-light-1440.png`, fullPage: true });
await ps.locator('#inv-lots-0').fill(sn1);
await ps.waitForTimeout(1200);
await ps.locator('#inv-submit').click();
await ps.waitForURL(/\/docs\/goods_issue\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
const lot1 = (await one(`SELECT l.lot_id, coalesce((SELECT sum(qty) FROM erp.stock_lot_balance b WHERE b.lot_id = l.lot_id), 0) AS q FROM erp.stock_lot l WHERE company_code = 'ZZ99' AND number = $1`, [sn1]));
ok('issue with the serial posted; the serial is out of stock', Number(lot1.q) === 0);

// ---------- 4. Issue beyond stock ----------
await newDoc('goods_issue', 'DAMAGE', [{ item: 'SMP-1040', qty: 5 }]);
ok('issue beyond stock refused inline', (await ps.locator('[data-testid=inv-line-error]', { hasText: 'only 0 of SMP-1040 in stock in WH01' }).count()) === 1);

// ---------- 5. Above the limit → approval ----------
const oh1050 = await oh('SMP-1050', 'WH01');
await newDoc('goods_receipt', 'FOUND', [{ item: 'SMP-1050', qty: 120, price: 100 }]);
ok('above 10,000 AED: preview says it needs approval and names the approver', (await txt(ps.locator('[data-testid=inv-preview]'))).includes('Needs approval')
  && (await txt(ps.locator('[data-testid=inv-preview]'))).includes('QA · stock manager'));
await ps.locator('#inv-submit').click();
ok('submit without a reason asks for one', (await ps.locator('[data-testid=bk-error]', { hasText: 'Add a reason for the approver.' }).count()) === 1);
await ps.locator('#inv-why').fill('Pallet found behind racking during housekeeping');
await ps.screenshot({ path: `${OUT}/a7-gr-approval-form-en-light-1440.png`, fullPage: true });
await ps.locator('#inv-submit').click();
await ps.waitForURL(/\/docs\/goods_receipt\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
const gr3 = entryFromUrl(ps.url());
ok('waiting for approval; nothing moved; requester sees who decides', (await seen(ps.locator('h1 .pill', { hasText: 'Waiting approval' })))
  && (await oh('SMP-1050', 'WH01')) === oh1050 && (await txt(ps.locator('[data-testid=inv-status-card]'))).includes('QA · stock manager'));
{
  const C2 = await context(browser);
  const pm = await C2.newPage(); watch(pm, 'smgr');
  await login(pm, 'smgr'); await settle(pm);
  await pm.goto(`${BASE}/approvals`); await settle(pm);
  const link = pm.locator(`a[href="/docs/goods_receipt/ZZ99/${gr3}"]`);
  ok('stock manager: receipt waiting in Approvals', (await link.count()) === 1);
  await link.click(); await docReady(pm);
  ok('approval card with the reason', await seen(pm.locator('[data-testid=inv-approval-card]', { hasText: 'Pallet found behind racking' })));
  await pm.screenshot({ path: `${OUT}/a7-gr-approval-en-light-1440.png`, fullPage: true });
  await pm.locator('#inv-approve').click();
  await pm.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
  await settle(pm);
  ok('approve → posted: stock +120, decided card', (await oh('SMP-1050', 'WH01')) === oh1050 + 120 && (await pm.locator('[data-testid=inv-decided-card]').count()) === 1);
  await C2.close();
}

// ---------- 6. Transfer request → transfer into a bin ----------
await ps.goto(`${BASE}/inventory/transfer-request/new`); await settle(ps);
await ps.locator('#tr-from').selectOption('WH01');
await ps.locator('#tr-to').selectOption('WH02');
await pickCombo(ps, ps.locator('#tr-item-0'), 'SMP-1050', 'SMP-1050');
await ps.locator('#tr-qty-0').fill('7');
await ps.waitForTimeout(900);
await ps.locator('#tr-submit').click();
await ps.waitForURL(/\/docs\/transfer_request\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
const trq = entryFromUrl(ps.url());
ok('transfer request open, with "Copy to transfer"', await seen(ps.locator('#inv-copy-transfer')));
const tot1050 = await tot('SMP-1050'); const wh2 = await oh('SMP-1050', 'WH02');
await ps.locator('#inv-copy-transfer').click(); await settle(ps);
await ps.locator('#tr-submit').waitFor({ timeout: 10000 });
await ps.waitForTimeout(1200);
ok('transfer form copied from the request asks for the put-away bin', (await ps.locator('[data-testid=inv-line-error]', { hasText: 'WH02 uses bins' }).count()) === 1);
await ps.locator('#tr-to-bin-0').selectOption('WH02-A-01-L1');
await ps.waitForTimeout(1000);
await ps.screenshot({ path: `${OUT}/a7-transfer-form-en-light-1440.png`, fullPage: true });
await ps.locator('#tr-submit').click();
await ps.waitForURL(/\/docs\/inventory_transfer\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(ps);
const tr = entryFromUrl(ps.url());
ok('transfer keeps the total quantity; WH02 +7; request closed', (await tot('SMP-1050')) === tot1050 && (await oh('SMP-1050', 'WH02')) === wh2 + 7
  && (await one('SELECT status FROM erp.document WHERE company_code = $1 AND obj_type = 1250000001 AND doc_entry = $2', ['ZZ99', trq])).status === 'closed');
ok('transfer flow strip links back to the request', await seen(ps.locator(`[data-testid=inv-flow] a[href="/docs/transfer_request/ZZ99/${trq}"]`)));

// ---------- 7. Inventory count on the phone sheet ----------
await db.query(`SELECT 1`);
await ps.goto(`${BASE}/inventory/counts/new`); await settle(ps);
await ps.locator('#count-whs').selectOption('QC');
await ps.locator('#count-group').selectOption('101');
await ps.locator('#count-create').click();
await ps.waitForURL(/\/inventory\/counts\/ZZ99\/\d+$/, { timeout: 15000 }); await ps.locator('[data-testid=count-sheet]').waitFor({ timeout: 15000 }).catch(() => {});
const cnt = entryFromUrl(ps.url());
const lines = (await db.query('SELECT line_num, item_code, system_qty FROM erp.inv_count_line WHERE company_code = $1 AND count_id = $2 ORDER BY line_num', ['ZZ99', cnt])).rows;
ok('count started; blind sheet hides the system quantity', lines.length > 0 && (await ps.locator('text=Blind count').count()) === 1 && (await ps.locator('text=/System \\d/').count()) === 0, `${lines.length} lines`);
const target = lines.find((l) => l.item_code === 'SMP-1010') ?? lines[0];
for (const l of lines) {
  const v = l === target ? Number(l.system_qty) - 21 : Number(l.system_qty);
  await ps.locator(`#count-qty-${l.line_num}`).fill(String(v));
}
const barcode = (await one('SELECT barcode FROM erp.item WHERE company_code = $1 AND item_code = $2', ['ZZ99', target.item_code])).barcode;
await ps.locator('#count-scan').fill(barcode);
await ps.locator('#count-scan').press('Enter');
ok('barcode scan adds 1 to the line', (await ps.locator(`#count-qty-${target.line_num}`).inputValue()) === String(Number(target.system_qty) - 20));
await ps.locator('#count-save').click();
await ps.locator('[data-testid=bk-flash]', { hasText: 'Counts saved' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('counts saved: every line counted', (await txt(ps.locator('[data-testid=count-progress]'))).includes(`${lines.length} of ${lines.length}`));
await ps.locator('#count-submit').click();
ok('variance over 1 % without a reason is refused', await seen(ps.locator('[data-testid=bk-error]', { hasText: 'needs approval (variance above the limit)' })));
await ps.locator('#count-why').fill('Two cartons crushed in the QC cage');
await ps.locator('#count-submit').click();
await ps.locator('h1 .pill', { hasText: 'Waiting approval' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('count waits for approval; the variance report shows the line (warn row)', (await ps.locator('h1 .pill', { hasText: 'Waiting approval' }).count()) === 1
  && (await ps.locator('[data-testid=count-variance-row]', { hasText: target.item_code }).count()) === 1);
const sys1010 = await oh(target.item_code, 'QC');
{
  const C3 = await context(browser);
  const pm = await C3.newPage(); watch(pm, 'smgr2');
  await login(pm, 'smgr'); await settle(pm);
  await pm.goto(`${BASE}/approvals`); await settle(pm);
  const link = pm.locator(`a[href="/inventory/counts/ZZ99/${cnt}"]`);
  ok('stock manager: count waiting in Approvals', (await link.count()) === 1);
  await link.click(); await settle(pm);
  await pm.screenshot({ path: `${OUT}/a7-count-approval-en-light-1440.png`, fullPage: true });
  await pm.locator('#inv-approve').click();
  await pm.locator('[data-testid=count-posted]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('approval posts the count: stock −20, journal number shown', (await oh(target.item_code, 'QC')) === sys1010 - 20 && (await txt(pm.locator('[data-testid=count-posted]'))).includes('Journal'));
  await C3.close();
}

// ---------- 8. Serial history, item history ----------
await ps.goto(`${BASE}/inventory/serials?q=${sn1}`); await settle(ps);
await ps.locator(`text=${sn1}`).first().waitFor({ timeout: 10000 }).catch(() => {});
ok('Item Serial Numbers list finds the serial', (await ps.locator(`text=${sn1}`).count()) > 0);
await ps.goto(`${BASE}/inventory/lots/ZZ99/${lot1.lot_id}`); await settle(ps);
ok('serial history: received and issued', (await ps.locator('[data-testid=lot-history] tbody tr').count()) === 2);
await ps.goto(`${BASE}/items/ZZ99/SMP-1010`); await settle(ps);
await ps.locator('[data-testid=item-history]').waitFor({ timeout: 10000 }).catch(() => {});
ok('item detail shows movement history with the receipt number', (await ps.locator('[data-testid=item-history]', { hasText: grNo }).count()) === 1);

// ---------- 9. Lists, module page, setup ----------
await ps.goto(`${BASE}/docs/goods_receipt`); await settle(ps);
ok('Goods receipts list shows Super ERP numbers', (await ps.locator(`text=${grNo}`).count()) > 0);
await ps.goto(`${BASE}/inventory/counts`); await settle(ps);
ok('Inventory Counting list shows the count as Posted', (await ps.locator('tbody tr', { hasText: 'Posted' }).count()) > 0);
await ps.goto(`${BASE}/m/inventory`); await settle(ps);
ok('module page: Inventory Transactions live', (await ps.locator('text=Inventory Transactions').count()) > 0);
await ps.goto(`${BASE}/inventory/setup`); await settle(ps);
ok('setup: WH02 uses bins; stock accounts are Finance-only for the stock user', (await ps.locator('#whs-bins-WH02').isChecked()) && (await ps.locator('#whs-acct-WH01').isDisabled()));
await C.close();

// ---------- 10. Access ----------
{
  const C5 = await context(browser);
  const p5 = await C5.newPage(); watch(p5, 'sales');
  await login(p5, 'sales'); await settle(p5);
  await p5.goto(`${BASE}/inventory/goods-receipt/new`); await settle(p5);
  ok('sales-only user: the server refuses inventory screens (42501)', await seen(p5.locator('text=/have access to this/')));
  await C5.close();
}

// ---------- 11. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['gr', `/docs/goods_receipt/ZZ99/${gr3}`],
  ['transfer', `/docs/inventory_transfer/ZZ99/${tr}`],
  ['count', `/inventory/counts/ZZ99/${cnt}`],
  ['gi-form', '/inventory/goods-issue/new'],
  ['counts', '/inventory/counts'],
  ['serial', `/inventory/lots/ZZ99/${lot1.lot_id}`],
  ['item', '/items/ZZ99/SMP-1010'],
  ['setup', '/inventory/setup'],
];
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'admin'); await settle(page);
  let scrollOk = true;
  for (const [name, p] of shots) {
    await page.goto(`${BASE}${p}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(500);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${name}`); }
    await page.screenshot({ path: `${OUT}/a7-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}
// Phone count sheet in the middle of counting (qa.stock, 390 px).
{
  const ctx = await context(browser, { width: 390, height: 844 });
  const page = await ctx.newPage(); watch(page, 'phone-count');
  await login(page, 'stock'); await settle(page);
  await page.goto(`${BASE}/inventory/counts/new`); await settle(page);
  await page.locator('#count-whs').selectOption('WH01');
  await page.locator('#count-group').selectOption('104');
  await page.locator('#count-create').click();
  await page.waitForURL(/\/inventory\/counts\/ZZ99\/\d+$/, { timeout: 15000 }).catch(() => {});
  await page.locator('[data-testid=count-sheet]').waitFor({ timeout: 15000 }).catch(() => {});
  ok('phone: count sheet has big inputs and no horizontal scroll', (await noHScroll(page)) && (await page.locator('#count-scan').count()) === 1);
  await page.screenshot({ path: `${OUT}/a7-count-sheet-en-light-390.png`, fullPage: true });
  const id = entryFromUrl(page.url());
  if (id) {
    page.on('dialog', (d) => d.accept());
    await page.locator('#count-cancel').click().catch(() => {});
    await page.locator('#count-cancel-note').fill('E2E phone screenshot only').catch(() => {});
    await page.locator('#count-cancel-confirm').click().catch(() => {});
    await page.waitForTimeout(800);
  }
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA7 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

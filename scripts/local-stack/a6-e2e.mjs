// A6 browser test: purchasing, China flow, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a6-e2e.mjs [outDir]
// qa.staff raises a purchase request → qa.purchase copies it to two supplier quotations, compares them, copies the cheaper
// one to a purchase order above the limit (reason) → qa.purchmgr approves from the inbox → PI + 30 % deposit → qa.admin pays
// the deposit in Banking (prefilled from Purchasing) → QC (shipment blocked until a pass) → shipment → goods receipt (over-receipt
// refused) → A/P invoice drawing the deposit → landed costs (split shown, posted, average cost) → flow strip, China office
// filter, setup, access rules. Screenshots 1440 / 390, light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a6-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const money = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));
const iso = (d) => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 10); };
const TODAY = iso(Date.now());
const NEEDED = iso(Date.now() + 40 * 86400000);
const ETA = iso(Date.now() + 30 * 86400000);
const uniq = String(Date.now()).slice(-6);

const USERS = {
  staff: ['qa.staff@sample.test', 'local-only-12'],
  purch: ['qa.purchase@sample.test', 'local-only-10'],
  pmgr: ['qa.purchmgr@sample.test', 'local-only-11'],
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
const entryFromUrl = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const C = await context(browser);

// ---------- 1. Purchase request (qa.staff, read-only Purchasing) ----------
const ps = await C.newPage(); watch(ps, 'staff');
await login(ps, 'staff'); await settle(ps);
await ps.goto(`${BASE}/docs/purchase_order`); await settle(ps);
ok('staff: "New purchase order" disabled with the read-only reason', await ps.locator('#new-purchase').isDisabled().catch(() => false));
await ps.goto(`${BASE}/docs/purchase_request/new`); await settle(ps);
await ps.locator('#pu-due_date').fill(NEEDED);
await ps.locator('#pu-office').selectOption('SZ');
await pickCombo(ps, ps.locator('#pu-line-0-item'), 'SMP-1170', 'SMP-1170');
await ps.locator('#pu-line-0-qty').fill('400');
await ps.locator('[data-step=request][data-state=current]').waitFor({ timeout: 5000 }).catch(() => {});
await ps.waitForTimeout(800);
await ps.screenshot({ path: `${OUT}/a6-request-form-en-light-1440.png`, fullPage: true });
await ps.locator('#pu-submit').click();
await ps.waitForURL(/\/docs\/purchase_request\/ZZ99\/\d+$/, { timeout: 15000 });
await settle(ps);
const req = entryFromUrl(ps.url());
const reqNo = (await one('SELECT doc_no FROM erp.doc_workflow WHERE company_code = $1 AND obj_type = 1470000113 AND doc_entry = $2', ['ZZ99', req]))?.doc_no;
ok('staff submits a purchase request: open, China office stored', (await txt(ps.locator('[data-testid=bk-flash]'))).includes('open') && Boolean(reqNo)
  && (await one('SELECT china_office FROM erp.doc_workflow WHERE company_code = $1 AND obj_type = 1470000113 AND doc_entry = $2', ['ZZ99', req]))?.china_office === 'SZ', reqNo);
ok('staff: request page shows no copy buttons it can use', await ps.locator('#pu-copy-quotation').isDisabled().catch(() => true));

// ---------- 2. Two quotations, compared (qa.purchase) ----------
await ps.close();
const C2 = await context(browser);
const pa = await C2.newPage(); watch(pa, 'purch');
await login(pa, 'purch'); await settle(pa);
async function quote(card, cardText, price) {
  await pa.goto(`${BASE}/docs/purchase_request/ZZ99/${req}`); await settle(pa);
  await pa.locator('#pu-copy-quotation').click();
  await pa.waitForURL(/purchase_quotation\/new/, { timeout: 10000 }); await settle(pa);
  await pickCombo(pa, pa.locator('#pu-card_code'), card, cardText);
  await pa.locator('#pu-line-0-price').fill(String(price));
  await pa.waitForTimeout(700);
  await pa.locator('#pu-submit').click();
  await pa.waitForURL(/\/docs\/purchase_quotation\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
  return entryFromUrl(pa.url());
}
const q1 = await quote('S0009', 'S0009', 140);
await pa.screenshot({ path: `${OUT}/a6-quotation-en-light-1440.png`, fullPage: true });
const q2 = await quote('S0010', 'S0010', 150);
ok('two supplier quotations open from the request', q1 > 0 && q2 > 0 && (await one('SELECT count(*)::int n FROM erp.document WHERE company_code = $1 AND obj_type = 540000006 AND doc_entry IN ($2, $3) AND status = $4', ['ZZ99', q1, q2, 'open'])).n === 2);
await pa.goto(`${BASE}/purchasing/compare/ZZ99/${req}`); await settle(pa);
await pa.locator('[data-testid=pu-compare-table]').waitFor({ timeout: 10000 });
const bestCells = await pa.locator('[data-best=true]').count();
ok('comparison shows both quotations side by side, lowest marked', (await pa.locator('[data-testid=pu-compare-table] thead th').count()) === 3 && bestCells === 1);
await pa.screenshot({ path: `${OUT}/a6-compare-en-light-1440.png`, fullPage: true });

// ---------- 3. Purchase order above the limit → approval ----------
await pa.locator(`#pu-choose-${q1}`).click();
await pa.waitForURL(/purchase_order\/new/, { timeout: 10000 }); await settle(pa);
await pa.locator('#pu-due_date').fill(ETA);
await pa.locator('#pu-line-0-cbm').fill('48');
await pa.locator('[data-testid=pu-submit-card] >> text=Needs approval').waitFor({ timeout: 10000 }).catch(() => {});
const sub = await txt(pa.locator('[data-testid=pu-submit-card]'));
ok('PO form shows the approval rule before submitting', sub.includes('above your limit of 50,000.00 AED'), sub.slice(0, 160));
await pa.screenshot({ path: `${OUT}/a6-po-form-en-light-1440.png`, fullPage: true });
await pa.locator('#pu-reason').fill('Winter range; Shenzhen price agreed');
await pa.locator('#pu-submit').click();
await pa.waitForURL(/\/docs\/purchase_order\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const po = entryFromUrl(pa.url());
const poNo = (await one('SELECT doc_no FROM erp.doc_workflow WHERE company_code = $1 AND obj_type = 22 AND doc_entry = $2', ['ZZ99', po]))?.doc_no;
ok('PO waits for approval', (await txt(pa.locator('[data-testid=pu-status-card]'))).includes('Waiting for approval'), poNo);
ok('PO approval enforced: no copy to goods receipt yet', await pa.locator('#pu-copy-grpo').isDisabled().catch(() => false));

const C3 = await context(browser);
const pm = await C3.newPage(); watch(pm, 'pmgr');
await login(pm, 'pmgr'); await settle(pm);
await pm.goto(`${BASE}/approvals`); await settle(pm);
await pm.locator(`text=${poNo}`).first().waitFor({ timeout: 10000 }).catch(() => {});
ok('purchasing manager sees the PO in Approvals', (await pm.locator(`[data-testid=inbox-table] >> text=${poNo}`).count()) > 0);
await pm.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(pm);
await pm.locator('[data-testid=pu-approval-card]').waitFor({ timeout: 10000 });
await pm.screenshot({ path: `${OUT}/a6-po-approval-en-light-1440.png`, fullPage: true });
await pm.locator('#pu-approve').click();
await pm.locator('[data-testid=pu-decided-card]').waitFor({ timeout: 10000 });
ok('approved: PO open', (await one('SELECT status FROM erp.document WHERE company_code = $1 AND obj_type = 22 AND doc_entry = $2', ['ZZ99', po]))?.status === 'open');
await C3.close();

// ---------- 4. PI and deposit ----------
await pa.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(pa);
await pa.locator('#pu-pi-add').click();
await pa.locator('#pu-pi-no').fill(`SZ-PI-${uniq}`);
await pa.locator('#pu-pi-eta').fill(ETA);
await pa.locator('#pu-pi-status').selectOption('confirmed');
await pa.locator('#pu-pi-save').click();
await pa.locator('[data-testid=pu-pi-row]').first().waitFor({ timeout: 10000 });
ok('PI recorded with its status', (await txt(pa.locator('[data-testid=pu-pi-row]').first())).includes('PI confirmed'));
await pa.locator('#pu-deposit-add').click();
await pa.locator('#pu-dep-pi').selectOption({ index: 1 });
await pa.locator('#pu-dep-save').click();
await pa.locator('[data-testid=pu-deposit-row]').first().waitFor({ timeout: 10000 });
const dep = await one(`SELECT d.doc_entry, d.total FROM erp.document d JOIN erp.document_line l USING (company_code, obj_type, doc_entry)
                        WHERE d.company_code = 'ZZ99' AND d.obj_type = 204 AND l.base_obj_type = 22 AND l.base_doc_entry = $1`, [po]);
const poTotal = Number((await one('SELECT total FROM erp.document WHERE company_code = $1 AND obj_type = 22 AND doc_entry = $2', ['ZZ99', po])).total);
ok('30 % deposit raised as an A/P down payment invoice', dep && Math.abs(Number(dep.total) - Math.round(poTotal * 30) / 100) < 0.005, `${dep?.total} of ${poTotal}`);
await pa.screenshot({ path: `${OUT}/a6-po-china-en-light-1440.png`, fullPage: true });

// ---------- 5. Pay the deposit in Banking (qa.admin, prefilled from Purchasing) ----------
const C4 = await context(browser);
const pb = await C4.newPage(); watch(pb, 'admin');
await login(pb, 'admin'); await settle(pb);
await pb.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(pb);
await pb.locator(`#pu-pay-${dep.doc_entry}`).click();
await pb.waitForURL(/banking\/payments\/out\/new/, { timeout: 10000 }); await settle(pb);
await pb.locator('[data-testid=bk-doc], #bk-docs').first().waitFor({ timeout: 10000 }).catch(() => {});
await pb.waitForTimeout(1200);
await pb.locator('#bk-submit').click();
await pb.waitForURL(/banking\/payments\/out\/ZZ99\/\d+$/, { timeout: 15000 }).catch(() => {});
await settle(pb);
ok('deposit paid through A5 (payment prefilled from Purchasing)', Number((await one('SELECT paid FROM erp.document WHERE company_code = $1 AND obj_type = 204 AND doc_entry = $2', ['ZZ99', dep.doc_entry])).paid) === Number(dep.total), pb.url());
await C4.close();

// ---------- 6. QC and shipment ----------
await pa.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(pa);
ok('shipment blocked until a passed QC inspection', await pa.locator('#pu-ship-add').isDisabled());
await pa.locator('#pu-qc-add').click();
await pa.locator('#pu-qc-inspector').fill('Li Wei');
for (const c of await pa.locator('[id^=pu-qc-check-]').all()) await c.check();
await pa.locator('#pu-qc-save').click();
await pa.locator('[data-testid=pu-qc-row]').first().waitFor({ timeout: 10000 });
ok('QC pass recorded', (await txt(pa.locator('[data-testid=pu-qc-row]').first())).includes('Pass'));
await pa.locator('#pu-ship-add').click();
await pa.locator('#pu-ship-container').fill(`MSKU${uniq}1`);
await pa.locator('#pu-ship-mark').fill('SANFORD DXB');
await pa.locator('#pu-ship-eta').fill(ETA);
await pa.locator('#pu-ship-save').click();
await pa.locator('[data-testid=pu-ship-row]').first().waitFor({ timeout: 10000 });
ok('shipment recorded (in transit, ETA)', (await txt(pa.locator('[data-testid=pu-ship-row]').first())).includes('In transit'));
const atp = await one(`SELECT (erp._atp('ZZ99', 'SMP-1170', 'WH01', $1::date, erp._atp_rule('ZZ99', 'SMP-1170'))->>'in_transit')::numeric AS it`, [ETA]);
ok('ETA feeds ATP (in transit by the ETA)', Number(atp.it) >= 400, String(atp.it));

// ---------- 7. Goods receipt PO ----------
await pa.locator('#pu-copy-grpo').click();
await pa.waitForURL(/purchasing\/grpo\/new/, { timeout: 10000 }); await settle(pa);
await pa.locator('#pu-pick-0-qty').fill('401');
await pa.locator('#pu-grpo-submit').click();
await pa.locator('[data-testid=bk-error]').waitFor({ timeout: 10000 });
ok('receiving more than the PO is refused with the server message', (await txt(pa.locator('[data-testid=bk-error]'))).includes('you are receiving 401 of SMP-1170 but only 400 are still open'));
await pa.locator('#pu-pick-0-qty').fill('400');
await pa.screenshot({ path: `${OUT}/a6-grpo-form-en-light-1440.png`, fullPage: true });
await pa.locator('#pu-grpo-submit').click();
await pa.waitForURL(/\/docs\/goods_receipt_po\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const gr = entryFromUrl(pa.url());
ok('goods receipt posted (journal)', (await txt(pa.locator('[data-testid=pu-posting]'))).includes('Stock received and posted'));
ok('container arrived', (await one('SELECT status FROM erp.purchase_shipment WHERE company_code = $1 AND po_doc_entry = $2', ['ZZ99', po]))?.status === 'arrived');

// ---------- 8. A/P invoice drawing the deposit ----------
await pa.locator('#pu-copy-ap').click();
await pa.waitForURL(/purchasing\/ap-invoice\/new/, { timeout: 10000 }); await settle(pa);
await pa.locator('[data-testid=pu-draw-row]').first().waitFor({ timeout: 10000 });
await pa.locator('#pu-ref').fill(`INV-${uniq}`);
await pa.waitForTimeout(500);
await pa.screenshot({ path: `${OUT}/a6-ap-form-en-light-1440.png`, fullPage: true });
await pa.locator('#pu-ap-submit').click();
await pa.waitForURL(/\/docs\/ap_invoice\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const ap = entryFromUrl(pa.url());
const apDoc = await one('SELECT total FROM erp.document WHERE company_code = $1 AND obj_type = 18 AND doc_entry = $2', ['ZZ99', ap]);
const draw = await one('SELECT coalesce(sum(amount), 0) AS s FROM erp.ap_dp_draw WHERE company_code = $1 AND invoice_entry = $2', ['ZZ99', ap]);
ok('A/P invoice draws the paid deposit; the rest is due', Math.abs(Number(draw.s) - Number(dep.total)) < 0.005 && Math.abs(Number(apDoc.total) - (poTotal - Number(dep.total))) < 0.01, `${apDoc.total} due, ${draw.s} drawn`);
ok('A/P invoice page shows what is still to pay', (await txt(pa.locator('[data-testid=pu-open-amount]'))).includes('Still to pay'));
await pa.screenshot({ path: `${OUT}/a6-ap-invoice-en-light-1440.png`, fullPage: true });

// ---------- 9. Landed costs ----------
const avg0 = Number((await one(`SELECT avg_cost FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = 'SMP-1170' AND whs_code = 'WH01'`)).avg_cost);
await pa.goto(`${BASE}/docs/goods_receipt_po/ZZ99/${gr}`); await settle(pa);
await pa.locator('#pu-landed').click();
await pa.waitForURL(/landed-costs\/new/, { timeout: 10000 }); await settle(pa);
await pa.locator('[data-testid=lc-line]').first().waitFor({ timeout: 10000 });
await pa.locator('#lc-charge-0-code').selectOption('FREIGHT');
await pa.locator('#lc-charge-0-amount').fill('1000');
await pa.locator('#lc-charge-add').click();
await pa.locator('#lc-charge-1-code').selectOption('DUTY');
await pa.locator('#lc-charge-1-amount').fill('500.55');
await pa.locator('[data-testid=lc-total]').waitFor({ timeout: 10000 });
ok('landed cost preview: split and total shown', money(await txt(pa.locator('[data-testid=lc-total]'))) === 1500.55 && (await pa.locator('[data-testid=lc-split]').count()) === 1);
await pa.screenshot({ path: `${OUT}/a6-landed-form-en-light-1440.png`, fullPage: true });
await pa.locator('#lc-submit').click();
await pa.waitForURL(/landed-costs\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const lcEntry = entryFromUrl(pa.url());
const lcSum = await one('SELECT l.total, (SELECT sum(amount) FROM erp.landed_cost_alloc a WHERE a.company_code = l.company_code AND a.doc_entry = l.doc_entry) AS alloc FROM erp.landed_cost l WHERE company_code = $1 AND doc_entry = $2', ['ZZ99', lcEntry]);
const avg1 = Number((await one(`SELECT avg_cost FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = 'SMP-1170' AND whs_code = 'WH01'`)).avg_cost);
ok('landed costs posted; the split adds up exactly', Number(lcSum.total) === 1500.55 && Number(lcSum.alloc) === 1500.55);
ok('average cost raised by the landed costs', avg1 > avg0, `${avg0} → ${avg1}`);
await pa.screenshot({ path: `${OUT}/a6-landed-cost-en-light-1440.png`, fullPage: true });

// ---------- 10. Flow strip, list filter, setup ----------
await pa.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(pa);
await pa.locator('[data-step=landed][data-state=done]').waitFor({ timeout: 10000 }).catch(() => {});
const states = await pa.locator('[data-testid=pu-flow] [data-step]').evaluateAll((els) => els.map((e) => `${e.getAttribute('data-step')}:${e.getAttribute('data-state')}`));
ok('flow strip: every step done, PO current', states.join(',') === 'request:done,quotation:done,order:current,deposit:done,qc:done,shipment:done,grpo:done,invoice:done,landed:done', states.join(','));
await pa.screenshot({ path: `${OUT}/a6-po-done-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/docs/purchase_order?f_china_office=SZ`); await settle(pa);
await pa.locator('table').first().waitFor({ timeout: 10000 }).catch(() => {});
await pa.locator(`text=${poNo}`).first().waitFor({ timeout: 10000 }).catch(() => {});
const officeSel = await pa.locator('select').evaluateAll((els) => els.map((e) => e.value));
const rowTexts = await pa.locator('tbody tr').allInnerTexts();
ok('China office filter on the PO list', rowTexts.some((r) => r.includes(poNo)) && officeSel.includes('SZ') && rowTexts.every((r) => /\bSZ\b/.test(r)), `${rowTexts.length} rows`);
await pa.goto(`${BASE}/purchasing/setup`); await settle(pa);
ok('Purchasing Setup lists the landed cost codes', (await pa.locator('text=Sea freight').count()) > 0);
await pa.goto(`${BASE}/m/purchasing?fn=17`); await settle(pa);
await pa.goto(`${BASE}/purchasing/landed-costs`); await settle(pa);
ok('landed cost list shows the new document', (await pa.locator(`text=${(await one('SELECT doc_no FROM erp.landed_cost WHERE company_code = $1 AND doc_entry = $2', ['ZZ99', lcEntry])).doc_no}`).count()) > 0);
await C2.close();

// ---------- 11. Access ----------
{
  const C5 = await context(browser);
  const p5 = await C5.newPage(); watch(p5, 'sales');
  await login(p5, 'sales'); await settle(p5);
  await p5.goto(`${BASE}/docs/purchase_order/ZZ99/${po}`); await settle(p5);
  ok('sales-only user: no access to Purchasing', (await p5.locator('text=does not include Purchasing').count()) > 0);
  await C5.close();
}
await C.close();

// ---------- 12. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['po', `/docs/purchase_order/ZZ99/${po}`],
  ['compare', `/purchasing/compare/ZZ99/${req}`],
  ['request-form', '/docs/purchase_request/new'],
  ['grpo', `/docs/goods_receipt_po/ZZ99/${gr}`],
  ['ap-invoice', `/docs/ap_invoice/ZZ99/${ap}`],
  ['landed-cost', `/purchasing/landed-costs/ZZ99/${lcEntry}`],
  ['po-list', '/docs/purchase_order'],
  ['setup', '/purchasing/setup'],
];
for (const [lang, theme, width] of [['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'purch'); await settle(page);
  let scrollOk = true;
  for (const [name, p] of shots) {
    await page.goto(`${BASE}${p}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(500);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${name}`); }
    await page.screenshot({ path: `${OUT}/a6-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA6 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

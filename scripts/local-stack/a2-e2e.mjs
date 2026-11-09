// A2 browser test: sales order with approval, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright> node scripts/local-stack/a2-e2e.mjs [outDir]
// Two browser contexts: qa.sales raises an order with 18 % discount, qa.salesmgr approves it at 10 %. Also the reject path,
// read-only user, phone width (390 px), light/dark and English/Arabic screenshots.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import fs from 'node:fs';

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const API = process.env.API_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a2-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  sales: ['qa.sales@sample.test', 'local-only-2'],
  mgr: ['qa.salesmgr@sample.test', 'local-only-7'],
  sread: ['qa.salesread@sample.test', 'local-only-6'],
};
async function login(page, who) {
  const [email, password] = USERS[who];
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
async function token(who) {
  const [email, password] = USERS[who];
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { 'content-type': 'application/json', apikey: 'local' }, body: JSON.stringify({ email, password }) });
  return (await r.json()).access_token;
}
async function rpc(tok, fn, args) {
  const r = await fetch(`${API}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: 'local', authorization: `Bearer ${tok}`, 'content-type': 'application/json', 'content-profile': 'erp', 'accept-profile': 'erp' },
    body: JSON.stringify(args),
  });
  return { status: r.status, body: await r.json() };
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
/** Fill the first (or n-th) line of the order form. */
async function fillLine(page, n, item, { qty, price, disc } = {}) {
  const line = page.locator('[data-testid=so-line]').nth(n);
  await pickCombo(page, line.locator('input[role=combobox]'), item, item);
  if (qty !== undefined) await line.locator('input[id$="-qty"]').fill(String(qty));
  if (price !== undefined) await line.locator('input[id$="-price"]').fill(String(price));
  if (disc !== undefined) await line.locator('input[id$="-discount_pct"]').fill(String(disc));
}
const entryFromUrl = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());
/** The order page is ready when its totals and its state pill are on screen. */
async function orderReady(page) {
  await settle(page);
  await page.locator('[data-testid=so-total]').waitFor({ timeout: 15000 }).catch(() => {});
  await page.locator('h1 .pill >> nth=1').waitFor({ timeout: 15000 }).catch(() => {});
}

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- API: the database enforces the rules ----------
{
  const sread = await token('sread');
  const r = await rpc(sread, 'sales_order_save', { p_company: 'ZZ99', p_doc_entry: null, p_header: { card_code: 'C0011', doc_date: '2026-11-09', whs_code: 'WH01' }, p_lines: [{ item_code: 'SMP-1010', qty: 1 }] });
  ok('API: read-only user cannot save an order', r.status === 403 && /read-only access to Sales/.test(r.body.message), `${r.status} ${r.body.message}`);
  const sales = await token('sales');
  const v = await rpc(sales, 'sales_order_save', { p_company: 'ZZ99', p_doc_entry: null, p_header: { card_code: 'C0018', doc_date: '2026-11-09', whs_code: 'WH01' }, p_lines: [{ item_code: 'SMP-1010', qty: 1 }] });
  ok('API: inactive customer refused with the exact message', v.body.message === 'Customer C0018 is inactive. Choose an active customer.', v.body.message);
  const w = await fetch(`${API}/rest/v1/doc_workflow?select=state`, { method: 'PATCH', headers: { apikey: 'local', authorization: `Bearer ${sales}`, 'content-type': 'application/json', 'content-profile': 'erp' }, body: JSON.stringify({ state: 'approved' }) });
  ok('API: direct PATCH on doc_workflow refused', w.status === 401 || w.status === 403, String(w.status));
}

// ---------- 1. qa.sales creates an order with 18 % discount ----------
const A = await context(browser);
const pa = await A.newPage(); watch(pa, 'sales');
await login(pa, 'sales'); await settle(pa);
await pa.goto(`${BASE}/docs/sales_order`); await settle(pa);
const newLink = pa.locator('a#new-sales');
ok('sales user: "+ New sales order" is enabled (a link)', (await newLink.count()) === 1 && (await newLink.isVisible()));
await newLink.click();
await pa.waitForURL(/\/docs\/sales_order\/new$/); await settle(pa);
await pickCombo(pa, pa.locator('#so-card_code'), 'C0011', 'C0011');
await fillLine(pa, 0, 'SMP-1010', { qty: 10, price: '133.16', disc: 18 });
await pa.locator('[data-testid=so-preview]', { hasText: 'Needs approval' }).waitFor({ timeout: 10000 }).catch(() => {});
const preview = await pa.locator('[data-testid=so-preview]').innerText().catch(() => '');
ok('Submit preview says "Needs approval: discount above your 10% limit"', /Needs approval: discount above your 10% limit/.test(preview), preview.replace(/\n/g, ' | '));
ok('line breaking the rule shows the warn note', (await pa.locator('[data-testid=so-line].bg-warn-bg', { hasText: 'Discount 18% is above your limit of 10%' }).count()) === 1);
ok('live total 1,146.51 while typing', (await pa.locator('[data-testid=so-total]').innerText()).includes('1,146.51'), await pa.locator('[data-testid=so-total]').innerText());
await pa.screenshot({ path: `${OUT}/a2-form-needs-approval-en-light-1440.png`, fullPage: true });
await pa.click('#so-submit');
ok('Submit without a reason asks for one', await pa.locator('#so-reason-err', { hasText: 'Add a reason for the approver.' }).isVisible().catch(() => false));
await pa.fill('#so-reason', 'Launch promotion agreed with the buyer');
await pa.click('#so-submit');
await pa.waitForURL(/\/docs\/sales_order\/ZZ99\/\d+$/, { timeout: 15000 }); await orderReady(pa);
const entry = entryFromUrl(pa.url());
ok('2. submitted: "Waiting approval" on the order page', (await pa.locator('h1 .pill', { hasText: 'Waiting approval' }).count()) === 1, `entry ${entry}`);
ok('flash: "Submitted for approval"', (await pa.locator('[role=status]', { hasText: 'Submitted for approval' }).count()) === 1);
ok('source pill "Super ERP"', (await pa.locator('h1 .pill', { hasText: 'Super ERP' }).count()) === 1);
const docNo = (await pa.locator('h1').innerText()).match(/SO-26-\d+/)?.[0];
ok('order number from the series (SO-26-…)', Boolean(docNo), docNo);
ok('submitter sees "You can’t approve your own order." and no approve button', (await pa.locator('text=You can’t approve your own order.').count()) === 1 && (await pa.locator('#so-approve').count()) === 0);
await pa.screenshot({ path: `${OUT}/a2-order-waiting-sales-en-light-1440.png`, fullPage: true });

// ---------- 3. qa.salesmgr sees it in Approvals and approves at 10 % ----------
const B = await context(browser);
const pb = await B.newPage(); watch(pb, 'mgr');
await login(pb, 'mgr'); await settle(pb);
ok('home: "Waiting for my approval" KPI for the approver', await pb.locator('a', { hasText: 'Waiting for my approval' }).first().isVisible().catch(() => false));
await pb.screenshot({ path: `${OUT}/a2-home-approver-en-light-1440.png`, fullPage: true });
await pb.goto(`${BASE}/approvals`); await settle(pb);
const row = pb.locator('[data-testid=inbox-table] a', { hasText: docNo ?? 'SO-26-' });
ok('3. order is in Approvals › Documents › Waiting for me', (await row.count()) === 1);
await pb.screenshot({ path: `${OUT}/a2-approvals-waiting-en-light-1440.png`, fullPage: true });
await row.click(); await orderReady(pb);
await pb.locator('[data-testid=so-approval-card]').waitFor({ timeout: 10000 }).catch(() => {});
ok('approval card: "Your approval is needed" with the reason', (await pb.locator('[data-testid=so-approval-card]', { hasText: 'Your approval is needed' }).count()) === 1
  && (await pb.locator('[data-testid=so-approval-card]', { hasText: 'Launch promotion agreed with the buyer' }).count()) === 1);
ok('"Approve at 10%" offered', (await pb.locator('#so-approve-at').innerText().catch(() => '')).includes('10%'));
await pb.screenshot({ path: `${OUT}/a2-order-approval-card-mgr-en-light-1440.png`, fullPage: true });
await pb.click('#so-approve-at');
await pb.locator('[role=status]', { hasText: 'Approved. The order is open.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('approved at 10 %: flash and green card', (await pb.locator('[data-testid=so-decided-card]', { hasText: 'Approved by you' }).count()) === 1);
await pb.screenshot({ path: `${OUT}/a2-order-approved-mgr-en-light-1440.png`, fullPage: true });

// ---------- 4. qa.sales sees Approved, updated totals, Open in the list ----------
await pa.reload(); await orderReady(pa);
ok('4. sales user sees "Approved"', (await pa.locator('h1 .pill', { hasText: 'Approved' }).count()) === 1);
ok('totals updated to 1,258.36 (10 %)', (await pa.locator('[data-testid=so-total]').innerText()).includes('1,258.36'), await pa.locator('[data-testid=so-total]').innerText());
ok('discount shows 10%', (await pa.locator('[data-testid=so-disc]').first().innerText()).includes('10%'));
ok('activity: created, sent for approval, approved', (await pa.locator('[data-testid=so-activity] li').count()) === 3);
// A4 made Copy to delivery real: once the order is approved and open it is a link to the delivery form.
ok('Copy to delivery enabled once approved (A4)', (await pa.locator('a#so-copy', { hasText: 'Copy to delivery' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a2-order-approved-sales-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/docs/sales_order?f_source=erp`); await settle(pa);
const listRow = pa.locator('main table tbody tr', { hasText: docNo ?? 'SO-26-' });
ok('order in the list as Open (source filter Super ERP)', (await listRow.locator('.pill', { hasText: 'Open' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a2-list-source-erp-en-light-1440.png`, fullPage: true });

// ---------- Reject path ----------
{
  const sales = await token('sales');
  const s = await rpc(sales, 'sales_order_save', { p_company: 'ZZ99', p_doc_entry: null, p_header: { card_code: 'C0011', doc_date: '2026-11-09', whs_code: 'WH01' },
    p_lines: [{ item_code: 'SMP-1040', qty: 4, discount_pct: 20, tax_code: 'SR' }] });
  const rej = s.body.doc_entry;
  await rpc(sales, 'sales_order_submit', { p_company: 'ZZ99', p_doc_entry: rej, p_reason: 'Clearance of old stock' });
  await pa.goto(`${BASE}/docs/sales_order?f_state=pending_approval`); await settle(pa);
  ok('list filter "Waiting approval" shows the pending order', (await pa.locator('main table tbody tr', { hasText: s.body.doc_no }).count()) === 1);
  await pb.goto(`${BASE}/docs/sales_order/ZZ99/${rej}`); await orderReady(pb);
  await pb.click('#so-reject');
  await pb.click('#so-reject-confirm');
  ok('reject without a note: message in the dialog', await pb.locator('#so-reject-err', { hasText: 'Add a note saying why you are rejecting this order.' }).isVisible().catch(() => false));
  await pb.screenshot({ path: `${OUT}/a2-reject-dialog-en-light-1440.png` });
  await pb.fill('#so-reject-note', 'Too much for this customer — 10 % at most');
  await pb.click('#so-reject-confirm');
  await pb.locator('[data-testid=so-decided-card]', { hasText: 'Rejected by you' }).waitFor({ timeout: 10000 }).catch(() => {});
  ok('rejected: red card for the approver', (await pb.locator('[data-testid=so-decided-card]', { hasText: 'Rejected by you' }).count()) === 1);
  await pa.goto(`${BASE}/docs/sales_order/ZZ99/${rej}`); await orderReady(pa);
  ok('requester sees Rejected, the note and "Edit and resubmit"', (await pa.locator('h1 .pill', { hasText: 'Rejected' }).count()) === 1
    && (await pa.locator('text=Too much for this customer').count()) > 0 && (await pa.locator('#so-edit', { hasText: 'Edit and resubmit' }).count()) === 1);
  await pa.screenshot({ path: `${OUT}/a2-order-rejected-sales-en-light-1440.png`, fullPage: true });
  await pa.click('#so-edit'); await settle(pa);
  await pa.locator('[data-testid=so-line] input[id$="-discount_pct"]').first().fill('10');
  await pa.locator('[data-testid=so-preview]', { hasText: 'Goes straight to Open' }).waitFor({ timeout: 10000 }).catch(() => {});
  ok('edit: 10 % now "Goes straight to Open"', (await pa.locator('[data-testid=so-preview]', { hasText: 'Goes straight to Open' }).count()) === 1);
  // A4: SMP-1040 has nothing Available-to-Promise in WH01, so the promise needs a confirming reason.
  if (await pa.locator('#so-reason').count()) await pa.fill('#so-reason', 'Container due next week');
  await pa.click('#so-submit');
  await pa.waitForURL(new RegExp(`/docs/sales_order/ZZ99/${rej}$`), { timeout: 15000 }); await orderReady(pa);
  await pa.locator('h1 .pill', { hasText: 'Approved' }).waitFor({ timeout: 10000 }).catch(() => {});
  ok('resubmitted: approved straight away (Open)', (await pa.locator('h1 .pill', { hasText: 'Approved' }).count()) === 1);
  await pb.goto(`${BASE}/approvals?view=decided`); await settle(pb);
  ok('Approvals › Decided lists both decisions', (await pb.locator('[data-testid=inbox-table] tbody tr').count()) >= 2);
  await pb.screenshot({ path: `${OUT}/a2-approvals-decided-en-light-1440.png`, fullPage: true });
}
await A.close(); await B.close();

// ---------- Read-only user: can read, cannot create ----------
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'sread');
  await login(page, 'sread'); await settle(page);
  await page.goto(`${BASE}/docs/sales_order/new`); await settle(page);
  ok('read-only user: Submit disabled with "Read-only access to Sales"', (await page.locator('#so-submit').isDisabled()) && (await page.locator('text=Read-only access to Sales').count()) > 0);
  await page.screenshot({ path: `${OUT}/a2-form-readonly-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

// ---------- Screens in every theme, language and width ----------
for (const [width, lang, theme] of [[1440, 'en', 'dark'], [1440, 'ar', 'light'], [1440, 'ar', 'dark'], [390, 'en', 'light'], [390, 'en', 'dark'], [390, 'ar', 'light'], [390, 'ar', 'dark']]) {
  const tag = `${lang}-${theme}-${width}`;
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, tag);
  await login(page, 'sales'); await settle(page);
  await page.goto(`${BASE}/docs/sales_order/new`); await settle(page);
  await pickCombo(page, page.locator('#so-card_code'), 'C0011', 'C0011');
  await fillLine(page, 0, 'SMP-1010', { qty: 6, disc: 15 });
  await page.locator('[data-testid=so-preview]').waitFor({ timeout: 10000 }).catch(() => {});
  if (width === 390) ok(`form: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
  if (lang === 'ar' && width === 1440 && theme === 'light') ok('Arabic form: RTL and Arabic labels', (await page.evaluate(() => document.documentElement.dir)) === 'rtl' && (await page.locator('text=أمر بيع جديد').count()) > 0);
  await page.screenshot({ path: `${OUT}/a2-form-${tag}.png`, fullPage: true });
  await page.goto(`${BASE}/docs/sales_order/ZZ99/${entry}`); await orderReady(page);
  if (width === 390) ok(`order page: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
  await page.screenshot({ path: `${OUT}/a2-order-${tag}.png`, fullPage: true });
  await page.goto(`${BASE}/approvals?view=sent`); await settle(page);
  if (width === 390) ok(`approvals: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
  await page.screenshot({ path: `${OUT}/a2-approvals-sent-${tag}.png`, fullPage: true });
  await ctx.close();
}

// Approver at phone width: approval card fits.
{
  const sales = await token('sales');
  const s = await rpc(sales, 'sales_order_save', { p_company: 'ZZ99', p_doc_entry: null, p_header: { card_code: 'C0011', doc_date: '2026-11-09', whs_code: 'WH01' },
    p_lines: [{ item_code: 'SMP-1020', qty: 12, discount_pct: 14, tax_code: 'SR' }] });
  await rpc(sales, 'sales_order_submit', { p_company: 'ZZ99', p_doc_entry: s.body.doc_entry, p_reason: 'Opening order for a new branch' });
  for (const [lang, theme] of [['en', 'light'], ['ar', 'dark']]) {
    const ctx = await context(browser, { width: 390, height: 844, lang, theme });
    const page = await ctx.newPage(); watch(page, `mgr-390-${lang}`);
    await login(page, 'mgr'); await settle(page);
    await page.goto(`${BASE}/docs/sales_order/ZZ99/${s.body.doc_entry}`); await orderReady(page);
    ok(`approval card at 390 px (${lang}, ${theme})`, (await page.locator('[data-testid=so-approval-card]').isVisible().catch(() => false)) && (await noHScroll(page)));
    await page.screenshot({ path: `${OUT}/a2-order-approval-card-mgr-${lang}-${theme}-390.png`, fullPage: true });
    await ctx.close();
  }
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await browser.close();
fs.writeFileSync(`${OUT}/a2-results.json`, JSON.stringify(results, null, 1));
const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

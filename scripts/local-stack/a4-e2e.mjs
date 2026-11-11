// A4 browser test: sales cycle, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright> node scripts/local-stack/a4-e2e.mjs [outDir]
// qa.sales: quotation (12 %) → qa.salesmgr approves → Copy to sales order (base links, remaining qty) → approval →
// Copy to delivery (over-delivery refused, partial 10 of 15) → Copy to A/R invoice (6 of 10 + a service line; closed
// period refused) → Copy to credit memo (2 back to stock) → print (EN/AR, TRN). ATP warning on a new order, ATP check and
// ATP rule list, lists and approvals, read-only user. Screenshots 1440 / 390, light / dark, EN / AR.
// Leaves the posted test documents behind (they are Super ERP documents of the sample company); the period is reopened.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import fs from 'node:fs';

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const API = process.env.API_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a4-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const money = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
  sread: ['qa.salesread@sample.test', 'local-only-6'],
  mgr: ['qa.salesmgr@sample.test', 'local-only-7'],
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
  return { status: r.status, body: await r.json().catch(() => null) };
}
async function get(tok, path) {
  const r = await fetch(`${API}/rest/v1/${path}`, { headers: { apikey: 'local', authorization: `Bearer ${tok}`, 'accept-profile': 'erp' } });
  return r.json();
}
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); localStorage.setItem('sf-remember', '1'); }, [lang, theme]);  // U0: "Remember me" so a second tab of the same context shares the session
  return ctx;
}
async function pickCombo(page, input, text, optionText) {
  await input.click();
  await input.fill(text);
  const opt = page.locator('[role=listbox] [role=option]', { hasText: optionText }).first();
  await opt.waitFor({ timeout: 10000 });
  await opt.click();
}
async function fillLine(page, n, item, { qty, price, disc } = {}) {
  const line = page.locator('[data-testid=so-line]').nth(n);
  await pickCombo(page, line.locator('input[role=combobox]'), item, item);
  if (qty !== undefined) await line.locator('input[id$="-qty"]').fill(String(qty));
  if (price !== undefined) await line.locator('input[id$="-price"]').fill(String(price));
  if (disc !== undefined) await line.locator('input[id$="-discount_pct"]').fill(String(disc));
}
const entryFromUrl = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());
async function docReady(page) {
  await settle(page);
  await page.locator('[data-testid=so-total]').first().waitFor({ timeout: 15000 }).catch(() => {});
  await page.locator('[data-testid=doc-flow]').waitFor({ timeout: 15000 }).catch(() => {});
}
const stock = async (tok, item) => (await get(tok, `stock_balance?company_code=eq.ZZ99&item_code=eq.${item}&whs_code=eq.WH01&select=on_hand,committed`))[0];
const balance = async (tok) => Number((await get(tok, 'business_partner?company_code=eq.ZZ99&card_code=eq.C0011&select=balance'))[0].balance);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const salesTok = await token('sales');
const s1010 = await stock(salesTok, 'SMP-1010');
const bal0 = await balance(salesTok);

// ---------- API: the database enforces the rules ----------
{
  const sread = await token('sread');
  const r = await rpc(sread, 'sales_doc_save', { p_company: 'ZZ99', p_obj: 23, p_doc_entry: null, p_header: { card_code: 'C0011', doc_date: '2026-11-09' }, p_lines: [{ item_code: 'SMP-1010', qty: 1 }] });
  ok('API: read-only user cannot save a quotation', r.status === 403 && /create quotations/.test(r.body?.message ?? ''), `${r.status} ${r.body?.message}`);
  const w = await fetch(`${API}/rest/v1/stock_balance?company_code=eq.ZZ99`, { method: 'PATCH', headers: { apikey: 'local', authorization: `Bearer ${salesTok}`, 'content-type': 'application/json', 'content-profile': 'erp' }, body: JSON.stringify({ on_hand: 0 }) });
  ok('API: direct PATCH on stock_balance refused', w.status === 401 || w.status === 403, String(w.status));
}

// ---------- 1. Quotation with 12 % → approval ----------
const A = await context(browser);
const pa = await A.newPage(); watch(pa, 'sales');
await login(pa, 'sales'); await settle(pa);
await pa.goto(`${BASE}/docs/sales_quotation`); await settle(pa);
ok('quotations list: "+ New sales quotation" is a link', (await pa.locator('a#new-sales_quotation').count()) === 1);
await pa.click('a#new-sales_quotation');
await pa.waitForURL(/\/docs\/sales_quotation\/new$/); await settle(pa);
await pa.locator('h1', { hasText: 'New sales quotation' }).waitFor({ timeout: 15000 }).catch(() => {}); // A14: pages are lazy-loaded
ok('quotation form: title and "Valid until"', (await pa.locator('h1', { hasText: 'New sales quotation' }).count()) === 1 && (await pa.locator('label', { hasText: 'Valid until' }).count()) === 1);
await pickCombo(pa, pa.locator('#so-card_code'), 'C0011', 'C0011');
await fillLine(pa, 0, 'SMP-1010', { qty: 20, disc: 12 });
await pa.locator('[data-testid=so-preview]', { hasText: 'Needs approval' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('quotation: same discount rule (needs approval above 10 %)', (await pa.locator('[data-testid=so-preview]', { hasText: 'Needs approval' }).count()) === 1);
ok('quotation: no ATP note (orders only) and no credit card', (await pa.locator('[data-testid=atp-note]').count()) === 0 && (await pa.locator('h2', { hasText: 'Customer credit' }).count()) === 0);
await pa.screenshot({ path: `${OUT}/a4-quotation-form-en-light-1440.png`, fullPage: true });
await pa.fill('#so-reason', 'Price agreed for the 2027 range');
await pa.click('#so-submit');
await pa.waitForURL(/\/docs\/sales_quotation\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(pa);
const qEntry = entryFromUrl(pa.url());
const qNo = (await pa.locator('h1').innerText()).match(/SQ-26-\d+/)?.[0];
ok('quotation submitted: SQ number, "Waiting approval"', Boolean(qNo) && (await pa.locator('h1 .pill', { hasText: 'Waiting approval' }).count()) === 1, qNo);
ok('quotation: Copy to sales order disabled until approved', await pa.locator('#so-copy').isDisabled().catch(() => false));

const B = await context(browser);
const pb = await B.newPage(); watch(pb, 'mgr');
await login(pb, 'mgr'); await settle(pb);
await pb.goto(`${BASE}/approvals`); await settle(pb);
ok('Approvals: the quotation waits for the sales manager', (await pb.locator('[data-testid=inbox-table] tr', { hasText: qNo ?? 'SQ-26-' }).filter({ hasText: 'Sales quotation' }).count()) === 1);
await pb.goto(`${BASE}/docs/sales_quotation/ZZ99/${qEntry}`); await docReady(pb);
await pb.click('#so-approve');
await pb.locator('[role=status]', { hasText: 'The quotation is open' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('manager approves the quotation', (await pb.locator('[role=status]', { hasText: 'Approved. The quotation is open.' }).count()) === 1);

// ---------- 2. Copy to sales order ----------
await pa.reload(); await docReady(pa);
const copyQ = pa.locator('a#so-copy', { hasText: 'Copy to sales order' });
ok('approved quotation: Copy to sales order is a link', (await copyQ.count()) === 1);
await copyQ.click();
await pa.waitForURL(/\/docs\/sales_order\/new\?/); await settle(pa);
await pa.locator('[data-testid=so-line]').first().waitFor({ timeout: 10000 }).catch(() => {});
const line0 = pa.locator('[data-testid=so-line]').first();
ok('order prefilled from the quotation: item fixed, 20 left, base noted', (await line0.locator('input[role=combobox]').count()) === 0
  && (await line0.locator('input[id$="-qty"]').inputValue()) === '20' && (await line0.innerText()).includes(`from ${qNo}`), await line0.innerText().catch(() => ''));
await line0.locator('input[id$="-qty"]').fill('15');
await pa.locator('[data-testid=atp-note]').first().waitFor({ timeout: 10000 }).catch(() => {});
ok('ATP: "Can promise n by date" on the order line', /Can promise [\d,]+ by/.test(await pa.locator('[data-testid=atp-note]').first().innerText().catch(() => '')));
ok('flow strip: quotation done, order current', (await pa.locator('[data-testid=doc-flow] [data-step=order][data-state=current]').count()) === 1);
await pa.screenshot({ path: `${OUT}/a4-order-from-quotation-en-light-1440.png`, fullPage: true });
await pa.fill('#so-reason', 'Same terms as the quotation');
await pa.click('#so-submit');
await pa.waitForURL(/\/docs\/sales_order\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(pa);
const oEntry = entryFromUrl(pa.url());
const oNo = (await pa.locator('h1').innerText()).match(/SO-26-\d+/)?.[0];
ok('order from quotation waits for approval', (await pa.locator('h1 .pill', { hasText: 'Waiting approval' }).count()) === 1, oNo);
await pb.goto(`${BASE}/docs/sales_order/ZZ99/${oEntry}`); await docReady(pb);
await pb.click('#so-approve');
await pb.locator('[role=status]', { hasText: 'The order is open' }).waitFor({ timeout: 10000 }).catch(() => {});
await pa.reload(); await docReady(pa);
ok('order approved: flow shows the quotation as done (link)', (await pa.locator(`[data-testid=doc-flow] [data-step=quotation][data-state=done] a`, { hasText: qNo ?? 'SQ' }).count()) === 1);
const qInfo = await get(salesTok, `document_line?company_code=eq.ZZ99&obj_type=eq.23&doc_entry=eq.${qEntry}&select=open_qty`);
ok('quotation now has 5 left (20 − 15)', Number(qInfo[0]?.open_qty) === 5, JSON.stringify(qInfo));
ok('stock committed +15 for SMP-1010', Number((await stock(salesTok, 'SMP-1010')).committed) === Number(s1010.committed) + 15);

// ATP warning on a new order (nothing to promise for SMP-1040 in WH01)
{
  const P = await A.newPage(); watch(P, 'sales-atp');
  await P.goto(`${BASE}/docs/sales_order/new`); await settle(P);
  await pickCombo(P, P.locator('#so-card_code'), 'C0011', 'C0011');
  await fillLine(P, 0, 'SMP-1040', { qty: 5 });
  await P.locator('[data-testid=so-line].bg-warn-bg', { hasText: 'can promise only 0' }).waitFor({ timeout: 10000 }).catch(() => {});
  ok('ATP warning: line above Available-to-Promise is flagged', (await P.locator('[data-testid=so-line].bg-warn-bg', { hasText: 'you are promising 5 of SMP-1040 but can promise only 0' }).count()) === 1);
  ok('ATP: submit asks for a reason to confirm the promise', (await P.locator('label', { hasText: 'Reason for promising more than available' }).count()) === 1
    && (await P.locator('[data-testid=so-preview]', { hasText: 'Add a reason to confirm' }).count()) === 1);
  await P.screenshot({ path: `${OUT}/a4-order-atp-warning-en-light-1440.png`, fullPage: true });
  await P.click('#so-submit');
  ok('ATP: submit without the reason is stopped', await P.locator('#so-reason-err', { hasText: 'Add a reason to confirm the promise.' }).isVisible().catch(() => false));
  await P.close();
}

// ---------- 3. Copy to delivery: over-delivery refused, then partial ----------
const copyO = pa.locator('a#so-copy', { hasText: 'Copy to delivery' });
ok('approved order: Copy to delivery is a link', (await copyO.count()) === 1);
await copyO.click();
await pa.waitForURL(/\/docs\/delivery\/new\?/); await settle(pa);
await pa.locator('[data-testid=pick-line]').first().waitFor({ timeout: 10000 }).catch(() => {});
ok('delivery form: order line with 15 open, warehouse WH01', (await pa.locator('#pick-0-qty').inputValue()) === '15' && (await pa.locator('#pick-0-whs').inputValue()) === 'WH01');
await pa.fill('#pick-0-qty', '16');
ok('over-delivery: warning before saving', (await pa.locator('[data-testid=pick-line]', { hasText: 'More than the 15 still open' }).count()) === 1);
await pa.click('#sc-submit');
await pa.locator('[data-testid=sc-error]').waitFor({ timeout: 10000 }).catch(() => {});
ok('over-delivery refused by the server (message as written)', (await pa.locator('[data-testid=sc-error]').innerText().catch(() => '')) === `Line 1: you are delivering 16 of SMP-1010 but only 15 are still open on sales order ${oNo}.`,
  await pa.locator('[data-testid=sc-error]').innerText().catch(() => ''));
await pa.screenshot({ path: `${OUT}/a4-delivery-over-refused-en-light-1440.png`, fullPage: true });
await pa.fill('#pick-0-qty', '10');
await pa.fill('#sc-comments', 'Partial — rest next week');
await pa.click('#sc-submit');
await pa.waitForURL(/\/docs\/delivery\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(pa);
const dEntry = entryFromUrl(pa.url());
const dNo = (await pa.locator('h1').innerText()).match(/DN-26-\d+/)?.[0];
ok('delivery added: DN number and flash', Boolean(dNo) && (await pa.locator('[role=status]', { hasText: 'Stock and cost of goods sold are posted' }).count()) === 1, dNo);
ok('delivery: COGS journal shown on the page', (await pa.locator('[data-testid=sc-posting]', { hasText: 'Cost of goods sold posted' }).count()) === 1);
ok('delivery: flow quotation → order done, delivery current', (await pa.locator('[data-testid=doc-flow] [data-state=done]').count()) >= 2 && (await pa.locator('[data-testid=doc-flow] [data-step=delivery][data-state=current]').count()) === 1);
const s1010b = await stock(salesTok, 'SMP-1010');
ok('stock: on hand −10, committed −10', Number(s1010b.on_hand) === Number(s1010.on_hand) - 10 && Number(s1010b.committed) === Number(s1010.committed) + 5, JSON.stringify(s1010b));
await pa.screenshot({ path: `${OUT}/a4-delivery-en-light-1440.png`, fullPage: true });
{
  const ol = await get(salesTok, `document_line?company_code=eq.ZZ99&obj_type=eq.17&doc_entry=eq.${oEntry}&select=open_qty,line_status`);
  ok('order line: 5 still open', Number(ol[0].open_qty) === 5 && ol[0].line_status === 'O');
}

// ---------- 4. Copy to A/R invoice (+ service line); closed period refused ----------
const finTok = await token('fin');
const closeP = await rpc(finTok, 'period_set_status', { p_company: 'ZZ99', p_period: '2026-10', p_status: 'closed' });
ok('finance closes 2026-10 for the test', closeP.status === 200, JSON.stringify(closeP.body).slice(0, 120));
await pa.click('a#sc-copy');
await pa.waitForURL(/\/docs\/ar_invoice\/new\?/); await settle(pa);
await pa.locator('[data-testid=pick-line]').first().waitFor({ timeout: 10000 }).catch(() => {});
ok('invoice form: the delivery line is picked with 10 open', (await pa.locator('#pick-0-sel').isChecked()) && (await pa.locator('#pick-0-qty').inputValue()) === '10');
await pa.fill('#pick-0-qty', '6');
await pa.click('#svc-add');
await pickCombo(pa, pa.locator('[data-testid=svc-line] input[role=combobox]').first(), 'SVC', 'SMP-SVC-01');
await pa.fill('#sc-doc_date', '2026-10-15');
await pa.click('#sc-submit');
await pa.locator('[data-testid=sc-error]').waitFor({ timeout: 10000 }).catch(() => {});
ok('invoice in a closed period refused', (await pa.locator('[data-testid=sc-error]').innerText().catch(() => '')).startsWith('Posting period 2026-10 is closed'), await pa.locator('[data-testid=sc-error]').innerText().catch(() => ''));
await pa.screenshot({ path: `${OUT}/a4-invoice-closed-period-en-light-1440.png`, fullPage: true });
await rpc(finTok, 'period_set_status', { p_company: 'ZZ99', p_period: '2026-10', p_status: 'open' });
await pa.fill('#sc-doc_date', '2026-11-10');
await pa.fill('#sc-ref', 'PO-7781');
await pa.click('#sc-submit');
await pa.waitForURL(/\/docs\/ar_invoice\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(pa);
const iEntry = entryFromUrl(pa.url());
const iNo = (await pa.locator('h1').innerText()).match(/IN-26-\d+/)?.[0];
const iTotal = money(await pa.locator('[data-testid=so-total]').innerText());
ok('invoice added: IN number, 2 lines, posting shown', Boolean(iNo) && (await pa.locator('[data-testid=sc-line]').count()) === 2
  && (await pa.locator('[data-testid=sc-posting]', { hasText: 'Receivable, revenue and VAT posted' }).count()) === 1, `${iNo} ${iTotal}`);
ok('invoice total = 6 × 133.16 − 12 % + 150 service, plus 5 % VAT', Math.abs(iTotal - Math.round((Math.round(6 * 133.16 * 0.88 * 100) / 100 + 150) * 1.05 * 100) / 100) < 0.02, String(iTotal));
ok('customer balance up by the invoice total', Math.abs((await balance(salesTok)) - (bal0 + iTotal)) < 0.01);
await pa.screenshot({ path: `${OUT}/a4-invoice-en-light-1440.png`, fullPage: true });

// ---------- 5. Copy to credit memo, goods back to stock ----------
await pa.click('a#sc-copy');
await pa.waitForURL(/\/docs\/ar_credit_note\/new\?/); await settle(pa);
await pa.locator('[data-testid=pick-line]').first().waitFor({ timeout: 10000 }).catch(() => {});
await pa.fill('#pick-0-qty', '2');
await pa.uncheck('#pick-1-sel');
ok('credit memo: Return the goods to stock is ticked', await pa.locator('#sc-return').isChecked());
await pa.fill('#sc-comments', '2 damaged in transit');
await pa.click('#sc-submit');
await pa.waitForURL(/\/docs\/ar_credit_note\/ZZ99\/\d+$/, { timeout: 15000 }); await docReady(pa);
const cTotal = money(await pa.locator('[data-testid=so-total]').innerText());
ok('credit memo added: revenue and VAT reversed, goods back', (await pa.locator('[data-testid=sc-posting]', { hasText: 'Goods back in stock' }).count()) === 1, String(cTotal));
ok('credit memo total = 2 × 133.16 − 12 % + VAT', Math.abs(cTotal - Math.round(Math.round(2 * 133.16 * 0.88 * 100) / 100 * 1.05 * 100) / 100) < 0.02, String(cTotal));
ok('flow on the credit memo shows all five steps', (await pa.locator('[data-testid=doc-flow] [data-step=credit][data-state=current]').count()) === 1
  && (await pa.locator('[data-testid=doc-flow] [data-state=done]').count()) === 4);
const s1010c = await stock(salesTok, 'SMP-1010');
ok('stock reconciles: on hand −10 +2', Number(s1010c.on_hand) === Number(s1010.on_hand) - 8, JSON.stringify(s1010c));
ok('balance reconciles: + invoice − credit memo', Math.abs((await balance(salesTok)) - (bal0 + iTotal - cTotal)) < 0.01);
await pa.screenshot({ path: `${OUT}/a4-credit-memo-en-light-1440.png`, fullPage: true });

// ---------- 6. Print / PDF ----------
await pa.goto(`${BASE}/docs/ar_invoice/ZZ99/${iEntry}`); await docReady(pa);
await pa.click('a#sc-print');
await pa.waitForURL(/\/print\/ar_invoice\/ZZ99\/\d+$/); await settle(pa);
await pa.locator('[data-testid=print-sheet]').waitFor({ timeout: 10000 }).catch(() => {});
ok('print: Tax invoice (EN + AR title), company TRN, number, lines', (await pa.locator('[data-testid=print-title]').textContent().catch(() => '')).includes('Tax invoice')
  && (await pa.locator('[data-testid=print-sheet]').innerText()).includes('فاتورة ضريبية')
  && (await pa.locator('[data-testid=print-company-trn]').innerText()) === '100000000000003'
  && (await pa.locator('[data-testid=print-doc-no]').innerText()) === iNo && (await pa.locator('[data-testid=print-line]').count()) === 2);
ok('print: total matches the invoice', Math.abs(money(await pa.locator('[data-testid=print-total]').innerText()) - iTotal) < 0.01);
await pa.screenshot({ path: `${OUT}/a4-print-invoice-en-light-1440.png`, fullPage: true });
await pa.emulateMedia({ media: 'print' });
ok('print media: toolbar hidden', !(await pa.locator('#print-now').isVisible()));
await pa.emulateMedia({ media: 'screen' });

// ---------- 7. Lists, ATP check, ATP rules ----------
await pa.goto(`${BASE}/docs/delivery?f_source=erp`); await settle(pa);
ok('deliveries list shows the DN number (Super ERP source)', (await pa.locator('main table tbody tr', { hasText: dNo ?? 'DN-26-' }).count()) === 1);
ok('deliveries list: New delivery disabled with the hint', (await pa.locator('#new-delivery').isDisabled()) && (await pa.locator('text=Open an approved sales order and choose Copy to delivery.').count()) > 0);
await pa.goto(`${BASE}/sales/atp`); await settle(pa);
await pickCombo(pa, pa.locator('#atp-item'), '1260', 'SMP-1260');
await pa.click('#atp-run');
await pa.locator('[data-testid=atp-result]').waitFor({ timeout: 10000 }).catch(() => {});
ok('ATP check: SMP-1260 can promise 240 (on hand − committed + PO)', (await pa.locator('[data-testid=atp-result]').innerText().catch(() => '')).includes('Can promise 240'), await pa.locator('[data-testid=atp-result]').innerText().catch(() => ''));
await pa.screenshot({ path: `${OUT}/a4-atp-check-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/sales/atp-rules`); await settle(pa);
ok('ATP rule list shows the sample rule ATP-STD (default)', (await pa.locator('[data-testid=rules-table] tr', { hasText: 'ATP-STD' }).filter({ hasText: 'Default' }).count()) === 1);
await pa.click('#rule-new');
await pa.fill('#rule-code', 'a b');
await pa.fill('#rule-name', 'Bad code');
await pa.click('#rule-save');
await pa.locator('[data-testid=sc-error]').waitFor({ timeout: 10000 }).catch(() => {});
ok('ATP rule: server message for a bad code', (await pa.locator('[data-testid=sc-error]').innerText().catch(() => '')) === 'The rule code can use letters, numbers, - and _ (2 to 20 characters).');
await pa.screenshot({ path: `${OUT}/a4-atp-rules-en-light-1440.png`, fullPage: true });
{
  const C = await context(browser);
  const pc = await C.newPage(); watch(pc, 'sread');
  await login(pc, 'sread'); await settle(pc);
  await pc.goto(`${BASE}/sales/atp-rules`); await settle(pc);
  ok('read-only Sales: New ATP rule disabled with the reason', await pc.locator('#rule-new').isDisabled());
  await pc.goto(`${BASE}/docs/delivery/ZZ99/${dEntry}`); await docReady(pc);
  ok('read-only Sales: Copy to A/R invoice disabled', await pc.locator('#sc-copy').isDisabled().catch(() => false));
  await C.close();
}

// ---------- 8. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['quotation', `/docs/sales_quotation/ZZ99/${qEntry}`],
  ['order', `/docs/sales_order/ZZ99/${oEntry}`],
  ['delivery', `/docs/delivery/ZZ99/${dEntry}`],
  ['invoice', `/docs/ar_invoice/ZZ99/${iEntry}`],
  ['delivery-form', `/docs/delivery/new?company=ZZ99&order=${oEntry}`],
  ['print-invoice', `/print/ar_invoice/ZZ99/${iEntry}`],
  ['atp-rules', '/sales/atp-rules'],
];
for (const [lang, theme, width] of [['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 390], ['en', 'light', 390], ['ar', 'light', 390], ['en', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'sales'); await settle(page);
  let scrollOk = true;
  for (const [name, path] of shots) {
    await page.goto(`${BASE}${path}`); await settle(page);
    await page.locator('h1, [data-testid=print-sheet]').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(300);
    if (width < 640 && name !== 'print-invoice' && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${name}`); }
    await page.screenshot({ path: `${OUT}/a4-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA4 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

// A5 browser test: banking, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a5-e2e.mjs [outDir]
// qa.finance: incoming payment (over-allocation shown, Apply in due-date order, cheques incl. a post-dated one, posting) →
// outgoing payment above the limit (reason, waits) → qa.finmgr approves → bank details changed → small payment needs
// finance manager + owner (two steps) → deposit (post-dated cheque refused, cash deposited) → bank statement CSV import,
// auto-match, re-import skipped, manual unmatch / match → cash position, banking setup, BP bank accounts → cancel a payment.
// Read-only and no-module users. Screenshots 1440 / 390, light / dark, EN / AR.
// Fixtures: two Super ERP A/R invoices through the A4 API, two Super ERP A/P invoices inserted directly (LOCAL STACK ONLY,
// sample company ZZ99: A/P invoices come with A6). Amounts carry random cents so reruns never collide.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const API = process.env.API_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a5-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const money = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));
const fmt2 = (n) => n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const iso = (d) => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 10); };
const TODAY = iso(Date.now());
const LATER = iso(Date.now() + 30 * 86400000);
const dmy = (s) => `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}`;
const cents = () => Math.floor(Math.random() * 90 + 10) / 100;

const USERS = {
  fin: ['qa.finance@sample.test', 'local-only-4'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  owner: ['qa.owner@sample.test', 'local-only-5'],
  fmgr: ['qa.finmgr@sample.test', 'local-only-8'],
  bread: ['qa.bankread@sample.test', 'local-only-9'],
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

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- Fixtures ----------
const salesTok = await token('sales');
const finTok = await token('fin');
const inv = [];
for (const price of [100, 200]) {
  const r = await rpc(salesTok, 'sales_invoice_create', { p_company: 'ZZ99', p_header: { card_code: 'C0011', doc_date: TODAY }, p_lines: [{ item_code: 'SMP-SVC-01', qty: 10, price }] });
  inv.push(r.body);
}
ok('fixtures: two Super ERP A/R invoices (1,050 and 2,100)', inv.every((x) => x?.doc_no) && inv[0].total === 1050 && inv[1].total === 2100, JSON.stringify(inv.map((x) => x?.doc_no)));
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const apBase = 980000000 + Math.floor(Math.random() * 9000000);
const BIG = 25000 + cents();
const SMALL = 1000 + cents();
await db.query(`INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, card_name, currency, total, vat_total, paid, source)
  VALUES ('ZZ99', 18, $1, $1, 'ap_invoice', 'open', $3, $3, 'S0006', 'Sample Freight Forwarder', 'AED', 40000, 0, 0, 'erp'),
         ('ZZ99', 18, $2, $2, 'ap_invoice', 'open', $3, $3, 'S0005', 'Local Carton Supplier', 'AED', 5000, 0, 0, 'erp')`, [apBase, apBase + 1, TODAY]);
// The bank-change rule looks at changes in the last 30 days: start S0006 with none (earlier runs added some).
await db.query(`UPDATE erp.bp_bank_change SET changed_at = now() - interval '400 days' WHERE company_code = 'ZZ99' AND card_code = 'S0006'`);

// ---------- API: the database enforces the rules ----------
{
  const bread = await token('bread');
  const r = await rpc(bread, 'payment_submit', { p_company: 'ZZ99', p_dir: 'I', p_header: { card_code: 'C0011', doc_date: TODAY, cash: 1 }, p_lines: [], p_reason: null });
  ok('API: banking read-only user cannot record a payment', r.status === 403 && /read-only access to Banking/.test(r.body?.message ?? ''), `${r.status} ${r.body?.message}`);
  const w = await fetch(`${API}/rest/v1/bank_account`, { method: 'POST', headers: { apikey: 'local', authorization: `Bearer ${finTok}`, 'content-type': 'application/json', 'content-profile': 'erp' },
    body: JSON.stringify({ company_code: 'ZZ99', bank_code: 'HACK', name: 'x', acct_code: '1600' }) });
  ok('API: direct insert into bank_account refused', w.status === 401 || w.status === 403, String(w.status));
}

const C1 = await context(browser);
const pa = await C1.newPage(); watch(pa, 'fin');
await login(pa, 'fin'); await settle(pa);

// ---------- 1. Incoming payment ----------
await pa.goto(`${BASE}/m/banking`); await settle(pa);
ok('Banking module: Incoming Payments marked live', (await pa.locator('text=Incoming Payments').count()) > 0);
await pa.goto(`${BASE}/banking/payments/in`); await settle(pa);
ok('incoming payments list: + New incoming payment', await pa.locator('#new-payment-in').isVisible());
await pa.click('#new-payment-in'); await settle(pa);
await pa.locator('h1', { hasText: 'New incoming payment' }).waitFor({ timeout: 15000 }).catch(() => {}); // A14: pages are lazy-loaded
ok('payment form opens', (await txt(pa.locator('h1'))).includes('New incoming payment'));
await pickCombo(pa, pa.locator('#bk-bp'), 'C0011', 'C0011');
await pa.locator('[data-testid=bk-doc]').first().waitFor({ timeout: 10000 }).catch(() => {});
const docRows = pa.locator('[data-testid=bk-doc]');
ok('open invoices of the customer listed', (await docRows.filter({ hasText: inv[0].doc_no }).count()) === 1 && (await docRows.filter({ hasText: inv[1].doc_no }).count()) === 1);
const TR = 1000 + cents();
await pa.fill('#bk-cash', '100');
await pa.fill('#bk-transfer', String(TR));
await pa.selectOption('#bk-transfer-bank', 'BNK-AED');
await pa.fill('#bk-transfer-ref', 'E2E-TRX');
await pa.click('#bk-add-cheque');
const chq = pa.locator('[data-testid=bk-cheque]').first();
await chq.locator('input[id$="-no"]').fill(`PDC-${apBase}`);
await chq.locator('input[id$="-bank"]').fill('Test bank');
await chq.locator('input[id$="-due"]').fill(LATER);
await chq.locator('input[id$="-amount"]').fill('300');
ok('post-dated cheque flagged in the form', (await chq.locator('text=Post-dated cheque').count()) === 1);
const i0 = await docRows.filter({ hasText: inv[0].doc_no }).locator('input').getAttribute('id');
await pa.fill(`#${i0}`, '1050.01');
await pa.locator('[data-testid=bk-problems]').waitFor({ timeout: 10000 }).catch(() => {});
ok('over-allocation: the server message shows on the form', (await txt(pa.locator('[data-testid=bk-problems]'))).includes(`1,050.01 AED is more than the 1,050.00 AED still open on invoice ${inv[0].doc_no}.`), await txt(pa.locator('[data-testid=bk-problems]')));
await pa.click('#bk-apply-all');
await pa.waitForTimeout(300);
const total = Math.round((100 + TR + 300) * 100) / 100;
ok('Apply in due-date order fills the whole payment', money(await txt(pa.locator('[data-testid=bk-applied]'))) === total, await txt(pa.locator('[data-testid=bk-applied]')));
const i1 = await docRows.filter({ hasText: inv[1].doc_no }).locator('input').getAttribute('id');
for (const id of await docRows.locator('input').evaluateAll((els) => els.map((e) => e.id))) await pa.fill(`#${id}`, '');
await pa.fill(`#${i0}`, '1050');
await pa.fill(`#${i1}`, '200');
await pa.waitForTimeout(600);
ok('allocation maths on screen: 1,050 + 200 applied, the rest on account', money(await txt(pa.locator('[data-testid=bk-total]'))) === total
  && money(await txt(pa.locator('[data-testid=bk-applied]'))) === 1250 && money(await txt(pa.locator('[data-testid=bk-on-account]'))) === Math.round((total - 1250) * 100) / 100,
  `${await txt(pa.locator('[data-testid=bk-total]'))} / ${await txt(pa.locator('[data-testid=bk-applied]'))} / ${await txt(pa.locator('[data-testid=bk-on-account]'))}`);
await pa.locator('[data-testid=bk-preview]', { hasText: 'Posts straight away' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('preview: incoming posts straight away', (await txt(pa.locator('[data-testid=bk-preview]'))).includes('Posts straight away'));
await pa.screenshot({ path: `${OUT}/a5-payment-form-en-light-1440.png`, fullPage: true });
await pa.click('#bk-submit');
await pa.waitForURL(/\/banking\/payments\/in\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
await settle(pa);
const pinEntry = entryFromUrl(pa.url());
ok('incoming payment posted: flash and Posted status', (await txt(pa.locator('[data-testid=bk-flash]'))).startsWith('Posted payment RC-26-') && (await txt(pa.locator('[data-testid=bk-status]'))) === 'Posted',
  await txt(pa.locator('[data-testid=bk-flash]')));
ok('payment page: allocations to both invoices and the journal link', (await pa.locator('[data-testid=bk-allocations] tbody tr').count()) === 2 && await pa.locator('#bk-journal-link').isVisible());
ok('payment page: post-dated cheque shown as PDC, not deposited', (await txt(pa.locator('[data-testid=bk-cheques]'))).includes('PDC') && (await txt(pa.locator('[data-testid=bk-cheques]'))).includes('Not deposited'));
await pa.screenshot({ path: `${OUT}/a5-payment-detail-en-light-1440.png`, fullPage: true });
await pa.click('#bk-journal-link'); await settle(pa);
await pa.locator('text=Debit = credit').first().waitFor({ timeout: 10000 }).catch(() => {});
ok('payment journal balances', (await pa.locator('text=Debit = credit').count()) > 0);

// ---------- 2. Outgoing payment above the limit ----------
await pa.goto(`${BASE}/banking/payments/out/new`); await settle(pa);
await pickCombo(pa, pa.locator('#bk-bp'), 'S0006', 'S0006');
await pa.locator('[data-testid=bk-doc]').first().waitFor({ timeout: 10000 }).catch(() => {});
await pa.fill('#bk-transfer', String(BIG));
await pa.selectOption('#bk-transfer-bank', 'BNK-AED');
const apRow = pa.locator('[data-testid=bk-doc]', { hasText: String(apBase) });
await pa.fill(`#${await apRow.locator('input').getAttribute('id')}`, String(BIG));
await pa.locator('[data-testid=bk-preview]', { hasText: 'Needs approval' }).waitFor({ timeout: 10000 }).catch(() => {});
const pv = await txt(pa.locator('[data-testid=bk-preview]'));
ok('preview: above the limit needs the finance manager', pv.includes(`Payment ${fmt2(BIG)} AED is above your payment limit of 20,000.00 AED.`) && pv.includes('Step 1: QA · finance manager'), pv);
await pa.click('#bk-submit');
ok('a reason is required before sending', (await txt(pa.locator('#bk-reason-err'))) === 'Add a reason for the approver.');
await pa.fill('#bk-reason', 'Container balance due');
await pa.click('#bk-submit');
await pa.waitForURL(/\/banking\/payment-drafts\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
await settle(pa);
const d1 = entryFromUrl(pa.url());
ok('payment waits for approval (draft page)', (await txt(pa.locator('[data-testid=bk-flash]'))).includes('Sent for approval to QA · finance manager') && (await txt(pa.locator('h1'))).includes('Waiting for approval'));
ok('creator sees no approval card', (await pa.locator('[data-testid=bk-approval-card]').count()) === 0 && (await txt(pa.locator('[data-testid=bk-status-card]'))).includes("You entered this payment, so you can't approve it."));
{
  const C = await context(browser);
  const pm = await C.newPage(); watch(pm, 'fmgr');
  await login(pm, 'fmgr'); await settle(pm);
  await pm.goto(`${BASE}/approvals`); await settle(pm);
  await pm.locator('[data-testid=inbox-table]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('finance manager: payment in Waiting for me', (await pm.locator('[data-testid=inbox-table] tr', { hasText: `Payment draft ${d1}` }).count()) === 1);
  await pm.locator('[data-testid=inbox-table] a', { hasText: `Payment draft ${d1}` }).click(); await settle(pm);
  await pm.locator('[data-testid=bk-approval-card]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('approval card names the rule and the reason', (await txt(pm.locator('[data-testid=bk-approval-card]'))).includes('above your payment limit') && (await txt(pm.locator('[data-testid=bk-approval-card]'))).includes('Container balance due'));
  await pm.screenshot({ path: `${OUT}/a5-draft-approval-fmgr-en-light-1440.png`, fullPage: true });
  await pm.click('#bk-approve');
  await pm.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('approve: paid at once', (await txt(pm.locator('[data-testid=bk-flash]'))).startsWith('Approved and paid as PV-26-'), await txt(pm.locator('[data-testid=bk-flash]')));
  await C.close();
}

// ---------- 3. Bank details change → two-step approval ----------
await pa.goto(`${BASE}/banking/bp-bank-accounts`); await settle(pa);
await pa.click('#bpb-new');
await pickCombo(pa, pa.locator('#bpb-bp'), 'S0006', 'S0006');
await pa.fill('#bpb-bank_name', 'New Bank (e2e)');
await pa.fill('#bpb-iban', 'AE12 34');
await pa.click('#bpb-save');
ok('BP bank details: invalid IBAN refused with the server message', (await txt(pa.locator('[data-testid=bk-error]'))).startsWith('The IBAN AE1234 is not valid.'));
await pa.fill('#bpb-iban', 'AE07 0331 2345 6789 0123 456');
await pa.click('#bpb-save');
await pa.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
ok('BP bank details added and logged', (await txt(pa.locator('[data-testid=bk-flash]'))).includes('Bank details of S0006 added'));
await pa.locator('main table tbody tr', { hasText: 'S0006' }).first().waitFor({ timeout: 10000 }).catch(() => {});
ok('BP bank accounts list flags the recent change', (await pa.locator('main table tbody tr', { hasText: 'S0006' }).filter({ hasText: 'Changed recently' }).count()) > 0);
await pa.screenshot({ path: `${OUT}/a5-bp-bank-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/banking/payments/out/new`); await settle(pa);
await pickCombo(pa, pa.locator('#bk-bp'), 'S0006', 'S0006');
await pa.locator('[data-testid=bk-bp-info]').waitFor({ timeout: 10000 }).catch(() => {});
ok('form warns that the bank details changed', (await txt(pa.locator('[data-testid=bk-bp-info]'))).includes('Bank details changed'));
await pa.fill('#bk-transfer', String(SMALL));
await pa.selectOption('#bk-transfer-bank', 'BNK-AED');
await pa.fill(`#${await pa.locator('[data-testid=bk-doc]', { hasText: String(apBase) }).locator('input').getAttribute('id')}`, String(SMALL));
await pa.locator('[data-testid=bk-preview]', { hasText: 'Needs approval' }).waitFor({ timeout: 10000 }).catch(() => {});
const pv2 = await txt(pa.locator('[data-testid=bk-preview]'));
ok('small payment to changed bank details needs finance manager then owner', pv2.includes("Sample Freight Forwarder's bank details changed on") && pv2.includes('Step 1: QA · finance manager') && pv2.includes('Step 2: QA · owner'), pv2);
await pa.fill('#bk-reason', 'Supplier confirmed the new account by phone');
await pa.click('#bk-submit');
await pa.waitForURL(/\/banking\/payment-drafts\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
const d2 = entryFromUrl(pa.url());
{
  const C = await context(browser);
  const po = await C.newPage(); watch(po, 'owner');
  await login(po, 'owner'); await settle(po);
  await po.goto(`${BASE}/banking/payment-drafts/ZZ99/${d2}`); await settle(po);
  await po.locator('[data-testid=bk-steps]').first().waitFor({ timeout: 10000 }).catch(() => {});
  ok('owner: no approval card before the finance manager', (await po.locator('[data-testid=bk-approval-card]').count()) === 0 && (await txt(po.locator('[data-testid=bk-status-card]'))).includes('Waiting for QA · finance manager'));
  const pm = await (await context(browser)).newPage(); watch(pm, 'fmgr2');
  await login(pm, 'fmgr'); await settle(pm);
  await pm.goto(`${BASE}/banking/payment-drafts/ZZ99/${d2}`); await settle(pm);
  await pm.locator('#bk-approve').click();
  await pm.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('finance manager approves step 1: still waiting', (await txt(pm.locator('[data-testid=bk-flash]'))) === 'Approved. It now waits for the next approver.');
  await po.reload(); await settle(po);
  await po.locator('[data-testid=bk-approval-card]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('owner: approval card at step 2', await po.locator('[data-testid=bk-approval-card]').isVisible());
  await po.screenshot({ path: `${OUT}/a5-draft-two-step-owner-en-light-1440.png`, fullPage: true });
  await po.click('#bk-approve');
  await po.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('owner approves step 2: paid', (await txt(po.locator('[data-testid=bk-flash]'))).startsWith('Approved and paid as PV-26-'));
  await C.close();
}

// ---------- 4. Deposit ----------
await pa.goto(`${BASE}/banking/deposits/new`); await settle(pa);
await pa.locator('[data-testid=dep-cheque]').first().waitFor({ timeout: 10000 }).catch(() => {});
const pdcRow = pa.locator('[data-testid=dep-cheque]', { hasText: `PDC-${apBase}` });
ok('deposit form lists the post-dated cheque (flagged)', (await pdcRow.count()) === 1 && (await pdcRow.filter({ hasText: 'PDC' }).count()) === 1);
await pdcRow.locator('input[type=checkbox]').check();
await pa.click('#dep-submit');
await pa.locator('[data-testid=bk-error]').waitFor({ timeout: 10000 }).catch(() => {});
ok('post-dated cheque refused before its date', (await txt(pa.locator('[data-testid=bk-error]'))).startsWith(`Cheque PDC-${apBase} is post-dated to`), await txt(pa.locator('[data-testid=bk-error]')));
await pdcRow.locator('input[type=checkbox]').uncheck();
await pa.fill('#dep-cash', '100');
await pa.screenshot({ path: `${OUT}/a5-deposit-form-en-light-1440.png`, fullPage: true });
await pa.click('#dep-submit');
await pa.waitForURL(/\/banking\/deposits$/, { timeout: 15000 }).catch(() => {});
await pa.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
ok('cash deposit posted', /Posted deposit DP-26-\d+ of 100\.00 AED/.test(await txt(pa.locator('[data-testid=bk-flash]'))), await txt(pa.locator('[data-testid=bk-flash]')));

// ---------- 5. Bank statement import and matching ----------
const csv = path.join(os.tmpdir(), `a5-statement-${apBase}.csv`);
const UNKNOWN = 777 + cents();
fs.writeFileSync(csv, ['Date,Description,Reference,Amount',
  `${dmy(TODAY)},Transfer from Sunrise,E2E-TRX,${TR}`,
  `${dmy(TODAY)},"Payment, Sample Freight",,-${BIG}`,
  `${dmy(TODAY)},Payment Sample Freight new account,,-${SMALL}`,
  `${dmy(TODAY)},Unknown credit,,${UNKNOWN}`].join('\n'));
await pa.goto(`${BASE}/banking/statements`); await settle(pa);
await pa.setInputFiles('#imp-file', csv);
await pa.locator('[data-testid=imp-preview]').waitFor({ timeout: 10000 }).catch(() => {});
ok('CSV parsed and columns guessed (preview)', (await pa.locator('[data-testid=imp-preview] tbody tr').count()) === 4 && (await txt(pa.locator('[data-testid=imp-preview]'))).includes(TODAY));
await pa.screenshot({ path: `${OUT}/a5-statement-import-en-light-1440.png`, fullPage: true });
await pa.click('#imp-submit');
await pa.waitForURL(/\/banking\/statements\/ZZ99\/\d+/, { timeout: 15000 }).catch(() => {});
await settle(pa);
const stmt = entryFromUrl(pa.url());
ok('statement imported: 4 lines', (await txt(pa.locator('[data-testid=bk-flash]'))).startsWith('Imported 4 statement lines.') && (await pa.locator('[data-testid=stmt-line]').count()) === 4);
await pa.click('#stmt-auto');
await pa.locator('[data-testid=bk-flash]', { hasText: 'Matched' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('auto-match: payments matched, unknown line stays listed', (await txt(pa.locator('[data-testid=bk-flash]'))) === 'Matched 3 lines. 1 still need a match.' && (await txt(pa.locator('[data-testid=stmt-count]'))) === '3 of 4 matched',
  await txt(pa.locator('[data-testid=bk-flash]')));
await pa.click('#stmt-auto');
await pa.locator('[data-testid=bk-flash]', { hasText: 'Matched 0' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('auto-match again changes nothing (idempotent)', (await txt(pa.locator('[data-testid=bk-flash]'))) === 'Matched 0 lines. 1 still need a match.' && (await txt(pa.locator('[data-testid=stmt-count]'))) === '3 of 4 matched');
const trRow = pa.locator('[data-testid=stmt-line]', { hasText: 'Transfer from Sunrise' });
ok('match shows the payment number', /RC-26-\d+/.test(await txt(trRow)));
await trRow.getByRole('button', { name: /Unmatch/ }).click();
await pa.locator('[data-testid=bk-flash]', { hasText: 'Match removed.' }).waitFor({ timeout: 10000 }).catch(() => {});
await trRow.getByRole('button', { name: 'Match…' }).click();
await pa.locator('[data-testid=cand-list]').waitFor({ timeout: 10000 }).catch(() => {});
ok('manual match: the payment journal line is offered', (await pa.locator('[data-testid=cand-list] li').count()) >= 1 && /RC-26-/.test(await txt(pa.locator('[data-testid=cand-list]'))));
await pa.screenshot({ path: `${OUT}/a5-statement-match-dialog-en-light-1440.png`, fullPage: true });
await pa.locator('[data-testid=cand-list] li').first().getByRole('button', { name: 'Match' }).click();
await pa.locator('[data-testid=bk-flash]', { hasText: 'Line matched.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('manual match saved', (await txt(pa.locator('[data-testid=stmt-count]'))) === '3 of 4 matched' && (await txt(trRow)).includes('Matched by hand'));
await pa.locator('[data-testid=stmt-line]', { hasText: 'Unknown credit' }).getByRole('button', { name: 'Match…' }).click();
await pa.locator('[data-testid=cand-empty]').waitFor({ timeout: 10000 }).catch(() => {});
ok('unknown line: no candidates, it stays unmatched', await pa.locator('[data-testid=cand-empty]').isVisible());
await pa.keyboard.press('Escape');
await pa.check('#stmt-only');
ok('filter: only unmatched lines', (await pa.locator('[data-testid=stmt-line]').count()) === 1);
await pa.screenshot({ path: `${OUT}/a5-statement-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/banking/statements`); await settle(pa);
await pa.setInputFiles('#imp-file', csv);
await pa.locator('[data-testid=imp-preview]').waitFor({ timeout: 10000 }).catch(() => {});
await pa.click('#imp-submit');
await pa.locator('[data-testid=bk-import-result]').waitFor({ timeout: 10000 }).catch(() => {});
ok('same file again: nothing new imported', (await txt(pa.locator('[data-testid=bk-import-result]'))) === 'Nothing new: all 4 lines were imported before.');

// ---------- 6. Cash position, setup ----------
await pa.goto(`${BASE}/banking/cash-position`); await settle(pa);
await pa.locator('[data-testid=cp-accounts]').waitFor({ timeout: 10000 }).catch(() => {});
ok('cash position: house bank and cash accounts with balances', (await pa.locator('[data-testid=cp-accounts] tbody tr', { hasText: 'BNK-AED' }).count()) === 1 && money(await txt(pa.locator('[data-testid=cp-total]'))) > 0);
ok('cash position: cheques not deposited include post-dated', (await txt(pa.locator('main'))).includes('post-dated'));
await pa.screenshot({ path: `${OUT}/a5-cash-position-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/m/banking?fn=8`); await settle(pa);
ok('Banking Reports: House Bank Accounts Query live, other reports stay previews', (await pa.locator('text=House Bank Accounts Query').count()) > 0);
await pa.goto(`${BASE}/banking/setup`); await settle(pa);
await pa.locator('[data-testid=ba-list]').waitFor({ timeout: 10000 }).catch(() => {});
ok('banking setup: sample house accounts listed', (await pa.locator('[data-testid=ba-list] tbody tr', { hasText: 'BNK-AED' }).count()) === 1);
await pa.click('#ba-new');
await pa.fill('#ba-bank_code', 'X');
await pa.fill('#ba-name', 'Bad');
await pa.click('#ba-save');
ok('banking setup: server message for a bad code', (await txt(pa.locator('[data-testid=bk-error]'))) === 'The code can use letters, numbers, - and _ (2 to 20 characters).');
await pa.screenshot({ path: `${OUT}/a5-setup-en-light-1440.png`, fullPage: true });

// ---------- 7. Cancel a payment ----------
{
  const r = await rpc(finTok, 'payment_submit', { p_company: 'ZZ99', p_dir: 'O', p_header: { card_code: 'S0005', doc_date: TODAY, transfer: 500, transfer_bank: 'BNK-AED' },
    p_lines: [{ obj_type: 18, doc_entry: apBase + 1, amount: 500 }], p_reason: null });
  ok('API: small outgoing payment posts', r.body?.state === 'posted', JSON.stringify(r.body));
  await pa.goto(`${BASE}/banking/payments/out/ZZ99/${r.body?.doc_entry}`); await settle(pa);
  await pa.click('#bk-cancel-payment');
  await pa.click('#bk-cancel-confirm');
  ok('cancel needs a reason', (await txt(pa.locator('[role=dialog] [role=alert]'))) === 'Add a reason for the cancellation.');
  await pa.fill('#bk-cancel-reason', 'Wrong invoice');
  await pa.click('#bk-cancel-confirm');
  await pa.locator('[data-testid=bk-flash]').waitFor({ timeout: 10000 }).catch(() => {});
  ok('payment cancelled with a reversal', (await txt(pa.locator('[data-testid=bk-status]'))) === 'Cancelled' && (await txt(pa.locator('[data-testid=bk-flash]'))).startsWith('Payment cancelled.'));
  await pa.goto(`${BASE}/banking/payments/in/ZZ99/${pinEntry}`); await settle(pa);
  ok('matched payment: Cancel disabled with the reason', await pa.locator('#bk-cancel-payment').isDisabled() && (await txt(pa.locator('main'))).includes('matched to a bank statement line'));
}
await C1.close();

// ---------- 8. Read-only and no-module users ----------
{
  const C = await context(browser);
  const pb = await C.newPage(); watch(pb, 'bread');
  await login(pb, 'bread'); await settle(pb);
  await pb.goto(`${BASE}/banking/payments/in`); await settle(pb);
  ok('banking read-only: New incoming payment disabled', await pb.locator('#new-payment-in').isDisabled());
  await pb.goto(`${BASE}/banking/statements/ZZ99/${stmt}`); await settle(pb);
  ok('banking read-only: Auto-match disabled', await pb.locator('#stmt-auto').isDisabled());
  await C.close();
  const C2 = await context(browser);
  const ps = await C2.newPage(); watch(ps, 'sales');
  await login(ps, 'sales'); await settle(ps);
  await ps.goto(`${BASE}/banking/payments/in/new`); await settle(ps);
  ok('sales-only user: no access to Banking', (await ps.locator('text=You don\'t have access to this').count()) > 0 || (await ps.locator('text=does not include Banking').count()) > 0);
  await C2.close();
}

// ---------- 9. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['payment-form', '/banking/payments/in/new'],
  ['payment-detail', `/banking/payments/in/ZZ99/${pinEntry}`],
  ['draft', `/banking/payment-drafts/ZZ99/${d2}`],
  ['statement', `/banking/statements/ZZ99/${stmt}`],
  ['cash-position', '/banking/cash-position'],
  ['deposit-form', '/banking/deposits/new'],
  ['payments-list', '/banking/payments/in'],
];
for (const [lang, theme, width] of [['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'fin'); await settle(page);
  let scrollOk = true;
  for (const [name, p] of shots) {
    await page.goto(`${BASE}${p}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(400);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${name}`); }
    await page.screenshot({ path: `${OUT}/a5-${name}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA5 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

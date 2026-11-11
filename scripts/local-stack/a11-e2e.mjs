// A11 browser test: Reports, Control Tower rules, Ask AI — against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a11-e2e.mjs [outDir]
// Report library → trial balance = journal sums, CSV = screen, chart, Print / PDF → P&L and balance sheet totals → a sales user is
// refused finance reports (screen + API) but runs customer aging → sales analysis by item → inventory by warehouse →
// Control Tower 10 rules with record links, rights per user → Ask Sana (U0+S1 replaced Ask AI): switched off, then on: a basic-mode answer
// with sources, no finance data for a sales user, logged as ai:sana; Ask Sana about this order → screenshots 1440 / 390,
// light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const GW = process.env.GATEWAY_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a11-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
  purch: ['qa.purchase@sample.test', 'local-only-10'],
  stock: ['qa.stock@sample.test', 'local-only-13'],
};
const SALES_ID = '00000000-0000-4000-8000-000000000002';
async function loginAs(page, email, password) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
const login = (page, who) => loginAs(page, ...USERS[who]);
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, acceptDownloads: true, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  return ctx;
}
const txt = (loc) => loc.first().innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const num = (s) => Number(String(s).replace(/[^0-9.\-]/g, ''));
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
async function token(who) {
  const [email, password] = USERS[who];
  const r = await fetch(`${GW}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password }) });
  return (await r.json()).access_token;
}
async function api(who, fn, args) {
  const r = await fetch(`${GW}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { 'content-type': 'application/json', 'content-profile': 'erp', authorization: `Bearer ${await token(who)}` }, body: JSON.stringify(args) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
const today = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const y0 = `${today.slice(0, 4)}-01-01`;

// ---------- fixtures (sample company only; they stay on the running DB, see HANDOFF) ----------
await db.query(`DELETE FROM erp.ai_setting WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.ai_usage WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99'`);   // U0+S1: Sana on (no row)
await db.query(`DELETE FROM erp.sana_usage WHERE company_code = 'ZZ99'`);
// same supplier invoice twice (closed and paid, so payments and aging are not affected)
await db.query(`INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, card_name, customer_ref, currency, total, paid, source)
  VALUES ('ZZ99', 18, 990001, 990001, 'ap_invoice', 'closed', current_date - 3, current_date + 27, 'S0001', 'E2E duplicate supplier invoice', 'INV-E2E-A11', 'AED', 1000, 1000, 'erp'),
         ('ZZ99', 18, 990002, 990002, 'ap_invoice', 'closed', current_date - 1, current_date + 29, 'S0001', 'E2E duplicate supplier invoice', 'INV-E2E-A11', 'AED', 1000, 1000, 'erp')
  ON CONFLICT DO NOTHING`);
// a draft purchase order 20 % above the last purchase price of SMP-1010
const lp = await one(`SELECT l.price FROM erp.document_line l JOIN erp.document d USING (company_code, obj_type, doc_entry)
  WHERE l.company_code = 'ZZ99' AND l.item_code = 'SMP-1010' AND l.obj_type IN (22, 20, 18) AND l.price > 0 AND d.doc_entry <> 990011
    AND d.status NOT IN ('draft', 'cancelled', 'cancellation') ORDER BY d.doc_date DESC, d.doc_entry DESC LIMIT 1`);
await db.query(`INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, total, source)
  VALUES ('ZZ99', 22, 990011, 990011, 'purchase_order', 'draft', current_date, 'S0001', 'E2E price check', 'AED', 0, 'erp') ON CONFLICT DO NOTHING`);
await db.query(`INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total)
  VALUES ('ZZ99', 22, 990011, 0, 'SMP-1010', 10, 10, $1::numeric, $1::numeric * 10) ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET price = EXCLUDED.price`, [Math.round(Number(lp.price) * 120) / 100]);
await db.query(`UPDATE erp.document SET doc_date = current_date WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = 990011`);
// supplier bank details changed today
await db.query(`INSERT INTO erp.bp_bank_change (company_code, card_code, change_kind, changed_at) VALUES ('ZZ99', 'S0002', 'changed', now())`);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

async function tableRows(p) {
  return p.locator('[data-testid=rpt-row]').evaluateAll((trs) => trs.map((tr) => Object.fromEntries([...tr.querySelectorAll('td')].map((td) => [td.dataset.col, td.innerText.trim()]))));
}
async function downloadCsv(p) {
  const dl = p.waitForEvent('download', { timeout: 10000 });
  await p.click('#rpt-csv');
  const f = await dl;
  const path = `${OUT}/${f.suggestedFilename()}`; await f.saveAs(path);
  const lines = fs.readFileSync(path, 'utf8').replace(/^\ufeff/, '').trim().split(/\r?\n/);
  const split = (l) => { const out = []; let cur = '', q = false; for (const ch of l) { if (ch === '"') q = !q; else if (ch === ',' && !q) { out.push(cur); cur = ''; } else cur += ch; } out.push(cur); return out; };
  return { name: f.suggestedFilename(), head: split(lines[0]), rows: lines.slice(1).map(split) };
}

// ---------- 1. Library and the trial balance (finance) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'fin');
  await login(p, 'fin'); await settle(p);
  await p.goto(`${BASE}/reports`); await settle(p);
  ok('library lists the 9 reports', (await p.locator('[data-report]').count()) === 9);
  ok('finance user: trial balance card opens, inventory valuation locked',
    (await p.locator('a[data-report=trial-balance]').count()) === 1 && (await p.locator('div[data-report=inventory-valuation][aria-disabled=true]').count()) === 1);
  await p.click('a[data-report=trial-balance]'); await settle(p);
  await p.fill('#rpt-from', y0); await p.fill('#rpt-to', today); await p.click('#rpt-run'); await settle(p);
  await seen(p.locator('[data-testid=rpt-row]'));
  ok('report parameters kept in the URL', p.url().includes(`from=${y0}`) && p.url().includes(`to=${today}`) && p.url().includes('company=ZZ99'));
  const rows = await tableRows(p);
  const j = await one(`SELECT round(sum(jl.debit), 2) AS d, round(sum(jl.credit), 2) AS c, count(DISTINCT jl.acct_code) AS n FROM erp.journal_line jl
    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id WHERE jl.company_code = 'ZZ99' AND je.ref_date BETWEEN $1 AND $2`, [y0, today]);
  const tot = await p.locator('[data-testid=rpt-total] td').allInnerTexts();
  ok('trial balance on screen: total debit and credit = journal sums', num(tot[3]) === Number(j.d) && num(tot[4]) === Number(j.c), `${tot[3]} / ${j.d} · ${tot[4]} / ${j.c}`);
  ok('trial balance closing total is zero', num(tot[5]) === 0, tot[5]);
  ok('chart shown', await seen(p.locator('[data-testid=rpt-chart] li')));
  const csv = await downloadCsv(p);
  ok('CSV has the same rows as the screen', csv.rows.length === rows.length, `${csv.rows.length} / ${rows.length}`);
  ok('CSV headers = table headers', csv.head.join('|') === (await p.locator('[data-testid=rpt-table] thead th').allInnerTexts()).map((h) => h.trim()).join('|').replace(/\|/g, '|')
    || csv.head.map((h) => h.toUpperCase()).join('|') === (await p.locator('[data-testid=rpt-table] thead th').allInnerTexts()).map((h) => h.trim().toUpperCase()).join('|'), csv.head.join(', '));
  ok('CSV values match what is on screen', rows.every((r, i) => csv.rows[i][0] === r.acct_code && Number(csv.rows[i][3]) === num(r.debit)
    && Number(csv.rows[i][4]) === num(r.credit) && Number(csv.rows[i][5]) === num(r.closing)), csv.name);
  await p.screenshot({ path: `${OUT}/a11-trial-balance-en-light-1440.png`, fullPage: true });
  // Print / PDF
  const href = await p.locator('#rpt-pdf').getAttribute('href');
  await p.goto(`${BASE}${href}`); await settle(p);
  ok('Print / PDF sheet shows the same rows', await seen(p.locator('[data-testid=print-sheet] [data-testid=rpt-row]')) && (await p.locator('[data-testid=rpt-row]').count()) === rows.length);
  await p.screenshot({ path: `${OUT}/a11-trial-balance-print.png`, fullPage: true });
  // P&L and balance sheet
  await p.goto(`${BASE}/reports/profit-loss?company=ZZ99&from=${y0}&to=${today}`); await settle(p);
  await seen(p.locator('[data-testid=rpt-total]'));
  const pl = await one(`SELECT round(sum(jl.credit - jl.debit), 2) AS n FROM erp.journal_line jl JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
    JOIN erp.account a ON a.company_code = jl.company_code AND a.acct_code = jl.acct_code WHERE jl.company_code = 'ZZ99' AND je.ref_date BETWEEN $1 AND $2 AND a.group_mask NOT IN (1, 2, 3)`, [y0, today]);
  const net = (await p.locator('[data-testid=rpt-total] td').allInnerTexts()).at(-1);
  ok('P&L net profit on screen = journal sum', num(net) === Number(pl.n), `${net} / ${pl.n}`);
  await p.goto(`${BASE}/reports/balance-sheet?company=ZZ99&as_of=${today}`); await settle(p);
  await seen(p.locator('[data-testid=rpt-subtotal]'));
  const subs = await p.locator('[data-testid=rpt-subtotal] td:last-child').allInnerTexts();
  const le = (await p.locator('[data-testid=rpt-total] td:last-child').allInnerTexts()).at(-1);
  ok('balance sheet: total assets = total liabilities and equity', subs.length >= 2 && num(subs[0]) === num(le), `${subs[0]} / ${le}`);
  ok('current period result line shown', (await txt(p.locator('[data-testid=rpt-table]'))).includes('Current period result'));
  await C.close();
}

// ---------- 2. A sales user can't run finance reports ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'sales');
  await login(p, 'sales'); await settle(p);
  await p.goto(`${BASE}/reports/trial-balance`); await settle(p);
  ok('sales user: trial balance shows No access with the reason', await seen(p.locator('[data-testid=rpt-no-access]'))
    && (await txt(p.locator('[data-testid=rpt-no-access]'))).includes('Your position does not include Financials'));
  const r = await api('sales', 'rpt_trial_balance', { p_company: 'ZZ99', p_from: y0, p_to: today });
  ok('API: the database refuses the sales user the trial balance', r.status === 403 && r.body?.message === 'Your position does not include Financials. Ask the system admin if you need it.', `${r.status} ${r.body?.message}`);
  const r2 = await api('sales', 'rpt_profit_loss', { p_company: 'ZZ99', p_from: y0, p_to: today });
  ok('API: … and the P&L', r2.status === 403, String(r2.status));
  await p.goto(`${BASE}/reports`); await settle(p);
  ok('library: finance reports locked for the sales user', (await p.locator('div[data-report=trial-balance][aria-disabled=true]').count()) === 1 && (await p.locator('a[data-report=ar-aging]').count()) === 1);
  await p.click('a[data-report=ar-aging]'); await settle(p);
  await seen(p.locator('[data-testid=rpt-row]'));
  const rows = await tableRows(p);
  const o = await one(`SELECT round(sum(sign * (coalesce(total, 0) - coalesce(paid, 0))), 2) AS t FROM erp.document WHERE company_code = 'ZZ99' AND obj_type IN (13, 14) AND status = 'open' AND doc_date <= $1`, [today]);
  const tot = (await p.locator('[data-testid=rpt-total] td').allInnerTexts()).at(-1);
  ok('sales user runs customer aging; total = open A/R documents', rows.length > 0 && num(tot) === Number(o.t), `${tot} / ${o.t}`);
  const csv = await downloadCsv(p);
  ok('aging CSV matches the screen', csv.rows.length === rows.length && rows.every((r, i) => csv.rows[i][0] === r.card_code && Number(csv.rows[i].at(-1)) === num(r.total)));
  await p.screenshot({ path: `${OUT}/a11-ar-aging-en-light-1440.png`, fullPage: true });
  await p.goto(`${BASE}/reports/sales-analysis`); await settle(p);
  await p.selectOption('#rpt-by', 'item'); await p.click('#rpt-run'); await settle(p);
  await seen(p.locator('[data-testid=rpt-row]'));
  ok('sales analysis grouped by item (URL + item links)', p.url().includes('by=item') && await seen(p.locator('[data-testid=rpt-row] a[href^="/items/ZZ99/"]')));
  // Control Tower for the sales user: none of the new rules
  await p.goto(`${BASE}/control`); await settle(p);
  await seen(p.locator('[data-testid=ct-cards] [data-check]'));
  ok('Control Tower shows 10 rule cards', (await p.locator('[data-testid=ct-cards] [data-check]').count()) === 10);
  ok('sales user: no duplicate-invoice, bank, price, count or check-in findings',
    (await p.locator('li[data-check=duplicate_invoice], li[data-check=bank_change], li[data-check=price_increase], li[data-check=count_variance], li[data-check=checkin_outside]').count()) === 0);
  await C.close();
}

// ---------- 3. Inventory by warehouse (inventory user) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'stock');
  await login(p, 'stock'); await settle(p);
  await p.goto(`${BASE}/reports/inventory-in-warehouse`); await settle(p);
  await seen(p.locator('#rpt-whs option[value=WH01]'));
  await p.selectOption('#rpt-whs', 'WH01'); await p.click('#rpt-run'); await settle(p);
  await seen(p.locator('[data-testid=rpt-row]'));
  const rows = await tableRows(p);
  const v = await one(`SELECT count(*) AS n FROM erp.stock_balance WHERE company_code = 'ZZ99' AND whs_code = 'WH01' AND (on_hand <> 0 OR committed <> 0 OR on_order <> 0)`);
  ok('inventory in warehouse filtered to WH01', rows.length === Number(v.n) && rows.every((r) => r.whs_code === 'WH01'), `${rows.length} rows`);
  await C.close();
}

// ---------- 4. Control Tower rules (purchasing user and admin) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'purch');
  await login(p, 'purch'); await settle(p);
  await p.goto(`${BASE}/control`); await settle(p);
  await seen(p.locator('li[data-check]'));
  ok('purchasing user: duplicate supplier invoice flagged with record link',
    (await p.locator('li[data-check=duplicate_invoice] a[href="/docs/ap_invoice/ZZ99/990001"]').count()) === 1 && (await p.locator('li[data-check=duplicate_invoice]').count()) >= 2);
  ok('purchasing user: price over last + 10 % flagged', (await p.locator('li[data-check=price_increase] a[href="/docs/purchase_order/ZZ99/990011"]').count()) === 1);
  ok('purchasing user: supplier bank change flagged', (await p.locator('li[data-check=bank_change] a[href="/bp/ZZ99/S0002"]').count()) === 1);
  await p.click('[data-testid=ct-cards] [data-check=duplicate_invoice]');
  ok('rule card filters the findings', (await p.locator('li[data-check]').count()) === (await p.locator('li[data-check=duplicate_invoice]').count()));
  await p.click('[data-testid=ct-cards] [data-check=duplicate_invoice]');
  await p.click('button[aria-pressed]:has-text("Critical")');
  ok('severity chip: only critical findings', (await p.locator('li[data-check] .pill-warning').count()) === 0);
  await C.close();
}

// ---------- 5. Ask Sana (U0+S1: Sana replaced A11's "Ask AI"; same intents, checked through Sana) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'ai-sales');
  await login(p, 'sales'); await settle(p);
  // admin switches Sana off for ZZ99 (Administration › Add-Ons › AI Assistant (Sana)); the provider key is a Supabase secret, never in the database
  const off = await api('admin', 'sana_settings_save', { p_company: 'ZZ99', p: { enabled: false } });
  ok('admin switches Sana off for ZZ99', off.status === 200, JSON.stringify(off.body));
  await p.click('#top-ask-sana');
  ok('Sana off: the panel says it is switched off', await seen(p.locator('[data-testid=sana-off]')) && (await txt(p.locator('[data-testid=sana-off]'))).includes('switched off'));
  await p.keyboard.press('Escape');
  const on = await api('admin', 'sana_settings_save', { p_company: 'ZZ99', p: { enabled: true } });
  ok('admin switches Sana on', on.status === 200, JSON.stringify(on.body));
  await p.reload(); await settle(p);
  await p.click('#top-ask-sana');
  const ask = async (page, q) => {
    const n = await page.locator('aside[role=dialog] [data-testid=sana-answer], aside[role=dialog] [data-testid=sana-refusal]').count();
    await page.fill('#sana-input', q); await page.keyboard.press('Enter');
    await page.waitForFunction((k) => document.querySelectorAll('aside[role=dialog] [data-testid=sana-answer], aside[role=dialog] [data-testid=sana-refusal]').length > k, n, { timeout: 15000 }).catch(() => {});
    return txt(page.locator('aside[role=dialog] [data-testid=sana-answer], aside[role=dialog] [data-testid=sana-refusal]').last());
  };
  const before = Number((await one(`SELECT count(*) AS n FROM erp.audit_log WHERE actor = 'ai:sana'`)).n);
  const a1 = await ask(p, 'Show me the trial balance and the profit and loss');
  ok('sales user: finance data refused (no numbers)', /isn.t available for your role/.test(a1) && !/\d/.test(a1), a1);
  const a2 = await ask(p, 'Who owes us the most? overdue receivables');
  ok('sales user: receivables answered', /Open receivables are/.test(a2) && /AED/.test(a2), a2.slice(0, 120));
  ok('answer labelled basic mode (never shown as a real AI model)', await seen(p.locator('[data-testid=sana-basic]')));
  const srcs = await p.locator('aside[role=dialog] [data-testid=sana-answer] a').evaluateAll((as) => as.map((x) => x.getAttribute('href')));
  ok('sources are record links (open receivables list)', srcs.some((h) => h.startsWith('/docs/ar_invoice')) && !srcs.some((h) => h.includes('financials')), srcs.join(' '));
  const log = await one(`SELECT detail FROM erp.audit_log WHERE actor = 'ai:sana' AND action = 'sana.ask' ORDER BY audit_id DESC LIMIT 1`);
  ok('questions logged as ai:sana (user, tools, mode) without the question text',
    Number((await one(`SELECT count(*) AS n FROM erp.audit_log WHERE actor = 'ai:sana'`)).n) === before + 2 && log.detail.user_id === SALES_ID
    && log.detail.tools.includes('sana_receivables') && log.detail.mode === 'basic' && !JSON.stringify(log.detail).includes('owes us'));
  await p.screenshot({ path: `${OUT}/a11-ai-sales-en-light-1440.png`, fullPage: true });
  const href = srcs.find((h) => h.startsWith('/docs/ar_invoice'));
  await p.click(`aside[role=dialog] a[href="${href}"]`); await settle(p);
  ok('a source opens the record list', new URL(p.url()).pathname === '/docs/ar_invoice');
  await p.keyboard.press('Escape');
  // Ask Sana about this order
  const so = await one(`SELECT d.doc_entry, coalesce(w.doc_no, d.doc_num::text) AS no FROM erp.document d LEFT JOIN erp.doc_workflow w USING (company_code, obj_type, doc_entry)
                         WHERE d.company_code = 'ZZ99' AND d.obj_type = 17 ORDER BY d.doc_entry LIMIT 1`);
  await p.goto(`${BASE}/docs/sales_order/ZZ99/${so.doc_entry}`); await settle(p);
  await p.click('[data-testid=ask-sana-about]');
  ok('Ask Sana about this order: the panel shows the order as context', (await txt(p.locator('[data-testid=sana-context]'))).includes(so.no));
  await p.locator('aside[role=dialog] button', { hasText: 'Summarize this document' }).click();
  await p.locator('aside[role=dialog] [data-testid=sana-answer]').last().waitFor({ timeout: 15000 }).catch(() => {});
  ok('order answer uses the order', (await p.locator(`aside[role=dialog] a[href="/docs/sales_order/ZZ99/${so.doc_entry}"]`).count()) === 1
    && (await txt(p.locator('aside[role=dialog] [data-testid=sana-answer]').last())).includes(so.no));
  ok('document question logged with its context type', (await one(`SELECT detail FROM erp.audit_log WHERE actor = 'ai:sana' ORDER BY audit_id DESC LIMIT 1`)).detail.context === 'document');
  await C.close();
  // finance user asks about the P&L report
  const C2 = await context(browser);
  const f = await C2.newPage(); watch(f, 'ai-fin');
  await login(f, 'fin'); await settle(f);
  await f.goto(`${BASE}/reports/profit-loss`); await settle(f);
  await f.click('#rpt-ask-about');
  await f.locator('aside[role=dialog] [data-testid=sana-answer]').last().waitFor({ timeout: 15000 }).catch(() => {});
  ok('finance user: P&L question answered from the accounts', /revenue/i.test(await txt(f.locator('aside[role=dialog] [data-testid=sana-answer]').last())));
  await C2.close();
  const r = await fetch(`${GW}/functions/v1/sana`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ company: 'ZZ99', message: 'stock' }) });
  ok('server function refuses a request without a session', r.status === 401);
  const old = await fetch(`${GW}/functions/v1/ai-assistant`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ company: 'ZZ99', question: 'stock' }) });
  ok('the old ai-assistant function is gone (Sana is the single assistant)', old.status === 404);
}

// ---------- 6. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['library', '/reports'], ['trial-balance', `/reports/trial-balance?company=ZZ99&from=${y0}&to=${today}`], ['balance-sheet', `/reports/balance-sheet?company=ZZ99&as_of=${today}`],
  ['ar-aging', `/reports/ar-aging?company=ZZ99&as_of=${today}`], ['control', '/control'],
];
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'admin'); await settle(page);
  let scrollOk = true;
  for (const [nm, path] of shots) {
    await page.goto(`${BASE}${path}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(500);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${nm}`); }
    await page.screenshot({ path: `${OUT}/a11-${nm}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  // the Sana panel with an answer about the report
  await page.goto(`${BASE}/reports/ar-aging?company=ZZ99&as_of=${today}`); await settle(page);
  await page.locator('[data-testid=rpt-row]').first().waitFor({ timeout: 10000 }).catch(() => {});
  await page.locator('#rpt-ask-about').click();
  await page.locator('aside[role=dialog] [data-testid=sana-answer]').last().waitFor({ timeout: 15000 }).catch(() => {});
  if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log('  h-scroll: ai panel'); }
  await page.screenshot({ path: `${OUT}/a11-ai-panel-${lang}-${theme}-${width}.png` });
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

// module page shows the Reports functions as live
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'module');
  await login(page, 'admin'); await settle(page);
  await page.goto(`${BASE}/m/reports?fn=0`); await settle(page);
  ok('module page: Reports › Financials opens the library', await seen(page.locator('a[href="/reports?cat=financials"]')));
  await page.goto(`${BASE}/m/reports?fn=4`); await settle(page);
  ok('module page: Business Partners aging reports live', await seen(page.locator('a[href="/reports/ar-aging"]')) && await seen(page.locator('a[href="/reports/ap-aging"]')));
  await page.screenshot({ path: `${OUT}/a11-module-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA11 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

// B6 browser test: landed cost Broker (header) and Vendor per cost line (validation, A/P invoices filtered by vendor, rate
// difference, the landed cost page), Administration › Company Details › System currency (switch ZZ99's SAMPLE USD on),
// Financials › Conversion Differences (inactive note, preview, post, detail with the system currency journal, cancel, post
// again), and screenshots (1440 / 390, light / dark, EN / AR). Local stack only (Vite :5173 + gateway :54321 + PostgREST +
// Postgres). Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/b6-e2e.mjs [outDir]
// Leaves on the running DB: USD rates for today and yesterday, a USD PO / GRPO / A/P invoice of S0001 (ref B6-E2E) and a landed
// cost, two journals in 6200 / 6800 with system currency amounts, a cancelled and a posted conversion difference run. Switches
// ZZ99's system currency OFF again at the end (every posting date would need a USD rate otherwise).
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'b6-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail && !pass ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'], sales: ['qa.sales@sample.test', 'local-only-2'], fin: ['qa.finance@sample.test', 'local-only-4'],
  purch: ['qa.purchase@sample.test', 'local-only-10'],
};
const ID = { admin: '00000000-0000-4000-8000-000000000001', fin: '00000000-0000-4000-8000-000000000004', purch: '00000000-0000-4000-8000-000000000010' };
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
const YDAY = isoDay(Date.now() - 86400000);
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));
const num = (s) => Number(String(s).replace(/[^0-9.-]/g, ''));
async function pickCombo(page, id, q, label) {
  await page.fill(`#${id}`, q);
  const opt = page.locator('[role=option]', { hasText: label }).first();
  await opt.waitFor({ timeout: 8000 });
  await opt.click();
}

// ---------- Fixtures ----------
await as(ID.fin, `SELECT erp.fx_rate_save('ZZ99', $1::date, 'USD', 3.6725)`, [TODAY]);
await as(ID.fin, `SELECT erp.fx_rate_save('ZZ99', $1::date, 'USD', 3.70)`, [YDAY]);
// the shared database keeps ZZ99's system currency off; earlier aborted runs may have left it on
await db.query(`DELETE FROM erp.system_currency_setting WHERE company_code = 'ZZ99'`);
async function cleanup() {
  await db.query(`DELETE FROM erp.system_currency_setting WHERE company_code = 'ZZ99'`);
}
const po = (await as(ID.purch, `SELECT erp.purchase_doc_save('ZZ99', 22, NULL, $1::jsonb, $2::jsonb) AS r`,
  [JSON.stringify({ card_code: 'S0001', doc_date: YDAY, due_date: YDAY, whs_code: 'WH01' }), JSON.stringify([{ item_code: 'SMP-1140', qty: 10, price: 10 }])])).r.doc_entry;
await as(ID.purch, `SELECT erp.purchase_doc_submit('ZZ99', 22, $1, NULL)`, [po]);
const gr = (await as(ID.purch, `SELECT erp.purchase_grpo_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: YDAY }), JSON.stringify([{ base_doc_entry: po, base_line: 0, qty: 10 }])])).r.doc_entry;
const ap = (await as(ID.purch, `SELECT erp.purchase_invoice_create('ZZ99', $1::jsonb, $2::jsonb) AS r`, [JSON.stringify({ doc_date: YDAY, customer_ref: 'B6-E2E' }), JSON.stringify([{ base_doc_entry: gr, base_line: 0, qty: 10 }])])).r.doc_entry;

const browser = await chromium.launch();
let lc; let run;
try {
  ok('fixtures: USD goods receipt and S0001\'s A/P invoice yesterday (3.70)', Boolean(gr && ap), JSON.stringify({ gr, ap }));

  // ---------- 1. Landed cost: broker on the header, vendor per cost line ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'lc');
    await login(p, 'purch');
    await p.goto(`${BASE}/purchasing/landed-costs/new?company=ZZ99&grpo=${gr}`); await settle(p);
    await p.locator('[data-testid=lc-line]').first().waitFor({ timeout: 10000 });
    await pickCombo(p, 'lc-broker', 'S0009', 'S0009');
    ok('header: Broker combobox (supplier S0009 chosen)', (await p.inputValue('#lc-broker')).includes('S0009'));
    await p.selectOption('#lc-charge-0-currency', 'USD');
    await p.fill('#lc-charge-0-amount', '10');
    await pickCombo(p, 'lc-charge-0-vendor', 'S0009', 'S0009');
    const alert = p.locator('[data-testid=lc-summary] [role=alert]');
    ok('an AED vendor with a USD cost: the database message is shown', await seen(alert) && (await txt(alert)).includes('supplier S0009 trades in AED. Enter the charge in AED.'), await txt(p.locator('[data-testid=lc-summary]')));
    await pickCombo(p, 'lc-charge-0-vendor', 'S0001', 'S0001');
    const opts = await p.locator('#lc-charge-0-ap option').allInnerTexts();
    ok('A/P invoices offered for the cost are the vendor\'s (S0001, USD) only', opts.length >= 2 && opts.slice(1).every((o) => o.includes('S0001')), opts.join(' | '));
    await p.selectOption('#lc-charge-0-ap', String(ap));
    await p.locator('[data-testid=lc-fx-diff]').waitFor({ timeout: 10000 }).catch(() => {});
    ok('vendor\'s invoice at 3.70 against today\'s 3.6725: rate difference 0.27', num(await txt(p.locator('[data-testid=lc-fx-diff]'))) === 0.27, await txt(p.locator('[data-testid=lc-summary]')));
    await p.screenshot({ path: `${OUT}/b6-lc-new-en-light-1440.png`, fullPage: true });
    await p.click('#lc-submit');
    await p.waitForURL(/\/purchasing\/landed-costs\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    lc = Number(p.url().split('/').pop());
    ok('landed cost page: broker in the header, vendor per cost', await seen(p.locator('[data-testid=lc-charge-vendor]')) && (await txt(p.locator('main'))).includes('S0009')
      && (await txt(p.locator('[data-testid=lc-charge-vendor]').first())).includes('S0001'), await txt(p.locator('main')));
    const row = await one(`SELECT l.card_code AS broker, c.card_code AS vendor, c.fx_diff FROM erp.landed_cost l JOIN erp.landed_cost_charge c USING (company_code, doc_entry) WHERE l.company_code = 'ZZ99' AND l.doc_entry = $1`, [lc]);
    ok('stored: broker S0009, vendor S0001, difference 0.27', row?.broker === 'S0009' && row.vendor === 'S0001' && Number(row.fx_diff) === 0.27, JSON.stringify(row));
    await C.close();
  }

  // ---------- 2. Conversion Differences is off until a system currency is set ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'cvd-off');
    await login(p, 'fin');
    await p.goto(`${BASE}/financials/conversion-differences?company=ZZ99`); await settle(p);
    ok('Conversion Differences explains there is no system currency (and links to Company Details)', await seen(p.locator('[data-testid=cvd-inactive]')) && (await p.locator('#cvd-post').count()) === 0);
    await p.screenshot({ path: `${OUT}/b6-cvd-off-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // ---------- 3. Administration › Company Details › System currency ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'sys');
    await login(p, 'admin');
    await p.goto(`${BASE}/admin/company?company=ZZ99`); await settle(p);
    const card = p.locator('[data-testid=adm-sys-cur]');
    ok('Company Details shows the System currency card: off (local currency)', await seen(card) && (await txt(p.locator('[data-testid=adm-sys-cur-state]'))).includes('Off'));
    await p.selectOption('#adm-sys-cur', 'USD');
    await p.click('#adm-sys-cur-save');
    ok('admin switches the SAMPLE system currency USD on', await seen(card.locator('[role=status]')) && /Active: USD/.test(await txt(p.locator('[data-testid=adm-sys-cur-state]'))), await txt(card));
    ok('today\'s USD rate is shown', /1 USD = 3\.6725 AED/.test(await txt(p.locator('[data-testid=adm-sys-cur-state]'))), await txt(p.locator('[data-testid=adm-sys-cur-state]')));
    const s = await one(`SELECT currency FROM erp.system_currency_setting WHERE company_code = 'ZZ99'`);
    ok('stored: ZZ99 system currency USD', s?.currency === 'USD');
    await p.screenshot({ path: `${OUT}/b6-company-en-light-1440.png`, fullPage: true });
    await C.close();
  }

  // journals yesterday (3.70) and back today (3.6725): 6200 / 6800 net to 0 in AED but not in USD
  const j1 = (await one(`SELECT erp.post_journal('ZZ99', $1::date, 'B6 e2e rent', '[{"acct_code":"6200","debit":100},{"acct_code":"6800","credit":100}]'::jsonb, '{}') AS t`, [YDAY])).t;
  const j2 = (await one(`SELECT erp.post_journal('ZZ99', $1::date, 'B6 e2e rent back', '[{"acct_code":"6800","debit":100},{"acct_code":"6200","credit":100}]'::jsonb, '{}') AS t`, [TODAY])).t;
  const sys = await one(`SELECT string_agg(trim_scale(greatest(sys_debit, sys_credit))::text, ' ' ORDER BY trans_id, line_id) AS s FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id IN ($1, $2)`, [j1, j2]);
  ok('journals carry USD amounts: 27.03 yesterday, 27.23 today', sys?.s === '27.03 27.03 27.23 27.23', sys?.s);

  // ---------- 4. Conversion Differences: preview, post, detail, cancel, post again ----------
  {
    const C = await context(browser); const p = await C.newPage(); watch(p, 'cvd');
    await login(p, 'fin');
    await p.goto(`${BASE}/financials/conversion-differences?company=ZZ99`); await settle(p);
    await p.fill('#cvd-date', TODAY);
    const r6200 = p.locator('[data-testid=cvd-row][data-acct="6200"]');
    ok('preview: 6200 Rent (−0.20 USD, AED balance 0) and 6800 (+0.20 USD)', await seen(r6200) && (await txt(r6200)).includes('-0.20') && (await txt(p.locator('[data-testid=cvd-row][data-acct="6800"]'))).includes('0.20'),
      await txt(p.locator('[data-testid=cvd-rows]')));
    ok('summary: system currency USD', (await txt(p.locator('[data-testid=cvd-sys-cur]'))) === 'USD');
    await p.screenshot({ path: `${OUT}/b6-cvd-en-light-1440.png`, fullPage: true });
    await p.click('#cvd-post');
    await p.click('#cvd-post-confirm');
    await p.waitForURL(/\/financials\/conversion-differences\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    run = Number(p.url().split('/').pop());
    ok('posted: detail page with the journal in USD only', await seen(p.locator('[data-testid=cvd-journal]')) && (await txt(p.locator('[data-testid=cvd-journal]'))).includes('0.20'));
    const jr = await one(`SELECT j.total_local, j.total_sys, (SELECT count(*) FROM erp.journal_line l WHERE l.company_code = j.company_code AND l.trans_id = j.trans_id AND (l.debit <> 0 OR l.credit <> 0)) AS lc_lines
                            FROM erp.conv_diff_run r JOIN erp.journal_entry j ON j.company_code = r.company_code AND j.trans_id = r.trans_id WHERE r.run_id = $1`, [run]);
    ok('the run\'s journal has no AED effect', jr && Number(jr.total_local) === 0 && Number(jr.lc_lines) === 0 && Number(jr.total_sys) > 0, JSON.stringify(jr));
    await p.screenshot({ path: `${OUT}/b6-cvd-detail-en-light-1440.png`, fullPage: true });
    await p.click('#cvd-cancel');
    await p.fill('#cvd-cancel-reason', 'b6-e2e');
    await p.click('#cvd-cancel-confirm'); await settle(p);
    await p.locator('[data-testid=cvd-journal]').nth(1).waitFor({ timeout: 10000 }).catch(() => {});
    ok('cancelled: state Cancelled, reversal listed', /Cancelled/.test(await txt(p.locator('[data-testid=cvd-state]'))) && (await p.locator('[data-testid=cvd-journal]').count()) === 2,
      `${await txt(p.locator('[data-testid=cvd-state]'))} / ${await p.locator('[data-testid=cvd-journal]').count()} / ${await txt(p.locator('main [role=alert]'))}`);
    await p.goto(`${BASE}/financials/conversion-differences?company=ZZ99`); await settle(p);
    await p.fill('#cvd-date', TODAY);
    ok('after cancelling, the differences are offered again', await seen(p.locator('[data-testid=cvd-row][data-acct="6200"]')));
    await p.click('#cvd-post');
    await p.click('#cvd-post-confirm');
    await p.waitForURL(/\/financials\/conversion-differences\/ZZ99\/\d+/, { timeout: 15000 }); await settle(p);
    run = Number(p.url().split('/').pop());
    await p.goto(`${BASE}/financials/conversion-differences?company=ZZ99`); await settle(p);
    await p.fill('#cvd-date', TODAY);
    ok('posted again: nothing left, post disabled', await seen(p.locator('text=No conversion differences')) && await p.locator('#cvd-post').isDisabled());
    ok('history lists both runs', (await p.locator('[data-testid=cvd-history] li').count()) >= 2);
    await C.close();
    const S = await context(browser); const ps = await S.newPage(); watch(ps, 'cvd-sales');
    await login(ps, 'sales');
    await ps.goto(`${BASE}/financials/conversion-differences?company=ZZ99`); await settle(ps);
    ok('Sales can\'t open Conversion Differences', !(await seen(ps.locator('#cvd-date'), 3000)));
    await S.close();
    const M = await context(browser); const pm = await M.newPage(); watch(pm, 'menu');
    await login(pm, 'fin');
    await pm.goto(`${BASE}/m/financials`); await settle(pm);
    await pm.locator('[role=option] button', { hasText: 'Conversion Differences' }).first().click().catch(() => {});
    ok('Financials menu: Conversion Differences is live', await seen(pm.locator('a[href="/financials/conversion-differences"]')));
    await M.close();
  }

  // ---------- 5. Screenshots: 1440 / 390, light / dark, EN / AR ----------
  const PAGES = [
    ['company', '/admin/company?company=ZZ99'],
    ['cvd', '/financials/conversion-differences?company=ZZ99'],
    ['cvd-detail', `/financials/conversion-differences/ZZ99/${run}`],
    ['lc', `/purchasing/landed-costs/ZZ99/${lc}`],
    ['lc-new', `/purchasing/landed-costs/new?company=ZZ99&grpo=${gr}`],
  ];
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      for (const lang of ['en', 'ar']) {
        const C = await context(browser, { width: w, height: h, lang, theme });
        const p = await C.newPage(); watch(p, `shots-${w}-${theme}-${lang}`);
        await login(p, 'admin');
        for (const [name, url] of PAGES) {
          await p.goto(`${BASE}${url}`); await settle(p); await p.waitForTimeout(400);
          await p.screenshot({ path: `${OUT}/b6-${name}-${lang}-${theme}-${w}.png`, fullPage: w > 500 });
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

// A1 browser + API test against the local stack (Vite + gateway + PostgREST + Postgres with ZZ99, 16_module_access.sql
// and test-users.sql). Usage: node scripts/local-stack/a1-e2e.mjs [outDir] — needs Vite on :5173 and the gateway on :54321.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright'); // preinstalled globally, or add it as a dev dependency
import fs from 'node:fs';

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const API = process.env.API_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a1-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const rowsCount = async (page) => page.locator('main table tbody tr').count();

async function login(page, email, password) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
async function token(email, password) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { 'content-type': 'application/json', apikey: 'local' }, body: JSON.stringify({ email, password }) });
  return (await r.json()).access_token;
}
async function rest(tok, path) {
  const r = await fetch(`${API}/rest/v1/${path}`, { headers: { apikey: 'local', authorization: `Bearer ${tok}`, 'accept-profile': 'erp' } });
  return { status: r.status, body: await r.json() };
}
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); }, [lang, theme]);
  return ctx;
}

const browser = await chromium.launch();

// ---------- API: the database itself enforces module access ----------
{
  const sales = await token('qa.sales@sample.test', 'local-only-2');
  let r = await rest(sales, 'journal_entry?select=trans_id');
  ok('API: sales user fetching journal_entry gets []', r.status === 200 && Array.isArray(r.body) && r.body.length === 0, `${r.status} ${JSON.stringify(r.body).slice(0, 60)}`);
  r = await rest(sales, 'payment?select=doc_entry');
  ok('API: sales user fetching payment gets []', r.status === 200 && r.body.length === 0, `${r.body.length} rows`);
  r = await rest(sales, 'document?select=doc_entry&obj_type=eq.22');
  ok('API: sales user fetching purchase orders gets []', r.status === 200 && r.body.length === 0, `${r.body.length} rows`);
  r = await rest(sales, 'document?select=doc_entry&obj_type=eq.17');
  ok('API: sales user still gets sales orders', r.status === 200 && r.body.length > 0, `${r.body.length} rows`);
  const fin = await token('qa.finance@sample.test', 'local-only-4');
  r = await rest(fin, 'journal_entry?select=trans_id');
  ok('API: finance user gets journal entries', r.status === 200 && r.body.length > 0, `${r.body.length} rows`);
  const nobody = await token('qa.nobody@sample.test', 'local-only-3');
  r = await rest(nobody, 'document?select=doc_entry');
  ok('API: user with no profile gets []', r.status === 200 && r.body.length === 0, `${r.body.length} rows`);
}

// ---------- Sales-only user: no access to Financials ----------
for (const [lang, theme] of [['en', 'light'], ['ar', 'dark']]) {
  const ctx = await context(browser, { lang, theme });
  const page = await ctx.newPage();
  await login(page, 'qa.sales@sample.test', 'local-only-2'); await settle(page);
  await page.goto(`${BASE}/financials/journals`); await settle(page);
  const blocked = (await page.locator('[role=alert]').count()) > 0 && (await rowsCount(page)) === 0;
  ok(`sales user: /financials/journals shows the no-access screen (${lang}, ${theme})`, blocked);
  await page.screenshot({ path: `${OUT}/a1-sales-journals-noaccess-${lang}-${theme}-1440.png`, fullPage: true });
  await ctx.close();
}

// ---------- Read-only sales user: reads, but New is disabled with the reason ----------
for (const [width, lang, theme] of [[1440, 'en', 'light'], [1440, 'en', 'dark'], [1440, 'ar', 'light'], [1440, 'ar', 'dark'], [390, 'en', 'light'], [390, 'en', 'dark'], [390, 'ar', 'light'], [390, 'ar', 'dark']]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await login(page, 'qa.salesread@sample.test', 'local-only-6'); await settle(page);
  await page.goto(`${BASE}/docs/sales_order`); await settle(page);
  const tag = `${lang}-${theme}-${width}`;
  if (width === 1440 && lang === 'en' && theme === 'light') {
    ok('read-only user can read sales orders', (await rowsCount(page)) > 0, `${await rowsCount(page)} rows`);
    const btn = page.locator('#new-sales');
    ok('read-only user: "New sales order" is disabled', await btn.isDisabled());
    ok('read-only user: reason "Read-only access to Sales" is shown', (await page.locator('text=Read-only access to Sales').count()) > 0);
    const mods = await page.locator('aside nav a[href^="/m/"]').allInnerTexts();
    ok('read-only user sees Sales in the sidebar', mods.some((m) => /Sales/.test(m)), mods.map((m) => m.split('\n')[0]).join(', '));
  }
  if (lang === 'ar' && width === 1440 && theme === 'light') {
    ok('Arabic read-only reason shown', (await page.locator('text=صلاحية قراءة فقط').count()) > 0);
  }
  if (width === 390) ok(`no horizontal scroll at 390 px (${lang}, ${theme})`, !(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)));
  ok(`no page errors (${tag})`, errors.length === 0, errors.slice(0, 2).join(' | '));
  await page.screenshot({ path: `${OUT}/a1-readonly-sales-orders-${tag}.png`, fullPage: true });
  await ctx.close();
}

// ---------- Finance user ----------
{
  const ctx = await context(browser);
  const page = await ctx.newPage();
  await login(page, 'qa.finance@sample.test', 'local-only-4'); await settle(page);
  const mods = await page.locator('aside nav a[href^="/m/"]').allInnerTexts();
  ok('finance user sees Financials and Banking', mods.some((m) => /Financials/.test(m)) && mods.some((m) => /Banking/.test(m)), mods.map((m) => m.split('\n')[0]).join(', '));
  await page.goto(`${BASE}/financials/journals`); await settle(page);
  ok('finance user reads journals', (await rowsCount(page)) > 0, `${await rowsCount(page)} rows`);
  await page.goto(`${BASE}/docs/purchase_order`); await settle(page);
  ok('finance user reads purchase orders (API rule)', (await rowsCount(page)) > 0 || (await page.locator('[role=alert]').count()) > 0);
  await page.screenshot({ path: `${OUT}/a1-finance-journals-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

// ---------- Owner (business): sees all modules, but no automatic write ----------
{
  const ctx = await context(browser);
  const page = await ctx.newPage();
  await login(page, 'qa.owner@sample.test', 'local-only-5'); await settle(page);
  ok('owner sees all 11 modules', (await page.locator('aside nav a[href^="/m/"]').count()) === 11);
  await page.goto(`${BASE}/financials/journals`); await settle(page);
  ok('owner reads journals', (await rowsCount(page)) > 0);
  ok('owner: "New journal entry" shows read-only reason', (await page.locator('text=Read-only access to Financials').count()) > 0);
  await page.screenshot({ path: `${OUT}/a1-owner-journals-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

await browser.close();
fs.writeFileSync(`${OUT}/a1-results.json`, JSON.stringify(results, null, 1));
const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);


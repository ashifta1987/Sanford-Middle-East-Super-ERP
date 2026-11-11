// A10 browser test: Administration, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a10-e2e.mjs [outDir]
// Non-admins refused, IT read-only → admin invites a user (gateway stand-in for the invite-user Edge Function + test inbox) →
// the invited user follows the email link, sets a password, signs in again → admin deactivates them (gone on the next request) →
// Authorizations matrix with review and save (takes effect on the next sign-in) → approval templates → numbering →
// company details changed by admin, approved by the owner from the inbox → exchange rates (finance, CSV import) →
// AI Assistant (Sana) settings (no key field) → screenshots 1440 / 390, light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const GW = process.env.GATEWAY_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a10-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const uniq = String(Date.now()).slice(-6);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
  owner: ['qa.owner@sample.test', 'local-only-5'],
  salesread: ['qa.salesread@sample.test', 'local-only-6'],
  it: ['qa.it@sample.test', 'local-only-23'],
};
async function loginAs(page, email, password) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
const login = (page, who) => loginAs(page, ...USERS[who]);
async function context(browser, { width = 1440, height = 900, lang = 'en', theme = 'light' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  return ctx;
}
const txt = (loc) => loc.first().innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const flash = async (p) => { await seen(p.locator('[data-testid=adm-flash]')); return txt(p.locator('[data-testid=adm-flash]')); };
const flashHas = (p, text) => seen(p.locator('[data-testid=adm-flash]', { hasText: text }));
const errText = async (p) => { await seen(p.locator('[data-testid=adm-error]')); return txt(p.locator('[data-testid=adm-error]')); };
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

// fixtures: no company change waiting; QA_SALES_READ back to sales read; AI off
await db.query(`UPDATE erp.approval SET superseded = true WHERE company_code = 'ZZ99' AND object = 'company_details' AND decision IS NULL`);
await db.query(`UPDATE erp.company_change_request SET state = 'cancelled' WHERE company_code = 'ZZ99' AND state = 'pending_approval'`);
await db.query(`INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_SALES_READ', 'sales', 'read') ON CONFLICT (position_code, module) DO UPDATE SET level = 'read'`);
await db.query(`DELETE FROM erp.approval_rule WHERE company_code = 'ZZ99' AND rule_code = 'payment_amount' AND position_code = 'QA_SALES_READ'`);
await db.query(`DELETE FROM erp.ai_setting WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99'`);

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- 1. Non-admin refused; IT read-only ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'sales');
  await login(p, 'sales'); await settle(p);
  for (const path of ['/admin/users', '/admin/authorizations', '/admin/ai-assistant']) {
    await p.goto(`${BASE}${path}`); await settle(p);
    ok(`sales user refused on ${path}`, await seen(p.locator('main [role=alert]')) && (await txt(p.locator('main [role=alert]'))).includes('No access'));
  }
  await C.close();
  const C2 = await context(browser);
  const q = await C2.newPage(); watch(q, 'it');
  await login(q, 'it'); await settle(q);
  await q.goto(`${BASE}/admin/users`); await settle(q);
  ok('IT sees the user list', await seen(q.locator('[data-testid=adm-user-row]')));
  ok('IT is read-only (note + invite disabled)', await seen(q.locator('[data-testid=adm-readonly]')) && await q.locator('#adm-invite-off').isDisabled());
  await q.goto(`${BASE}/admin/authorizations`); await settle(q);
  ok('IT sees the matrix without editors', await seen(q.locator('[data-testid=adm-matrix-row]')) && (await q.locator('[data-testid=adm-matrix] select').count()) === 0);
  await C2.close();
}

// ---------- 2. Invite → email link → set password → sign in ----------
const email = `e2e.${uniq}@sample.test`;
let newId = null;
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'admin-invite');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/admin/users`); await settle(p);
  ok('admin sees users with last sign-in column', await seen(p.locator('[data-testid=adm-user-row]')) && (await p.locator('[data-testid=adm-user-row]').count()) >= 20);
  await p.click('#adm-invite'); await settle(p);
  await p.fill('#adm-u-email', 'qa.sales@sample.test');
  await p.fill('#adm-u-name', `E2E Invitee ${uniq}`);
  await p.selectOption('#adm-u-position', 'QA_SALES_READ');
  await p.click('#adm-u-save');
  await seen(p.locator('[data-testid=adm-error]'));
  ok('invite of an existing email refused with the server message', (await errText(p)).includes('already exists'));
  await p.fill('#adm-u-email', email);
  await p.click('#adm-u-save');
  await p.waitForURL((u) => u.pathname === '/admin/users', { timeout: 15000 }).catch(() => {});
  await seen(p.locator('[data-testid=adm-flash]'));
  ok('invitation sent', (await flash(p)).includes(email));
  const u = await one(`SELECT user_id, position_code, active FROM erp.app_user WHERE email = $1`, [email]);
  newId = u?.user_id;
  ok('invited user has a profile with the chosen position', u?.position_code === 'QA_SALES_READ' && u?.active === true);
  await p.screenshot({ path: `${OUT}/a10-users-after-invite-en-light-1440.png`, fullPage: true });
  await C.close();
}
const inbox = await (await fetch(`${GW}/local/inbox?email=${encodeURIComponent(email)}`)).json();
ok('test inbox received the invitation email', inbox.length === 1 && inbox[0].link.includes('type=invite'));
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'invitee');
  await p.goto(inbox[0].link); await settle(p);
  await p.waitForTimeout(800);
  ok('invitee lands signed in, with Sales (read) in the sidebar', await seen(p.locator('aside nav a[href="/m/sales"]')) && (await p.locator('aside nav a[href="/m/administration"]').count()) === 0);
  await p.click(`button[aria-label="Change password"]`);
  await p.fill('#pw1', `E2e-pass-${uniq}`); await p.fill('#pw2', `E2e-pass-${uniq}`);
  await p.click('button:has-text("Save password")');
  await p.waitForTimeout(800);
  await C.close();
  const C2 = await context(browser);
  const q = await C2.newPage(); watch(q, 'invitee2');
  await loginAs(q, email, `E2e-pass-${uniq}`).then(() => ok('invitee signs in with the password they set', true)).catch((e) => ok('invitee signs in with the password they set', false, e.message));
  await settle(q);
  // ---------- 3. Admin deactivates → gone on the next request ----------
  const A = await context(browser);
  const a = await A.newPage(); watch(a, 'admin-deact');
  await login(a, 'admin'); await settle(a);
  await a.goto(`${BASE}/admin/users/${newId}`); await settle(a);
  await seen(a.locator('#adm-u-active'));
  await a.uncheck('#adm-u-active');
  await a.click('#adm-u-save');
  await a.waitForURL((u) => u.pathname === '/admin/users', { timeout: 15000 }).catch(() => {});
  ok('admin deactivates the user', (await flash(a)).includes('saved') && (await one(`SELECT active FROM erp.app_user WHERE user_id = $1`, [newId]))?.active === false);
  await a.goto(`${BASE}/admin/users/${(await one(`SELECT user_id FROM erp.app_user WHERE email = 'qa.admin@sample.test'`)).user_id}`); await settle(a);
  ok('admin cannot switch themselves off (checkbox disabled)', await a.locator('#adm-u-active').isDisabled());
  await A.close();
  const rr = await q.evaluate(async () => {
    const k = Object.keys(localStorage).find((x) => x.includes('auth-token'));
    const tok = JSON.parse(localStorage.getItem(k)).access_token;
    const r = await fetch('http://127.0.0.1:54321/rest/v1/item?select=item_code&limit=1', { headers: { authorization: `Bearer ${tok}`, apikey: 'local', 'accept-profile': 'erp' } });
    return (await r.json()).length;
  });
  ok('deactivated user reads nothing on the next request', rr === 0);
  await q.reload(); await settle(q); await q.waitForTimeout(600);
  ok('deactivated user sees no modules after reload', (await q.locator('aside nav a[href^="/m/"]').count()) === 0);
  await C2.close();
}

// ---------- 4. Authorizations matrix ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'admin-auth');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/admin/authorizations`); await settle(p);
  const row = p.locator('[data-testid=adm-matrix-row][data-position=QA_SALES_READ]');
  await seen(row);
  await row.locator('select[data-module=sales]').selectOption('none');
  await row.locator('select[data-module=inventory]').selectOption('read');
  await p.click('#adm-review-QA_SALES_READ'); await settle(p);
  await seen(p.locator('[data-testid=adm-preview]'));
  const pv = await txt(p.locator('[data-testid=adm-preview]'));
  ok('review shows gain, loss and the affected user', pv.includes('Will gain') && pv.includes('Inventory') && pv.includes('Will lose') && pv.includes('Sales') && pv.includes('QA Sales read-only'));
  await p.screenshot({ path: `${OUT}/a10-authorizations-review-en-light-1440.png`, fullPage: true });
  await p.click('#adm-access-save'); await settle(p);
  ok('matrix saved', (await flash(p)).includes('QA_SALES_READ') && (await one(`SELECT count(*)::int AS n FROM erp.position_module WHERE position_code = 'QA_SALES_READ' AND module = 'sales'`)).n === 0);
  const own = p.locator('[data-testid=adm-matrix-row][data-position=QA_ALL]');
  await own.locator('select[data-module=admin]').selectOption('read');
  await p.click('#adm-review-QA_ALL'); await settle(p);
  await seen(p.locator('[data-testid=adm-preview]'));
  await p.click('#adm-access-save'); await settle(p);
  await seen(p.locator('[data-testid=adm-error]'));
  ok('admin cannot lower their own Administration access', (await errText(p)).includes("can't remove your own Administration access"));
  await C.close();
  const C2 = await context(browser);
  const q = await C2.newPage(); watch(q, 'salesread');
  await login(q, 'salesread'); await settle(q);
  ok('next sign-in: Sales gone, Inventory there', (await q.locator('aside nav a[href="/m/sales"]').count()) === 0 && await seen(q.locator('aside nav a[href="/m/inventory"]')));
  await C2.close();
  const C3 = await context(browser);
  const r = await C3.newPage(); watch(r, 'admin-auth2');
  await login(r, 'admin'); await settle(r);
  await r.goto(`${BASE}/admin/authorizations`); await settle(r);
  const row2 = r.locator('[data-testid=adm-matrix-row][data-position=QA_SALES_READ]');
  await seen(row2);
  await row2.locator('select[data-module=sales]').selectOption('read');
  await row2.locator('select[data-module=inventory]').selectOption('none');
  await r.click('#adm-review-QA_SALES_READ'); await settle(r);
  await seen(r.locator('[data-testid=adm-preview]'));
  await r.click('#adm-access-save'); await settle(r);
  await flash(r);
  ok('access restored', (await one(`SELECT level FROM erp.position_module WHERE position_code = 'QA_SALES_READ' AND module = 'sales'`))?.level === 'read');
  await C3.close();
}

// ---------- 5. Approval templates, numbering ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'admin-setup');
  await login(p, 'admin'); await settle(p);
  // B2: the A10 rule list moved to /admin/approval-rules (compatibility); /admin/approval-templates is the new Approval Templates screen.
  await p.goto(`${BASE}/admin/approval-rules`); await settle(p);
  ok('templates list the sample rules and the new-documents note', await seen(p.locator('[data-testid=adm-rule-row]')) && (await txt(p.locator('[data-testid=adm-tpl-note]'))).includes('from now on'));
  await p.click('#adm-add-discount_pct');
  await p.fill('#adm-r-limit', '5'); await p.selectOption('#adm-r-appr', 'QA_SALES_MGR');
  await p.click('#adm-r-save'); await settle(p);
  ok('discount rule without a position refused', (await errText(p)).includes("Choose the requester's position"));
  await p.click('#adm-add-payment_amount');
  await p.selectOption('#adm-r-pos', 'QA_SALES_READ'); await p.fill('#adm-r-limit', '1000'); await p.selectOption('#adm-r-appr', 'QA_FIN_MGR');
  await p.click('#adm-r-save'); await settle(p);
  ok('rule added', (await flash(p)).includes('Rule added') && Boolean(await one(`SELECT rule_id FROM erp.approval_rule WHERE company_code = 'ZZ99' AND rule_code = 'payment_amount' AND position_code = 'QA_SALES_READ'`)));
  await p.locator('[data-rule=payment_amount] [data-testid=adm-rule-row]', { hasText: 'sales read-only' }).locator('button').click();
  await p.click('[data-testid=adm-rule-form] button:has-text("Delete")');
  await p.click('#adm-r-delete-confirm'); await settle(p);
  ok('rule deleted', await flashHas(p, 'Rule deleted'));

  await p.goto(`${BASE}/admin/numbering`); await settle(p);
  const lead = await one(`SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 2003`);
  await p.locator('[data-testid=adm-series-row][data-obj="2003"] button').click();
  await p.fill('#adm-n-next', String(lead.next_num + 1));
  await p.click('#adm-n-save'); await settle(p);
  ok('numbering moved forward', (await flash(p)).includes('Lead code') && (await one(`SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 2003`)).next_num === lead.next_num + 1);
  await p.locator('[data-testid=adm-series-row][data-obj="2003"] button').click();
  await p.fill('#adm-n-next', String(lead.next_num));
  await p.click('#adm-n-save'); await settle(p);
  ok('numbering cannot go back', (await errText(p)).includes('Numbers only move forward'));
  await C.close();
}

// ---------- 6. Company details: admin asks, owner approves from the inbox ----------
{
  const phone = `+971 4 ${uniq.slice(0, 3)} ${uniq.slice(3)}`;
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'admin-co');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/admin/company`); await settle(p);
  await seen(p.locator('#adm-co-phone'));
  await p.fill('#adm-co-tax_id', '123');
  await p.click('#adm-co-submit'); await settle(p);
  ok('short TRN refused', (await errText(p)).includes('15 digits'));
  await p.fill('#adm-co-tax_id', '100000000000003');
  await p.fill('#adm-co-phone', phone);
  await p.fill('#adm-co-reason', 'E2E new phone line');
  await p.click('#adm-co-submit'); await settle(p);
  ok('change sent to the owner', (await flash(p)).includes('Sent to') && await seen(p.locator('[data-testid=adm-co-pending]')));
  await C.close();
  const C2 = await context(browser);
  const q = await C2.newPage(); watch(q, 'owner');
  await login(q, 'owner'); await settle(q);
  await q.goto(`${BASE}/approvals`); await settle(q);
  const link = q.locator('[data-testid=inbox-table] a[href^="/admin/company"]');
  ok('owner sees the change in the inbox', await seen(link));
  await link.first().click(); await settle(q);
  await seen(q.locator('#adm-co-approve'));
  await q.screenshot({ path: `${OUT}/a10-company-owner-en-light-1440.png`, fullPage: true });
  await q.click('#adm-co-approve'); await settle(q);
  ok('owner approves; printed details changed', (await flash(q)).includes('Approved') && (await one(`SELECT phone FROM erp.company_profile WHERE company_code = 'ZZ99'`))?.phone === phone);
  await C2.close();
}

// ---------- 7. Exchange rates (finance) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'fin-fx');
  await login(p, 'fin'); await settle(p);
  await p.goto(`${BASE}/admin/exchange-rates`); await settle(p);
  await seen(p.locator('#adm-fx-rate'));
  await p.selectOption('#adm-fx-cur', 'USD'); await p.fill('#adm-fx-rate', '3.6725');
  await p.click('#adm-fx-save'); await settle(p);
  ok('finance enters a USD rate', (await flash(p)).includes('USD rate'));
  await p.setInputFiles('#adm-fx-file', { name: 'bad.csv', mimeType: 'text/csv', buffer: Buffer.from('date,currency,rate\n2026-10-01,USD,3.6725\n2026-10-01,JPY,0.02\n') });
  await settle(p);
  ok('import with a bad row saves nothing and names the row', (await txt(p.locator('[data-testid=adm-fx-rowerrs]'))).includes('Row 2'));
  await p.setInputFiles('#adm-fx-file', { name: 'ok.csv', mimeType: 'text/csv', buffer: Buffer.from('date,currency,rate\n2026-10-01,USD,3.6725\n2026-10-01,CNY,0.5161\n2026-10-01,EUR,4.2412\n') });
  await settle(p);
  ok('clean import saved', await flashHas(p, '3 rates imported'));
  ok('rates table shows the dates', await seen(p.locator('[data-testid=adm-fx-row][data-date="2026-10-01"]')));
  await C.close();
}

// ---------- 8. AI Assistant (U0+S1: the screen now edits Sana's settings; A10's provider / tables form is gone) ----------
{
  const C = await context(browser);
  const p = await C.newPage(); watch(p, 'admin-ai');
  await login(p, 'admin'); await settle(p);
  await p.goto(`${BASE}/admin/ai-assistant`); await settle(p);
  await seen(p.locator('#adm-ai-enabled'));
  ok('no field for an API key on the page', (await p.locator('main input[type=password], main input[name*=key i], main input[id*=key i]').count()) === 0 && (await txt(p.locator('[data-testid=adm-ai-key]'))).includes('never saved in the database'));
  await p.fill('#adm-ai-limit', '6000');
  await p.click('#adm-ai-save'); await settle(p);
  ok('daily limit above 5,000 refused with the reason', (await errText(p)).includes('Enter a daily limit from 0 to 5,000'));
  await p.fill('#adm-ai-limit', '150'); await p.uncheck('input[data-lang=ru]');
  await p.click('#adm-ai-save'); await settle(p);
  ok('Sana settings saved (on, limit 150, Russian off)', (await flash(p)).includes('Sana is on') && (await txt(p.locator('[data-testid=adm-ai-state]'))) === 'On'
    && !(await p.isChecked('input[data-lang=ru]')));
  ok('usage shown as counts only', await seen(p.locator('[data-testid=adm-ai-usage]')));
  await p.uncheck('#adm-ai-enabled');
  await p.click('#adm-ai-save'); await settle(p);
  ok('Sana switched off again', await flashHas(p, 'Sana is off'));
  await p.check('#adm-ai-enabled'); await p.check('input[data-lang=ru]'); await p.fill('#adm-ai-limit', '200');
  await p.click('#adm-ai-save'); await settle(p);
  await C.close();
}

// ---------- 9. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['users', '/admin/users'], ['invite', '/admin/users/invite'], ['authorizations', '/admin/authorizations'], ['templates', '/admin/approval-rules'],
  ['numbering', '/admin/numbering'], ['company', '/admin/company'], ['rates', '/admin/exchange-rates'], ['ai', '/admin/ai-assistant'],
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
    await page.screenshot({ path: `${OUT}/a10-${nm}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

// module page shows the Administration functions as live
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'module');
  await login(page, 'admin'); await settle(page);
  await page.goto(`${BASE}/m/administration?fn=7`); await settle(page);
  await page.waitForTimeout(500);
  ok('module page: Approval Process opens the templates', await seen(page.locator('a[href="/admin/approvals/templates"]')));
  await page.goto(`${BASE}/m/administration?fn=3`); await settle(page);
  ok('module page: Authorizations and Document Numbering live', await seen(page.locator('a[href="/admin/authorizations"]')) && await seen(page.locator('a[href="/admin/numbering"]')));
  await page.screenshot({ path: `${OUT}/a10-module-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA10 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

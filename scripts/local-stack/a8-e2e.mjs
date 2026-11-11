// A8 browser test: master data (business partners and items), against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright + pg> node scripts/local-stack/a8-e2e.mjs [outDir]
// qa.bpread sees New disabled → qa.bp creates a customer: empty form problems, UAE TRN check, duplicate warning (same phone) confirmed
// with a reason, credit limit waits → edit applies other fields → qa.finmgr approves from the inbox and the limit applies → SAP stand-in
// partner explains why it can't be edited → bank details by qa.bp wait for approval → qa.stock creates an item (barcode must be unique),
// edits it; SAP item read-only → read-only inventory user → Trademark Master, change list, module page. Screenshots 1440 / 390,
// light / dark, EN / AR.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'a8-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const uniq = String(Date.now()).slice(-6);

const USERS = {
  bp: ['qa.bp@sample.test', 'local-only-16'],
  bpread: ['qa.bpread@sample.test', 'local-only-17'],
  fmgr: ['qa.finmgr@sample.test', 'local-only-8'],
  stock: ['qa.stock@sample.test', 'local-only-13'],
  sread: ['qa.stockread@sample.test', 'local-only-15'],
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
const txt = (loc) => loc.first().innerText({ timeout: 8000 }).catch(() => '');
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- 1. Read-only Business Partners user ----------
{
  const C0 = await context(browser);
  const p0 = await C0.newPage(); watch(p0, 'bpread');
  await login(p0, 'bpread'); await settle(p0);
  await p0.goto(`${BASE}/bp`); await settle(p0);
  ok('read-only: "New business partner" disabled with the reason', await p0.locator('#bp-new').isDisabled().catch(() => false)
    && /read-only/i.test(await txt(p0.locator('#bp-new-reason'))));
  await C0.close();
}

// ---------- 2. qa.bp creates a customer ----------
const C = await context(browser);
const pb = await C.newPage(); watch(pb, 'bp');
await login(pb, 'bp'); await settle(pb);
await pb.goto(`${BASE}/bp/new`); await settle(pb);
await pb.locator('#bp-save').waitFor({ timeout: 15000 });
ok('form shows the next code from the series', (await txt(pb.locator('[data-testid=bp-save-card]'))).includes('Gets code C'));
await pb.locator('#bp-save').click();
await seen(pb.locator('[data-testid=md-error-summary]'));
const summary = await txt(pb.locator('[data-testid=md-error-summary]'));
ok('empty form: problems listed at the top and under the fields', summary.includes('Enter the partner name.') && summary.includes('Enter the group. It is mandatory in company ZZ99.')
  && (await txt(pb.locator('#bp-name-err'))) === 'Enter the partner name.', summary.slice(0, 200));
const name = `E2E Hypermarket ${uniq}`;
await pb.fill('#bp-name', name);
await pb.fill('#bp-foreign_name', 'هايبرماركت تجريبي');
await pb.locator('#bp-group_code').selectOption('100');
await pb.locator('#bp-payment_terms').selectOption('2');
await pb.locator('#bp-price_list').selectOption('1');
await pb.fill('#bp-city', 'Dubai');
await pb.fill('#bp-trn', '12345');
await pb.fill('#bp-phone', '+971 4 000 0000');
await pb.fill('#bp-email', `buyer${uniq}@e2e.test`);
await pb.fill('#bp-credit_limit', '50000');
await pb.locator('#bp-add-contact').click();
await pb.fill('#bp-contacts-0', 'E2E Buyer');
await pb.fill('#bp-contact-mobile-0', '+971 50 000 1111');
await pb.locator('#bp-add-address').click();
await pb.fill('#bp-addresses-0', 'Head office');
await pb.locator('#bp-save').click();
await seen(pb.locator('#bp-trn-err'));
ok('UAE TRN must be 15 digits (message under the field)', (await txt(pb.locator('#bp-trn-err'))) === 'The TRN must be 15 digits for a UAE partner, e.g. 100123456700003.');
await pb.fill('#bp-trn', `100${uniq}000003`);
await pb.waitForTimeout(800);
ok('credit limit note names the approver', (await txt(pb.locator('[data-testid=bp-credit-note]'))).includes('QA · finance manager'));
await pb.fill('#bp-reason', 'New key account (E2E)');
ok('duplicate warning shown before saving (same phone)', (await txt(pb.locator('[data-testid=bp-dup-warning]'))).includes('same phone'));
await pb.screenshot({ path: `${OUT}/a8-bp-form-filled-en-light-1440.png`, fullPage: true });
await pb.locator('#bp-save').click();
ok('save opens the duplicate dialog with the matches', await seen(pb.locator('[data-testid=md-dup-list]')));
await pb.screenshot({ path: `${OUT}/a8-bp-duplicate-dialog-en-light-1440.png`, fullPage: true });
await pb.locator('#md-dup-confirm').click();
ok('a reason is needed to save anyway', (await txt(pb.locator('[role=dialog] [role=alert]'))).includes('Enter the reason'));
await pb.fill('#md-dup-reason', 'Shared switchboard number of the mall');
await pb.locator('#md-dup-confirm').click();
await pb.waitForURL(/\/bp\/ZZ99\/C\d+$/, { timeout: 15000 }).catch(() => {});
const code = decodeURIComponent(new URL(pb.url()).pathname.split('/').pop());
await settle(pb);
const flash1 = await txt(pb.locator('[data-testid=bk-flash]'));
ok('partner created; flash says the credit limit waits', /^C\d{5}$/.test(code) && flash1.includes('created') && flash1.includes('waits for QA · finance manager'), `${code} · ${flash1}`);
const row = await one('SELECT credit_limit, source, trn FROM erp.business_partner WHERE company_code = $1 AND card_code = $2', ['ZZ99', code]);
ok('database: Super ERP partner, credit limit 0 until approved', row?.source === 'erp' && Number(row?.credit_limit) === 0 && row?.trn === `100${uniq}000003`);
ok('duplicate reason in the audit log', Boolean(await one(`SELECT 1 FROM erp.audit_log WHERE action = 'bp_duplicate_confirmed' AND object_ref = $1 AND detail->>'reason' = $2`, [code, 'Shared switchboard number of the mall'])));
ok('partner page: change request waiting, contact and address shown', (await txt(pb.locator('[data-testid=bp-requests]'))).includes('Waiting for approval')
  && (await txt(pb.locator('[data-testid=bp-contacts]'))).includes('E2E Buyer') && (await txt(pb.locator('[data-testid=bp-addresses]'))).includes('Head office'));
await pb.screenshot({ path: `${OUT}/a8-bp-detail-pending-en-light-1440.png`, fullPage: true });

// edit: other fields apply at once
await pb.locator('#bp-edit').click();
await pb.locator('#bp-city').waitFor({ timeout: 15000 });
await pb.fill('#bp-city', 'Sharjah');
await pb.locator('#bp-save').click();
await pb.waitForURL(new RegExp(`/bp/ZZ99/${code}$`), { timeout: 15000 }).catch(() => {});
await settle(pb);
ok('edit saved (no approval for the city)', (await txt(pb.locator('[data-testid=bk-flash]'))).includes(`Changes to ${code} saved.`)
  && (await one('SELECT city FROM erp.business_partner WHERE company_code = $1 AND card_code = $2', ['ZZ99', code]))?.city === 'Sharjah');

// bank details by qa.bp wait for approval
await pb.locator('#bp-bank-add').click();
await pb.fill('#bpb-bank', 'E2E Sample Bank');
await pb.fill('#bpb-iban', 'AE12 34');
await pb.locator('#bpb-save').click();
ok('bank details: invalid IBAN refused with the server message', (await txt(pb.locator('[data-testid=bp-bank-error]'))).startsWith('The IBAN AE1234 is not valid.'));
await pb.fill('#bpb-iban', 'AE07 0331 2345 6789 0123 456');
await pb.fill('#bpb-reason', 'Letter from the customer');
await pb.locator('#bpb-save').click();
await pb.waitForTimeout(800);
ok('bank details sent for approval, not used yet', (await txt(pb.locator('[data-testid=bk-flash]'))).includes('sent for approval')
  && !(await one('SELECT 1 FROM erp.bp_bank_account WHERE company_code = $1 AND card_code = $2', ['ZZ99', code])));

// SAP stand-in partner explains why it is read-only
await pb.goto(`${BASE}/bp/ZZ99/C0001`); await settle(pb);
await pb.locator('#bp-edit').waitFor({ timeout: 10000 }).catch(() => {});
ok('SAP partner: Edit disabled with the cut-over explanation', await pb.locator('#bp-edit').isDisabled().catch(() => false)
  && (await txt(pb.locator('#bp-edit-reason'))) === 'This partner comes from SAP. Change it in SAP until ZZ99 goes live on Southfield.');
await pb.goto(`${BASE}/bp/ZZ99/C0001/edit`); await settle(pb);
ok('SAP partner: edit URL shows the same explanation', (await txt(pb.locator('[data-testid=md-readonly]'))).includes('This partner comes from SAP.'));
await C.close();

// ---------- 3. qa.finmgr approves both changes from the inbox ----------
{
  const C2 = await context(browser);
  const pf = await C2.newPage(); watch(pf, 'fmgr');
  await login(pf, 'fmgr'); await settle(pf);
  await pf.goto(`${BASE}/approvals`); await settle(pf);
  const inbox = await txt(pf.locator('[data-testid=inbox-table]'));
  ok('inbox lists the partner change with the rule', inbox.includes(code) && inbox.includes('Credit limit change') && inbox.includes('Bank detail change'), inbox.slice(0, 200));
  await pf.locator(`[data-testid=inbox-table] a:has-text("${code}")`).first().click();
  await pf.waitForURL(new RegExp(`/bp/ZZ99/${code}$`), { timeout: 15000 }).catch(() => {});
  await settle(pf);
  await pf.locator('[id^=bp-approve-]').first().waitFor({ timeout: 10000 }).catch(() => {});
  await pf.screenshot({ path: `${OUT}/a8-bp-approval-en-light-1440.png`, fullPage: true });
  const n = await pf.locator('[id^=bp-approve-]').count();
  for (let i = 0; i < n; i++) {
    await pf.locator('[id^=bp-approve-]').first().click();
    await pf.waitForTimeout(1200);
  }
  await settle(pf);
  ok('approval applies the credit limit', Number((await one('SELECT credit_limit FROM erp.business_partner WHERE company_code = $1 AND card_code = $2', ['ZZ99', code]))?.credit_limit) === 50000
    && (await txt(pf.locator('[data-testid=bp-credit-limit]'))).includes('50,000.00'));
  ok('approval writes the bank details and A5 change log', Boolean(await one(`SELECT 1 FROM erp.bp_bank_account a JOIN erp.bp_bank_change c ON c.bp_bank_id = a.bp_bank_id WHERE a.company_code = 'ZZ99' AND a.card_code = $1 AND a.iban = 'AE070331234567890123456'`, [code])));
  ok('history shows request and approval', (await txt(pf.locator('[data-testid=bp-history]'))).includes('approved the credit limit'));
  await C2.close();
}

// ---------- 4. Items: qa.stock creates and edits ----------
const itemCode = `E2E-${uniq}`;
{
  const C3 = await context(browser);
  const pi = await C3.newPage(); watch(pi, 'stock');
  await login(pi, 'stock'); await settle(pi);
  await pi.goto(`${BASE}/items/new`); await settle(pi);
  await pi.locator('#item-save').waitFor({ timeout: 15000 });
  await pi.locator('#item-save').click();
  await seen(pi.locator('[data-testid=md-error-summary]'));
  const s2 = await txt(pi.locator('[data-testid=md-error-summary]'));
  ok('item: empty form problems', s2.includes('Enter the item code.') && s2.includes('Enter the inventory unit. It is mandatory in company ZZ99.'), s2.slice(0, 160));
  await pi.fill('#it-item_code', itemCode);
  await pi.fill('#it-name', 'E2E stand mixer 5 L');
  await pi.locator('#it-group_code').selectOption('101');
  await pi.fill('#it-inventory_uom', 'pcs');
  await pi.fill('#it-barcode', '6299448074725');
  await pi.fill('#it-hs_code', '8509.40.00');
  await pi.fill('#it-moq', '200');
  await pi.locator('#it-sourcing_type').selectOption('ODM');
  await pi.locator('#it-tax_code').selectOption('SR');
  await pi.locator('#item-save').click();
  await seen(pi.locator('#it-barcode-err'));
  ok('barcode must be unique in the company', (await txt(pi.locator('#it-barcode-err'))).startsWith('Barcode 6299448074725 is already used by item SMP-1010'));
  await pi.fill('#it-barcode', `629${uniq}0001`);
  await pi.screenshot({ path: `${OUT}/a8-item-form-en-light-1440.png`, fullPage: true });
  await pi.locator('#item-save').click();
  await pi.waitForURL(new RegExp(`/items/ZZ99/${itemCode}$`), { timeout: 15000 }).catch(() => {});
  await settle(pi);
  ok('item created (flash, database)', (await txt(pi.locator('[data-testid=bk-flash]'))).includes(`Item ${itemCode} created.`)
    && (await one('SELECT source, inventory_uom FROM erp.item WHERE company_code = $1 AND item_code = $2', ['ZZ99', itemCode]))?.inventory_uom === 'PCS');
  await pi.locator('#item-edit').click();
  await pi.locator('#it-name').waitFor({ timeout: 15000 });
  await pi.fill('#it-moq', '300');
  await pi.locator('#item-save').click();
  await pi.waitForURL(new RegExp(`/items/ZZ99/${itemCode}$`), { timeout: 15000 }).catch(() => {});
  await settle(pi);
  ok('item edited; history lists the change', Number((await one('SELECT moq FROM erp.item WHERE company_code = $1 AND item_code = $2', ['ZZ99', itemCode]))?.moq) === 300
    && await seen(pi.locator('[data-testid=item-changes]', { hasText: 'changed the item' })));
  await pi.goto(`${BASE}/items/ZZ99/SMP-1010`); await settle(pi);
  await pi.locator('#item-edit').waitFor({ timeout: 10000 }).catch(() => {});
  ok('SAP item: Edit disabled with the explanation', await pi.locator('#item-edit').isDisabled().catch(() => false)
    && (await txt(pi.locator('#item-edit-reason'))) === 'This item comes from SAP. Change it in SAP until ZZ99 goes live on Southfield.');
  await C3.close();
}
{
  const C4 = await context(browser);
  const pr = await C4.newPage(); watch(pr, 'sread');
  await login(pr, 'sread'); await settle(pr);
  await pr.goto(`${BASE}/items`); await settle(pr);
  await pr.waitForTimeout(800);
  ok('read-only inventory user: "New item" disabled', await pr.locator('#item-new').isDisabled().catch(() => false));
  await C4.close();
}

// ---------- 5. Lists and module page (admin) ----------
{
  const C5 = await context(browser);
  const pa = await C5.newPage(); watch(pa, 'admin');
  await login(pa, 'admin'); await settle(pa);
  await pa.goto(`${BASE}/bp/trademarks`); await settle(pa);
  ok('Trademark Master: read-only list of migrated rows', (await txt(pa.locator('main table'))).includes('TM-SMP-01') && (await txt(pa.locator('[data-testid=tm-note]'))).includes('Read only'));
  await pa.goto(`${BASE}/bp/changes`); await settle(pa);
  ok('change list shows the approved requests', (await txt(pa.locator('main table'))).includes(code));
  await pa.goto(`${BASE}/m/bp?fn=1`); await settle(pa);
  ok('module page: Business Partner Master Data links New business partner and change list', await seen(pa.locator('main a[href="/bp/new"]'))
    && await seen(pa.locator('main a[href="/bp/changes"]')));
  await pa.goto(`${BASE}/m/bp?fn=0`); await settle(pa);
  ok('module page: Trademark Master opens the read-only list', await seen(pa.locator('main a[href="/bp/trademarks"]')));
  await pa.goto(`${BASE}/bp?f_source=erp`); await settle(pa);
  ok('BP list: source filter finds Southfield partners', (await txt(pa.locator('main table'))).includes(code));
  await C5.close();
}

// ---------- 6. Screenshots: 1440 / 390, light / dark, EN / AR ----------
const shots = [
  ['bp-new', '/bp/new'],
  ['bp-detail', `/bp/ZZ99/${code}`],
  ['bp-sap', '/bp/ZZ99/C0001'],
  ['item-new', '/items/new'],
  ['item-detail', `/items/ZZ99/${itemCode}`],
  ['trademarks', '/bp/trademarks'],
  ['changes', '/bp/changes'],
];
for (const [lang, theme, width] of [['en', 'light', 1440], ['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
  const ctx = await context(browser, { width, height: width < 640 ? 844 : 900, lang, theme });
  const page = await ctx.newPage(); watch(page, `${lang}-${theme}-${width}`);
  await login(page, 'admin'); await settle(page);
  let scrollOk = true;
  for (const [nm, p] of shots) {
    await page.goto(`${BASE}${p}`); await settle(page);
    await page.locator('h1').first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(600);
    if (width < 640 && !(await noHScroll(page))) { scrollOk = false; console.log(`  h-scroll: ${nm}`); }
    await page.screenshot({ path: `${OUT}/a8-${nm}-${lang}-${theme}-${width}.png`, fullPage: true });
  }
  if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, scrollOk);
  if (lang === 'ar') ok(`Arabic: page is RTL (${theme}, ${width})`, (await page.evaluate(() => document.documentElement.dir)) === 'rtl');
  await ctx.close();
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await db.end();
await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`\nA8 e2e: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

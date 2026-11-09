// A3 browser test: posting engine, against the local stack (Vite :5173 + gateway :54321 + PostgREST + Postgres, ZZ99).
// Usage: NODE_PATH=<dir with playwright> node scripts/local-stack/a3-e2e.mjs [outDir]
// qa.finance posts a balanced journal, reverses it, sends a 60,000 journal for approval; qa.finmgr approves it.
// Closed period refusal, G/L account determination edit, read-only owner, sales user blocked, 390 px, light/dark, EN/AR.
// Leaves the sample data as it found it apart from the posted test journals (posting periods reopened, Rounding cleared).
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import fs from 'node:fs';

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const API = process.env.API_URL ?? 'http://127.0.0.1:54321';
const OUT = process.argv[2] ?? 'a3-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const DATE = '2026-11-09';
const RUN = Date.now().toString(36);

const USERS = {
  admin: ['qa.admin@sample.test', 'local-only-1'],
  sales: ['qa.sales@sample.test', 'local-only-2'],
  fin: ['qa.finance@sample.test', 'local-only-4'],
  owner: ['qa.owner@sample.test', 'local-only-5'],
  fmgr: ['qa.finmgr@sample.test', 'local-only-8'],
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
async function fillLine(page, n, acct, { debit, credit, memo } = {}) {
  const line = page.locator('[data-testid=je-line]').nth(n);
  await pickCombo(page, line.locator('input[role=combobox]'), acct, `${acct} ·`);
  if (memo !== undefined) await line.locator('input[id$="-memo"]').fill(String(memo));
  if (debit !== undefined) await line.locator('input[id$="-debit"]').fill(String(debit));
  if (credit !== undefined) await line.locator('input[id$="-credit"]').fill(String(credit));
}
/** true when the locator shows up within 10 s (pages load their data after navigation). */
const has = (loc) => loc.first().waitFor({ timeout: 10000 }).then(() => true, () => false);
const lastId = (url) => Number(new URL(url).pathname.split('/').filter(Boolean).pop());

const browser = await chromium.launch();
const errors = [];
const watch = (page, tag) => page.on('pageerror', (e) => errors.push(`${tag}: ${e.message}`));

// ---------- API: the database enforces the rules ----------
{
  const sales = await token('sales');
  const r = await rpc(sales, 'journal_draft_save', { p_company: 'ZZ99', p_draft_id: null, p_header: { ref_date: DATE }, p_lines: [] });
  ok('API: sales user cannot save a journal', r.status === 403 && r.body?.message === 'Your position does not include Financials. Ask the system admin if you need it.', `${r.status} ${r.body?.message}`);
  const owner = await token('owner');
  const o = await rpc(owner, 'period_set_status', { p_company: 'ZZ99', p_period: '2026-11', p_status: 'closed' });
  ok('API: read-only owner cannot close a period', o.status === 403 && /read-only access to Financials/.test(o.body?.message), `${o.status} ${o.body?.message}`);
  const fin = await token('fin');
  const p = await rpc(fin, 'post_journal', { p_company: 'ZZ99', p_date: DATE, p_memo: 'x', p_lines: [], p_source_ref: {} });
  ok('API: post_journal is not callable from the browser', p.status === 401 || p.status === 403 || p.status === 404, String(p.status));
  const w = await fetch(`${API}/rest/v1/posting_period?company_code=eq.ZZ99`, { method: 'PATCH', headers: { apikey: 'local', authorization: `Bearer ${fin}`, 'content-type': 'application/json', 'content-profile': 'erp' }, body: JSON.stringify({ status: 'locked' }) });
  ok('API: direct PATCH on posting_period refused', w.status === 401 || w.status === 403, String(w.status));
  // make sure the period used below is open (a previous failed run may have left it closed)
  const per = await rpc(fin, 'period_set_status', { p_company: 'ZZ99', p_period: '2026-11', p_status: 'open' });
  ok('setup: 2026-11 open', per.status === 200 || /already open/.test(per.body?.message ?? ''), per.body?.message ?? '');
}

// ---------- 1. qa.finance: list → new journal, running difference, post ----------
const A = await context(browser);
const pa = await A.newPage(); watch(pa, 'fin');
await login(pa, 'fin'); await settle(pa);
await pa.goto(`${BASE}/financials/journals`); await settle(pa);
ok('journals list: "+ New journal entry" is a link for full Financials', (await pa.locator('a#new-journal').count()) === 1);
ok('journals list: "Drafts and approvals" link', (await pa.locator('a#je-drafts-link').count()) === 1);
await pa.click('a#new-journal');
await pa.waitForURL(/\/financials\/journals\/new$/); await settle(pa);
await pa.fill('#je-ref_date', DATE);
await pa.fill('#je-memo', `A3 e2e rent ${RUN}`);
await fillLine(pa, 0, '6200', { debit: '1000', memo: 'Warehouse rent' });
await fillLine(pa, 1, '1110', { credit: '900' });
await pa.waitForTimeout(300);
ok('running difference 100.00 while unbalanced', (await pa.locator('[data-testid=je-diff]').innerText()).includes('100.00'), await pa.locator('[data-testid=je-diff]').innerText());
ok('Post disabled until the difference is zero, with the reason', (await pa.locator('#je-post').isDisabled()) && (await pa.locator('text=Debits and credits must be equal. Difference 100.00 AED.').count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-form-unbalanced-en-light-1440.png`, fullPage: true });
await pa.locator('[data-testid=je-line]').nth(1).locator('input[id$="-credit"]').fill('1000');
await pa.locator('[data-testid=je-preview]', { hasText: 'Posts straight away' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('balanced: difference 0.00, Post enabled, "Posts straight away"', (await pa.locator('[data-testid=je-diff]').innerText()).includes('0.00') && !(await pa.locator('#je-post').isDisabled())
  && (await pa.locator('[data-testid=je-preview]', { hasText: 'Posts straight away' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-form-balanced-en-light-1440.png`, fullPage: true });
await pa.click('#je-post');
await pa.waitForURL(/\/financials\/journals\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const t1 = lastId(pa.url());
ok('posted: lands on the journal page with trans_id ≥ 900000000', t1 >= 900000000, String(t1));
ok('flash "Posted as journal …"', await has(pa.locator('[role=status]', { hasText: `Posted as journal ${t1}.` })));
ok('journal shows "Debit = credit" and source Super ERP', (await has(pa.locator('text=Debit = credit'))) && (await has(pa.locator('dd', { hasText: 'Super ERP' }))));
await pa.screenshot({ path: `${OUT}/a3-journal-posted-en-light-1440.png`, fullPage: true });

// ---------- 2. Reverse ----------
await pa.click('#je-reverse');
await pa.click('#je-reverse-confirm');
ok('reverse without a reason asks for one', (await pa.locator('[data-testid=je-reverse-error]', { hasText: 'Add a reason for the reversal.' }).count()) === 1);
await pa.fill('#je-reverse-reason', 'Posted to the wrong account');
await pa.screenshot({ path: `${OUT}/a3-reverse-dialog-en-light-1440.png`, fullPage: true });
await pa.click('#je-reverse-confirm');
await pa.waitForURL((u) => /\/financials\/journals\/ZZ99\/\d+$/.test(u.pathname) && lastId(u.href) !== t1, { timeout: 15000 }); await settle(pa);
const t2 = lastId(pa.url());
ok('reversal posted as a new journal', t2 > t1, String(t2));
ok('reversal page: flash and "Reversal of journal" link', (await has(pa.locator('[role=status]', { hasText: `Reversal posted as journal ${t2}.` })))
  && (await has(pa.locator(`a[href="/financials/journals/ZZ99/${t1}"]`))));
await has(pa.locator('text=Debit = credit'));
const revRows = await pa.locator('main table tbody tr').allInnerTexts();
ok('reversal mirrors the lines (1110 debit, 6200 credit)', revRows.some((r) => /1110/.test(r) && /1,000\.00/.test(r)) && revRows.some((r) => /6200/.test(r) && /1,000\.00/.test(r)), revRows.join(' | ').replace(/\s+/g, ' ').slice(0, 160));
ok('a reversal cannot be reversed (disabled with the reason)', (await pa.locator('#je-reverse').isDisabled()) && (await pa.locator('text=/is itself a reversal of journal/').count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-journal-reversal-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/financials/journals/ZZ99/${t1}`); await settle(pa);
ok('original: "Reversed by journal" link, Reverse disabled', (await pa.locator('#je-reversed-by').innerText().catch(() => '')) === String(t2) && (await pa.locator('#je-reverse').isDisabled()));

// ---------- 3. Journal above the limit → approval ----------
await pa.goto(`${BASE}/financials/journals/new`); await settle(pa);
await pa.fill('#je-ref_date', DATE);
await pa.fill('#je-memo', `A3 e2e accrual ${RUN}`);
await fillLine(pa, 0, '6100', { debit: '60000' });
await fillLine(pa, 1, '2200', { credit: '60000' });
await pa.locator('[data-testid=je-preview]', { hasText: 'Needs approval' }).waitFor({ timeout: 10000 }).catch(() => {});
const pv = await pa.locator('[data-testid=je-preview]').innerText().catch(() => '');
ok('preview: needs approval, names the finance manager', /Needs approval/.test(pv) && /QA · finance manager/.test(pv) && /above your journal limit of 50,000.00 AED/.test(pv), pv.replace(/\n/g, ' | '));
ok('button reads "Submit for approval"', (await pa.locator('#je-post').innerText()).includes('Submit for approval'));
await pa.click('#je-post');
ok('submit without a reason asks for one', await pa.locator('#je-reason-err', { hasText: 'Add a reason for the approver.' }).isVisible().catch(() => false));
await pa.fill('#je-reason', 'Year-end salary accrual');
await pa.screenshot({ path: `${OUT}/a3-form-needs-approval-en-light-1440.png`, fullPage: true });
await pa.click('#je-post');
await pa.waitForURL(/\/financials\/journals\/drafts\/ZZ99\/\d+$/, { timeout: 15000 }); await settle(pa);
const d2 = lastId(pa.url());
ok('draft page: "Waiting approval" and the flash', (await has(pa.locator('h1 .pill', { hasText: 'Waiting approval' })))
  && (await has(pa.locator('[role=status]', { hasText: 'Sent for approval to QA · finance manager' }))), `draft ${d2}`);
ok('requester sees "You can’t approve your own journal." and no approve button', (await has(pa.locator('text=You can\'t approve your own journal.'))) && (await pa.locator('#je-approve').count()) === 0);
await pa.screenshot({ path: `${OUT}/a3-draft-waiting-fin-en-light-1440.png`, fullPage: true });

// ---------- 4. qa.finmgr approves from the Approvals inbox ----------
const B = await context(browser);
const pb = await B.newPage(); watch(pb, 'fmgr');
await login(pb, 'fmgr'); await settle(pb);
await pb.goto(`${BASE}/approvals`); await settle(pb);
const link = pb.locator(`a[href="/financials/journals/drafts/ZZ99/${d2}"]`);
ok('finance manager: journal waiting in Approvals', (await link.count()) === 1);
await pb.screenshot({ path: `${OUT}/a3-approvals-waiting-fmgr-en-light-1440.png`, fullPage: true });
await link.click(); await settle(pb);
await pb.locator('[data-testid=je-approval-card]').waitFor({ timeout: 10000 }).catch(() => {});
ok('approval card with the reason', (await pb.locator('[data-testid=je-approval-card]', { hasText: 'Year-end salary accrual' }).count()) === 1);
await pb.screenshot({ path: `${OUT}/a3-draft-approval-card-fmgr-en-light-1440.png`, fullPage: true });
await pb.click('#je-approve');
await pb.locator('[role=status]', { hasText: 'Approved and posted as journal' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('approve → "Approved and posted as journal …", state Posted', (await pb.locator('[role=status]', { hasText: 'Approved and posted as journal' }).count()) === 1
  && (await pb.locator('h1 .pill', { hasText: 'Posted' }).count()) === 1);
ok('decided card + link to the posted journal', (await pb.locator('[data-testid=je-decided-card]').count()) === 1 && (await pb.locator('#je-open-posted').count()) === 1);
await pb.screenshot({ path: `${OUT}/a3-draft-approved-fmgr-en-light-1440.png`, fullPage: true });
await B.close();

// ---------- 5. Closed period refuses posting ----------
await pa.goto(`${BASE}/financials/periods`); await settle(pa);
ok('periods screen lists 2026 months', (await pa.locator('[data-testid=per-row]').count()) === 12);
await pa.click('#per-close-2026-11');
await pa.locator('[data-testid=fs-flash]', { hasText: 'Period 2026-11 is closed.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('finance closes 2026-11', (await pa.locator('[data-period="2026-11"] .pill', { hasText: 'Closed' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-periods-closed-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/financials/journals/new`); await settle(pa);
await pa.fill('#je-ref_date', DATE);
await fillLine(pa, 0, '6800', { debit: '25' });
await fillLine(pa, 1, '1110', { credit: '25' });
const periodMsg = 'Posting period 2026-11 is closed, so nothing can be posted on 09 Nov 2026. Choose a date in an open period, or ask Finance to reopen it.';
await pa.locator('#je-period-msg').waitFor({ timeout: 10000 }).catch(() => {});
ok('period problem shown next to the posting date', (await pa.locator('#je-period-msg').innerText().catch(() => '')) === periodMsg);
await pa.click('#je-post');
ok('Post in a closed period: the server message at the top', await has(pa.locator('[data-testid=je-error]', { hasText: periodMsg })), await pa.locator('[data-testid=je-error]').innerText().catch(() => ''));
await pa.screenshot({ path: `${OUT}/a3-form-closed-period-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/financials/periods`); await settle(pa);
await pa.click('#per-open-2026-11');
await pa.locator('[data-testid=fs-flash]', { hasText: 'Period 2026-11 is open.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('finance reopens 2026-11', (await pa.locator('[data-period="2026-11"] .pill', { hasText: 'Open' }).count()) === 1);
await pa.click('#per-lock-2026-12');
ok('lock asks for confirmation', await pa.locator('[role=dialog]', { hasText: 'Lock period 2026-12?' }).isVisible().catch(() => false));
await pa.click('#per-lock-confirm');
await pa.locator('[data-period="2026-12"] .pill', { hasText: 'Locked' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('2026-12 locked', (await pa.locator('[data-period="2026-12"] .pill', { hasText: 'Locked' }).count()) === 1);
await pa.click('#per-open-2026-12'); await settle(pa);
await pa.locator('[data-period="2026-12"] .pill', { hasText: 'Open' }).waitFor({ timeout: 10000 }).catch(() => {});

// ---------- 6. G/L Account Determination ----------
await pa.goto(`${BASE}/financials/gl-determination`); await settle(pa);
ok('G/L screen: 22 posting keys in 5 areas', (await pa.locator('[data-testid=gl-row]').count()) === 22);
ok('G/L screen: Revenue → 4100 for ZZ99', (await pa.locator('[data-testid=gl-row][data-key=revenue]').innerText()).includes('4100'));
ok('G/L screen: Rounding not set (warning)', (await pa.locator('[data-testid=gl-row][data-key=rounding] .pill', { hasText: 'Not set' }).count()) === 1);
await pa.click('#gl-edit-rounding');
await pickCombo(pa, pa.locator('#gl-rounding'), '6800', '6800 ·');
await pa.locator('[data-testid=fs-flash]', { hasText: 'Saved: Rounding → 6800.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('finance sets Rounding → 6800', (await pa.locator('[data-testid=gl-row][data-key=rounding]').innerText()).includes('6800'));
await pa.screenshot({ path: `${OUT}/a3-gl-determination-en-light-1440.png`, fullPage: true });
await pa.click('#gl-clear-rounding');
await pa.locator('[data-testid=fs-flash]', { hasText: 'Cleared: Rounding.' }).waitFor({ timeout: 10000 }).catch(() => {});
ok('finance clears Rounding again', (await pa.locator('[data-testid=gl-row][data-key=rounding] .pill', { hasText: 'Not set' }).count()) === 1);
await pa.goto(`${BASE}/preview/gldet?from=administration`); await settle(pa);
ok('old design preview /preview/gldet opens the working screen', new URL(pa.url()).pathname === '/financials/gl-determination');
await pa.goto(`${BASE}/m/financials`); await settle(pa);
await pa.locator('[role=listbox] [role=option]', { hasText: 'Financials Setup' }).click();
ok('Financials module: "Financials Setup" lists both screens as Live data',
  (await pa.locator('a[href="/financials/gl-determination"]', { hasText: 'Live data' }).count()) >= 1 && (await pa.locator('a[href="/financials/periods"]', { hasText: 'Live data' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-module-financials-setup-en-light-1440.png`, fullPage: true });
await pa.goto(`${BASE}/financials/journals/drafts`); await settle(pa);
ok('drafts list shows the approved draft as Posted', (await pa.locator('main table tbody tr', { hasText: `A3 e2e accrual ${RUN}` }).locator('.pill', { hasText: 'Posted' }).count()) === 1);
await pa.screenshot({ path: `${OUT}/a3-drafts-list-en-light-1440.png`, fullPage: true });
await A.close();

// ---------- 7. Read-only owner and sales user ----------
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'owner');
  await login(page, 'owner'); await settle(page);
  await page.goto(`${BASE}/financials/journals`); await settle(page);
  ok('owner: "New journal entry" disabled with "Read-only access to Financials"', (await page.locator('#new-financials').isDisabled()) && (await page.locator('text=Read-only access to Financials').count()) > 0);
  await page.goto(`${BASE}/financials/journals/ZZ99/${t1}`); await settle(page);
  ok('owner: Reverse disabled', await page.locator('#je-reverse').isDisabled().catch(() => false));
  await page.goto(`${BASE}/financials/periods`); await settle(page);
  ok('owner: periods visible, no change buttons', (await page.locator('[data-testid=per-row]').count()) > 0 && (await page.locator('[id^=per-close-]').count()) === 0);
  await page.goto(`${BASE}/financials/gl-determination`); await settle(page);
  ok('owner: G/L visible, no change buttons', (await page.locator('[data-testid=gl-row]').count()) === 22 && (await page.locator('[id^=gl-edit-]').count()) === 0);
  await ctx.close();
}
{
  const ctx = await context(browser);
  const page = await ctx.newPage(); watch(page, 'sales');
  await login(page, 'sales'); await settle(page);
  for (const path of ['/financials/journals/new', '/financials/gl-determination', '/financials/periods']) {
    await page.goto(`${BASE}${path}`); await settle(page);
    ok(`sales user: ${path} shows the no-access screen`, (await page.locator('[role=alert]', { hasText: 'Your position does not include Financials' }).count()) === 1);
  }
  await page.screenshot({ path: `${OUT}/a3-sales-noaccess-en-light-1440.png`, fullPage: true });
  await ctx.close();
}

// ---------- 8. Light/dark, English/Arabic, 1440/390 ----------
for (const width of [1440, 390]) {
  for (const [lang, theme] of [['en', 'light'], ['en', 'dark'], ['ar', 'light'], ['ar', 'dark']]) {
    const tag = `${lang}-${theme}-${width}`;
    const ctx = await context(browser, { width, height: width === 390 ? 844 : 900, lang, theme });
    const page = await ctx.newPage(); watch(page, `fin-${tag}`);
    await login(page, 'fin'); await settle(page);
    await page.goto(`${BASE}/financials/journals/new`); await settle(page);
    await page.fill('#je-ref_date', DATE);
    await fillLine(page, 0, '6200', { debit: '1250.50', memo: lang === 'ar' ? 'إيجار المستودع' : 'Warehouse rent' });
    await fillLine(page, 1, '1110', { credit: '1000' });
    await page.waitForTimeout(500);
    if (width === 390) ok(`form: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
    if (lang === 'ar' && width === 1440 && theme === 'light') ok('Arabic form: RTL and Arabic labels', (await page.evaluate(() => document.documentElement.dir)) === 'rtl' && (await page.locator('text=قيد يومية جديد').count()) > 0);
    await page.screenshot({ path: `${OUT}/a3-form-${tag}.png`, fullPage: true });
    await page.goto(`${BASE}/financials/journals/ZZ99/${t1}`); await settle(page);
    await page.locator('#je-reversed-by').waitFor({ timeout: 10000 }).catch(() => {});
    if (width === 390) ok(`journal page: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
    await page.screenshot({ path: `${OUT}/a3-journal-${tag}.png`, fullPage: true });
    await page.goto(`${BASE}/financials/periods`); await settle(page);
    if (width === 390) ok(`periods: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
    await page.screenshot({ path: `${OUT}/a3-periods-${tag}.png`, fullPage: true });
    await page.goto(`${BASE}/financials/gl-determination`); await settle(page);
    if (width === 390) ok(`G/L: no horizontal scroll at 390 px (${lang}, ${theme})`, await noHScroll(page));
    await page.screenshot({ path: `${OUT}/a3-gl-${tag}.png`, fullPage: true });
    await ctx.close();
  }
}

// Approver at phone width: approval card fits.
{
  const fin = await token('fin');
  const s = await rpc(fin, 'journal_draft_save', { p_company: 'ZZ99', p_draft_id: null, p_header: { ref_date: DATE, memo: `A3 e2e phone ${RUN}` },
    p_lines: [{ acct_code: '6400', debit: 75000 }, { acct_code: '1110', credit: 75000 }] });
  await rpc(fin, 'journal_submit', { p_company: 'ZZ99', p_draft_id: s.body.draft_id, p_reason: 'Campaign prepayment' });
  for (const [lang, theme] of [['en', 'light'], ['ar', 'dark']]) {
    const ctx = await context(browser, { width: 390, height: 844, lang, theme });
    const page = await ctx.newPage(); watch(page, `fmgr-390-${lang}`);
    await login(page, 'fmgr'); await settle(page);
    await page.goto(`${BASE}/financials/journals/drafts/ZZ99/${s.body.draft_id}`); await settle(page);
    await page.locator('[data-testid=je-approval-card]').waitFor({ timeout: 10000 }).catch(() => {});
    ok(`approval card at 390 px (${lang}, ${theme})`, (await page.locator('[data-testid=je-approval-card]').isVisible().catch(() => false)) && (await noHScroll(page)));
    await page.screenshot({ path: `${OUT}/a3-draft-approval-card-fmgr-${lang}-${theme}-390.png`, fullPage: true });
    await ctx.close();
  }
  const fmgr = await token('fmgr');
  const rej = await rpc(fmgr, 'journal_decide', { p_company: 'ZZ99', p_draft_id: s.body.draft_id, p_decision: 'rejected', p_note: 'Test run: not needed' });
  ok('cleanup: phone-test journal rejected (not posted)', rej.body?.state === 'rejected', JSON.stringify(rej.body).slice(0, 80));
}

ok('no page errors', errors.length === 0, errors.slice(0, 3).join(' | '));
await browser.close();
fs.writeFileSync(`${OUT}/a3-results.json`, JSON.stringify(results, null, 1));
const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

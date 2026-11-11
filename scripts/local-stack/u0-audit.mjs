// U0 · Step 0 audit: open every route from A1–B6 (+ S1) at 1440 and 390 px, light and dark, EN and AR, as QA Admin, and list
// every place that does not match the U0 brief. LOCAL STACK ONLY (Vite :5173 + gateway :54321, sample company ZZ99).
//   node scripts/local-stack/u0-audit.mjs <outDir> [--shots all|key|none] [--variants 1440-light-en,390-light-en,...] [--only home,users,...]
// Checks per route and variant:
//   hscroll   page wider than the viewport (phones: no horizontal page scroll)
//   brand     the old product name "Super ERP" in the visible text
//   rawkey    an untranslated i18n key (e.g. "sana.q.stock") in the visible text
//   title     the page title (h1 in main) is not in the display font (Outfit)
//   shell     the sidebar is not navy / the active item has no teal marker (desktop) — once per variant
//   sana      no way to open Sana on the screen (top bar button on desktop, floating button on phones)
//   errors    uncaught page errors
//   dir       Arabic without dir=rtl
// Writes audit.json and audit.md (the mismatch list) into outDir, screenshots as <variant>/<name>.png.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import postgres from 'postgres';
const { chromium } = createRequire(import.meta.url)('playwright');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const OUT = process.argv[2] ?? 'u0-audit';
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const SHOTS = arg('--shots', 'key');
const VARIANTS = arg('--variants', '1440-light-en,1440-dark-en,1440-light-ar,1440-dark-ar,390-light-en,390-dark-en,390-light-ar,390-dark-ar').split(',');
fs.mkdirSync(OUT, { recursive: true });
const sql = postgres({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local', onnotice: () => {} });
const one = async (q) => (await sql.unsafe(q))[0] ?? {};

// ---------- sample records for parameterised routes ----------
const so = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=17 AND source='sample' ORDER BY doc_entry LIMIT 1`);
const soE = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=17 AND source='erp' ORDER BY doc_entry DESC LIMIT 1`);
const qt = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=23 ORDER BY doc_entry LIMIT 1`);
const inv = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=13 ORDER BY doc_entry LIMIT 1`);
const dn = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=15 ORDER BY doc_entry LIMIT 1`);
const po = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=22 ORDER BY doc_entry LIMIT 1`);
const api = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=18 ORDER BY doc_entry LIMIT 1`);
const gr = await one(`SELECT doc_entry FROM erp.document WHERE company_code='ZZ99' AND obj_type=59 ORDER BY doc_entry DESC LIMIT 1`);
const je = await one(`SELECT trans_id FROM erp.journal_entry WHERE company_code='ZZ99' ORDER BY trans_id LIMIT 1`);
const pay = await one(`SELECT doc_entry FROM erp.payment WHERE company_code='ZZ99' AND direction='I' ORDER BY doc_entry LIMIT 1`);
const emp = await one(`SELECT emp_id FROM erp.employee WHERE company_code='ZZ99' ORDER BY emp_id LIMIT 1`);
const leave = await one(`SELECT request_id FROM erp.leave_request WHERE company_code='ZZ99' ORDER BY request_id DESC LIMIT 1`).catch(() => ({}));
const pr = await one(`SELECT run_id FROM erp.payroll_run WHERE company_code='ZZ99' ORDER BY run_id DESC LIMIT 1`).catch(() => ({}));
const lc = await one(`SELECT lc_entry FROM erp.landed_cost WHERE company_code='ZZ99' ORDER BY lc_entry DESC LIMIT 1`).catch(() => ({}));
const cnt = await one(`SELECT count_id FROM erp.inv_count WHERE company_code='ZZ99' ORDER BY count_id DESC LIMIT 1`).catch(() => ({}));
const lot = await one(`SELECT lot_id FROM erp.stock_lot WHERE company_code='ZZ99' ORDER BY lot_id DESC LIMIT 1`).catch(() => ({}));
const prd = await one(`SELECT order_id FROM erp.prod_order WHERE company_code='ZZ99' ORDER BY order_id DESC LIMIT 1`).catch(() => ({}));
const svc = await one(`SELECT call_id FROM erp.service_call WHERE company_code='ZZ99' ORDER BY call_id DESC LIMIT 1`).catch(() => ({}));
const eq = await one(`SELECT card_id FROM erp.equipment_card WHERE company_code='ZZ99' ORDER BY card_id LIMIT 1`).catch(() => ({}));
const ct = await one(`SELECT contract_id FROM erp.service_contract WHERE company_code='ZZ99' ORDER BY contract_id DESC LIMIT 1`).catch(() => ({}));
const tpl = await one(`SELECT template_id FROM erp.apr_template WHERE company_code='ZZ99' ORDER BY template_id LIMIT 1`).catch(() => ({}));
const stmt = await one(`SELECT statement_id FROM erp.bank_statement WHERE company_code='ZZ99' ORDER BY statement_id DESC LIMIT 1`).catch(() => ({}));
const fxr = await one(`SELECT reval_id FROM erp.fx_revaluation WHERE company_code='ZZ99' ORDER BY reval_id DESC LIMIT 1`).catch(() => ({}));
const cvd = await one(`SELECT run_id FROM erp.conv_diff_run WHERE company_code='ZZ99' ORDER BY run_id DESC LIMIT 1`).catch(() => ({}));
const jdr = await one(`SELECT draft_id FROM erp.journal_draft WHERE company_code='ZZ99' ORDER BY draft_id DESC LIMIT 1`).catch(() => ({}));
const pdr = await one(`SELECT draft_id FROM erp.payment_draft WHERE company_code='ZZ99' ORDER BY draft_id DESC LIMIT 1`).catch(() => ({}));
await sql.end();

// [name, path, key screen?]
const ROUTES = [
  ['home', '/', 1], ['portal', '/portal', 1], ['search', '/search?q=SMP', 0], ['control', '/control', 1], ['approvals', '/approvals', 1],
  ...['admin', 'finance', 'sales', 'purchasing', 'bp', 'banking', 'inventory', 'production', 'service', 'hr', 'reports'].map((m) => [`m-${m}`, `/m/${m}`, m === 'sales' ? 1 : 0]),
  ['preview-tax', '/preview/tax', 0],
  // Business partners / items
  ['bp-list', '/bp', 1], ['bp-detail', '/bp/ZZ99/C0001', 1], ['bp-new', '/bp/new', 0], ['bp-changes', '/bp/changes', 0], ['bp-trademarks', '/bp/trademarks', 0],
  ['items', '/items', 1], ['item-detail', '/items/ZZ99/SMP-1010', 1], ['item-new', '/items/new', 0],
  // Sales
  ['so-list', '/docs/sales_order', 1], ['so-detail', `/docs/sales_order/ZZ99/${so.doc_entry}`, 1], ['so-erp', soE.doc_entry ? `/docs/sales_order/ZZ99/${soE.doc_entry}` : null, 1], ['so-new', '/docs/sales_order/new', 1],
  ['qt-detail', `/docs/sales_quotation/ZZ99/${qt.doc_entry}`, 0], ['qt-new', '/docs/sales_quotation/new', 0], ['dn-detail', `/docs/delivery/ZZ99/${dn.doc_entry}`, 0], ['dn-new', '/docs/delivery/new', 0],
  ['inv-list', '/docs/ar_invoice', 0], ['inv-detail', `/docs/ar_invoice/ZZ99/${inv.doc_entry}`, 1], ['inv-new', '/docs/ar_invoice/new', 0], ['cm-new', '/docs/ar_credit_note/new', 0],
  ['atp', '/sales/atp', 0], ['atp-rules', '/sales/atp-rules', 0],
  // Purchasing
  ['po-list', '/docs/purchase_order', 0], ['po-detail', `/docs/purchase_order/ZZ99/${po.doc_entry}`, 1], ['pr-list', '/docs/purchase_request', 0], ['grpo-new', '/purchasing/grpo/new', 0],
  ['apinv-new', '/purchasing/ap-invoice/new', 0], ['apinv-detail', `/docs/ap_invoice/ZZ99/${api.doc_entry}`, 0], ['lc-list', '/purchasing/landed-costs', 0], ['lc-new', '/purchasing/landed-costs/new', 0],
  ['lc-detail', lc.lc_entry ? `/purchasing/landed-costs/ZZ99/${lc.lc_entry}` : null, 0], ['pu-setup', '/purchasing/setup', 0], ['lc-types', '/purchasing/landed-cost-types', 0],
  // Inventory
  ['stock', '/inventory/stock', 1], ['prices', '/inventory/prices', 0], ['special-prices', '/inventory/special-prices', 0], ['discounts', '/inventory/discounts', 0],
  ['gr-new', '/inventory/goods-receipt/new', 0], ['gi-new', '/inventory/goods-issue/new', 0], ['trq-new', '/inventory/transfer-request/new', 0], ['tr-new', '/inventory/transfer/new', 0],
  ['gr-detail', gr.doc_entry ? `/docs/goods_receipt/ZZ99/${gr.doc_entry}` : null, 0], ['counts', '/inventory/counts', 0], ['count-new', '/inventory/counts/new', 0],
  ['count-detail', cnt.count_id ? `/inventory/counts/ZZ99/${cnt.count_id}` : null, 0], ['batches', '/inventory/batches', 0], ['serials', '/inventory/serials', 0],
  ['lot', lot.lot_id ? `/inventory/lots/ZZ99/${lot.lot_id}` : null, 0], ['inv-setup', '/inventory/setup', 0], ['warehouses', '/inventory/warehouses', 0], ['warehouse', '/inventory/warehouses/ZZ99/WH01', 0],
  ['item-groups', '/inventory/item-groups', 0], ['item-group', '/inventory/item-groups/ZZ99/101', 0], ['reasons', '/inventory/reasons', 0],
  // Financials
  ['accounts', '/financials/accounts', 0], ['journals', '/financials/journals', 0], ['je-new', '/financials/journals/new', 0], ['je-drafts', '/financials/journals/drafts', 0],
  ['je-draft', jdr.draft_id ? `/financials/journals/drafts/ZZ99/${jdr.draft_id}` : null, 0], ['je-detail', `/financials/journals/ZZ99/${je.trans_id}`, 1], ['gl-determination', '/financials/gl-determination', 0],
  ['fx-reval', '/financials/fx-revaluation', 0], ['fx-reval-detail', fxr.reval_id ? `/financials/fx-revaluation/ZZ99/${fxr.reval_id}` : null, 0],
  ['conv-diff', '/financials/conversion-differences', 0], ['conv-diff-detail', cvd.run_id ? `/financials/conversion-differences/ZZ99/${cvd.run_id}` : null, 0], ['periods', '/financials/periods', 0],
  // Banking
  ['pay-in', '/banking/payments/in', 0], ['pay-in-new', '/banking/payments/in/new', 0], ['pay-detail', pay.doc_entry ? `/banking/payments/in/ZZ99/${pay.doc_entry}` : null, 0],
  ['pay-drafts', '/banking/payment-drafts', 0], ['pay-draft', pdr.draft_id ? `/banking/payment-drafts/ZZ99/${pdr.draft_id}` : null, 0], ['deposits', '/banking/deposits', 0], ['deposit-new', '/banking/deposits/new', 0],
  ['statements', '/banking/statements', 0], ['statement', stmt.statement_id ? `/banking/statements/ZZ99/${stmt.statement_id}` : null, 0], ['cash', '/banking/cash-position', 1],
  ['bp-bank', '/banking/bp-bank-accounts', 0], ['bk-setup', '/banking/setup', 0],
  // HR
  ['employees', '/hr/employees', 0], ['employee', `/hr/employees/ZZ99/${emp.emp_id}`, 1], ['employee-new', '/hr/employees/new', 0], ['leave', '/hr/leave', 0],
  ['leave-detail', leave.request_id ? `/hr/leave/ZZ99/${leave.request_id}` : null, 0], ['attendance', '/hr/attendance', 0], ['expiry', '/hr/expiry', 0], ['payroll', '/hr/payroll', 0],
  ['payroll-run', pr.run_id ? `/hr/payroll/ZZ99/${pr.run_id}` : null, 0], ['hr-setup', '/hr/setup', 0],
  // Administration
  ['users', '/admin/users', 1], ['invite', '/admin/users/invite', 0], ['authorizations', '/admin/authorizations', 0], ['approval-rules', '/admin/approval-rules', 0],
  ['apr-stages', '/admin/approvals/stages', 0], ['apr-templates', '/admin/approvals/templates', 0], ['apr-template', tpl.template_id ? `/admin/approvals/templates/${tpl.template_id}` : null, 0],
  ['apr-report', '/admin/approvals/report', 0], ['apr-substitutes', '/admin/approvals/substitutes', 0], ['my-substitute', '/approvals/substitute', 0],
  ['numbering', '/admin/numbering', 0], ['companies', '/admin/companies', 0], ['company-new', '/admin/companies/new', 0], ['company-zz99', '/admin/companies/ZZ99', 0],
  ['company-details', '/admin/company', 0], ['rates', '/admin/exchange-rates', 0], ['ai-assistant', '/admin/ai-assistant', 1], ['go-live', '/admin/go-live', 0],
  ['go-live-zz99', '/admin/go-live/ZZ99', 0], ['health', '/admin/health', 0],
  // Reports
  ['reports', '/reports', 0], ['rpt-tb', '/reports/trial-balance', 0], ['rpt-aging', '/reports/ar-aging', 1],
  // Production / Service
  ['boms', '/production/boms', 0], ['bom', '/production/boms/ZZ99/SMP-PRD-100', 0], ['prod-orders', '/production/orders', 0], ['prod-new', '/production/orders/new', 0],
  ['prod-order', prd.order_id ? `/production/orders/ZZ99/${prd.order_id}` : null, 0], ['moulds', '/production/moulds', 0], ['mould', '/production/moulds/ZZ99/MLD-KET-2', 0],
  ['resources', '/production/resources', 0], ['prod-setup', '/production/setup', 0],
  ['svc-calls', '/service/calls', 0], ['svc-call', svc.call_id ? `/service/calls/ZZ99/${svc.call_id}` : null, 0], ['svc-new', '/service/calls/new', 0], ['equipment', '/service/equipment', 0],
  ['equipment-card', eq.card_id ? `/service/equipment/ZZ99/${eq.card_id}` : null, 0], ['contracts', '/service/contracts', 0], ['contract', ct.contract_id ? `/service/contracts/ZZ99/${ct.contract_id}` : null, 0], ['svc-setup', '/service/setup', 0],
  // Back office (migration console)
  ['backoffice', '/backoffice', 0], ['migration', '/backoffice/migration', 0], ['mig-upload', '/backoffice/migration/upload', 0], ['mig-fields', '/backoffice/migration/fields?company=ZZ99', 0],
].filter((r) => r[1] && (!arg('--only', '') || arg('--only', '').split(',').includes(r[0])));

const browser = await chromium.launch();
const findings = [];
const add = (variant, name, route, check, detail) => findings.push({ variant, name, route, check, detail });

for (const v of VARIANTS) {
  const [w, theme, lang] = v.split('-');
  const width = Number(w);
  const ctx = await browser.newContext({ viewport: { width, height: width < 640 ? 844 : 900 }, deviceScaleFactor: 1, ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); }, [lang, theme]);
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', (e) => errs.push(e.message));
  await page.goto(`${BASE}/login`);
  await page.fill('#email', 'qa.admin@sample.test'); await page.fill('#password', 'local-only-1');
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
  fs.mkdirSync(path.join(OUT, v), { recursive: true });
  let shellChecked = false;
  for (const [name, route, key] of ROUTES) {
    errs.length = 0;
    await page.goto(`${BASE}${route}`).catch(() => {});
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.locator('main h1').first().waitFor({ timeout: 8000 }).catch(() => {});
    await page.waitForTimeout(250);
    const m = await page.evaluate(() => {
      const de = document.documentElement;
      const body = document.body.innerText;
      const h1 = document.querySelector('main h1');
      const raw = (body.match(/\b(?:sana|erp|adm|so|sc|pu|bk|inv|md|hr|rpt|apr|stp|cur|fxr|cvd|gl|je|fs|nav|top|app|login|errors)\.[a-zA-Z]+(?:\.[a-zA-Z0-9_]+)+\b/g) || []).filter((x) => !/\.(sql|json|csv|ts|tsx|png|svg|test)$/.test(x));
      return {
        hscroll: de.scrollWidth > de.clientWidth + 1 ? de.scrollWidth - de.clientWidth : 0,
        superErp: /Super ERP/.test(body),
        raw: [...new Set(raw)].slice(0, 5),
        h1Font: h1 ? getComputedStyle(h1).fontFamily : null,
        dir: de.dir,
        sanaTop: Boolean(document.querySelector('#top-ask-sana')) && getComputedStyle(document.querySelector('#top-ask-sana')).display !== 'none',
        sanaFab: Boolean(document.querySelector('[data-testid=sana-fab]')) && getComputedStyle(document.querySelector('[data-testid=sana-fab]')).display !== 'none',
        side: (() => { const a = document.querySelector('aside nav'); const s = a?.closest('aside'); return s ? getComputedStyle(s).backgroundColor : null; })(),
        marker: (() => { const act = document.querySelector('aside nav a[aria-current=page]'); return act ? getComputedStyle(act, '::before').backgroundColor : null; })(),
      };
    });
    if (m.hscroll) add(v, name, route, 'hscroll', `${m.hscroll}px wider than the viewport`);
    if (m.superErp) add(v, name, route, 'brand', '"Super ERP" in the visible text');
    if (m.raw.length) add(v, name, route, 'rawkey', m.raw.join(', '));
    if (m.h1Font && !/Outfit/.test(m.h1Font)) add(v, name, route, 'title', `h1 font: ${m.h1Font.split(',')[0]}`);
    if (!m.h1Font) add(v, name, route, 'title', 'no page title (h1) in main');
    if (lang === 'ar' && m.dir !== 'rtl') add(v, name, route, 'dir', `dir=${m.dir}`);
    if (!(width < 640 ? m.sanaFab : m.sanaTop)) add(v, name, route, 'sana', width < 640 ? 'no floating Sana button' : 'no Ask Sana in the top bar');
    if (errs.length) add(v, name, route, 'errors', errs.slice(0, 2).join(' | ').slice(0, 200));
    if (!shellChecked && width >= 1024 && name === 'home') {
      shellChecked = true;
      const navy = theme === 'light' ? 'rgb(1, 28, 69)' : 'rgb(4, 12, 27)';
      if (m.side !== navy) add(v, 'shell', '/', 'shell', `sidebar ${m.side}, expected ${navy}`);
      if (!m.marker || !/rgb\(8, 187, 169\)/.test(m.marker)) add(v, 'shell', '/', 'shell', `active marker ${m.marker}`);
    }
    if (SHOTS === 'all' || (SHOTS === 'key' && key)) await page.screenshot({ path: path.join(OUT, v, `${name}.png`), fullPage: false });
  }
  await ctx.close();
  console.log(`${v}: ${ROUTES.length} routes, ${findings.filter((f) => f.variant === v).length} findings`);
}
await browser.close();

fs.writeFileSync(path.join(OUT, 'audit.json'), JSON.stringify({ routes: ROUTES.length, variants: VARIANTS, findings }, null, 1));
const byCheck = {};
for (const f of findings) (byCheck[f.check] ??= []).push(f);
const md = [`# U0 audit · ${ROUTES.length} routes × ${VARIANTS.length} variants · ${findings.length} findings`, ''];
for (const [c, list] of Object.entries(byCheck)) {
  md.push(`## ${c} (${list.length})`);
  const grouped = {};
  for (const f of list) (grouped[`${f.name} ${f.route}`] ??= []).push(`${f.variant}: ${f.detail}`);
  for (const [k, x] of Object.entries(grouped)) md.push(`- **${k}** — ${x.slice(0, 3).join('; ')}${x.length > 3 ? ` (+${x.length - 3} more)` : ''}`);
  md.push('');
}
fs.writeFileSync(path.join(OUT, 'audit.md'), md.join('\n'));
console.log(`TOTAL ${ROUTES.length} routes × ${VARIANTS.length} variants: ${findings.length} findings`);

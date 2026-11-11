// U0: refresh design/reference with the current Southfield screens (local stack). Login screens are taken here;
// the app screens are copied from the u0-audit and s1-e2e screenshots.
//   node scripts/local-stack/u0-reference.mjs <auditDir> <s1ShotsDir>
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { chromium } = createRequire(import.meta.url)('playwright');
const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const [AUDIT, S1] = process.argv.slice(2);
const REF = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../design/reference');

const browser = await chromium.launch();
for (const [file, width, lang, theme, wrong] of [['00-login-light.png', 1440, 'en', 'light'], ['00-login-dark.png', 1440, 'en', 'dark'],
  ['00-login-arabic.png', 1440, 'ar', 'light'], ['00-login-390.png', 390, 'en', 'light'], ['00-login-error.png', 1440, 'en', 'light', true]]) {
  const ctx = await browser.newContext({ viewport: { width, height: width < 640 ? 844 : 900 }, deviceScaleFactor: 1 });
  await ctx.addInitScript(([l, t]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); }, [lang, theme]);
  const p = await ctx.newPage();
  await p.goto(`${BASE}/login`); await p.waitForLoadState('networkidle');
  if (wrong) { await p.fill('#email', 'qa.admin@sample.test'); await p.fill('#password', 'wrong'); await p.click('button[type=submit]'); await p.waitForTimeout(1500); }
  await p.screenshot({ path: path.join(REF, file) });
  await ctx.close();
}
await browser.close();
const copy = (from, to) => { if (fs.existsSync(from)) fs.copyFileSync(from, path.join(REF, to)); else console.log('missing', from); };
copy(`${S1}/s1-home-hero-en-light-1440.png`, '00-home-sana.png');
copy(`${S1}/s1-home-hero-en-light-390.png`, '00-home-sana-390.png');
copy(`${S1}/s1-panel-answer-en-light-1440.png`, '00-sana-panel-sales.png');
copy(`${S1}/s1-panel-answer-ar-light-1440.png`, '00-sana-panel-arabic.png');
copy(`${S1}/s1-panel-empty-en-light-390.png`, '00-sana-panel-390.png');
copy(`${S1}/s1-panel-refusal-en-light-1440.png`, '00-sana-refusal.png');
copy(`${S1}/s1-panel-history-en-light-1440.png`, '00-sana-history.png');
copy(`${S1}/s1-panel-voice-en-light-1440.png`, '00-sana-voice.png');
copy(`${S1}/s1-admin-en-light-1440.png`, '40-admin-ai-assistant.png');
copy(`${AUDIT}/1440-light-en/home.png`, '01-home-light-1440.png');
copy(`${AUDIT}/1440-light-en/m-sales.png`, '02-module-sales.png');
copy(`${AUDIT}/1440-light-en/so-list.png`, '04-sales-orders.png');
copy(`${AUDIT}/1440-light-en/so-detail.png`, '05-sales-order-detail.png');
copy(`${AUDIT}/1440-light-en/bp-detail.png`, '06-bp-detail.png');
copy(`${AUDIT}/1440-light-en/control.png`, '14-control-tower.png');
copy(`${AUDIT}/1440-light-en/item-detail.png`, '15-item-detail.png');
copy(`${AUDIT}/1440-dark-en/so-list.png`, '19-sales-orders-dark.png');
copy(`${AUDIT}/1440-light-ar/stock.png`, '21-inventory-ar-rtl.png');
copy(`${AUDIT}/390-light-en/home.png`, '30-home-390.png');
copy(`${AUDIT}/390-light-en/inv-detail.png`, '32-invoices-390.png');
console.log('design/reference refreshed');

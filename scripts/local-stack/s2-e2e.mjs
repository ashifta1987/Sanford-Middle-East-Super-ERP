// S2 browser test: Sana on Gemini — text mode through the provider adapters (LOCAL-ONLY provider mock, NOT AI), the admin
// screen (read-only provider card from the admin-only config action, no key field anywhere, voice mode per company), voice
// mode "browser" (S1 Web Speech path unchanged) and voice mode "provider" (MediaRecorder → sana-voice → Gemini STT; answers
// read aloud from the Gemini TTS WAV — including Malayalam on a device without a Malayalam voice), fallbacks, and screenshots
// at 1440 / 390 px, light / dark, EN / AR.
// LOCAL STACK ONLY (Vite :5173 + gateway :54321 + PostgREST + Postgres, sample company ZZ99).
//   NODE_PATH=<localstack>/node_modules node scripts/local-stack/s2-e2e.mjs <outDir>
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const GW = process.env.GATEWAY_URL ?? 'http://127.0.0.1:54321';
if (!/^http:\/\/(127\.0\.0\.1|localhost)/.test(BASE) || !/^http:\/\/(127\.0\.0\.1|localhost)/.test(GW)) { console.error('local stack only'); process.exit(2); }
const OUT = process.argv[2] ?? 's2-shots';
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail && !pass ? ' — ' + String(detail).slice(0, 240) : ''}`); };
const settle = (page) => page.waitForLoadState('networkidle').catch(() => {});
const seen = (loc, timeout = 10000) => loc.first().waitFor({ timeout }).then(() => true).catch(() => false);
const txt = async (loc) => ((await loc.first().innerText().catch(() => '')) || '').trim();
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
const SALES = '00000000-0000-4000-8000-000000000002';
const setProvider = async (provider) => (await fetch(`${GW}/local/sana-provider`, { method: 'POST', body: JSON.stringify({ provider }) })).json();
const voiceMode = (m) => db.query(`INSERT INTO erp.sana_settings (company_code, voice_mode) VALUES ('ZZ99', $1) ON CONFLICT (company_code) DO UPDATE SET voice_mode = EXCLUDED.voice_mode`, [m]);

await db.query(`DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.sana_usage WHERE company_code = 'ZZ99'`);
await db.query(`DELETE FROM erp.sana_conversation WHERE user_id IN ($1, '00000000-0000-4000-8000-000000000004')`, [SALES]);

// Browser speech stand-in (as in s1-e2e): recognition "hears" window.__said; the device has English and Arabic voices only.
// Audio playback is recorded (headless Chromium has no speakers): window.__played gets every <audio> source that played.
const stubs = () => {
  class FakeRec {
    constructor() { this.lang = ''; this.onresult = null; this.onerror = null; this.onend = null; }
    start() { window.__recLang = this.lang; setTimeout(() => { this.onresult?.({ resultIndex: 0, results: [{ isFinal: true, 0: { transcript: window.__said } }] }); this.onend?.(); }, 900); }
    stop() {} abort() {}
  }
  window.__said = 'open sales orders';
  window.SpeechRecognition = FakeRec; window.webkitSpeechRecognition = FakeRec;
  const voices = [{ lang: 'en-US', name: 'English', default: true, localService: true, voiceURI: 'en' }, { lang: 'ar-SA', name: 'Arabic', default: false, localService: true, voiceURI: 'ar' }];
  window.__spoken = [];
  const synth = { getVoices: () => voices, speak: (u) => { window.__spoken.push(u.lang); setTimeout(() => u.onend?.(), 50); }, cancel: () => {}, addEventListener: () => {}, removeEventListener: () => {} };
  Object.defineProperty(window, 'speechSynthesis', { configurable: true, get: () => synth });
  Object.defineProperty(window, 'SpeechSynthesisUtterance', { configurable: true, writable: true, value: function (t) { this.text = t; this.lang = ''; this.voice = null; } });
  window.__played = [];
  HTMLMediaElement.prototype.play = function () { window.__played.push(this.src); setTimeout(() => this.dispatchEvent(new Event('ended')), 300); return Promise.resolve(); };
};
async function context(browser, { width = 1440, lang = 'en', theme = 'light', sanaLang = 'auto' } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height: width < 640 ? 844 : 900 }, deviceScaleFactor: 1, permissions: ['microphone'], ...(width < 640 ? { isMobile: true, hasTouch: true } : {}) });
  await ctx.addInitScript(([l, t, sl]) => { localStorage.setItem('lang', l); localStorage.setItem('theme', t); localStorage.setItem('company', 'ZZ99'); localStorage.setItem('sana-lang', sl); localStorage.setItem('sana-speak', '1'); }, [lang, theme, sanaLang]);
  await ctx.addInitScript(stubs);
  return ctx;
}
async function login(page, email, password) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email); await page.fill('#password', password);
  await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
  await settle(page);
}
const ANS = 'aside[role=dialog] [data-testid=sana-answer], aside[role=dialog] [data-testid=sana-refusal], aside[role=dialog] [data-testid=sana-error]';
async function waitAnswer(page, n) {
  await page.waitForFunction(([sel, k]) => document.querySelectorAll(sel).length > k && !document.querySelector('aside[role=dialog] [aria-busy=true]'), [ANS, n], { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(200);
  return txt(page.locator(ANS).last());
}
async function ask(page, q) {
  const n = await page.locator(ANS).count();
  await page.fill('#sana-input', q); await page.keyboard.press('Enter');
  return waitAnswer(page, n);
}
async function openPanel(page, width = 1440) {
  if (width < 640) await page.click('[data-testid=sana-fab]'); else await page.click('#top-ask-sana');
  await seen(page.locator('aside[role=dialog]'));
  await page.waitForTimeout(500);
}
/** push-to-talk through the provider: start, hold ~1.4 s of (fake) microphone audio, stop → transcribe → ask */
async function talk(page, holdMs = 1400) {
  const n = await page.locator(ANS).count();
  // the local mock answers in a few ms; hold the speech-to-text reply briefly so the "Transcribing…" state is observable
  await page.route('**/functions/v1/sana-voice', async (r) => { if ((r.request().postData() ?? '').includes('"mode":"stt"')) await new Promise((x) => setTimeout(x, 900)); await r.continue(); });
  await page.click('[data-testid=sana-mic]');
  const listening = await seen(page.locator('[data-testid=sana-listening]'), 4000);
  await page.waitForTimeout(holdMs);
  await page.click('[data-testid=sana-mic]');
  const transcribing = await seen(page.locator('[data-testid=sana-transcribing]'), 3000);
  const answer = await waitAnswer(page, n);
  await page.unroute('**/functions/v1/sana-voice');
  return { listening, transcribing, answer };
}

const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required'] });
try {
  // ---------- 1. Admin screen: read-only provider card, no key field, voice mode ----------
  await setProvider('basic');
  {
    const ctx = await context(browser); const p = await ctx.newPage();
    await login(p, 'qa.admin@sample.test', 'local-only-1');
    await p.goto(`${BASE}/admin/ai-assistant`); await settle(p);
    await seen(p.locator('[data-testid=adm-ai-provider]'));
    ok('admin: provider card from the config action — Google Gemini, gemini-2.5-flash', (await txt(p.locator('[data-testid=adm-ai-prov-name]'))) === 'Google Gemini'
      && (await txt(p.locator('[data-testid=adm-ai-prov-model]'))) === 'gemini-2.5-flash');
    ok('admin: voice models shown (STT gemini-2.5-flash, TTS gemini-2.5-flash-preview-tts · Kore)', (await txt(p.locator('[data-testid=adm-ai-prov-stt]'))) === 'gemini-2.5-flash'
      && (await txt(p.locator('[data-testid=adm-ai-prov-tts]'))).includes('gemini-2.5-flash-preview-tts'));
    ok('admin: key configured = No in the local stack (no key here), basic mode explained', (await txt(p.locator('[data-testid=adm-ai-prov-key]'))) === 'No' && /Basic mode: no key/.test(await txt(p.locator('[data-testid=adm-ai-key]'))));
    const keyish = await p.locator('main input, main textarea, main select').evaluateAll((els) => els.filter((e) => /key|secret|token|password|credential/i.test(
      [e.id, e.getAttribute('name'), e.getAttribute('placeholder'), e.getAttribute('aria-label'), e.type].join(' '))).length);
    ok('admin: no key field anywhere on the screen (no input for a key, secret, token or password)', keyish === 0 && (await p.locator('main input[type=password]').count()) === 0, String(keyish));
    ok('admin: voice mode — browser by default, both choices explained', await p.isChecked('#adm-ai-voice-mode-browser') && (await p.locator('#adm-ai-voice-mode-provider').count()) === 1
      && /Malayalam/.test(await txt(p.locator('[data-testid=adm-ai-voice-mode]'))));
    await p.screenshot({ path: `${OUT}/s2-admin-en-light-1440.png`, fullPage: true });
    await p.check('#adm-ai-voice-mode-provider'); await p.click('#adm-ai-save'); await settle(p);
    await seen(p.locator('[data-testid=adm-flash]'));
    const row = (await db.query(`SELECT voice_mode FROM erp.sana_settings WHERE company_code = 'ZZ99'`)).rows[0];
    const aud = (await db.query(`SELECT detail FROM erp.audit_log WHERE action = 'sana_settings_save' AND company_code = 'ZZ99' ORDER BY audit_id DESC LIMIT 1`)).rows[0]?.detail;
    ok('admin: saving voice mode provider stores it and audits it', row?.voice_mode === 'provider' && aud?.to?.voice_mode === 'provider', JSON.stringify(aud));
    await p.reload(); await settle(p);
    ok('admin: the saved voice mode shows after reload', await p.isChecked('#adm-ai-voice-mode-provider'));
    await ctx.close();
    // IT (Administration read-only): sees the card and the voice mode, cannot change it
    const c2 = await context(browser); const it = await c2.newPage();
    await login(it, 'qa.it@sample.test', 'local-only-23');
    await it.goto(`${BASE}/admin/ai-assistant`); await settle(it);
    ok('IT: provider card readable, voice mode read-only', await seen(it.locator('[data-testid=adm-ai-provider]')) && await seen(it.locator('#adm-ai-voice-mode-provider[disabled]')) && (await it.locator('#adm-ai-save').count()) === 0);
    await c2.close();
    // a non-admin cannot read the provider config
    const c3 = await context(browser); const s = await c3.newPage();
    await login(s, 'qa.sales@sample.test', 'local-only-2');
    const tok = await s.evaluate(() => { const k = Object.keys(sessionStorage).concat(Object.keys(localStorage)).find((x) => x.includes('auth-token')); return k ? JSON.parse(sessionStorage.getItem(k) ?? localStorage.getItem(k)).access_token : null; });
    const r = await fetch(`${GW}/functions/v1/sana`, { method: 'POST', headers: { authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: JSON.stringify({ action: 'config', company: 'ZZ99' }) });
    ok('config action: refused for a sales user (403)', r.status === 403);
    await c3.close();
  }
  await setProvider('gemini-mock');
  {
    const ctx = await context(browser); const p = await ctx.newPage();
    await login(p, 'qa.admin@sample.test', 'local-only-1');
    await p.goto(`${BASE}/admin/ai-assistant`); await settle(p);
    await seen(p.locator('[data-testid=adm-ai-provider]'));
    ok('admin (local mock): key configured Yes, AI mode, labelled "Local test mock — not AI"', (await txt(p.locator('[data-testid=adm-ai-prov-key]'))) === 'Yes'
      && (await txt(p.locator('[data-testid=adm-ai-mock]'))).includes('not AI'));
    const html = await p.content();
    ok('admin: the page never contains the placeholder key or any key value', !html.includes('local-mock'));
    await ctx.close();
  }

  // ---------- 2. Text mode through the provider (mock) ----------
  await voiceMode('browser');
  for (const prov of ['gemini-mock', 'anthropic-mock']) {
    await setProvider(prov);
    const ctx = await context(browser); const p = await ctx.newPage();
    const errs = []; p.on('pageerror', (e) => errs.push(e.message));
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(p);
    const a = await ask(p, 'How many open sales orders do we have?');
    ok(`text (${prov}): streamed answer from the provider path, with source links`, /^\[mock\]/.test(a) && /count \d+/.test(a) && (await p.locator('aside[role=dialog] [data-testid=sana-answer] a[href^="/docs/sales_order"]').count()) > 0, a);
    ok(`text (${prov}): no basic-mode note (AI mode)`, (await p.locator('[data-testid=sana-basic]').count()) === 0);
    const r = await ask(p, 'Show me the profit and the journal entries');
    ok(`text (${prov}): out of role → standard refusal`, /isn.t available for your role/.test(r) && (await p.locator('aside[role=dialog] [data-testid=sana-refusal]').count()) === 1, r);
    if (prov === 'gemini-mock') await p.screenshot({ path: `${OUT}/s2-panel-text-gemini-en-light-1440.png` });
    const f = await ask(p, 'open sales orders [[mock:error]]');
    ok(`text (${prov}): provider failure → basic-mode answer with the fallback note`, /open sales orders/.test(f) && /didn.t answer, so this is a basic-mode answer/.test(await txt(p.locator(ANS).last())), f);
    ok(`text (${prov}): no page errors`, errs.length === 0, errs.join(' | '));
    await ctx.close();
  }

  // ---------- 3. Voice mode browser (S1 path unchanged) ----------
  await setProvider('gemini-mock');
  await voiceMode('browser');
  {
    const ctx = await context(browser); const p = await ctx.newPage();
    const voiceCalls = []; p.on('request', (r) => { if (r.url().includes('/functions/v1/sana-voice')) voiceCalls.push(r.url()); });
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(p);
    ok('browser voice: the microphone is the Web Speech path', (await p.getAttribute('[data-testid=sana-mic]', 'data-voice-mode')) === 'browser');
    const n = await p.locator(ANS).count();
    await p.click('[data-testid=sana-mic]');
    await waitAnswer(p, n);
    ok('browser voice: spoken question answered and read aloud by the device voice', (await p.locator('aside[role=dialog] [data-testid=sana-user-msg] svg').count()) > 0
      && (await p.evaluate(() => window.__spoken.length)) >= 1);
    await p.selectOption('#sana-lang', 'ml');
    await ask(p, 'തുറന്ന സെയിൽസ് ഓർഡറുകൾ എത്ര?');
    await p.locator('aside[role=dialog] [data-testid=sana-answer] button', { hasText: 'Listen' }).last().click();
    ok('browser voice: still "No voice for മലയാളം on this device" (unchanged S1 behaviour)', (await txt(p.locator('[data-testid=sana-no-voice]'))).includes('No voice for മലയാളം'));
    ok('browser voice: nothing is sent to sana-voice', voiceCalls.length === 0);
    await ctx.close();
  }

  // ---------- 4. Voice mode provider (Gemini STT/TTS through sana-voice) ----------
  await voiceMode('provider');
  await db.query(`DELETE FROM erp.sana_usage WHERE company_code = 'ZZ99'`);
  {
    const ctx = await context(browser, { sanaLang: 'ml' }); const p = await ctx.newPage();
    const errs = []; p.on('pageerror', (e) => errs.push(e.message));
    const calls = [];
    p.on('request', (r) => { if (r.url().includes('/functions/v1/sana-voice')) { const b = JSON.parse(r.postData() || '{}'); calls.push({ mode: b.mode, mime: b.mime, language: b.language, audio: (b.audio ?? '').length, text: b.text }); } });
    const ttsReplies = [];
    p.on('response', async (r) => { if (r.url().includes('/functions/v1/sana-voice') && r.headers()['content-type'] === 'audio/wav') ttsReplies.push({ status: r.status(), provider: r.headers()['x-sana-provider'] }); });
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(p);
    ok('provider voice: the microphone uses the provider path, the privacy line says so', (await p.getAttribute('[data-testid=sana-mic]', 'data-voice-mode')) === 'provider'
      && /transcribed and read aloud by Gemini/.test(await txt(p.locator('aside[role=dialog] form'))));
    const t1 = await talk(p);
    await p.screenshot({ path: `${OUT}/s2-panel-provider-voice-ml-en-light-1440.png` });
    const stt = calls.find((c) => c.mode === 'stt');
    ok('provider voice: recording → listening → transcribing states', t1.listening && t1.transcribing);
    ok('provider voice: MediaRecorder audio converted to WAV and sent once with the chosen language (ml)', stt?.mime === 'audio/wav' && stt.language === 'ml' && stt.audio > 2000, JSON.stringify(stt));
    const userMsg = await txt(p.locator('aside[role=dialog] [data-testid=sana-user-msg]').last());
    ok('provider voice: the Malayalam transcript becomes the question (with the microphone mark)', /[ഀ-ൿ]/.test(userMsg) && (await p.locator('aside[role=dialog] [data-testid=sana-user-msg]').last().locator('svg').count()) > 0, userMsg);
    await p.waitForTimeout(1200);
    ok('provider voice: the answer is read aloud from Gemini TTS audio (WAV), no "no voice" note', ttsReplies.some((r) => r.status === 200 && r.provider === 'gemini')
      && (await p.evaluate(() => window.__played.length)) >= 1 && (await p.locator('[data-testid=sana-no-voice]').count()) === 0, JSON.stringify(ttsReplies));
    // Listen on a Malayalam answer: provider TTS instead of "No voice for Malayalam"
    const before = await p.evaluate(() => window.__played.length);
    await p.locator('aside[role=dialog] [data-testid=sana-answer] button', { hasText: 'Listen' }).last().click();
    await p.waitForTimeout(1200);
    const tts = calls.filter((c) => c.mode === 'tts').pop();
    ok('provider voice: Listen plays Malayalam through Gemini — solves "no Malayalam voice on this device"', (await p.evaluate(() => window.__played.length)) > before && tts?.language === 'ml'
      && (await p.locator('[data-testid=sana-no-voice]').count()) === 0, JSON.stringify(tts));
    ok('provider voice: browser speech synthesis not used', (await p.evaluate(() => window.__spoken.length)) === 0);
    const usage = (await db.query(`SELECT sum(voice_calls)::int vc FROM erp.sana_usage WHERE company_code = 'ZZ99' AND user_id = $1`, [SALES])).rows[0];
    ok('provider voice: calls counted (STT + TTS) and audited with metadata only', usage.vc >= 3
      && (await db.query(`SELECT count(*)::int n FROM erp.audit_log WHERE action = 'sana.voice' AND detail ? 'audio'`)).rows[0].n === 0);
    // English, auto
    await p.selectOption('#sana-lang', 'en');
    const t2 = await talk(p);
    ok('provider voice: English question transcribed and answered', /How many open sales orders/.test(await txt(p.locator('aside[role=dialog] [data-testid=sana-user-msg]').last())) && /\[mock\]/.test(t2.answer), t2.answer);
    ok('provider voice: no page errors', errs.length === 0, errs.join(' | '));
    await ctx.close();
  }
  // Home hero microphone (provider mode)
  {
    const ctx = await context(browser); const p = await ctx.newPage();
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    const mic = p.locator('main form button[data-voice-mode]');   // the label changes to "Stop listening" while recording
    await seen(p.locator('main form button[data-voice-mode=provider]'), 8000);
    await mic.click(); await p.waitForTimeout(1300); await mic.click();
    ok('home hero (provider voice): the recorded question opens Sana and is answered', await seen(p.locator('aside[role=dialog] [data-testid=sana-user-msg]'), 15000)
      && /\[mock\]/.test(await txt(p.locator('aside[role=dialog] [data-testid=sana-user-msg]'))));
    await ctx.close();
  }
  // Provider voice unavailable (no Gemini key on the server): microphone says why; Listen falls back to the device voice
  await setProvider('basic');
  {
    const ctx = await context(browser); const p = await ctx.newPage();
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(p);
    await p.click('[data-testid=sana-mic]'); await p.waitForTimeout(900); await p.click('[data-testid=sana-mic]');
    ok('provider voice without a server key: the microphone shows the reason (no crash)', /isn.t set up on the server yet/.test(await txt(p.locator('[data-testid=sana-mic-msg]')).catch(() => '')) || await seen(p.locator('[data-testid=sana-mic-msg]'), 6000));
    await ask(p, 'open sales orders');
    await p.locator('aside[role=dialog] [data-testid=sana-answer] button', { hasText: 'Listen' }).last().click();
    await p.waitForTimeout(800);
    ok('provider voice without a server key: Listen falls back to the device voice (English)', (await p.evaluate(() => window.__spoken.length)) >= 1);
    await ctx.close();
  }

  // ---------- 5. Screenshots: 1440 / 390, light / dark, EN / AR (provider voice mode, mock answer, admin) ----------
  await setProvider('gemini-mock');
  await voiceMode('provider');
  await db.query(`DELETE FROM erp.sana_usage WHERE company_code = 'ZZ99'`);
  for (const [lang, theme, width] of [['en', 'dark', 1440], ['ar', 'light', 1440], ['ar', 'dark', 1440], ['en', 'light', 390], ['en', 'dark', 390], ['ar', 'light', 390], ['ar', 'dark', 390]]) {
    const tag = `${lang}-${theme}-${width}`;
    const ctx = await context(browser, { width, lang, theme }); const p = await ctx.newPage();
    await login(p, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(p, width);
    await ask(p, lang === 'ar' ? 'كم عدد أوامر البيع المفتوحة؟' : 'How many open sales orders do we have?');
    await p.screenshot({ path: `${OUT}/s2-panel-text-${tag}.png` });
    await p.route('**/functions/v1/sana-voice', async (r) => { if ((r.request().postData() ?? '').includes('"mode":"stt"')) await new Promise((x) => setTimeout(x, 1500)); await r.continue(); });
    await p.click('[data-testid=sana-mic]'); await p.waitForTimeout(700);
    await p.screenshot({ path: `${OUT}/s2-panel-provider-listening-${tag}.png` });
    await p.click('[data-testid=sana-mic]');
    await seen(p.locator('[data-testid=sana-transcribing]'), 3000);
    await p.screenshot({ path: `${OUT}/s2-panel-provider-transcribing-${tag}.png` });
    await p.waitForTimeout(2500);
    if (lang === 'ar') ok(`Arabic (${theme}, ${width}): the panel is right-to-left and the voice texts are translated`, (await p.getAttribute('html', 'dir')) === 'rtl'
      && !/sana\.(transcribing|voiceProviderNote|listeningProvider)/.test(await txt(p.locator('aside[role=dialog]'))));
    if (width < 640) ok(`no horizontal page scroll at 390 px (${lang}, ${theme})`, await p.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1));
    await ctx.close();
    const c2 = await context(browser, { width, lang, theme }); const a = await c2.newPage();
    await login(a, 'qa.admin@sample.test', 'local-only-1');
    await a.goto(`${BASE}/admin/ai-assistant`); await settle(a);
    await seen(a.locator('[data-testid=adm-ai-provider]'));
    await a.screenshot({ path: `${OUT}/s2-admin-${tag}.png`, fullPage: true });
    if (lang === 'ar') ok(`admin Arabic (${theme}, ${width}): voice mode and provider card translated`, /وضع الصوت/.test(await txt(a.locator('main'))) && !/adm\.ai\.(vm|prov)/.test(await txt(a.locator('main'))));
    if (width < 640) ok(`admin: no horizontal page scroll at 390 px (${lang}, ${theme})`, await a.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1));
    await c2.close();
  }
} finally {
  await setProvider('basic');
  await db.query(`DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99'`);
  await browser.close();
  await db.end();
}
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(results, null, 1));
const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed (text answers come from the LOCAL-ONLY provider mock — not AI)`);
process.exit(failed.length ? 1 : 0);

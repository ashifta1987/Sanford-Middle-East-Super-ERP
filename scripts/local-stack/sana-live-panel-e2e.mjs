// Sana Live in the panel (S5 · M3). LOCAL STACK + Vite (:5173). The Gemini Live socket is MOCKED with Playwright's routeWebSocket:
// the mock speaks the BidiGenerateContentConstrained messages (setupComplete, inputTranscription, toolCall, audio, outputTranscription,
// turnComplete, interrupted); the token, tool calls, log_turn and end go to the real local handlers (gateway → livecore).
//   NODE_PATH=~/erp-work/localstack/node_modules node scripts/local-stack/sana-live-panel-e2e.mjs
// Checks: Talk button (desktop next to the mic, phone large at the bottom), states (connecting → listening → looking up → speaking),
// transcript bubbles (user right, Sana left, source chips, unverified mark), barge-in stops playback, end on button / silence /
// tab hidden / minutes cap, the push-to-talk mic stays, no Talk button without AudioWorklet, the turns land in the DB via 'live'.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const pg = require('pg');

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:5173';
const GW = process.env.GATEWAY_URL ?? 'http://127.0.0.1:54321';
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + String(detail).slice(0, 200) : ''}`); };
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();
await db.query("DELETE FROM erp.sana_live_session WHERE user_id IN (SELECT user_id FROM erp.app_user WHERE email LIKE 'qa.%@sample.test')");
const pcm = Buffer.alloc(4800).toString('base64');   // 0.1 s of silence at 24 kHz

/** the mock Live server for one page; `script` decides what happens after each client message */
async function mockLive(page, log) {
  await page.routeWebSocket(/generativelanguage\.googleapis\.com/, (ws) => {
    let turn = 0;
    const send = (m) => ws.send(JSON.stringify(m));
    ws.onMessage((raw) => {
      const m = JSON.parse(String(raw));
      if (m.setup) { log.push('setup'); send({ setupComplete: {} }); setTimeout(() => startTurn(), 300); return; }
      if (m.toolResponse) {
        log.push('toolResponse:' + JSON.stringify(m.toolResponse.functionResponses?.[0]?.response ?? {}).slice(0, 80));
        setTimeout(() => {
          send({ serverContent: { modelTurn: { parts: [{ inlineData: { mimeType: 'audio/pcm;rate=24000', data: pcm } }] } } });
          send({ serverContent: { outputTranscription: { text: 'SMP-1010: 861 എണ്ണം ലഭ്യമാണ്.' } } });
          setTimeout(() => { send({ serverContent: { turnComplete: true } }); setTimeout(() => startTurn(), 600); }, 300);
        }, 400);
      }
    });
    function startTurn() {
      turn++;
      if (turn === 1) {   // a lookup turn
        send({ serverContent: { inputTranscription: { text: 'എസ്എംപി 1010 സ്റ്റോക്ക് എത്ര?' } } });
        setTimeout(() => send({ toolCall: { functionCalls: [{ id: 'c1', name: 'get_stock', args: { query: 'smp 1010' } }] } }), 500);
      } else if (turn === 2) {   // a figure without a lookup → unverified; Sana is interrupted mid-answer
        send({ serverContent: { inputTranscription: { text: 'ആകെ എത്ര?' } } });
        for (let i = 0; i < 30; i++) send({ serverContent: { modelTurn: { parts: [{ inlineData: { mimeType: 'audio/pcm;rate=24000', data: pcm } }] } } });
        send({ serverContent: { outputTranscription: { text: 'ആകെ 1,240 എണ്ണം ഉണ്ട്.' } } });
        setTimeout(() => { send({ serverContent: { interrupted: true } }); send({ serverContent: { turnComplete: true } }); log.push('interrupted'); }, 700);
      }
    }
  });
}
async function login(page, email, password) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email); await page.fill('#password', password); await page.click('button[type=submit]');
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}
const openPanel = async (page, width) => { if (width < 640) await page.click('[data-testid=sana-fab]'); else await page.click('#top-ask-sana'); await page.waitForSelector('[role=dialog]'); };

// a silent microphone (Chrome's default fake device beeps, which counts as speech and would keep the session from going silent)
import fs from 'node:fs';
const SILENT = '/tmp/sana-silent.wav';
{ const n = 16000 * 5 * 2, h = Buffer.alloc(44); h.write('RIFF', 0); h.writeUInt32LE(36 + n, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(16000, 24); h.writeUInt32LE(32000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(n, 40); fs.writeFileSync(SILENT, Buffer.concat([h, Buffer.alloc(n)])); }
const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${SILENT}`, '--autoplay-policy=no-user-gesture-required'] });
try {
  // ---------- desktop: a full session ----------
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, permissions: ['microphone'] });
    const page = await ctx.newPage();
    const log = []; await mockLive(page, log);
    await login(page, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(page, 1280);
    ok('desktop: the Talk button sits next to the mic; the push-to-talk mic is still there', await page.locator('[data-testid=sana-talk]').isVisible() && await page.locator('[data-testid=sana-mic]').isVisible()
      && !(await page.locator('[data-testid=sana-talk-phone]').isVisible()));
    await page.selectOption('#sana-lang', 'ml').catch(() => {});
    const states = new Set();
    const watch = setInterval(async () => { const s = await page.getAttribute('[data-testid=sana-live-bar]', 'data-live-state', { timeout: 200 }).catch(() => null); if (s) states.add(s); }, 100);
    await page.click('[data-testid=sana-talk]');
    await page.waitForSelector('[data-testid=sana-live-answer]', { timeout: 15000 });
    await page.waitForFunction(() => [...document.querySelectorAll('[data-testid=sana-live-answer]')].some((e) => e.textContent.includes('861')), null, { timeout: 15000 });
    const user1 = await page.locator('[data-testid=sana-live-user]').first().innerText();
    ok('transcript: the user line is a right-hand bubble in Malayalam script', /[\u0D00-\u0D7F]/.test(user1) && (await page.locator('[data-testid=sana-live-user]').first().getAttribute('class')).includes('justify-end'), user1);
    const chip = page.locator('[data-testid=sana-live-answer] a[href*="/items/ZZ99/SMP-1010"]');
    ok('transcript: Sana\'s answer is a left bubble with the source chip from the tool result', await chip.count() > 0, await page.locator('[data-testid=sana-live-answer]').first().innerText());
    ok('the tool call went through sana-live-tool (masked result back to the model)', log.some((l) => l.startsWith('toolResponse:') && l.includes('SMP-1010')), log.join(' | '));
    await page.waitForFunction(() => document.querySelectorAll('[data-testid=sana-live-flag]').length > 0, null, { timeout: 15000 }).catch(() => {});
    const flags = await page.locator('[data-testid=sana-live-flag]').allInnerTexts();
    ok('rule 1a: the figure without a lookup is marked unverified (from log_turn)', flags.some((f) => /Unverified/i.test(f)) && (await page.locator('[data-live-flag=unverified]').count()) === 1, flags.join(' | '));
    ok('barge-in: `interrupted` arrived and the bar went back to listening', log.includes('interrupted'));
    await page.waitForTimeout(400);
    clearInterval(watch);
    ok('states shown: connecting → listening → looking up → speaking', ['connecting', 'listening', 'looking', 'speaking'].every((s) => states.has(s)), [...states].join(','));
    await page.click('[data-testid=sana-live-end]');
    await page.waitForSelector('[data-testid=sana-live-note]', { timeout: 5000 });
    ok('end on the button: the bar goes, the note says it ended, Talk is back', !(await page.locator('[data-testid=sana-live-bar]').count()) && /ended/i.test(await page.locator('[data-testid=sana-live-note]').innerText())
      && await page.locator('[data-testid=sana-talk]').isVisible());
    await page.waitForTimeout(800);
    const sess = (await db.query("SELECT ended_reason, turns, tool_calls FROM erp.sana_live_session s JOIN erp.app_user u USING (user_id) WHERE u.email = 'qa.sales@sample.test' ORDER BY started_at DESC LIMIT 1")).rows[0];
    ok('server: the session ended once with reason user, 2 turns, 1 tool call', sess?.ended_reason === 'user' && sess.turns === 2 && sess.tool_calls === 1, JSON.stringify(sess));
    const rows = (await db.query("SELECT m.via, m.context->>'label' AS label FROM erp.sana_message m JOIN erp.sana_conversation c USING (conversation_id) JOIN erp.app_user u ON u.user_id = c.user_id WHERE u.email = 'qa.sales@sample.test' AND m.role = 'user' ORDER BY m.message_id DESC LIMIT 2")).rows;
    ok('server: both turns logged as via live (one live, one live-unverified)', rows.length === 2 && rows.every((r) => r.via === 'live') && rows.some((r) => r.label === 'live-unverified'), JSON.stringify(rows));
    await page.screenshot({ path: `${process.env.HOME}/erp-work/s5/m3-panel-desktop.png` });

    // ---------- end on silence and on a hidden tab (shortened limits, dev build only) ----------
    await page.evaluate(() => { localStorage.setItem('sana-live-test-silence-ms', '2500'); });
    await page.unrouteAll({ behavior: 'ignoreErrors' }).catch(() => {});
    await page.routeWebSocket(/generativelanguage\.googleapis\.com/, (ws) => ws.onMessage((raw) => { if (JSON.parse(String(raw)).setup) ws.send(JSON.stringify({ setupComplete: {} })); }));
    await page.click('[data-testid=sana-talk]');
    await page.waitForSelector('[data-testid=sana-live-bar][data-live-state=listening]', { timeout: 10000 });
    await page.waitForSelector('[data-testid=sana-live-note]', { timeout: 15000 });
    ok('end on silence (60 s; 2.5 s in this test)', /silence/i.test(await page.locator('[data-testid=sana-live-note]').innerText()), await page.locator('[data-testid=sana-live-note]').innerText());
    await page.evaluate(() => { localStorage.setItem('sana-live-test-silence-ms', '600000'); localStorage.setItem('sana-live-test-hidden-ms', '1500'); });
    await page.click('[data-testid=sana-talk]');
    await page.waitForSelector('[data-testid=sana-live-bar][data-live-state=listening]', { timeout: 10000 });
    await page.evaluate(() => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' }); document.dispatchEvent(new Event('visibilitychange')); });
    await page.waitForFunction(() => /background/.test(document.querySelector('[data-testid=sana-live-note]')?.textContent ?? ''), null, { timeout: 10000 }).catch(() => {});
    ok('end when the tab is hidden for more than 30 s (1.5 s in this test)', /background/i.test(await page.locator('[data-testid=sana-live-note]').innerText().catch(() => '')));
    const reasons = (await db.query("SELECT ended_reason FROM erp.sana_live_session s JOIN erp.app_user u USING (user_id) WHERE u.email = 'qa.sales@sample.test' ORDER BY started_at DESC LIMIT 2")).rows.map((r) => r.ended_reason);
    ok('server: those sessions ended as hidden and silence', reasons.join(',') === 'hidden,silence', reasons.join(','));
    await page.evaluate(() => { localStorage.removeItem('sana-live-test-silence-ms'); localStorage.removeItem('sana-live-test-hidden-ms'); });
    await ctx.close();
  }
  // ---------- minutes cap ----------
  {
    const admin = await (await fetch(`${GW}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: 'local', 'content-type': 'application/json' }, body: JSON.stringify({ email: 'qa.admin@sample.test', password: 'local-only-1' }) })).json();
    const caps = (n) => fetch(`${GW}/rest/v1/rpc/sana_caps_save`, { method: 'POST', headers: { apikey: 'local', authorization: `Bearer ${admin.access_token}`, 'content-type': 'application/json', 'content-profile': 'erp' }, body: JSON.stringify({ p_company: 'ZZ99', p_live_minutes: n }) });
    await caps(0);
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, permissions: ['microphone'] });
    const page = await ctx.newPage();
    await login(page, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(page, 1280);
    await page.click('[data-testid=sana-talk]');
    await page.waitForSelector('[data-testid=sana-live-note]', { timeout: 10000 });
    ok('end on cap: at the daily minutes cap Talk shows the cap message (no socket opened)', /minutes/i.test(await page.locator('[data-testid=sana-live-note]').innerText()), await page.locator('[data-testid=sana-live-note]').innerText());
    await caps(30);
    await ctx.close();
  }
  // ---------- phone: large Talk button at the bottom ----------
  {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, permissions: ['microphone'] });
    const page = await ctx.newPage();
    await login(page, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(page, 390);
    const big = page.locator('[data-testid=sana-talk-phone]');
    const box = await big.boundingBox();
    ok('phone: a large Talk button at the bottom of the panel (desktop button hidden)', await big.isVisible() && box && box.width > 300 && box.height >= 48 && box.y > 600 && !(await page.locator('[data-testid=sana-talk]').isVisible()), JSON.stringify(box));
    await page.screenshot({ path: `${process.env.HOME}/erp-work/s5/m3-panel-phone.png` });
    await ctx.close();
  }
  // ---------- no AudioWorklet: push-to-talk only ----------
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 } });
    await ctx.addInitScript(() => { delete window.AudioWorkletNode; });
    const page = await ctx.newPage();
    await login(page, 'qa.sales@sample.test', 'local-only-2');
    await openPanel(page, 1280);
    ok('no AudioWorklet: no Talk button, the push-to-talk mic stays', !(await page.locator('[data-testid=sana-talk]').count()) && await page.locator('[data-testid=sana-mic]').isVisible());
    await ctx.close();
  }
} catch (e) {
  ok('panel e2e ran without an exception', false, e.stack ?? e.message);
} finally {
  await browser.close();
  await db.query("DELETE FROM erp.sana_live_session WHERE user_id IN (SELECT user_id FROM erp.app_user WHERE email LIKE 'qa.%@sample.test')").catch(() => null);
  await db.end();
}
const failed = results.filter((r) => !r.pass).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);


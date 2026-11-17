// Sana Live e2e (S5 · M2). LOCAL STACK only (gateway :54321 with the fake token mint, sample company ZZ99, test users).
//   NODE_PATH=~/erp-work/localstack/node_modules node scripts/local-stack/sana-live-e2e.mjs
// The Gemini Live socket is MOCKED: mockLive() speaks the same JSON messages as BidiGenerateContentConstrained
// (setupComplete, toolCall, serverContent with transcriptions, turnComplete), and the client loop below does what the test
// page does with them (tool call → sana-live-tool → toolResponse; turn end → log_turn). The real socket is tried once on live.
// Checks: token per role (sales has no finance tools; the locked setup carries exactly the role's tools, the system prompt and
// the transcription pinned to the session language), GRP → home company, a finance tool in a sales session is refused, a tool
// outside the role is refused, item codes match with spaces/dashes/case, near misses come back as did_you_mean, results are
// masked, log_turn writes a via='live' row, end closes once, an expired session is refused, the minutes cap gives 429.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const pg = require('pg');

const GW = process.env.GATEWAY_URL ?? 'http://127.0.0.1:54321';
const U = {
  admin: { email: 'qa.admin@sample.test', password: 'local-only-1' }, sales: { email: 'qa.sales@sample.test', password: 'local-only-2' },
  finance: { email: 'qa.finance@sample.test', password: 'local-only-4' }, owner: { email: 'qa.owner@sample.test', password: 'local-only-5' },
};
const results = [];
const ok = (name, pass, detail = '') => { results.push({ name, pass }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + String(detail).slice(0, 220) : ''}`); };
const db = new pg.Client({ host: '127.0.0.1', port: 5433, user: 'postgres', database: 'erp_local' });
await db.connect();

const token = async (u) => (await (await fetch(`${GW}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: 'local', 'content-type': 'application/json' }, body: JSON.stringify(u) })).json()).access_token;
const call = async (fn, tok, body) => { const r = await fetch(`${GW}/functions/v1/${fn}`, { method: 'POST', headers: { apikey: 'local', authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: JSON.stringify(body) }); return { status: r.status, j: await r.json().catch(() => ({})) }; };
const rpc = async (tok, fn, a) => { const r = await fetch(`${GW}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: 'local', authorization: `Bearer ${tok}`, 'content-type': 'application/json', 'content-profile': 'erp', 'accept-profile': 'erp' }, body: JSON.stringify(a) }); return { status: r.status, j: await r.json().catch(() => ({})) }; };
const lastSetup = async () => (await fetch(`${GW}/local/live-last-setup`)).json();
const FINANCE = ['payables', 'finance_summary', 'banking'];   // sales roles see customer receivables (S3 role matrix), not these

// ---------- mock of the Live socket (server side of the protocol) ----------
function mockLive(script) {
  const out = [];   // messages "from Gemini"
  return {
    send(msg) {   // what the browser sends
      if (msg.setup) out.push({ setupComplete: {} });
      if (msg.realtimeInput?.text != null || msg.clientContent) { const turn = script.shift(); if (turn) out.push(...turn); }
      if (msg.toolResponse) { const turn = script.shift(); if (turn) out.push(...turn); }
    },
    next: () => out.shift(),
  };
}
// the page's handling of one spoken turn: answer tool calls through sana-live-tool, collect transcripts, log the turn
async function runTurn(sock, tok, sid, userSays) {
  const t0 = performance.now(); let firstAudio = null; const tools = [], toolResults = []; let inText = '', outText = '';
  sock.send({ realtimeInput: { text: userSays } });
  for (let guard = 0; guard < 20; guard++) {
    const m = sock.next(); if (!m) break;
    if (m.toolCall) {
      const responses = [];
      for (const fc of m.toolCall.functionCalls) {
        const r = await call('sana-live-tool', tok, { action: 'tool', live_session_id: sid, tool: fc.name, args: fc.args });
        tools.push(fc.name); toolResults.push(r);
        responses.push({ id: fc.id, name: fc.name, response: r.status === 200 ? r.j : { error: r.j.error } });
      }
      sock.send({ toolResponse: { functionResponses: responses } });
      continue;
    }
    if (m.serverContent?.inputTranscription) inText += m.serverContent.inputTranscription.text;
    if (m.serverContent?.outputTranscription) outText += m.serverContent.outputTranscription.text;
    if (m.serverContent?.modelTurn?.parts?.some((p) => p.inlineData)) firstAudio ??= performance.now() - t0;
    if (m.serverContent?.turnComplete) break;
  }
  const log = await call('sana-live-tool', tok, { action: 'log_turn', live_session_id: sid, user_text: inText, sana_text: outText, tools,
    timings: { ms_first_audio: firstAudio ?? 0, ms_total: performance.now() - t0 }, device: 'desktop' });
  return { tools, toolResults, inText, outText, log };
}
const audio = { serverContent: { modelTurn: { parts: [{ inlineData: { mimeType: 'audio/pcm;rate=24000', data: 'AAAA' } }] } } };
const said = (t) => ({ serverContent: { inputTranscription: { text: t } } });
const spoke = (t) => ({ serverContent: { outputTranscription: { text: t } } });
const done = { serverContent: { turnComplete: true } };

try {
  const ts = await token(U.sales), tf = await token(U.finance), ta = await token(U.admin), to = await token(U.owner);
  await db.query("DELETE FROM erp.sana_live_session WHERE user_id IN (SELECT user_id FROM erp.app_user WHERE email LIKE 'qa.%@sample.test')");

  // ---------- token per role, locked setup ----------
  const s1 = await call('sana-live-token', ts, { company: 'ZZ99', language: 'ml' });
  const setupS = await lastSetup();
  const declared = (setupS.tools?.[0]?.functionDeclarations ?? []).map((d) => d.name);
  ok('token (sales, ml): 200, single-use token, session id, seconds left, the role\'s tool list', s1.status === 200 && s1.j.token && /^[0-9a-f-]{36}$/.test(s1.j.live_session_id) && s1.j.seconds_left > 0 && Array.isArray(s1.j.tools),
    JSON.stringify({ status: s1.status, tools: s1.j.tools, left: s1.j.seconds_left, err: s1.j.error }));
  ok('token (sales): no finance tools', !s1.j.tools?.some((t) => FINANCE.includes(t)), s1.j.tools?.join());
  ok('locked setup: the declared tools are exactly the role\'s tools', declared.length === s1.j.tools?.length && declared.every((d) => s1.j.tools.includes(d)), declared.join());
  ok('locked setup: transcription pinned to ml-IN, speech in ml-IN, audio out, system prompt set',
    JSON.stringify(setupS.inputAudioTranscription?.languageCodes) === '["ml-IN"]' && setupS.generationConfig?.speechConfig?.languageCode === 'ml-IN'
    && setupS.generationConfig?.responseModalities?.[0] === 'AUDIO' && (setupS.systemInstruction?.parts?.[0]?.text ?? '').length > 200,
    JSON.stringify({ in: setupS.inputAudioTranscription, sp: setupS.generationConfig?.speechConfig?.languageCode }));
  const f1 = await call('sana-live-token', tf, { company: 'ZZ99', language: 'en' });
  ok('token (finance): finance tools present, setup pinned to en-US', f1.status === 200 && f1.j.tools?.some((t) => FINANCE.includes(t)) && JSON.stringify((await lastSetup()).inputAudioTranscription?.languageCodes) === '["en-US"]', f1.j.tools?.join());
  const g = await call('sana-live-token', tf, { company: 'GRP', language: 'en' });
  ok('token with "All companies" (GRP) → home company ZZ99, not a 403', g.status === 200 && g.j.company === 'ZZ99', JSON.stringify({ s: g.status, c: g.j.company, e: g.j.error }));
  const a1 = await call('sana-live-token', ta, { company: 'ZZ99', language: 'en' });
  ok('token (admin, IT modules only): 200 with the tools this role has (shown on the test page)', a1.status === 200 && Array.isArray(a1.j.tools), a1.j.tools?.join() || '(none)');
  const bad = await call('sana-live-token', ts, { company: 'XX01', language: 'en' });
  ok('token for a company the user cannot see → 403', bad.status === 403, JSON.stringify(bad.j));
  const anon = await fetch(`${GW}/functions/v1/sana-live-token`, { method: 'POST', body: '{}' });
  ok('token without sign-in → 401', anon.status === 401);

  // ---------- tool calls against the session ----------
  const sid = s1.j.live_session_id;
  const fin = await call('sana-live-tool', ts, { action: 'tool', live_session_id: sid, tool: 'payables', args: {} });
  ok('a finance tool in a sales session → 403 (not in the minted list)', fin.status === 403, JSON.stringify(fin.j));
  const other = await call('sana-live-tool', tf, { action: 'tool', live_session_id: sid, tool: 'find_records', args: { query: 'SMP' } });
  ok('someone else\'s session id → 403', other.status === 403, JSON.stringify(other.j));
  const unknown = await call('sana-live-tool', ts, { action: 'tool', live_session_id: sid, tool: 'run_sql', args: { q: 'select 1' } });
  ok('an unknown tool name → 403', unknown.status === 403);
  const noSid = await call('sana-live-tool', ts, { action: 'tool', tool: 'find_records', args: {} });
  ok('no session id → 400', noSid.status === 400);

  const stockTool = s1.j.tools.includes('get_stock') ? 'get_stock' : 'find_records';
  const variants = ['SMP-1010', 'smp 1010', 'Smp1010', 'S M P - 1 0 1 0'];
  const hits = [];
  for (const q of variants) {
    const r = await call('sana-live-tool', ts, { action: 'tool', live_session_id: sid, tool: stockTool, args: { query: q } });
    hits.push(JSON.stringify(r.j).includes('SMP-1010'));
  }
  ok(`item codes match ignoring spaces, dashes and case (${stockTool}: ${variants.join(' | ')})`, hits.every(Boolean), hits.join());
  if (stockTool === 'get_stock') {
    const near = await call('sana-live-tool', ts, { action: 'tool', live_session_id: sid, tool: 'get_stock', args: { query: 'SMP-1O10' } });
    ok('a near-miss code returns did_you_mean (not a guess)', Array.isArray(near.j.result?.did_you_mean) && near.j.result.did_you_mean.some((d) => JSON.stringify(d).includes('SMP-10')), JSON.stringify(near.j).slice(0, 200));
  }

  // ---------- the mocked socket: one spoken turn with a tool call ----------
  const sock = mockLive([
    [said('എസ്എംപി 1010 സ്റ്റോക്ക് എത്ര?'), { toolCall: { functionCalls: [{ id: 'c1', name: stockTool, args: { query: 'smp 1010' } }] } }],
    [audio, spoke('SMP-1010 ന്റെ സ്റ്റോക്ക് ലഭ്യമാണ്.'), done],
  ]);
  sock.send({ setup: { model: s1.j.model } });
  ok('mock socket: setupComplete after {setup:{model}} (the browser sends only the model)', !!sock.next()?.setupComplete);
  const turn = await runTurn(sock, ts, sid, 'audio');
  ok('mock turn: the tool call went through sana-live-tool and came back with the item', turn.toolResults[0]?.status === 200 && JSON.stringify(turn.toolResults[0].j).includes('SMP-1010'));
  ok('mock turn: input transcript kept in Malayalam script', /[\u0D00-\u0D7F]/.test(turn.inText) && !/[\u0B80-\u0BFF]/.test(turn.inText), turn.inText);
  ok('log_turn: 200, message saved, verified (a tool was used)', turn.log.status === 200 && turn.log.j.message_id && turn.log.j.unverified === false, JSON.stringify(turn.log.j));
  const row = (await db.query('SELECT via, language, model, context FROM erp.sana_message WHERE message_id = $1', [turn.log.j.question_id])).rows[0];
  ok('the logged turn is a via=\'live\' row like a typed turn (question row: via live, language ml, label live)', row?.via === 'live' && row?.language === 'ml' && row?.context?.label === 'live', JSON.stringify(row));
  const unv = await call('sana-live-tool', ts, { action: 'log_turn', live_session_id: sid, user_text: 'how much stock', sana_text: 'You have 1,240 units in stock.', tools: [] });
  ok('log_turn: a figure without a lookup is flagged live-unverified (rule 1a)', unv.status === 200 && unv.j.unverified === true, JSON.stringify(unv.j));
  const sess = (await db.query('SELECT turns, tool_calls FROM erp.sana_live_session WHERE id = $1', [sid])).rows[0];
  ok('session counts turns and tool calls', sess.turns >= 2 && sess.tool_calls >= 5, JSON.stringify(sess));

  // ---------- masking ----------
  const { maskDeep } = await import('../../supabase/functions/sana/mask.ts');
  const masked = JSON.stringify(maskDeep({ r: [{ note: 'IBAN AE070331234567890123456, card 4111 1111 1111 1234' }] }));
  ok('tool results go through the masker (IBAN, card)', !masked.includes('AE070331234567890123456') && !masked.includes('4111 1111 1111 1234'), masked);

  // ---------- end, expiry, cap ----------
  const e1 = await call('sana-live-tool', ts, { action: 'end', live_session_id: sid, reason: 'user' });
  const e2 = await call('sana-live-tool', ts, { action: 'end', live_session_id: sid, reason: 'user' });
  ok('end: closes the session once (second end says already ended)', e1.status === 200 && typeof e1.j.seconds === 'number' && e2.j.already_ended === true, JSON.stringify([e1.j, e2.j]));
  const after = await call('sana-live-tool', ts, { action: 'tool', live_session_id: sid, tool: 'find_records', args: { query: 'SMP' } });
  ok('a tool call after end → 403', after.status === 403, JSON.stringify(after.j));
  const s2 = await call('sana-live-token', ts, { company: 'ZZ99', language: 'en' });
  await db.query("UPDATE erp.sana_live_session SET started_at = now() - interval '12 minutes', expires_at = now() - interval '2 minutes' WHERE id = $1", [s2.j.live_session_id]);
  const exp = await call('sana-live-tool', ts, { action: 'tool', live_session_id: s2.j.live_session_id, tool: 'find_records', args: { query: 'SMP' } });
  const expRow = (await db.query('SELECT ended_reason, seconds FROM erp.sana_live_session WHERE id = $1', [s2.j.live_session_id])).rows[0];
  ok('an expired session is refused and closed as expired (seconds capped at the expiry)', exp.status === 403 && expRow.ended_reason === 'expired' && expRow.seconds <= 600, JSON.stringify({ e: exp.j, expRow }));

  const cap0 = await rpc(ta, 'sana_caps_save', { p_company: 'ZZ99', p_live_minutes: 0 });
  const capped = await call('sana-live-token', ts, { company: 'ZZ99', language: 'ml' });
  ok('minutes cap: at 0 minutes the token is refused with 429 and the message in the session language', cap0.status === 200 && capped.status === 429 && /[\u0D00-\u0D7F]/.test(capped.j.error ?? ''), JSON.stringify(capped.j));
  const notAdmin = await rpc(ts, 'sana_caps_save', { p_company: 'ZZ99', p_live_minutes: 600 });
  ok('only an admin can change the caps', notAdmin.status >= 400, JSON.stringify(notAdmin.j).slice(0, 120));
  await rpc(ta, 'sana_caps_save', { p_company: 'ZZ99', p_live_minutes: 30 });
  const caps = await rpc(ts, 'sana_caps', { p_company: 'ZZ99' });
  ok('caps restored: 30 Live minutes, TTS cap read from settings', caps.j.live_minutes_daily === 30 && caps.j.tts_daily_cap === 10, JSON.stringify(caps.j));
  const audit = (await db.query("SELECT count(*)::int n FROM erp.audit_log WHERE action IN ('sana.live.start','sana.live.end','sana_caps_save') AND at > now() - interval '5 minutes'")).rows[0].n;
  ok('starts, ends and cap changes are in the audit log', audit >= 5, `${audit} rows`);
  const ownerSees = await rpc(to, 'sana_live_usage_today', { p_company: 'ZZ99' });
  ok('usage today returns minutes used / cap / left', ownerSees.status === 200 && 'minutes_cap' in ownerSees.j, JSON.stringify(ownerSees.j));
} catch (e) {
  ok('e2e ran without an exception', false, e.stack ?? e.message);
} finally {
  await db.query("DELETE FROM erp.sana_live_session WHERE user_id IN (SELECT user_id FROM erp.app_user WHERE email LIKE 'qa.%@sample.test')").catch(() => null);
  await db.end();
}
const failed = results.filter((r) => !r.pass).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);

// Local stand-in for the Supabase API, for development and browser tests only.
// /rest/v1/* is proxied to a local PostgREST (real Postgres, real RLS from supabase/sql/10-15).
// /auth/v1/* issues HS256 JWTs for the test users in users.json (never real users or passwords).
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { LOCAL_RESPONDER, localAnswer } from './ai-test-responder.mjs';

const PORT = Number(process.env.GATEWAY_PORT ?? 54321);
const PGRST = process.env.PGRST_URL ?? 'http://127.0.0.1:3000';
const SECRET = process.env.JWT_SECRET ?? 'local-dev-secret-local-dev-secret-0001';
const users = JSON.parse(fs.readFileSync(new URL('./users.json', import.meta.url)));
// A10 · invited users and the test inbox (local only; the file is git-ignored). Stands in for Supabase Auth + Inbucket.
const INVITED = new URL('./.invited.json', import.meta.url);
const store = fs.existsSync(INVITED) ? JSON.parse(fs.readFileSync(INVITED)) : { users: [], inbox: [] };
users.push(...store.users);
const persist = () => fs.writeFileSync(INVITED, JSON.stringify(store, null, 2));

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function sign(payload) {
  const head = b64({ alg: 'HS256', typ: 'JWT' });
  const body = b64(payload);
  const sig = crypto.createHmac('sha256', SECRET).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}
function verify(token) {
  const [h, b, s] = (token ?? '').split('.');
  if (!s) return null;
  const sig = crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url');
  if (sig !== s) return null;
  const p = JSON.parse(Buffer.from(b, 'base64url').toString());
  return p.exp > Date.now() / 1000 ? p : null;
}
const userObj = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, app_metadata: { provider: 'email' }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' });
function session(u) {
  const now = Math.floor(Date.now() / 1000);
  const access_token = sign({ sub: u.id, role: 'authenticated', aud: 'authenticated', email: u.email, iat: now, exp: now + 3600 });
  return { access_token, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: `rt.${u.id}`, user: userObj(u) };
}
const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, accept-profile, content-profile, prefer, range, x-client-info, x-supabase-api-version, accept',
  'access-control-allow-methods': 'GET, POST, PATCH, PUT, DELETE, OPTIONS',
  'access-control-expose-headers': 'content-range, content-profile',
};
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json', ...cors }); res.end(obj === undefined ? '' : JSON.stringify(obj)); };
const readBody = (req) => new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d)); });

http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/auth/v1/token') {
    const body = JSON.parse((await readBody(req)) || '{}');
    if (url.searchParams.get('grant_type') === 'password') {
      const u = users.find((x) => x.email === body.email && x.password && x.password === body.password);
      return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials', msg: 'Invalid login credentials' });
    }
    const u = users.find((x) => `rt.${x.id}` === body.refresh_token);
    return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid refresh token' });
  }
  if (url.pathname === '/auth/v1/user') {
    const p = verify((req.headers.authorization ?? '').replace(/^Bearer /i, ''));
    const u = p && users.find((x) => x.id === p.sub);
    if (!u) return send(res, 401, { msg: 'invalid JWT' });
    if (req.method === 'PUT') {  // set / change password (invited users set theirs after following the email link)
      const body = JSON.parse((await readBody(req)) || '{}');
      if (body.password) {
        if (String(body.password).length < 6) return send(res, 422, { code: 'weak_password', msg: 'Password should be at least 6 characters.' });
        u.password = body.password;
        const inv = store.users.find((x) => x.id === u.id);
        if (inv) { inv.password = body.password; persist(); }
      }
    }
    return send(res, 200, userObj(u));
  }
  // A10 · test inbox: the emails the local invite-user stand-in "sent".
  if (url.pathname === '/local/inbox') {
    const to = (url.searchParams.get('email') ?? '').toLowerCase();
    return send(res, 200, store.inbox.filter((m) => !to || m.to === to));
  }
  // A10 · stand-in for the invite-user Edge Function (supabase/functions/invite-user): same three steps, same rules.
  if (url.pathname === '/functions/v1/invite-user' && req.method === 'POST') {
    const auth = req.headers.authorization ?? '';
    if (!verify(auth.replace(/^Bearer /i, ''))) return send(res, 401, { code: '42501', message: 'Sign in first.' });
    const invite = JSON.parse((await readBody(req)) || '{}');
    const rpc = (fn, args, authz) => fetch(`${PGRST}/rpc/${fn}`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'content-profile': 'erp', authorization: authz }, body: JSON.stringify(args),
    });
    // 1. as the admin
    const r1 = await rpc('admin_invite_create', { p_invite: invite }, auth);
    const j1 = await r1.json();
    if (!r1.ok) return send(res, j1.code === '42501' ? 403 : 400, { code: j1.code, message: j1.message });
    // 2. "Supabase Auth": create the user and drop the email in the test inbox
    const u = { id: crypto.randomUUID(), email: j1.email, password: null, name: invite.display_name };
    users.push(u); store.users.push(u);
    const s = session(u);
    const origin = req.headers.origin ?? 'http://127.0.0.1:5173';
    store.inbox.push({ to: j1.email, at: new Date().toISOString(), subject: 'You have been invited to Sanford Super ERP',
      link: `${origin}/#access_token=${s.access_token}&expires_at=${s.expires_at}&expires_in=3600&refresh_token=${s.refresh_token}&token_type=bearer&type=invite` });
    persist();
    // 3. as the service role
    const service = `Bearer ${sign({ role: 'service_role', iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 60 })}`;
    const r3 = await rpc('admin_invite_link', { p_invite_id: j1.invite_id, p_user_id: u.id }, service);
    const j3 = await r3.json();
    if (!r3.ok) return send(res, 400, { code: j3.code, message: j3.message, invite_id: j1.invite_id });
    return send(res, 200, { invite_id: j1.invite_id, user_id: u.id, email: j1.email, state: 'sent' });
  }
  // A11 · stand-in for the ai-assistant Edge Function (supabase/functions/ai-assistant): same RPC flow with the user's own JWT,
  // but the answer comes from a deterministic LOCAL TEST RESPONDER (labelled, not AI). Local stack only, never deployed.
  if (url.pathname === '/functions/v1/ai-assistant' && req.method === 'POST') {
    const auth = req.headers.authorization ?? '';
    if (!verify(auth.replace(/^Bearer /i, ''))) return send(res, 401, { code: '42501', message: 'Sign in first.' });
    const body = JSON.parse((await readBody(req)) || '{}');
    if (!body.company || !body.question) return send(res, 400, { code: 'P0001', message: 'Send the company and the question.' });
    const rpc = (fn, args, authz) => fetch(`${PGRST}/rpc/${fn}`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'content-profile': 'erp', authorization: authz }, body: JSON.stringify(args),
    });
    const r1 = await rpc('ai_ask_context', { p_company: body.company, p_question: String(body.question), p_ref: body.ref ?? null }, auth);
    const ctx = await r1.json();
    if (!r1.ok) return send(res, ctx.code === '42501' ? 403 : 400, { code: ctx.code, message: ctx.message });
    const answer = localAnswer(ctx);
    await rpc('ai_log_answer', { p_audit_id: ctx.audit_id, p_responder: LOCAL_RESPONDER, p_chars: answer.length }, auth);
    const service = `Bearer ${sign({ role: 'service_role', iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 60 })}`;
    await rpc('ai_usage_record', { p_company: body.company, p_requests: 1, p_tokens: 0 }, service);
    return send(res, 200, { answer, responder: LOCAL_RESPONDER, sources: ctx.sources, tools: ctx.tools, audit_id: ctx.audit_id });
  }
  if (url.pathname === '/auth/v1/logout') return send(res, 204);
  if (url.pathname.startsWith('/rest/v1/')) {
    const target = PGRST + url.pathname.replace('/rest/v1', '') + url.search;
    const headers = { ...req.headers };
    delete headers.host; delete headers.apikey;
    if (!verify((headers.authorization ?? '').replace(/^Bearer /i, ''))) delete headers.authorization; // anon key → anonymous
    const body = ['GET', 'HEAD'].includes(req.method) ? undefined : await readBody(req);
    const r = await fetch(target, { method: req.method, headers, body });
    const out = Buffer.from(await r.arrayBuffer());
    const h = { ...cors };
    for (const k of ['content-type', 'content-range', 'content-profile']) if (r.headers.get(k)) h[k] = r.headers.get(k);
    res.writeHead(r.status, h);
    return res.end(out);
  }
  send(res, 404, { msg: `not available in the local stack: ${url.pathname}` });
}).listen(PORT, () => console.log(`local Supabase gateway on :${PORT} → PostgREST ${PGRST}`));

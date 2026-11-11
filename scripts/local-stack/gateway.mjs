// Local stand-in for the Supabase API, for development and browser tests only.
// /rest/v1/* is proxied to a local PostgREST (real Postgres, real RLS from supabase/sql/10-15).
// /functions/v1/sana runs the Sana assistant (basic mode unless ANTHROPIC_API_KEY is set).
// /auth/v1/* issues HS256 JWTs for the test users in users.json (never real users or passwords).
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const PORT = Number(process.env.GATEWAY_PORT ?? 54321);
const PGRST = process.env.PGRST_URL ?? 'http://127.0.0.1:3000';
const SECRET = process.env.JWT_SECRET ?? 'local-dev-secret-local-dev-secret-0001';
const users = JSON.parse(fs.readFileSync(new URL('./users.json', import.meta.url)));

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
      const u = users.find((x) => x.email === body.email && x.password === body.password);
      return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials', msg: 'Invalid login credentials' });
    }
    const u = users.find((x) => `rt.${x.id}` === body.refresh_token);
    return u ? send(res, 200, session(u)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid refresh token' });
  }
  if (url.pathname === '/auth/v1/user') {
    const p = verify((req.headers.authorization ?? '').replace(/^Bearer /i, ''));
    const u = p && users.find((x) => x.id === p.sub);
    return u ? send(res, 200, userObj(u)) : send(res, 401, { msg: 'invalid JWT' });
  }
  if (url.pathname === '/auth/v1/logout') return send(res, 204);
  // Sana: the same code as the Supabase Edge Function (supabase/functions/sana/core.ts), run by Node.
  if (url.pathname === '/functions/v1/sana' && req.method === 'POST') {
    const { handleAsk } = await import('../../supabase/functions/sana/core.ts');
    let body = null;
    try { body = JSON.parse((await readBody(req)) || 'null'); } catch { /* bad JSON → 400 from handleAsk */ }
    const r = await handleAsk(req.headers.authorization ?? null, body, {
      SUPABASE_URL: `http://127.0.0.1:${PORT}`, SUPABASE_ANON_KEY: 'local',
      ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY, SANA_MODEL: process.env.SANA_MODEL,
    });
    return send(res, r.status, r.json);
  }
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

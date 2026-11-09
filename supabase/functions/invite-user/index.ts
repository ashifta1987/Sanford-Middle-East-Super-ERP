// Supabase Edge Function: invite-user (A10 · Administration). NOT DEPLOYED by the phase build.
//
// Why a server function: creating a Supabase Auth user and sending the invitation email needs the service role key.
// That key must never be in the browser, so the app calls this function with the admin's own session instead.
//
// Flow
//   1. As the caller (their JWT): rpc erp.admin_invite_create(p_invite) → checks Administration full, validates position,
//      companies, employee link, duplicates, and records erp.user_invite (state 'pending'). Not an admin → 42501, stop.
//   2. As the service role: auth.admin.inviteUserByEmail(email, { redirectTo }) → Supabase creates the auth user and
//      sends the invitation email (local Supabase: the Inbucket/Mailpit test inbox).
//   3. As the service role: rpc erp.admin_invite_link(invite_id, user.id) → creates erp.app_user + erp.user_company.
//   If step 2 fails, the invitation stays 'pending' and the admin can cancel it in the app.
//
// Deploy (Ashif / IT, once):
//   supabase functions deploy invite-user
//   supabase secrets set APP_URL=https://<your-app-domain>
//   (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided to Edge Functions by Supabase.)
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json(405, { code: 'P0001', message: 'Use POST.' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const appUrl = Deno.env.get('APP_URL') ?? '';
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { code: '42501', message: 'Sign in first.' });

  let invite: Record<string, unknown>;
  try {
    invite = await req.json();
  } catch {
    return json(400, { code: 'P0001', message: 'Send the invitation details.' });
  }

  // 1. As the admin: the database decides whether they may invite, and validates everything.
  const asUser = createClient(url, anon, { global: { headers: { Authorization: authHeader } }, db: { schema: 'erp' } });
  const created = await asUser.rpc('admin_invite_create', { p_invite: invite });
  if (created.error) {
    const status = created.error.code === '42501' ? 403 : 400;
    return json(status, { code: created.error.code, message: created.error.message });
  }
  const { invite_id, email } = created.data as { invite_id: number; email: string };

  // 2. As the service role (server only): create the auth user and send the email.
  const admin = createClient(url, service, { auth: { persistSession: false }, db: { schema: 'erp' } });
  const sent = await admin.auth.admin.inviteUserByEmail(email, { redirectTo: appUrl || undefined, data: { invite_id } });
  if (sent.error || !sent.data.user) {
    return json(502, {
      code: 'P0001',
      message: `We couldn't send the invitation email: ${sent.error?.message ?? 'no user returned'}. The invitation is still waiting; cancel it and try again.`,
      invite_id,
    });
  }

  // 3. As the service role: create the Super ERP profile from the invitation.
  const linked = await admin.rpc('admin_invite_link', { p_invite_id: invite_id, p_user_id: sent.data.user.id });
  if (linked.error) return json(400, { code: linked.error.code, message: linked.error.message, invite_id });

  return json(200, { invite_id, user_id: sent.data.user.id, email, state: 'sent' });
});

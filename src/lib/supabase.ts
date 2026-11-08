import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

// The browser holds only the publishable (anon) key and the user's session.
// The service role / secret key lives only on the worker server.
export const supabase = createClient(url ?? 'http://localhost', anonKey ?? 'missing', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

export const SUPABASE_URL = url ?? '';

/** Every app call goes to the exposed `erp` schema. */
export const erp = () => supabase.schema('erp');

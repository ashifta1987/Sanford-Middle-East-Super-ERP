import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

// "Remember me" on the sign-in page: ticked → the session is kept in localStorage (stays signed in after the
// browser closes); not ticked → sessionStorage (signed out when the browser closes). Storage can be blocked
// (private mode, policies), so every access is guarded.
const REMEMBER_KEY = 'sf-remember';
export function setRememberMe(on: boolean) {
  try { localStorage.setItem(REMEMBER_KEY, on ? '1' : '0'); } catch { /* storage blocked */ }
}
export function getRememberMe() {
  try { return localStorage.getItem(REMEMBER_KEY) === '1'; } catch { return false; }
}
const sessionStore = {
  getItem(key: string) {
    try { return localStorage.getItem(key) ?? sessionStorage.getItem(key); } catch { return null; }
  },
  setItem(key: string, value: string) {
    try {
      const keep = getRememberMe();
      (keep ? sessionStorage : localStorage).removeItem(key);
      (keep ? localStorage : sessionStorage).setItem(key, value);
    } catch { /* storage blocked: the session lives in memory only */ }
  },
  removeItem(key: string) {
    try { localStorage.removeItem(key); sessionStorage.removeItem(key); } catch { /* ignore */ }
  },
};

// The browser holds only the publishable (anon) key and the user's session.
// The service role / secret key lives only on the worker server.
export const supabase = createClient(url ?? 'http://localhost', anonKey ?? 'missing', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage: sessionStore },
});

export const SUPABASE_URL = url ?? '';

/** Every app call goes to the exposed `erp` schema. */
export const erp = () => supabase.schema('erp');


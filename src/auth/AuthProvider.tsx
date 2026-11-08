import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { erp, supabase } from '@/lib/supabase';
import type { AppUser, Company, Position } from '@/lib/database.types';

export interface Profile {
  user: AppUser | null;
  position: Position | null;
  companies: Company[];
  modules: string[];
}

interface AuthCtx {
  session: Session | null;
  ready: boolean;
  profile: Profile | null;
  profileLoading: boolean;
  /** module 'admin' or 'it' → whole migration module */
  isMigrationAdmin: boolean;
  /** roles this user may sign (erp.migration_role_module defaults) */
  signRoles: Array<'finance' | 'it' | 'business'>;
  signOut: () => Promise<void>;
}

const Ctx = createContext<AuthCtx | null>(null);

// Mirrors erp.migration_role_module defaults in 13_migration_console.sql (the server is the authority).
const ROLE_MODULES: Record<'finance' | 'it' | 'business', string[]> = {
  finance: ['finance'],
  it: ['it', 'admin'],
  business: ['business', 'sales'],
};

async function loadProfile(userId: string): Promise<Profile> {
  const { data: user, error } = await erp().from('app_user').select('*').eq('user_id', userId).maybeSingle();
  if (error) throw error;
  if (!user) return { user: null, position: null, companies: [], modules: [] };
  const [{ data: position }, { data: uc }] = await Promise.all([
    erp().from('position').select('position_code,name,module_access').eq('position_code', user.position_code).maybeSingle(),
    erp().from('user_company').select('company_code').eq('user_id', userId),
  ]);
  const codes = (uc ?? []).map((r: { company_code: string }) => r.company_code);
  const { data: companies } = codes.length
    ? await erp().from('company').select('*').in('company_code', codes).order('company_code')
    : { data: [] as Company[] };
  return {
    user: user as AppUser,
    position: (position as Position) ?? null,
    companies: (companies as Company[]) ?? [],
    modules: (position as Position | null)?.module_access ?? [],
  };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const qc = useQueryClient();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s);
      if (!s) qc.clear();
    });
    return () => sub.subscription.unsubscribe();
  }, [qc]);

  const uid = session?.user.id;
  const profileQ = useQuery({
    queryKey: ['profile', uid],
    queryFn: () => loadProfile(uid!),
    enabled: Boolean(uid),
    staleTime: 5 * 60_000,
  });

  const value = useMemo<AuthCtx>(() => {
    const modules = profileQ.data?.modules ?? [];
    const has = (m: string) => modules.includes(m);
    return {
      session,
      ready,
      profile: profileQ.data ?? null,
      profileLoading: Boolean(uid) && profileQ.isLoading,
      isMigrationAdmin: has('admin') || has('it'),
      signRoles: (Object.keys(ROLE_MODULES) as Array<keyof typeof ROLE_MODULES>).filter((r) => ROLE_MODULES[r].some(has)),
      signOut: async () => { await supabase.auth.signOut(); },
    };
  }, [session, ready, profileQ.data, profileQ.isLoading, uid]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth() {
  const v = useContext(Ctx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}

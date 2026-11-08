import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { useAuth } from '@/auth/AuthProvider';

/** Selected company in the top bar. 'GRP' = all companies the user can see. */
interface CompanyCtx { company: string; setCompany: (c: string) => void }
const Ctx = createContext<CompanyCtx>({ company: 'GRP', setCompany: () => {} });

export function CompanyProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth();
  const [company, setCompanyState] = useState<string>(() => localStorage.getItem('company') ?? 'GRP');

  useEffect(() => {
    const codes = profile?.companies.map((c) => c.company_code) ?? [];
    if (profile && company !== 'GRP' && !codes.includes(company)) setCompanyState('GRP');
  }, [profile, company]);

  const setCompany = (c: string) => {
    localStorage.setItem('company', c);
    setCompanyState(c);
  };
  return <Ctx.Provider value={{ company, setCompany }}>{children}</Ctx.Provider>;
}

export const useCompany = () => useContext(Ctx);


import { useEffect, useId, useRef, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Bell, Menu, Moon, Search, Sun, LogOut } from 'lucide-react';
import { SanaMark } from '@/features/sana/SanaMark';
import { useSana } from '@/features/sana/SanaProvider';
import { useAuth } from '@/auth/AuthProvider';
import { useTheme } from '@/theme/ThemeProvider';
import { useCompany } from './CompanyContext';
import { LanguageToggle } from './LanguageToggle';
import { ChangePassword } from './ChangePassword';

export function TopBar({ onMenu }: { onMenu: () => void }) {
  const { t } = useTranslation();
  const { profile, signOut } = useAuth();
  const { company, setCompany } = useCompany();
  const { theme, toggle } = useTheme();
  const sana = useSana();
  const nav = useNavigate();
  const loc = useLocation();
  const selectId = useId();
  const searchRef = useRef<HTMLInputElement>(null);
  const [q, setQ] = useState('');
  const companies = profile?.companies ?? [];
  const current = companies.find((c) => c.company_code === company);
  const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform);

  // Ctrl+K / ⌘K focuses the search box from anywhere.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); searchRef.current?.focus(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  useEffect(() => { if (loc.pathname === '/search') setQ(new URLSearchParams(loc.search).get('q') ?? ''); }, [loc]);

  return (
    <header className="sticky top-0 z-20 flex items-center gap-2 sm:gap-3 border-b border-line bg-surface/95 px-4 py-3 backdrop-blur lg:px-6">
      <button type="button" onClick={onMenu} className="grid h-11 w-11 shrink-0 place-items-center rounded-btn border border-line lg:hidden" aria-label={t('nav.openMenu')}>
        <Menu className="h-5 w-5" aria-hidden />
      </button>

      <div className="relative flex min-h-[44px] min-w-0 items-center gap-3 rounded-btn border border-line px-3 sm:w-[280px]">
        <span className="rounded-md bg-ink px-1.5 py-0.5 text-xs font-bold text-surface">{current?.company_code ?? 'GRP'}</span>
        <div className="hidden min-w-0 flex-1 sm:block">
          <div className="truncate text-sm font-medium">{current?.legal_name ?? t('top.allCompanies')}</div>
          <div className="truncate text-xs text-muted">
            {current ? `${current.is_parent ? t('top.parent') + ' · ' : ''}${current.currency}` : t('top.companiesSummary', { count: companies.length })}
          </div>
        </div>
        <label htmlFor={selectId} className="sr-only">{t('top.company')}</label>
        <select id={selectId} value={company} onChange={(e) => setCompany(e.target.value)} className="absolute inset-0 cursor-pointer opacity-0">
          <option value="GRP">{t('top.allCompanies')}</option>
          {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.legal_name}</option>)}
        </select>
      </div>

      <form role="search" className="hidden flex-1 md:block" onSubmit={(e) => { e.preventDefault(); if (q.trim()) nav(`/search?q=${encodeURIComponent(q.trim())}`); }}>
        <label className="flex min-h-[44px] items-center gap-2 rounded-btn bg-page px-3 text-muted focus-within:ring-1 focus-within:ring-primary">
          <Search className="h-4 w-4 shrink-0" aria-hidden />
          <span className="sr-only">{t('top.search')}</span>
          <input ref={searchRef} type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('top.search')} className="w-full bg-transparent text-ink outline-none placeholder:text-muted" />
          <kbd className="hidden whitespace-nowrap rounded border border-line px-1.5 text-[11px] text-muted lg:inline">{isMac ? '⌘K' : 'Ctrl K'}</kbd>
        </label>
      </form>

      <div className="ms-auto flex items-center gap-1.5 sm:gap-2">
        <Link to="/search" className="grid h-11 w-11 place-items-center rounded-btn border border-line md:hidden" aria-label={t('top.search')}>
          <Search className="h-5 w-5" aria-hidden />
        </Link>
        <button type="button" onClick={() => sana.setOpen(true)} title={`${t('sana.ask')} (${isMac ? '⌘J' : 'Ctrl J'})`}
          className="hidden min-h-[44px] items-center gap-2 rounded-btn border border-primary-line bg-primary-soft px-3 text-sm font-semibold text-primary-text hover:border-primary sm:inline-flex">
          <SanaMark className="h-6 w-6" /> {t('sana.ask')}
        </button>
        <Link to="/approvals" className="hidden h-11 w-11 place-items-center sm:grid rounded-btn border border-line" aria-label={t('nav.approvals')} title={t('nav.approvals')}>
          <Bell className="h-5 w-5" aria-hidden />
        </Link>
        <button type="button" onClick={toggle} className="grid h-11 w-11 place-items-center rounded-btn border border-line" aria-label={theme === 'dark' ? t('top.light') : t('top.dark')} title={theme === 'dark' ? t('top.light') : t('top.dark')}>
          {theme === 'dark' ? <Sun className="h-5 w-5" aria-hidden /> : <Moon className="h-5 w-5" aria-hidden />}
        </button>
        <LanguageToggle />
        <span className="max-sm:hidden"><ChangePassword /></span>
        <button type="button" onClick={signOut} className="grid h-11 w-11 place-items-center rounded-btn border border-line" aria-label={t('top.signOut')} title={t('top.signOut')}>
          <LogOut className="h-5 w-5 rtl:rotate-180" aria-hidden />
        </button>
      </div>
    </header>
  );
}

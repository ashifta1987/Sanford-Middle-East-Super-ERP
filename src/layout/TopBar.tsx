import { useId } from 'react';
import { useTranslation } from 'react-i18next';
import { Bell, Menu, Mic, Search, LogOut } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from './CompanyContext';
import { LanguageToggle } from './LanguageToggle';

export function TopBar({ onMenu }: { onMenu: () => void }) {
  const { t } = useTranslation();
  const { profile, signOut } = useAuth();
  const { company, setCompany } = useCompany();
  const selectId = useId();
  const companies = profile?.companies ?? [];
  const current = companies.find((c) => c.company_code === company);

  return (
    <header className="flex items-center gap-3 border-b border-line bg-white px-4 py-3 lg:px-6">
      <button type="button" onClick={onMenu} className="grid h-11 w-11 place-items-center rounded-btn border border-line lg:hidden" aria-label={t('nav.openMenu')}>
        <Menu className="h-5 w-5" aria-hidden />
      </button>

      <div className="relative flex min-h-[44px] min-w-0 items-center gap-3 rounded-btn border border-line px-3 sm:w-[300px]">
        <span className="rounded-md bg-ink px-1.5 py-0.5 text-xs font-bold text-white">{current?.company_code ?? 'GRP'}</span>
        <div className="hidden min-w-0 flex-1 sm:block">
          <div className="truncate text-sm font-medium">{current?.legal_name ?? t('top.allCompanies')}</div>
          <div className="truncate text-xs text-muted">
            {current
              ? `${current.is_parent ? t('top.parent') + ' · ' : ''}${current.currency}`
              : t('top.companiesSummary', { count: companies.length })}
          </div>
        </div>
        <label htmlFor={selectId} className="sr-only">{t('top.company')}</label>
        <select
          id={selectId}
          value={company}
          onChange={(e) => setCompany(e.target.value)}
          className="absolute inset-0 cursor-pointer opacity-0"
        >
          <option value="GRP">{t('top.allCompanies')}</option>
          {companies.map((c) => (
            <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.legal_name}</option>
          ))}
        </select>
      </div>

      <div className="hidden flex-1 md:block">
        <label className="flex min-h-[44px] items-center gap-2 rounded-btn bg-page px-3 text-muted">
          <Search className="h-4 w-4" aria-hidden />
          <span className="sr-only">{t('top.search')}</span>
          <input type="search" placeholder={t('top.search')} className="w-full bg-transparent text-ink outline-none placeholder:text-muted" />
        </label>
      </div>

      <div className="ms-auto flex items-center gap-2">
        <button type="button" className="hidden min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 font-medium text-white sm:inline-flex">
          <Mic className="h-4 w-4" aria-hidden /> {t('top.ask')}
        </button>
        <button type="button" className="grid h-11 w-11 place-items-center rounded-btn border border-line" aria-label={t('top.notifications')}>
          <Bell className="h-5 w-5" aria-hidden />
        </button>
        <LanguageToggle />
        <button type="button" onClick={signOut} className="grid h-11 w-11 place-items-center rounded-btn border border-line" aria-label={t('top.signOut')} title={t('top.signOut')}>
          <LogOut className="h-5 w-5 rtl:rotate-180" aria-hidden />
        </button>
      </div>
    </header>
  );
}


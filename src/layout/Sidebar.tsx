import { NavLink, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { MODULES, canOpenModule, DOC_KINDS } from '@/features/erp/modules';
import { ModuleIcon } from '@/features/erp/icons';
import { Logo } from '@/brand/Logo';

/** Which module a working screen belongs to, so the module stays highlighted on its list and detail pages. */
function moduleOfPath(p: string): string | undefined {
  if (p.startsWith('/m/')) return p.split('/')[2];
  if (p.startsWith('/docs/')) return DOC_KINDS[p.split('/')[2] as keyof typeof DOC_KINDS]?.module;
  if (p.startsWith('/bp')) return 'bp';
  if (p.startsWith('/items') || p.startsWith('/inventory')) return 'inventory';
  if (p.startsWith('/financials')) return 'financials';
  if (p.startsWith('/banking')) return 'banking';
  if (p.startsWith('/hr')) return 'hr';
  if (p.startsWith('/backoffice')) return 'administration';
  if (p.startsWith('/preview')) return new URLSearchParams(window.location.search).get('from') ?? 'administration';
  return undefined;
}

function Item({ to, label, icon, active, onNavigate, num }: { to: string; label: string; icon: string; active?: boolean; onNavigate?: () => void; num?: string }) {
  return (
    <li>
      <NavLink
        to={to}
        end={to === '/'}
        onClick={onNavigate}
        className={({ isActive }) =>
          clsx(
            'relative flex min-h-[40px] items-center gap-3 rounded-btn px-3 text-[14px] transition-colors',
            isActive || active
              ? 'bg-side-active font-semibold text-side-active-text before:absolute before:inset-y-2 before:start-0 before:w-[3px] before:rounded-full before:bg-brand-teal'
              : 'text-side-text hover:bg-side-hover hover:text-white',
          )
        }
      >
        <ModuleIcon name={icon} className="h-[18px] w-[18px] shrink-0" />
        <span className="min-w-0 flex-1 truncate">{label}</span>
        {num && <span className="num text-[11px] text-side-muted">{num}</span>}
      </NavLink>
    </li>
  );
}

export function Sidebar({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const loc = useLocation();
  const name = profile?.user?.display_name ?? '—';
  const initials = name.split(/\s+/).map((p) => p[0]).slice(0, 2).join('').toUpperCase();
  const companyCount = profile?.companies.length ?? 0;
  const mods = MODULES.filter((m) => canOpenModule(m, profile?.modules ?? []));
  const current = moduleOfPath(loc.pathname);

  return (
    <>
      {open && <div className="fixed inset-0 z-30 bg-black/40 lg:hidden" onClick={onClose} aria-hidden />}
      <aside
        className={clsx(
          'fixed inset-y-0 start-0 z-40 flex w-[248px] shrink-0 flex-col border-e border-side-line bg-side transition-transform lg:sticky lg:top-0 lg:h-screen',
          !open && 'max-lg:ltr:-translate-x-full max-lg:rtl:translate-x-full',
        )}
        aria-label={t('nav.main')}
      >
        <div className="flex items-center justify-between px-5 py-4">
          <NavLink to="/" onClick={onClose} aria-label={t('app.name')} className="rounded-btn"><Logo size="sm" tone="light" /></NavLink>
          <button type="button" onClick={onClose} className="grid h-11 w-11 place-items-center rounded-btn text-side-text hover:bg-side-hover lg:hidden" aria-label={t('nav.closeMenu')}>
            <X className="h-5 w-5" aria-hidden />
          </button>
        </div>
        <nav className="flex-1 overflow-y-auto px-3 pb-3">
          <ul className="space-y-0.5">
            <Item to="/" label={t('nav.home')} icon="home" onNavigate={onClose} />
          </ul>
          {mods.length > 0 && <h2 className="px-3 pb-1 pt-4 text-[11px] font-semibold uppercase tracking-wider text-side-muted">{t('nav.modules')}</h2>}
          <ul className="space-y-0.5">
            {mods.map((m) => <Item key={m.key} to={`/m/${m.key}`} label={m.title} icon={m.key} num={m.num} active={current === m.key} onNavigate={onClose} />)}
          </ul>
          <h2 className="px-3 pb-1 pt-4 text-[11px] font-semibold uppercase tracking-wider text-side-muted">{t('nav.oversight')}</h2>
          <ul className="space-y-0.5">
            <Item to="/control" label={t('nav.control')} icon="control" onNavigate={onClose} />
            <Item to="/approvals" label={t('nav.approvals')} icon="approvals" onNavigate={onClose} />
          </ul>
        </nav>
        <div className="mx-3 mb-4 flex items-center gap-3 border-t border-side-line px-2 pt-4">
          <span className="grid h-9 w-9 place-items-center rounded-full bg-brand-teal/20 text-sm font-semibold text-white" aria-hidden>{initials}</span>
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-white">{name}</div>
            <div className="truncate text-xs text-side-muted">
              {profile?.position?.name ?? ''}{companyCount ? ` · ${t('top.companiesSummary', { count: companyCount })}` : ''}
            </div>
          </div>
        </div>
      </aside>
    </>
  );
}

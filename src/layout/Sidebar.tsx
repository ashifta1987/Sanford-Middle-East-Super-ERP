import { NavLink } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import {
  Home, User, Inbox, Tag, MapPin, Calculator, Box, Truck, ShieldCheck, ShoppingCart, Megaphone, Users, FolderOpen, X,
} from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';

const groupItems = [
  { to: '/', key: 'dashboard', icon: Home, end: true },
  { to: '/my-hr', key: 'myHr', icon: User },
  { to: '/approvals', key: 'approvals', icon: Inbox },
];
const moduleItems = [
  { to: '/sales', key: 'sales', icon: Tag },
  { to: '/field', key: 'field', icon: MapPin },
  { to: '/accountant', key: 'accountant', icon: Calculator },
  { to: '/warehouses', key: 'warehouses', icon: Box },
  { to: '/logistics', key: 'logistics', icon: Truck },
  { to: '/quality', key: 'quality', icon: ShieldCheck },
  { to: '/purchase', key: 'purchase', icon: ShoppingCart },
  { to: '/marketing', key: 'marketing', icon: Megaphone },
  { to: '/hr', key: 'hr', icon: Users },
  { to: '/backoffice', key: 'backoffice', icon: FolderOpen },
];

function Item({ to, label, Icon, end, onNavigate }: { to: string; label: string; Icon: typeof Home; end?: boolean; onNavigate?: () => void }) {
  return (
    <li>
      <NavLink
        to={to}
        end={end}
        onClick={onNavigate}
        className={({ isActive }) =>
          clsx(
            'flex min-h-[44px] items-center gap-3 rounded-btn px-3 text-[15px]',
            isActive ? 'bg-primary-soft font-semibold text-primary' : 'text-ink hover:bg-page',
          )
        }
      >
        <Icon className="h-[18px] w-[18px] shrink-0" aria-hidden />
        {label}
      </NavLink>
    </li>
  );
}

export function Sidebar({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { t } = useTranslation();
  const { profile, isMigrationAdmin } = useAuth();
  const name = profile?.user?.display_name ?? '—';
  const initials = name.split(/\s+/).map((p) => p[0]).slice(0, 2).join('').toUpperCase();
  const companyCount = profile?.companies.length ?? 0;
  // Back office houses the admin modules; hide it for users without admin/IT.
  const modules = moduleItems.filter((m) => m.key !== 'backoffice' || isMigrationAdmin);

  return (
    <>
      {open && <div className="fixed inset-0 z-30 bg-black/30 lg:hidden" onClick={onClose} aria-hidden />}
      <aside
        className={clsx(
          'fixed inset-y-0 start-0 z-40 flex w-[240px] flex-col border-e border-line bg-white transition-transform lg:static lg:translate-x-0',
          open ? 'translate-x-0' : 'ltr:-translate-x-full rtl:translate-x-full',
        )}
        aria-label="Main"
      >
        <div className="flex items-center justify-between px-5 py-5">
          <div className="flex items-center gap-3">
            <span className="grid h-9 w-9 place-items-center rounded-btn bg-primary font-semibold text-white" aria-hidden>S</span>
            <div>
              <div className="font-semibold leading-tight">{t('app.name')}</div>
              <div className="text-xs text-muted">{t('app.group')}</div>
            </div>
          </div>
          <button type="button" onClick={onClose} className="grid h-11 w-11 place-items-center rounded-btn hover:bg-page lg:hidden" aria-label={t('nav.closeMenu')}>
            <X className="h-5 w-5" aria-hidden />
          </button>
        </div>
        <nav className="flex-1 overflow-y-auto px-3">
          <h2 className="px-3 pb-1 pt-2 text-xs font-semibold uppercase tracking-wider text-muted">{t('nav.group')}</h2>
          <ul className="space-y-0.5">
            {groupItems.map((i) => <Item key={i.key} to={i.to} end={i.end} label={t(`nav.${i.key}`)} Icon={i.icon} onNavigate={onClose} />)}
          </ul>
          <h2 className="px-3 pb-1 pt-5 text-xs font-semibold uppercase tracking-wider text-muted">{t('nav.modules')}</h2>
          <ul className="space-y-0.5">
            {modules.map((i) => <Item key={i.key} to={i.to} label={t(`nav.${i.key}`)} Icon={i.icon} onNavigate={onClose} />)}
          </ul>
        </nav>
        <div className="mx-3 mb-4 flex items-center gap-3 border-t border-line px-2 pt-4">
          <span className="grid h-9 w-9 place-items-center rounded-full bg-primary-soft text-sm font-semibold text-primary" aria-hidden>{initials}</span>
          <div className="min-w-0">
            <div className="truncate text-sm font-medium">{name}</div>
            <div className="truncate text-xs text-muted">
              {profile?.position?.name ?? ''}{companyCount ? ` · ${t('top.companiesSummary', { count: companyCount })}` : ''}
            </div>
          </div>
        </div>
      </aside>
    </>
  );
}

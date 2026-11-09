import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Lock } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { canOpenModule, canWriteModule, moduleByKey, type ModuleKey } from '../modules';

export function useModuleAccess() {
  const { profile } = useAuth();
  const mods = profile?.modules ?? [];
  return (k: ModuleKey) => {
    const m = moduleByKey(k);
    return Boolean(m && canOpenModule(m, mods));
  };
}

/**
 * 'full' / 'read' / null for an app module, from the position's levels (16_module_access.sql).
 * With 'read', screens hide or disable New, Edit and Approve and show readOnlyReason.
 */
export function useModuleLevel(k: ModuleKey) {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const m = moduleByKey(k);
  const open = Boolean(m && canOpenModule(m, profile?.modules ?? []));
  const write = Boolean(m && canWriteModule(m, profile?.levels ?? {}));
  const level: 'full' | 'read' | null = write ? 'full' : open ? 'read' : null;
  return { level, canWrite: write, readOnlyReason: level === 'read' ? t('erp.readOnly', { module: m?.title ?? k }) : undefined };
}

/** Hides a screen from users whose position does not include the module. The database rules still apply on top. */
export function RequireModule({ module, children }: { module: ModuleKey; children: ReactNode }) {
  const { t } = useTranslation();
  const can = useModuleAccess();
  const m = moduleByKey(module);
  if (can(module)) return <>{children}</>;
  return (
    <div className="card mx-auto mt-10 max-w-lg p-8 text-center" role="alert">
      <Lock className="mx-auto h-10 w-10 text-muted" aria-hidden />
      <h1 className="mt-3 text-2xl font-semibold">{t('access.title')}</h1>
      <p className="mt-2 text-muted">{t('erp.noModule', { module: m?.title ?? module })}</p>
      <Link to="/" className="mt-5 inline-flex min-h-[44px] items-center rounded-btn border border-line px-4 font-medium hover:bg-page">{t('access.home')}</Link>
    </div>
  );
}

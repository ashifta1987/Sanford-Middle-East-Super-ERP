import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Lock, Construction } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';

export function NoAccessPage() {
  const { t } = useTranslation();
  const { profile } = useAuth();
  return (
    <div className="card mx-auto mt-10 max-w-lg p-8 text-center">
      <Lock className="mx-auto h-10 w-10 text-muted" aria-hidden />
      <h1 className="mt-3 text-2xl font-semibold">{t('access.title')}</h1>
      <p className="mt-2 text-muted">{profile && !profile.user ? t('auth.noProfile') : t('access.body')}</p>
      <Link to="/" className="mt-5 inline-flex min-h-[44px] items-center rounded-btn border border-line px-4 font-medium hover:bg-page">{t('access.home')}</Link>
    </div>
  );
}

export function PlaceholderPage({ nameKey }: { nameKey: string }) {
  const { t } = useTranslation();
  const name = t(nameKey);
  return (
    <div className="space-y-4">
      <h1 className="text-[28px] font-semibold">{name}</h1>
      <div className="card flex flex-col items-center gap-2 p-10 text-center text-muted">
        <Construction className="h-8 w-8" aria-hidden />
        <p className="font-medium text-ink">{t('placeholder.soon')}</p>
        <p className="text-sm">{t('placeholder.body', { name })}</p>
      </div>
    </div>
  );
}


import { Loader2, Inbox, AlertTriangle } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button } from './Button';
import { errorMessage } from '@/lib/format';

export function PageLoading() {
  const { t } = useTranslation();
  return (
    <div role="status" aria-live="polite" className="flex min-h-[40vh] items-center justify-center gap-2 text-muted">
      <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> {t('app.loading')}
    </div>
  );
}

export function SkeletonRows({ rows = 5 }: { rows?: number }) {
  return (
    <div role="status" aria-busy="true" className="space-y-2 p-4">
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="h-6 animate-pulse rounded bg-neutral-bg" />
      ))}
    </div>
  );
}

export function EmptyState({ title, body }: { title?: string; body?: string }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col items-center justify-center gap-2 p-8 text-center text-muted">
      <Inbox className="h-8 w-8" aria-hidden />
      <p className="font-medium text-ink">{title ?? t('app.empty')}</p>
      {body && <p className="max-w-md text-sm">{body}</p>}
    </div>
  );
}

export function ErrorState({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const { t } = useTranslation();
  return (
    <div role="alert" className="flex flex-col items-center justify-center gap-3 p-8 text-center">
      <AlertTriangle className="h-8 w-8 text-crit-fg" aria-hidden />
      <p className="text-ink">{errorMessage(error)}</p>
      {onRetry && <Button onClick={onRetry}>{t('app.retry')}</Button>}
    </div>
  );
}

import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ChevronRight, Eye } from 'lucide-react';
import i18n from '@/lib/i18n';

const money = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const qty = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 });
export const fmtMoney = (n: unknown, cur?: string | null) =>
  n === null || n === undefined || n === '' ? '—' : `${money.format(Number(n))}${cur ? ` ${cur}` : ''}`;
export const fmtQty = (n: unknown) => (n === null || n === undefined || n === '' ? '—' : qty.format(Number(n)));
export const fmtDay = (iso: unknown) =>
  !iso ? '—' : new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(String(iso)));

const STATUS_TONE: Record<string, string> = {
  open: 'pill-info', closed: 'pill-neutral', cancelled: 'pill-crit', draft: 'pill-neutral', pending: 'pill-warning',
  approved: 'pill-ok', rejected: 'pill-crit', active: 'pill-ok', inactive: 'pill-neutral', critical: 'pill-crit', warning: 'pill-warning',
};
export function StatusTag({ value }: { value: string | null | undefined }) {
  const { t } = useTranslation();
  if (!value) return <span className="text-muted">—</span>;
  return <span className={clsx('pill', STATUS_TONE[value] ?? 'pill-neutral')}>{t(`erp.status.${value}`, { defaultValue: value })}</span>;
}

export function YesNo({ value }: { value: unknown }) {
  const { t } = useTranslation();
  return value ? <span className="pill pill-ok">{t('erp.yes')}</span> : <span className="pill pill-neutral">{t('erp.no')}</span>;
}

/** Marks what the user is looking at: connected to the database, or a design preview with sample content. */
export function LiveBadge({ live }: { live: boolean }) {
  const { t } = useTranslation();
  return live
    ? <span className="pill pill-ok">{t('erp.liveData')}</span>
    : <span className="pill pill-neutral"><Eye className="me-1 h-3 w-3" aria-hidden />{t('erp.designPreview')}</span>;
}

export function Crumbs({ items }: { items: Array<[string, string | undefined]> }) {
  return (
    <nav aria-label="Breadcrumb" className="mb-2 flex flex-wrap items-center gap-1 text-sm text-muted">
      {items.map(([label, to], i) => (
        <span key={i} className="inline-flex items-center gap-1">
          {i > 0 && <ChevronRight className="h-3.5 w-3.5 rtl:rotate-180" aria-hidden />}
          {to ? <Link to={to} className="hover:text-primary hover:underline">{label}</Link> : <span className="text-ink-2">{label}</span>}
        </span>
      ))}
    </nav>
  );
}

export function PageTitle({ eyebrow, title, desc, actions, crumbs }: { eyebrow?: ReactNode; title: ReactNode; desc?: ReactNode; actions?: ReactNode; crumbs?: Array<[string, string | undefined]> }) {
  return (
    <header className="mb-6">
      {crumbs && <Crumbs items={crumbs} />}
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="min-w-0">
          {eyebrow && <div className="eyebrow mb-1">{eyebrow}</div>}
          <h1 dir="auto" className="text-[26px] font-semibold leading-tight sm:text-[28px]">{title}</h1>
          {desc && <p dir="auto" className="mt-1 max-w-3xl text-[15px] text-muted">{desc}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </div>
    </header>
  );
}

/** Label / value grid for detail screens. */
export function Fields({ items }: { items: Array<[string, ReactNode]> }) {
  return (
    <dl className="grid grid-cols-1 gap-x-6 gap-y-3 p-5 sm:grid-cols-2 lg:grid-cols-3">
      {items.map(([k, v]) => (
        <div key={k} className="min-w-0">
          <dt className="text-xs font-medium text-muted">{k}</dt>
          <dd className="mt-0.5 break-words text-[15px] text-ink">{v === null || v === undefined || v === '' ? '—' : v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function SectionCard({ title, right, children, className }: { title?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={clsx('card overflow-hidden', className)}>
      {(title || right) && (
        <div className="flex items-center justify-between gap-3 border-b border-line px-5 py-3">
          <h2 className="text-[15px] font-semibold">{title}</h2>
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Kpi({ label, value, sub, to, tone }: { label: string; value: ReactNode; sub?: ReactNode; to?: string; tone?: 'crit' | 'warn' }) {
  const body = (
    <>
      <div className="text-sm text-muted">{label}</div>
      <div className={clsx('num mt-1 text-[26px] font-semibold leading-tight', tone === 'crit' && 'text-crit-fg', tone === 'warn' && 'text-warn-fg')}>{value}</div>
      {sub && <div className="num mt-1 text-sm text-ink-2">{sub}</div>}
    </>
  );
  return to
    ? <Link to={to} className="card block p-5 transition hover:border-primary-line">{body}</Link>
    : <div className="card p-5">{body}</div>;
}

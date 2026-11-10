import { useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { Hash } from 'lucide-react';
import { seriesProblem, useSeriesOptions } from '../numbering';

/**
 * B1 · Series picker for a new document (SAP B1 "Series" field). Defaults to the user's default series, else the company
 * default. With a single series it shows the next number only. The database checks the series again when the document
 * is saved (locked, period, warehouse, last number).
 */
export function SeriesPicker({ company, obj, value, onChange, date, whs, id = 'series-picker', className, hideWhenNone, label }: {
  company: string; obj: number; value: number | null; onChange: (v: number | null) => void;
  date?: string | null; whs?: string | null; id?: string; className?: string;
  /** Item codes: no series = codes are typed by hand, so show nothing. */
  hideWhenNone?: boolean; label?: string;
}) {
  const { t } = useTranslation();
  const q = useSeriesOptions(company, obj);
  const opts = q.data?.series ?? [];
  const defaultId = q.data?.default_id ?? null;

  // Pick the default once the options arrive, and again when the company changes.
  useEffect(() => {
    if (!q.data) return;
    if (value === null || !opts.some((o) => o.series_id === value)) onChange(defaultId ?? opts[0]?.series_id ?? null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q.data, company]);

  if (!company || company === 'GRP' || (hideWhenNone && !q.isLoading && opts.length === 0)) return null;
  const chosen = opts.find((o) => o.series_id === value);
  const problem = chosen ? seriesProblem(chosen, date, whs) : null;
  return (
    <div className={className} data-testid="series-picker" data-obj={obj}>
      <label htmlFor={id} className="block text-xs font-medium text-muted">{label ?? t('num.pick.label')}</label>
      {q.isLoading ? <div className="mt-1 h-11 animate-pulse rounded-btn bg-surface-2" />
        : opts.length === 0 ? (
          <p className="mt-1 rounded-btn border border-warn-fg/30 bg-warn-bg px-3 py-2.5 text-sm text-warn-fg" data-testid="series-none">{t('num.pick.none')}</p>
        ) : opts.length === 1 ? (
          <p className="mt-1 flex min-h-[44px] items-center gap-2 text-[15px]" id={id}>
            <Hash className="h-4 w-4 text-muted" aria-hidden />
            <span className="font-mono text-[13px]" dir="ltr">{opts[0].example ?? '—'}</span>
            <span className="text-xs text-muted" dir="auto">· {opts[0].name}</span>
          </p>
        ) : (
          <select id={id} className="input mt-1 text-[15px] text-ink" value={value ?? ''} onChange={(e) => onChange(e.target.value ? Number(e.target.value) : null)}>
            {opts.map((o) => {
              const p = seriesProblem(o, date, whs);
              return (
                <option key={o.series_id} value={o.series_id} disabled={p === 'full'}>
                  {o.name} · {o.example ?? '—'}{o.series_id === q.data?.mine ? ` (${t('num.pick.mine')})` : o.is_default ? ` (${t('num.pick.default')})` : ''}{p ? ` — ${t(`num.pick.problem.${p}`)}` : ''}
                </option>
              );
            })}
          </select>
        )}
      {problem && <p className="mt-1 text-xs text-warn-fg" data-testid="series-problem">{t(`num.pick.problemLong.${problem}`, { whs: chosen?.whs_code ?? '', from: chosen?.period_from ?? '…', to: chosen?.period_to ?? '…' })}</p>}
    </div>
  );
}

import { useTranslation } from 'react-i18next';
import { AlertTriangle } from 'lucide-react';
import { fmtDay } from './ui';
import { currencyChoices, defaultCurrency, fmtRate, useLocalCurrency, useRate } from '../currency';

/**
 * Currency + exchange rate fields of a document or payment form (B4).
 * - currency: the partner's fixed currency or LC; partners with '##' (all currencies) may pick any currency of the rates list.
 * - rate: the posting date's rate from Exchange Rates. Only Financials may type another rate; copies that keep the base
 *   document's rate show it read-only (keepRate). The server checks all of this again.
 */
export function CurrencyFields({
  company, date, bpCurrency, currency, onCurrency, rate, onRate, idPrefix = 'doc', locked, keepRate, errors,
}: {
  company: string; date: string; bpCurrency?: string | null; currency: string; onCurrency?: (c: string) => void;
  rate: string; onRate?: (r: string) => void; idPrefix?: string; locked?: boolean; keepRate?: number | null;
  errors?: { currency?: string | null; fx_rate?: string | null };
}) {
  const { t } = useTranslation();
  const local = useLocalCurrency(company);
  const cur = currency || defaultCurrency(bpCurrency, local);
  const info = useRate(company || null, cur, date || null);
  const I = info.data;
  const choices = currencyChoices(bpCurrency, local, I?.currencies ?? []);
  if (!choices.includes(cur)) choices.unshift(cur);
  const fc = Boolean(cur && local && cur !== local);
  return (
    <>
      <label className="block text-xs font-medium text-muted">{t('cur.currency')}
        {locked || !onCurrency || choices.length <= 1 ? (
          <p id={`${idPrefix}-currency`} className="mt-1 flex min-h-[44px] items-center rounded-btn border border-line bg-surface-2 px-3 font-mono text-[15px] text-ink" data-testid="cur-currency">{cur || '—'}</p>
        ) : (
          <select id={`${idPrefix}-currency`} className="input mt-1 font-mono text-[15px] text-ink" value={cur} data-testid="cur-currency"
            onChange={(e) => { onCurrency(e.target.value); onRate?.(''); }} aria-invalid={Boolean(errors?.currency)}>
            {choices.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        )}
        {errors?.currency && <span className="mt-1 block text-crit-fg">{errors.currency}</span>}
        {!errors?.currency && bpCurrency === '##' && <span className="mt-1 block">{t('cur.allCurrencies')}</span>}
      </label>
      {fc && (
        <label className="block text-xs font-medium text-muted">{t('cur.rate', { local, cur })}
          {keepRate != null ? (
            <>
              <p id={`${idPrefix}-fx_rate`} className="num mt-1 flex min-h-[44px] items-center rounded-btn border border-line bg-surface-2 px-3 text-[15px] text-ink" data-testid="cur-rate">{fmtRate(keepRate)}</p>
              <span className="mt-1 block">{t('cur.kept')}</span>
            </>
          ) : I?.can_override && onRate ? (
            <>
              <input id={`${idPrefix}-fx_rate`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={rate} data-testid="cur-rate"
                placeholder={I?.rate != null ? fmtRate(I.rate) : ''} onChange={(e) => onRate(e.target.value)} aria-invalid={Boolean(errors?.fx_rate)} />
              <span className="mt-1 block">{I?.rate != null ? t('cur.listRate', { rate: fmtRate(I.rate), date: fmtDay(date) }) : I?.message}{rate !== '' && I?.rate != null && Number(rate) !== Number(I.rate) ? ` · ${t('cur.overridden')}` : ''}</span>
            </>
          ) : (
            <>
              <p id={`${idPrefix}-fx_rate`} className="num mt-1 flex min-h-[44px] items-center rounded-btn border border-line bg-surface-2 px-3 text-[15px] text-ink" data-testid="cur-rate">{I?.rate != null ? fmtRate(I.rate) : '—'}</p>
              <span className="mt-1 block">{I?.rate != null ? t('cur.listRateRo', { date: fmtDay(date) }) : null}</span>
            </>
          )}
          {(errors?.fx_rate || (I && I.rate == null && keepRate == null && I.message)) && (
            <span className="mt-1 flex items-start gap-1 text-crit-fg" data-testid="cur-no-rate"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{errors?.fx_rate ?? I?.message}</span>
          )}
        </label>
      )}
    </>
  );
}

// B4 · Multi-currency helpers for the document and payment forms.
// Conventions (as SAP): document.total / line_total / vat are local currency (LC); *_fc are the document currency (DC).
import { useQuery } from '@tanstack/react-query';
import { useAuth } from '@/auth/AuthProvider';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface RateInfo {
  currency: string; local: string; rate: number | null; date: string | null; currencies: string[]; can_override: boolean; message: string | null;
}

/** The rate (LC per 1 unit) of a currency for a posting date, plus the company's currency list and whether the user may type another rate. */
export function useRate(company: string | null | undefined, currency: string | null | undefined, date: string | null | undefined) {
  return useQuery({
    queryKey: ['fx-rate', company, currency, date],
    enabled: Boolean(company),
    staleTime: 60_000,
    queryFn: async () => {
      const { data, error } = await erp().rpc('currency_rate', { p_company: company, p_currency: currency || null, p_date: date || null });
      if (error) throw new ApiError(error);
      return data as RateInfo;
    },
  });
}

/** Company → company currency, for list rows that span companies. */
export function useLocalCurrencies() {
  const { profile } = useAuth();
  const map = new Map((profile?.companies ?? []).map((c) => [c.company_code, c.currency]));
  return (company: string | null | undefined) => (company ? map.get(company) ?? '' : '');
}

/** "3,856.13 AED · USD": lists show the local-currency total (the views carry it); a foreign document names its own currency. */
export function lcLabel(amount: unknown, docCur: string | null | undefined, local: string, fmt: (n: unknown, c?: string | null) => string) {
  if (!docCur || !local || docCur === local) return fmt(amount, docCur || local);
  return `${fmt(amount, local)} · ${docCur}`;
}

/** The company currency from the signed-in profile. */
export function useLocalCurrency(company: string | null | undefined) {
  const { profile } = useAuth();
  return profile?.companies?.find((c) => c.company_code === company)?.currency ?? '';
}

/** Currencies a partner may use: its own fixed currency and LC; '##' / none = LC + the company's rates list. */
export function currencyChoices(bpCurrency: string | null | undefined, local: string, list: string[] = []): string[] {
  const bp = (bpCurrency ?? '').toUpperCase();
  const out = bp && bp !== '##' ? [bp, local] : [local, ...list];
  return [...new Set(out.filter(Boolean))];
}

/** The partner's default document currency: its own fixed currency, else LC. */
export const defaultCurrency = (bpCurrency: string | null | undefined, local: string) =>
  bpCurrency && bpCurrency !== '##' ? bpCurrency.toUpperCase() : local;

/** Is this stored document in a foreign currency (Super ERP or SAP)? */
export const isFcDoc = (d: R | null | undefined, local: string) =>
  Boolean(d && d.currency && local && d.currency !== local && d.total_fc != null && Number(d.total_fc) !== 0);

/** A line's total in the document currency. */
export const lineAmt = (l: R, fc: boolean) => Number((fc ? l.line_total_fc ?? l.line_total : l.line_total) ?? 0);

/** total / vat_total / paid of a document in its own currency. */
export const docAmt = (d: R, key: 'total' | 'vat_total' | 'paid', fc: boolean) => Number((fc ? d[`${key}_fc`] ?? d[key] : d[key]) ?? 0);

export const fmtRate = (n: unknown) => (n === null || n === undefined || n === '' ? '—' : String(Number(n)));

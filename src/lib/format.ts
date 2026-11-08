import i18n from './i18n';

/** Postgres / PostgREST error → message for the user (P0 › Error mapping). */
export function errorMessage(err: unknown): string {
  if (!err) return i18n.t('errors.generic');
  const e = err as { code?: string; message?: string };
  if (e.code === '42501') return i18n.t('errors.denied');
  return e.message || i18n.t('errors.generic');
}

export class ApiError extends Error {
  code?: string;
  constructor(err: { code?: string; message?: string }) {
    super(errorMessage(err));
    this.code = err.code;
  }
}

const nf = new Intl.NumberFormat('en-US');
export const fmtInt = (n: number | string | null | undefined) =>
  n === null || n === undefined || n === '' ? '—' : nf.format(Number(n));

export function fmtCompact(n: number | null | undefined) {
  if (n === null || n === undefined) return '—';
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)} M`;
  return nf.format(n);
}

export function fmtBytes(b: number | null | undefined) {
  if (b === null || b === undefined) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = b;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${u[i]}`;
}

export function fmtDate(iso: string | null | undefined, opts: Intl.DateTimeFormatOptions = { day: 'numeric', month: 'short' }) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', opts).format(new Date(iso));
}

export function fmtDuration(seconds: number | null | undefined) {
  if (seconds === null || seconds === undefined) return '—';
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  if (h) return `${h} h ${m} min`;
  if (m) return `${m} min ${r} s`;
  return `${r} s`;
}


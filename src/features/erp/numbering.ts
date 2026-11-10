import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';

/** Types and calls for B1 · Document Numbering and companies (supabase/sql/30_numbering_company.sql). The database is the authority. */
export interface DocSeries {
  series_id: number; obj_type: number; name: string; prefix: string; first_num: number; next_num: number; last_num: number | null; pad: number;
  period_from: string | null; period_to: string | null; branch_id: number | null; whs_code: string | null; locked: boolean; is_default: boolean;
  remarks: string | null; used: boolean; example: string | null; left: number; users: number;
}
export interface DocType { obj_type: number; label: string; module: string; used: boolean; series: DocSeries[] }
export interface NumberingSetup {
  can_write: boolean; types: DocType[];
  users: Array<{ user_id: string; display_name: string; email: string | null; position_name: string }>;
  user_defaults: Array<{ user_id: string; obj_type: number; series_id: number }>;
  warehouses: Array<{ code: string; name: string }>; branches: Array<{ id: number; name: string }>;
}
export interface SeriesOption {
  series_id: number; name: string; prefix: string; example: string | null; period_from: string | null; period_to: string | null;
  whs_code: string | null; branch_id: number | null; is_default: boolean; full: boolean;
}
export interface SeriesOptions { obj_type: number; label: string; default_id: number | null; mine: number | null; series: SeriesOption[] }
export interface SeriesInput {
  series_id?: number | null; obj_type: number; name: string; prefix: string; first_num: string; next_num: string; last_num: string; pad: string;
  period_from: string; period_to: string; branch_id: string; whs_code: string; locked: boolean; is_default: boolean; remarks: string;
}
export interface CompanyRow {
  company_code: string; legal_name: string; short_name: string; country: string; currency: string; licence_type: string | null;
  licence_authority: string | null; tax_id: string | null; sap_schema: string | null; active: boolean; in_register: boolean; live: boolean;
  users: number; series: number; has_documents: boolean;
}

export const useNumbering = (company: string) => useQuery({
  queryKey: ['adm-numbering', company], enabled: Boolean(company), queryFn: () => rpc<NumberingSetup>('doc_numbering_setup', { p_company: company }),
});
export const seriesSave = (company: string, s: SeriesInput) => rpc<DocSeries>('doc_series_save', { p_company: company, p_s: s });
export const seriesDelete = (company: string, id: number) => rpc('doc_series_delete', { p_company: company, p_series_id: id });
export const userDefaultSave = (company: string, user: string, obj: number, series: number | null) =>
  rpc('series_user_default_save', { p_company: company, p_user: user, p_obj: obj, p_series: series });
export const useSeriesOptions = (company: string, obj: number) => useQuery({
  queryKey: ['series-options', company, obj], enabled: Boolean(company && company !== 'GRP' && obj), staleTime: 30_000,
  queryFn: () => rpc<SeriesOptions>('doc_series_options', { p_company: company, p_obj: obj }),
});

export const useCompanies = () => useQuery({ queryKey: ['adm-companies'], queryFn: () => rpc<{ can_write: boolean; companies: CompanyRow[] }>('company_list', {}) });
export const companySave = (p: Record<string, unknown>) => rpc<{ company_code: string; created: boolean; in_register: boolean }>('company_save', { p });

/** Why an option can't number a document dated `date` for warehouse `whs` (null = it can). Mirrors erp._series_problem. */
export function seriesProblem(o: SeriesOption, date?: string | null, whs?: string | null): 'period' | 'whs' | 'full' | null {
  if (o.full) return 'full';
  if (date && ((o.period_from && date < o.period_from) || (o.period_to && date > o.period_to))) return 'period';
  if (whs && o.whs_code && o.whs_code !== whs) return 'whs';
  return null;
}


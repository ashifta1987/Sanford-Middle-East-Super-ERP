import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for A8 master data (supabase/sql/23_master_data.sql). The database checks every write. */

export type BpKind = 'customer' | 'supplier' | 'lead';
export interface Code<T = number> { code: T; name: string }
export interface MdRule { rule_code: string; step: number; approver_position: string; approver_name: string; message?: string }
export interface MdSetup {
  company_currency: string; company_country: string; currencies: string[];
  bp_groups: Array<Code & { kind: 'C' | 'S' | null }>; payment_terms: Code[]; price_lists: Code[]; salespeople: Code[];
  item_groups: Array<Code & { manage_method?: 'none' | 'batch' | 'serial' | null }>; brands: Code[]; tax_codes: Array<Code<string> & { rate: number }>; uoms: string[]; sourcing_types: string[];
  bp_required: string[]; item_required: string[]; dup_name_similarity: number;
  numbering: Partial<Record<BpKind, string>> | null;
  credit_approvers: MdRule[]; bank_approvers: MdRule[];
  can_read_bp: boolean; can_read_items: boolean; can_write_bp: Record<BpKind, boolean>; can_write_items: boolean;
}
export function useMdSetup(company: string | null) {
  return useQuery({
    queryKey: ['md-setup', company], enabled: Boolean(company), staleTime: 30_000,
    queryFn: () => rpc<MdSetup>('master_data_setup', { p_company: company }),
  });
}

export interface FieldError { field: string; line?: number; message: string }
export interface BpDuplicate { card_code: string; name: string; kind: BpKind; match: 'trn' | 'phone' | 'name'; similarity: number }
export interface BpEval { is_new: boolean; errors: FieldError[]; duplicates: BpDuplicate[]; approvals: MdRule[]; values: Record<string, unknown> }
export interface Contact { name: string; role?: string | null; phone?: string | null; mobile?: string | null; email?: string | null; is_default?: boolean }
export interface Address { address_name: string; kind: 'B' | 'S'; street?: string | null; block?: string | null; building?: string | null; city?: string | null; state?: string | null; zip?: string | null; country?: string | null }

export const bpChecks = (company: string, bp: Record<string, unknown>) => rpc<BpEval>('bp_checks', { p_company: company, p_bp: bp });
export const bpSave = (company: string, bp: Record<string, unknown>, dupReason: string | null, reason: string | null, series: number | null = null) =>
  rpc<{ card_code: string; created: boolean; changed: Record<string, unknown>; credit_request: { request_id: number; state: string; approvers: MdRule[] } | null }>(
    'bp_save', { p_company: company, p_bp: bp, p_dup_reason: dupReason, p_reason: reason, p_series: series });
export const bpChangeDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: string }>('bp_change_decide', { p_company: company, p_request: id, p_decision: decision, p_note: note });
export const bpChangeCancel = (company: string, id: number, note: string | null) =>
  rpc<{ state: string }>('bp_change_cancel', { p_company: company, p_request: id, p_note: note });
export const bpBankSave = (company: string, card: string, b: Record<string, unknown>) =>
  rpc<{ bp_bank_id: number | null; change: string; request_id?: number; state?: string }>('bp_bank_account_save', { p_company: company, p_card: card, p_bank: b });

export interface MdApproval {
  approval_id: number; step: number; rule_code: string; approver_position: string; approver_position_name: string; decision: string | null; note: string | null;
  decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean; requested_by_name: string | null; requested_at: string | null;
  detail: { checks?: Array<{ message: string }> } | null; superseded: boolean; current: boolean; mine: boolean;
}
export interface BpRequest {
  request_id: number; kind: 'credit_limit' | 'bank'; bp_bank_id: number | null; before: Record<string, unknown> | null; after: Record<string, unknown> | null;
  reason: string | null; state: 'pending_approval' | 'approved' | 'rejected' | 'cancelled'; requested_at: string; requested_by_name: string | null;
  requested_by_me: boolean; decided_at: string | null; decided_by_name: string | null; note: string | null; approvals: MdApproval[];
}
export interface BankAccount { bp_bank_id: number; bank_name: string; account_no: string | null; iban: string | null; swift: string | null; holder: string | null; active: boolean; source: string; updated_at: string }
export interface HistoryRow { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface BpInfo {
  partner: Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  can_edit: boolean; edit_reason: string | null; can_bank: boolean; bank_needs_approval: boolean; credit_needs_approval: boolean;
  contacts: Array<Contact & { contact_id: number }>; addresses: Address[]; bank_accounts: BankAccount[] | null; last_bank_change: string | null;
  requests: BpRequest[]; history: HistoryRow[];
}
export function useBpInfo(company: string, code: string) {
  return useQuery({
    queryKey: ['bp-info', company, code], enabled: Boolean(company && code),
    queryFn: () => rpc<BpInfo | null>('bp_info', { p_company: company, p_card: code }),
  });
}

export interface ItemEval { is_new: boolean; errors: FieldError[]; duplicates: Array<{ item_code: string; name: string; match: string; preferred_supplier: string | null }>; values: Record<string, unknown> }
export const itemChecks = (company: string, item: Record<string, unknown>) => rpc<ItemEval>('item_checks', { p_company: company, p_item: item });
export const itemSave = (company: string, item: Record<string, unknown>, dupReason: string | null, series: number | null = null) =>
  rpc<{ item_code: string; created: boolean; changed: Record<string, unknown> }>('item_save', { p_company: company, p_item: item, p_dup_reason: dupReason, p_series: series });
export interface ItemInfo {
  item: Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  can_edit: boolean; edit_reason: string | null; history: HistoryRow[];
}
export function useItemInfo(company: string, code: string) {
  return useQuery({
    queryKey: ['item-info', company, code], enabled: Boolean(company && code),
    queryFn: () => rpc<ItemInfo | null>('item_info', { p_company: company, p_item: code }),
  });
}

/** Suppliers for the preferred-supplier combobox. */
export async function searchSuppliers(company: string, q: string) {
  const s = q.replace(/[,()*%\\:"]/g, ' ').trim();
  const { data, error } = await erp().from('business_partner').select('card_code,name,currency').eq('company_code', company).eq('kind', 'supplier')
    .or(`card_code.ilike.*${s}*,name.ilike.*${s}*`).order('card_code').limit(20);
  if (error) throw new ApiError(error);
  return (data ?? []) as Array<{ card_code: string; name: string; currency: string | null }>;
}

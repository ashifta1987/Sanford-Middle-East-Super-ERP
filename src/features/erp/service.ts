import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for A13 service (supabase/sql/28_production_service.sql). The database checks every write. */

export type CallStatus = 'open' | 'in_progress' | 'resolved' | 'closed' | 'cancelled';
export type WarrantyStatus = 'in_warranty' | 'out_of_warranty' | 'contract' | 'no_rule' | 'unknown' | 'none';
export interface SvcSetup {
  currency: string;
  setting: { parts_reason_code: string | null; note: string | null };
  reasons: Array<{ code: string; name: string; acct_code: string | null }>;
  warranty_rules: Array<{ rule_id: number; item_code: string | null; group_code: number | null; months: number; note: string | null; source: string; name: string | null }>;
  item_groups: Array<{ code: number; name: string }>;
  warehouses: Array<{ code: string; name: string; bins: boolean }>;
  technicians: Array<{ user_id: string; name: string }>;
  numbering: { call: string | null; contract: string | null };
  me: string; can_write: boolean; can_inventory: boolean;
}
export function useSvcSetup(company: string | null) {
  return useQuery({ queryKey: ['svc-setup', company], enabled: Boolean(company), staleTime: 30_000,
    queryFn: () => rpc<SvcSetup>('service_setup', { p_company: company }) });
}

export interface Warranty {
  status: WarrantyStatus; flagged: boolean; warranty_start: string | null; warranty_end: string | null; basis: 'equipment_card' | 'invoice' | null;
  card_id: number | null; invoice: { doc_entry: number; doc_no: string; doc_date: string; source: string } | null; months: number | null; serial_known: boolean;
  contract: { contract_id: number; doc_no: string; ends_on: string; response_hours: number | null; covers_parts: boolean; covers_labour: boolean } | null;
  messages: string[];
}
export const warrantyCheck = (company: string, p: Record<string, unknown>) => rpc<Warranty>('service_warranty', { p_company: company, p });

export interface CallInfo {
  call: {
    call_id: number; doc_no: string; card_code: string; card_name: string | null; contact: string | null; phone: string | null; item_code: string | null;
    item_name: string | null; serial_no: string | null; serial_managed: boolean | null; invoice_entry: number | null; invoice: Warranty['invoice'];
    equipment_card_id: number | null; contract_id: number | null; contract_no: string | null; subject: string; problem: string | null;
    priority: 'low' | 'medium' | 'high'; technician: string | null; technician_name: string | null; status: CallStatus; solution: string | null;
    warranty_status: WarrantyStatus | null; warranty_end: string | null; warranty_note: string | null; flagged: boolean; opened_at: string; due_by: string | null;
    overdue: boolean; resolved_at: string | null; closed_at: string | null; cancel_note: string | null; created_by_name: string | null;
  };
  parts: Array<{ doc_entry: number; doc_no: string; doc_date: string; total: number; state: string; status: string }>;
  history: Array<{ call_id: number; doc_no: string; subject: string; status: CallStatus; opened_at: string }>;
  activity: Array<{ at: string; action: string; actor_name: string | null; text: string | null }>;
  can_write: boolean; can_inventory: boolean;
}
export function useCallInfo(company: string, id: number) {
  return useQuery({ queryKey: ['svc-call', company, id], enabled: Boolean(company && id),
    queryFn: () => rpc<CallInfo>('service_call_info', { p_company: company, p_call: id }) });
}
export const callSave = (company: string, c: Record<string, unknown>) =>
  rpc<{ call_id: number; doc_no: string; warranty: Warranty }>('service_call_save', { p_company: company, p_call: c });
export const callStatus = (company: string, id: number, status: CallStatus, text: string | null) =>
  rpc<unknown>('service_call_status', { p_company: company, p_call: id, p_status: status, p_text: text });
export const callParts = (company: string, id: number, h: Record<string, unknown>, lines: Array<Record<string, unknown>>, reason: string | null) =>
  rpc<{ doc_entry: number; doc_no: string; state: string; value: number }>('service_call_parts_issue', { p_company: company, p_call: id, p_header: h, p_lines: lines, p_reason: reason });

export interface CardInfo {
  card: { card_id: number; item_code: string; item_name: string | null; serial_no: string; card_code: string; card_name: string | null; invoice_entry: number | null;
    invoice: Warranty['invoice']; sold_on: string | null; warranty_start: string | null; warranty_end: string | null; note: string | null; source: string };
  warranty: Warranty;
  calls: Array<{ call_id: number; doc_no: string; subject: string; status: CallStatus; opened_at: string; warranty_status: WarrantyStatus | null }>;
  can_write: boolean;
}
export function useCardInfo(company: string, id: number) {
  return useQuery({ queryKey: ['svc-card', company, id], enabled: Boolean(company && id),
    queryFn: () => rpc<CardInfo>('equipment_card_info', { p_company: company, p_card_id: id }) });
}
export const cardSave = (company: string, c: Record<string, unknown>) => rpc<{ card_id: number }>('equipment_card_save', { p_company: company, p_card: c });

export interface ContractInfo {
  contract: { contract_id: number; doc_no: string; card_code: string; card_name: string | null; starts_on: string; ends_on: string; response_hours: number | null;
    covers_parts: boolean; covers_labour: boolean; covers_travel: boolean; all_items: boolean; terms: string | null;
    state: 'draft' | 'active' | 'ended' | 'cancelled'; expired: boolean; end_note: string | null; created_by_name: string | null };
  lines: Array<{ line_num: number; item_code: string; item_name: string | null; serial_no: string | null; note: string | null }>;
  calls: Array<{ call_id: number; doc_no: string; subject: string; status: CallStatus; opened_at: string }>;
  activity: Array<{ at: string; action: string; actor_name: string | null; note: string | null }>;
  can_write: boolean;
}
export function useContractInfo(company: string, id: number) {
  return useQuery({ queryKey: ['svc-contract', company, id], enabled: Boolean(company && id),
    queryFn: () => rpc<ContractInfo>('service_contract_info', { p_company: company, p_contract: id }) });
}
export const contractSave = (company: string, c: Record<string, unknown>) =>
  rpc<{ contract_id: number; doc_no: string }>('service_contract_save', { p_company: company, p_c: c });
export const contractStatus = (company: string, id: number, action: 'activate' | 'end' | 'cancel', note: string | null) =>
  rpc<unknown>('service_contract_status', { p_company: company, p_contract: id, p_action: action, p_note: note });
export const svcSettingSet = (company: string, s: Record<string, unknown>) => rpc<unknown>('service_setting_set', { p_company: company, p_setting: s });
export const warrantyRuleSave = (company: string, r: Record<string, unknown>) => rpc<unknown>('warranty_rule_save', { p_company: company, p_rule: r });

/** A/R invoices of a customer that have the item (any source; the warranty starts on the invoice date). */
export async function invoicesFor(company: string, card: string, item: string) {
  const { data, error } = await erp().from('document').select('doc_entry,doc_num,doc_date,source,document_line!inner(item_code)')
    .eq('company_code', company).eq('obj_type', 13).eq('card_code', card).eq('document_line.item_code', item).order('doc_date', { ascending: false }).limit(20);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as Array<{ doc_entry: number; doc_num: number; doc_date: string; source: string }>;
}

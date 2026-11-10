import { useQuery } from '@tanstack/react-query';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** A11 · Ask AI. The assistant answers only from data the user can already read (erp.ai_ask_context, SECURITY INVOKER). */
export interface AiStatus {
  company: string; configured: boolean; enabled: boolean; provider: string | null; model: string | null;
  remaining: number | null; tools: string[]; can_setup: boolean;
}
export interface AiRef { obj_type: number; doc_entry: number }
export interface AiSource { label: string; link: string }
export interface AiTool { tool: string; status: 'ok' | 'not_allowed' | 'refused'; message?: string; summary?: Record<string, unknown>; rows?: unknown[] }
export interface AiAnswer { answer: string; responder: string; sources: AiSource[]; tools: AiTool[]; audit_id: number }

/** The local stack's stand-in answers with a fixed script, never a model. The UI labels it so. */
export const LOCAL_RESPONDER = 'local-test';

export const useAiStatus = (company: string | null, enabled = true) => useQuery({
  queryKey: ['ai-status', company], enabled: Boolean(company) && enabled, staleTime: 30_000,
  queryFn: () => rpc<AiStatus>('ai_status', { p_company: company }),
});

export class AiNotConfigured extends Error {}

/** Sends the question to the ai-assistant server function with the user's own session. */
export async function askAi(company: string, question: string, ref?: AiRef | null): Promise<AiAnswer> {
  const { data, error } = await supabase.functions.invoke('ai-assistant', { body: { company, question, ref: ref ?? null } });
  if (error) {
    if (error instanceof FunctionsHttpError) {
      const res = error.context as Response;
      const body = await res.json().catch(() => ({}));
      if (body.code === 'ai_not_configured' || res.status === 503) throw new AiNotConfigured(body.message ?? 'AI is not configured.');
      throw new ApiError({ code: body.code, message: body.message ?? error.message });
    }
    throw new ApiError({ message: error.message });
  }
  return data as AiAnswer;
}

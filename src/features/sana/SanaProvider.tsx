import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { erp, supabase, SUPABASE_URL } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { useCompany } from '@/layout/CompanyContext';
import i18n from '@/lib/i18n';

export interface SanaSource { label: string; link: string }
export interface SanaMessage {
  id: string;
  messageId?: number | null;  // the stored answer (for 👍/👎)
  role: 'user' | 'assistant';
  text: string;
  sources?: SanaSource[];
  denied?: boolean;
  mode?: 'ai' | 'basic';
  fallback?: boolean;
  error?: boolean;
  streaming?: boolean;
  via?: 'text' | 'voice';
  language?: string;
  feedback?: 1 | -1 | null;
}
/** What the user is looking at when they press "Ask Sana about this". A hint only: the server still checks every record. */
export interface SanaContext { type: 'document' | 'partner' | 'item' | 'report' | 'page'; company?: string; kind?: string; number?: string; code?: string; label?: string }
export interface SanaStatus { profile: boolean; enabled: boolean; voice_enabled?: boolean; daily_limit?: number; used?: number; languages?: string[]; company?: string }
export interface SanaConversation { conversation_id: string; title: string; company: string | null; started_at: string; last_at: string; messages: number }

interface OpenOpts { context?: SanaContext | null; question?: string; via?: 'text' | 'voice' }
interface SanaCtx {
  open: boolean;
  setOpen: (v: boolean) => void;
  messages: SanaMessage[];
  busy: boolean;
  mode: 'ai' | 'basic' | null;
  language: string;
  setLanguage: (l: string) => void;
  autoSpeak: boolean;
  setAutoSpeak: (v: boolean) => void;
  context: SanaContext | null;
  setContext: (c: SanaContext | null) => void;
  status: SanaStatus | undefined;
  conversationId: string | null;
  ask: (text: string, via?: 'text' | 'voice') => Promise<SanaMessage | null>;
  newChat: () => void;
  /** open the panel and ask straight away (home page prompt box, suggestion chips) */
  openAndAsk: (text: string, via?: 'text' | 'voice') => void;
  /** open the panel, optionally with page context ("Ask Sana about this") and/or a question */
  openWith: (o?: OpenOpts) => void;
  loadConversation: (id: string) => Promise<void>;
  deleteConversation: (id: string) => Promise<void>;
  feedback: (m: SanaMessage, value: 1 | -1) => Promise<void>;
}
const Ctx = createContext<SanaCtx | null>(null);
const uid = () => Math.random().toString(36).slice(2);
const load = (k: string, d: string) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } };
const save = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* storage blocked */ } };

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await erp().rpc(fn, args);
  if (error) throw new ApiError(error);
  return data as T;
}

interface AskReply { conversation_id: string; message_id: number | null; reply: string; sources: SanaSource[]; mode: 'ai' | 'basic'; fallback: boolean; denied: boolean; language: string }
type OnEvent = (event: string, data: Record<string, unknown>) => void;

/**
 * Calls the "sana" Edge Function with the user's own session. All role limits are enforced on the server.
 * Streams the answer as Server-Sent Events; if the response is not a stream (proxy, old function), reads it as one JSON reply.
 */
async function callSana(body: Record<string, unknown>, onEvent: OnEvent): Promise<AskReply> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new Error(i18n.t('sana.err.signin'));
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/sana`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error(i18n.t('sana.err.network'));
  }
  const type = res.headers.get('content-type') ?? '';
  if (!type.includes('text/event-stream') || !res.body) {
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((json as { error?: string }).error || i18n.t('sana.err.generic'));
    return json as AskReply;
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let done: AskReply | null = null;
  let failure: string | null = null;
  for (;;) {
    const { value, done: end } = await reader.read();
    if (end) break;
    buf += dec.decode(value, { stream: true });
    let i: number;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 2);
      const ev = chunk.match(/^event: (.+)$/m)?.[1] ?? 'message';
      const raw = chunk.match(/^data: (.*)$/m)?.[1];
      if (!raw) continue;
      let d: Record<string, unknown>;
      try { d = JSON.parse(raw); } catch { continue; }
      if (ev === 'done') done = d as unknown as AskReply;
      else if (ev === 'error') failure = String(d.error ?? '');
      else onEvent(ev, d);
    }
  }
  if (failure !== null) throw new Error(failure || i18n.t('sana.err.generic'));
  if (!done) throw new Error(i18n.t('sana.err.generic'));
  return done;
}

export function SanaProvider({ children }: { children: ReactNode }) {
  const { company } = useCompany();
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<SanaMessage[]>([]);
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'ai' | 'basic' | null>(null);
  const [language, setLang] = useState(() => load('sana-lang', 'auto'));
  const [autoSpeak, setAuto] = useState(() => load('sana-speak', '1') === '1');
  const [context, setContext] = useState<SanaContext | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const conversation = useRef<string | null>(null);
  const pending = useRef<{ text: string; via: 'text' | 'voice' } | null>(null);
  const co = company === 'GRP' ? null : company;
  const status = useQuery({ queryKey: ['sana-status', co], queryFn: () => rpc<SanaStatus>('sana_status', { p_company: co }), enabled: open, staleTime: 15_000 });

  const setConv = (id: string | null) => { conversation.current = id; setConversationId(id); };

  const ask = useCallback(async (text: string, via: 'text' | 'voice' = 'text') => {
    const q = text.trim();
    if (!q || busy) return null;
    const answerId = uid();
    setMessages((m) => [...m, { id: uid(), role: 'user', text: q, via }]);
    setBusy(true);
    const patch = (fn: (m: SanaMessage) => SanaMessage) => setMessages((list) => list.map((x) => (x.id === answerId ? fn(x) : x)));
    try {
      const r = await callSana({ message: q, conversation_id: conversation.current, company: co ?? context?.company ?? null, language, via, context }, (ev, d) => {
        if (ev === 'meta') setMode(d.mode as 'ai' | 'basic');
        if (ev === 'delta') {
          setMessages((list) => (list.some((x) => x.id === answerId) ? list : [...list, { id: answerId, role: 'assistant', text: '', streaming: true }]));
          patch((m) => ({ ...m, text: d.replace ? String(d.text) : m.text + String(d.text), streaming: true }));
        }
        if (ev === 'reset') patch((m) => ({ ...m, text: '' }));
      });
      setConv(r.conversation_id);
      setMode(r.mode);
      const msg: SanaMessage = { id: answerId, messageId: r.message_id, role: 'assistant', text: r.reply, sources: r.sources, denied: r.denied, mode: r.mode, fallback: r.fallback, via, language: r.language };
      setMessages((list) => (list.some((x) => x.id === answerId) ? list.map((x) => (x.id === answerId ? msg : x)) : [...list, msg]));
      qc.invalidateQueries({ queryKey: ['sana-status'] });
      qc.invalidateQueries({ queryKey: ['sana-history'] });
      return msg;
    } catch (e) {
      const msg: SanaMessage = { id: answerId, role: 'assistant', text: (e as Error).message, error: true };
      setMessages((list) => (list.some((x) => x.id === answerId) ? list.map((x) => (x.id === answerId ? msg : x)) : [...list, msg]));
      return msg;
    } finally {
      setBusy(false);
    }
  }, [busy, co, language, context, qc]);

  const newChat = useCallback(() => { setConv(null); setMessages([]); setContext(null); }, []);
  const openAndAsk = useCallback((text: string, via: 'text' | 'voice' = 'text') => { pending.current = { text, via }; setOpen(true); }, []);
  const openWith = useCallback((o: OpenOpts = {}) => {
    if (o.context !== undefined) {
      // A record from a page starts a fresh conversation about it, so answers never mix records.
      setConv(null); setMessages([]); setContext(o.context);
    }
    if (o.question) pending.current = { text: o.question, via: o.via ?? 'text' };
    setOpen(true);
  }, []);
  const loadConversation = useCallback(async (id: string) => {
    const r = await rpc<{ conversation_id: string; messages: Array<{ message_id: number; role: 'user' | 'assistant'; content: string; sources: SanaSource[]; denied: boolean; mode: 'ai' | 'basic'; via: 'text' | 'voice'; language: string; fallback: boolean; feedback: 1 | -1 | null }> }>('sana_messages', { p_conversation: id });
    setConv(r.conversation_id);
    setContext(null);
    setMessages(r.messages.map((m) => ({ id: `m${m.message_id}`, messageId: m.role === 'assistant' ? m.message_id : null, role: m.role, text: m.content, sources: m.sources,
      denied: m.denied, mode: m.mode ?? undefined, via: m.via ?? undefined, language: m.language ?? undefined, fallback: m.fallback, feedback: m.feedback })));
  }, []);
  const deleteConversation = useCallback(async (id: string) => {
    await rpc('sana_delete_conversation', { p_conversation: id });
    if (conversation.current === id) { setConv(null); setMessages([]); }
    qc.invalidateQueries({ queryKey: ['sana-history'] });
  }, [qc]);
  const feedback = useCallback(async (m: SanaMessage, value: 1 | -1) => {
    if (!m.messageId) return;
    const next = m.feedback === value ? 0 : value;
    await rpc('sana_feedback_set', { p_message: m.messageId, p_value: next });
    setMessages((list) => list.map((x) => (x.id === m.id ? { ...x, feedback: next ? (next as 1 | -1) : null } : x)));
  }, []);

  useEffect(() => {
    if (open && pending.current) { const p = pending.current; pending.current = null; void ask(p.text, p.via); }
  }, [open, ask]);
  // A new company starts a new conversation, so answers never mix companies.
  useEffect(() => { setConv(null); }, [company]);
  // Ctrl/⌘ J opens Sana from anywhere.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'j') { e.preventDefault(); setOpen((o) => !o); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const value = useMemo<SanaCtx>(() => ({
    open, setOpen, messages, busy, mode, language, autoSpeak, ask, newChat, openAndAsk, openWith, context, setContext, status: status.data,
    conversationId, loadConversation, deleteConversation, feedback,
    setLanguage: (l) => { setLang(l); save('sana-lang', l); },
    setAutoSpeak: (v) => { setAuto(v); save('sana-speak', v ? '1' : '0'); },
  }), [open, messages, busy, mode, language, autoSpeak, ask, newChat, openAndAsk, openWith, context, status.data, conversationId, loadConversation, deleteConversation, feedback]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSana() {
  const c = useContext(Ctx);
  if (!c) throw new Error('useSana must be used inside SanaProvider');
  return c;
}

/** My conversations (History view). */
export const useSanaHistory = (enabled: boolean) => useQuery({
  queryKey: ['sana-history'], enabled, staleTime: 5_000,
  queryFn: () => rpc<SanaConversation[]>('sana_conversations', { p_limit: 30 }),
});

/** Suggested questions for the user's role (only topics the role covers). */
export function sanaSuggestions(modules: string[]): string[] {
  const has = (...m: string[]) => modules.includes('business') || m.some((x) => modules.includes(x));
  const out: string[] = [];
  if (has('sales')) out.push('sana.q.openOrders', 'sana.q.overdue');
  if (has('finance')) out.push('sana.q.overdue', 'sana.q.finance');
  if (has('inventory', 'sales', 'purchase')) out.push('sana.q.stock');
  if (has('purchase')) out.push('sana.q.openPOs');
  if (has('banking', 'finance')) out.push('sana.q.bank');
  if (has('hr')) out.push('sana.q.headcount');
  out.push('sana.q.approvals', 'sana.q.alerts', 'sana.q.whoami');
  return [...new Set(out)].slice(0, 4);
}

/** Suggested questions about the record the user came from. */
export function sanaContextSuggestions(c: SanaContext): string[] {
  if (c.type === 'document') return ['sana.ctx.q.summary', 'sana.ctx.q.status', 'sana.ctx.q.lines'];
  if (c.type === 'partner') return ['sana.ctx.q.balance', 'sana.ctx.q.latest'];
  if (c.type === 'item') return ['sana.ctx.q.stock', 'sana.ctx.q.where'];
  return ['sana.ctx.q.summary'];
}

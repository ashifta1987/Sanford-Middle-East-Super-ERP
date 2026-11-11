import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { supabase, SUPABASE_URL } from '@/lib/supabase';
import { useCompany } from '@/layout/CompanyContext';
import i18n from '@/lib/i18n';

export interface SanaSource { label: string; link: string }
export interface SanaMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  sources?: SanaSource[];
  denied?: boolean;
  mode?: 'ai' | 'basic';
  error?: boolean;
  via?: 'text' | 'voice';
  language?: string;
}
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
  ask: (text: string, via?: 'text' | 'voice') => Promise<SanaMessage | null>;
  newChat: () => void;
  /** open the panel and ask straight away (home page prompt box, suggestion chips) */
  openAndAsk: (text: string, via?: 'text' | 'voice') => void;
}
const Ctx = createContext<SanaCtx | null>(null);
const uid = () => Math.random().toString(36).slice(2);
const load = (k: string, d: string) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } };
const save = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* storage blocked */ } };

/** Calls the "sana" Edge Function with the user's own session. All role limits are enforced on the server. */
async function callSana(body: Record<string, unknown>) {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new Error(i18n.t('sana.err.signin'));
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/sana`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, apikey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string) ?? '', 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error(i18n.t('sana.err.network'));
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((json as { error?: string }).error || i18n.t('sana.err.generic'));
  return json as { conversation_id: string; reply: string; sources: SanaSource[]; mode: 'ai' | 'basic'; denied: boolean; language: string };
}

export function SanaProvider({ children }: { children: ReactNode }) {
  const { company } = useCompany();
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<SanaMessage[]>([]);
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'ai' | 'basic' | null>(null);
  const [language, setLang] = useState(() => load('sana-lang', 'auto'));
  const [autoSpeak, setAuto] = useState(() => load('sana-speak', '1') === '1');
  const conversation = useRef<string | null>(null);
  const pending = useRef<{ text: string; via: 'text' | 'voice' } | null>(null);

  const ask = useCallback(async (text: string, via: 'text' | 'voice' = 'text') => {
    const q = text.trim();
    if (!q || busy) return null;
    setMessages((m) => [...m, { id: uid(), role: 'user', text: q, via }]);
    setBusy(true);
    try {
      const r = await callSana({ message: q, conversation_id: conversation.current, company, language, via });
      conversation.current = r.conversation_id;
      setMode(r.mode);
      const msg: SanaMessage = { id: uid(), role: 'assistant', text: r.reply, sources: r.sources, denied: r.denied, mode: r.mode, via, language: r.language };
      setMessages((m) => [...m, msg]);
      return msg;
    } catch (e) {
      const msg: SanaMessage = { id: uid(), role: 'assistant', text: (e as Error).message, error: true };
      setMessages((m) => [...m, msg]);
      return msg;
    } finally {
      setBusy(false);
    }
  }, [busy, company, language]);

  const newChat = useCallback(() => { conversation.current = null; setMessages([]); }, []);
  const openAndAsk = useCallback((text: string, via: 'text' | 'voice' = 'text') => { pending.current = { text, via }; setOpen(true); }, []);
  useEffect(() => {
    if (open && pending.current) { const p = pending.current; pending.current = null; void ask(p.text, p.via); }
  }, [open, ask]);
  // A new company starts a new conversation, so answers never mix companies.
  useEffect(() => { conversation.current = null; }, [company]);
  // Ctrl/⌘ J opens Sana from anywhere.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'j') { e.preventDefault(); setOpen((o) => !o); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const value = useMemo<SanaCtx>(() => ({
    open, setOpen, messages, busy, mode, language, autoSpeak, ask, newChat, openAndAsk,
    setLanguage: (l) => { setLang(l); save('sana-lang', l); },
    setAutoSpeak: (v) => { setAuto(v); save('sana-speak', v ? '1' : '0'); },
  }), [open, messages, busy, mode, language, autoSpeak, ask, newChat, openAndAsk]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSana() {
  const c = useContext(Ctx);
  if (!c) throw new Error('useSana must be used inside SanaProvider');
  return c;
}

/** Suggested questions for the user's role (only topics the role covers). */
export function sanaSuggestions(modules: string[]): string[] {
  const has = (...m: string[]) => modules.includes('business') || m.some((x) => modules.includes(x));
  const out: string[] = [];
  if (has('sales')) out.push('sana.q.openOrders', 'sana.q.overdue');
  if (has('finance')) out.push('sana.q.overdue', 'sana.q.finance');
  if (has('inventory', 'sales', 'purchase')) out.push('sana.q.stock');
  if (has('purchase')) out.push('sana.q.openPOs');
  if (has('hr')) out.push('sana.q.headcount');
  out.push('sana.q.alerts', 'sana.q.whoami');
  return [...new Set(out)].slice(0, 4);
}

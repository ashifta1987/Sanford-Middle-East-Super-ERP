import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, Loader2, Search } from 'lucide-react';

export interface ComboOption<T> { value: string; label: string; meta?: ReactNode; data: T }

/**
 * Search combobox (UI/UX spec §5): type at least 1 character, results after 250 ms, arrow keys + Enter, Esc closes.
 * `text` is what the input shows; `onSelect` receives the chosen option.
 */
export function Combobox<T>({ id, label, text, onText, onSelect, search, placeholder, error, required, noMatch, className }: {
  id: string; label: string; text: string; onText: (s: string) => void; onSelect: (o: ComboOption<T>) => void;
  search: (q: string) => Promise<Array<ComboOption<T>>>; placeholder?: string; error?: string; required?: boolean; noMatch?: string; className?: string;
}) {
  const { t } = useTranslation();
  const listId = useId();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [opts, setOpts] = useState<Array<ComboOption<T>>>([]);
  const [active, setActive] = useState(0);
  const [typed, setTyped] = useState(false);
  const seq = useRef(0);

  useEffect(() => {
    if (!typed) return;
    const q = text.trim();
    if (q.length < 1) { setOpts([]); setOpen(false); return; }
    const n = ++seq.current;
    setBusy(true);
    const h = setTimeout(async () => {
      try {
        const res = await search(q);
        if (n !== seq.current) return;
        setOpts(res); setActive(0); setOpen(true);
      } catch {
        if (n === seq.current) { setOpts([]); setOpen(true); }
      } finally {
        if (n === seq.current) setBusy(false);
      }
    }, 250);
    return () => clearTimeout(h);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, typed]);

  function choose(o: ComboOption<T>) {
    setTyped(false); setOpen(false); onSelect(o);
  }

  return (
    <div className={clsx('relative min-w-0', className)}>
      <label htmlFor={id} className="mb-1 block text-xs font-medium text-muted">{label}{required && <span className="text-crit-fg"> *</span>}</label>
      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" aria-hidden />
        <input
          id={id}
          role="combobox"
          aria-expanded={open}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={open && opts[active] ? `${listId}-${active}` : undefined}
          aria-invalid={Boolean(error)}
          aria-describedby={error ? `${id}-err` : undefined}
          autoComplete="off"
          dir="auto"
          value={text}
          placeholder={placeholder}
          onChange={(e) => { setTyped(true); onText(e.target.value); }}
          onFocus={(e) => e.target.select()}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') { e.preventDefault(); if (!open && opts.length) setOpen(true); setActive((a) => Math.min(a + 1, opts.length - 1)); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
            else if (e.key === 'Enter' && open && opts[active]) { e.preventDefault(); e.stopPropagation(); choose(opts[active]); }
            else if (e.key === 'Escape') { setOpen(false); }
          }}
          className={clsx('input ps-9', error && 'border-crit-fg')}
        />
        {busy && <Loader2 className="absolute end-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-muted" aria-hidden />}
      </div>
      {open && (
        <ul id={listId} role="listbox" className="absolute inset-x-0 z-30 mt-1 max-h-72 overflow-auto rounded-btn border border-line bg-surface py-1 shadow-lg">
          {opts.length === 0 ? (
            <li className="px-3 py-2 text-sm text-muted" role="option" aria-selected={false} aria-disabled>{noMatch ?? t('so.combo.noMatch')}</li>
          ) : opts.map((o, i) => (
            <li key={o.value} id={`${listId}-${i}`} role="option" aria-selected={i === active}
              onMouseDown={(e) => { e.preventDefault(); choose(o); }} onMouseEnter={() => setActive(i)}
              className={clsx('cursor-pointer px-3 py-2', i === active && 'bg-primary-soft')}>
              <div dir="auto" className="text-[14px] font-medium text-ink">{o.label}</div>
              {o.meta && <div className="num text-xs text-muted">{o.meta}</div>}
            </li>
          ))}
        </ul>
      )}
      {error && <p id={`${id}-err`} className="mt-1 flex items-start gap-1 text-xs text-crit-fg"><AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden />{error}</p>}
    </div>
  );
}

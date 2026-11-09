import { useEffect, useRef, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { X } from 'lucide-react';

/**
 * Confirmation dialog for destructive or irreversible actions only (UI/UX spec §5).
 * Esc closes it and focus returns to the element that opened it.
 */
export function Dialog({ open, title, children, onClose, footer }: { open: boolean; title: string; children: ReactNode; onClose: () => void; footer: ReactNode }) {
  const { t } = useTranslation();
  const ref = useRef<HTMLDivElement>(null);
  const opener = useRef<Element | null>(null);

  useEffect(() => {
    if (!open) return;
    opener.current = document.activeElement;
    const first = ref.current?.querySelector<HTMLElement>('textarea, input, button:not([data-close])');
    first?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      (opener.current as HTMLElement | null)?.focus?.();
    };
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-4 sm:items-center" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div ref={ref} role="dialog" aria-modal="true" aria-labelledby="dlg-title" className="card w-full max-w-md">
        <div className="flex items-center justify-between gap-3 border-b border-line px-5 py-3">
          <h2 id="dlg-title" dir="auto" className="text-[15px] font-semibold">{title}</h2>
          <button type="button" data-close onClick={onClose} aria-label={t('so.dialog.close')} className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-page">
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>
        <div className="space-y-3 p-5">{children}</div>
        <div className="flex flex-wrap justify-end gap-2 border-t border-line px-5 py-3">{footer}</div>
      </div>
    </div>
  );
}

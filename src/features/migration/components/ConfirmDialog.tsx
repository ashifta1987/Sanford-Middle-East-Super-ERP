import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { Button } from '@/components/Button';

/** Accessible confirm dialog (native <dialog>, no window.confirm). Optional required note. */
export function ConfirmDialog({ open, title, body, confirmLabel, tone = 'primary', noteLabel, noteRequired, busy, error, onConfirm, onClose }: {
  open: boolean;
  title: string;
  body?: ReactNode;
  confirmLabel?: string;
  tone?: 'primary' | 'danger';
  noteLabel?: string;
  noteRequired?: boolean;
  busy?: boolean;
  error?: string | null;
  onConfirm: (note: string) => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const ref = useRef<HTMLDialogElement>(null);
  const [note, setNote] = useState('');
  const titleId = useId();
  const noteId = useId();

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) { setNote(''); d.showModal(); }
    if (!open && d.open) d.close();
  }, [open]);

  const blocked = noteRequired && note.trim() === '';

  return (
    <dialog
      ref={ref}
      aria-labelledby={titleId}
      onClose={onClose}
      className="w-[min(92vw,480px)] rounded-card border border-line p-0 backdrop:bg-black/40"
    >
      <form method="dialog" onSubmit={(e) => { e.preventDefault(); if (!blocked) onConfirm(note); }} className="space-y-4 p-6">
        <h2 id={titleId} className="text-lg font-semibold">{title}</h2>
        {body && <div className="text-[15px] text-muted">{body}</div>}
        {noteLabel && (
          <div>
            <label htmlFor={noteId} className="mb-1 block text-sm font-medium">{noteLabel}</label>
            <textarea id={noteId} value={note} onChange={(e) => setNote(e.target.value)} rows={3} required={noteRequired} className="input py-2" />
          </div>
        )}
        {error && <p role="alert" className="text-sm text-crit-fg">{error}</p>}
        <div className="flex justify-end gap-2">
          <Button onClick={onClose}>{t('app.cancel')}</Button>
          <Button type="submit" variant={tone} disabled={busy || blocked}>{confirmLabel ?? t('app.confirm')}</Button>
        </div>
      </form>
    </dialog>
  );
}


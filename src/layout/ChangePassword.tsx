import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { KeyRound } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { errorMessage } from '@/lib/format';
import { ConfirmDialog } from '@/features/migration/components/ConfirmDialog';

/** Top-bar button: the signed-in user changes their own password (temporary passwords are issued by IT). */
export function ChangePassword() {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function save() {
    setErr(null);
    if (pw.length < 10) return setErr(t('account.short'));
    if (pw !== pw2) return setErr(t('account.mismatch'));
    setBusy(true);
    const { error } = await supabase.auth.updateUser({ password: pw });
    setBusy(false);
    if (error) return setErr(errorMessage(error));
    setOpen(false);
    setPw(''); setPw2('');
    setMsg(t('account.saved'));
    setTimeout(() => setMsg(null), 4000);
  }

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="grid h-11 w-11 place-items-center rounded-btn border border-line" aria-label={t('account.password')} title={msg ?? t('account.password')}>
        <KeyRound className="h-5 w-5" aria-hidden />
      </button>
      {msg && <span role="status" className="sr-only">{msg}</span>}
      <ConfirmDialog
        open={open}
        title={t('account.password')}
        confirmLabel={t('account.save')}
        busy={busy}
        error={err}
        body={
          <div className="space-y-3 text-ink">
            <div>
              <label htmlFor="pw1" className="mb-1 block text-sm font-medium">{t('account.new')}</label>
              <input id="pw1" type="password" autoComplete="new-password" className="input" value={pw} onChange={(e) => setPw(e.target.value)} />
              <p className="mt-0.5 text-xs text-muted">{t('account.short')}</p>
            </div>
            <div>
              <label htmlFor="pw2" className="mb-1 block text-sm font-medium">{t('account.confirm')}</label>
              <input id="pw2" type="password" autoComplete="new-password" className="input" value={pw2} onChange={(e) => setPw2(e.target.value)} />
            </div>
          </div>
        }
        onConfirm={() => void save()}
        onClose={() => { setOpen(false); setErr(null); }}
      />
    </>
  );
}


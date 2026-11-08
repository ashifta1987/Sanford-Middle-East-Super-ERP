import { useState, type FormEvent } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { supabase, supabaseConfigured } from '@/lib/supabase';
import { useAuth } from './AuthProvider';
import { Button } from '@/components/Button';
import { errorMessage } from '@/lib/format';
import { LanguageToggle } from '@/layout/LanguageToggle';

export function LoginPage() {
  const { t } = useTranslation();
  const { session } = useAuth();
  const nav = useNavigate();
  const loc = useLocation() as { state?: { from?: string } };
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  if (session) return <Navigate to={loc.state?.from ?? '/'} replace />;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) setErr(errorMessage(error));
    else nav(loc.state?.from ?? '/', { replace: true });
  }

  return (
    <main className="min-h-screen bg-page flex items-center justify-center p-4">
      <div className="w-full max-w-sm">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            <span className="h-10 w-10 rounded-btn bg-primary text-white font-semibold grid place-items-center" aria-hidden>S</span>
            <div>
              <div className="font-semibold text-ink">{t('app.name')}</div>
              <div className="text-xs text-muted">{t('app.group')}</div>
            </div>
          </div>
          <LanguageToggle />
        </div>
        <form onSubmit={onSubmit} className="card p-6 space-y-4" noValidate>
          <h1 className="text-xl font-semibold">{t('auth.title')}</h1>
          {!supabaseConfigured && <p className="pill-crit block p-2 rounded-btn text-sm">{t('auth.notConfigured')}</p>}
          <div>
            <label htmlFor="email" className="block text-sm font-medium mb-1">{t('auth.email')}</label>
            <input id="email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} className="input" />
          </div>
          <div>
            <label htmlFor="password" className="block text-sm font-medium mb-1">{t('auth.password')}</label>
            <input id="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} className="input" />
          </div>
          {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
          <Button type="submit" variant="primary" className="w-full" disabled={busy || !email || !password}>
            {busy ? t('auth.signingIn') : t('auth.signIn')}
          </Button>
        </form>
      </div>
    </main>
  );
}

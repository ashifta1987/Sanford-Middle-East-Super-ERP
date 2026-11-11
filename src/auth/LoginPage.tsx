import { useState, type FormEvent, type ReactNode } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { ArrowLeft, ArrowRight, Eye, EyeOff, Lock, Mail, MailCheck } from 'lucide-react';
import clsx from 'clsx';
import { setRememberMe, supabase, supabaseConfigured } from '@/lib/supabase';
import { useAuth } from './AuthProvider';
import { LanguageToggle } from '@/layout/LanguageToggle';
import { Logo } from '@/brand/Logo';
import i18n from '@/lib/i18n';

/** Sign-in errors in plain words. Supabase returns English text; map the common ones so Arabic users get Arabic. */
export function authError(err: { message?: string; status?: number; code?: string } | null): string {
  if (!err) return '';
  const m = (err.message ?? '').toLowerCase();
  if (err.code === 'invalid_credentials' || m.includes('invalid login credentials')) return i18n.t('auth.err.credentials');
  if (err.code === 'email_not_confirmed' || m.includes('email not confirmed')) return i18n.t('auth.err.unconfirmed');
  if (err.status === 429 || m.includes('rate limit') || m.includes('too many')) return i18n.t('auth.err.rate');
  if (m.includes('failed to fetch') || m.includes('network')) return i18n.t('auth.err.network');
  if (m.includes('password should be') || m.includes('weak')) return i18n.t('auth.err.weak');
  return err.message || i18n.t('errors.generic');
}

/** The decorative brand panel on the left of the sign-in and reset pages (hidden on phones). */
export function BrandPanel() {
  const { t } = useTranslation();
  return (
    <aside aria-hidden className="relative hidden overflow-hidden bg-brand-navy lg:block">
      {/* Ribbons: the four logo colours sweeping across the panel */}
      <svg className="absolute inset-0 h-full w-full" viewBox="0 0 745 941" preserveAspectRatio="xMidYMid slice">
        <defs>
          <linearGradient id="sf-rb" x1="0" x2="1"><stop offset="0" stopColor="#0B4FE0" /><stop offset="1" stopColor="#0A3FD0" /></linearGradient>
          <linearGradient id="sf-ry" x1="0" x2="1" y1="0" y2="1"><stop offset="0" stopColor="#F7B646" /><stop offset="1" stopColor="#E59A22" /></linearGradient>
          <linearGradient id="sf-rt" x1="0" x2="1" y1="1" y2="0"><stop offset="0" stopColor="#08BBA9" /><stop offset="1" stopColor="#0FD3BD" /></linearGradient>
          <linearGradient id="sf-rc" x1="0" x2="1" y1="1" y2="0"><stop offset="0" stopColor="#F4745B" /><stop offset="1" stopColor="#FF8A6E" /></linearGradient>
          <linearGradient id="sf-glass" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#3D7BFF" stopOpacity=".55" /><stop offset="1" stopColor="#1240B8" stopOpacity=".55" /></linearGradient>
          <filter id="sf-glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18" /></filter>
          <linearGradient id="sf-bar" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#8FD3FF" /><stop offset="1" stopColor="#2F7BFF" /></linearGradient>
        </defs>
        <path d="M275 -10 L420 -10 L610 150 L460 150 Z" fill="url(#sf-rb)" />
        <path d="M480 140 L610 140 L745 280 L745 300 L700 345 L620 345 L700 270 Z" fill="url(#sf-ry)" />
        <path d="M700 345 L745 300 L745 420 L610 540 L540 540 Z" fill="url(#sf-rt)" opacity=".95" />
        <path d="M130 941 L250 941 L470 760 L350 760 Z" fill="url(#sf-rc)" />
        <path d="M505 0 L745 245" stroke="#18E3C7" strokeWidth="2" opacity=".7" />
        <path d="M745 410 L320 941" stroke="#18E3C7" strokeWidth="2" opacity=".55" />
        {/* Glass dashboard card */}
        <g transform="translate(114 481)">
          <rect width="526" height="291" rx="28" fill="#3D7BFF" opacity=".18" filter="url(#sf-glow)" />
          <rect width="526" height="291" rx="28" fill="url(#sf-glass)" stroke="#9CC2FF" strokeOpacity=".7" strokeWidth="2" />
          <rect x="46" y="44" width="152" height="12" rx="6" fill="#E6F0FF" opacity=".9" />
          <rect x="46" y="74" width="108" height="10" rx="5" fill="#9DBEFF" opacity=".8" />
          {[[46, 215], [90, 190], [134, 168], [178, 145], [222, 120], [266, 92]].map(([x, y], i) => (
            <rect key={i} x={x} y={y} width="34" height={252 - y} rx="7" fill="url(#sf-bar)" />
          ))}
          <line x1="318" y1="40" x2="318" y2="252" stroke="#9CC2FF" strokeOpacity=".35" />
          <g transform="translate(415 100)" fill="none" strokeWidth="22">
            <circle r="56" stroke="#2F7BFF" />
            <circle r="56" stroke="#08BBA9" strokeDasharray="88 352" transform="rotate(-90)" />
            <circle r="56" stroke="#F7B646" strokeDasharray="70 352" strokeDashoffset="-88" transform="rotate(-90)" />
            <circle r="56" stroke="#F4745B" strokeDasharray="62 352" strokeDashoffset="-158" transform="rotate(-90)" />
          </g>
          {[['#2F7BFF', 194], ['#08BBA9', 220], ['#F4745B', 246]].map(([c, y]) => (
            <g key={String(y)}><circle cx="358" cy={y} r="7" fill={String(c)} /><rect x="378" y={Number(y) - 4} width="104" height="8" rx="4" fill="#C7D9FF" opacity=".75" /></g>
          ))}
        </g>
      </svg>
      <div className="relative px-[11%] pt-[25%]">
        <p className="font-display text-[clamp(42px,4.6vw,64px)] font-bold leading-[1.06] tracking-[-0.02em] text-white">
          {t('auth.hero1')}<br />{t('auth.hero2')}
        </p>
        <span className="mt-6 block h-2 w-36 rounded-full bg-[#18E3C7]" />
      </div>
    </aside>
  );
}

export function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <main className="grid min-h-screen bg-[#FCF8F5] lg:grid-cols-[minmax(0,45fr)_minmax(0,55fr)] [[data-theme=dark]_&]:bg-page">
      <BrandPanel />
      <section className="flex min-h-screen flex-col px-5 py-6 sm:px-10 lg:px-[7%]">
        <div className="flex justify-end"><LanguageToggle /></div>
        <div className="mx-auto flex w-full max-w-[600px] flex-1 flex-col justify-center py-8">{children}</div>
      </section>
    </main>
  );
}

function Field({ id, label, icon, children, error }: { id: string; label: string; icon: ReactNode; children: ReactNode; error?: string }) {
  return (
    <div>
      <label htmlFor={id} className="mb-2 block text-[17px] font-semibold text-ink">{label}</label>
      <div className={clsx('flex min-h-[56px] items-center gap-3 rounded-[12px] border bg-surface px-4 transition focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20',
        error ? 'border-crit-fg' : 'border-line-strong')}>
        <span className="text-muted" aria-hidden>{icon}</span>
        {children}
      </div>
      {error && <p id={`${id}-err`} className="mt-1.5 text-sm text-crit-fg">{error}</p>}
    </div>
  );
}

const inputCls = 'min-w-0 flex-1 bg-transparent py-3 text-[16px] text-ink outline-none placeholder:text-muted focus-visible:outline-none';
const primaryBtn = 'inline-flex min-h-[56px] w-full items-center justify-center gap-3 rounded-[12px] bg-[#0A47F0] px-6 font-display text-[19px] font-semibold text-white transition hover:bg-[#0838C4] focus-visible:outline-offset-4 disabled:cursor-not-allowed disabled:bg-neutral-bg disabled:text-muted [[data-theme=dark]_&]:bg-primary [[data-theme=dark]_&]:hover:bg-primary-hover';

export function LoginPage() {
  const { t } = useTranslation();
  const { session } = useAuth();
  const nav = useNavigate();
  const loc = useLocation() as { state?: { from?: string } };
  const [mode, setMode] = useState<'signin' | 'forgot' | 'sent'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [show, setShow] = useState(false);
  // Unticked by default (as in the design): the session ends when the browser closes unless the user ticks it.
  const [remember, setRemember] = useState(() => { try { return localStorage.getItem('sf-remember') === '1'; } catch { return false; } });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [touched, setTouched] = useState(false);
  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());

  if (session && mode === 'signin') return <Navigate to={loc.state?.from ?? '/'} replace />;

  async function onSignIn(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!emailOk || !password) return;
    setBusy(true);
    setErr(null);
    setRememberMe(remember);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) setErr(authError(error));
    else nav(loc.state?.from ?? '/', { replace: true });
  }

  async function onForgot(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!emailOk) return;
    setBusy(true);
    setErr(null);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/reset-password` });
    setBusy(false);
    // Rate limits and network problems are shown; "no such user" is never revealed.
    if (error && (error.status === 429 || /fetch|network/i.test(error.message))) setErr(authError(error));
    else setMode('sent');
  }

  const emailErr = touched && !emailOk ? (email ? t('auth.err.emailFormat') : t('auth.err.emailRequired')) : undefined;
  const passErr = touched && mode === 'signin' && !password ? t('auth.err.passwordRequired') : undefined;

  return (
    <AuthLayout>
      <Logo size="lg" className="mb-10 self-start sm:mb-12" />

      {mode === 'sent' ? (
        <div role="status">
          <span className="mb-5 grid h-14 w-14 place-items-center rounded-full bg-ok-bg text-ok-fg"><MailCheck className="h-7 w-7" aria-hidden /></span>
          <h1 className="text-[34px] font-bold leading-tight tracking-[-0.02em] sm:text-[44px]">{t('auth.sentTitle')}</h1>
          <p className="mt-3 text-[18px] text-muted">{t('auth.sentBody', { email: email.trim() })}</p>
          <button type="button" onClick={() => { setMode('signin'); setTouched(false); }} className="mt-8 inline-flex min-h-[44px] items-center gap-2 font-semibold text-primary hover:underline">
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('auth.backToSignIn')}
          </button>
        </div>
      ) : (
        <>
          <h1 className="text-[36px] font-bold leading-tight tracking-[-0.02em] sm:text-[52px]">{mode === 'signin' ? t('auth.welcome') : t('auth.forgotTitle')}</h1>
          <p className="mt-2 text-[18px] text-muted sm:text-[22px]">{mode === 'signin' ? t('auth.subtitle') : t('auth.forgotBody')}</p>

          {!supabaseConfigured && <p className="pill-crit mt-6 block rounded-btn p-3 text-sm">{t('auth.notConfigured')}</p>}

          <form onSubmit={mode === 'signin' ? onSignIn : onForgot} className="mt-9 space-y-6" noValidate>
            <Field id="email" label={t('auth.email')} icon={<Mail className="h-6 w-6" />} error={emailErr}>
              <input id="email" type="email" inputMode="email" autoComplete="username" autoFocus value={email} onChange={(e) => setEmail(e.target.value)}
                placeholder={t('auth.emailPlaceholder')} aria-invalid={Boolean(emailErr)} aria-describedby={emailErr ? 'email-err' : undefined} className={inputCls} />
            </Field>

            {mode === 'signin' && (
              <>
                <Field id="password" label={t('auth.password')} icon={<Lock className="h-6 w-6" />} error={passErr}>
                  <input id="password" type={show ? 'text' : 'password'} autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)}
                    aria-invalid={Boolean(passErr)} aria-describedby={passErr ? 'password-err' : undefined} className={inputCls} />
                  <button type="button" onClick={() => setShow((v) => !v)} className="-me-2 grid h-11 w-11 place-items-center rounded-btn text-muted hover:text-ink"
                    aria-label={show ? t('auth.hidePassword') : t('auth.showPassword')} aria-pressed={show}>
                    {show ? <EyeOff className="h-6 w-6" aria-hidden /> : <Eye className="h-6 w-6" aria-hidden />}
                  </button>
                </Field>

                <div className="flex flex-wrap items-center justify-between gap-3">
                  <label className="inline-flex min-h-[44px] cursor-pointer items-center gap-3 text-[17px] text-ink">
                    <input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} className="h-6 w-6 rounded-md border-line-strong accent-[#0A47F0]" />
                    {t('auth.remember')}
                  </label>
                  <button type="button" onClick={() => { setMode('forgot'); setErr(null); setTouched(false); }} className="min-h-[44px] text-[17px] font-medium text-[#0A47F0] hover:underline [[data-theme=dark]_&]:text-primary-text">
                    {t('auth.forgot')}
                  </button>
                </div>
              </>
            )}

            {err && <p role="alert" className="rounded-btn border border-crit-fg/30 bg-crit-bg px-4 py-3 text-[15px] text-crit-fg">{err}</p>}

            <button type="submit" className={primaryBtn} disabled={busy || !supabaseConfigured}>
              {mode === 'signin' ? (busy ? t('auth.signingIn') : t('auth.signIn')) : (busy ? t('auth.sending') : t('auth.sendLink'))}
              {!busy && <ArrowRight className="h-6 w-6 rtl:rotate-180" aria-hidden />}
            </button>

            {mode === 'forgot' && (
              <button type="button" onClick={() => { setMode('signin'); setErr(null); setTouched(false); }} className="inline-flex min-h-[44px] items-center gap-2 font-semibold text-primary hover:underline">
                <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('auth.backToSignIn')}
              </button>
            )}
          </form>
          {mode === 'signin' && <p className="mt-10 text-sm text-muted">{t('auth.help')}</p>}
        </>
      )}
    </AuthLayout>
  );
}

/** Opened from the reset email. Supabase signs the user in from the link, then they choose a new password. */
export function ResetPasswordPage() {
  const { t } = useTranslation();
  const { session, ready } = useAuth();
  const nav = useNavigate();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [touched, setTouched] = useState(false);
  const longEnough = pw.length >= 10;
  const same = pw === pw2;

  async function onSave(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!longEnough || !same) return;
    setBusy(true);
    setErr(null);
    const { error } = await supabase.auth.updateUser({ password: pw });
    setBusy(false);
    if (error) setErr(authError(error));
    else nav('/', { replace: true });
  }

  return (
    <AuthLayout>
      <Logo size="lg" className="mb-10 self-start sm:mb-12" />
      {!ready ? <p className="text-muted">{t('app.loading')}</p> : !session ? (
        <div role="alert">
          <h1 className="text-[34px] font-bold leading-tight sm:text-[44px]">{t('auth.linkExpiredTitle')}</h1>
          <p className="mt-3 text-[18px] text-muted">{t('auth.linkExpiredBody')}</p>
          <Link to="/login" className="mt-8 inline-flex min-h-[44px] items-center gap-2 font-semibold text-primary hover:underline">
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('auth.backToSignIn')}
          </Link>
        </div>
      ) : (
        <>
          <h1 className="text-[36px] font-bold leading-tight sm:text-[48px]">{t('auth.newPasswordTitle')}</h1>
          <p className="mt-2 text-[18px] text-muted">{t('auth.newPasswordBody')}</p>
          <form onSubmit={onSave} className="mt-9 space-y-6" noValidate>
            <Field id="pw" label={t('auth.newPassword')} icon={<Lock className="h-6 w-6" />} error={touched && !longEnough ? t('auth.err.short') : undefined}>
              <input id="pw" type={show ? 'text' : 'password'} autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} className={inputCls} aria-describedby="pw-err" />
              <button type="button" onClick={() => setShow((v) => !v)} className="-me-2 grid h-11 w-11 place-items-center rounded-btn text-muted hover:text-ink" aria-label={show ? t('auth.hidePassword') : t('auth.showPassword')} aria-pressed={show}>
                {show ? <EyeOff className="h-6 w-6" aria-hidden /> : <Eye className="h-6 w-6" aria-hidden />}
              </button>
            </Field>
            <Field id="pw2" label={t('auth.confirmPassword')} icon={<Lock className="h-6 w-6" />} error={touched && !same ? t('auth.err.mismatch') : undefined}>
              <input id="pw2" type={show ? 'text' : 'password'} autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} className={inputCls} aria-describedby="pw2-err" />
            </Field>
            {err && <p role="alert" className="rounded-btn border border-crit-fg/30 bg-crit-bg px-4 py-3 text-[15px] text-crit-fg">{err}</p>}
            <button type="submit" className={primaryBtn} disabled={busy}>
              {busy ? t('auth.saving') : t('auth.savePassword')} {!busy && <ArrowRight className="h-6 w-6 rtl:rotate-180" aria-hidden />}
            </button>
          </form>
        </>
      )}
    </AuthLayout>
  );
}


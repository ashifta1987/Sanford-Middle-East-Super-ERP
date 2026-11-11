import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { ArrowRight, ArrowUp, Mic } from 'lucide-react';
import clsx from 'clsx';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { PoweredBySana, SanaMark } from './SanaMark';
import { sanaSuggestions, useSana } from './SanaProvider';
import { speechLocale, useSpeechInput } from './voice';

interface Alert { check: string; severity: string; company: string; subject: string; detail: string; amount: number | null }

function greetingKey() {
  const h = new Date().getHours();
  return h < 12 ? 'sana.home.morning' : h < 17 ? 'sana.home.afternoon' : 'sana.home.evening';
}

/** Home page hero: greeting, "Ask Sana" box with voice, role-based suggestions, and what needs attention (rule checks, role-limited). */
export function SanaHero() {
  const { t, i18n } = useTranslation();
  const { profile } = useAuth();
  const { company } = useCompany();
  const sana = useSana();
  const [q, setQ] = useState('');
  const mic = useSpeechInput((said) => sana.openAndAsk(said, 'voice'));
  const first = profile?.user?.display_name?.split(/\s+/)[0];
  const alerts = useQuery({
    queryKey: ['sana-alerts', company],
    queryFn: async () => {
      const { data, error } = await erp().rpc('sana_alerts', { p_company: company === 'GRP' ? null : company });
      if (error) throw new ApiError(error);
      return ((data as { alerts: Alert[] })?.alerts ?? []);
    },
  });
  const top = (alerts.data ?? []).slice().sort((a, b) => (a.severity === b.severity ? 0 : a.severity === 'critical' ? -1 : 1)).slice(0, 3);
  const onSubmit = (e: FormEvent) => { e.preventDefault(); if (q.trim()) { sana.openAndAsk(q.trim()); setQ(''); } };

  return (
    <section className="relative mb-7 overflow-hidden rounded-[20px] bg-brand-navy text-white">
      {/* Brand ribbons (decorative) */}
      <svg aria-hidden className="pointer-events-none absolute inset-y-0 end-0 h-full w-[60%] opacity-90 rtl:-scale-x-100" viewBox="0 0 600 360" preserveAspectRatio="xMaxYMid slice">
        <path d="M330 -20 L430 -20 L600 120 L600 210 Z" fill="#0B4FE0" opacity=".55" />
        <path d="M420 230 L600 90 L600 150 L470 260 Z" fill="#F7B646" opacity=".55" />
        <path d="M470 380 L600 270 L600 330 L540 380 Z" fill="#08BBA9" opacity=".6" />
        <path d="M250 380 L330 380 L460 280 L400 280 Z" fill="#F4745B" opacity=".35" />
        <path d="M380 0 L600 190" stroke="#18E3C7" strokeWidth="1.5" opacity=".45" />
      </svg>
      <div className="relative grid grid-cols-1 gap-6 p-5 sm:p-8 lg:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)] lg:items-start">
        <div className="min-w-0">
          <PoweredBySana tone="light" />
          <h1 className="mt-3 font-display text-[30px] font-bold leading-tight tracking-[-0.02em] text-white sm:text-[40px]">
            {first ? t(greetingKey(), { name: first }) : t('sana.home.hi')}
          </h1>
          <p className="mt-2 max-w-xl text-[15px] text-white/75 sm:text-[17px]">{t('sana.home.lead')}</p>

          <form onSubmit={onSubmit} className="mt-6 flex items-center gap-2 rounded-[16px] bg-white p-2 shadow-[0_8px_30px_rgba(0,0,0,0.25)]">
            <SanaMark className="ms-1 hidden h-8 w-8 min-[380px]:block" />
            <label htmlFor="sana-home" className="sr-only">{t('sana.placeholder')}</label>
            <input id="sana-home" dir="auto" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('sana.home.placeholder')}
              className="min-w-0 flex-1 bg-transparent px-1 py-2.5 text-[16px] text-[#012746] outline-none placeholder:text-[#5F6F86] focus-visible:outline-none" />
            <button type="button" onClick={() => (mic.listening ? mic.stop() : mic.start(speechLocale(sana.language, i18n.language)))}
              aria-pressed={mic.listening} aria-label={mic.listening ? t('sana.stopListening') : t('sana.speak')} disabled={!mic.supported}
              title={mic.supported ? t('sana.speak') : t('sana.mic.unsupported')}
              className={clsx('grid h-11 w-11 shrink-0 place-items-center rounded-full border transition disabled:opacity-40',
                mic.listening ? 'border-[#F4745B] bg-[#F4745B] text-white' : 'border-[#CBD3E1] text-[#012746] hover:border-[#226AD9] hover:text-[#226AD9]')}>
              <Mic className="h-5 w-5" aria-hidden />
            </button>
            <button type="submit" disabled={!q.trim()} aria-label={t('sana.send')}
              className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-[#226AD9] text-white hover:bg-[#1B56B3] disabled:bg-[#E3E8EF] disabled:text-[#8D9BB3]">
              <ArrowUp className="h-5 w-5" aria-hidden />
            </button>
          </form>
          {mic.listening && <p className="mt-2 text-[13px] text-white/80" aria-live="assertive">{mic.interim || t('sana.listening')}</p>}
          {mic.error && <p role="alert" className="mt-2 text-[13px] text-[#FDA29B]">{mic.error === 'not-allowed' ? t('sana.mic.denied') : t('sana.mic.failed')}</p>}

          <div className="mt-4 flex flex-wrap gap-2">
            {sanaSuggestions(profile?.modules ?? []).map((k) => (
              <button key={k} type="button" onClick={() => sana.openAndAsk(t(k))}
                className="min-h-[36px] rounded-full border border-white/20 bg-white/10 px-3.5 text-[13px] font-medium text-white backdrop-blur hover:bg-white/20">
                {t(k)}
              </button>
            ))}
          </div>
        </div>

        {/* What needs attention: rule checks the user is allowed to see */}
        <div className="min-w-0 rounded-[16px] border border-white/15 bg-white/[0.07] p-4 backdrop-blur-sm">
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-[13px] font-semibold uppercase tracking-[0.12em] text-white/80">{t('sana.home.noticed')}</h2>
            <span className="text-[11px] text-white/55">{t('sana.home.fromRules')}</span>
          </div>
          {alerts.isLoading ? (
            <div className="mt-3 space-y-2">{[0, 1, 2].map((i) => <div key={i} className="h-12 animate-pulse rounded-btn bg-white/10" />)}</div>
          ) : alerts.error ? (
            <p className="mt-3 text-[14px] text-white/75">{t('sana.home.alertsError')}</p>
          ) : top.length === 0 ? (
            <p className="mt-3 text-[14px] text-white/75">{t('sana.home.allClear')}</p>
          ) : (
            <ul className="mt-3 space-y-2">
              {top.map((a, i) => (
                <li key={i} className="flex gap-3 rounded-btn bg-white/[0.06] px-3 py-2.5">
                  <span className={clsx('mt-1.5 h-2 w-2 shrink-0 rounded-full', a.severity === 'critical' ? 'bg-[#F4745B]' : 'bg-[#F7B646]')} aria-label={a.severity} />
                  <span className="min-w-0">
                    <span className="block truncate text-[14px] font-medium text-white">{t(`erp.control.check.${a.check}`, { defaultValue: a.check })} · {a.subject}</span>
                    <span className="block truncate text-[12.5px] text-white/65">{a.detail}</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
          <div className="mt-3 flex items-center justify-between gap-2">
            <Link to="/control" className="inline-flex min-h-[36px] items-center gap-1.5 text-[13px] font-semibold text-[#7FE6D7] hover:underline">
              {t('sana.home.openControl', { n: alerts.data?.length ?? 0 })} <ArrowRight className="h-4 w-4 rtl:rotate-180" aria-hidden />
            </Link>
            {!!alerts.data?.length && (
              <button type="button" onClick={() => sana.openAndAsk(t('sana.q.alerts'))} className="min-h-[36px] rounded-full border border-white/20 px-3 text-[12.5px] font-medium hover:bg-white/10">
                {t('sana.home.askAbout')}
              </button>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}

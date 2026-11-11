import { useId } from 'react';
import clsx from 'clsx';

/** Southfield logo mark: rounded square in brand blue, yellow, teal and coral with the white turn arrow. Vector, so it stays sharp at any size. */
export function LogoMark({ className = 'h-9 w-9', title }: { className?: string; title?: string }) {
  const clip = useId();
  return (
    <svg viewBox="6 6 363 367" className={clsx('shrink-0', className)} role={title ? 'img' : undefined} aria-label={title} aria-hidden={title ? undefined : true}>
      <defs><clipPath id={clip}><rect x="6" y="6" width="363" height="367" rx="62" /></clipPath></defs>
      <g clipPath={`url(#${CSS.escape(clip)})`}>
        <rect x="0" y="0" width="380" height="380" fill="#08BBA9" />
        <path d="M120 0H380V45L287 138L270 112Z" fill="#F7B646" />
        <path d="M0 0H132L262 88Q287 105 287 135V380H0Z" fill="#226AD9" />
        <path d="M287 196V380H186V279Z" fill="#F4745B" />
        <path d="M94 380V215Q94 155 154 155H185V106L287 195L185 279V380Z" fill="#FFFFFF" />
      </g>
    </svg>
  );
}

/**
 * Mark + wordmark. The word "Southfield" is live text in Outfit so it follows the theme
 * (navy on light, white on dark or on the navy sidebar). The brand name stays in Latin letters in Arabic too.
 */
export function Logo({ size = 'md', tone = 'auto', className }: { size?: 'sm' | 'md' | 'lg'; tone?: 'auto' | 'light'; className?: string }) {
  const s = {
    sm: { mark: 'h-8 w-8', word: 'text-[19px]', tag: 'text-[8.5px] tracking-[0.2em]', gap: 'gap-2.5' },
    md: { mark: 'h-10 w-10', word: 'text-[23px]', tag: 'text-[10px] tracking-[0.22em]', gap: 'gap-3' },
    lg: { mark: 'h-16 w-16 sm:h-[84px] sm:w-[84px]', word: 'text-[42px] sm:text-[54px]', tag: 'text-[14.5px] sm:text-[19px] tracking-[0.24em]', gap: 'gap-3 sm:gap-4' },
  }[size];
  return (
    <span dir="ltr" className={clsx('inline-flex items-center', s.gap, className)}>
      <LogoMark className={s.mark} />
      <span className="flex flex-col leading-none">
        <span className={clsx('font-display font-bold tracking-[-0.02em]', s.word, tone === 'light' ? 'text-white' : 'text-ink')}>Southfield</span>
        <span className={clsx('mt-[0.28em] font-display font-semibold uppercase text-brand-teal', s.tag)}>AI-Powered ERP</span>
      </span>
    </span>
  );
}

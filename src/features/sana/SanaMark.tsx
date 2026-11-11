import { useId } from 'react';
import clsx from 'clsx';

/** SANA logo mark (Southfield AI Neural Assistant): four-colour speech bubble with the "S" network of nodes. Vector. */
export function SanaMark({ className = 'h-6 w-6', title }: { className?: string; title?: string }) {
  const id = useId();
  const clip = `sana-${id.replace(/[^a-zA-Z0-9_-]/g, '')}`;
  return (
    <svg viewBox="196 176 840 920" className={clsx('shrink-0', className)} role={title ? 'img' : undefined} aria-label={title} aria-hidden={title ? undefined : true}>
      <defs>
        <clipPath id={clip}>
          <path clipRule="evenodd" d="M500 188H735Q1023 188 1023 476V707Q1023 995 735 995H482Q466 995 452 1006L360 1076Q338 1092 322 1072Q316 1064 316 1052V938Q208 846 208 707V476Q208 188 500 188Z M508 291H722Q917 291 917 486V702Q917 897 722 897H508Q312 897 312 702V486Q312 291 508 291Z" />
        </clipPath>
      </defs>
      <path d="M508 291H722Q917 291 917 486V702Q917 897 722 897H508Q312 897 312 702V486Q312 291 508 291Z" fill="#FFFFFF" />
      <g clipPath={`url(#${clip})`}>
        <rect x="150" y="150" width="950" height="960" fill="#004ED6" />
        <path d="M470 150H1100V248L917 478L900 478Z" fill="#FCB001" />
        <path d="M880 524L1100 248V1100H880Z" fill="#029A96" />
        <path d="M736 780H880V1100H410Z" fill="#FB5B44" />
      </g>
      <g fill="none" stroke="#004ED6" strokeWidth="38" strokeLinecap="round">
        <path d="M460 537C520 492 600 468 752 413" />
        <path d="M460 537C525 585 610 590 767 657" />
        <path d="M767 657C700 690 620 722 509 775" />
      </g>
      <circle cx="460" cy="537" r="64" fill="#004ED6" />
      <circle cx="752" cy="413" r="64" fill="#FCB001" />
      <circle cx="767" cy="657" r="64" fill="#029A96" />
      <circle cx="509" cy="775" r="64" fill="#FB5B44" />
    </svg>
  );
}

/** "Powered by SANA" badge used on the home page and in the assistant panel. */
export function PoweredBySana({ tone = 'auto', className }: { tone?: 'auto' | 'light'; className?: string }) {
  return (
    <span dir="ltr" className={clsx('inline-flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.14em]', tone === 'light' ? 'text-white/80' : 'text-muted', className)}>
      Powered by <SanaMark className="h-4 w-4" /> <span className={clsx('font-display text-[13px] font-bold tracking-[0.06em]', tone === 'light' ? 'text-white' : 'text-ink')}>SANA</span>
    </span>
  );
}

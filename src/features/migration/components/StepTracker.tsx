import clsx from 'clsx';
import { useTranslation } from 'react-i18next';
import { Check } from 'lucide-react';

export type TrackerState = 'done' | 'action' | 'waiting';
export interface TrackerStep { state: TrackerState; note?: string }

const KEYS = ['upload', 'checkFiles', 'loadSap', 'rebuild', 'crossCheck', 'signOff'] as const;

/** 6 steps: Upload, Check files, Load SAP copy, Rebuild app tables, Cross-check, Sign-off. */
export function StepTracker({ steps, current }: { steps: TrackerStep[]; current: number }) {
  const { t } = useTranslation();
  return (
    <ol className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
      {KEYS.map((k, i) => {
        const s = steps[i] ?? { state: 'waiting' as const };
        const isCurrent = i === current;
        return (
          <li
            key={k}
            aria-current={isCurrent ? 'step' : undefined}
            className={clsx('card flex min-h-[72px] items-center gap-3 px-4 py-3', isCurrent && 'border-2 border-primary')}
          >
            <span
              className={clsx(
                'grid h-7 w-7 shrink-0 place-items-center rounded-full text-sm font-semibold',
                s.state === 'done' && 'bg-ok-fg text-white',
                s.state === 'action' && 'border border-[#F5C27A] bg-warn-bg text-warn-fg',
                s.state === 'waiting' && 'bg-neutral-bg text-neutral-fg',
              )}
              aria-hidden
            >
              {s.state === 'done' ? <Check className="h-4 w-4" /> : i + 1}
            </span>
            <div className="min-w-0">
              <div className="text-[15px] font-medium leading-tight">{t(`steps.${k}`)}</div>
              <div className="text-xs text-muted">
                <span className="sr-only">{t(`steps.${s.state === 'action' ? 'action' : s.state}`)} · </span>
                {s.note ?? t(`steps.${s.state === 'action' ? 'action' : s.state}`)}
              </div>
            </div>
          </li>
        );
      })}
    </ol>
  );
}


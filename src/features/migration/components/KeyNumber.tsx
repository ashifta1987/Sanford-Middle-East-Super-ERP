import clsx from 'clsx';
import type { Tone } from './StatusPill';

const valueTone: Record<Tone, string> = {
  ok: 'text-ok-fg', warning: 'text-warn-fg', critical: 'text-crit-fg', info: 'text-info-fg', neutral: 'text-ink',
};

export function KeyNumber({ label, value, note, tone = 'neutral' }: { label: string; value: React.ReactNode; note?: React.ReactNode; tone?: Tone }) {
  return (
    <div className="card p-4">
      <div className="text-sm text-muted">{label}</div>
      <div className={clsx('num mt-1 text-2xl font-semibold', valueTone[tone])}>{value}</div>
      {note && <div className="mt-1 text-xs text-muted">{note}</div>}
    </div>
  );
}

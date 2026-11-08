import clsx from 'clsx';
import { useTranslation } from 'react-i18next';
import type { RunStatus, StepStatus } from '@/lib/database.types';

export type Tone = 'ok' | 'warning' | 'critical' | 'info' | 'neutral';

const toneClass: Record<Tone, string> = {
  ok: 'pill-ok', warning: 'pill-warning', critical: 'pill-crit', info: 'pill-info', neutral: 'pill-neutral',
};

export function StatusPill({ tone, children, className }: { tone: Tone; children: React.ReactNode; className?: string }) {
  return <span className={clsx('pill', toneClass[tone], className)}>{children}</span>;
}

/** P0 › Pills: running states blue, needs_review amber, signed_off green, failed red, cancelled grey. */
export function runTone(s: RunStatus | null | undefined): Tone {
  switch (s) {
    case 'queued': case 'validating': case 'loading': case 'rebuilding': case 'checking': case 'uploading': return 'info';
    case 'needs_review': return 'warning';
    case 'signed_off': return 'ok';
    case 'failed': return 'critical';
    default: return 'neutral';
  }
}

export function stepTone(s: StepStatus | null | undefined): Tone {
  switch (s) {
    case 'ok': return 'ok';
    case 'warning': return 'warning';
    case 'failed': return 'critical';
    case 'running': return 'info';
    default: return 'neutral';
  }
}

export function RunStatusPill({ status }: { status: RunStatus | null | undefined }) {
  const { t } = useTranslation();
  if (!status) return <StatusPill tone="neutral">—</StatusPill>;
  return <StatusPill tone={runTone(status)}>{t(`status.${status}`)}</StatusPill>;
}

export function StepStatusPill({ status }: { status: StepStatus | null | undefined }) {
  const { t } = useTranslation();
  if (!status) return <StatusPill tone="neutral">—</StatusPill>;
  return <StatusPill tone={stepTone(status)}>{t(`status.${status}`)}</StatusPill>;
}

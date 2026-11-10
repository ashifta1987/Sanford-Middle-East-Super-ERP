import { useTranslation } from 'react-i18next';

/** B2: which approval template and stage a waiting document is at (shown on every document's approval card). */
export interface StageItem {
  step?: number | null; template_name?: string | null; stage_name?: string | null; need_approvals?: number | null;
  votes?: Array<{ decision: string }> | null;
}

export function ApprovalStageNote({ items, steps }: { items: StageItem[]; steps?: number }) {
  const { t } = useTranslation();
  const seen = new Set<string>();
  const rows = items.filter((a) => {
    const k = `${a.template_name ?? ''}|${a.stage_name ?? ''}|${a.step ?? ''}`;
    if (!a.template_name && !a.stage_name) return false;
    if (seen.has(k)) return false;
    seen.add(k); return true;
  });
  if (!rows.length) return null;
  return (
    <ul className="mt-1 space-y-0.5 text-xs text-ink-2" data-testid="apr-stage-note">
      {rows.map((a) => {
        const ok = (a.votes ?? []).filter((v) => v.decision === 'approved').length;
        const need = a.need_approvals ?? 1;
        return (
          <li key={`${a.template_name}|${a.stage_name}|${a.step}`}>
            <span className="text-muted">{t('apr.note.template')}</span> <span dir="auto" className="font-medium">{a.template_name ?? '—'}</span>
            {' · '}<span className="text-muted">{steps ? t('apr.note.stageOf', { n: a.step ?? 1, of: steps }) : t('apr.note.stage', { n: a.step ?? 1 })}</span> <span dir="auto" className="font-medium">{a.stage_name ?? '—'}</span>
            {need > 1 && <> · <span className="num">{t('apr.votes', { a: ok, n: need })}</span></>}
          </li>
        );
      })}
    </ul>
  );
}

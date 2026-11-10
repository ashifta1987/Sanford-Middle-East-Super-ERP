import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Card } from './Card';
import { StatusPill } from './StatusPill';
import { Button } from '@/components/Button';
import { SkeletonRows } from '@/components/States';
import { errorMessage } from '@/lib/format';
import { useMigrationSetting, useSaveSetting } from '../more';

/** A12 · settings an opening-balances-only run needs (erp.migration_setting): empty for real companies until Finance gives them. */
export function OpeningSettingsCard({ company }: { company: string }) {
  const { t } = useTranslation();
  const q = useMigrationSetting(company);
  const save = useSaveSetting(company);
  const [v, setV] = useState({ opening_date: '', opening_clearing_acct: '', net_pay_wage_codes: '', vat_period_from: '', vat_period_to: '' });
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    const d = q.data;
    setV({
      opening_date: d?.opening_date ?? '', opening_clearing_acct: d?.opening_clearing_acct ?? '',
      net_pay_wage_codes: (d?.net_pay_wage_codes ?? []).join(', '), vat_period_from: d?.vat_period_from ?? '', vat_period_to: d?.vat_period_to ?? '',
    });
  }, [q.data]);

  const ready = Boolean(q.data?.opening_date && q.data?.opening_clearing_acct);
  const field = (k: keyof typeof v, type = 'text', mono = false) => (
    <div>
      <label htmlFor={`os-${k}`} className="mb-1 block text-sm font-medium">{t(`migration.settings.${k}`)}</label>
      <input id={`os-${k}`} type={type} className={mono ? 'input font-mono' : 'input'} dir={type === 'text' ? 'ltr' : undefined} value={v[k]}
        onChange={(e) => { setSaved(false); setV((x) => ({ ...x, [k]: e.target.value })); }} />
      <p className="mt-0.5 text-xs text-muted">{t(`migration.settings.${k}Help`)}</p>
    </div>
  );

  function onSave() {
    setSaved(false);
    save.mutate({
      opening_date: v.opening_date, opening_clearing_acct: v.opening_clearing_acct.trim(),
      net_pay_wage_codes: v.net_pay_wage_codes.split(',').map((x) => x.trim()).filter(Boolean),
      vat_period_from: v.vat_period_from, vat_period_to: v.vat_period_to,
    }, { onSuccess: () => setSaved(true) });
  }

  return (
    <Card
      title={t('migration.settings.title', { company })}
      actions={<StatusPill tone={ready ? 'ok' : 'warning'}>{ready ? t('migration.settings.ready') : t('migration.settings.missing')}</StatusPill>}
      bodyClassName="space-y-4 p-5"
    >
      {q.isLoading ? <SkeletonRows rows={3} /> : (
        <>
          <p className="text-sm text-muted">{t('migration.settings.body')}</p>
          {field('opening_date', 'date')}
          {field('opening_clearing_acct', 'text', true)}
          {field('net_pay_wage_codes', 'text', true)}
          <div className="grid gap-3 sm:grid-cols-2">
            {field('vat_period_from', 'date')}
            {field('vat_period_to', 'date')}
          </div>
          {save.error && <p role="alert" className="text-sm text-crit-fg">{errorMessage(save.error)}</p>}
          {saved && <p role="status" className="text-sm text-ok-fg">{t('migration.settings.saved')}</p>}
          <div className="flex justify-end">
            <Button variant="primary" onClick={onSave} disabled={save.isPending}>{t('migration.settings.save')}</Button>
          </div>
        </>
      )}
    </Card>
  );
}

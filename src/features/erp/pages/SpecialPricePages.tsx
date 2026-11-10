import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { YesNo, fmtDay, fmtMoney } from '../components/ui';
import type { Row } from '../api';
import { Frame } from './ListPages';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const pct = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : `${Number(v).toLocaleString('en-US', { maximumFractionDigits: 2 })} %`);

/** A12 · Special prices for partners (SAP OSPP, with SPP1 date ranges), read-only copy synced from SAP. */
export function SpecialPricesPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'special_price', table: 'special_price_list',
    select: 'company_code,card_code,card_name,item_code,item_name,price,currency,discount_pct,list_num,valid,valid_from,valid_to,periods,source',
    searchCols: ['card_code', 'card_name', 'item_code', 'item_name'], searchLabel: t('erp.sp.search'),
    filters: [{ key: 'valid', label: t('erp.sp.valid'), options: [['true', t('erp.sp.yes')], ['false', t('erp.sp.no')]], type: 'boolean' }],
    defaultSort: { col: 'card_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.card_code}|${r.item_code}`,
    rowLink: (r) => `/items/${r.company_code}/${encodeURIComponent(r.item_code)}`,
    columns: [
      { key: 'card_code', header: t('erp.sp.bp'), mono: true },
      { key: 'card_name', header: t('erp.col.name'), cell: (r) => <span dir="auto">{r.card_name ?? (String(r.card_code).startsWith('*') ? t('erp.sp.listPeriod') : '—')}</span>, hideBelow: 'md' },
      { key: 'item_code', header: t('erp.col.itemNo'), mono: true },
      { key: 'item_name', header: t('erp.col.description'), cell: (r) => <span dir="auto">{r.item_name ?? '—'}</span>, hideBelow: 'lg' },
      { key: 'price', header: t('erp.col.price'), align: 'end', cell: (r) => fmtMoney(r.price, r.currency) },
      { key: 'discount_pct', header: t('erp.sp.discount'), align: 'end', cell: (r) => pct(r.discount_pct), csv: (r) => r.discount_pct },
      { key: 'valid', header: t('erp.sp.valid'), cell: (r) => <YesNo value={r.valid} />, hideBelow: 'sm' },
      { key: 'valid_to', header: t('erp.sp.validTo'), cell: (r) => (r.valid_to ? fmtDay(r.valid_to) : '—'), hideBelow: 'md' },
      { key: 'periods', header: t('erp.sp.periods'), align: 'end', sortable: false, hideBelow: 'md' },
    ],
  }), [t]);
  return <Frame module="inventory" title={t('erp.sp.title')} desc={t('erp.sp.desc')}><ListScreen config={cfg} /></Frame>;
}

/** A12 · Period and volume discounts (SAP OEDG groups with their EDG1 lines). */
export function DiscountGroupsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'discount_group_line', table: 'discount_group_line',
    select: 'company_code,abs_entry,line_num,obj_type,obj_key,disc_type,discount_pct,pay_for,for_free,up_to,discount_group(kind,obj_code,valid,valid_from,valid_to)',
    searchCols: ['obj_key'], searchLabel: t('erp.dg.search'),
    defaultSort: { col: 'abs_entry', asc: true },
    rowKey: (r) => `${r.company_code}|${r.abs_entry}|${r.line_num}`,
    columns: [
      { key: 'abs_entry', header: t('erp.dg.group'), mono: true },
      { key: 'kind', header: t('erp.dg.for'), sortable: false, cell: (r) => t(`erp.dg.kind.${r.discount_group?.kind ?? 'x'}`, { defaultValue: r.discount_group?.kind ?? '—' }) + (r.discount_group?.obj_code ? ` · ${r.discount_group.obj_code}` : ''), csv: (r) => r.discount_group?.kind },
      { key: 'obj_type', header: t('erp.dg.applies'), cell: (r) => t(`erp.dg.obj.${r.obj_type}`, { defaultValue: String(r.obj_type ?? '—') }) },
      { key: 'obj_key', header: t('erp.dg.key'), mono: true },
      { key: 'discount_pct', header: t('erp.sp.discount'), align: 'end', cell: (r) => pct(r.discount_pct), csv: (r) => r.discount_pct },
      { key: 'up_to', header: t('erp.dg.upTo'), align: 'end', hideBelow: 'md' },
      { key: 'valid_to', header: t('erp.sp.validTo'), sortable: false, cell: (r) => (r.discount_group?.valid_to ? fmtDay(r.discount_group.valid_to) : '—'), hideBelow: 'sm', csv: (r) => r.discount_group?.valid_to },
    ],
  }), [t]);
  return <Frame module="inventory" title={t('erp.dg.title')} desc={t('erp.dg.desc')}><ListScreen config={cfg} /></Frame>;
}

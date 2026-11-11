import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Fields, LiveBadge, PageTitle, SectionCard, StatusTag, YesNo, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { DOC_KINDS, docKindByObj, moduleByKey, type DocKind, type ModuleKey } from '../modules';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

async function rows(table: string, select: string, match: Record<string, string | number>, order?: string, limit = 200) {
  let qb = erp().from(table).select(select).match(match);
  if (order) qb = qb.order(order, { ascending: false });
  const { data, error } = await qb.limit(limit);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as R[];
}
async function single(table: string, select: string, match: Record<string, string | number>) {
  const { data, error } = await erp().from(table).select(select).match(match).maybeSingle();
  if (error) throw new ApiError(error);
  return data as unknown as R | null;
}

function Shell({ module, parent, title, live = true, children, q }: {
  module: ModuleKey; parent: [string, string]; title: string; live?: boolean; children: React.ReactNode; q: { isLoading: boolean; error: unknown; data: unknown; refetch: () => unknown };
}) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  let body: React.ReactNode = children;
  if (q.isLoading) body = <PageLoading />;
  else if (q.error) body = <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>;
  else if (!q.data) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  return (
    <RequireModule module={module}>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], parent, [title, undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live={live} /></span>} />
      {body}
    </RequireModule>
  );
}

function Table({ head, children, empty }: { head: Array<[string, boolean?]>; children: React.ReactNode; empty?: boolean }) {
  const { t } = useTranslation();
  if (empty) return <EmptyState title={t('erp.list.empty')} />;
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] text-[14px]">
        <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
          {head.map(([h, end]) => <th key={h} scope="col" className={`px-4 py-2.5 ${end ? 'text-end' : 'text-start'}`}>{h}</th>)}
        </tr></thead>
        <tbody className="[&>tr]:border-t [&>tr]:border-line [&_td]:px-4 [&_td]:py-2.5">{children}</tbody>
      </table>
    </div>
  );
}

// ---------- Business partner ----------
export function BusinessPartnerDetail() {
  const { t } = useTranslation();
  const { company = '', code = '' } = useParams();
  const q = useQuery({
    queryKey: ['bp', company, code],
    queryFn: async () => {
      const bp = await single('business_partner', '*', { company_code: company, card_code: code });
      if (!bp) return null;
      const docs = await rows('document', 'obj_type,doc_entry,doc_num,doc_kind,status,doc_date,due_date,total,paid,currency', { company_code: company, card_code: code }, 'doc_date', 50);
      return { bp, docs };
    },
  });
  const bp = q.data?.bp;
  return (
    <Shell module="bp" parent={[t('erp.page.bp'), '/bp']} title={bp ? `${bp.card_code} · ${bp.name}` : code} q={q}>
      {bp && (
        <div className="space-y-5">
          <SectionCard title={t('erp.section.general')} right={<StatusTag value={bp.active ? 'active' : 'inactive'} />}>
            <Fields items={[
              [t('erp.col.type'), t(`erp.kind.${bp.kind}`, { defaultValue: bp.kind })], [t('erp.col.foreignName'), bp.foreign_name],
              [t('erp.col.currency'), bp.currency], [t('erp.col.trn'), bp.trn], [t('erp.col.phone'), bp.phone ?? bp.mobile], [t('erp.col.email'), bp.email],
              [t('erp.col.city'), [bp.city, bp.country].filter(Boolean).join(', ')], [t('erp.col.balance'), <span className="num">{fmtMoney(bp.balance, bp.currency)}</span>],
              [t('erp.col.creditLimit'), <span className="num">{fmtMoney(bp.credit_limit, bp.currency)}</span>], [t('erp.col.created'), fmtDay(bp.created_on)],
              [t('erp.col.source'), bp.source === 'sap' ? 'SAP Business One' : bp.source === 'sample' ? t('erp.sampleData') : 'Southfield'],
            ]} />
          </SectionCard>
          <SectionCard title={t('erp.section.documents')}>
            <Table empty={!q.data!.docs.length} head={[[t('erp.col.document')], [t('erp.col.docNo')], [t('erp.col.date')], [t('erp.col.status')], [t('erp.col.total'), true]]}>
              {q.data!.docs.map((d) => {
                const kind = docKindByObj(d.obj_type);
                return (
                  <tr key={`${d.obj_type}-${d.doc_entry}`}>
                    <td>{kind ? t(`erp.doc.${kind}`, { defaultValue: DOC_KINDS[kind].title }) : d.doc_kind}</td>
                    <td className="font-mono text-[13px]">{kind ? <Link className="text-primary hover:underline" to={`/docs/${kind}/${company}/${d.doc_entry}`}>{d.doc_num}</Link> : d.doc_num}</td>
                    <td>{fmtDay(d.doc_date)}</td><td><StatusTag value={d.status} /></td><td className="num text-end">{fmtMoney(d.total, d.currency)}</td>
                  </tr>
                );
              })}
            </Table>
          </SectionCard>
        </div>
      )}
    </Shell>
  );
}

// ---------- Item ----------
export function ItemDetail() {
  const { t } = useTranslation();
  const { company = '', code = '' } = useParams();
  const q = useQuery({
    queryKey: ['item', company, code],
    queryFn: async () => {
      const item = await single('item', '*', { company_code: company, item_code: code });
      if (!item) return null;
      const [prices, stock] = await Promise.all([
        rows('item_price', 'list_num,price,currency,price_list(name)', { company_code: company, item_code: code }),
        rows('stock_balance', 'whs_code,on_hand,committed,on_order,min_stock,warehouse(name)', { company_code: company, item_code: code }),
      ]);
      return { item, prices, stock };
    },
  });
  const it = q.data?.item;
  return (
    <Shell module="inventory" parent={[t('erp.page.items'), '/items']} title={it ? `${it.item_code} · ${it.name}` : code} q={q}>
      {it && (
        <div className="space-y-5">
          <SectionCard title={t('erp.section.general')} right={<StatusTag value={it.active ? 'active' : 'inactive'} />}>
            <Fields items={[
              [t('erp.col.foreignName'), it.foreign_name], [t('erp.col.category'), [it.category, it.subcategory].filter(Boolean).join(' › ')],
              [t('erp.col.barcode'), it.barcode], [t('erp.col.hsCode'), it.hs_code], [t('erp.col.uom'), it.inventory_uom ?? it.sales_uom],
              [t('erp.col.inventoryItem'), <YesNo value={it.is_stock} />], [t('erp.col.salesItem'), <YesNo value={it.is_sold} />], [t('erp.col.purchaseItem'), <YesNo value={it.is_bought} />],
              [t('erp.col.avgCost'), <span className="num">{fmtMoney(it.avg_cost)}</span>], [t('erp.col.preferredSupplier'), it.preferred_supplier],
              [t('erp.col.moq'), fmtQty(it.moq)], [t('erp.col.container'), [it.pcs_20gp, it.pcs_40gp, it.pcs_40hq].some(Boolean) ? `20GP ${fmtQty(it.pcs_20gp)} · 40GP ${fmtQty(it.pcs_40gp)} · 40HQ ${fmtQty(it.pcs_40hq)}` : null],
            ]} />
          </SectionCard>
          <div className="grid gap-5 lg:grid-cols-2">
            <SectionCard title={t('erp.section.stock')}>
              <Table empty={!q.data!.stock.length} head={[[t('erp.col.warehouse')], [t('erp.col.onHand'), true], [t('erp.col.committed'), true], [t('erp.col.ordered'), true], [t('erp.col.available'), true]]}>
                {q.data!.stock.map((s) => (
                  <tr key={s.whs_code}>
                    <td>{s.whs_code} · {s.warehouse?.name}</td>
                    <td className={`num text-end ${Number(s.min_stock) > 0 && Number(s.on_hand) < Number(s.min_stock) ? 'font-semibold text-crit-fg' : ''}`}>{fmtQty(s.on_hand)}</td>
                    <td className="num text-end">{fmtQty(s.committed)}</td><td className="num text-end">{fmtQty(s.on_order)}</td>
                    <td className="num text-end font-medium">{fmtQty(Number(s.on_hand) - Number(s.committed) + Number(s.on_order))}</td>
                  </tr>
                ))}
              </Table>
            </SectionCard>
            <SectionCard title={t('erp.section.prices')}>
              <Table empty={!q.data!.prices.length} head={[[t('erp.col.priceList')], [t('erp.col.price'), true]]}>
                {q.data!.prices.map((p) => <tr key={p.list_num}><td>{p.price_list?.name ?? p.list_num}</td><td className="num text-end">{fmtMoney(p.price, p.currency)}</td></tr>)}
              </Table>
            </SectionCard>
          </div>
        </div>
      )}
    </Shell>
  );
}

// ---------- Marketing / inventory document ----------
export function DocumentDetail() {
  const { t } = useTranslation();
  const { kind = '', company = '', entry = '' } = useParams();
  const def = DOC_KINDS[kind as DocKind];
  const q = useQuery({
    queryKey: ['doc', kind, company, entry],
    enabled: Boolean(def),
    queryFn: async () => {
      const doc = await single('document', '*', { company_code: company, obj_type: def.obj, doc_entry: Number(entry) });
      if (!doc) return null;
      const lines = await rows('document_line', '*', { company_code: company, obj_type: def.obj, doc_entry: Number(entry) });
      lines.sort((a, b) => a.line_num - b.line_num);
      return { doc, lines };
    },
  });
  if (!def) return <PageTitle title={t('erp.notFound')} />;
  const d = q.data?.doc;
  const title = t(`erp.doc.${kind}`, { defaultValue: def.title });
  const net = q.data?.lines.reduce((s, l) => s + Number(l.line_total ?? 0), 0) ?? 0;
  return (
    <Shell module={def.module as ModuleKey} parent={[title, `/docs/${kind}`]} title={d ? `${title} ${d.doc_num}` : entry} q={q}>
      {d && (
        <div className="space-y-5">
          <SectionCard title={t('erp.section.header')} right={<StatusTag value={d.status} />}>
            <Fields items={[
              ...(def.side !== 'none' ? [[def.side === 'customer' ? t('erp.col.customer') : t('erp.col.supplier'),
                <Link className="text-primary hover:underline" to={`/bp/${company}/${encodeURIComponent(d.card_code ?? '')}`}>{d.card_code} · {d.card_name}</Link>] as [string, React.ReactNode]] : []),
              [t('erp.col.date'), fmtDay(d.doc_date)], [t('erp.col.dueDate'), fmtDay(d.due_date)], [t('erp.col.customerRef'), d.customer_ref],
              ...(d.from_whs || d.to_whs ? [[t('erp.col.warehouses'), [d.from_whs, d.to_whs].filter(Boolean).join(' → ')] as [string, React.ReactNode]] : []),
              [t('erp.col.currency'), d.currency], [t('erp.col.remarks'), d.comments],
              [t('erp.col.source'), d.source === 'sap' ? 'SAP Business One' : d.source === 'sample' ? t('erp.sampleData') : 'Southfield'],
            ]} />
          </SectionCard>
          <SectionCard title={t('erp.section.lines')}>
            <Table empty={!q.data!.lines.length} head={[['#'], [t('erp.col.itemNo')], [t('erp.col.description')], [t('erp.col.qty'), true], [t('erp.col.price'), true], [t('erp.col.discount'), true], [t('erp.col.taxCode')], [t('erp.col.warehouse')], [t('erp.col.lineTotal'), true]]}>
              {q.data!.lines.map((l) => (
                <tr key={l.line_num}>
                  <td className="text-muted">{l.line_num + 1}</td>
                  <td className="font-mono text-[13px]"><Link className="text-primary hover:underline" to={`/items/${company}/${encodeURIComponent(l.item_code ?? '')}`}>{l.item_code}</Link></td>
                  <td>{l.description}</td><td className="num text-end">{fmtQty(l.quantity)} {l.uom}</td><td className="num text-end">{fmtMoney(l.price)}</td>
                  <td className="num text-end">{Number(l.discount_pct) ? `${fmtQty(l.discount_pct)} %` : '—'}</td><td>{l.tax_code ?? '—'}</td>
                  <td>{[l.from_whs, l.whs_code].filter(Boolean).join(' → ') || '—'}</td><td className="num text-end font-medium">{fmtMoney(l.line_total)}</td>
                </tr>
              ))}
            </Table>
            <dl className="num ms-auto grid max-w-xs grid-cols-2 gap-x-6 gap-y-1 border-t border-line p-5 text-[15px]">
              <dt className="text-muted">{t('erp.col.net')}</dt><dd className="text-end">{fmtMoney(net)}</dd>
              <dt className="text-muted">{t('erp.col.vat')}</dt><dd className="text-end">{fmtMoney(d.vat_total)}</dd>
              <dt className="font-semibold">{t('erp.col.total')}</dt><dd className="text-end font-semibold">{fmtMoney(d.total, d.currency)}</dd>
              {kind.endsWith('invoice') && <><dt className="text-muted">{t('erp.col.paid')}</dt><dd className="text-end">{fmtMoney(d.paid)}</dd></>}
            </dl>
          </SectionCard>
        </div>
      )}
    </Shell>
  );
}

// ---------- Journal entry ----------
export function JournalDetail() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = useQuery({
    queryKey: ['je', company, id],
    queryFn: async () => {
      const je = await single('journal_entry', '*', { company_code: company, trans_id: Number(id) });
      if (!je) return null;
      const lines = await rows('journal_line', '*', { company_code: company, trans_id: Number(id) });
      lines.sort((a, b) => a.line_id - b.line_id);
      const codes = [...new Set(lines.map((l) => l.acct_code))];
      const { data: accts } = codes.length ? await erp().from('account').select('acct_code,name').eq('company_code', company).in('acct_code', codes) : { data: [] };
      const names = new Map(((accts ?? []) as R[]).map((a) => [a.acct_code, a.name]));
      return { je, lines: lines.map((l): R => ({ ...l, acct_name: names.get(l.acct_code) })) };
    },
  });
  const je = q.data?.je;
  const dr = q.data?.lines.reduce((s, l) => s + Number(l.debit ?? 0), 0) ?? 0;
  const cr = q.data?.lines.reduce((s, l) => s + Number(l.credit ?? 0), 0) ?? 0;
  return (
    <Shell module="financials" parent={[t('erp.page.journals'), '/financials/journals']} title={je ? `${t('erp.col.number')} ${je.number}` : id} q={q}>
      {je && (
        <div className="space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[[t('erp.col.postingDate'), fmtDay(je.ref_date)], [t('erp.col.remarks'), je.memo], [t('erp.col.ref'), [je.ref1, je.ref2].filter(Boolean).join(' / ')],
              [t('erp.col.source'), je.source === 'sap' ? 'SAP Business One' : je.source === 'sample' ? t('erp.sampleData') : 'Southfield']]} />
          </SectionCard>
          <SectionCard title={t('erp.section.lines')} right={<span className={`pill ${Math.abs(dr - cr) < 0.005 ? 'pill-ok' : 'pill-crit'}`}>{Math.abs(dr - cr) < 0.005 ? t('erp.balanced') : t('erp.unbalanced')}</span>}>
            <Table empty={!q.data!.lines.length} head={[[t('erp.col.account')], [t('erp.col.name')], [t('erp.col.remarks')], [t('erp.col.debit'), true], [t('erp.col.credit'), true]]}>
              {q.data!.lines.map((l) => (
                <tr key={l.line_id}><td className="font-mono text-[13px]">{l.acct_code}</td><td>{l.acct_name ?? '—'}</td><td>{l.memo}</td>
                  <td className="num text-end">{Number(l.debit) ? fmtMoney(l.debit) : ''}</td><td className="num text-end">{Number(l.credit) ? fmtMoney(l.credit) : ''}</td></tr>
              ))}
              <tr className="font-semibold"><td colSpan={3}>{t('erp.col.total')}</td><td className="num text-end">{fmtMoney(dr)}</td><td className="num text-end">{fmtMoney(cr)}</td></tr>
            </Table>
          </SectionCard>
        </div>
      )}
    </Shell>
  );
}

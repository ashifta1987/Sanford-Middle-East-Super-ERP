import { useState } from 'react';
import { Navigate, useParams, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Eye } from 'lucide-react';
import { EmptyState } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard } from '../components/ui';
import { PREVIEW_SCREENS, designData as D, moduleByKey } from '../modules';

type Tab = { title: string; sub: string; add?: string; h: string[]; noteLabel?: string; note?: string; rows: string[][] };
const TT_DATA: Record<string, string> = {
  tax: 'TAX', fa: 'FA', setupsales: 'SSAL', setuppur: 'SPUR', setupsvc: 'SSVC', setuphr: 'SHR', dexport: 'DEXP', aging: 'AGING', serials: 'SERIALS',
  batches: 'BATCHES', invcount: 'INVCOUNT', bprec: 'BPREC', frepbud: 'FRBUD', frepcmp: 'FRCMP', taxrep: 'TAXREP', fareports: 'FAREP', dimport: 'DIMP', bins: 'BINS',
};
const TONE: Record<string, string> = { ok: 'pill-ok', acc: 'pill-info', neu: 'pill-neutral', warn: 'pill-warning', bad: 'pill-crit' };
const LV: Record<string, [string, string]> = { F: ['Full', 'pill-ok'], R: ['Read only', 'pill-info'], N: ['None', 'pill-neutral'] };
const AUTH_COLS = ['Admin', 'Financials', 'Sales', 'Purchasing', 'Business Partners', 'Banking', 'Inventory', 'Production', 'Service', 'HR', 'Reports'];

function Grid({ head, rows, emptyText }: { head: string[]; rows: Array<Array<React.ReactNode>>; emptyText: string }) {
  if (!rows.length) return <EmptyState title={emptyText} />;
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[640px] text-[14px]">
        <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">{head.map((h) => <th key={h} scope="col" className="px-4 py-2.5 text-start">{h}</th>)}</tr></thead>
        <tbody>{rows.map((r, i) => <tr key={i} className="border-t border-line">{r.map((c, j) => <td key={j} className="px-4 py-2.5 align-top">{c}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

/**
 * Sub-screens drawn in the canvas design that are not built yet. They are shown so the team can review layout and wording,
 * always under a "Design preview" banner: the content is the design's sample text, nothing is read from or saved to the database.
 */
export function PreviewPage() {
  const { t } = useTranslation();
  const { key = '' } = useParams();
  const [sp] = useSearchParams();
  const [tab, setTab] = useState<string | null>(null);
  const meta = PREVIEW_SCREENS[key];
  if (key === 'migration') return <Navigate to="/backoffice/migration" replace />;
  if (!meta) return <PageTitle title={t('erp.notFound')} />;
  const from = moduleByKey(sp.get('from') ?? '') ?? moduleByKey('administration')!;
  const empty = t('erp.preview.noSample');

  let body: React.ReactNode = null;
  const cards = (D.CARDSETS as Record<string, { list: string[][]; note?: string }>)[key];
  const tt = (D.TT as Record<string, { tabs: string[][] }>)[key];
  if (cards) {
    body = (
      <SectionCard>
        <ul className="grid gap-px bg-line sm:grid-cols-2">
          {cards.list.map(([n, d]) => <li key={n} className="bg-surface p-4"><div className="font-medium">{n}</div><div className="text-sm text-muted">{d}</div></li>)}
        </ul>
        {cards.note && <p className="border-t border-line p-4 text-sm text-ink-2">{cards.note}</p>}
      </SectionCard>
    );
  } else if (tt) {
    const data = D[TT_DATA[key]] as Record<string, Tab>;
    const cur = tab && data[tab] ? tab : tt.tabs[0][0];
    const d = data[cur];
    body = (
      <>
        <div className="mb-4 flex flex-wrap gap-2" role="tablist">
          {tt.tabs.map(([k, label]) => (
            <button key={k} type="button" role="tab" aria-selected={cur === k} onClick={() => setTab(k)}
              className={clsx('min-h-[40px] rounded-full px-4 text-sm font-semibold', cur === k ? 'bg-ink text-surface' : 'border border-line-strong bg-surface hover:bg-surface-2')}>{label}</button>
          ))}
        </div>
        {d && (
          <SectionCard title={d.title}>
            <p className="px-5 pt-4 text-sm text-muted">{d.sub}</p>
            <div className="mt-3">
              <Grid head={d.h} emptyText={empty}
                rows={d.rows.map((r) => [<span className={clsx('pill', TONE[r[4]] ?? 'pill-neutral')}>{r[0]}</span>, <b className="font-medium">{r[1]}</b>, r[2], <span className="text-ink-2">{r[3]}</span>])} />
            </div>
            {d.note && <p className="m-4 rounded-btn border border-primary-line bg-primary-soft px-3 py-2 text-sm text-primary-text"><b>{d.noteLabel}</b> {d.note}</p>}
          </SectionCard>
        )}
      </>
    );
  } else if (key === 'company') {
    body = <SectionCard><dl className="divide-y divide-line">{(D.company as Array<{ l: string; v: string }>).map((c) => <div key={c.l} className="grid gap-1 px-5 py-3 sm:grid-cols-[220px_1fr]"><dt className="text-sm text-muted">{c.l}</dt><dd>{c.v}</dd></div>)}</dl></SectionCard>;
  } else if (key === 'docnum') {
    body = <SectionCard><Grid emptyText={empty} head={['Document', 'Series', 'Prefix', 'Next no.', 'Branch', 'Status']} rows={(D.docnum as Array<Record<string, string>>).map((r) => [r.doc, r.series, <span className="font-mono">{r.prefix}</span>, <span className="font-mono">{r.next}</span>, r.branch, r.st])} /></SectionCard>;
  } else if (key === 'rates') {
    body = <SectionCard><Grid emptyText={empty} head={['Date', 'Entered by', 'USD', 'SAR', 'CNY', 'EUR']} rows={(D.rates as Array<Record<string, string>>).map((r) => [r.d, r.by, r.usd, r.sar, r.cny, r.eur])} /></SectionCard>;
  } else if (key === 'auth') {
    body = <SectionCard><Grid emptyText={empty} head={['Role', ...AUTH_COLS]} rows={(D.AUTH as Array<[string, string]>).map(([role, s]) => [<b className="font-medium">{role}</b>, ...s.split('').map((c) => <span className={clsx('pill', LV[c]?.[1])}>{LV[c]?.[0] ?? c}</span>)])} /></SectionCard>;
  } else if (key === 'approvals') {
    body = <SectionCard><Grid emptyText={empty} head={['Rule', 'Documents', 'When', 'Approvers']} rows={(D.AP as Array<[string, string, string, string[]]>).map((r) => [<b className="font-medium">{r[0]}</b>, r[1], r[2], r[3].join(' → ')])} /></SectionCard>;
  } else if (key === 'gldet') {
    body = <SectionCard><Grid emptyText={empty} head={['Area', 'Posting', 'Account', 'Account name']} rows={(D.GLD as string[][]).map((r) => [<span className="pill pill-info">{r[0]}</span>, <b className="font-medium">{r[1]}</b>, <span className="font-mono">{r[2]}</span>, <span className="text-muted">{r[3]}</span>])} /></SectionCard>;
  } else {
    body = <SectionCard><EmptyState title={t('erp.preview.textOnly')} body={meta.desc} /></SectionCard>;
  }

  return (
    <div>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${from.num} ${from.title}`, `/m/${from.key}`], [meta.parent, undefined], [meta.title, undefined]]}
        eyebrow={meta.parent} title={<span className="inline-flex flex-wrap items-center gap-3">{meta.title} <LiveBadge live={false} /></span>} desc={meta.desc} />
      <div role="note" className="mb-5 flex items-start gap-3 rounded-card border border-warn-fg/40 bg-warn-bg px-4 py-3 text-sm text-warn-fg">
        <Eye className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
        <span><b>{t('erp.preview.bannerTitle')}</b> {t('erp.preview.bannerBody')}</span>
      </div>
      {body}
    </div>
  );
}

import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { UserRoundCheck } from 'lucide-react';
import { erp } from '@/lib/supabase';
import i18n from '@/lib/i18n';
import { ApiError, fmtDate } from '@/lib/format';
import { Card } from '@/features/migration/components/Card';
import { StatusPill, RunStatusPill } from '@/features/migration/components/StatusPill';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { fmtMoney } from '@/features/erp/components/ui';
import { useInbox, type InboxRow, type WorkflowState } from '@/features/erp/salesOrder';
import { StatePill } from '@/features/erp/pages/SalesOrderPages';
import { JeStatePill } from '@/features/erp/pages/JournalPages';
import { DraftStatePill } from '@/features/erp/pages/BankingPages';
import type { DraftState } from '@/features/erp/banking';
import type { RunStatus } from '@/lib/database.types';
import { CountStatePill } from '@/features/erp/pages/InventoryPages';
import type { CountState } from '@/features/erp/inventory';

interface MigrationRow {
  run_id: string; company_code: string; company_name: string; kind: string; status: RunStatus; finished_at: string | null;
  critical_open: number; warning_open: number; signoffs: Array<{ role: string; decision: string }>; my_roles: string[]; waiting_for_me: boolean; live: boolean;
}

/** How long a request has waited, in plain words. */
function waited(iso: string | null) {
  const t = i18n.t.bind(i18n);
  if (!iso) return '—';
  const min = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  if (min < 60) return t('inbox.waitedMin', { n: min });
  const h = Math.round(min / 60);
  if (h < 48) return t('inbox.waitedHours', { n: h });
  return t('inbox.waitedDays', { n: Math.round(h / 24) });
}

/** Approvals inbox (UI/UX spec §4.5): document approvals (erp.approval_inbox) and SAP migration sign-offs (erp.migration_inbox). */
export function ApprovalsPage() {
  const { t } = useTranslation();
  const [sp, setSp] = useSearchParams();
  const tab = sp.get('tab') === 'migration' ? 'migration' : 'docs';
  const inbox = useInbox();
  const waitingN = inbox.data?.waiting.length ?? 0;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-[26px] font-semibold sm:text-[28px]">{t('inbox.title')}</h1>
        <p className="mt-1 text-[15px] text-muted">{tab === 'docs' ? t('inbox.docsSubtitle') : t('inbox.subtitle')}</p>
      </div>
      <div role="tablist" aria-label={t('inbox.title')} className="flex flex-wrap gap-2 border-b border-line">
        {(['docs', 'migration'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} id={`tab-${k}`}
            onClick={() => setSp(k === 'docs' ? {} : { tab: k }, { replace: true })}
            className={clsx('-mb-px inline-flex min-h-[44px] items-center gap-2 border-b-2 px-3 text-[15px] font-medium',
              tab === k ? 'border-primary text-primary' : 'border-transparent text-muted hover:text-ink')}>
            {k === 'docs' ? t('inbox.tabDocs') : t('inbox.tabMigration')}
            {k === 'docs' && waitingN > 0 && <span className="pill pill-warning">{waitingN}</span>}
          </button>
        ))}
      </div>
      {tab === 'docs' ? <DocumentApprovals /> : <MigrationSignoffs />}
    </div>
  );
}

function DocumentApprovals() {
  const { t } = useTranslation();
  const [sp, setSp] = useSearchParams();
  const view = (['waiting', 'sent', 'decided'] as const).find((v) => v === sp.get('view')) ?? 'waiting';
  const q = useInbox();
  const rows: InboxRow[] = q.data?.[view] ?? [];
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
      <div role="tablist" aria-label={t('inbox.tabDocs')} className="flex flex-wrap gap-2">
        {(['waiting', 'sent', 'decided'] as const).map((v) => (
          <button key={v} type="button" role="tab" aria-selected={view === v} id={`view-${v}`}
            onClick={() => setSp(v === 'waiting' ? {} : { view: v }, { replace: true })}
            className={clsx('inline-flex min-h-[40px] items-center gap-2 rounded-full border px-4 text-sm font-medium',
              view === v ? 'border-primary bg-primary-soft text-primary-text' : 'border-line bg-surface text-ink-2 hover:bg-page')}>
            {t(`inbox.${v}`)} <span className="num text-xs">{q.data ? q.data[v].length : ''}</span>
          </button>
        ))}
      </div>
      {/* B5: every authorizer can name their own substitute (SAP B1 "Substitute Authorizer"). */}
      <Link to="/approvals/substitute" id="inbox-substitute-link" className="inline-flex min-h-[40px] items-center gap-2 rounded-btn border border-line bg-surface px-4 text-sm font-medium text-ink hover:bg-page">
        <UserRoundCheck className="h-4 w-4" aria-hidden />{t('apr.sub.mine')}
      </Link>
      </div>
      <Card>
        {q.isLoading ? <SkeletonRows rows={3} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : rows.length === 0 ? (
          <EmptyState title={t(`inbox.empty_${view}`)} body={t(`inbox.emptyBody_${view}`)} />
        ) : (
          <div className="relative overflow-x-auto">
            <table className="w-full text-[14px] sm:min-w-[640px]" data-testid="inbox-table">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('inbox.col.document')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('inbox.col.template')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{view === 'decided' ? t('inbox.col.decision') : t('inbox.col.requester')}</th>
                <th scope="col" className="px-4 py-2.5 text-end">{t('inbox.col.amount')}</th>
                <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{view === 'waiting' ? t('inbox.col.waited') : t('inbox.col.status')}</th>
              </tr></thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.approval_id} className="border-t border-line align-top">
                    <td className="px-4 py-2.5">
                      {r.kind === 'bp_change' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/bp/${r.company_code}/${encodeURIComponent(r.card_code ?? '')}`}>{r.card_code}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('inbox.kind.bp_change')} · {r.card_name}</div>
                        </>
                      ) : r.kind === 'payment' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/banking/payment-drafts/${r.company_code}/${r.doc_entry}`}>{t('bk.draftN', { n: r.doc_no })}</Link>
                          <div dir="auto" className="text-xs text-muted">{t(r.rule_code === 'incoming_payment' ? 'inbox.kind.payment_in' : 'inbox.kind.payment')} · {r.card_code} {r.card_name}</div>
                        </>
                      ) : r.kind === 'inventory_count' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/inventory/counts/${r.company_code}/${r.doc_entry}`}>{r.doc_no}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('inbox.kind.inventory_count')} · {r.card_code} {r.card_name}</div>
                        </>
                      ) : r.kind === 'leave' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/hr/leave/${r.company_code}/${r.doc_entry}`}>{t('hr.leave.titleN', { n: r.doc_no })}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('inbox.kind.leave')} · {r.card_code} {r.card_name}</div>
                        </>
                      ) : r.kind === 'company_details' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/admin/company?company=${r.company_code}`}>{t('adm.co.requestN', { n: r.doc_no })}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('inbox.kind.company_details')} · {r.card_code} {r.card_name}</div>
                        </>
                      ) : r.kind === 'sales_doc_request' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/sales/requests/${r.company_code}/${r.doc_entry}`}>{r.doc_no}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('inbox.kind.sales_doc_request')} · {r.card_code} {r.card_name}</div>
                        </>
                      ) : r.kind === 'journal' ? (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/financials/journals/drafts/${r.company_code}/${r.doc_entry}`}>{t('je.titleDraft', { n: r.doc_no })}</Link>
                          <div dir="auto" className="text-xs text-muted">{t('je.manualJournal')}{r.card_name ? ` · ${r.card_name}` : ''}</div>
                        </>
                      ) : (
                        <>
                          <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/docs/${r.kind}/${r.company_code}/${r.doc_entry}`}>{r.doc_no}</Link>
                          <div dir="auto" className="text-xs text-muted">{t(`inbox.kind.${r.kind}`)} · {r.card_code} {r.card_name}</div>
                        </>
                      )}
                    </td>
                    <td className="px-4 py-2.5">
                      <div dir="auto" data-testid="inbox-template">{r.template_name ?? t(`so.rule.${r.rule_code}`)}</div>
                      <div className="text-xs text-ink-2" data-testid="inbox-stage">
                        {t('apr.stageOfShort', { n: r.step, of: r.stages ?? r.step })} · <span dir="auto">{r.stage_name ?? r.approver_position_name}</span>
                        {(r.need_approvals ?? 1) > 1 && <> · <span className="num">{t('apr.votes', { a: r.approvals ?? 0, n: r.need_approvals })}</span></>}
                      </div>
                      <div className="text-xs text-muted" dir="auto">{t(`so.rule.${r.rule_code}`)} · {r.approver_position_name}</div>
                      {view === 'waiting' && r.on_behalf_of_name && <div className="mt-1"><span className="pill pill-info" data-testid="inbox-behalf">{t('apr.sub.onBehalf', { name: r.on_behalf_of_name })}</span></div>}
                    </td>
                    <td className="px-4 py-2.5 max-md:hidden">
                      {view === 'decided'
                        ? <><span className={clsx('pill', r.decision === 'approved' ? 'pill-ok' : 'pill-crit')}>{t(`erp.status.${r.decision}`)}</span> <span className="text-xs text-muted">{fmtDate(r.decided_at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</span></>
                        : <>{r.requested_by_name ?? '—'}{r.reason && <div dir="auto" className="text-xs italic text-muted">“{r.reason}”</div>}</>}
                    </td>
                    <td className="num px-4 py-2.5 text-end">{r.kind === 'leave' ? t('hr.nDays', { n: r.total }) : (r.kind === 'bp_change' || r.kind === 'company_details') && r.total === null ? '—' : fmtMoney(r.total, r.currency)}</td>
                    <td className="px-4 py-2.5 text-end max-sm:hidden">
                      {view === 'waiting' ? <span className="num text-ink-2">{waited(r.requested_at)}</span>
                        : r.superseded && !r.decision ? <span className="pill pill-neutral">{t('inbox.closed')}</span>
                        : r.kind === 'bp_change' || r.kind === 'company_details' || r.kind === 'sales_doc_request' ? <span className={clsx('pill', r.state === 'approved' ? 'pill-ok' : r.state === 'pending_approval' ? 'pill-warning' : r.state === 'rejected' ? 'pill-crit' : 'pill-neutral')}>{t(`md.req.pill.${r.state}`)}</span>
                        : r.kind === 'payment' ? <DraftStatePill state={r.state as DraftState} />
                        : r.kind === 'inventory_count' ? <CountStatePill state={r.state as CountState} />
                        : r.kind === 'journal' ? <JeStatePill state={r.state === 'approved' ? 'posted' : r.state} /> : <StatePill state={r.state as WorkflowState} />}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
      <p className="text-sm text-muted">{t('inbox.decideOnPage')}</p>
    </div>
  );
}

/** SAP migration sign-offs: unchanged from Stage 1 (B8 is reached from here). */
function MigrationSignoffs() {
  const { t } = useTranslation();
  const q = useQuery({
    queryKey: ['migration', 'inbox'],
    queryFn: async () => {
      const { data, error } = await erp().rpc('migration_inbox');
      if (error) throw new ApiError(error);
      return (data ?? []) as MigrationRow[];
    },
    refetchInterval: 30_000,
  });
  return (
    <Card>
      {q.isLoading ? <SkeletonRows rows={3} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !q.data?.length ? <EmptyState title={t('inbox.empty')} /> : (
        <ul className="divide-y divide-line">
          {q.data.map((r) => {
            const approved = r.signoffs.filter((s) => s.decision === 'approved').length;
            return (
              <li key={r.run_id} className="flex flex-wrap items-center gap-3 px-5 py-4">
                <div className="min-w-0 flex-1">
                  <div className="font-semibold">{r.company_code} · {r.company_name}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-muted">
                    <RunStatusPill status={r.status} />
                    <span>{fmtDate(r.finished_at)}</span>
                    <span>· {t('inbox.signed', { n: approved })}</span>
                    {r.critical_open > 0 && <StatusPill tone="critical">{t('inbox.critical', { n: r.critical_open })}</StatusPill>}
                  </div>
                </div>
                {r.live ? <StatusPill tone="ok">{t('inbox.live')}</StatusPill>
                  : r.waiting_for_me ? <StatusPill tone="warning">{t('inbox.waitingYou')}</StatusPill>
                  : <StatusPill tone="neutral">{t('inbox.done')}</StatusPill>}
                <Link to={`/backoffice/migration/runs/${r.run_id}/check`} className="inline-flex min-h-[44px] items-center rounded-btn bg-primary px-4 font-medium text-white">
                  {t('inbox.open')}
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}

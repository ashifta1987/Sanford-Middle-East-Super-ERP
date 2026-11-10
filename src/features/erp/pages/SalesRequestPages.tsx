import { useState } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Check, X } from 'lucide-react';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { ErrorState, PageLoading } from '@/components/States';
import { Fields, PageTitle, SectionCard, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { Dialog } from '../components/Dialog';
import { salesRequestCancel, salesRequestDecide, useSalesRequest } from '../salesCycle';
import { ErrorBox, Flash } from './AdminPages';

const STATE_TONE: Record<string, string> = { pending_approval: 'pill-warning', approved: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-neutral' };

/** B1 · A credit memo or direct service invoice waiting for approval (erp.sales_doc_request). The last approval creates it. */
export function SalesRequestPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const loc = useLocation();
  const qc = useQueryClient();
  const q = useSalesRequest(company, Number(id));
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejectOpen, setRejectOpen] = useState(false);
  const [note, setNote] = useState('');

  if (q.isLoading) return <RequireModule module="sales"><PageLoading /></RequireModule>;
  if (q.error || !q.data) return <RequireModule module="sales"><PageTitle title={t('sreq.titleN', { n: id })} /><div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div></RequireModule>;
  const { request: r, approvals } = q.data;
  const kind = r.obj_type === 14 ? 'ar_credit_note' : 'ar_invoice';
  const refresh = () => qc.invalidateQueries({ queryKey: ['sales-request', company, Number(id)] });

  async function decide(decision: 'approved' | 'rejected') {
    setErr(null); setFlash(null); setBusy(true);
    try {
      const res = await salesRequestDecide(company, r.request_id, decision, note);
      setRejectOpen(false);
      setFlash(res.state === 'approved' ? t('sreq.flash.approved', { no: res.doc_no }) : res.state === 'rejected' ? t('sreq.flash.rejected') : t('sreq.flash.nextStep'));
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      await refresh();
    } catch (e) { setErr(errorMessage(e)); setRejectOpen(false); } finally { setBusy(false); }
  }
  async function cancel() {
    setErr(null); setFlash(null); setBusy(true);
    try {
      await salesRequestCancel(company, r.request_id, '');
      setFlash(t('sreq.flash.cancelled'));
      await refresh();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }

  return (
    <RequireModule module="sales">
      <PageTitle crumbs={[[t('nav.home'), '/'], [t('inbox.title'), '/approvals'], [r.doc_no_req, undefined]]}
        eyebrow={t(`sreq.kind.${kind}`)}
        title={<span className="inline-flex flex-wrap items-center gap-3"><span dir="ltr">{r.doc_no_req}</span><span className={clsx('pill', STATE_TONE[r.state])} data-testid="sreq-state">{t(`md.req.pill.${r.state}`)}</span></span>}
        desc={t('sreq.desc')} />
      <Flash text={flash} />
      <ErrorBox text={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('sreq.what')}>
            <Fields items={[
              [t('erp.col.customer'), r.card_code ? `${r.card_code} · ${r.card_name ?? ''}` : '—'],
              [t('erp.col.total'), fmtMoney(r.total, r.currency)],
              [t('erp.col.postingDate'), fmtDay(r.header.doc_date)],
              [t('sreq.requestedBy'), `${r.requested_by_name ?? '—'} · ${fmtDate(r.requested_at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}`],
              [t('num.pick.label'), r.series ?? t('num.pick.default')],
              [t('sreq.document'), r.doc_entry ? <Link className="font-mono text-primary hover:underline" to={`/docs/${kind}/${company}/${r.doc_entry}`}>{r.doc_no}</Link> : t('sreq.notYet')],
            ]} />
            {r.reason && <p className="border-t border-line px-5 py-3 text-sm italic text-ink-2" dir="auto">“{r.reason}”</p>}
          </SectionCard>
          <SectionCard title={t('sreq.why')}>
            <ul className="divide-y divide-line" data-testid="sreq-checks">
              {r.checks.map((c, i) => <li key={i} className="bg-warn-bg/40 px-5 py-3 text-sm" dir="auto">{c.message}</li>)}
            </ul>
          </SectionCard>
          <SectionCard title={t('sreq.lines')}>
            <div className="overflow-x-auto">
              <table className="w-full text-[14px]">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2 text-start">#</th>
                  <th scope="col" className="px-4 py-2 text-start">{t('sreq.line')}</th>
                  <th scope="col" className="px-4 py-2 text-end">{t('erp.col.qty')}</th>
                  <th scope="col" className="px-4 py-2 text-end">{t('so.unitPrice')}</th>
                  <th scope="col" className="px-4 py-2 text-end">{t('so.disc')}</th>
                </tr></thead>
                <tbody>
                  {r.lines.map((l, i) => (
                    <tr key={i} className="border-t border-line">
                      <td className="px-4 py-2 text-muted">{i + 1}</td>
                      <td className="px-4 py-2 font-mono text-[13px]" dir="ltr">{l.base_doc_entry ? t('sreq.baseLine', { entry: l.base_doc_entry, line: Number(l.base_line) + 1 }) : String(l.item_code ?? '')}</td>
                      <td className="num px-4 py-2 text-end">{fmtQty(l.qty)}</td>
                      <td className="num px-4 py-2 text-end">{l.price != null ? fmtMoney(l.price) : '—'}</td>
                      <td className="num px-4 py-2 text-end">{l.discount_pct != null && l.discount_pct !== '' ? `${fmtQty(l.discount_pct)}%` : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          {q.data.can_decide && (
            <SectionCard title={t('sreq.yourApproval')}>
              <div className="space-y-3 p-5" data-testid="sreq-decide">
                <p className="text-sm text-ink-2">{t('sreq.yourApprovalBody')}</p>
                <Button variant="success" id="sreq-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('sreq.approve')}</Button>
                <Button variant="danger" id="sreq-reject" className="w-full" disabled={busy} onClick={() => { setNote(''); setRejectOpen(true); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('sreq.reject')}</Button>
              </div>
            </SectionCard>
          )}
          {q.data.is_requester && (r.state === 'pending_approval' || r.state === 'rejected') && (
            <SectionCard title={t('sreq.yours')}>
              <div className="space-y-3 p-5">
                <p className="text-sm text-ink-2">{t('sreq.yoursBody')}</p>
                <Button variant="secondary" id="sreq-cancel" className="w-full" disabled={busy} onClick={cancel}>{t('sreq.cancel')}</Button>
              </div>
            </SectionCard>
          )}
          <SectionCard title={t('sreq.steps')}>
            <ol className="divide-y divide-line" data-testid="sreq-steps">
              {approvals.map((a, i) => (
                <li key={i} className="px-5 py-3 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span>{t('sreq.stepN', { n: a.step })} · <span dir="auto">{a.approver_name}</span></span>
                    <span className={clsx('pill', a.decision === 'approved' ? 'pill-ok' : a.decision === 'rejected' ? 'pill-crit' : a.superseded ? 'pill-neutral' : 'pill-warning')}>
                      {a.decision ? t(`erp.status.${a.decision}`) : a.superseded ? t('inbox.closed') : t('md.req.pill.pending_approval')}
                    </span>
                  </div>
                  {a.decided_by_name && <p className="mt-1 text-xs text-muted">{a.decided_by_name} · {fmtDate(a.decided_at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</p>}
                  {a.note && <p className="mt-1 text-xs italic text-ink-2" dir="auto">“{a.note}”</p>}
                </li>
              ))}
            </ol>
          </SectionCard>
        </aside>
      </div>
      <Dialog open={rejectOpen} title={t('sreq.rejectTitle', { no: r.doc_no_req })} onClose={() => setRejectOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setRejectOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="sreq-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('sreq.reject')}</Button></>}>
        <label className="block text-xs font-medium text-muted">{t('sreq.rejectNote')}
          <textarea id="sreq-note" className="input mt-1 min-h-[88px] text-[15px] text-ink" dir="auto" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
      </Dialog>
    </RequireModule>
  );
}

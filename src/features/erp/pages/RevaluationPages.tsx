import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Ban, Send } from 'lucide-react';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { Fields, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { Dialog } from '../components/Dialog';
import { moduleByKey } from '../modules';
import { fmtRate } from '../currency';
import { fxrCancel, fxrPost, fxrPreview, useFxrInfo, useFxrSetup, type FxrPreview, type FxrRow } from '../revaluation';
import { CompanyPicker, ErrorBox, Flash, useAdminCompany } from './AdminPages';

/** B5 · Financials › Exchange Rate Differences: period-end revaluation of open foreign-currency A/R and A/P items. */
function FxrFrame({ title, desc, actions, crumbs, children }: { title: string; desc?: string; actions?: ReactNode; crumbs?: Array<[string, string | undefined]>; children: ReactNode }) {
  const { t } = useTranslation();
  const m = moduleByKey('financials')!;
  return (
    <RequireModule module="financials">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/financials'], ...(crumbs ?? [[title, undefined] as [string, undefined]])]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
      {children}
    </RequireModule>
  );
}

function lastMonthEnd() {
  const d = new Date();
  return new Date(Date.UTC(d.getFullYear(), d.getMonth(), 0)).toISOString().slice(0, 10);
}

function GainCell({ v, cur }: { v: number; cur: string }) {
  const n = Number(v);
  return <span className={clsx('num font-medium', n > 0 ? 'text-ok-fg' : n < 0 ? 'text-crit-fg' : 'text-muted')}>{fmtMoney(n, cur)}</span>;
}

function RowsTable({ rows, cur }: { rows: FxrRow[]; cur: string }) {
  const { t } = useTranslation();
  return (
    <div className="relative overflow-x-auto">
      <table className="w-full text-[14px] sm:min-w-[720px]" data-testid="fxr-rows">
        <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
          <th scope="col" className="px-4 py-2.5 text-start">{t('fxr.col.partner')}</th>
          <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('fxr.col.side')}</th>
          <th scope="col" className="px-4 py-2.5 text-end">{t('fxr.col.openFc')}</th>
          <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('fxr.col.book')}</th>
          <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('fxr.col.rate')}</th>
          <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('fxr.col.new')}</th>
          <th scope="col" className="px-4 py-2.5 text-end">{t('fxr.col.gain')}</th>
        </tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.side}|${r.currency}|${r.card_code}`} className="border-t border-line" data-testid="fxr-row" data-card={r.card_code}>
              <td className="px-4 py-2.5"><span className="font-mono text-[13px] text-muted">{r.card_code}</span> <span dir="auto">{r.card_name}</span>
                <div className="text-xs text-muted">{t('fxr.docs', { n: r.docs })}</div></td>
              <td className="px-4 py-2.5 max-sm:hidden">{t(`fxr.side.${r.side}`)}</td>
              <td className="num px-4 py-2.5 text-end">{fmtMoney(r.open_fc, r.currency)}</td>
              <td className="num px-4 py-2.5 text-end max-md:hidden">{fmtMoney(r.book_lc, cur)}</td>
              <td className="num px-4 py-2.5 text-end max-md:hidden">{fmtRate(r.rate)}</td>
              <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(r.new_lc, cur)}</td>
              <td className="px-4 py-2.5 text-end"><GainCell v={r.gain} cur={cur} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function FxRevaluationPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const setup = useFxrSetup(company);
  const S = setup.data;
  const loc = useLocation();
  const [flash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [date, setDate] = useState(lastMonthEnd());
  const [curs, setCurs] = useState<string[]>([]);
  const [rates, setRates] = useState<Record<string, string>>({});
  const [auto, setAuto] = useState(true);
  const [memo, setMemo] = useState('');
  const [preview, setPreview] = useState<FxrPreview | null>(null);
  const [pErr, setPErr] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const cur = S?.local_currency ?? '';
  const choices = useMemo(() => [...new Set([...(S?.open_currencies ?? []), ...(S?.currencies ?? [])])].filter((c) => c !== cur), [S, cur]);
  const key = JSON.stringify({ company, date, curs, rates });
  useEffect(() => {
    if (!company || !S?.can_write || !date) { setPreview(null); return; }
    let live = true;
    const tm = setTimeout(() => {
      fxrPreview(company, { date, currencies: curs, rates }).then((r) => { if (live) { setPreview(r); setPErr(null); } })
        .catch((e) => { if (live) { setPreview(null); setPErr(errorMessage(e)); } });
    }, 350);
    return () => { live = false; clearTimeout(tm); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, S?.can_write]);

  async function post() {
    setErr(null); setBusy(true); setConfirm(false);
    try {
      const r = await fxrPost(company, { date, currencies: curs, rates, auto_reverse: auto, memo });
      await qc.invalidateQueries({ queryKey: ['fxr-setup', company] });
      nav(`/financials/fx-revaluation/${company}/${r.reval_id}`, { state: { flash: t('fxr.flash.posted', { no: r.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const P = preview;
  const blocked = Boolean(P?.already || P?.later);
  const nothing = P && !P.rows.some((r) => Number(r.diff) !== 0);

  return (
    <FxrFrame title={t('fxr.title')} desc={t('fxr.desc')} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      {setup.isLoading ? <div className="card"><SkeletonRows rows={5} /></div> : setup.error ? <div className="card"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div> : S && (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="min-w-0 space-y-5">
            {!S.can_write && <p className="rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-ink-2" data-testid="fxr-readonly">{t('fxr.readOnly')}</p>}
            <SectionCard title={t('fxr.selection')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                <label className="block text-xs font-medium text-muted">{t('fxr.date')} <span className="text-crit-fg">*</span>
                  <input id="fxr-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} disabled={!S.can_write} />
                </label>
                <fieldset className="min-w-0">
                  <legend className="text-xs font-medium text-muted">{t('fxr.currencies')}</legend>
                  <div className="mt-1 flex flex-wrap gap-2" data-testid="fxr-currencies">
                    {choices.length === 0 && <span className="text-sm text-muted">{t('fxr.noOpen')}</span>}
                    {choices.map((c) => (
                      <label key={c} className={clsx('inline-flex min-h-[40px] items-center gap-2 rounded-full border px-3 text-sm', curs.includes(c) ? 'border-primary bg-primary-soft text-primary-text' : 'border-line')}>
                        <input type="checkbox" id={`fxr-cur-${c}`} className="h-4 w-4" checked={curs.includes(c)} disabled={!S.can_write}
                          onChange={(e) => setCurs((cs) => (e.target.checked ? [...cs, c] : cs.filter((x) => x !== c)))} />{c}
                      </label>
                    ))}
                  </div>
                  <p className="mt-1 text-xs text-muted">{t('fxr.currenciesHint')}</p>
                </fieldset>
                {(P?.currencies ?? []).map((c) => (
                  <label key={c} className="block text-xs font-medium text-muted">{t('fxr.rateFor', { cur: c, local: cur })}
                    <input id={`fxr-rate-${c}`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" placeholder={P?.rates[c]?.list_rate != null ? fmtRate(P.rates[c].list_rate) : ''}
                      value={rates[c] ?? ''} onChange={(e) => setRates((r) => ({ ...r, [c]: e.target.value }))} disabled={!S.can_write} />
                    <span className="mt-1 block text-xs text-muted">{P?.rates[c]?.overridden ? t('fxr.rateTyped') : t('fxr.rateList', { date: fmtDay(date) })}</span>
                  </label>
                ))}
                <label className="inline-flex min-h-[44px] items-center gap-2 text-sm sm:col-span-2">
                  <input id="fxr-auto" type="checkbox" className="h-4 w-4" checked={auto} onChange={(e) => setAuto(e.target.checked)} disabled={!S.can_write} />
                  {t('fxr.autoReverse', { date: P ? fmtDay(P.reverse_date) : '—' })}
                </label>
                {!auto && <p className="text-xs text-warn-fg sm:col-span-2" data-testid="fxr-no-reverse">{t('fxr.noReverseNote')}</p>}
                <label className="block text-xs font-medium text-muted sm:col-span-2">{t('fxr.memo')}
                  <input id="fxr-memo" dir="auto" className="input mt-1 text-[15px] text-ink" value={memo} onChange={(e) => setMemo(e.target.value)} disabled={!S.can_write} />
                </label>
              </div>
            </SectionCard>
            {S.can_write && (
              <SectionCard title={t('fxr.preview')}>
                {pErr ? <p role="alert" className="p-5 text-sm text-crit-fg" dir="auto" data-testid="fxr-preview-error">{pErr}</p>
                  : !P ? <SkeletonRows rows={3} />
                  : P.rows.length === 0 ? <EmptyState title={t('fxr.emptyTitle')} body={t('fxr.emptyBody', { date: fmtDay(P.date) })} />
                  : <RowsTable rows={P.rows} cur={cur} />}
              </SectionCard>
            )}
          </div>
          <aside className="min-w-0 space-y-5">
            <SectionCard title={t('fxr.summary')}>
              <div className="space-y-3 p-5" data-testid="fxr-summary">
                {P ? (
                  <dl className="num grid grid-cols-2 gap-y-1 text-[15px]">
                    <dt className="text-muted">{t('fxr.gain')}</dt><dd className="text-end text-ok-fg" data-testid="fxr-gain">{fmtMoney(P.totals.gain, cur)}</dd>
                    <dt className="text-muted">{t('fxr.loss')}</dt><dd className="text-end text-crit-fg" data-testid="fxr-loss">{fmtMoney(P.totals.loss, cur)}</dd>
                    <dt className="font-semibold">{t('fxr.net')}</dt><dd className="text-end font-semibold" data-testid="fxr-net">{fmtMoney(P.totals.net, cur)}</dd>
                  </dl>
                ) : <p className="text-sm text-muted">{t('fxr.fill')}</p>}
                <p className="text-xs text-muted">{t('fxr.what', { gain: S.gain_acct ?? t('fxr.notSet'), loss: S.loss_acct ?? t('fxr.notSet') })}</p>
                {P?.already && <p role="alert" className="text-sm font-medium text-crit-fg" data-testid="fxr-already">{t('fxr.already', { no: P.already.doc_no })}</p>}
                {P?.later && <p role="alert" className="text-sm font-medium text-crit-fg">{t('fxr.later', { no: P.later.doc_no, date: fmtDay(P.later.date) })}</p>}
                {nothing && !blocked && <p className="text-sm text-muted">{t('fxr.nothing')}</p>}
                <Button variant="primary" id="fxr-post" className="w-full" icon={<Send className="h-4 w-4" aria-hidden />}
                  disabled={busy || !S.can_write || !P || blocked || Boolean(nothing)} disabledReason={!S.can_write ? t('fxr.readOnly') : undefined} onClick={() => setConfirm(true)}>
                  {busy ? t('so.saving') : t('fxr.post')}
                </Button>
              </div>
            </SectionCard>
            <SectionCard title={t('fxr.history')}>
              {S.history.length === 0 ? <p className="p-5 text-sm text-muted">{t('fxr.noHistory')}</p> : (
                <ul className="divide-y divide-line" data-testid="fxr-history">
                  {S.history.map((h) => (
                    <li key={h.reval_id} className="flex items-start justify-between gap-3 px-5 py-3">
                      <div className="min-w-0">
                        <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/financials/fx-revaluation/${company}/${h.reval_id}`}>{h.doc_no}</Link>
                        <div className="text-xs text-muted">{fmtDay(h.reval_date)} · {h.currencies.join(', ')}</div>
                      </div>
                      <div className="text-end">
                        <GainCell v={h.net} cur={cur} />
                        <div><span className={clsx('pill', h.state === 'posted' ? 'pill-ok' : 'pill-neutral')}>{t(`fxr.state.${h.state}`)}</span></div>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </aside>
        </div>
      )}
      <Dialog open={confirm} title={t('fxr.confirmTitle')} onClose={() => setConfirm(false)}
        footer={<><Button variant="secondary" onClick={() => setConfirm(false)}>{t('je.keep')}</Button><Button variant="primary" id="fxr-post-confirm" disabled={busy} onClick={post}>{t('fxr.post')}</Button></>}>
        <p className="text-sm text-ink-2">{P && t(auto ? 'fxr.confirmBody' : 'fxr.confirmBodyNoReverse', { date: fmtDay(P.date), net: fmtMoney(P.totals.net, cur), rev: fmtDay(P.reverse_date), n: P.rows.length })}</p>
      </Dialog>
    </FxrFrame>
  );
}

export function FxRevaluationDetailPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const { company = '', id = '' } = useParams();
  const loc = useLocation();
  const q = useFxrInfo(company, Number(id));
  const R = q.data;
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  async function cancel() {
    setErr(null); setBusy(true);
    try {
      await fxrCancel(company, Number(id), reason);
      setOpen(false); setFlash(t('fxr.flash.cancelled'));
      await qc.invalidateQueries({ queryKey: ['fxr-info', company, Number(id)] });
      await qc.invalidateQueries({ queryKey: ['fxr-setup', company] });
    } catch (e) { setErr(errorMessage(e)); setOpen(false); } finally { setBusy(false); }
  }
  const crumbs: Array<[string, string | undefined]> = [[t('fxr.title'), `/financials/fx-revaluation?company=${company}`], [R?.doc_no ?? id, undefined]];
  if (q.isLoading) return <FxrFrame title={t('fxr.title')} crumbs={crumbs}><PageLoading /></FxrFrame>;
  if (q.error || !R) return <FxrFrame title={t('fxr.title')} crumbs={crumbs}><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} />}</div></FxrFrame>;
  const cur = R.local_currency;
  return (
    <FxrFrame title={t('fxr.titleN', { no: R.doc_no })} crumbs={crumbs} desc={t('fxr.detailDesc', { date: fmtDay(R.reval_date) })}
      actions={R.can_cancel ? <Button variant="danger" id="fxr-cancel" icon={<Ban className="h-4 w-4" aria-hidden />} onClick={() => setOpen(true)}>{t('fxr.cancel')}</Button> : undefined}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('fxr.date'), fmtDay(R.reval_date)],
              [t('fxr.currencies'), R.currencies.join(', ')],
              [t('fxr.rates'), Object.entries(R.rates).map(([c, x]) => `${c} ${fmtRate(x.rate)}${x.overridden ? ` (${t('fxr.typed')})` : ''}`).join(' · ')],
              [t('fxr.reversal'), R.reverse_date ? fmtDay(R.reverse_date) : t('fxr.noReversal')],
              [t('fxr.net'), fmtMoney(R.net, cur)],
              [t('erp.col.status'), <span key="s" className={clsx('pill', R.state === 'posted' ? 'pill-ok' : 'pill-neutral')} data-testid="fxr-state">{t(`fxr.state.${R.state}`)}</span>],
              [t('fxr.memo'), R.memo],
              ...(R.state === 'cancelled' ? [[t('fxr.cancelReason'), R.cancel_reason] as [string, string | null]] : []),
            ]} />
          </SectionCard>
          <SectionCard title={t('fxr.lines')}><RowsTable rows={R.lines} cur={cur} /></SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('fxr.journals')}>
            <ul className="divide-y divide-line text-sm" data-testid="fxr-journals">
              {R.journals.map((j) => (
                <li key={j.trans_id} className="px-5 py-3">
                  <Link className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${j.trans_id}`}>{j.trans_id}</Link>
                  <span className="text-muted"> · {fmtDay(j.ref_date)}</span>
                  <div className="text-xs text-muted" dir="auto">{j.memo}</div>
                  <div className="num text-xs">{fmtMoney(j.total, cur)}</div>
                </li>
              ))}
            </ul>
          </SectionCard>
          <SectionCard title={t('adm.audit.title')}>
            <ul className="divide-y divide-line text-sm">
              {R.activity.map((a, i) => (
                <li key={i} className="px-5 py-2.5"><span className="font-medium">{t(`fxr.action.${a.action}`, { defaultValue: a.action })}</span>
                  <div className="text-xs text-muted">{a.actor_name} · {fmtDate(a.at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</div></li>
              ))}
            </ul>
          </SectionCard>
        </aside>
      </div>
      <Dialog open={open} title={t('fxr.cancelTitle')} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="fxr-cancel-confirm" disabled={busy} onClick={cancel}>{t('fxr.cancel')}</Button></>}>
        <p className="mb-3 text-sm text-ink-2">{t('fxr.cancelBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('fxr.cancelReason')}
          <input id="fxr-cancel-reason" dir="auto" className="input mt-1 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
      </Dialog>
    </FxrFrame>
  );
}

import { useEffect, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Ban, Save, Send } from 'lucide-react';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { Fields, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { Dialog } from '../components/Dialog';
import { moduleByKey } from '../modules';
import { fmtRate } from '../currency';
import { cvdCancel, cvdPost, cvdPreview, sysCurSave, useCvdInfo, useCvdSetup, useSysCur, type CvdPreview, type CvdRow } from '../conversion';
import { CompanyPicker, ErrorBox, Flash, useAdminCompany } from './AdminPages';

/** B6 · Financials › Exchange Rates and Revaluation › Conversion Differences (system currency rounding, SAP B1 style). */
function CvdFrame({ title, desc, actions, crumbs, children }: { title: string; desc?: string; actions?: ReactNode; crumbs?: Array<[string, string | undefined]>; children: ReactNode }) {
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

const todayIso = () => new Date().toISOString().slice(0, 10);

function Who({ r }: { r: Pick<CvdRow, 'kind' | 'acct_code' | 'acct_name' | 'card_code' | 'card_name'> }) {
  const { t } = useTranslation();
  return r.kind === 'partner'
    ? <><span className="font-mono text-[13px] text-muted">{r.card_code}</span> <span dir="auto">{r.card_name}</span>
        <div className="text-xs text-muted">{t('cvd.onAccount', { acct: r.acct_code })}</div></>
    : <><span className="font-mono text-[13px] text-muted">{r.acct_code}</span> <span dir="auto">{r.acct_name}</span></>;
}

function RowsTable({ rows, lc, sc }: { rows: CvdRow[]; lc: string; sc: string }) {
  const { t } = useTranslation();
  return (
    <div className="relative overflow-x-auto">
      <table className="w-full text-[14px] sm:min-w-[640px]" data-testid="cvd-rows">
        <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
          <th scope="col" className="px-4 py-2.5 text-start">{t('cvd.col.who')}</th>
          <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('cvd.col.kind')}</th>
          <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('cvd.col.lc', { cur: lc })}</th>
          <th scope="col" className="px-4 py-2.5 text-end">{t('cvd.col.sc', { cur: sc })}</th>
          <th scope="col" className="px-4 py-2.5 text-end">{t('cvd.col.correction')}</th>
        </tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.kind}|${r.acct_code}|${r.card_code ?? ''}`} className="border-t border-line" data-testid="cvd-row" data-acct={r.acct_code} data-card={r.card_code ?? ''}>
              <td className="px-4 py-2.5"><Who r={r} /><div className="text-xs text-muted">{t('cvd.journals', { n: r.journals })}</div></td>
              <td className="px-4 py-2.5 max-sm:hidden">{t(`cvd.kind.${r.kind}`)}</td>
              <td className="num px-4 py-2.5 text-end max-md:hidden">{fmtMoney(r.lc_balance, lc)}</td>
              <td className="num px-4 py-2.5 text-end">{fmtMoney(r.sc_balance, sc)}</td>
              <td className="num px-4 py-2.5 text-end font-medium">{Number(r.sc_balance) > 0 ? t('cvd.cr', { n: fmtMoney(r.sc_balance, sc) }) : t('cvd.dr', { n: fmtMoney(-Number(r.sc_balance), sc) })}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function ConversionDiffPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const setup = useCvdSetup(company);
  const S = setup.data;
  const loc = useLocation();
  const [flash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [date, setDate] = useState(todayIso());
  const [accounts, setAccounts] = useState(true);
  const [partners, setPartners] = useState(true);
  const [memo, setMemo] = useState('');
  const [preview, setPreview] = useState<CvdPreview | null>(null);
  const [pErr, setPErr] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const key = JSON.stringify({ company, date, accounts, partners });
  useEffect(() => {
    if (!company || !S?.can_write || !S.active || !date) { setPreview(null); return; }
    let live = true;
    const tm = setTimeout(() => {
      cvdPreview(company, { date, accounts, partners }).then((r) => { if (live) { setPreview(r); setPErr(null); } })
        .catch((e) => { if (live) { setPreview(null); setPErr(errorMessage(e)); } });
    }, 350);
    return () => { live = false; clearTimeout(tm); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, S?.can_write, S?.active]);

  async function post() {
    setErr(null); setBusy(true); setConfirm(false);
    try {
      const r = await cvdPost(company, { date, accounts, partners, ...(memo ? { memo } : {}) });
      await qc.invalidateQueries({ queryKey: ['cvd-setup', company] });
      nav(`/financials/conversion-differences/${company}/${r.run_id}`, { state: { flash: t('cvd.flash.posted', { no: r.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const P = preview;
  const lc = S?.local_currency ?? '';
  const scur = S?.sys_currency ?? '';

  return (
    <CvdFrame title={t('cvd.title')} desc={t('cvd.desc')} actions={<CompanyPicker {...sc} />}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      {setup.isLoading ? <div className="card"><SkeletonRows rows={5} /></div> : setup.error ? <div className="card"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div> : S && (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="min-w-0 space-y-5">
            {!S.active && (
              <div className="card p-5" data-testid="cvd-inactive">
                <p className="font-semibold">{t('cvd.inactiveTitle')}</p>
                <p className="mt-1 text-sm text-ink-2">{t('cvd.inactiveBody', { company, cur: lc })}</p>
                <Link className="mt-3 inline-flex text-sm font-medium text-primary hover:underline" to={`/admin/company?company=${company}`}>{t('cvd.toCompany')}</Link>
              </div>
            )}
            {S.active && !S.can_write && <p className="rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-ink-2" data-testid="cvd-readonly">{t('cvd.readOnly')}</p>}
            {S.active && (
              <SectionCard title={t('cvd.selection')}>
                <div className="grid gap-4 p-5 sm:grid-cols-2">
                  <label className="block text-xs font-medium text-muted">{t('cvd.date')} <span className="text-crit-fg">*</span>
                    <input id="cvd-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} disabled={!S.can_write} />
                    <span className="mt-1 block text-xs text-muted">{t('cvd.dateHint')}</span>
                  </label>
                  <fieldset className="min-w-0">
                    <legend className="text-xs font-medium text-muted">{t('cvd.include')}</legend>
                    <div className="mt-1 flex flex-wrap gap-2">
                      {([['accounts', accounts, setAccounts], ['partners', partners, setPartners]] as const).map(([k, v, set]) => (
                        <label key={k} className={clsx('inline-flex min-h-[44px] items-center gap-2 rounded-full border px-3 text-sm', v ? 'border-primary bg-primary-soft text-primary-text' : 'border-line')}>
                          <input type="checkbox" id={`cvd-${k}`} className="h-4 w-4" checked={v} disabled={!S.can_write} onChange={(e) => set(e.target.checked)} />{t(`cvd.inc.${k}`)}
                        </label>
                      ))}
                    </div>
                  </fieldset>
                  <label className="block text-xs font-medium text-muted sm:col-span-2">{t('cvd.memo')}
                    <input id="cvd-memo" dir="auto" className="input mt-1 text-[15px] text-ink" value={memo} onChange={(e) => setMemo(e.target.value)} disabled={!S.can_write} />
                  </label>
                </div>
              </SectionCard>
            )}
            {S.active && S.can_write && (
              <SectionCard title={t('cvd.preview')}>
                {pErr ? <p role="alert" className="p-5 text-sm text-crit-fg" dir="auto" data-testid="cvd-preview-error">{pErr}</p>
                  : !P ? <SkeletonRows rows={3} />
                  : P.rows.length === 0 ? <EmptyState title={t('cvd.emptyTitle')} body={t('cvd.emptyBody', { date: fmtDay(P.date), cur: scur })} />
                  : <RowsTable rows={P.rows} lc={lc} sc={scur} />}
              </SectionCard>
            )}
          </div>
          <aside className="min-w-0 space-y-5">
            <SectionCard title={t('cvd.summary')}>
              <div className="space-y-3 p-5" data-testid="cvd-summary">
                <dl className="grid grid-cols-2 gap-y-1 text-[15px]">
                  <dt className="text-muted">{t('cvd.localCur')}</dt><dd className="text-end font-mono">{lc}</dd>
                  <dt className="text-muted">{t('cvd.sysCur')}</dt><dd className="text-end font-mono" data-testid="cvd-sys-cur">{scur}</dd>
                  {P && <>
                    <dt className="text-muted">{t('cvd.debit')}</dt><dd className="num text-end">{fmtMoney(P.totals.debit, scur)}</dd>
                    <dt className="text-muted">{t('cvd.credit')}</dt><dd className="num text-end">{fmtMoney(P.totals.credit, scur)}</dd>
                    <dt className="font-semibold">{t('cvd.net')}</dt><dd className="num text-end font-semibold" data-testid="cvd-net">{fmtMoney(P.totals.net, scur)}</dd>
                  </>}
                </dl>
                <p className="text-xs text-muted">{t('cvd.what', { acct: S.acct_code ?? t('cvd.notSet'), cur: scur, lc })}</p>
                {S.active && (
                  <Button variant="primary" id="cvd-post" className="w-full" icon={<Send className="h-4 w-4" aria-hidden />}
                    disabled={busy || !S.can_write || !P || P.rows.length === 0} disabledReason={!S.can_write ? t('cvd.readOnly') : undefined} onClick={() => setConfirm(true)}>
                    {busy ? t('so.saving') : t('cvd.post')}
                  </Button>
                )}
              </div>
            </SectionCard>
            <SectionCard title={t('cvd.history')}>
              {S.history.length === 0 ? <p className="p-5 text-sm text-muted">{t('cvd.noHistory')}</p> : (
                <ul className="divide-y divide-line" data-testid="cvd-history">
                  {S.history.map((h) => (
                    <li key={h.run_id} className="flex items-start justify-between gap-3 px-5 py-3">
                      <div className="min-w-0">
                        <Link className="font-mono text-[13px] font-medium text-primary hover:underline" to={`/financials/conversion-differences/${company}/${h.run_id}`}>{h.doc_no}</Link>
                        <div className="text-xs text-muted">{fmtDay(h.run_date)} · {t('cvd.nLines', { n: h.lines })}</div>
                      </div>
                      <div className="text-end">
                        <span className="num text-sm">{fmtMoney(h.credit, h.sys_currency)}</span>
                        <div><span className={clsx('pill', h.state === 'posted' ? 'pill-ok' : 'pill-neutral')}>{t(`cvd.state.${h.state}`)}</span></div>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </aside>
        </div>
      )}
      <Dialog open={confirm} title={t('cvd.confirmTitle')} onClose={() => setConfirm(false)}
        footer={<><Button variant="secondary" onClick={() => setConfirm(false)}>{t('je.keep')}</Button><Button variant="primary" id="cvd-post-confirm" disabled={busy} onClick={post}>{t('cvd.post')}</Button></>}>
        <p className="text-sm text-ink-2">{P && t('cvd.confirmBody', { n: P.rows.length, date: fmtDay(P.date), cur: scur, lc })}</p>
      </Dialog>
    </CvdFrame>
  );
}

export function ConversionDiffDetailPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const { company = '', id = '' } = useParams();
  const loc = useLocation();
  const q = useCvdInfo(company, Number(id));
  const R = q.data;
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  async function cancel() {
    setErr(null); setBusy(true);
    try {
      await cvdCancel(company, Number(id), reason);
      setOpen(false); setFlash(t('cvd.flash.cancelled'));
      await qc.invalidateQueries({ queryKey: ['cvd-info', company, Number(id)] });
      await qc.invalidateQueries({ queryKey: ['cvd-setup', company] });
    } catch (e) { setErr(errorMessage(e)); setOpen(false); } finally { setBusy(false); }
  }
  const crumbs: Array<[string, string | undefined]> = [[t('cvd.title'), `/financials/conversion-differences?company=${company}`], [R?.doc_no ?? id, undefined]];
  if (q.isLoading) return <CvdFrame title={t('cvd.title')} crumbs={crumbs}><PageLoading /></CvdFrame>;
  if (q.error || !R) return <CvdFrame title={t('cvd.title')} crumbs={crumbs}><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} />}</div></CvdFrame>;
  const scur = R.sys_currency;
  const lc = R.local_currency;
  return (
    <CvdFrame title={t('cvd.titleN', { no: R.doc_no })} crumbs={crumbs} desc={t('cvd.detailDesc', { date: fmtDay(R.run_date), cur: scur })}
      actions={R.can_cancel ? <Button variant="danger" id="cvd-cancel" icon={<Ban className="h-4 w-4" aria-hidden />} onClick={() => setOpen(true)}>{t('cvd.cancel')}</Button> : undefined}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('cvd.date'), fmtDay(R.run_date)],
              [t('cvd.sysCur'), scur],
              [t('cvd.include'), [R.accounts && t('cvd.inc.accounts'), R.partners && t('cvd.inc.partners')].filter(Boolean).join(' · ')],
              [t('cvd.debit'), fmtMoney(R.debit, scur)],
              [t('cvd.credit'), fmtMoney(R.credit, scur)],
              [t('cvd.account'), R.acct_code ?? '—'],
              [t('erp.col.status'), <span key="s" className={clsx('pill', R.state === 'posted' ? 'pill-ok' : 'pill-neutral')} data-testid="cvd-state">{t(`cvd.state.${R.state}`)}</span>],
              [t('cvd.memo'), R.memo],
              ...(R.state === 'cancelled' ? [[t('cvd.cancelReason'), R.cancel_reason] as [string, string | null]] : []),
            ]} />
          </SectionCard>
          <SectionCard title={t('cvd.lines')}><RowsTable rows={R.lines} lc={lc} sc={scur} /></SectionCard>
          {R.journals.map((j) => (
            <SectionCard key={j.trans_id} title={t('cvd.journalN', { n: j.trans_id, date: fmtDay(j.ref_date) })}>
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px] sm:min-w-[560px]" data-testid="cvd-journal">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('cvd.col.account')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('cvd.col.lcDrCr', { cur: lc })}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('cvd.col.scDebit', { cur: scur })}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('cvd.col.scCredit', { cur: scur })}</th>
                  </tr></thead>
                  <tbody>
                    {j.lines.map((l, i) => (
                      <tr key={i} className="border-t border-line">
                        <td className="px-4 py-2.5"><span className="font-mono text-[13px]">{l.acct_code}</span>{l.short_name && l.short_name !== l.acct_code && <span className="text-muted"> · {l.short_name}</span>}</td>
                        <td className="num px-4 py-2.5 text-end text-muted max-sm:hidden">{fmtMoney(Number(l.debit) - Number(l.credit), lc)}</td>
                        <td className="num px-4 py-2.5 text-end">{Number(l.sys_debit ?? 0) ? fmtMoney(l.sys_debit, scur) : ''}</td>
                        <td className="num px-4 py-2.5 text-end">{Number(l.sys_credit ?? 0) ? fmtMoney(l.sys_credit, scur) : ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="border-t border-line px-5 py-3 text-xs text-muted">
                <Link className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${j.trans_id}`}>{j.trans_id}</Link> · {t('cvd.noLc', { lc })}
              </p>
            </SectionCard>
          ))}
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('adm.audit.title')}>
            <ul className="divide-y divide-line text-sm" data-testid="cvd-activity">
              {R.activity.map((a, i) => (
                <li key={i} className="px-5 py-2.5"><span className="font-medium">{t(`cvd.action.${a.action}`, { defaultValue: a.action })}</span>
                  <div className="text-xs text-muted">{a.actor_name} · {fmtDate(a.at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</div></li>
              ))}
            </ul>
          </SectionCard>
        </aside>
      </div>
      <Dialog open={open} title={t('cvd.cancelTitle')} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="cvd-cancel-confirm" disabled={busy} onClick={cancel}>{t('cvd.cancel')}</Button></>}>
        <p className="mb-3 text-sm text-ink-2">{t('cvd.cancelBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('cvd.cancelReason')}
          <input id="cvd-cancel-reason" dir="auto" className="input mt-1 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
      </Dialog>
    </CvdFrame>
  );
}

/** B6 · Administration › Company Details: the optional system currency (default = the local currency = inactive). */
export function SystemCurrencyCard({ company }: { company: string }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const q = useSysCur(company);
  const I = q.data;
  const [cur, setCur] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { setCur(null); setErr(null); setMsg(null); }, [company]);
  if (q.isLoading) return <SectionCard title={t('adm.co.sys.title')}><SkeletonRows rows={2} /></SectionCard>;
  if (q.error || !I) return <SectionCard title={t('adm.co.sys.title')}>{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : null}</SectionCard>;
  const value = cur ?? I.system_currency;
  const options = [...new Set([I.local_currency, ...I.currencies])];
  async function save() {
    setErr(null); setMsg(null); setBusy(true);
    try {
      const r = await sysCurSave(company, value);
      setMsg(r.active ? t('adm.co.sys.saved', { cur: r.system_currency }) : t('adm.co.sys.off'));
      setCur(null);
      await qc.invalidateQueries({ queryKey: ['sys-cur', company] });
      await qc.invalidateQueries({ queryKey: ['cvd-setup', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <SectionCard title={t('adm.co.sys.title')}>
      <div className="space-y-3 p-5" data-testid="adm-sys-cur">
        <p className="text-sm text-ink-2">{t('adm.co.sys.desc', { lc: I.local_currency })}</p>
        <label className="block text-xs font-medium text-muted">{t('adm.co.sys.label')}
          <select id="adm-sys-cur" className="input mt-1 font-mono text-[15px] text-ink" value={value} disabled={!I.can_write || I.locked} onChange={(e) => setCur(e.target.value)}>
            {options.map((c) => <option key={c} value={c}>{c === I.local_currency ? t('adm.co.sys.local', { cur: c }) : c}</option>)}
          </select>
        </label>
        <p className="text-xs" data-testid="adm-sys-cur-state">
          <span className={clsx('pill', I.active ? 'pill-ok' : 'pill-neutral')}>{I.active ? t('adm.co.sys.active', { cur: I.system_currency }) : t('adm.co.sys.inactive')}</span>
          {I.active && <span className="ms-2 text-muted">{I.rate_today != null ? t('adm.co.sys.rateToday', { rate: fmtRate(I.rate_today), lc: I.local_currency, cur: I.system_currency }) : t('adm.co.sys.noRateToday', { cur: I.system_currency })}</span>}
        </p>
        {I.locked && <p className="text-xs text-muted" data-testid="adm-sys-cur-locked">{t('adm.co.sys.locked', { n: I.journals })}</p>}
        {err && <p role="alert" className="text-sm text-crit-fg" dir="auto">{err}</p>}
        {msg && <p role="status" className="text-sm text-ok-fg">{msg}</p>}
        {I.can_write && !I.locked && (
          <Button variant="secondary" id="adm-sys-cur-save" className="w-full" disabled={busy || value === I.system_currency} icon={<Save className="h-4 w-4" aria-hidden />} onClick={save}>{t('adm.co.sys.save')}</Button>
        )}
      </div>
    </SectionCard>
  );
}

import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Download, FileDown, FileSpreadsheet, FileText, ListChecks, PencilLine, X } from 'lucide-react';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { KeyNumber } from '../components/KeyNumber';
import { RunStatusPill, StatusPill, type Tone } from '../components/StatusPill';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { useAuth } from '@/auth/AuthProvider';
import { useGoLive, useOverview, useResolveIssue, useReview, useSetReportFigure, useSign, useStatus } from '../queries';
import { useRunRealtime } from '../useRunRealtime';
import { FINANCE_ROWS, MORE_AREAS, issueDetail, money, qty, stockRows, summarise } from '../check/derive';
import { downloadText, moreApi, reportCsv } from '../more';
import { errorMessage, fmtDate } from '@/lib/format';
import type { IssueStatus, MigrationReviewRow, SignRole } from '@/lib/database.types';

type Tr = (k: string, o?: Record<string, unknown>) => string;
const ROLES: SignRole[] = ['finance', 'it', 'business'];
const sevTone: Record<string, Tone> = { critical: 'critical', warning: 'warning', info: 'info' };
const when = (iso?: string | null) => (iso ? `${fmtDate(iso)}, ${new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}` : '');

/** B8 Cross-check and sign-off (design/B8-cross-check-signoff.jpg). */
export function CrossCheckPage() {
  const { t } = useTranslation();
  const tr = t as unknown as Tr;
  const { runId = '' } = useParams();
  useRunRealtime(runId);
  const { profile, isMigrationAdmin, signRoles } = useAuth();
  const status = useStatus(runId);
  const review = useReview(runId);
  const overview = useOverview();
  const head = status.data?.[0];
  const code = head?.company_code ?? '';

  const companyName = profile?.companies.find((c) => c.company_code === code)?.legal_name
    ?? overview.data?.find((c) => c.company_code === code)?.company_name ?? '';
  const currency = profile?.companies.find((c) => c.company_code === code)?.currency ?? overview.data?.find((c) => c.company_code === code)?.currency ?? 'AED';
  const goLiveAt = overview.data?.find((c) => c.company_code === code)?.go_live_at ?? null;

  const all = useMemo(() => review.data ?? [], [review.data]);
  const issues = useMemo(() => all.filter((r) => r.item === 'issue'), [all]);
  const checks = useMemo(() => all.filter((r) => r.item === 'check' && (!code || r.company_code === code)), [all, code]);
  const areas = useMemo(() => summarise({ t: tr, checks, issues: issues.filter((i) => !i.company_code || i.company_code === code) }), [tr, checks, issues, code]);
  const finance = useMemo(() => FINANCE_ROWS.map((name) => checks.find((c) => c.area === 'finance' && c.name === name)).filter(Boolean) as MigrationReviewRow[], [checks]);
  const stockValueTotal = checks.find((c) => c.area === 'stock' && c.name === 'on hand value, all warehouses');
  const stock = useMemo(() => stockRows(checks), [checks]);
  const required = useMemo(() => checks.filter((c) => c.report_required), [checks]);

  // ---- permissions (the server checks every call again)
  const canResolve = isMigrationAdmin;
  const canEnterFigures = (isMigrationAdmin || signRoles.includes('finance')) && head?.run_status === 'needs_review';
  const isCfo = signRoles.includes('business');

  const [figuresOpen, setFiguresOpen] = useState(false);
  const [busyReport, setBusyReport] = useState<null | 'pdf' | 'xlsx' | 'csv'>(null);
  const [reportErr, setReportErr] = useState<string | null>(null);

  if (status.isLoading) return <PageLoading />;
  if (status.error) return <ErrorState error={status.error} onRetry={() => status.refetch()} />;
  if (!head) return <EmptyState title={t('migration.run.notFound')} />;

  const signoffs = head.signoffs ?? [];
  const approved = signoffs.filter((s) => s.decision === 'approved').length;
  const waitingRoles = ROLES.filter((r) => !signoffs.some((s) => s.role === r && s.decision === 'approved'));
  const passed = checks.filter((c) => c.ok).length;
  const acceptedCount = issues.filter((i) => i.status === 'accepted').length;

  async function report(kind: 'pdf' | 'xlsx' | 'csv') {
    setBusyReport(kind);
    setReportErr(null);
    try {
      // the server builds (and audits) the auditor's report: run, steps, files, checks, issues, sign-offs, register, attachments
      const extra = await moreApi.report(runId);
      const generatedAt = new Date().toISOString();
      if (kind === 'csv') {
        downloadText(reportCsv(extra), `sanford-migration-${code}-${runId.slice(0, 8)}-${generatedAt.slice(0, 10)}.csv`);
        return;
      }
      const mod = await import('../check/report');
      const data = { runId, company: code, companyName, status: head!.run_status, generatedAt, checks: all.filter((r) => r.item === 'check'), issues, signoffs, extra };
      await (kind === 'pdf' ? mod.downloadPdf(data) : mod.downloadExcel(data));
    } catch (e) {
      setReportErr(errorMessage(e));
    } finally {
      setBusyReport(null);
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <PageHeader crumb={t('migration.check.breadcrumb')} title={t('migration.check.titleFull', { code })} subtitle={t('migration.check.subtitle')} />
        <div className="flex flex-wrap items-center gap-2">
          <RunStatusPill status={head.run_status} />
          <Link to={`/backoffice/migration/fields?company=${code}`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-line bg-surface px-4 font-medium hover:bg-page">
            <ListChecks className="h-4 w-4" aria-hidden /> {t('migration.fields.open')}
          </Link>
          <details className="relative">
            <summary className="inline-flex min-h-[44px] cursor-pointer list-none items-center gap-2 rounded-btn border border-line bg-surface px-4 font-medium hover:bg-page">
              <Download className="h-4 w-4" aria-hidden /> {busyReport ? t('migration.check.building') : t('migration.check.download')}
            </summary>
            <div className="absolute end-0 z-10 mt-1 w-48 rounded-btn border border-line bg-surface p-1 shadow-lg">
              <button type="button" disabled={!!busyReport || review.isLoading} onClick={() => void report('pdf')} className="flex min-h-[44px] w-full items-center gap-2 rounded-md px-3 hover:bg-page">
                <FileText className="h-4 w-4" aria-hidden /> {t('migration.check.pdf')}
              </button>
              <button type="button" disabled={!!busyReport || review.isLoading} onClick={() => void report('xlsx')} className="flex min-h-[44px] w-full items-center gap-2 rounded-md px-3 hover:bg-page">
                <FileSpreadsheet className="h-4 w-4" aria-hidden /> {t('migration.check.excel')}
              </button>
              <button type="button" disabled={!!busyReport || review.isLoading} onClick={() => void report('csv')} className="flex min-h-[44px] w-full items-center gap-2 rounded-md px-3 hover:bg-page">
                <FileDown className="h-4 w-4" aria-hidden /> {t('migration.check.csv')}
              </button>
            </div>
          </details>
        </div>
      </div>
      {reportErr && <p role="alert" className="card bg-crit-bg p-4 text-crit-fg">{reportErr}</p>}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <KeyNumber label={t('migration.check.checksPassed')} value={`${passed} of ${checks.length}`} tone={passed === checks.length ? 'ok' : 'warning'}
          note={t('migration.check.checksNote', { n: acceptedCount })} />
        <KeyNumber label={t('migration.check.critical')} value={String(head.critical_open)} tone={head.critical_open ? 'critical' : 'neutral'}
          note={head.critical_open ? t('migration.check.criticalNoteOpen') : t('migration.check.criticalNoteNone')} />
        <KeyNumber label={t('migration.check.notes')} value={String(head.warning_open)} tone={head.warning_open ? 'warning' : 'neutral'}
          note={t('migration.check.notesNote', { missing: head.report_missing })} />
        <KeyNumber label={t('migration.check.signoffs')} value={`${approved} of 3`} tone={approved === 3 ? 'ok' : 'neutral'}
          note={waitingRoles.length ? t('migration.check.signoffsNote', { who: waitingRoles.map((r) => t(`migration.check.role.${r}`).split(' · ')[0]).join(', ') }) : t('migration.check.signoffsDone')} />
      </div>

      <Card title={t('migration.check.glance')}>
        {review.isLoading ? <SkeletonRows rows={3} /> : review.error ? <ErrorState error={review.error} onRetry={() => review.refetch()} /> : (
          <ul className="grid sm:grid-cols-2 lg:grid-cols-4">
            {areas.map((a) => (
              <li key={a.area} className="border-b border-e border-line p-4 sm:p-5">
                <div className="flex items-start justify-between gap-2">
                  <span className="font-semibold">{t(`migration.check.area.${a.area}`)}</span>
                  <StatusPill tone={a.tone}>{a.pill}</StatusPill>
                </div>
                <p className="mt-1 text-sm text-muted">{a.detail}</p>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card
        title={t('migration.check.financeTitle', { currency })}
        actions={
          <div className="flex flex-wrap items-center gap-3">
            <span className="text-sm text-muted">{t('migration.check.financeNote')}</span>
            {canEnterFigures && required.length > 0 && (
              <Button icon={<PencilLine className="h-4 w-4" aria-hidden />} onClick={() => setFiguresOpen(true)}>{t('migration.check.enterOpen')}</Button>
            )}
          </div>
        }
      >
        {review.isLoading ? <SkeletonRows /> : (
          <DataTable
            caption={t('migration.check.financeTitle', { currency })}
            rows={[...finance, ...(stockValueTotal ? [stockValueTotal] : [])]}
            rowKey={(r) => r.id}
            empty={<EmptyState body={t('migration.check.areaDetail.none')} />}
            columns={[
              { key: 'c', header: t('migration.check.colCheck'), cell: (r) => t(`migration.check.fin.${r.name}`, { defaultValue: r.name }) },
              { key: 'rep', header: t('migration.check.colReport'), align: 'end', cell: (r) => <span title={r.report_source ?? undefined}>{r.report_value != null ? money(r.report_value) : '—'}</span> },
              { key: 'raw', header: t('migration.check.colRaw'), align: 'end', cell: (r) => money(r.raw_value) },
              { key: 'app', header: t('migration.check.colApp'), align: 'end', cell: (r) => money(r.app_value) },
              { key: 'd', header: t('migration.check.colDiff'), align: 'end', cell: (r) => <strong>{money(r.difference ?? 0)}</strong> },
              { key: 'res', header: t('migration.check.colResult'), cell: (r) => <FinanceResult r={r} t={tr} /> },
            ]}
          />
        )}
      </Card>

      <MoreChecksCard checks={checks} loading={review.isLoading} />

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
        <div className="min-w-0 space-y-6">
          <Card title={t('migration.check.stockTitle')}>
            {review.isLoading ? <SkeletonRows rows={3} /> : (
              <DataTable
                caption={t('migration.check.stockTitle')}
                rows={stock.rows}
                rowKey={(r) => r.whs}
                empty={<EmptyState body={t('migration.check.areaDetail.none')} />}
                columns={[
                  { key: 'w', header: t('migration.check.colWhs'), cell: (r) => r.whs },
                  { key: 'qs', header: t('migration.check.colPcsSap'), align: 'end', cell: (r) => qty(r.qtySap) },
                  { key: 'qa', header: t('migration.check.colPcsApp'), align: 'end', cell: (r) => qty(r.qtyApp) },
                  { key: 'vs', header: t('migration.check.colValSap'), align: 'end', cell: (r) => money(r.valSap) },
                  { key: 'va', header: t('migration.check.colValApp'), align: 'end', cell: (r) => money(r.valApp) },
                  { key: 'ok', header: t('migration.check.colResult'), cell: (r) => <StatusPill tone={r.ok ? 'ok' : 'critical'}>{r.ok ? t('migration.check.ok') : t('migration.check.rawAppDiffer')}</StatusPill> },
                ]}
                footer={stock.total && (
                  <tr className="border-t-2 border-line font-semibold">
                    <th scope="row" className="px-4 py-2.5 text-start">{t('migration.check.total')}</th>
                    <td className="num px-4 py-2.5 text-end">{qty(stock.total.qtySap)}</td>
                    <td className="num px-4 py-2.5 text-end">{qty(stock.total.qtyApp)}</td>
                    <td className="num whitespace-nowrap px-4 py-2.5 text-end">{money(stock.total.valSap)}</td>
                    <td className="num whitespace-nowrap px-4 py-2.5 text-end">{money(stock.total.valApp)}</td>
                    <td className="px-4 py-2.5"><StatusPill tone={stock.total.ok ? 'ok' : 'critical'}>{stock.total.ok ? t('migration.check.ok') : t('migration.check.rawAppDiffer')}</StatusPill></td>
                  </tr>
                )}
              />
            )}
          </Card>

          <IssuesCard runId={runId} issues={issues} canResolve={canResolve && head.run_status !== 'signed_off'} loading={review.isLoading} />
        </div>

        <div className="min-w-0 space-y-6">
          <SignoffCard runId={runId} code={code} status={head.run_status} criticalOpen={head.critical_open} signoffs={signoffs} signRoles={signRoles} />
          <GoLive runId={runId} code={code} signedOff={head.run_status === 'signed_off'} isCfo={isCfo} liveAt={goLiveAt} />
          {!isMigrationAdmin && <Link to="/approvals" className="block text-center text-sm text-primary underline">{t('nav.approvals')}</Link>}
        </div>
      </div>

      {figuresOpen && <FiguresSheet runId={runId} company={code} rows={required} onClose={() => setFiguresOpen(false)} />}
    </div>
  );
}

/** A12 · checks 5.3, 5.5-5.10, duplicates, register and coexistence: failed first, values as returned. */
function MoreChecksCard({ checks, loading }: { checks: MigrationReviewRow[]; loading: boolean }) {
  const { t } = useTranslation();
  const [all, setAll] = useState(false);
  const rows = useMemo(() => {
    const order = new Map<string, number>(MORE_AREAS.map((a, i) => [a, i]));
    return checks.filter((c) => order.has(c.area))
      .sort((a, b) => Number(a.ok !== false) - Number(b.ok !== false) || (order.get(a.area)! - order.get(b.area)!) || a.name.localeCompare(b.name));
  }, [checks]);
  if (!loading && rows.length === 0) return null;
  const shown = all ? rows : rows.slice(0, 25);
  const failed = rows.filter((r) => r.ok === false).length;
  return (
    <Card
      title={t('migration.check.moreTitle')}
      actions={<span className="text-sm text-muted">{t('migration.check.moreNote', { n: rows.length, failed })}</span>}
    >
      {loading ? <SkeletonRows rows={4} /> : (
        <>
          <DataTable
            caption={t('migration.check.moreTitle')}
            rows={shown}
            rowKey={(r) => r.id}
            minWidth={820}
            columns={[
              { key: 'a', header: t('migration.check.colArea'), cell: (r) => <StatusPill tone="info">{t(`migration.check.area.${r.area}`, { defaultValue: r.area })}</StatusPill> },
              { key: 'c', header: t('migration.check.colCheck'), cell: (r) => <span dir="auto">{r.name}</span> },
              { key: 's', header: t('migration.check.colSap'), align: 'end', cell: (r) => money(r.sap_value) },
              { key: 'raw', header: t('migration.check.colRaw'), align: 'end', cell: (r) => money(r.raw_value) },
              { key: 'app', header: t('migration.check.colApp'), align: 'end', cell: (r) => money(r.app_value) },
              { key: 'd', header: t('migration.check.colDiff'), align: 'end', cell: (r) => <strong>{money(r.difference)}</strong> },
              { key: 'res', header: t('migration.check.colResult'), cell: (r) => (
                (r.detail as { skipped?: boolean } | null)?.skipped ? <StatusPill tone="neutral">{t('migration.check.skipped')}</StatusPill>
                  : <StatusPill tone={r.ok === false ? 'critical' : 'ok'}>{r.ok === false ? t('migration.check.rawAppDiffer') : t('migration.check.ok')}</StatusPill>) },
            ]}
          />
          {rows.length > 25 && (
            <div className="border-t border-line px-5 py-3">
              <Button className="min-h-[40px] px-3 text-sm" onClick={() => setAll((x) => !x)}>{all ? t('migration.check.showFewer') : t('migration.check.showAll', { n: rows.length })}</Button>
            </div>
          )}
        </>
      )}
    </Card>
  );
}

function FinanceResult({ r, t }: { r: MigrationReviewRow; t: Tr }) {
  if (r.report_required && r.report_value == null) return <StatusPill tone="warning">{t('migration.check.enterFigure')}</StatusPill>;
  if (r.report_ok === false) return <StatusPill tone="critical">{t('migration.check.reportDiffers')}</StatusPill>;
  if (r.ok === false) return <StatusPill tone="critical">{t('migration.check.rawAppDiffer')}</StatusPill>;
  return <StatusPill tone="ok">{t('migration.check.ok')}</StatusPill>;
}

/** Side panel: one input per report_required check + a source note. Save = migration_set_report_figure per changed row. */
function FiguresSheet({ runId, company, rows, onClose }: { runId: string; company: string; rows: MigrationReviewRow[]; onClose: () => void }) {
  const { t } = useTranslation();
  const ref = useRef<HTMLDialogElement>(null);
  const save = useSetReportFigure(runId);
  const [values, setValues] = useState<Record<number, string>>(() => Object.fromEntries(rows.map((r) => [r.id, r.report_value == null ? '' : String(r.report_value)])));
  const [source, setSource] = useState(() => rows.find((r) => r.report_source)?.report_source ?? '');
  const [err, setErr] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => { ref.current?.showModal(); }, []);

  async function onSave() {
    setErr(null);
    setSaving(true);
    try {
      for (const r of rows) {
        const raw = values[r.id].replace(/,/g, '').trim();
        const before = r.report_value == null ? '' : String(r.report_value);
        if (raw === before && (r.report_source ?? '') === source) continue;
        if (raw !== '' && !/^-?\d+(\.\d+)?$/.test(raw)) throw new Error(`${t(`migration.check.fin.${r.name}`, { defaultValue: r.name })}: not a number`);
        await save.mutateAsync({ company: r.company_code ?? company, area: r.area, checkName: r.name, value: raw === '' ? null : raw, source: source || null });
      }
      onClose();
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <dialog ref={ref} onClose={onClose} aria-labelledby="fig-title"
      className="m-0 ms-auto h-full max-h-none w-[min(100vw,460px)] border-s border-line p-0 backdrop:bg-black/40">
      <div className="flex h-full flex-col">
        <header className="flex items-center justify-between border-b border-line px-5 py-4">
          <h2 id="fig-title" className="text-lg font-semibold">{t('migration.check.enterTitle')}</h2>
          <button type="button" onClick={onClose} className="grid h-11 w-11 place-items-center rounded-btn hover:bg-page" aria-label={t('app.close')}><X className="h-5 w-5" aria-hidden /></button>
        </header>
        <div className="flex-1 space-y-4 overflow-y-auto px-5 py-4">
          <p className="text-sm text-muted">{t('migration.check.enterBody')}</p>
          {rows.map((r) => (
            <div key={r.id}>
              <label htmlFor={`fig-${r.id}`} className="mb-1 block text-sm font-medium">{t(`migration.check.fin.${r.name}`, { defaultValue: r.name })}</label>
              <input id={`fig-${r.id}`} inputMode="decimal" dir="ltr" className="input num text-end" value={values[r.id]}
                onChange={(e) => setValues((v) => ({ ...v, [r.id]: e.target.value }))} placeholder={money(r.raw_value)} />
              <p className="mt-0.5 text-xs text-muted">{t('migration.check.colRaw')}: {money(r.raw_value)} · {t('migration.check.colApp')}: {money(r.app_value)}</p>
            </div>
          ))}
          <div>
            <label htmlFor="fig-source" className="mb-1 block text-sm font-medium">{t('migration.check.source')}</label>
            <input id="fig-source" className="input" value={source} onChange={(e) => setSource(e.target.value)} placeholder={t('migration.check.sourcePh')} />
          </div>
          {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
        </div>
        <footer className="flex justify-end gap-2 border-t border-line px-5 py-4">
          <Button onClick={onClose}>{t('app.cancel')}</Button>
          <Button variant="primary" onClick={() => void onSave()} disabled={saving}>{t('migration.check.save')}</Button>
        </footer>
      </div>
    </dialog>
  );
}

function IssuesCard({ runId, issues, canResolve, loading }: { runId: string; issues: MigrationReviewRow[]; canResolve: boolean; loading: boolean }) {
  const { t } = useTranslation();
  const resolve = useResolveIssue(runId);
  const [action, setAction] = useState<{ issue: MigrationReviewRow; status: IssueStatus } | null>(null);
  const order: Record<string, number> = { critical: 0, warning: 1, info: 2 };
  const sorted = [...issues].sort((a, b) => Number(a.status !== 'open') - Number(b.status !== 'open') || (order[a.severity ?? 'info'] - order[b.severity ?? 'info']));
  const needNote = action?.status === 'accepted' && action.issue.severity === 'critical';
  const titleKey = action?.status === 'accepted' ? 'acceptTitle' : action?.status === 'fixed' ? 'fixedTitle' : 'reopenTitle';

  return (
    <Card title={t('migration.check.issues')}>
      {loading ? <SkeletonRows rows={3} /> : sorted.length === 0 ? <p className="px-5 py-4 text-sm text-muted">{t('migration.check.noIssues')}</p> : (
        <ul className="divide-y divide-line">
          {sorted.map((i) => {
            const d = issueDetail(i);
            const st = (i.status ?? 'open') as IssueStatus;
            return (
              <li key={i.id} className="flex flex-wrap items-start gap-3 px-5 py-3 sm:flex-nowrap">
                <StatusPill tone={sevTone[i.severity ?? 'info']} className="mt-0.5">{t(`migration.check.sev.${i.severity ?? 'info'}`)}</StatusPill>
                <div className="min-w-0 flex-1">
                  <div className="font-medium">{i.name}</div>
                  {d.detail && <div className="line-clamp-3 text-sm text-muted">{d.detail}</div>}
                  {d.note && <div className="mt-1 text-sm italic text-muted">“{d.note}”</div>}
                  {canResolve && (
                    <div className="mt-2 flex flex-wrap gap-2">
                      {st !== 'accepted' && <Button className="min-h-[36px] px-3 text-sm" onClick={() => setAction({ issue: i, status: 'accepted' })}>{t('migration.check.accept')}</Button>}
                      {st !== 'fixed' && <Button className="min-h-[36px] px-3 text-sm" onClick={() => setAction({ issue: i, status: 'fixed' })}>{t('migration.check.markFixed')}</Button>}
                      {st !== 'open' && <Button className="min-h-[36px] px-3 text-sm" onClick={() => setAction({ issue: i, status: 'open' })}>{t('migration.check.reopen')}</Button>}
                    </div>
                  )}
                </div>
                <StatusPill tone={st === 'open' ? (i.severity === 'critical' ? 'critical' : 'neutral') : 'ok'}>{t(`migration.check.state.${st}`)}</StatusPill>
              </li>
            );
          })}
        </ul>
      )}
      <ConfirmDialog
        open={!!action}
        title={t(`migration.check.${titleKey}`)}
        body={action ? <><strong className="text-ink">{action.issue.name}</strong>{needNote && <><br />{t('migration.check.noteRequired')}</>}</> : null}
        noteLabel={t('migration.check.noteLabel')}
        noteRequired={needNote}
        busy={resolve.isPending}
        error={resolve.error ? errorMessage(resolve.error) : null}
        onConfirm={(note) => action && resolve.mutate({ issue: action.issue.id, status: action.status, note: note || null }, { onSuccess: () => setAction(null) })}
        onClose={() => { setAction(null); resolve.reset(); }}
      />
    </Card>
  );
}

function SignoffCard({ runId, code, status, criticalOpen, signoffs, signRoles }: {
  runId: string; code: string; status: string; criticalOpen: number;
  signoffs: NonNullable<ReturnType<typeof useStatus>['data']>[number]['signoffs']; signRoles: SignRole[];
}) {
  const { t } = useTranslation();
  const sign = useSign(runId);
  const [dlg, setDlg] = useState<{ role: SignRole; decision: 'approved' | 'rejected' } | null>(null);
  const lockReason = status === 'signed_off' ? t('migration.check.signedOff')
    : status !== 'needs_review' ? t('migration.check.lockedStatus')
    : criticalOpen > 0 ? t('migration.check.lockedCritical', { n: criticalOpen }) : null;

  return (
    <Card title={<span>{t('migration.check.signoff')}<span className="mt-1 block text-sm font-normal text-muted">{t('migration.check.signoffNote')}</span></span>}>
      <ul className="divide-y divide-line">
        {ROLES.map((role) => {
          const s = (signoffs ?? []).find((o) => o.role === role);
          const mine = signRoles.includes(role);
          const tone: Tone = s?.decision === 'approved' ? 'ok' : s?.decision === 'rejected' ? 'critical' : 'neutral';
          return (
            <li key={role} className="space-y-2 px-5 py-4">
              <div className="flex items-center justify-between gap-2">
                <span className="font-semibold">{t(`migration.check.role.${role}`)}</span>
                <StatusPill tone={tone}>{s ? t(`migration.check.${s.decision}`) : t('migration.check.waiting')}</StatusPill>
              </div>
              {s && <p className="text-sm text-muted">{t('migration.check.signedAt', { when: when(s.signed_at) })}</p>}
              {s?.comment && <p className="rounded-btn bg-page px-3 py-2 text-sm">“{s.comment}”</p>}
              {mine && s?.decision !== 'approved' && (
                lockReason && status !== 'signed_off' ? <p className="text-sm text-muted">{lockReason}</p> : status === 'needs_review' && (
                  <div className="space-y-2">
                    <p className="text-sm text-muted">{t('migration.check.youCanSign')}</p>
                    <div className="flex flex-wrap gap-2">
                      <Button variant="success" onClick={() => setDlg({ role, decision: 'approved' })}>{t('migration.check.approve')}</Button>
                      <Button variant="danger" onClick={() => setDlg({ role, decision: 'rejected' })}>{t('migration.check.reject')}</Button>
                    </div>
                  </div>
                )
              )}
            </li>
          );
        })}
      </ul>
      {lockReason && status === 'needs_review' && criticalOpen > 0 && (
        <p className="border-t border-line bg-crit-bg px-5 py-3 text-sm text-crit-fg">{lockReason}</p>
      )}
      <ConfirmDialog
        open={!!dlg}
        title={dlg ? t(dlg.decision === 'approved' ? 'migration.check.approveTitle' : 'migration.check.rejectTitle', { role: t(`migration.check.role.${dlg.role}`) }) : ''}
        body={code}
        tone={dlg?.decision === 'rejected' ? 'danger' : 'primary'}
        confirmLabel={dlg?.decision === 'rejected' ? t('migration.check.reject') : t('migration.check.approve')}
        noteLabel={dlg?.decision === 'rejected' ? t('migration.check.reasonLabel') : t('migration.check.commentLabel')}
        noteRequired={dlg?.decision === 'rejected'}
        busy={sign.isPending}
        error={sign.error ? errorMessage(sign.error) : null}
        onConfirm={(note) => dlg && sign.mutate({ role: dlg.role, decision: dlg.decision, comment: note || null }, { onSuccess: () => setDlg(null) })}
        onClose={() => { setDlg(null); sign.reset(); }}
      />
    </Card>
  );
}

function GoLive({ runId, code, signedOff, isCfo, liveAt }: { runId: string; code: string; signedOff: boolean; isCfo: boolean; liveAt: string | null }) {
  const { t } = useTranslation();
  const go = useGoLive(runId);
  const [open, setOpen] = useState(false);
  const [doneAt, setDoneAt] = useState<string | null>(null);
  const live = doneAt ?? liveAt;
  if (live) return <p className="card bg-ok-bg p-4 text-center font-semibold text-ok-fg">{t('migration.check.live', { code, when: when(live) })}</p>;
  const enabled = signedOff && isCfo;
  return (
    <>
      <Button id="go-live" variant="primary" className="w-full" disabled={!enabled || go.isPending}
        disabledReason={!enabled ? (signedOff ? t('migration.check.goLiveNotCfo') : t('migration.check.goLiveReason')) : undefined}
        onClick={() => setOpen(true)}>
        {t('migration.check.goLive', { code })}
      </Button>
      <ConfirmDialog
        open={open}
        title={t('migration.check.goLiveTitle', { code })}
        body={t('migration.check.goLiveBody', { code })}
        confirmLabel={t('migration.check.goLive', { code })}
        busy={go.isPending}
        error={go.error ? errorMessage(go.error) : null}
        onConfirm={() => go.mutate(code, { onSuccess: (at) => { setDoneAt(String(at)); setOpen(false); } })}
        onClose={() => { setOpen(false); go.reset(); }}
      />
    </>
  );
}


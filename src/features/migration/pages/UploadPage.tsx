import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { UploadCloud, Pause, Play, RotateCcw, Copy, Download, Check } from 'lucide-react';
import clsx from 'clsx';
import exportScript from '../../../../supabase/sql/05_hana_export.sql?raw';
import { PageHeader } from '../components/PageHeader';
import { StepTracker, type TrackerStep } from '../components/StepTracker';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { StatusPill, type Tone } from '../components/StatusPill';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { Button } from '@/components/Button';
import { EmptyState, SkeletonRows } from '@/components/States';
import { useAuth } from '@/auth/AuthProvider';
import { migrationApi } from '../api';
import { mk, RUNNING, useFiles, useOverview, useReview } from '../queries';
import { useRunRealtime } from '../useRunRealtime';
import { analyse, type Analysis, type PickedFile } from '../upload/classify';
import { ResumableUpload, type Progress } from '../upload/ResumableUpload';
import { sessions, type UploadSession } from '../upload/uploadStore';
import { found as deriveFound, hasFromWorker, mergeAnalysis, points as derivePoints, receivedRows, type PointTone } from '../upload/derive';
import { errorMessage, fmtBytes, fmtDate, fmtInt } from '@/lib/format';

type Tr = (k: string, o?: Record<string, unknown>) => string;
const pointTone: Record<PointTone, Tone> = { blocker: 'critical', sendCsv: 'warning', fix: 'warning', info: 'info' };

/** Read a dropped folder tree (DataTransferItem.webkitGetAsEntry) keeping relative paths. */
async function filesFromDrop(e: DragEvent): Promise<PickedFile[]> {
  const out: PickedFile[] = [];
  const walk = async (entry: FileSystemEntry, prefix: string): Promise<void> => {
    if (entry.isFile) {
      const file = await new Promise<File>((res, rej) => (entry as FileSystemFileEntry).file(res, rej));
      out.push({ file, path: prefix + file.name });
    } else if (entry.isDirectory) {
      const reader = (entry as FileSystemDirectoryEntry).createReader();
      let batch: FileSystemEntry[];
      do {
        batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
        for (const child of batch) await walk(child, `${prefix}${entry.name}/`);
      } while (batch.length);
    }
  };
  const entries = [...e.dataTransfer.items].map((i) => i.webkitGetAsEntry?.()).filter(Boolean) as FileSystemEntry[];
  if (!entries.length) return [...e.dataTransfer.files].map((file) => ({ file, path: file.name }));
  for (const en of entries) await walk(en, '');
  return out;
}

const fromInput = (list: FileList | null): PickedFile[] =>
  [...(list ?? [])].map((file) => ({ file, path: (file as File & { webkitRelativePath?: string }).webkitRelativePath || file.name }));

/** B6 Upload SAP backup (design/B6-upload-backup.jpg). */
export function UploadPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { profile } = useAuth();
  const [params, setParams] = useSearchParams();
  const overview = useOverview();

  const companies = useMemo(() => {
    if (overview.data?.length) return overview.data.map((c) => ({ code: c.company_code, name: c.company_name, schema: c.sap_schema }));
    return (profile?.companies ?? []).map((c) => ({ code: c.company_code, name: c.legal_name, schema: c.sap_schema ?? '' }));
  }, [overview.data, profile]);
  const company = params.get('company') ?? companies[0]?.code ?? '';
  const co = companies.find((c) => c.code === company);

  // the latest run of the company decides what the screen shows
  const latest = useQuery({ queryKey: [...mk.all, 'latest', company], queryFn: () => migrationApi.latestRunForCompany(company), enabled: Boolean(company) });
  const run = latest.data ?? null;
  const runId = run?.run_id;
  useRunRealtime(runId);
  const workerFiles = useFiles(run && run.status !== 'uploading' ? runId : undefined);
  const review = useReview(run && run.status !== 'uploading' ? runId : undefined);
  const busy = run ? RUNNING.includes(run.status) : false;

  const [session, setSession] = useState<UploadSession | null>(null);
  const [analysis, setAnalysis] = useState<Analysis | null>(null);
  const [reading, setReading] = useState(false);
  const [progress, setProgress] = useState<Progress | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [confirmStart, setConfirmStart] = useState(false);
  const [starting, setStarting] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const uploader = useRef<ResumableUpload | null>(null);
  const folderInput = useRef<HTMLInputElement>(null);
  const filesInput = useRef<HTMLInputElement>(null);

  // restore the stored session of this run (after a reload or a closed tab)
  useEffect(() => {
    let alive = true;
    setSession(null); setAnalysis(null); setProgress(null); setError(null);
    if (!runId) return;
    void sessions.get(runId).then((s) => {
      if (!alive || !s) return;
      setSession(s);
      setAnalysis((s.facts as Analysis) ?? null);
    });
    return () => { alive = false; };
  }, [runId]);

  useEffect(() => () => uploader.current?.pause(), []);

  const uploading = Boolean(uploader.current && progress && progress.done + progress.failed < progress.total);
  const sessionFiles = session ? Object.values(session.files) : [];
  const sessionDone = sessionFiles.filter((x) => x.done).length;
  const needsResume = Boolean(run?.status === 'uploading' && session && sessionDone < sessionFiles.length && !uploading);
  const allUploaded = Boolean(session && sessionFiles.length > 0 && sessionDone === sessionFiles.length);

  const markSubmitted = useCallback(async (rid: string) => {
    const s = await sessions.get(rid);
    if (s) await sessions.put({ ...s, submitted: true });
    void qc.invalidateQueries({ queryKey: mk.all });
  }, [qc]);

  async function handlePicked(picked: PickedFile[]) {
    if (!picked.length || !company) return;
    setError(null);
    setReading(true);
    try {
      const fresh = await analyse(picked);
      // continue the open upload of this company, or start a new run
      const continuing = run?.status === 'uploading' && session ? session : null;
      const merged = continuing ? mergeAnalysis(analysis, fresh) : fresh;
      const rid = continuing?.runId ?? (await migrationApi.request(company, merged.structureOnly ? 'structure_only' : 'full', null));
      const files = { ...(continuing?.files ?? {}) };
      for (const p of picked) if (!files[p.path]) files[p.path] = { size: p.file.size, done: false };
      const sess: UploadSession = {
        runId: rid, company, kind: merged.structureOnly ? 'structure_only' : 'full',
        createdAt: continuing?.createdAt ?? new Date().toISOString(), files, facts: merged,
      };
      await sessions.put(sess);
      setSession(sess);
      setAnalysis(merged);
      setReading(false);
      if (!continuing) await qc.invalidateQueries({ queryKey: [...mk.all, 'latest', company] });

      const done = new Set(Object.entries(files).filter(([, v]) => v.done).map(([k]) => k));
      const up = new ResumableUpload(rid, company, picked, setProgress, done);
      uploader.current = up;
      const result = await up.start();
      uploader.current = null;
      const after = await sessions.get(rid);
      if (after) setSession(after);
      const complete = after && Object.values(after.files).every((x) => x.done);
      // field lists only: submit as soon as the upload finishes; the worker checks the structure
      if (complete && merged.structureOnly && result.failed === 0) {
        await migrationApi.submit(rid);
        await markSubmitted(rid);
      }
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setReading(false);
    }
  }

  async function onDrop(e: DragEvent) {
    e.preventDefault();
    setDragOver(false);
    void handlePicked(await filesFromDrop(e));
  }

  async function discard() {
    if (!runId) return;
    uploader.current?.pause();
    try { await migrationApi.cancel(runId); } catch { /* already gone */ }
    await sessions.remove(runId);
    void qc.invalidateQueries({ queryKey: mk.all });
  }

  // ---- what the screen shows
  const has = hasFromWorker(workerFiles.data) ?? analysis?.has ?? null;
  const hasArchive = Boolean(analysis?.hasArchive);
  const f = deriveFound(review.data, analysis);
  const anyFiles = Boolean(analysis?.files.length || analysis?.dataFiles || workerFiles.data?.length);
  const pts = derivePoints({ t: t as unknown as Tr, review: review.data, has, hasArchive, found: f, anyFiles });
  const rows = receivedRows({ t: t as unknown as Tr, analysis, workerFiles: workerFiles.data, progress: progress?.files });
  const fileCount = workerFiles.data?.length || sessionFiles.length;
  const dataReady = Boolean(has && ((has.data && has.columns && has.rowCounts) || hasArchive));
  const canStart = run?.status === 'uploading' && allUploaded && dataReady && !uploading;
  const startReason = busy ? t('migration.upload.startReasonBusy')
    : uploading || (run?.status === 'uploading' && !allUploaded && anyFiles) ? t('migration.upload.startReasonUploading')
    : t('migration.upload.startReason');
  const onlyStructure = Boolean(anyFiles && has && !has.data && !hasArchive);

  async function start() {
    if (!runId) return;
    setStarting(true);
    setError(null);
    try {
      await migrationApi.submit(runId);
      await markSubmitted(runId);
      nav(`/backoffice/migration/runs/${runId}`);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setStarting(false);
      setConfirmStart(false);
    }
  }

  // ---- step tracker
  const pct = progress && progress.totalBytes ? Math.floor((progress.sentBytes / progress.totalBytes) * 100) : null;
  const filesIn = anyFiles && (allUploaded || Boolean(workerFiles.data?.length));
  const tracker: TrackerStep[] = [
    filesIn
      ? { state: 'done', note: t('steps.filesIn', { count: fileCount }) }
      : { state: 'action', note: uploading && pct !== null ? t('steps.uploadingNote', { pct }) : undefined },
    !anyFiles ? { state: 'waiting' }
      : dataReady ? { state: 'done' }
      : busy ? { state: 'action', note: t('steps.checking') }
      : { state: 'action', note: t('steps.dataMissing') },
    { state: 'waiting' }, { state: 'waiting' }, { state: 'waiting' }, { state: 'waiting' },
  ];

  // ---- IT helpers
  const schema = co?.schema || 'SBO_SANFORD';
  async function copyIt() {
    await navigator.clipboard.writeText(t('migration.upload.itMessage', { company, name: co?.name ?? '', schema }));
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }
  function downloadScript() {
    const sql = exportScript.replace(/SBO_SANFORD/g, schema).replace(/AE01_/g, `${company}_`);
    const url = URL.createObjectURL(new Blob([sql], { type: 'text/plain' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = `05_hana_export_${company}_${schema}.sql`;
    a.click();
    URL.revokeObjectURL(url);
  }

  const need = (key: string, ok: boolean, inArchive = false, optional = false) => (
    <li key={key} className="flex items-start gap-3 border-b border-line py-3 last:border-0">
      <StatusPill tone={ok ? 'ok' : inArchive ? 'info' : optional ? 'neutral' : 'critical'} className="mt-0.5">
        {ok ? t('migration.upload.received') : inArchive ? t('migration.upload.inArchive') : optional ? t('migration.upload.optional') : t('migration.upload.missing')}
      </StatusPill>
      <div>
        <div className="font-medium">{t(`migration.upload.${key}`)}</div>
        <div className="text-sm text-muted">{t(`migration.upload.${key}Note`)}</div>
      </div>
    </li>
  );

  const structureRows: Array<[string, string]> = f ? [
    [t('migration.upload.tablesInSap'), fmtInt(f.tablesInSap)],
    [t('migration.upload.tablesInErp'), fmtInt(f.tablesInErp)],
    [t('migration.upload.leftOut'), fmtInt(f.leftOut)],
    [t('migration.upload.fieldsCompared'), fmtInt(f.fieldsCompared)],
    [t('migration.upload.fieldsMissing'), fmtInt(f.fieldsMissing)],
    [t('migration.upload.typeDiff'), fmtInt(f.typeDiff)],
    ...(f.itemFields ? [[t('migration.upload.itemFields'), `${fmtInt(f.itemFields)} · ${fmtInt(f.itemUserFields)}`] as [string, string]] : []),
  ] : [];

  const disabledPick = busy || uploading || reading || !company;

  return (
    <div className="space-y-6">
      <PageHeader
        crumb={t('migration.upload.breadcrumb')}
        title={t('migration.upload.title')}
        subtitle={
          <span className="flex flex-wrap items-center gap-3">
            {t('migration.upload.subtitle')}
            {run && anyFiles && <StatusPill tone="ok">{t('migration.upload.realResult', { date: fmtDate(run.created_at) })}</StatusPill>}
          </span>
        }
        right={
          <div className="w-full sm:w-[360px]">
            <label htmlFor="company-picker" className="mb-1 block text-sm text-muted">{t('top.company')}</label>
            <select id="company-picker" className="input" value={company} onChange={(e) => setParams({ company: e.target.value })} disabled={uploading}>
              {companies.map((c) => <option key={c.code} value={c.code}>{c.code} · {c.name}{c.schema ? ` · ${c.schema}` : ''}</option>)}
            </select>
          </div>
        }
      />

      <StepTracker steps={tracker} current={filesIn ? 1 : 0} />

      {busy && run && (
        <div className="card flex flex-wrap items-center justify-between gap-3 bg-info-bg p-4">
          <span className="font-medium text-info-fg">{t('migration.upload.runBusy', { company, status: t(`status.${run.status}`) })}</span>
          <Link to={`/backoffice/migration/runs/${run.run_id}`} className="inline-flex min-h-[44px] items-center rounded-btn bg-primary px-4 font-medium text-white">{t('migration.upload.openRun')}</Link>
        </div>
      )}

      {needsResume && (
        <div role="status" className="card flex flex-wrap items-center justify-between gap-3 bg-warn-bg p-4">
          <div>
            <div className="font-semibold text-warn-fg">{t('migration.upload.resumeTitle', { company })}</div>
            <div className="text-sm text-warn-fg">{t('migration.upload.resumeBody', { done: sessionDone, total: sessionFiles.length })}</div>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="primary" icon={<Play className="h-4 w-4" aria-hidden />} onClick={() => folderInput.current?.click()}>{t('migration.upload.resume')}</Button>
            <Button icon={<RotateCcw className="h-4 w-4" aria-hidden />} onClick={discard}>{t('migration.upload.discard')}</Button>
          </div>
        </div>
      )}

      {error && <p role="alert" className="card bg-crit-bg p-4 text-crit-fg">{error}</p>}

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
        {/* ---------- left column ---------- */}
        <div className="min-w-0 space-y-6">
          <Card title={t('migration.upload.addFiles')} bodyClassName="p-5 space-y-5">
            <div
              onDragOver={(e) => { e.preventDefault(); if (!disabledPick) setDragOver(true); }}
              onDragLeave={() => setDragOver(false)}
              onDrop={disabledPick ? (e) => e.preventDefault() : onDrop}
              className={clsx('flex flex-col items-center gap-3 rounded-card border-2 border-dashed px-6 py-8 text-center',
                dragOver ? 'border-primary bg-primary-soft' : 'border-[#C9CED6]')}
            >
              <UploadCloud className="h-9 w-9 text-primary" aria-hidden />
              <p className="text-lg font-semibold">{t('migration.upload.drop')}</p>
              <p className="max-w-lg text-sm text-muted">{t('migration.upload.dropNote')}</p>
              <div className="flex flex-wrap justify-center gap-2">
                <Button variant="primary" onClick={() => folderInput.current?.click()} disabled={disabledPick}>{t('migration.upload.chooseFolder')}</Button>
                <Button onClick={() => filesInput.current?.click()} disabled={disabledPick}>{t('migration.upload.chooseFiles')}</Button>
              </div>
              <input ref={folderInput} type="file" className="hidden" multiple aria-label={t('migration.upload.chooseFolder')}
                {...({ webkitdirectory: '', directory: '' } as Record<string, string>)}
                onChange={(e) => { void handlePicked(fromInput(e.target.files)); e.target.value = ''; }} />
              <input ref={filesInput} type="file" className="hidden" multiple aria-label={t('migration.upload.chooseFiles')} accept=".zip,.gz,.tgz,.tar,.csv,.xlsx,.xlsm,.sql"
                onChange={(e) => { void handlePicked(fromInput(e.target.files)); e.target.value = ''; }} />
              {reading && <p role="status" className="text-sm text-muted">{t('migration.upload.reading')}</p>}
            </div>

            {progress && progress.total > 0 && (
              <div className="space-y-2" aria-live="polite">
                <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                  <span>
                    {progress.done === progress.total
                      ? t('migration.upload.uploaded', { total: progress.total })
                      : t('migration.upload.progress', { done: progress.done, total: progress.total, sent: fmtBytes(progress.sentBytes), size: fmtBytes(progress.totalBytes) })}
                    {progress.failed > 0 && <span className="ms-2 text-crit-fg">{t('migration.upload.failed', { n: progress.failed })}</span>}
                  </span>
                  {uploading && <Button icon={<Pause className="h-4 w-4" aria-hidden />} onClick={() => uploader.current?.pause()}>{t('migration.upload.pause')}</Button>}
                </div>
                <div role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct ?? 0} aria-label={t('migration.upload.addFiles')}
                  className="h-2 overflow-hidden rounded-full bg-neutral-bg">
                  <div className="h-full bg-primary transition-[width]" style={{ width: `${pct ?? 0}%` }} />
                </div>
                {uploading && (
                  <ul className="max-h-40 space-y-1 overflow-y-auto">
                    {Object.values(progress.files).filter((x) => x.state === 'uploading').map((x) => {
                      const p = Math.floor((x.sent / Math.max(1, x.size)) * 100);
                      return (
                        <li key={x.path} className="flex items-center gap-3 text-xs">
                          <span className="w-1/2 truncate font-mono">{x.path}</span>
                          <div role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={p} aria-label={x.path} className="h-1.5 flex-1 overflow-hidden rounded-full bg-neutral-bg">
                            <div className="h-full bg-primary" style={{ width: `${p}%` }} />
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>
            )}

            <div>
              <h3 className="mb-1 font-semibold">{t('migration.upload.needs')}</h3>
              <ul>
                {need('needFieldList', Boolean(has?.fieldList), false, true)}
                {need('needData', Boolean(has?.data), hasArchive)}
                {need('needColumns', Boolean(has?.columns), hasArchive)}
                {need('needConstraints', Boolean(has?.constraints), hasArchive)}
                {need('needRowCounts', Boolean(has?.rowCounts), hasArchive)}
              </ul>
            </div>
          </Card>

          <Card
            title={t('migration.upload.receivedTitle', { count: fileCount }) + (run && anyFiles ? ` · ${fmtDate(run.created_at)}` : '')}
            actions={onlyStructure ? <span className="text-sm text-muted">{t('migration.upload.receivedNoteStructure')}</span> : undefined}
          >
            {latest.isLoading ? <SkeletonRows rows={4} /> : (
              <DataTable
                caption={t('migration.upload.receivedTitle', { count: fileCount })}
                rows={rows}
                rowKey={(r) => r.key}
                empty={<EmptyState body={t('migration.upload.notChecked')} />}
                columns={[
                  { key: 'f', header: t('migration.upload.colFile'), mono: true, cell: (r) => r.file },
                  { key: 'r', header: t('migration.upload.colReadAs'), cell: (r) => r.readAs },
                  { key: 'n', header: t('migration.upload.colRows'), align: 'end', cell: (r) => fmtInt(r.rows) },
                  { key: 's', header: t('migration.upload.colSize'), align: 'end', cell: (r) => fmtBytes(r.size) },
                  { key: 'x', header: t('migration.upload.colResult'), cell: (r) => (r.result.label ? <StatusPill tone={r.result.tone}>{r.result.label}</StatusPill> : null) },
                ]}
              />
            )}
          </Card>
        </div>

        {/* ---------- right column ---------- */}
        <div className="min-w-0 space-y-6">
          <section className="card overflow-hidden">
            <div className="border-b border-line px-5 py-4">
              <h2 className="text-[17px] font-semibold">{t('migration.upload.found')}</h2>
              {f?.pct != null ? (
                <p className={clsx('mt-1 text-xl font-semibold', f.pct === 100 ? 'text-ok-fg' : 'text-warn-fg')}>
                  {t('migration.upload.structureMatch', { pct: f.pct })}
                </p>
              ) : busy ? (
                <p className="mt-1 text-muted">{t('migration.upload.waitingWorker')}</p>
              ) : !anyFiles ? (
                <p className="mt-1 text-muted">{t('migration.upload.notChecked')}</p>
              ) : null}
              {anyFiles && (onlyStructure || dataReady) && (
                <p className={clsx('mt-1 text-[15px]', onlyStructure ? 'text-warn-fg' : 'text-ok-fg')}>
                  {onlyStructure ? t('migration.upload.noDataYet') : t('migration.upload.dataReady')}
                </p>
              )}
            </div>
            {(structureRows.length > 0 || (analysis?.dataTables ?? 0) > 0) && (
              <dl className="divide-y divide-line px-5">
                {structureRows.map(([k, v]) => (
                  <div key={k} className="flex items-center justify-between gap-4 py-2.5">
                    <dt className="text-muted">{k}</dt><dd className="num font-semibold">{v}</dd>
                  </div>
                ))}
                {!!analysis?.dataTables && (
                  <>
                    <div className="flex items-center justify-between gap-4 py-2.5"><dt className="text-muted">{t('migration.upload.dataTables')}</dt><dd className="num font-semibold">{fmtInt(analysis.dataTables)}</dd></div>
                    <div className="flex items-center justify-between gap-4 py-2.5"><dt className="text-muted">{t('migration.upload.dataFiles')}</dt><dd className="num font-semibold">{fmtInt(analysis.dataFiles)} · {fmtBytes(analysis.dataBytes)}</dd></div>
                  </>
                )}
              </dl>
            )}
          </section>

          <Card title={t('migration.upload.pointsToFix')}>
            {review.isLoading ? <SkeletonRows rows={3} /> : pts.length === 0 ? (
              <p className="px-5 py-4 text-sm text-muted">{anyFiles ? t('migration.upload.noPoints') : t('migration.upload.notChecked')}</p>
            ) : (
              <ul className="divide-y divide-line">
                {pts.map((p) => (
                  <li key={p.key} className="flex items-start gap-3 px-5 py-3">
                    <StatusPill tone={pointTone[p.tone]} className="mt-0.5">{t(`migration.upload.${p.tone}`)}</StatusPill>
                    <div className="min-w-0">
                      <div className="font-medium">{p.title}</div>
                      {p.detail && <div className="line-clamp-3 text-sm text-muted">{p.detail}</div>}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <section className="card border-[#C7D4F7] bg-info-bg p-5">
            <h2 className="text-[17px] font-semibold text-info-fg">{t('migration.upload.nextStep')}</h2>
            <ol className="mt-2 list-decimal space-y-1 ps-5 text-[15px]">
              <li>{t('migration.upload.next1', { schema })}</li>
              <li>{t('migration.upload.next2')}</li>
              <li>{t('migration.upload.next3')}</li>
            </ol>
            <div className="mt-4 flex flex-wrap gap-2">
              <Button icon={copied ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />} onClick={copyIt}>
                {copied ? t('migration.upload.copied') : t('migration.upload.copyIt')}
              </Button>
              <Button icon={<Download className="h-4 w-4" aria-hidden />} onClick={downloadScript}>{t('migration.upload.downloadScript')}</Button>
            </div>
          </section>

          <Button
            id="start-load"
            variant="primary"
            className="w-full"
            disabled={!canStart || starting}
            disabledReason={!canStart ? startReason : undefined}
            onClick={() => (has?.constraints || hasArchive ? void start() : setConfirmStart(true))}
          >
            {t('migration.upload.start')}
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirmStart}
        title={t('migration.upload.startNoConstraintsTitle')}
        body={t('migration.upload.startNoConstraintsBody')}
        confirmLabel={t('migration.upload.start')}
        busy={starting}
        onConfirm={() => void start()}
        onClose={() => setConfirmStart(false)}
      />
    </div>
  );
}

import { Fragment, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Download, Lock, Pencil, Plus, ShieldCheck, Trash2, Upload } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { ErrorState, PageLoading } from '@/components/States';
import { Fields, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { SeriesPicker } from '../components/SeriesPicker';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import type { Row } from '../api';
import { Flash, FormError, fmtWhen, sourceName, useDefaultCompany, useFlash } from './BankingPages';
import { BalanceList, DocRow, FieldErr, FlagPills, HrFrame, HrHeader, LeavePill, days, hrInput, hrLabel, primaryLink, secondaryLink } from './HrPages';
import {
  documentSave, downloadText, employeeExtraSave, employeeSave, paySet, payrollCalculate, payrollInputRemove, payrollInputSave, payrollPost, payrollStep,
  setupSave, uploadHrFile, useEmployeeInfo, useHrSetup, usePayroll, wpsCheck, wpsFile, type EmployeeInfo, type HrSetup, type RunState,
} from '../hr';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const RUN_TONE: Record<RunState, string> = { draft: 'pill-neutral', reviewed: 'pill-info', locked: 'pill-warning', posted: 'pill-ok' };
export function RunPill({ state }: { state: RunState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', RUN_TONE[state])}>{t(`hr.runState.${state}`)}</span>;
}
const thisMonth = () => new Date().toISOString().slice(0, 7);

function Txt({ label, value, onChange, type = 'text', id, required, dir, help, inputMode }: {
  label: string; value: string; onChange: (v: string) => void; type?: string; id?: string; required?: boolean; dir?: 'ltr' | 'auto'; help?: string; inputMode?: 'decimal' | 'numeric';
}) {
  return (
    <label className={hrLabel}>{label}{required && <span className="text-crit-fg"> *</span>}
      <input id={id} data-testid={id} type={type} dir={dir ?? 'auto'} inputMode={inputMode} className={clsx(hrInput, inputMode && 'num')} value={value} onChange={(e) => onChange(e.target.value)} />
      {help && <span className="mt-1 block text-[12px] font-normal text-muted">{help}</span>}
    </label>
  );
}
function Sel({ label, value, onChange, options, id, empty }: { label: string; value: string; onChange: (v: string) => void; options: Array<[string, string]>; id?: string; empty?: string }) {
  return (
    <label className={hrLabel}>{label}
      <select id={id} data-testid={id} className={hrInput} value={value} onChange={(e) => onChange(e.target.value)}>
        {empty !== undefined && <option value="">{empty}</option>}
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </label>
  );
}
const s = (v: unknown) => (v === null || v === undefined ? '' : String(v));

// ---------- Employees ----------
export function NewEmployeeAction() {
  const { t } = useTranslation();
  const { canWrite } = useModuleLevel('hr');
  if (!canWrite) return null;
  return <Link to="/hr/employees/new" className={primaryLink} data-testid="hr-new-employee"><Plus className="h-4 w-4" aria-hidden />{t('hr.emp.new')}</Link>;
}
export function HrLinks() {
  const { t } = useTranslation();
  const { canWrite } = useModuleLevel('hr');
  return (
    <>
      <Link to="/hr/expiry" className={secondaryLink}>{t('hr.exp.title')}</Link>
      {canWrite && <Link to="/hr/payroll" className={secondaryLink}>{t('hr.payroll.title')}</Link>}
    </>
  );
}

export function EmployeeDetailPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = useEmployeeInfo(company, Number(id));
  const [flash, setFlash] = useFlash();
  if (q.isLoading) return <PageLoading />;
  if (q.error || !q.data) return <RequireModule module="hr"><ErrorState error={q.error ?? new Error(t('erp.notFound'))} onRetry={() => q.refetch()} /></RequireModule>;
  const d = q.data;
  const e = d.employee;
  const name = `${e.first_name ?? ''} ${e.last_name ?? ''}`.trim();
  const done = (msg: string) => { setFlash(msg); q.refetch(); };
  return (
    <div>
      <HrHeader back={[t('erp.page.employees'), '/hr/employees']} title={`${e.hr_code ?? e.emp_id} · ${name}`}
        pills={<><span className={clsx('pill', e.active ? 'pill-ok' : 'pill-neutral')}>{t(`hr.status.${e.status ?? (e.active ? 'active' : 'left')}`, { defaultValue: e.status })}</span>
          <span className={clsx('pill', e.source === 'erp' ? 'pill-info' : 'pill-neutral')}>{sourceName(e.source)}</span></>}
        sub={<span dir="auto">{e.job_title ?? '—'} · {e.division ?? '—'}{e.manager_name ? ` · ${t('hr.f.manager')}: ${e.manager_name}` : ''}</span>}
        actions={d.can_edit ? <Link to={`/hr/employees/${company}/${e.emp_id}/edit`} className={secondaryLink} data-testid="hr-edit-employee"><Pencil className="h-4 w-4" aria-hidden />{t('hr.emp.edit')}</Link>
          : d.edit_reason === 'sap' ? <p className="max-w-xs text-sm text-muted">{t('hr.emp.sapNote', { company })}</p> : undefined} />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[
              [t('hr.f.firstName'), e.first_name], [t('hr.f.lastName'), e.last_name], [t('hr.f.jobTitle'), e.job_title], [t('hr.f.department'), e.division],
              [t('hr.f.branch'), e.branch_name], [t('hr.f.manager'), e.manager_name], [t('hr.f.mobile'), e.mobile], [t('hr.f.email'), e.email],
              [t('hr.f.nationality'), e.nationality], [t('hr.f.birth'), fmtDay(e.birth_date)], [t('hr.f.joined'), fmtDay(e.joined_on)], [t('hr.f.left'), fmtDay(e.left_on)],
              [t('hr.f.passport'), e.passport_no], [t('hr.f.passportExpires'), fmtDay(e.passport_expires)], [t('hr.f.govId'), e.gov_id], [t('erp.col.source'), sourceName(e.source)],
            ]} />
          </SectionCard>
          <HrDetailsCard company={company} info={d} onDone={done} />
          {d.salary_visible && <PayCard company={company} info={d} onDone={done} />}
          <DocumentsCard company={company} info={d} onDone={done} />
          <SectionCard title={t('hr.emp.recentLeave')}>
            {d.leave.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.portal.noRequests')}</p> : (
              <ul className="divide-y divide-line">{d.leave.map((l) => (
                <li key={l.request_id}><Link to={`/hr/leave/${company}/${l.request_id}`} className="flex min-h-[44px] flex-wrap items-center justify-between gap-2 px-5 py-2.5 text-sm hover:bg-surface-2">
                  <span>{l.leave_code} · {fmtDay(l.from_date)} – {fmtDay(l.to_date)} · {t('hr.nDays', { n: days(l.days) })}</span><LeavePill state={l.state} /></Link></li>))}
              </ul>
            )}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          {!d.salary_visible && <p className="card flex items-start gap-2 p-4 text-sm text-muted" data-testid="hr-salary-hidden"><Lock className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{t('hr.emp.salaryHidden')}</p>}
          {d.salary_visible && <EosCard info={d} />}
          <SectionCard title={t('hr.portal.balances')}><BalanceList items={d.balances} /></SectionCard>
          <SectionCard title={t('hr.emp.attendance')}>
            {d.attendance.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.att.empty')}</p> : (
              <ul className="divide-y divide-line">{d.attendance.map((a) => (
                <li key={a.work_date} className="flex flex-wrap items-center justify-between gap-2 px-5 py-2.5 text-sm"><span>{fmtDay(a.work_date)}</span><FlagPills flags={[...a.in_flags, ...a.out_flags]} /></li>))}
              </ul>
            )}
          </SectionCard>
          {d.history && (
            <SectionCard title={t('hr.emp.history')}>
              <ol className="space-y-3 p-5 text-sm">{d.history.length === 0 ? <li className="text-muted">—</li> : d.history.map((h, i) => (
                <li key={i}><span className="font-medium">{h.actor ?? '—'}</span> {t(`hr.activity.${h.action}`, { defaultValue: h.action })}<div className="text-xs text-muted">{fmtWhen(h.at)}</div></li>))}
              </ol>
            </SectionCard>
          )}
        </aside>
      </div>
    </div>
  );
}

function HrDetailsCard({ company, info, onDone }: { company: string; info: EmployeeInfo; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const setup = useHrSetup(company, info.can_edit_hr);
  const [edit, setEdit] = useState(false);
  const [f, setF] = useState<Record<string, string>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const x = info.hr; const b = info.bank; const tk = info.ticket_entitlement;
  const open = () => {
    setF({ shift_code: s(x.shift_code), site_code: s(x.site_code), labour_card_no: s(x.labour_card_no), home_city: s(x.home_city),
      ...(info.salary_visible ? { iban: s(b?.iban), bank_routing: s(b?.bank_routing), mol_person_id: s(b?.mol_person_id), wps_bank: s(b?.wps_bank),
        ticket_value: s(tk?.ticket_value), ticket_every_months: s(tk?.ticket_every_months), ticket_last_date: s(tk?.ticket_last_date) } : {}) });
    setErr(null); setEdit(true);
  };
  const save = async () => {
    setBusy(true); setErr(null);
    try { await employeeExtraSave(company, info.employee.emp_id, f); setEdit(false); onDone(t('hr.saved')); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const st = setup.data;
  return (
    <SectionCard title={t('hr.emp.hrDetails')} right={info.can_edit_hr && !edit ? <Button variant="ghost" data-testid="hr-edit-details" onClick={open} icon={<Pencil className="h-4 w-4" aria-hidden />}>{t('hr.edit')}</Button> : undefined}>
      {!edit ? (
        <Fields items={[
          [t('hr.f.shift'), x.shift ? `${x.shift.name} (${String(x.shift.start_time).slice(0, 5)}–${String(x.shift.end_time).slice(0, 5)})` : null],
          [t('hr.f.site'), x.site_code], [t('hr.f.labourCard'), x.labour_card_no], [t('hr.f.homeCity'), x.home_city],
          ...(info.salary_visible ? [
            [t('hr.f.iban'), <span className="font-mono">{b?.iban ?? '—'}</span>], [t('hr.f.routing'), b?.bank_routing], [t('hr.f.mol'), b?.mol_person_id], [t('hr.f.wpsBank'), b?.wps_bank],
          ] as Array<[string, ReactNode]> : []),
        ]} />
      ) : (
        <div className="p-5">
          <FormError message={err} />
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Sel id="hr-x-shift" label={t('hr.f.shift')} value={f.shift_code} onChange={(v) => setF({ ...f, shift_code: v })} empty={t('hr.byDepartment')}
              options={(st?.shifts ?? []).map((x2) => [x2.shift_code, x2.name])} />
            <Sel id="hr-x-site" label={t('hr.f.site')} value={f.site_code} onChange={(v) => setF({ ...f, site_code: v })} empty={t('hr.nearestSite')}
              options={(st?.sites ?? []).map((x2) => [x2.site_code, x2.name])} />
            <Txt label={t('hr.f.labourCard')} value={f.labour_card_no} onChange={(v) => setF({ ...f, labour_card_no: v })} />
            <Txt label={t('hr.f.homeCity')} value={f.home_city} onChange={(v) => setF({ ...f, home_city: v })} />
            {info.salary_visible && <>
              <Txt id="hr-x-iban" label={t('hr.f.iban')} dir="ltr" value={f.iban} onChange={(v) => setF({ ...f, iban: v })} />
              <Txt id="hr-x-routing" label={t('hr.f.routing')} dir="ltr" inputMode="numeric" value={f.bank_routing} onChange={(v) => setF({ ...f, bank_routing: v })} />
              <Txt id="hr-x-mol" label={t('hr.f.mol')} dir="ltr" inputMode="numeric" value={f.mol_person_id} onChange={(v) => setF({ ...f, mol_person_id: v })} />
              <Sel label={t('hr.f.wpsBank')} value={f.wps_bank} onChange={(v) => setF({ ...f, wps_bank: v })} empty="—" options={(st?.wps_banks ?? []).map((x2) => [x2.bank_code, x2.name])} />
              <Txt label={t('hr.f.ticketValue')} inputMode="decimal" value={f.ticket_value} onChange={(v) => setF({ ...f, ticket_value: v })} />
              <Txt label={t('hr.f.ticketEvery')} inputMode="numeric" value={f.ticket_every_months} onChange={(v) => setF({ ...f, ticket_every_months: v })} />
              <Txt label={t('hr.f.ticketLast')} type="date" value={f.ticket_last_date} onChange={(v) => setF({ ...f, ticket_last_date: v })} />
            </>}
          </div>
          <div className="mt-4 flex justify-end gap-2">
            <Button onClick={() => setEdit(false)}>{t('hr.cancel')}</Button>
            <Button variant="primary" data-testid="hr-save-details" disabled={busy} onClick={save}>{t('hr.save')}</Button>
          </div>
        </div>
      )}
    </SectionCard>
  );
}

function PayCard({ company, info, onDone }: { company: string; info: EmployeeInfo; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const setup = useHrSetup(company, info.can_edit_hr);
  const [f, setF] = useState({ wage: '', amount: '', from: '', note: '' });
  const [open, setOpen] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const fixed = (setup.data?.wage_types ?? []).filter((w) => w.is_earning && (w.calc_type ?? 'fixed') === 'fixed');
  const total = (info.pay ?? []).reduce((a, p) => a + Number(p.amount), 0);
  const save = async () => {
    setBusy(true); setErr(null);
    try { await paySet(company, info.employee.emp_id, f.wage, Number(f.amount), f.from, f.note.trim() || null); setOpen(false); setF({ wage: '', amount: '', from: '', note: '' }); onDone(t('hr.emp.payChanged')); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <SectionCard title={t('hr.emp.pay')} right={info.can_edit_hr && !open ? <Button variant="ghost" data-testid="hr-pay-change" onClick={() => setOpen(true)}>{t('hr.emp.changePay')}</Button> : undefined}>
      <div className="relative overflow-x-auto">
        <table className="w-full text-sm" data-testid="hr-pay">
          <thead className="bg-surface-2 text-xs text-muted"><tr><th scope="col" className="px-5 py-2 text-start">{t('hr.col.wage')}</th><th scope="col" className="px-5 py-2 text-start">{t('hr.col.from')}</th><th scope="col" className="px-5 py-2 text-end">{t('hr.col.amount')}</th></tr></thead>
          <tbody>
            {(info.pay ?? []).map((p) => <tr key={p.wage_code} className="border-t border-line"><td className="px-5 py-2">{p.name ?? p.wage_code}</td><td className="px-5 py-2">{fmtDay(p.valid_from)}</td><td className="num px-5 py-2 text-end">{fmtMoney(p.amount)}</td></tr>)}
            <tr className="border-t border-line font-semibold"><td className="px-5 py-2" colSpan={2}>{t('hr.emp.monthly')}</td><td className="num px-5 py-2 text-end">{fmtMoney(total, info.currency)}</td></tr>
          </tbody>
        </table>
      </div>
      {open && (
        <div className="border-t border-line p-5">
          <FormError message={err} />
          <div className="grid gap-4 sm:grid-cols-4">
            <Sel id="hr-pay-wage" label={t('hr.col.wage')} value={f.wage} onChange={(v) => setF({ ...f, wage: v })} empty={t('hr.choose')} options={fixed.map((w) => [w.code, w.name ?? w.code])} />
            <Txt id="hr-pay-amount" label={t('hr.col.amount')} inputMode="decimal" value={f.amount} onChange={(v) => setF({ ...f, amount: v })} />
            <Txt id="hr-pay-from" label={t('hr.col.from')} type="date" value={f.from} onChange={(v) => setF({ ...f, from: v })} />
            <Txt label={t('hr.f.note')} value={f.note} onChange={(v) => setF({ ...f, note: v })} />
          </div>
          <div className="mt-4 flex justify-end gap-2"><Button onClick={() => setOpen(false)}>{t('hr.cancel')}</Button><Button variant="primary" data-testid="hr-pay-save" disabled={busy} onClick={save}>{t('hr.save')}</Button></div>
        </div>
      )}
      <p className="flex items-center gap-1 border-t border-line px-5 py-2 text-xs text-muted"><ShieldCheck className="h-3.5 w-3.5" aria-hidden />{t('hr.emp.salaryAudited')}</p>
    </SectionCard>
  );
}

function EosCard({ info }: { info: EmployeeInfo }) {
  const { t } = useTranslation();
  const g = info.gratuity ?? {}; const k = info.ticket ?? {};
  const cur = info.currency;
  return (
    <SectionCard title={t('hr.emp.eos')}>
      <div className="space-y-4 p-5 text-sm" data-testid="hr-eos">
        <div>
          <div className="text-xs text-muted">{t('hr.emp.gratuity')}</div>
          {g.set ? <><div className="num text-lg font-semibold">{fmtMoney(g.amount, cur)}</div>
            <div className="text-xs text-muted">{t('hr.emp.gratuityDetail', { years: Number(g.years).toFixed(2), basic: fmtMoney(g.basic), daily: fmtMoney(g.daily) })}</div></>
            : <p dir="auto" className="text-muted">{g.message}</p>}
        </div>
        <div>
          <div className="text-xs text-muted">{t('hr.emp.ticket')}</div>
          {k.set ? <><div className="num text-lg font-semibold">{fmtMoney(k.amount, cur)}</div>
            <div className="text-xs text-muted">{t('hr.emp.ticketDetail', { months: k.months, every: k.every_months ?? '—', next: fmtDay(k.next_due) })}</div></>
            : <p dir="auto" className="text-muted">{k.message}</p>}
        </div>
        <p className="rounded-btn bg-surface-2 px-3 py-2 text-xs text-muted">{t('hr.emp.notPosted')}</p>
      </div>
    </SectionCard>
  );
}

function DocumentsCard({ company, info, onDone }: { company: string; info: EmployeeInfo; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ doc_type: 'passport', doc_no: '', issued_on: '', expires_on: '' });
  const [file, setFile] = useState<File | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true); setErr(null);
    try {
      const path = file ? await uploadHrFile(company, info.employee.emp_id, file) : null;
      await documentSave(company, { ...f, emp_id: info.employee.emp_id, storage_path: path, file_name: file?.name ?? null });
      setOpen(false); setFile(null); setF({ doc_type: 'passport', doc_no: '', issued_on: '', expires_on: '' }); onDone(t('hr.emp.docSaved'));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const docs = [...info.documents, ...info.sap_documents.map((d) => ({ ...d, doc_type: String(d.doc_type).toLowerCase().replace(/ /g, '_'), storage_path: null }))];
  return (
    <SectionCard title={t('hr.portal.documents')} right={info.can_edit_hr && !open ? <Button variant="ghost" data-testid="hr-doc-add" onClick={() => setOpen(true)} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('hr.emp.addDoc')}</Button> : undefined}>
      {docs.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.portal.noDocuments')}</p> : <ul className="divide-y divide-line" data-testid="hr-docs">{docs.map((d, i) => <DocRow key={i} d={d as Parameters<typeof DocRow>[0]["d"]} />)}</ul>}
      {open && (
        <div className="border-t border-line p-5">
          <FormError message={err} />
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Sel id="hr-doc-type" label={t('hr.col.document')} value={f.doc_type} onChange={(v) => setF({ ...f, doc_type: v })}
              options={['passport', 'visa', 'emirates_id', 'labour_card', 'other'].map((x) => [x, t(`hr.docType.${x}`)])} />
            <Txt id="hr-doc-no" label={t('hr.col.docNo')} dir="ltr" value={f.doc_no} onChange={(v) => setF({ ...f, doc_no: v })} />
            <Txt label={t('hr.f.issued')} type="date" value={f.issued_on} onChange={(v) => setF({ ...f, issued_on: v })} />
            <Txt id="hr-doc-expires" label={t('hr.expires')} type="date" value={f.expires_on} onChange={(v) => setF({ ...f, expires_on: v })} />
            <label className={clsx(hrLabel, 'sm:col-span-2 lg:col-span-4')}>{t('hr.emp.file')}
              <span className="mt-1 flex items-center gap-2"><Upload className="h-4 w-4 text-muted" aria-hidden />
                <input type="file" accept="application/pdf,image/*" className="text-sm" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></span>
              <span className="mt-1 block text-[12px] font-normal text-muted">{t('hr.emp.fileHelp')}</span>
            </label>
          </div>
          <div className="mt-4 flex justify-end gap-2"><Button onClick={() => setOpen(false)}>{t('hr.cancel')}</Button><Button variant="primary" data-testid="hr-doc-save" disabled={busy} onClick={save}>{t('hr.save')}</Button></div>
        </div>
      )}
    </SectionCard>
  );
}

export function EmployeeFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = params.company ?? dflt;
  const id = Number(params.id ?? 0);
  const info = useEmployeeInfo(company, mode === 'edit' ? id : 0);
  const setup = useHrSetup(company);
  const { canWrite } = useModuleLevel('hr');
  const [f, setF] = useState<Record<string, string>>({ first_name: '', middle_name: '', last_name: '', job_title: '', division: '', branch_id: '', manager_emp_id: '',
    mobile: '', email: '', gender: '', birth_date: '', nationality: '', passport_no: '', passport_expires: '', gov_id: '', joined_on: '', left_on: '', status: 'active' });
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const e = info.data?.employee;
    if (mode === 'edit' && e) setF(Object.fromEntries(Object.keys(f).map((k) => [k, s(e[k])])));
  }, [info.data]); // eslint-disable-line react-hooks/exhaustive-deps
  if (mode === 'edit' && info.isLoading) return <PageLoading />;
  const set = (k: string) => (v: string) => setF((p) => ({ ...p, [k]: v }));
  const save = async () => {
    setBusy(true); setErr(null);
    try {
      const body: Record<string, unknown> = { ...f };
      if (mode === 'edit') body.emp_id = id;
      const r = await employeeSave(company, body, mode === 'new' ? series : null);
      qc.invalidateQueries({ queryKey: ['hr-emp'] });
      nav(`/hr/employees/${company}/${r.emp_id}`, { state: { flash: mode === 'new' ? t('hr.emp.created', { code: r.hr_code }) : t('hr.saved') } });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const st: HrSetup | undefined = setup.data;
  const title = mode === 'new' ? t('hr.emp.new') : t('hr.emp.editTitle', { code: info.data?.employee.hr_code ?? id });
  return (
    <RequireModule module="hr">
      <HrHeader back={[t('erp.page.employees'), '/hr/employees']} title={title} />
      {!canWrite && <FormError message={t('erp.readOnly', { module: 'Human Resources' })} />}
      <FormError message={err} />
      <SectionCard title={t('erp.section.general')}>
        <div className="grid gap-4 p-5 sm:grid-cols-2 lg:grid-cols-3">
          <Txt id="hr-f-first" label={t('hr.f.firstName')} required value={f.first_name} onChange={set('first_name')} />
          <Txt label={t('hr.f.middleName')} value={f.middle_name} onChange={set('middle_name')} />
          <Txt id="hr-f-last" label={t('hr.f.lastName')} required value={f.last_name} onChange={set('last_name')} />
          <Txt id="hr-f-job" label={t('hr.f.jobTitle')} value={f.job_title} onChange={set('job_title')} />
          <label className={hrLabel}>{t('hr.f.department')}
            <input data-testid="hr-f-dept" list="hr-depts" dir="auto" className={hrInput} value={f.division} onChange={(e) => set('division')(e.target.value)} />
            <datalist id="hr-depts">{(st?.departments ?? []).map((d) => <option key={d} value={d} />)}</datalist>
          </label>
          <Sel label={t('hr.f.branch')} value={f.branch_id} onChange={set('branch_id')} empty="—" options={(st?.branches ?? []).map((b) => [String(b.id), b.name])} />
          {mode === 'new' && <SeriesPicker company={company} obj={171} value={series} onChange={setSeries} label={t('num.pick.empLabel')} />}
          <Sel id="hr-f-manager" label={t('hr.f.manager')} value={f.manager_emp_id} onChange={set('manager_emp_id')} empty="—"
            options={(st?.employees ?? []).filter((x) => x.emp_id !== id).map((x) => [String(x.emp_id), `${x.hr_code} · ${x.name}`])} />
          <Txt label={t('hr.f.mobile')} dir="ltr" value={f.mobile} onChange={set('mobile')} />
          <Txt id="hr-f-email" label={t('hr.f.email')} dir="ltr" value={f.email} onChange={set('email')} />
          <Sel label={t('hr.f.gender')} value={f.gender} onChange={set('gender')} empty="—" options={[['F', t('hr.gender.F')], ['M', t('hr.gender.M')]]} />
          <Txt label={t('hr.f.birth')} type="date" value={f.birth_date} onChange={set('birth_date')} />
          <Txt label={t('hr.f.nationality')} dir="ltr" value={f.nationality} onChange={set('nationality')} help={t('hr.f.nationalityHelp')} />
          <Txt label={t('hr.f.passport')} dir="ltr" value={f.passport_no} onChange={set('passport_no')} />
          <Txt label={t('hr.f.passportExpires')} type="date" value={f.passport_expires} onChange={set('passport_expires')} />
          <Txt id="hr-f-govid" label={t('hr.f.govId')} dir="ltr" value={f.gov_id} onChange={set('gov_id')} help={t('hr.f.govIdHelp')} />
          <Txt id="hr-f-joined" label={t('hr.f.joined')} required type="date" value={f.joined_on} onChange={set('joined_on')} />
          <Txt label={t('hr.f.left')} type="date" value={f.left_on} onChange={set('left_on')} />
          <Sel label={t('erp.col.status')} value={f.status} onChange={set('status')} options={['active', 'on_leave', 'left'].map((x) => [x, t(`hr.status.${x}`)])} />
        </div>
      </SectionCard>
      <div className="mt-5 flex justify-end gap-2">
        <Link to="/hr/employees" className={secondaryLink}>{t('hr.cancel')}</Link>
        <Button variant="primary" data-testid="hr-f-save" disabled={busy || !canWrite} onClick={save}>{mode === 'new' ? t('hr.emp.create') : t('hr.save')}</Button>
      </div>
    </RequireModule>
  );
}

// ---------- Payroll ----------
export function PayrollListPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const company = useDefaultCompany();
  const [period, setPeriod] = useState(thisMonth());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'hr-payroll', table: 'payroll_run_list',
    select: 'company_code,run_id,period,state,stale,headcount,gross,deductions,net,currency,calculated_at,posted_at,trans_id',
    searchCols: ['period'], searchLabel: t('hr.payroll.search'),
    filters: [{ key: 'state', label: t('erp.col.status'), options: (['draft', 'reviewed', 'locked', 'posted'] as RunState[]).map((x) => [x, t(`hr.runState.${x}`)]) }],
    defaultSort: { col: 'period', asc: false },
    rowKey: (r) => String(r.run_id), rowLink: (r) => `/hr/payroll/${r.company_code}/${r.run_id}`,
    emptyTitle: t('hr.payroll.empty'), emptyBody: t('hr.payroll.emptyBody'),
    columns: [
      { key: 'period', header: t('hr.col.period'), mono: true },
      { key: 'headcount', header: t('hr.col.headcount'), align: 'end', hideBelow: 'sm' },
      { key: 'gross', header: t('hr.gross'), align: 'end', cell: (r) => fmtMoney(r.gross), hideBelow: 'md' },
      { key: 'deductions', header: t('hr.deductions'), align: 'end', cell: (r) => fmtMoney(r.deductions), hideBelow: 'lg' },
      { key: 'net', header: t('hr.net'), align: 'end', cell: (r) => fmtMoney(r.net, r.currency) },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <RunPill state={r.state} />, csv: (r) => r.state },
    ],
  }), [t]);
  const calc = async () => {
    setBusy(true); setErr(null);
    try { const r = await payrollCalculate(company, period); nav(`/hr/payroll/${company}/${r.run_id}`, { state: { flash: t('hr.payroll.calculated', { n: r.headcount }) } }); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <HrFrame title={t('hr.payroll.title')} desc={t('hr.payroll.desc')}>
      <SectionCard title={t('hr.payroll.run')} className="mb-5">
        <div className="flex flex-wrap items-end gap-3 p-5">
          <FormError message={err} />
          <label className={hrLabel}>{t('hr.col.period')}<input data-testid="hr-run-period" type="month" className={hrInput} value={period} onChange={(e) => setPeriod(e.target.value)} /></label>
          <Button variant="primary" data-testid="hr-run-calc" disabled={busy || !company} onClick={calc}>{t('hr.payroll.calculate')}</Button>
        </div>
      </SectionCard>
      <ListScreen config={cfg} />
    </HrFrame>
  );
}

export function PayrollRunPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = usePayroll(company, Number(id));
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [openEmp, setOpenEmp] = useState<number | null>(null);
  if (q.isLoading) return <PageLoading />;
  if (q.error || !q.data) return <RequireModule module="hr"><ErrorState error={q.error ?? new Error(t('erp.notFound'))} onRetry={() => q.refetch()} /></RequireModule>;
  const { run, employees, inputs, banks, journal } = q.data;
  const cur = run.currency;
  const act = async (fn: () => Promise<unknown>, msg: string) => {
    setBusy(true); setErr(null);
    try { await fn(); setFlash(msg); await q.refetch(); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const bad = employees.filter((e) => e.errors.length > 0).length;
  return (
    <RequireModule module="hr">
      <HrHeader back={[t('hr.payroll.title'), '/hr/payroll']} title={t('hr.payroll.titleN', { period: run.period })} pills={<RunPill state={run.state} />}
        sub={`${fmtDay(run.from_date)} – ${fmtDay(run.to_date)} · ${t('hr.payroll.headcount', { n: run.headcount })}`}
        actions={<>
          {run.state === 'draft' && <Button data-testid="hr-run-recalc" disabled={busy} onClick={() => act(() => payrollCalculate(company, run.period), t('hr.payroll.recalculated'))}>{t('hr.payroll.recalculate')}</Button>}
          {run.state === 'draft' && <Button variant="primary" data-testid="hr-run-review" disabled={busy} onClick={() => act(() => payrollStep(company, run.run_id, 'review'), t('hr.payroll.reviewedMsg'))}>{t('hr.payroll.review')}</Button>}
          {run.state === 'reviewed' && <Button data-testid="hr-run-reopen" disabled={busy} onClick={() => act(() => payrollStep(company, run.run_id, 'reopen'), t('hr.payroll.reopenedMsg'))}>{t('hr.payroll.reopen')}</Button>}
          {run.state === 'reviewed' && <Button variant="primary" data-testid="hr-run-lock" disabled={busy} icon={<Lock className="h-4 w-4" aria-hidden />} onClick={() => act(() => payrollStep(company, run.run_id, 'lock'), t('hr.payroll.lockedMsg'))}>{t('hr.payroll.lock')}</Button>}
          {run.state === 'locked' && <Button variant="primary" data-testid="hr-run-post" disabled={busy} onClick={() => act(() => payrollPost(company, run.run_id), t('hr.payroll.postedMsg'))}>{t('hr.payroll.post')}</Button>}
        </>} />
      <Flash text={flash} />
      <FormError message={err} />
      {run.stale && <p role="status" className="mb-4 rounded-btn border border-warn-fg/30 bg-warn-bg px-4 py-3 text-sm text-warn-fg">{t('hr.payroll.stale')}</p>}
      {bad > 0 && <p role="alert" className="mb-4 rounded-btn border border-crit-fg/30 bg-crit-bg px-4 py-3 text-sm text-crit-fg">{t('hr.payroll.problems', { n: bad })}</p>}
      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-4" data-testid="hr-run-totals">
        {([['hr.col.headcount', String(run.headcount)], ['hr.gross', fmtMoney(run.gross, cur)], ['hr.deductions', fmtMoney(run.deductions, cur)], ['hr.net', fmtMoney(run.net, cur)]] as const).map(([k, v]) => (
          <div key={k} className="card p-4"><div className="text-xs text-muted">{t(k)}</div><div className="num mt-1 text-lg font-semibold">{v}</div></div>
        ))}
      </div>
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('hr.payroll.employees')}>
            <div className="relative overflow-x-auto">
              <table className="w-full text-sm" data-testid="hr-run-emps">
                <thead className="bg-surface-2 text-xs text-muted"><tr>
                  <th scope="col" className="px-4 py-2 text-start">{t('hr.col.employee')}</th>
                  <th scope="col" className="px-4 py-2 text-end max-sm:hidden">{t('hr.daysPaid')}</th>
                  <th scope="col" className="px-4 py-2 text-end max-md:hidden">{t('hr.gross')}</th>
                  <th scope="col" className="px-4 py-2 text-end max-md:hidden">{t('hr.deductions')}</th>
                  <th scope="col" className="px-4 py-2 text-end">{t('hr.net')}</th></tr></thead>
                <tbody>
                  {employees.map((e) => (
                    <Fragment key={e.emp_id}>
                      <tr className={clsx('cursor-pointer border-t border-line hover:bg-surface-2', e.errors.length > 0 && 'bg-crit-bg')} onClick={() => setOpenEmp(openEmp === e.emp_id ? null : e.emp_id)}>
                        <td className="px-4 py-2"><button type="button" className="text-start font-medium text-primary hover:underline" aria-expanded={openEmp === e.emp_id}>{e.name}</button>
                          <span className="ms-1 font-mono text-xs text-muted">{e.hr_code}</span>
                          {e.errors.map((m: string) => <div key={m} className="text-xs text-crit-fg" dir="auto">{m}</div>)}</td>
                        <td className="num px-4 py-2 text-end max-sm:hidden">{days(e.days_paid)}</td>
                        <td className="num px-4 py-2 text-end max-md:hidden">{fmtMoney(e.gross)}</td>
                        <td className="num px-4 py-2 text-end max-md:hidden">{fmtMoney(e.deductions)}</td>
                        <td className="num px-4 py-2 text-end font-semibold">{fmtMoney(e.net)}</td>
                      </tr>
                      {openEmp === e.emp_id && (
                        <tr className="bg-surface-2"><td colSpan={5} className="px-4 py-2">
                          <ul className="space-y-1 text-xs">{e.lines.map((l) => (
                            <li key={l.line_no} className="flex justify-between gap-2"><span dir="auto">{l.kind === 'deduction' ? '− ' : ''}{l.name ?? l.wage_code}{l.note ? ` · ${l.note}` : ''}</span><span className="num">{fmtMoney(l.amount)}</span></li>))}
                          </ul>
                          {['locked', 'posted'].includes(run.state) && <Link to={`/portal/payslip/${company}/${run.run_id}?emp=${e.emp_id}`} className="mt-2 inline-block text-xs font-medium text-primary hover:underline">{t('hr.payroll.payslip')}</Link>}
                        </td></tr>
                      )}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
            {run.skipped.length > 0 && <p className="border-t border-line px-5 py-2 text-xs text-muted" dir="auto">{t('hr.payroll.skipped', { list: run.skipped.map((x: R) => `${x.hr_code} ${x.name}`).join(', ') })}</p>}
          </SectionCard>
          {journal && (
            <SectionCard title={t('hr.payroll.journal', { n: run.trans_id })} right={<Link to={`/financials/journals/${company}/${run.trans_id}`} className="text-sm font-medium text-primary hover:underline">{t('hr.open')}</Link>}>
              <div className="relative overflow-x-auto"><table className="w-full text-sm" data-testid="hr-run-journal"><tbody>
                {journal.map((l, i) => <tr key={i} className="border-t border-line"><td className="px-5 py-2 font-mono text-xs">{l.acct_code}</td><td className="px-5 py-2" dir="auto">{l.name}</td>
                  <td className="num px-5 py-2 text-end">{Number(l.debit) ? fmtMoney(l.debit) : ''}</td><td className="num px-5 py-2 text-end">{Number(l.credit) ? fmtMoney(l.credit) : ''}</td></tr>)}
              </tbody></table></div>
            </SectionCard>
          )}
        </div>
        <aside className="min-w-0 space-y-5">
          <InputsCard company={company} run={run} inputs={inputs} employees={employees} onDone={(m) => { setFlash(m); q.refetch(); }} />
          <WpsCard company={company} runId={run.run_id} state={run.state} banks={banks} currency={cur} />
          <SectionCard title={t('je.activity.title')}>
            <ol className="space-y-3 p-5 text-sm">{q.data.history.map((h, i) => (
              <li key={i}><span className="font-medium">{h.actor ?? '—'}</span> {t(`hr.activity.${h.action}`, { defaultValue: h.action })}<div className="text-xs text-muted">{fmtWhen(h.at)}</div></li>))}
            </ol>
          </SectionCard>
        </aside>
      </div>
    </RequireModule>
  );
}

function InputsCard({ company, run, inputs, employees, onDone }: { company: string; run: R; inputs: R[]; employees: R[]; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const setup = useHrSetup(company);
  const [f, setF] = useState({ emp_id: '', kind: 'overtime_hours', wage_code: '', value: '', note: '' });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const editable = run.state === 'draft';
  const wages = (setup.data?.wage_types ?? []).filter((w) => w.calc_type === 'input' && (f.kind === 'deduction' ? w.is_deduction : w.is_earning));
  const add = async () => {
    setBusy(true); setErr(null);
    try { await payrollInputSave(company, { ...f, period: run.period }); setF({ ...f, value: '', note: '' }); onDone(t('hr.payroll.inputAdded')); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const emps = setup.data?.employees ?? employees.map((e) => ({ emp_id: e.emp_id, hr_code: e.hr_code, name: e.name }));
  return (
    <SectionCard title={t('hr.payroll.inputs')}>
      {inputs.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.payroll.noInputs')}</p> : (
        <ul className="divide-y divide-line text-sm" data-testid="hr-inputs">{inputs.map((i) => (
          <li key={i.input_id} className="flex items-center justify-between gap-2 px-5 py-2">
            <span dir="auto"><span className="font-medium">{i.hr_code}</span> · {t(`hr.input.${i.kind}`)}{i.wage_code ? ` (${i.wage_code})` : ''}: <span className="num">{fmtMoney(i.value)}</span></span>
            {editable && <button type="button" aria-label={t('hr.remove')} className="grid h-10 w-10 place-items-center rounded-btn hover:bg-crit-bg"
              onClick={() => payrollInputRemove(company, i.input_id).then(() => onDone(t('hr.payroll.inputRemoved'))).catch((e) => setErr(errorMessage(e)))}><Trash2 className="h-4 w-4 text-crit-fg" aria-hidden /></button>}
          </li>))}
        </ul>
      )}
      {editable && (
        <div className="space-y-3 border-t border-line p-5">
          <FormError message={err} />
          <Sel id="hr-in-emp" label={t('hr.col.employee')} value={f.emp_id} onChange={(v) => setF({ ...f, emp_id: v })} empty={t('hr.choose')} options={emps.map((e) => [String(e.emp_id), `${e.hr_code} · ${e.name}`])} />
          <Sel id="hr-in-kind" label={t('hr.payroll.kind')} value={f.kind} onChange={(v) => setF({ ...f, kind: v, wage_code: '' })} options={['overtime_hours', 'unpaid_days', 'deduction', 'earning'].map((k) => [k, t(`hr.input.${k}`)])} />
          {(f.kind === 'deduction' || f.kind === 'earning') && <Sel id="hr-in-wage" label={t('hr.col.wage')} value={f.wage_code} onChange={(v) => setF({ ...f, wage_code: v })} empty={t('hr.choose')} options={wages.map((w) => [w.code, w.name ?? w.code])} />}
          <Txt id="hr-in-value" label={f.kind === 'overtime_hours' ? t('hr.payroll.hours') : f.kind === 'unpaid_days' ? t('hr.col.days') : t('hr.col.amount')} inputMode="decimal" value={f.value} onChange={(v) => setF({ ...f, value: v })} />
          <Txt label={t('hr.f.note')} value={f.note} onChange={(v) => setF({ ...f, note: v })} />
          <Button variant="primary" data-testid="hr-in-add" className="w-full" disabled={busy} onClick={add}>{t('hr.payroll.addInput')}</Button>
        </div>
      )}
    </SectionCard>
  );
}

function WpsCard({ company, runId, state, banks, currency }: { company: string; runId: number; state: RunState; banks: Array<{ bank_code: string; name: string }>; currency: string }) {
  const { t } = useTranslation();
  const [bank, setBank] = useState(banks[0]?.bank_code ?? '');
  const [res, setRes] = useState<Awaited<ReturnType<typeof wpsCheck>> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const locked = state === 'locked' || state === 'posted';
  const check = async () => { setBusy(true); setErr(null); try { setRes(await wpsCheck(company, runId, bank)); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); } };
  const download = async () => {
    setBusy(true); setErr(null);
    try { const f = await wpsFile(company, runId, bank); downloadText(f.file_name, f.content); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <SectionCard title={t('hr.wps.title')}>
      <div className="space-y-3 p-5 text-sm">
        <FormError message={err} />
        {banks.length === 0 ? <p className="text-muted">{t('hr.wps.noBank')}</p> : (
          <Sel id="hr-wps-bank" label={t('hr.f.wpsBank')} value={bank} onChange={(v) => { setBank(v); setRes(null); }} options={banks.map((b) => [b.bank_code, b.name])} />
        )}
        <div className="flex flex-wrap gap-2">
          <Button data-testid="hr-wps-check" disabled={busy || !bank} onClick={check}>{t('hr.wps.check')}</Button>
          <Button variant="primary" data-testid="hr-wps-download" disabled={busy || !bank || !locked} disabledReason={!locked ? t('hr.wps.lockFirst') : undefined}
            icon={<Download className="h-4 w-4" aria-hidden />} onClick={download}>{t('hr.wps.download')}</Button>
        </div>
        {res && (res.errors.length === 0
          ? <p role="status" data-testid="hr-wps-ok" className="rounded-btn border border-ok-fg/30 bg-ok-bg px-3 py-2 text-ok-fg">{t('hr.wps.ok', { n: res.count, total: fmtMoney(res.total, currency) })}</p>
          : <ul role="alert" data-testid="hr-wps-errors" className="space-y-1 rounded-btn border border-crit-fg/30 bg-crit-bg px-3 py-2 text-crit-fg">{res.errors.map((e, i) => <li key={i} dir="auto">{e.message}</li>)}</ul>)}
        <p className="text-xs text-muted">{t('hr.wps.note')}</p>
      </div>
    </SectionCard>
  );
}

// ---------- HR setup ----------
export function HrSetupPage() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const q = useHrSetup(company);
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const save = async (kind: string, data: Record<string, unknown>, msg = t('hr.saved')) => {
    setErr(null);
    try { await setupSave(company, kind, data); setFlash(msg); await q.refetch(); return true; } catch (e) { setErr(errorMessage(e)); return false; }
  };
  return (
    <HrFrame title={t('hr.setup.title')} desc={t('hr.setup.desc')}>
      <Flash text={flash} />
      <FormError message={err} />
      {q.isLoading ? <PageLoading /> : q.error || !q.data ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : (
        <SetupBody st={q.data} save={save} />
      )}
    </HrFrame>
  );
}

function SetupBody({ st, save }: { st: HrSetup; save: (kind: string, data: Record<string, unknown>, msg?: string) => Promise<boolean> }) {
  const { t } = useTranslation();
  const ed = st.can_edit;
  const g = st.setting ?? {};
  const [gs, setGs] = useState<Record<string, string>>(() => ({
    timezone: s(g.timezone || 'Asia/Dubai'), weekend: (g.weekend ?? []).join(','), long_leave_days: s(g.long_leave_days), hr_approver_position: s(g.hr_approver_position),
    owner_position: s(g.owner_position), month_days_basis: s(g.month_days_basis), hours_per_day: s(g.hours_per_day), ot_multiplier: s(g.ot_multiplier),
    ot_rate_basis: s(g.ot_rate_basis), ot_wage_code: s(g.ot_wage_code), unpaid_wage_code: s(g.unpaid_wage_code), unpaid_basis: s(g.unpaid_basis),
    gratuity_min_years: s(g.gratuity_min_years), gratuity_years_first: s(g.gratuity_years_first), gratuity_days_first: s(g.gratuity_days_first),
    gratuity_days_after: s(g.gratuity_days_after), gratuity_cap_years: s(g.gratuity_cap_years), gratuity_day_basis: s(g.gratuity_day_basis),
    employer_mol_id: s(g.employer_mol_id), wps_employer_id_len: s(g.wps_employer_id_len), wps_person_id_len: s(g.wps_person_id_len), wps_routing_len: s(g.wps_routing_len),
    expiry_alert_days: (g.expiry_alert_days ?? [60, 30, 7]).join(','),
  }));
  const pos: Array<[string, string]> = st.positions.map((p) => [p.code, p.name]);
  const wages: Array<[string, string]> = st.wage_types.map((w) => [w.code, w.name ?? w.code]);
  const G = (k: string) => (v: string) => setGs((p) => ({ ...p, [k]: v }));
  const saveGeneral = () => {
    const nums = (v: string) => v.split(',').map((x) => x.trim()).filter(Boolean).map(Number);
    const { weekend, expiry_alert_days, ...rest } = gs;
    return save('setting', { ...rest, weekend: nums(weekend), expiry_alert_days: nums(expiry_alert_days) });
  };
  return (
    <div className="space-y-5">
      {!st.setting && <p role="status" className="rounded-btn border border-warn-fg/30 bg-warn-bg px-4 py-3 text-sm text-warn-fg">{t('hr.setup.empty')}</p>}
      <SectionCard title={t('hr.setup.general')}>
        <fieldset disabled={!ed} className="grid gap-4 p-5 sm:grid-cols-2 lg:grid-cols-4">
          <Txt label={t('hr.setup.timezone')} dir="ltr" value={gs.timezone} onChange={G('timezone')} />
          <Txt label={t('hr.setup.weekend')} dir="ltr" value={gs.weekend} onChange={G('weekend')} help={t('hr.setup.weekendHelp')} />
          <Txt label={t('hr.setup.longLeave')} inputMode="decimal" value={gs.long_leave_days} onChange={G('long_leave_days')} />
          <Txt label={t('hr.setup.alerts')} dir="ltr" value={gs.expiry_alert_days} onChange={G('expiry_alert_days')} />
          <Sel label={t('hr.setup.hrApprover')} value={gs.hr_approver_position} onChange={G('hr_approver_position')} empty="—" options={pos} />
          <Sel label={t('hr.setup.ownerApprover')} value={gs.owner_position} onChange={G('owner_position')} empty="—" options={pos} />
          <Sel label={t('hr.setup.monthBasis')} value={gs.month_days_basis} onChange={G('month_days_basis')} empty="—" options={[['30', t('hr.setup.basis30')], ['calendar', t('hr.setup.basisCal')]]} />
          <Txt label={t('hr.setup.hoursDay')} inputMode="decimal" value={gs.hours_per_day} onChange={G('hours_per_day')} />
          <Txt label={t('hr.setup.otMult')} inputMode="decimal" value={gs.ot_multiplier} onChange={G('ot_multiplier')} />
          <Sel label={t('hr.setup.otBasis')} value={gs.ot_rate_basis} onChange={G('ot_rate_basis')} empty="—" options={[['basic', t('hr.setup.basic')], ['gross', t('hr.setup.grossB')]]} />
          <Sel label={t('hr.setup.otWage')} value={gs.ot_wage_code} onChange={G('ot_wage_code')} empty="—" options={wages} />
          <Sel label={t('hr.setup.unpaidWage')} value={gs.unpaid_wage_code} onChange={G('unpaid_wage_code')} empty="—" options={wages} />
          <Sel label={t('hr.setup.unpaidBasis')} value={gs.unpaid_basis} onChange={G('unpaid_basis')} empty="—" options={[['basic', t('hr.setup.basic')], ['gross', t('hr.setup.grossB')]]} />
          <Txt label={t('hr.setup.gMin')} inputMode="decimal" value={gs.gratuity_min_years} onChange={G('gratuity_min_years')} />
          <Txt label={t('hr.setup.gYears')} inputMode="decimal" value={gs.gratuity_years_first} onChange={G('gratuity_years_first')} />
          <Txt label={t('hr.setup.gDaysFirst')} inputMode="decimal" value={gs.gratuity_days_first} onChange={G('gratuity_days_first')} />
          <Txt label={t('hr.setup.gDaysAfter')} inputMode="decimal" value={gs.gratuity_days_after} onChange={G('gratuity_days_after')} />
          <Txt label={t('hr.setup.gCap')} inputMode="decimal" value={gs.gratuity_cap_years} onChange={G('gratuity_cap_years')} />
          <Sel label={t('hr.setup.gBasis')} value={gs.gratuity_day_basis} onChange={G('gratuity_day_basis')} empty="—" options={[['30', t('hr.setup.g30')], ['365', t('hr.setup.g365')]]} />
          <Txt label={t('hr.setup.employerId')} dir="ltr" inputMode="numeric" value={gs.employer_mol_id} onChange={G('employer_mol_id')} />
          <Txt label={t('hr.setup.lenEmployer')} inputMode="numeric" value={gs.wps_employer_id_len} onChange={G('wps_employer_id_len')} />
          <Txt label={t('hr.setup.lenPerson')} inputMode="numeric" value={gs.wps_person_id_len} onChange={G('wps_person_id_len')} />
          <Txt label={t('hr.setup.lenRouting')} inputMode="numeric" value={gs.wps_routing_len} onChange={G('wps_routing_len')} />
        </fieldset>
        <div className="flex flex-wrap items-center justify-between gap-2 border-t border-line px-5 py-3">
          <p className="text-xs text-muted">{t('hr.setup.payable', { acct: g.payable_acct ?? '—' })}</p>
          {ed && <Button variant="primary" data-testid="hr-setup-save" onClick={saveGeneral}>{t('hr.save')}</Button>}
        </div>
      </SectionCard>
      <RowsCard title={t('hr.setup.sites')} kind="site" ed={ed} save={save} rows={st.sites} testid="hr-sites"
        cols={[['site_code', t('hr.col.code')], ['name', t('hr.f.name')], ['lat', t('hr.setup.lat')], ['lng', t('hr.setup.lng')], ['radius_m', t('hr.setup.radius')]]} />
      <RowsCard title={t('hr.setup.shifts')} kind="shift" ed={ed} save={save} rows={st.shifts.map((x) => ({ ...x, departments: x.departments.join(', ') }))}
        cols={[['shift_code', t('hr.col.code')], ['name', t('hr.f.name')], ['start_time', t('hr.setup.start')], ['end_time', t('hr.setup.end')], ['grace_min', t('hr.setup.grace')], ['departments', t('hr.setup.departments')]]}
        prep={(r) => ({ ...r, departments: String(r.departments ?? '').split(',').map((x) => x.trim()).filter(Boolean) })} />
      <RowsCard title={t('hr.setup.duties')} kind="duty" ed={ed} save={save} rows={st.duties}
        cols={[['department', t('hr.f.department')], ['title', t('hr.setup.duty')], ['shift_code', t('hr.f.shift')], ['sort', t('hr.setup.sort')]]} idKey="duty_id" />
      <RowsCard title={t('hr.setup.holidays')} kind="holiday" ed={ed} save={save} rows={st.holidays} cols={[['day', t('hr.col.date')], ['name', t('hr.f.name')]]} removeKind="holiday_remove" />
      <RowsCard title={t('hr.setup.policies')} kind="policy" ed={ed} save={save}
        rows={st.leave_types.map((lt) => ({ leave_code: lt.code, name: lt.name, annual_days: lt.policy?.annual_days ?? '', accrual: lt.policy?.accrual ?? '', basis: lt.policy?.basis ?? '' }))}
        cols={[['leave_code', t('hr.col.code')], ['name', t('hr.f.name'), true], ['annual_days', t('hr.setup.annual')], ['accrual', t('hr.setup.accrual')], ['basis', t('hr.setup.dayBasis')]]} noAdd />
      <RowsCard title={t('hr.setup.banks')} kind="wps_bank" ed={ed} save={save} rows={st.wps_banks}
        cols={[['bank_code', t('hr.col.code')], ['name', t('hr.f.name')], ['employer_routing', t('hr.setup.routing')], ['employer_ref', t('hr.setup.ref')]]} />
      <AdjustCard st={st} save={save} />
    </div>
  );
}

function RowsCard({ title, kind, rows, cols, ed, save, idKey, removeKind, noAdd, prep, testid }: {
  title: string; kind: string; rows: R[]; cols: Array<[string, string, boolean?]>; ed: boolean; idKey?: string; removeKind?: string; noAdd?: boolean; testid?: string;
  prep?: (r: Record<string, unknown>) => Record<string, unknown>; save: (kind: string, data: Record<string, unknown>) => Promise<boolean>;
}) {
  const { t } = useTranslation();
  const [edit, setEdit] = useState<Record<string, string> | null>(null);
  const begin = (r?: R) => setEdit(Object.fromEntries([...cols.map(([k]) => [k, s(r?.[k])]), ...(idKey && r ? [[idKey, s(r[idKey])]] : [])]));
  const commit = async () => { if (!edit) return; if (await save(kind, prep ? prep(edit) : edit)) setEdit(null); };
  return (
    <SectionCard title={title} right={ed && !noAdd && !edit ? <Button variant="ghost" icon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => begin()}>{t('hr.add')}</Button> : undefined}>
      <div className="relative overflow-x-auto">
        <table className="w-full text-sm" data-testid={testid}>
          <thead className="bg-surface-2 text-xs text-muted"><tr>{cols.map(([k, l]) => <th key={k} scope="col" className="px-4 py-2 text-start">{l}</th>)}<th scope="col" className="w-24"><span className="sr-only">{t('hr.edit')}</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={cols.length + 1} className="px-4 py-3 text-muted">{t('hr.setup.none')}</td></tr>}
            {rows.map((r, i) => (
              <tr key={i} className="border-t border-line">{cols.map(([k]) => <td key={k} dir="auto" className="px-4 py-2">{s(r[k]) || '—'}</td>)}
                <td className="px-2 py-1 text-end">{ed && <span className="inline-flex">
                  <button type="button" aria-label={t('hr.edit')} className="grid h-10 w-10 place-items-center rounded-btn hover:bg-surface-2" onClick={() => begin(r)}><Pencil className="h-4 w-4" aria-hidden /></button>
                  {removeKind && <button type="button" aria-label={t('hr.remove')} className="grid h-10 w-10 place-items-center rounded-btn hover:bg-crit-bg" onClick={() => save(removeKind, r)}><Trash2 className="h-4 w-4 text-crit-fg" aria-hidden /></button>}
                </span>}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
      {edit && (
        <div className="border-t border-line p-5">
          <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
            {cols.filter(([, , ro]) => !ro).map(([k, l]) => <Txt key={k} label={l} value={edit[k] ?? ''} onChange={(v) => setEdit({ ...edit, [k]: v })} />)}
          </div>
          <div className="mt-3 flex justify-end gap-2"><Button onClick={() => setEdit(null)}>{t('hr.cancel')}</Button><Button variant="primary" onClick={commit}>{t('hr.save')}</Button></div>
        </div>
      )}
    </SectionCard>
  );
}

function AdjustCard({ st, save }: { st: HrSetup; save: (kind: string, data: Record<string, unknown>, msg?: string) => Promise<boolean> }) {
  const { t } = useTranslation();
  const [f, setF] = useState({ emp_id: '', leave_code: '', days: '', leave_year: String(new Date().getFullYear()), note: '' });
  if (!st.can_edit) return null;
  const tracked = st.leave_types.filter((lt) => lt.policy && lt.policy.accrual !== 'none');
  return (
    <SectionCard title={t('hr.setup.adjust')}>
      <div className="grid gap-3 p-5 sm:grid-cols-2 lg:grid-cols-5">
        <Sel label={t('hr.col.employee')} value={f.emp_id} onChange={(v) => setF({ ...f, emp_id: v })} empty={t('hr.choose')} options={st.employees.map((e) => [String(e.emp_id), `${e.hr_code} · ${e.name}`])} />
        <Sel label={t('hr.f.leaveType')} value={f.leave_code} onChange={(v) => setF({ ...f, leave_code: v })} empty={t('hr.choose')} options={tracked.map((lt) => [lt.code, lt.name])} />
        <Txt label={t('hr.col.days')} inputMode="decimal" value={f.days} onChange={(v) => setF({ ...f, days: v })} />
        <Txt label={t('hr.setup.year')} inputMode="numeric" value={f.leave_year} onChange={(v) => setF({ ...f, leave_year: v })} />
        <Txt label={t('hr.f.note')} value={f.note} onChange={(v) => setF({ ...f, note: v })} />
      </div>
      <div className="flex justify-end border-t border-line px-5 py-3"><Button variant="primary" onClick={async () => { if (await save('leave_adjust', f, t('hr.setup.adjusted'))) setF({ ...f, days: '', note: '' }); }}>{t('hr.add')}</Button></div>
    </SectionCard>
  );
}
export { FieldErr };

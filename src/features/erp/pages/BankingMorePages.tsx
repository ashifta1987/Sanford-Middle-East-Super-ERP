import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, Link2, Plus, Unlink, Upload, Wand2 } from 'lucide-react';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Fields, Kpi, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { SeriesPicker } from '../components/SeriesPicker';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey } from '../modules';
import type { Row } from '../api';
import { searchAccounts, type AccountHit } from '../journal';
import {
  autoMatch, bankAccountSave, bankingSettingSet, bpBankSave, candidates, depositCreate, dirPath, matchLine, parseCsv, searchPartners, statementFormatSave, statementImport,
  toAmount, toIsoDate, unmatchLine, useCashPosition, useDepositSetup, useStatementActivity, useStatementFormats, useStatementInfo,
  type BpHit, type Candidate, type DateFormat, type JlSource, type StatementLine, type StatementRow,
} from '../banking';
import { BkHeader, Flash, FormError, todayIso, useDefaultCompany, useFlash } from './BankingPages';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const r2 = (n: number) => Math.round(n * 100) / 100;

function BankingTitle({ title, desc, actions, parent }: { title: string; desc?: string; actions?: ReactNode; parent?: [string, string] }) {
  const { t } = useTranslation();
  const m = moduleByKey('banking')!;
  return (
    <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/banking'], ...(parent ? [parent] : []), [title, undefined]]}
      title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
  );
}
function NewLink({ to, id, label }: { to: string; id: string; label: string }) {
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  if (!canWrite) return <Button variant="primary" disabled id={id} disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {label}</Button>;
  return <Link to={to} id={id} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover"><Plus className="h-4 w-4" aria-hidden /> {label}</Link>;
}
/** Needs one company (not "all companies"). */
function NeedCompany() {
  const { t } = useTranslation();
  return <div className="card"><EmptyState title={t('bk.pickCompany')} body={t('bk.pickCompanyBody')} /></div>;
}
function sourceLink(s: JlSource | null | undefined, company: string) {
  if (!s) return null;
  if (s.kind === 'payment' && s.direction) return <Link className="font-mono text-[13px] text-primary hover:underline" to={`/banking/payments/${dirPath(s.direction)}/${company}/${s.doc_entry}`}>{s.doc_no}</Link>;
  if (s.kind === 'deposit') return <span className="font-mono text-[13px]">{s.doc_no}</span>;
  return null;
}

// ---------- Deposits ----------
export function DepositsPage() {
  const { t } = useTranslation();
  const [flash] = useFlash();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'deposit_list', table: 'deposit_list',
    select: 'company_code,deposit_id,doc_no,deposit_date,bank_code,bank_name,cheques,cheque_total,cash_amount,total,memo,trans_id',
    searchCols: ['doc_no', 'memo', 'bank_name'], numberSearchCols: ['deposit_id'], searchLabel: t('bk.searchDeposits'),
    defaultSort: { col: 'deposit_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.deposit_id}`,
    rowLink: (r) => `/financials/journals/${r.company_code}/${r.trans_id}`,
    emptyTitle: t('bk.depositsEmpty'), emptyBody: t('bk.depositsEmptyBody'),
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'deposit_date', header: t('erp.col.date'), cell: (r) => fmtDay(r.deposit_date), csv: (r) => r.deposit_date },
      { key: 'bank_name', header: t('bk.bankAccount'), cell: (r) => `${r.bank_code} · ${r.bank_name ?? ''}` },
      { key: 'cheques', header: t('bk.cheques'), align: 'end', hideBelow: 'md', cell: (r) => `${r.cheques} · ${fmtMoney(r.cheque_total)}` },
      { key: 'cash_amount', header: t('erp.means.cash'), align: 'end', hideBelow: 'md', cell: (r) => fmtMoney(r.cash_amount) },
      { key: 'total', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total) },
    ],
  }), [t]);
  return (
    <RequireModule module="banking">
      <BankingTitle title={t('bk.deposits')} desc={t('bk.depositsDesc')} actions={<NewLink to="/banking/deposits/new" id="new-deposit" label={t('bk.newDeposit')} />} />
      <Flash text={flash} />
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

export function DepositNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const company = useDefaultCompany();
  const s = useDepositSetup(company || null);
  const [date, setDate] = useState(todayIso());
  const [bank, setBank] = useState('');
  const [cash, setCash] = useState('');
  const [memo, setMemo] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [sel, setSel] = useState<Record<number, boolean>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const cur = s.data?.currency ?? '';
  const cheques = s.data?.cheques ?? [];
  const chosen = cheques.filter((c) => sel[c.cheque_id]);
  const total = r2(chosen.reduce((x, c) => x + Number(c.amount), 0) + (Number(cash) || 0));
  const bankCode = bank || (s.data?.banks.length === 1 ? s.data.banks[0].bank_code : '');
  async function go() {
    setErr(null); setBusy(true);
    try {
      const r = await depositCreate(company, { deposit_date: date, bank_code: bankCode, cash_amount: cash, memo }, chosen.map((c) => c.cheque_id), series);
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['dep-setup'] });
      nav('/banking/deposits', { state: { flash: t('bk.flash.deposited', { no: r.doc_no, amount: fmtMoney(r.total, cur) }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const why = !canWrite ? readOnlyReason : total <= 0 ? t('bk.depositEmpty') : undefined;
  return (
    <RequireModule module="banking">
      <BkHeader title={t('bk.newDeposit')} back={[t('bk.deposits'), '/banking/deposits']} pills={<span className="pill pill-info">Southfield</span>} sub={t('bk.depositSub')} />
      {company === '' ? <NeedCompany /> : s.isLoading ? <PageLoading /> : s.error ? <div className="card"><ErrorState error={s.error} onRetry={() => s.refetch()} /></div> : (
        <>
          <FormError message={err} />
          <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
            <div className="min-w-0 space-y-5">
              <SectionCard title={t('erp.section.header')}>
                <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-3">
                  <label className="block text-xs font-medium text-muted">{t('bk.depositDate')} <span className="text-crit-fg">*</span>
                    <input id="dep-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('bk.depositInto')} <span className="text-crit-fg">*</span>
                    <select id="dep-bank" className="input mt-1 text-[15px] text-ink" value={bankCode} onChange={(e) => setBank(e.target.value)}>
                      <option value="">{t('bk.chooseBank')}</option>
                      {s.data!.banks.map((b) => <option key={b.bank_code} value={b.bank_code}>{b.bank_code} · {b.name}</option>)}
                    </select>
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}
                    <input id="dep-memo" dir="auto" className="input mt-1 text-[15px] text-ink" value={memo} onChange={(e) => setMemo(e.target.value)} />
                  </label>
                  <SeriesPicker company={company} obj={25} value={series} onChange={setSeries} date={date} />
                </div>
              </SectionCard>
              <SectionCard title={t('bk.chequesOnHand')}>
                {cheques.length === 0 ? <p className="p-5 text-sm text-muted">{t('bk.noChequesOnHand')}</p> : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-[14px] sm:min-w-[560px]" data-testid="dep-cheques">
                      <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                        <th scope="col" className="w-12 px-4 py-2.5"><span className="sr-only">{t('bk.choose')}</span></th>
                        <th scope="col" className="px-4 py-2.5 text-start">{t('bk.chequeCol')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.dueDate')}</th>
                        <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('erp.col.customer')}</th>
                        <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.amount')}</th>
                      </tr></thead>
                      <tbody>
                        {cheques.map((c) => {
                          const pdc = c.due_date > date;
                          return (
                            <tr key={c.cheque_id} data-testid="dep-cheque" className={clsx('border-t border-line', pdc && 'bg-warn-bg/40')}>
                              <td className="px-4 py-2.5"><input type="checkbox" id={`dep-chq-${c.cheque_id}`} aria-label={c.cheque_no} className="h-5 w-5" checked={Boolean(sel[c.cheque_id])} onChange={(e) => setSel((x) => ({ ...x, [c.cheque_id]: e.target.checked }))} /></td>
                              <td className="px-4 py-2.5"><span className="font-mono text-[13px]">{c.cheque_no}</span><div className="text-xs text-muted">{c.bank_name} · {c.doc_no}</div></td>
                              <td className="num px-4 py-2.5">{fmtDay(c.due_date)} {pdc && <span className="pill pill-warning">{t('bk.pdc')}</span>}</td>
                              <td className="px-4 py-2.5 max-md:hidden">{c.card_code} · {c.card_name}</td>
                              <td className="num px-4 py-2.5 text-end">{fmtMoney(c.amount)}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </SectionCard>
              <SectionCard title={t('erp.means.cash')}>
                <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
                  <label className="block text-xs font-medium text-muted">{t('bk.cashToDeposit')}
                    <input id="dep-cash" inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={cash} onChange={(e) => setCash(e.target.value)} placeholder="0.00" />
                  </label>
                  <p className="self-end pb-3 text-sm text-muted" data-testid="dep-cash-on-hand">{s.data!.cash_on_hand != null ? t('bk.cashOnHand', { amount: fmtMoney(s.data!.cash_on_hand, cur) }) : t('bk.noCashAccount')}</p>
                </div>
              </SectionCard>
            </div>
            <aside className="min-w-0 space-y-5">
              <SectionCard title={t('bk.depositTotal')}>
                <div className="space-y-3 p-5">
                  <p className="num text-[26px] font-semibold" data-testid="dep-total">{fmtMoney(total, cur)}</p>
                  <p className="text-sm text-muted">{t('bk.depositPosting')}</p>
                  <Button variant="primary" id="dep-submit" className="w-full" disabled={Boolean(why) || busy} disabledReason={why} onClick={go}>{busy ? t('je.posting') : t('bk.postDeposit')}</Button>
                </div>
              </SectionCard>
            </aside>
          </div>
        </>
      )}
    </RequireModule>
  );
}

// ---------- Bank statements ----------
export function StatementsPage() {
  const { t } = useTranslation();
  const [flash] = useFlash();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'bank_statement_list', table: 'bank_statement_list',
    select: 'company_code,statement_id,bank_code,bank_name,file_name,from_date,to_date,lines,matched,imported_at',
    searchCols: ['file_name', 'bank_name'], numberSearchCols: ['statement_id'], searchLabel: t('bk.searchStatements'),
    defaultSort: { col: 'imported_at', asc: false },
    rowKey: (r) => `${r.company_code}|${r.statement_id}`,
    rowLink: (r) => `/banking/statements/${r.company_code}/${r.statement_id}`,
    emptyTitle: t('bk.statementsEmpty'), emptyBody: t('bk.statementsEmptyBody'),
    columns: [
      { key: 'statement_id', header: t('bk.col.statement'), mono: true },
      { key: 'bank_name', header: t('bk.bankAccount'), cell: (r) => `${r.bank_code} · ${r.bank_name ?? ''}` },
      { key: 'file_name', header: t('bk.file'), hideBelow: 'md' },
      { key: 'from_date', header: t('bk.period'), hideBelow: 'sm', cell: (r) => `${fmtDay(r.from_date)} – ${fmtDay(r.to_date)}` },
      { key: 'matched', header: t('bk.matched'), align: 'end', cell: (r) => <span className={clsx('pill', Number(r.matched) === Number(r.lines) ? 'pill-ok' : 'pill-warning')}>{r.matched} / {r.lines}</span>, csv: (r) => `${r.matched}/${r.lines}` },
    ],
  }), [t]);
  return (
    <RequireModule module="banking">
      <BankingTitle title={t('bk.statements')} desc={t('bk.statementsDesc')} />
      <Flash text={flash} />
      <ImportCard />
      <div className="mt-5"><ListScreen config={cfg} /></div>
    </RequireModule>
  );
}

const FORMATS: DateFormat[] = ['YYYY-MM-DD', 'DD/MM/YYYY', 'MM/DD/YYYY', 'DD-MM-YYYY', 'DD.MM.YYYY'];
function ImportCard() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const { company: top } = useCompany();
  const company = useDefaultCompany();
  const banks = useQuery({
    queryKey: ['bank-accounts', company], enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('bank_account').select('bank_code,name').eq('company_code', company).eq('kind', 'bank').eq('active', true).order('bank_code');
      if (error) throw new ApiError(error);
      return (data ?? []) as Array<{ bank_code: string; name: string }>;
    },
  });
  const [bank, setBank] = useState('');
  const [file, setFile] = useState<{ name: string; headers: string[]; rows: string[][] } | null>(null);
  const [map, setMap] = useState({ date: '', description: '', reference: '', amount: '', debit: '', credit: '' });
  const [mode, setMode] = useState<'amount' | 'split'>('amount');
  const [fmt, setFmt] = useState<DateFormat>('DD/MM/YYYY');
  const [dec, setDec] = useState<'.' | ','>('.');
  const [remember, setRemember] = useState(true);
  const [usedSaved, setUsedSaved] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const bankCode = bank || (banks.data?.length === 1 ? banks.data[0].bank_code : '');
  const formats = useStatementFormats(company);
  const saved = bankCode ? formats.data?.[bankCode] : undefined;
  // B3: a bank's saved column mapping is used when its columns are in the file.
  function applySaved(hs: string[]) {
    if (!saved) return false;
    const cols = [saved.date, saved.mode === 'amount' ? saved.amount : saved.debit, saved.mode === 'amount' ? null : saved.credit, saved.reference, saved.description].filter(Boolean) as string[];
    if (!cols.every((c) => hs.includes(c))) return false;
    setMap({ date: saved.date, description: saved.description ?? '', reference: saved.reference ?? '', amount: saved.amount ?? '', debit: saved.debit ?? '', credit: saved.credit ?? '' });
    setMode(saved.mode); setFmt(saved.date_format); setDec(saved.decimal_sep);
    return true;
  }
  useEffect(() => { if (file) setUsedSaved(applySaved(file.headers)); }, [saved, file?.name]); // eslint-disable-line react-hooks/exhaustive-deps
  const col = (h: string) => (file ? file.headers.indexOf(h) : -1);
  const guess = (hs: string[], ...words: string[]) => hs.find((h) => words.some((w) => h.toLowerCase().includes(w))) ?? '';

  async function onFile(f: File | undefined) {
    setErr(null); setResult(null);
    if (!f) { setFile(null); return; }
    const parsed = parseCsv(await f.text());
    if (!parsed.headers.length || !parsed.rows.length) { setErr(t('bk.csvEmpty')); setFile(null); return; }
    setFile({ name: f.name, ...parsed });
    const hs = parsed.headers;
    const debit = guess(hs, 'debit', 'withdraw', 'مدين');
    const credit = guess(hs, 'credit', 'deposit', 'دائن');
    setMap({ date: guess(hs, 'date', 'تاريخ'), description: guess(hs, 'desc', 'narr', 'details', 'بيان'), reference: guess(hs, 'ref', 'cheque', 'مرجع'),
      amount: guess(hs, 'amount', 'مبلغ'), debit, credit });
    setMode(!guess(hs, 'amount', 'مبلغ') && debit && credit ? 'split' : 'amount');
    const sample = parsed.rows[0]?.[hs.indexOf(guess(hs, 'date', 'تاريخ'))] ?? '';
    if (/^\d{4}-/.test(sample)) setFmt('YYYY-MM-DD');
    setUsedSaved(applySaved(hs));
  }
  const rows: StatementRow[] = (file?.rows ?? []).map((r) => {
    const cell = (h: string) => (h && col(h) >= 0 ? r[col(h)] ?? '' : '');
    let amount = toAmount(cell(map.amount), dec);
    if (mode === 'split') {
      const c = Number(toAmount(cell(map.credit), dec) || 0);
      const d = Number(toAmount(cell(map.debit), dec) || 0);
      amount = String(r2(c - Math.abs(d)));
    }
    return { date: toIsoDate(cell(map.date), fmt), description: cell(map.description).trim(), reference: cell(map.reference).trim(), amount };
  });
  async function go() {
    setErr(null); setResult(null); setBusy(true);
    try {
      const r = await statementImport(company, bankCode, file!.name, rows);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      if (remember) {
        try {
          await statementFormatSave(company, bankCode, { mode, date: map.date, amount: map.amount, debit: map.debit, credit: map.credit, reference: map.reference, description: map.description, date_format: fmt, decimal_sep: dec });
          qc.invalidateQueries({ queryKey: ['stmt-formats', company] });
        } catch { /* the import itself worked; the format is only a convenience */ }
      }
      if (r.statement_id) nav(`/banking/statements/${company}/${r.statement_id}`, { state: { flash: t('bk.flash.imported', { n: r.imported, skipped: r.skipped }) } });
      else setResult(t('bk.flash.nothingNew', { skipped: r.skipped }));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const sel = (id: string, label: string, value: string, onChange: (v: string) => void, optional = false) => (
    <label className="block text-xs font-medium text-muted">{label}
      <select id={id} className="input mt-1 text-[15px] text-ink" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">{optional ? t('bk.none') : t('bk.chooseColumn')}</option>
        {file?.headers.map((h) => <option key={h} value={h}>{h}</option>)}
      </select>
    </label>
  );
  const ready = file && bankCode && map.date && (mode === 'amount' ? map.amount : map.debit && map.credit);
  const why = !canWrite ? readOnlyReason : !ready ? t('bk.importNotReady') : undefined;
  if (top === 'GRP' && !company) return null;
  return (
    <SectionCard title={t('bk.importTitle')} right={<span className="text-sm text-muted max-sm:hidden">{t('bk.importHint')}</span>}>
      <div className="space-y-4 p-5">
        <FormError message={err} />
        {result && <p role="status" className="rounded-btn bg-info-bg px-4 py-3 text-sm text-info-fg" data-testid="bk-import-result">{result}</p>}
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <label className="block text-xs font-medium text-muted">{t('bk.bankAccount')} <span className="text-crit-fg">*</span>
            <select id="imp-bank" className="input mt-1 text-[15px] text-ink" value={bankCode} onChange={(e) => setBank(e.target.value)}>
              <option value="">{t('bk.chooseBank')}</option>
              {(banks.data ?? []).map((b) => <option key={b.bank_code} value={b.bank_code}>{b.bank_code} · {b.name}</option>)}
            </select>
          </label>
          <label className="block text-xs font-medium text-muted sm:col-span-2">{t('bk.csvFile')} <span className="text-crit-fg">*</span>
            <input id="imp-file" type="file" accept=".csv,text/csv,text/plain" className="input mt-1 py-2 text-[15px] text-ink" onChange={(e) => onFile(e.target.files?.[0])} />
          </label>
        </div>
        {file && (
          <>
            {usedSaved && <p className="rounded-btn bg-info-bg px-4 py-2 text-sm text-info-fg" data-testid="imp-saved">{t('bk.usingSaved', { bank: bankCode })}</p>}
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
              {sel('imp-date', t('bk.mapDate'), map.date, (v) => setMap((m) => ({ ...m, date: v })))}
              <label className="block text-xs font-medium text-muted">{t('bk.dateFormat')}
                <select id="imp-format" className="input mt-1 text-[15px] text-ink" value={fmt} onChange={(e) => setFmt(e.target.value as DateFormat)}>
                  {FORMATS.map((f) => <option key={f} value={f}>{f}</option>)}
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('bk.decimalSep')}
                <select id="imp-decimal" className="input mt-1 text-[15px] text-ink" value={dec} onChange={(e) => setDec(e.target.value as '.' | ',')}>
                  <option value=".">{t('bk.decimalDot')}</option><option value=",">{t('bk.decimalComma')}</option>
                </select>
              </label>
              {sel('imp-desc', t('bk.mapDescription'), map.description, (v) => setMap((m) => ({ ...m, description: v })), true)}
              {sel('imp-ref', t('bk.mapReference'), map.reference, (v) => setMap((m) => ({ ...m, reference: v })), true)}
              <fieldset className="sm:col-span-2 xl:col-span-4">
                <legend className="text-xs font-medium text-muted">{t('bk.amountColumns')}</legend>
                <div className="mt-1 flex flex-wrap gap-4 text-sm">
                  <label className="inline-flex min-h-[40px] items-center gap-2"><input type="radio" name="imp-mode" checked={mode === 'amount'} onChange={() => setMode('amount')} /> {t('bk.oneAmount')}</label>
                  <label className="inline-flex min-h-[40px] items-center gap-2"><input type="radio" name="imp-mode" id="imp-mode-split" checked={mode === 'split'} onChange={() => setMode('split')} /> {t('bk.debitCredit')}</label>
                </div>
              </fieldset>
              {mode === 'amount' ? sel('imp-amount', t('bk.mapAmount'), map.amount, (v) => setMap((m) => ({ ...m, amount: v })))
                : <>{sel('imp-debit', t('bk.mapDebit'), map.debit, (v) => setMap((m) => ({ ...m, debit: v })))}{sel('imp-credit', t('bk.mapCredit'), map.credit, (v) => setMap((m) => ({ ...m, credit: v })))}</>}
            </div>
            <div className="overflow-x-auto rounded-btn border border-line">
              <table className="w-full text-[13px]" data-testid="imp-preview">
                <caption className="px-3 py-2 text-start text-xs text-muted">{t('bk.preview', { n: rows.length, shown: Math.min(rows.length, 5) })}</caption>
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-3 py-2 text-start">{t('erp.col.date')}</th><th scope="col" className="px-3 py-2 text-start">{t('bk.description')}</th>
                  <th scope="col" className="px-3 py-2 text-start max-sm:hidden">{t('erp.col.ref')}</th><th scope="col" className="px-3 py-2 text-end">{t('erp.col.amount')}</th>
                </tr></thead>
                <tbody>{rows.slice(0, 5).map((r, i) => (
                  <tr key={i} className="border-t border-line">
                    <td className={clsx('num px-3 py-1.5', !/^\d{4}-\d{2}-\d{2}$/.test(r.date) && 'text-crit-fg')}>{r.date || '—'}</td>
                    <td dir="auto" className="px-3 py-1.5">{r.description}</td><td className="px-3 py-1.5 max-sm:hidden">{r.reference}</td>
                    <td className={clsx('num px-3 py-1.5 text-end', Number(r.amount) < 0 && 'text-crit-fg')}>{r.amount}</td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
          </>
        )}
        {file && canWrite && (
          <label className="inline-flex min-h-[40px] items-center gap-2 text-sm"><input type="checkbox" id="imp-remember" className="h-5 w-5" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
            {t('bk.rememberFormat', { bank: bankCode || '—' })}</label>
        )}
        <Button variant="primary" id="imp-submit" disabled={Boolean(why) || busy} disabledReason={why} onClick={go} icon={<Upload className="h-4 w-4" aria-hidden />}>{busy ? t('bk.importing') : t('bk.import')}</Button>
      </div>
    </SectionCard>
  );
}

export function StatementPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = useStatementInfo(company, Number(id));
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [only, setOnly] = useState(false);
  const [pick, setPick] = useState<StatementLine | null>(null);
  const { readOnlyReason } = useModuleLevel('banking');
  const back: [string, string] = [t('bk.statements'), '/banking/statements'];
  if (q.isLoading || q.error || !q.data) {
    return (
      <RequireModule module="banking">
        <BkHeader title={t('bk.statementN', { n: id })} back={back} />
        {q.isLoading ? <PageLoading /> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
          : <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>}
      </RequireModule>
    );
  }
  const s = q.data;
  const matched = s.lines.filter((l) => l.match).length;
  const refresh = (msg?: string) => { if (msg) setFlash(msg); qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['cash-position'] }); qc.invalidateQueries({ queryKey: ['stmt-activity'] }); q.refetch(); };
  async function runAuto() {
    setErr(null); setBusy(true);
    try { const r = await autoMatch(company, s.statement_id); refresh(t('bk.flash.autoMatched', { n: r.matched, left: r.unmatched })); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function unmatch(l: StatementLine) {
    setErr(null);
    try { await unmatchLine(company, l.line_id); refresh(t('bk.flash.unmatched')); } catch (e) { setErr(errorMessage(e)); }
  }
  const lines = only ? s.lines.filter((l) => !l.match) : s.lines;
  return (
    <RequireModule module="banking">
      <BkHeader title={t('bk.statementN', { n: s.statement_id })} back={back}
        pills={<><span className={clsx('pill', matched === s.lines.length ? 'pill-ok' : 'pill-warning')} data-testid="stmt-count">{t('bk.matchedOf', { n: matched, total: s.lines.length })}</span><LiveBadge live /></>}
        sub={[`${s.bank_code} · ${s.bank_name ?? ''}`, s.file_name, `${fmtDay(s.from_date)} – ${fmtDay(s.to_date)}`].filter(Boolean).join(' · ')}
        actions={<Button variant="primary" id="stmt-auto" disabled={!s.can_write || busy} disabledReason={!s.can_write ? readOnlyReason : undefined} onClick={runAuto} icon={<Wand2 className="h-4 w-4" aria-hidden />}>{t('bk.autoMatch')}</Button>} />
      <Flash text={flash} />
      <FormError message={err} />
      <SectionCard title={t('bk.lines')} right={
        <label className="inline-flex min-h-[40px] items-center gap-2 text-sm"><input type="checkbox" id="stmt-only" checked={only} onChange={(e) => setOnly(e.target.checked)} className="h-4 w-4" /> {t('bk.onlyUnmatched')}</label>}>
        <p className="border-b border-line px-5 py-2 text-xs text-muted" data-testid="stmt-rule">{t('bk.matchRuleRef', { n: s.match_days ?? 3 })}</p>
        {lines.length === 0 ? <EmptyState title={t('bk.allMatched')} body={t('bk.allMatchedBody')} /> : (
          <div className="overflow-x-auto">
            <table className="w-full text-[14px] sm:min-w-[720px]" data-testid="stmt-lines">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.date')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('bk.description')}</th>
                <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.amount')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('bk.match')}</th>
              </tr></thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.line_id} data-testid="stmt-line" className={clsx('border-t border-line align-top', !l.match && 'bg-warn-bg/30')}>
                    <td className="num px-4 py-2.5">{fmtDay(l.value_date)}</td>
                    <td className="px-4 py-2.5"><div dir="auto">{l.description ?? '—'}</div>{l.reference && <div className="font-mono text-xs text-muted">{l.reference}</div>}</td>
                    <td className={clsx('num px-4 py-2.5 text-end', l.amount < 0 && 'text-crit-fg')}>{fmtMoney(l.amount)}</td>
                    <td className="px-4 py-2.5">
                      {l.match ? (
                        <div className="flex flex-wrap items-start gap-2">
                          <div className="min-w-0">
                            <span className="pill pill-ok">{t(l.match.how === 'auto' ? 'bk.autoMatched' : 'bk.manualMatched')}</span>
                            <div className="mt-1 text-xs text-muted">{t('bk.matchNo', { n: l.match.match_no })} · <Link className="text-primary hover:underline" to={`/financials/journals/${company}/${l.match.trans_id}`}>{l.match.trans_id}</Link> {sourceLink(l.match.source, company)}</div>
                            <div dir="auto" className="text-xs text-muted">{l.match.memo}</div>
                          </div>
                          {s.can_write && <Button variant="ghost" className="min-h-[40px] px-2" onClick={() => unmatch(l)} icon={<Unlink className="h-4 w-4" aria-hidden />} aria-label={t('bk.unmatchLine', { n: l.line_no })}>{t('bk.unmatch')}</Button>}
                        </div>
                      ) : (
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="pill pill-warning">{t('bk.unmatched')}</span>
                          {s.can_write && <Button variant="secondary" className="min-h-[40px]" id={`stmt-match-${l.line_no}`} onClick={() => setPick(l)} icon={<Link2 className="h-4 w-4" aria-hidden />}>{t('bk.matchBtn')}</Button>}
                        </div>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>
      <StatementActivityCard company={company} id={s.statement_id} />
      {pick && <MatchDialog company={company} line={pick} currency={s.currency} onClose={() => setPick(null)} onDone={() => { setPick(null); refresh(t('bk.flash.matched')); }} />}
    </RequireModule>
  );
}

/** B3 · who matched, unmatched or auto-matched what (audit log). */
function StatementActivityCard({ company, id }: { company: string; id: number }) {
  const { t } = useTranslation();
  const a = useStatementActivity(company, id);
  if (!a.data?.length) return null;
  return (
    <SectionCard className="mt-5" title={t('bk.stmtActivity')}>
      <ul className="divide-y divide-line" data-testid="stmt-activity">
        {a.data.slice(0, 20).map((x, i) => (
          <li key={i} className="flex flex-wrap items-baseline justify-between gap-2 px-5 py-2.5 text-sm">
            <span><span className="font-medium">{t(`bk.act.${x.action}`, { defaultValue: x.action })}</span> · {x.actor_name}
              {x.detail && 'matched' in x.detail ? <span className="text-muted"> · {t('bk.act.counts', { n: x.detail.matched as number, left: x.detail.unmatched as number })}</span> : null}
              {x.detail && 'match_no' in x.detail ? <span className="text-muted"> · {t('bk.matchNo', { n: x.detail.match_no as number })}</span> : null}</span>
            <time className="num text-xs text-muted" dateTime={x.at}>{new Date(x.at).toLocaleString()}</time>
          </li>
        ))}
      </ul>
    </SectionCard>
  );
}

function MatchDialog({ company, line, currency, onClose, onDone }: { company: string; line: StatementLine; currency: string; onClose: () => void; onDone: () => void }) {
  const { t } = useTranslation();
  const c = useQuery({ queryKey: ['stmt-cand', company, line.line_id], queryFn: () => candidates(company, line.line_id) });
  const [err, setErr] = useState<string | null>(null);
  async function go(x: Candidate) {
    setErr(null);
    try { await matchLine(company, line.line_id, x.trans_id, x.line_id); onDone(); } catch (e) { setErr(errorMessage(e)); }
  }
  return (
    <Dialog open title={t('bk.matchTitle', { amount: fmtMoney(line.amount, currency), date: fmtDay(line.value_date) })} onClose={onClose}
      footer={<Button variant="secondary" onClick={onClose}>{t('so.dialog.close')}</Button>}>
      <p className="text-sm text-ink-2">{t('bk.matchBody')}</p>
      {err && <p role="alert" className="text-sm text-crit-fg" dir="auto">{err}</p>}
      {c.isLoading ? <p className="text-sm text-muted">{t('je.checking')}</p> : c.error ? <ErrorState error={c.error} /> : !c.data?.length ? <p className="text-sm text-muted" data-testid="cand-empty">{t('bk.noCandidates')}</p> : (
        <ul className="max-h-80 divide-y divide-line overflow-auto rounded-btn border border-line" data-testid="cand-list">
          {c.data.map((x) => (
            <li key={`${x.trans_id}-${x.line_id}`} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
              <div className="min-w-0">
                <div><span className="font-mono text-[13px]">{x.trans_id}</span> · {fmtDay(x.ref_date)} {x.source?.doc_no && <span className="font-mono text-[13px] text-muted">· {x.source.doc_no}</span>}
                  {x.ref_match && <span className="pill pill-ok ms-2" data-testid="cand-ref-match">{t('bk.refFits')}</span>}</div>
                <div dir="auto" className="truncate text-xs text-muted">{x.memo}</div>
              </div>
              <Button variant="secondary" className="min-h-[40px] shrink-0" onClick={() => go(x)}>{t('bk.matchThis')}</Button>
            </li>
          ))}
        </ul>
      )}
    </Dialog>
  );
}

// ---------- Banking Reports › cash position ----------
export function CashPositionPage() {
  const { t } = useTranslation();
  const { company: top } = useCompany();
  const q = useCashPosition(top !== 'GRP' ? top : null);
  const d = q.data;
  return (
    <RequireModule module="banking">
      <BankingTitle title={t('bk.cashPosition')} desc={t('bk.cashPositionDesc')} />
      {top === 'GRP' ? <NeedCompany /> : q.isLoading ? <PageLoading /> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : d && (
        <div className="space-y-5">
          <div className="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-4">
            <Kpi label={t('bk.kpiCash')} value={<span data-testid="cp-total">{fmtMoney(d.total, d.currency)}</span>} sub={t('bk.kpiCashSub', { n: d.accounts.length })} />
            <Kpi label={t('bk.kpiCheques')} value={fmtMoney(d.cheques.amount, d.currency)} to="/banking/deposits/new"
              sub={t('bk.kpiChequesSub', { n: d.cheques.count, pdc: d.cheques.post_dated_count, pdcAmount: fmtMoney(d.cheques.post_dated_amount) })} />
            <Kpi label={t('bk.kpiPending')} value={fmtMoney(d.pending_out.amount, d.currency)} to="/banking/payment-drafts?f_state=pending_approval" tone={d.pending_out.count ? 'warn' : undefined}
              sub={t('bk.kpiPendingSub', { n: d.pending_out.count })} />
            <Kpi label={t('bk.kpiUnmatched')} value={String(d.accounts.reduce((s, a) => s + Number(a.unmatched), 0))} to="/banking/statements"
              tone={d.accounts.some((a) => a.unmatched > 0) ? 'warn' : undefined} sub={t('bk.kpiUnmatchedSub')} />
          </div>
          <SectionCard title={t('bk.accounts')} right={<span className="text-sm text-muted">{t('bk.asOf', { when: fmtDay(d.as_of) })}</span>}>
            {d.accounts.length === 0 ? <EmptyState title={t('bk.noAccounts')} body={t('bk.noAccountsBody')} /> : (
              <div className="overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="cp-accounts">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('bk.bankAccount')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('erp.col.account')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('bk.lastStatement')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('bk.unmatched')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.balance')}</th>
                  </tr></thead>
                  <tbody>
                    {d.accounts.map((a) => (
                      <tr key={a.bank_code} className="border-t border-line">
                        <td className="px-4 py-2.5"><div className="font-medium">{a.name}</div><div className="font-mono text-xs text-muted">{a.bank_code}{a.iban ? ` · ${a.iban}` : ''}</div></td>
                        <td className="px-4 py-2.5 font-mono text-[13px] max-md:hidden">{a.acct_code}</td>
                        <td className="num px-4 py-2.5 max-sm:hidden">{a.kind === 'cash' ? '—' : fmtDay(a.last_statement)}</td>
                        <td className="num px-4 py-2.5 text-end max-sm:hidden">{a.kind === 'cash' ? '—' : a.unmatched > 0 ? <span className="pill pill-warning">{a.unmatched}</span> : '0'}</td>
                        <td className={clsx('num px-4 py-2.5 text-end font-semibold', a.balance < 0 && 'text-crit-fg')}>{fmtMoney(a.balance, a.currency)}</td>
                      </tr>
                    ))}
                    <tr className="border-t border-line-strong font-semibold"><td className="px-4 py-2.5" colSpan={1}>{t('erp.col.total')}</td><td className="max-md:hidden" /><td className="max-sm:hidden" /><td className="max-sm:hidden" /><td className="num px-4 py-2.5 text-end">{fmtMoney(d.total, d.currency)}</td></tr>
                  </tbody>
                </table>
              </div>
            )}
          </SectionCard>
          <SectionCard title={t('bk.notInBank')}>
            <Fields items={[
              [t('bk.chequesOnHand'), `${fmtMoney(d.cheque_acct?.balance ?? d.cheques.amount, d.currency)} · ${t('bk.chequesCount', { n: d.cheques.count })}`],
              [t('bk.chequesDue'), fmtMoney(d.cheques.due_amount, d.currency)],
              [t('bk.chequesPdc'), fmtMoney(d.cheques.post_dated_amount, d.currency)],
              [t('bk.cardReceipts'), d.card_acct ? fmtMoney(d.card_acct.balance, d.currency) : '—'],
            ]} />
          </SectionCard>
          <p className="text-sm text-muted">{t('bk.cashNote')}</p>
        </div>
      )}
    </RequireModule>
  );
}

// ---------- BP bank accounts ----------
export function BpBankAccountsPage() {
  const { t } = useTranslation();
  const [flash, setFlash] = useFlash();
  const [edit, setEdit] = useState<R | null | undefined>(undefined);
  const days = useQuery({
    queryKey: ['bank-change-days'],
    queryFn: async () => {
      const { data } = await erp().from('approval_rule').select('limit_value').eq('rule_code', 'bank_change').eq('active', true).limit(1);
      return (data?.[0] as { limit_value?: number } | undefined)?.limit_value ?? null;
    },
  });
  const recent = (iso: string | null) => Boolean(iso && days.data && Date.now() - new Date(iso).getTime() < Number(days.data) * 86400000);
  const { canWrite } = useModuleLevel('banking');
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'bp_bank_account_list', table: 'bp_bank_account_list',
    select: 'company_code,bp_bank_id,card_code,card_name,kind,bank_name,account_no,iban,swift,holder,active,source,updated_at,last_change_at',
    searchCols: ['card_code', 'card_name', 'bank_name', 'iban', 'account_no'], searchLabel: t('bk.searchBpBank'),
    filters: [{ key: 'kind', label: t('erp.col.type'), options: [['supplier', t('erp.kind.supplier')], ['customer', t('erp.kind.customer')]] }],
    defaultSort: { col: 'updated_at', asc: false },
    rowKey: (r) => String(r.bp_bank_id),
    emptyTitle: t('bk.bpBankEmpty'), emptyBody: t('bk.bpBankEmptyBody'),
    columns: [
      { key: 'card_code', header: t('erp.col.code'), mono: true },
      { key: 'card_name', header: t('erp.col.name') },
      { key: 'bank_name', header: t('bk.bank'), cell: (r) => <span>{r.bank_name}<div className="font-mono text-xs text-muted">{r.iban ?? r.account_no}</div></span> },
      { key: 'last_change_at', header: t('bk.lastChange'), hideBelow: 'md',
        cell: (r) => r.last_change_at ? <span>{fmtDay(r.last_change_at)} {recent(r.last_change_at) && <span className="pill pill-warning">{t('bk.changedRecently')}</span>}</span> : '—' },
      { key: 'active', header: t('erp.col.status'), cell: (r) => <span className={clsx('pill', r.active ? 'pill-ok' : 'pill-neutral')}>{r.active ? t('erp.status.active') : t('erp.status.inactive')}</span>, csv: (r) => (r.active ? 'active' : 'inactive') },
      { key: 'edit', header: '', sortable: false,
        cell: (r) => canWrite && r.source !== 'sap' ? <button type="button" className="min-h-[40px] px-2 text-sm font-medium text-primary hover:underline" onClick={(e) => { e.stopPropagation(); setEdit(r); }}>{t('bk.change')}</button> : null },
    ],
  }), [t, days.data, canWrite]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <RequireModule module="banking">
      <BankingTitle title={t('bk.bpBank')} desc={t('bk.bpBankDesc', { n: days.data ?? '—' })}
        actions={<Button variant="primary" id="bpb-new" disabled={!canWrite} onClick={() => setEdit(null)}><Plus className="h-4 w-4" aria-hidden /> {t('bk.addBpBank')}</Button>} />
      <Flash text={flash} />
      {edit !== undefined && <BpBankForm row={edit} onClose={() => setEdit(undefined)} onDone={(m) => { setEdit(undefined); setFlash(m); }} />}
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

function BpBankForm({ row, onClose, onDone }: { row: R | null; onClose: () => void; onDone: (msg: string) => void }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const def = useDefaultCompany();
  const company: string = row?.company_code ?? def;
  const [card, setCard] = useState<string>(row?.card_code ?? '');
  const [text, setText] = useState(row ? `${row.card_code} · ${row.card_name}` : '');
  const [f, setF] = useState({ bank_name: row?.bank_name ?? '', account_no: row?.account_no ?? '', iban: row?.iban ?? '', swift: row?.swift ?? '', holder: row?.holder ?? '', active: row?.active ?? true });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const opts = async (q: string): Promise<Array<ComboOption<BpHit>>> => (await searchPartners(company, null, q)).map((b) => ({ value: b.card_code, label: `${b.card_code} · ${b.name}`, data: b, meta: t(`erp.kind.${b.kind}`) }));
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await bpBankSave(company, card, { ...(row ? { bp_bank_id: row.bp_bank_id } : {}), ...f });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      // A8: when an approval rule covers the user, the change waits for approval instead of applying at once
      onDone(r.state === 'pending_approval' ? t('md.bank.pending', { code: card }) : t('bk.flash.bpBank', { code: card, change: t(`bk.change_${r.change}`) }));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const input = (k: keyof typeof f, label: string, mono = false) => (
    <label className="block text-xs font-medium text-muted">{label}
      <input id={`bpb-${k}`} dir="auto" className={clsx('input mt-1 text-[15px] text-ink', mono && 'font-mono')} value={String(f[k])} onChange={(e) => setF((x) => ({ ...x, [k]: e.target.value }))} />
    </label>
  );
  return (
    <SectionCard className="mb-5" title={row ? t('bk.changeBpBank', { code: row.card_code }) : t('bk.addBpBank')}>
      <div className="space-y-4 p-5">
        <FormError message={err} />
        <p className="rounded-btn border border-warn-fg/30 bg-warn-bg p-3 text-sm text-warn-fg">{t('bk.bpBankWarning')}</p>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {row ? <div><p className="text-xs font-medium text-muted">{t('bk.partner')}</p><p className="mt-2 text-[15px]">{text}</p></div>
            : <Combobox<BpHit> id="bpb-bp" label={t('bk.partner')} required text={text} onText={(s) => { setText(s); setCard(''); }} search={opts} onSelect={(o) => { setText(o.label); setCard(o.value); }} />}
          {input('bank_name', t('bk.bank'))}
          {input('holder', t('bk.holder'))}
          {input('iban', 'IBAN', true)}
          {input('account_no', t('bk.accountNo'), true)}
          {input('swift', 'SWIFT / BIC', true)}
          {row && <label className="inline-flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" id="bpb-active" checked={f.active} onChange={(e) => setF((x) => ({ ...x, active: e.target.checked }))} className="h-4 w-4" /> {t('erp.status.active')}</label>}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="primary" id="bpb-save" disabled={busy || !card} onClick={save}>{t('bk.saveBpBank')}</Button>
          <Button variant="secondary" onClick={onClose}>{t('je.cancelEdit')}</Button>
        </div>
      </div>
    </SectionCard>
  );
}

// ---------- Banking setup ----------
export function BankingSetupPage() {
  const { t } = useTranslation();
  const { company: top } = useCompany();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const company = top !== 'GRP' ? top : '';
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const q = useQuery({
    queryKey: ['bk-setup', company], enabled: Boolean(company),
    queryFn: async () => {
      const [a, s] = await Promise.all([
        erp().from('bank_account').select('*').eq('company_code', company).order('kind').order('bank_code'),
        erp().from('banking_setting').select('*').eq('company_code', company).maybeSingle(),
      ]);
      if (a.error) throw new ApiError(a.error);
      if (s.error) throw new ApiError(s.error);
      return { accounts: (a.data ?? []) as R[], setting: (s.data ?? null) as R | null };
    },
  });
  const [edit, setEdit] = useState<R | null | undefined>(undefined);
  const done = (m: string) => { setFlash(m); setEdit(undefined); qc.invalidateQueries({ queryKey: ['bk-setup'] }); qc.invalidateQueries({ queryKey: ['pay-setup'] }); };
  return (
    <RequireModule module="banking">
      <BankingTitle title={t('bk.setup')} desc={t('bk.setupDesc')} />
      <Flash text={flash} />
      {!company ? <NeedCompany /> : q.isLoading ? <PageLoading /> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="space-y-5">
          <SectionCard title={t('bk.houseAccounts')} right={<Button variant="secondary" id="ba-new" disabled={!canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={() => setEdit(null)}><Plus className="h-4 w-4" aria-hidden /> {t('bk.addAccount')}</Button>}>
            {edit !== undefined && <BankAccountForm company={company} row={edit} onClose={() => setEdit(undefined)} onDone={done} />}
            {q.data!.accounts.length === 0 ? <EmptyState title={t('bk.noAccounts')} body={t('bk.noAccountsBody')} /> : (
              <div className="overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="ba-list">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.code')}</th><th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.name')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('erp.col.account')}</th><th scope="col" className="px-4 py-2.5 text-start max-md:hidden">IBAN</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th><th scope="col" className="px-4 py-2.5"><span className="sr-only">{t('bk.change')}</span></th>
                  </tr></thead>
                  <tbody>{q.data!.accounts.map((a) => (
                    <tr key={a.bank_code} className="border-t border-line">
                      <td className="px-4 py-2.5 font-mono text-[13px]">{a.bank_code}</td>
                      <td className="px-4 py-2.5">{a.name}<div className="text-xs text-muted">{t(`bk.kind.${a.kind}`)}{a.bank_name ? ` · ${a.bank_name}` : ''}{a.source === 'sample' ? ` · ${t('erp.sampleData')}` : ''}</div></td>
                      <td className="px-4 py-2.5 font-mono text-[13px] max-sm:hidden">{a.acct_code}</td>
                      <td className="px-4 py-2.5 font-mono text-[13px] max-md:hidden">{a.iban ?? '—'}</td>
                      <td className="px-4 py-2.5"><span className={clsx('pill', a.active ? 'pill-ok' : 'pill-neutral')}>{a.active ? t('erp.status.active') : t('erp.status.inactive')}</span></td>
                      <td className="px-4 py-2.5 text-end">{canWrite && a.source !== 'sap' && <button type="button" className="min-h-[40px] px-2 text-sm font-medium text-primary hover:underline" onClick={() => setEdit(a)}>{t('bk.change')}</button>}</td>
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            )}
          </SectionCard>
          <SettingsForm company={company} s={q.data!.setting} onDone={done} />
        </div>
      )}
    </RequireModule>
  );
}

function AcctPicker({ id, label, company, value, onChange }: { id: string; label: string; company: string; value: string; onChange: (v: string) => void }) {
  const { t } = useTranslation();
  const [text, setText] = useState(value);
  const opts = async (q: string): Promise<Array<ComboOption<AccountHit>>> => (await searchAccounts(company, q)).filter((a) => !a.is_control)
    .map((a) => ({ value: a.acct_code, label: `${a.acct_code} · ${a.name}`, data: a }));
  return <Combobox<AccountHit> id={id} label={label} text={text} onText={(s) => { setText(s); if (!s.trim()) onChange(''); }} search={opts} placeholder={t('je.accountPh')} noMatch={t('je.noAccount')}
    onSelect={(o) => { setText(o.label); onChange(o.value); }} />;
}

function BankAccountForm({ company, row, onClose, onDone }: { company: string; row: R | null; onClose: () => void; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const [f, setF] = useState({ bank_code: row?.bank_code ?? '', name: row?.name ?? '', kind: row?.kind ?? 'bank', acct_code: row?.acct_code ?? '', bank_name: row?.bank_name ?? '',
    account_no: row?.account_no ?? '', iban: row?.iban ?? '', swift: row?.swift ?? '', currency: row?.currency ?? '', active: row?.active ?? true });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function save() {
    setErr(null); setBusy(true);
    try { const r = await bankAccountSave(company, f); onDone(t('bk.flash.accountSaved', { code: String(r.bank_code) })); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const input = (k: keyof typeof f, label: string, mono = false, disabled = false) => (
    <label className="block text-xs font-medium text-muted">{label}
      <input id={`ba-${k}`} dir="auto" disabled={disabled} className={clsx('input mt-1 text-[15px] text-ink', mono && 'font-mono')} value={String(f[k])} onChange={(e) => setF((x) => ({ ...x, [k]: e.target.value }))} />
    </label>
  );
  return (
    <div className="space-y-4 border-b border-line p-5" data-testid="ba-form">
      <FormError message={err} />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {input('bank_code', t('erp.col.code'), true, Boolean(row))}
        {input('name', t('erp.col.name'))}
        <label className="block text-xs font-medium text-muted">{t('erp.col.type')}
          <select id="ba-kind" className="input mt-1 text-[15px] text-ink" value={f.kind} onChange={(e) => setF((x) => ({ ...x, kind: e.target.value }))}>
            <option value="bank">{t('bk.kind.bank')}</option><option value="cash">{t('bk.kind.cash')}</option>
          </select>
        </label>
        <AcctPicker id="ba-acct" label={t('bk.glAccount')} company={company} value={f.acct_code} onChange={(v) => setF((x) => ({ ...x, acct_code: v }))} />
        {input('bank_name', t('bk.bank'))}
        {input('iban', 'IBAN', true)}
        {input('account_no', t('bk.accountNo'), true)}
        {input('swift', 'SWIFT / BIC', true)}
        {input('currency', t('erp.col.currency'), true)}
        {row && <label className="inline-flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" checked={f.active} onChange={(e) => setF((x) => ({ ...x, active: e.target.checked }))} className="h-4 w-4" /> {t('erp.status.active')}</label>}
      </div>
      <div className="flex flex-wrap gap-2">
        <Button variant="primary" id="ba-save" disabled={busy} onClick={save}>{t('bk.saveAccount')}</Button>
        <Button variant="secondary" onClick={onClose}>{t('je.cancelEdit')}</Button>
      </div>
    </div>
  );
}

function SettingsForm({ company, s, onDone }: { company: string; s: R | null; onDone: (m: string) => void }) {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const [f, setF] = useState({ cash_acct: s?.cash_acct ?? '', cheque_acct: s?.cheque_acct ?? '', card_acct: s?.card_acct ?? '', match_days: s?.match_days != null ? String(s.match_days) : '' });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function save() {
    setErr(null); setBusy(true);
    try { await bankingSettingSet(company, f); onDone(t('bk.flash.settingsSaved')); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <SectionCard title={t('bk.settings')}>
      <div className="space-y-4 p-5">
        <FormError message={err} />
        {!s && <p className="flex items-start gap-2 rounded-btn border border-warn-fg/30 bg-warn-bg p-3 text-sm text-warn-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{t('bk.settingsEmpty')}</p>}
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <AcctPicker id="bs-cash" label={t('bk.cashAcct')} company={company} value={f.cash_acct} onChange={(v) => setF((x) => ({ ...x, cash_acct: v }))} />
          <AcctPicker id="bs-cheque" label={t('bk.chequeAcct')} company={company} value={f.cheque_acct} onChange={(v) => setF((x) => ({ ...x, cheque_acct: v }))} />
          <AcctPicker id="bs-card" label={t('bk.cardAcct')} company={company} value={f.card_acct} onChange={(v) => setF((x) => ({ ...x, card_acct: v }))} />
          <label className="block text-xs font-medium text-muted">{t('bk.matchDays')}
            <input id="bs-days" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" value={f.match_days} onChange={(e) => setF((x) => ({ ...x, match_days: e.target.value }))} />
            <span className="mt-1 block text-muted">{t('bk.matchDaysHelp')}</span>
          </label>
        </div>
        <Button variant="primary" id="bs-save" disabled={!canWrite || busy} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={save}>{t('bk.saveSettings')}</Button>
      </div>
    </SectionCard>
  );
}

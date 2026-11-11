import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { CalendarX, Pencil, Plus, Save, X } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard, fmtDay } from '../components/ui';
import { Dialog } from '../components/Dialog';
import { substituteEnd, substituteSave, useSubstitutes, type SubStatus, type Substitution } from '../approvals';
import { AdminFrame, AuditCard, CompanyPicker, ErrorBox, Flash, useAdminCompany } from './AdminPages';
import { ProcessTabs } from './ApprovalProcessPages';

/**
 * B5 · Substitute Authorizer (Administration › Approval Process, SAP B1 "Substitute Authorizer for Approval Templates").
 * mode 'admin': every substitution of the company (Administration full may change anyone's).
 * mode 'mine': the signed-in authorizer's own substitution (opened from the Approvals inbox).
 * The database checks every rule (supabase/sql/34_open_items.sql).
 */
interface SubForm { sub_id: number | null; user_id: string; substitute_id: string; from_date: string; to_date: string; note: string }

const today = () => new Date().toISOString().slice(0, 10);
const plusDays = (d: string, n: number) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };

export function SubStatusPill({ status }: { status: SubStatus }) {
  const { t } = useTranslation();
  const cls = status === 'active' ? 'pill-ok' : status === 'planned' ? 'pill-info' : 'pill-neutral';
  return <span className={clsx('pill', cls)} data-testid="sub-status">{t(`apr.sub.status.${status}`)}</span>;
}

export function SubstitutesPage({ mode }: { mode: 'admin' | 'mine' }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useAdminCompany();
  const { company } = sc;
  const q = useSubstitutes(company);
  const L = q.data;
  const [form, setForm] = useState<SubForm | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [endFor, setEndFor] = useState<Substitution | null>(null);
  const admin = mode === 'admin' && Boolean(L?.can_admin);
  const rows = (L?.rows ?? []).filter((r) => mode === 'admin' || r.user_id === L?.me.user_id || r.substitute_id === L?.me.user_id);
  const authorizers = (L?.users ?? []).filter((u) => u.stages.length > 0);
  const canAdd = admin || Boolean(L?.me.stages.length);

  const start = (r?: Substitution) => {
    setErr(null); setFlash(null);
    setForm(r ? { sub_id: r.sub_id, user_id: r.user_id, substitute_id: r.substitute_id, from_date: r.from_date, to_date: r.to_date, note: r.note ?? '' }
      : { sub_id: null, user_id: admin ? '' : L?.me.user_id ?? '', substitute_id: '', from_date: today(), to_date: plusDays(today(), 7), note: '' });
  };
  async function save() {
    if (!form) return;
    setErr(null); setFlash(null); setBusy(true);
    try {
      const r = await substituteSave(company, { ...form, user_id: form.user_id || null, note: form.note || null });
      setFlash(t(form.sub_id ? 'apr.sub.changed' : 'apr.sub.added', { status: t(`apr.sub.status.${r.status}`) }));
      setForm(null);
      await qc.invalidateQueries({ queryKey: ['apr-subs', company] });
      await qc.invalidateQueries({ queryKey: ['approval-inbox'] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function end() {
    if (!endFor) return;
    setErr(null); setFlash(null); setBusy(true);
    try {
      await substituteEnd(company, endFor.sub_id);
      setFlash(t('apr.sub.ended', { name: endFor.substitute_name }));
      await qc.invalidateQueries({ queryKey: ['apr-subs', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); setEndFor(null); }
  }

  const title = mode === 'admin' ? t('apr.sub.title') : t('apr.sub.mineTitle');
  const desc = mode === 'admin' ? t('apr.sub.desc') : t('apr.sub.mineDesc');
  const actions = (
    <div className="flex flex-wrap items-end gap-2">
      <CompanyPicker {...sc} />
      {canAdd && <Button variant="primary" id="sub-new" onClick={() => start()} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('apr.sub.new')}</Button>}
    </div>
  );
  const body = (
    <>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <p className="mb-4 rounded-btn border border-info-fg/20 bg-info-bg px-4 py-3 text-sm text-info-fg" data-testid="sub-rule">{t('apr.sub.rule')}</p>
      {L && mode === 'mine' && L.me.stages.length === 0 && <p className="mb-4 text-sm text-muted" data-testid="sub-not-authorizer">{t('apr.sub.notAuthorizer')}</p>}
      {form && L && (
        <SectionCard title={form.sub_id ? t('apr.sub.editTitle') : t('apr.sub.new')} className="mb-5">
          <div className="space-y-4 p-5" data-testid="sub-form">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <label className="block text-xs font-medium text-muted">{t('apr.sub.authorizer')}
                {admin && !form.sub_id ? (
                  <select id="sub-user" className="input mt-1 text-[15px] text-ink" value={form.user_id} onChange={(e) => setForm({ ...form, user_id: e.target.value })}>
                    <option value="">{t('adm.choose')}</option>
                    {authorizers.map((u) => <option key={u.user_id} value={u.user_id}>{u.display_name}</option>)}
                  </select>
                ) : (
                  <span className="input mt-1 flex items-center bg-surface-2 text-[15px] text-ink" id="sub-user-fixed" dir="auto">
                    {L.users.find((u) => u.user_id === form.user_id)?.display_name ?? L.me.display_name}
                  </span>
                )}
              </label>
              <label className="block text-xs font-medium text-muted">{t('apr.sub.substitute')}
                <select id="sub-substitute" className="input mt-1 text-[15px] text-ink" value={form.substitute_id} onChange={(e) => setForm({ ...form, substitute_id: e.target.value })}>
                  <option value="">{t('adm.choose')}</option>
                  {L.users.filter((u) => u.user_id !== (form.user_id || L.me.user_id)).map((u) => (
                    <option key={u.user_id} value={u.user_id}>{u.display_name}{u.position_name ? ` · ${u.position_name}` : ''}</option>
                  ))}
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('apr.sub.from')}
                <input id="sub-from" type="date" className="input num mt-1 text-[15px] text-ink" value={form.from_date} onChange={(e) => setForm({ ...form, from_date: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('apr.sub.to')}
                <input id="sub-to" type="date" className="input num mt-1 text-[15px] text-ink" value={form.to_date} onChange={(e) => setForm({ ...form, to_date: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted sm:col-span-2 lg:col-span-4">{t('apr.sub.note')}
                <input id="sub-note" dir="auto" className="input mt-1 text-[15px] text-ink" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
              </label>
            </div>
            {form.user_id && (
              <p className="text-xs text-ink-2" dir="auto" data-testid="sub-stages">
                {t('apr.sub.stagesOf', { stages: (L.users.find((u) => u.user_id === form.user_id)?.stages ?? []).join(', ') || '—' })}
              </p>
            )}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="ghost" onClick={() => setForm(null)} icon={<X className="h-4 w-4" aria-hidden />}>{t('fs.cancel')}</Button>
              <Button variant="primary" id="sub-save" disabled={busy} onClick={save} icon={<Save className="h-4 w-4" aria-hidden />}>{t('apr.sub.save')}</Button>
            </div>
          </div>
        </SectionCard>
      )}
      {q.isLoading ? <div className="card"><SkeletonRows rows={4} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : L && (
        <div className="min-w-0 space-y-5">
          <div className="card min-w-0 max-w-full overflow-hidden">
            {rows.length === 0 ? <EmptyState title={t('apr.sub.none')} body={t('apr.sub.noneBody')} /> : (
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="sub-table">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.sub.authorizer')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.sub.substitute')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('apr.sub.period')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('apr.sub.stages')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('apr.sub.decided')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                    <th scope="col" className="px-4 py-2.5"><span className="sr-only">{t('fs.per.actions')}</span></th>
                  </tr></thead>
                  <tbody>
                    {rows.map((r) => (
                      <tr key={r.sub_id} className="border-t border-line align-top" data-testid="sub-row" data-status={r.status}>
                        <td className="px-4 py-2.5" dir="auto"><div className="font-medium">{r.user_name}</div>{r.note && <div className="text-xs text-muted">{r.note}</div>}</td>
                        <td className="px-4 py-2.5" dir="auto">{r.substitute_name}</td>
                        <td className="num px-4 py-2.5 whitespace-nowrap">{fmtDay(r.from_date)} – {fmtDay(r.to_date)}</td>
                        <td className="px-4 py-2.5 text-ink-2 max-md:hidden" dir="auto">{r.stages.join(', ') || '—'}</td>
                        <td className="num px-4 py-2.5 text-end max-sm:hidden">{r.decided}</td>
                        <td className="px-4 py-2.5"><SubStatusPill status={r.status} />
                          {r.status === 'ended' && r.ended_by_name && <div className="mt-1 text-xs text-muted">{t('apr.sub.endedBy', { name: r.ended_by_name })}</div>}</td>
                        <td className="px-4 py-2.5 text-end">
                          <div className="flex flex-wrap justify-end gap-1">
                            {r.can_edit && <Button variant="ghost" className="min-h-[40px] px-3 text-sm" onClick={() => start(r)} icon={<Pencil className="h-4 w-4" aria-hidden />}>{t('adm.edit')}</Button>}
                            {r.active && r.status !== 'expired' && (admin || r.user_id === L.me.user_id) && (
                              <Button variant="ghost" className="min-h-[40px] px-3 text-sm" data-testid="sub-end" onClick={() => setEndFor(r)} icon={<CalendarX className="h-4 w-4" aria-hidden />}>{t('apr.sub.end')}</Button>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
          {mode === 'admin' && L.sees_all && <AuditCard objects={['approval_substitute', 'approval']} />}
        </div>
      )}
      <Dialog open={Boolean(endFor)} title={t('apr.sub.endTitle')} onClose={() => setEndFor(null)}
        footer={<><Button variant="secondary" onClick={() => setEndFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="sub-end-confirm" disabled={busy} onClick={end}>{t('apr.sub.end')}</Button></>}>
        <p className="text-sm text-ink-2">{t('apr.sub.endBody', { name: endFor?.substitute_name ?? '', user: endFor?.user_name ?? '' })}</p>
      </Dialog>
    </>
  );

  if (mode === 'admin') {
    return (
      <AdminFrame title={t('apr.sub.title')} desc={desc} crumbs={[[t('apr.process'), '/admin/approvals/templates'], [t('apr.sub.title'), undefined]]} actions={actions}>
        <ProcessTabs company={company} />
        {body}
      </AdminFrame>
    );
  }
  return (
    <div>
      <PageTitle crumbs={[[t('nav.home'), '/'], [t('inbox.title'), '/approvals'], [title, undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
      {body}
    </div>
  );
}

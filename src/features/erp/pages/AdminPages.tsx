import { useMemo, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, CircleCheck, Eye, Mail, Plus, Save, Search, Trash2, UserPlus, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard, fmtDay } from '../components/ui';
import { RequireModule, useModuleAccess } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { moduleByKey } from '../modules';
import {
  ADMIN_MODULES, accessPreview, accessSave, employeeOptions, inviteCancel, inviteUser, positionDelete, positionSave, useAdminPositions,
  useAdminUsers, useAudit, userSave, type AccessPreview, type AdminModule, type AdminUser, type UserInput,
} from '../admin';

// ---------- Shared pieces for the Administration screens ----------
/** The company a setup screen works on: ?company=, the top-bar company, or the user's home company when "all companies" is selected. */
export function useAdminCompany() {
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const [sp] = useSearchParams();
  const companies = profile?.companies ?? [];
  const [picked, setPicked] = useState<string | null>(sp.get('company'));
  const company = picked ?? (top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? '');
  return { company, setCompany: setPicked, companies };
}

export function AdminFrame({ title, desc, children, actions, crumbs, module = 'administration' }: {
  title: string; desc: string; children: ReactNode; actions?: ReactNode; crumbs?: Array<[string, string | undefined]>;
  module?: 'administration' | 'financials';
}) {
  const { t } = useTranslation();
  const m = moduleByKey('administration')!;
  const body = (
    <>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/administration'], ...(crumbs ?? [[title, undefined] as [string, undefined]])]}
        eyebrow={t('adm.eyebrow')} title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
      {children}
    </>
  );
  return module === 'financials' ? <FinanceOrAdmin>{body}</FinanceOrAdmin> : <RequireModule module="administration">{body}</RequireModule>;
}
/** Exchange rates: Finance enters them, so Financials users may open this Administration screen too. */
function FinanceOrAdmin({ children }: { children: ReactNode }) {
  const can = useModuleAccess();
  return can('financials') ? <>{children}</> : <RequireModule module="administration">{children}</RequireModule>;
}

export function CompanyPicker({ company, setCompany, companies }: { company: string; setCompany: (c: string) => void; companies: Array<{ company_code: string; short_name: string }> }) {
  const { t } = useTranslation();
  if (companies.length < 2) return null;
  return (
    <label className="flex flex-col gap-1 text-xs font-medium text-muted">{t('je.company')}
      <select id="adm-company" className="input min-h-[40px] py-0 text-sm text-ink" value={company} onChange={(e) => setCompany(e.target.value)}>
        {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
      </select>
    </label>
  );
}

export function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden /><span data-testid="adm-flash">{text}</span></p>;
}
export function ErrorBox({ text }: { text: string | null }) {
  if (!text) return null;
  return <div role="alert" className="mb-4 flex items-start gap-2 rounded-card border border-crit-fg/30 bg-crit-bg p-4 font-semibold text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="adm-error">{text}</span></div>;
}
export function ReadOnlyNote({ show }: { show: boolean }) {
  const { t } = useTranslation();
  if (!show) return null;
  return <p className="mb-4 rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-ink-2" data-testid="adm-readonly">{t('adm.readOnly')}</p>;
}
function useLocFlash() {
  const loc = useLocation();
  return useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
}

export function AuditCard({ objects }: { objects: string[] }) {
  const { t } = useTranslation();
  const q = useAudit(objects);
  return (
    <SectionCard title={t('adm.audit.title')}>
      {q.isLoading ? <SkeletonRows rows={3} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !(q.data ?? []).length ? (
        <p className="p-5 text-sm text-muted">{t('adm.audit.empty')}</p>
      ) : (
        <ul className="divide-y divide-line" data-testid="adm-audit">
          {(q.data ?? []).map((a, i) => (
            <li key={i} className="px-5 py-3 text-sm">
              <div className="flex flex-wrap justify-between gap-2"><span className="font-medium">{t(`adm.audit.act.${a.action}`, { defaultValue: a.action })}</span>
                <span className="num text-xs text-muted">{fmtDate(a.at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</span></div>
              <div className="text-xs text-muted" dir="auto">{a.actor_name}{a.object_ref ? ` · ${a.object_ref}` : ''}{a.company_code ? ` · ${a.company_code}` : ''}</div>
            </li>
          ))}
        </ul>
      )}
    </SectionCard>
  );
}

const lvlTone = (l: string | undefined) => (l === 'full' ? 'pill-ok' : l === 'read' ? 'pill-info' : 'pill-neutral');

// ---------- Users ----------
export function UsersPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const q = useAdminUsers();
  const [flash, setFlash] = useLocFlash();
  const [err, setErr] = useState<string | null>(null);
  const [s, setS] = useState('');
  const [st, setSt] = useState<'all' | 'active' | 'inactive'>('all');
  const [cancelFor, setCancelFor] = useState<{ id: number; email: string } | null>(null);
  const rows = useMemo(() => (q.data?.users ?? []).filter((u) => {
    const k = s.trim().toLowerCase();
    if (st === 'active' && !u.active) return false;
    if (st === 'inactive' && u.active) return false;
    return !k || [u.display_name, u.email, u.position_name, u.position_code, u.emp_code].some((x) => (x ?? '').toLowerCase().includes(k));
  }), [q.data, s, st]);
  const canWrite = Boolean(q.data?.can_write);

  async function cancel() {
    if (!cancelFor) return;
    setErr(null);
    try {
      await inviteCancel(cancelFor.id);
      setFlash(t('adm.users.inviteCancelled', { email: cancelFor.email }));
      setCancelFor(null);
      await qc.invalidateQueries({ queryKey: ['adm-users'] });
    } catch (e) { setErr(errorMessage(e)); setCancelFor(null); }
  }

  return (
    <AdminFrame title={t('adm.users.title')} desc={t('adm.users.desc')}
      actions={canWrite ? <Link to="/admin/users/invite" id="adm-invite" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-primary bg-primary px-4 font-medium text-white hover:bg-primary-hover"><UserPlus className="h-4 w-4" aria-hidden />{t('adm.users.invite')}</Link>
        : q.data ? <Button disabled disabledReason={t('adm.readOnlyShort')} id="adm-invite-off" icon={<UserPlus className="h-4 w-4" aria-hidden />}>{t('adm.users.invite')}</Button> : undefined}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="space-y-5 min-w-0">
          <div className="card">
            <div className="flex flex-wrap items-end gap-3 border-b border-line p-4">
              <label className="relative min-w-[220px] flex-1">
                <span className="sr-only">{t('adm.users.search')}</span>
                <Search className="pointer-events-none absolute start-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" aria-hidden />
                <input id="adm-user-search" className="input min-h-[40px] ps-9 text-sm" placeholder={t('adm.users.search')} value={s} onChange={(e) => setS(e.target.value)} />
              </label>
              <label className="flex flex-col gap-1 text-xs font-medium text-muted">{t('erp.col.status')}
                <select id="adm-user-status" className="input min-h-[40px] w-auto py-0 text-sm text-ink" value={st} onChange={(e) => setSt(e.target.value as typeof st)}>
                  <option value="all">{t('adm.users.all')}</option><option value="active">{t('adm.users.active')}</option><option value="inactive">{t('adm.users.inactive')}</option>
                </select>
              </label>
            </div>
            <p className="px-4 pt-3 text-sm text-muted" aria-live="polite">{q.data ? t('adm.users.count', { count: rows.length }) : ''}</p>
            {q.isLoading ? <SkeletonRows rows={6} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : rows.length === 0 ? (
              <EmptyState title={t('adm.users.empty')} body={t('adm.users.emptyBody')} />
            ) : (
              <div className="relative overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="adm-users-table">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('adm.users.col.user')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('adm.users.col.position')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('adm.users.col.companies')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-lg:hidden">{t('adm.users.col.employee')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('adm.users.col.lastSignIn')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                  </tr></thead>
                  <tbody>
                    {rows.map((u) => (
                      <tr key={u.user_id} className="border-t border-line hover:bg-surface-2" data-testid="adm-user-row" data-email={u.email ?? ''}>
                        <td className="px-4 py-2.5">
                          <Link to={`/admin/users/${u.user_id}`} className="font-medium text-primary hover:underline" dir="auto">{u.display_name}</Link>
                          <div className="text-xs text-muted" dir="ltr">{u.email ?? '—'}</div>
                        </td>
                        <td className="px-4 py-2.5"><div dir="auto">{u.position_name}</div><div className="font-mono text-xs text-muted">{u.position_code}</div></td>
                        <td className="px-4 py-2.5 font-mono text-[13px] max-md:hidden">{u.companies.join(', ')}</td>
                        <td className="px-4 py-2.5 max-lg:hidden" dir="auto">{u.emp_name ? <>{u.emp_name} <span className="font-mono text-xs text-muted">{u.emp_code}</span></> : <span className="text-muted">—</span>}</td>
                        <td className="num px-4 py-2.5 text-ink-2 max-sm:hidden">{u.last_sign_in_at ? fmtDate(u.last_sign_in_at, { day: '2-digit', month: 'short', year: 'numeric' }) : u.invited_at ? t('adm.users.invitedNotYet') : t('adm.users.never')}</td>
                        <td className="px-4 py-2.5"><span className={clsx('pill', u.active ? 'pill-ok' : 'pill-neutral')}>{u.active ? t('adm.users.active') : t('adm.users.inactive')}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
        <aside className="space-y-5">
          <SectionCard title={t('adm.users.invites', { count: q.data?.invites.length ?? 0 })}>
            {!(q.data?.invites ?? []).length ? <p className="p-5 text-sm text-muted">{t('adm.users.noInvites')}</p> : (
              <ul className="divide-y divide-line" data-testid="adm-invites">
                {(q.data?.invites ?? []).map((i) => (
                  <li key={i.invite_id} className="flex items-start justify-between gap-3 px-5 py-3 text-sm">
                    <div className="min-w-0"><div className="font-medium" dir="auto">{i.display_name}</div><div className="truncate text-xs text-muted" dir="ltr">{i.email}</div>
                      <div className="text-xs text-muted">{i.position_code} · {fmtDay(i.invited_at)}</div></div>
                    {canWrite && <Button variant="ghost" className="min-h-[40px] px-3 text-sm" onClick={() => setCancelFor({ id: i.invite_id, email: i.email })}>{t('adm.users.cancelInvite')}</Button>}
                  </li>
                ))}
              </ul>
            )}
          </SectionCard>
          <SectionCard title={t('adm.users.howTitle')}><p className="p-5 text-sm text-ink-2">{t('adm.users.howBody')}</p></SectionCard>
          <AuditCard objects={['app_user', 'user_invite']} />
        </aside>
      </div>
      <Dialog open={Boolean(cancelFor)} title={t('adm.users.cancelTitle', { email: cancelFor?.email ?? '' })} onClose={() => setCancelFor(null)}
        footer={<><Button variant="secondary" onClick={() => setCancelFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="adm-cancel-invite-confirm" onClick={cancel}>{t('adm.users.cancelInvite')}</Button></>}>
        <p className="text-sm text-ink-2">{t('adm.users.cancelBody')}</p>
      </Dialog>
    </AdminFrame>
  );
}

const emptyUser: UserInput & { email: string } = { email: '', display_name: '', position_code: '', company_code: '', companies: [], emp_id: null, language: 'en', mobile: '', active: true };

export function UserFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const { id = '' } = useParams();
  const nav = useNavigate();
  const qc = useQueryClient();
  const q = useAdminUsers();
  const pos = useAdminPositions();
  const user: AdminUser | undefined = q.data?.users.find((u) => u.user_id === id);
  const [form, setForm] = useState<(UserInput & { email: string }) | null>(null);
  const [empText, setEmpText] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const isMe = mode === 'edit' && q.data?.me === id;
  const f: UserInput & { email: string } = form ?? (mode === 'edit' && user
    ? { email: user.email ?? '', display_name: user.display_name, position_code: user.position_code, company_code: user.company_code, companies: user.companies,
        emp_id: user.emp_id, language: user.language, mobile: user.mobile ?? '', active: user.active }
    : { ...emptyUser, company_code: q.data?.companies[0]?.company_code ?? '', companies: q.data?.companies.length === 1 ? [q.data.companies[0].company_code] : [] });
  const set = (p: Partial<UserInput & { email: string }>) => setForm({ ...f, ...p });
  const empShown = empText ?? (user && user.emp_id === f.emp_id && user.emp_name ? `${user.emp_code ?? user.emp_id} · ${user.emp_name}` : '');
  const levels = pos.data?.positions.find((p) => p.position_code === f.position_code)?.levels ?? {};
  const title = mode === 'new' ? t('adm.users.inviteTitle') : user?.display_name ?? t('adm.users.title');

  async function submit() {
    setErr(null); setBusy(true);
    try {
      const body = { ...f, mobile: f.mobile.trim() };
      if (mode === 'new') {
        const r = await inviteUser(body);
        await qc.invalidateQueries({ queryKey: ['adm-users'] });
        nav('/admin/users', { state: { flash: t('adm.users.invited', { email: r.email }) } });
      } else {
        await userSave(id, body);
        await qc.invalidateQueries({ queryKey: ['adm-users'] });
        nav('/admin/users', { state: { flash: t('adm.users.saved', { name: f.display_name }) } });
      }
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const empOpts = async (s: string): Promise<Array<ComboOption<number>>> => (await employeeOptions(f.company_code, s)).map((e) => ({
    value: String(e.emp_id), label: `${e.hr_code ?? e.emp_id} · ${e.name}`, data: e.emp_id, meta: e.linked_to ? t('adm.users.linkedTo', { name: e.linked_to }) : undefined,
  }));

  return (
    <AdminFrame title={title} desc={mode === 'new' ? t('adm.users.inviteDesc') : t('adm.users.editDesc')}
      crumbs={[[t('adm.users.title'), '/admin/users'], [title, undefined]]}>
      {q.isLoading ? <div className="card"><SkeletonRows rows={6} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
        : mode === 'edit' && !user ? <div className="card"><EmptyState title={t('adm.users.notFound')} body={t('adm.users.notFoundBody')} /></div> : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
          <div className="min-w-0">
            <ErrorBox text={err} />
            <ReadOnlyNote show={!q.data?.can_write} />
            <SectionCard title={t('adm.users.general')}>
              <div className="grid gap-4 p-5 sm:grid-cols-2">
                {mode === 'new' ? (
                  <label className="block text-xs font-medium text-muted sm:col-span-2">{t('adm.users.email')}
                    <input id="adm-u-email" type="email" dir="ltr" className="input mt-1 text-[15px] text-ink" value={f.email} onChange={(e) => set({ email: e.target.value })} autoComplete="off" />
                  </label>
                ) : (
                  <div className="text-xs font-medium text-muted sm:col-span-2">{t('adm.users.email')}<div className="mt-1 text-[15px] text-ink" dir="ltr">{f.email || '—'}</div></div>
                )}
                <label className="block text-xs font-medium text-muted">{t('adm.users.name')}
                  <input id="adm-u-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={f.display_name} onChange={(e) => set({ display_name: e.target.value })} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('adm.users.mobile')}
                  <input id="adm-u-mobile" dir="ltr" inputMode="tel" className="input mt-1 text-[15px] text-ink" value={f.mobile} onChange={(e) => set({ mobile: e.target.value })} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('adm.users.col.position')}
                  <select id="adm-u-position" className="input mt-1 text-[15px] text-ink" value={f.position_code} disabled={isMe} onChange={(e) => set({ position_code: e.target.value })}>
                    <option value="">{t('adm.choose')}</option>
                    {(q.data?.positions ?? []).map((p) => <option key={p.position_code} value={p.position_code}>{p.name} ({p.position_code})</option>)}
                  </select>
                  {isMe && <span className="mt-1 block text-xs text-muted">{t('adm.users.ownPosition')}</span>}
                </label>
                <label className="block text-xs font-medium text-muted">{t('adm.users.language')}
                  <select id="adm-u-lang" className="input mt-1 text-[15px] text-ink" value={f.language} onChange={(e) => set({ language: e.target.value as 'en' | 'ar' })}>
                    <option value="en">English</option><option value="ar">العربية</option>
                  </select>
                </label>
                <fieldset className="sm:col-span-2">
                  <legend className="text-xs font-medium text-muted">{t('adm.users.col.companies')}</legend>
                  <div className="mt-2 flex flex-wrap gap-3">
                    {(q.data?.companies ?? []).map((c) => (
                      <label key={c.company_code} className="inline-flex min-h-[40px] items-center gap-2 rounded-btn border border-line px-3 text-sm">
                        <input type="checkbox" className="h-4 w-4" data-company={c.company_code} checked={f.companies.includes(c.company_code)}
                          onChange={(e) => set({ companies: e.target.checked ? [...f.companies, c.company_code] : f.companies.filter((x) => x !== c.company_code) })} />
                        <span className="font-mono">{c.company_code}</span> <span className="text-ink-2">{c.short_name}</span>
                      </label>
                    ))}
                  </div>
                </fieldset>
                <label className="block text-xs font-medium text-muted">{t('adm.users.home')}
                  <select id="adm-u-home" className="input mt-1 text-[15px] text-ink" value={f.company_code} onChange={(e) => { set({ company_code: e.target.value, emp_id: null }); setEmpText(''); }}>
                    {(q.data?.companies ?? []).map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
                  </select>
                </label>
                <div>
                  <Combobox<number> id="adm-u-emp" label={t('adm.users.col.employee')} text={empShown} onText={(s) => { setEmpText(s); if (!s) set({ emp_id: null }); }}
                    search={empOpts} placeholder={t('adm.users.empPh')} noMatch={t('adm.users.empNone')}
                    onSelect={(o) => { set({ emp_id: o.data }); setEmpText(o.label); }} />
                  {f.emp_id !== null && <button type="button" className="mt-1 text-xs text-primary hover:underline" onClick={() => { set({ emp_id: null }); setEmpText(''); }}>{t('adm.users.unlink')}</button>}
                </div>
                {mode === 'edit' && (
                  <label className="inline-flex min-h-[44px] items-center gap-2 text-sm sm:col-span-2">
                    <input id="adm-u-active" type="checkbox" className="h-4 w-4" checked={f.active !== false} disabled={isMe} onChange={(e) => set({ active: e.target.checked })} />
                    {t('adm.users.activeLabel')}{isMe && <span className="text-xs text-muted">· {t('adm.users.ownActive')}</span>}
                  </label>
                )}
              </div>
            </SectionCard>
            <div className="mt-5 flex flex-wrap justify-end gap-2">
              <Link to="/admin/users" className="inline-flex min-h-[44px] items-center rounded-btn border border-line px-4 font-medium hover:bg-page">{t('fs.cancel')}</Link>
              <Button variant="primary" id="adm-u-save" disabled={busy || !q.data?.can_write} disabledReason={!q.data?.can_write ? t('adm.readOnlyShort') : undefined} onClick={submit}
                icon={mode === 'new' ? <Mail className="h-4 w-4" aria-hidden /> : <Save className="h-4 w-4" aria-hidden />}>
                {mode === 'new' ? t('adm.users.sendInvite') : t('adm.save')}
              </Button>
            </div>
          </div>
          <aside className="space-y-5">
            <SectionCard title={t('adm.users.accessTitle')}>
              <div className="p-5 text-sm">
                {!f.position_code ? <p className="text-muted">{t('adm.users.accessNone')}</p> : (
                  <>
                    <div className="flex flex-wrap gap-2" data-testid="adm-u-levels">
                      {ADMIN_MODULES.filter((m) => levels[m]).map((m) => <span key={m} className={clsx('pill', lvlTone(levels[m]))}>{t(`adm.mod.${m}`)} · {t(`adm.lvl.${levels[m]}`)}</span>)}
                      {!ADMIN_MODULES.some((m) => levels[m]) && <span className="text-muted">{t('adm.users.accessEmpty')}</span>}
                    </div>
                    <Link to="/admin/authorizations" className="mt-3 inline-block text-primary hover:underline">{t('adm.users.changeAccess')}</Link>
                  </>
                )}
              </div>
            </SectionCard>
            {mode === 'new' && <SectionCard title={t('adm.users.howTitle')}><p className="p-5 text-sm text-ink-2">{t('adm.users.howBody')}</p></SectionCard>}
          </aside>
        </div>
      )}
    </AdminFrame>
  );
}

// ---------- Positions and Authorizations ----------
type Cell = 'full' | 'read' | 'none';
export function AuthorizationsPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const q = useAdminPositions();
  const [edits, setEdits] = useState<Record<string, Record<string, Cell>>>({});
  const [preview, setPreview] = useState<AccessPreview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [newCode, setNewCode] = useState('');
  const [newName, setNewName] = useState('');
  const [manage, setManage] = useState('');
  const [rename, setRename] = useState<string | null>(null);
  const [delFor, setDelFor] = useState<string | null>(null);
  const canWrite = Boolean(q.data?.can_write);
  const mods = q.data?.modules ?? [...ADMIN_MODULES];
  const cur = (code: string, m: string): Cell => (edits[code]?.[m] ?? q.data?.positions.find((p) => p.position_code === code)?.levels[m as AdminModule] ?? 'none') as Cell;
  const changed = (code: string) => Object.entries(edits[code] ?? {}).some(([m, v]) => v !== ((q.data?.positions.find((p) => p.position_code === code)?.levels[m as AdminModule]) ?? 'none'));
  const managed = q.data?.positions.find((p) => p.position_code === manage);

  async function review(code: string) {
    setErr(null); setBusy(true);
    try { setPreview(await accessPreview(code, edits[code] ?? {})); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function save() {
    if (!preview) return;
    setErr(null); setBusy(true);
    try {
      await accessSave(preview.position_code, edits[preview.position_code] ?? {});
      setFlash(t('adm.auth.saved', { pos: preview.position_code, count: preview.users.length }));
      setEdits(({ [preview.position_code]: _drop, ...rest }) => rest);
      setPreview(null);
      await Promise.all([qc.invalidateQueries({ queryKey: ['adm-positions'] }), qc.invalidateQueries({ queryKey: ['profile'] })]);
    } catch (e) { setErr(errorMessage(e)); setPreview(null); } finally { setBusy(false); }
  }
  async function run(fn: () => Promise<unknown>, msg: string) {
    setErr(null); setFlash(null); setBusy(true);
    try { await fn(); setFlash(msg); await qc.invalidateQueries({ queryKey: ['adm-positions'] }); return true; } catch (e) { setErr(errorMessage(e)); return false; } finally { setBusy(false); }
  }

  return (
    <AdminFrame title={t('adm.auth.title')} desc={t('adm.auth.desc')}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(q.data && !canWrite)} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : (
        <div className="space-y-5">
          <SectionCard title={t('adm.auth.matrix')} right={<span className="text-xs text-muted">{t('adm.auth.legend')}</span>}>
            <div className="relative overflow-x-auto">
              <table className="w-full min-w-[960px] text-[13px]" data-testid="adm-matrix">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="sticky start-0 z-10 bg-surface-2 px-4 py-2.5 text-start">{t('adm.users.col.position')}</th>
                  {mods.map((m) => <th key={m} scope="col" className="px-2 py-2.5 text-center">{t(`adm.mod.${m}`)}</th>)}
                  <th scope="col" className="px-4 py-2.5 text-end"><span className="sr-only">{t('fs.per.actions')}</span></th>
                </tr></thead>
                <tbody>
                  {(q.data?.positions ?? []).map((p) => (
                    <tr key={p.position_code} className={clsx('border-t border-line', changed(p.position_code) && 'bg-warn-bg/60')} data-testid="adm-matrix-row" data-position={p.position_code}>
                      <th scope="row" className="sticky start-0 z-10 bg-surface px-4 py-2 text-start font-normal">
                        <div className="font-medium" dir="auto">{p.name}</div>
                        <div className="text-xs text-muted"><span className="font-mono">{p.position_code}</span> · {t('adm.auth.nUsers', { count: p.users })}{p.position_code === q.data?.my_position ? ` · ${t('adm.auth.yours')}` : ''}</div>
                      </th>
                      {mods.map((m) => {
                        const v = cur(p.position_code, m);
                        return (
                          <td key={m} className="px-1 py-2 text-center">
                            {canWrite ? (
                              <select aria-label={`${p.name} · ${t(`adm.mod.${m}`)}`} data-module={m}
                                className={clsx('input min-h-[40px] w-[84px] px-2 py-0 text-xs font-semibold', v === 'full' ? 'text-ok-fg' : v === 'read' ? 'text-info-fg' : 'text-muted')}
                                value={v} onChange={(e) => setEdits({ ...edits, [p.position_code]: { ...(edits[p.position_code] ?? {}), [m]: e.target.value as Cell } })}>
                                <option value="full">{t('adm.lvl.full')}</option><option value="read">{t('adm.lvl.read')}</option><option value="none">{t('adm.lvl.none')}</option>
                              </select>
                            ) : <span className={clsx('pill', lvlTone(v))}>{t(`adm.lvl.${v}`)}</span>}
                          </td>
                        );
                      })}
                      <td className="px-4 py-2 text-end">
                        {canWrite && changed(p.position_code) && (
                          <div className="flex justify-end gap-1">
                            <Button variant="primary" className="min-h-[40px] px-3 text-sm" disabled={busy} id={`adm-review-${p.position_code}`} onClick={() => review(p.position_code)} icon={<Eye className="h-4 w-4" aria-hidden />}>{t('adm.auth.review')}</Button>
                            <Button variant="ghost" className="min-h-[40px] px-2" aria-label={t('adm.auth.undo')} onClick={() => setEdits(({ [p.position_code]: _d, ...rest }) => rest)} icon={<X className="h-4 w-4" aria-hidden />} />
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SectionCard>
          <div className="grid gap-5 lg:grid-cols-3">
            <SectionCard title={t('adm.auth.meaning')}>
              <dl className="space-y-3 p-5 text-sm">
                {(['full', 'read', 'none'] as const).map((l) => <div key={l}><dt><span className={clsx('pill', lvlTone(l))}>{t(`adm.lvl.${l}`)}</span></dt><dd className="mt-1 text-ink-2">{t(`adm.auth.means.${l}`)}</dd></div>)}
                <p className="text-muted">{t('adm.auth.ownerNote')}</p>
              </dl>
            </SectionCard>
            {canWrite && (
              <SectionCard title={t('adm.auth.newPosition')}>
                <div className="space-y-3 p-5">
                  <label className="block text-xs font-medium text-muted">{t('adm.auth.code')}
                    <input id="adm-pos-code" dir="ltr" className="input mt-1 font-mono text-[15px] uppercase text-ink" value={newCode} onChange={(e) => setNewCode(e.target.value.toUpperCase())} placeholder="SALES_MGR" />
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('adm.auth.name')}
                    <input id="adm-pos-name" dir="auto" className="input mt-1 text-[15px] text-ink" value={newName} onChange={(e) => setNewName(e.target.value)} />
                  </label>
                  <Button variant="secondary" id="adm-pos-create" className="w-full" disabled={busy || !newCode || !newName} icon={<Plus className="h-4 w-4" aria-hidden />}
                    onClick={async () => { if (await run(() => positionSave(newCode, newName, true), t('adm.auth.created', { pos: newCode }))) { setNewCode(''); setNewName(''); } }}>{t('adm.auth.create')}</Button>
                  <p className="text-xs text-muted">{t('adm.auth.newBody')}</p>
                </div>
              </SectionCard>
            )}
            {canWrite && (
              <SectionCard title={t('adm.auth.manage')}>
                <div className="space-y-3 p-5">
                  <label className="block text-xs font-medium text-muted">{t('adm.users.col.position')}
                    <select id="adm-pos-manage" className="input mt-1 text-[15px] text-ink" value={manage} onChange={(e) => { setManage(e.target.value); setRename(null); }}>
                      <option value="">{t('adm.choose')}</option>
                      {(q.data?.positions ?? []).map((p) => <option key={p.position_code} value={p.position_code}>{p.name} ({p.position_code})</option>)}
                    </select>
                  </label>
                  {managed && (
                    <>
                      <label className="block text-xs font-medium text-muted">{t('adm.auth.name')}
                        <input id="adm-pos-rename" dir="auto" className="input mt-1 text-[15px] text-ink" value={rename ?? managed.name} onChange={(e) => setRename(e.target.value)} />
                      </label>
                      <p className="text-xs text-muted">{t('adm.auth.usage', { users: managed.users, rules: managed.rules })}</p>
                      <div className="flex flex-wrap gap-2">
                        <Button variant="secondary" disabled={busy || !rename || rename === managed.name} onClick={() => run(() => positionSave(managed.position_code, rename ?? '', false), t('adm.auth.renamed', { pos: managed.position_code }))}>{t('adm.auth.rename')}</Button>
                        <Button variant="danger" id="adm-pos-delete" disabled={busy} onClick={() => setDelFor(managed.position_code)} icon={<Trash2 className="h-4 w-4" aria-hidden />}>{t('adm.delete')}</Button>
                      </div>
                    </>
                  )}
                </div>
              </SectionCard>
            )}
          </div>
          <AuditCard objects={['position']} />
        </div>
      )}
      <Dialog open={Boolean(preview)} title={t('adm.auth.reviewTitle', { pos: preview?.position_code ?? '' })} onClose={() => setPreview(null)}
        footer={<><Button variant="secondary" onClick={() => setPreview(null)}>{t('fs.cancel')}</Button><Button variant="primary" id="adm-access-save" disabled={busy} onClick={save}>{t('adm.auth.saveChanges')}</Button></>}>
        {preview && (
          <div className="space-y-4 text-sm" data-testid="adm-preview">
            {preview.gain.length > 0 && <div><div className="font-semibold text-ok-fg">{t('adm.auth.gain')}</div>
              <ul className="mt-1 space-y-1">{preview.gain.map((c) => <li key={c.module}>{t(`adm.mod.${c.module}`)}: {t(`adm.lvl.${c.from}`)} → <b>{t(`adm.lvl.${c.to}`)}</b></li>)}</ul></div>}
            {preview.lose.length > 0 && <div><div className="font-semibold text-crit-fg">{t('adm.auth.lose')}</div>
              <ul className="mt-1 space-y-1">{preview.lose.map((c) => <li key={c.module}>{t(`adm.mod.${c.module}`)}: {t(`adm.lvl.${c.from}`)} → <b>{t(`adm.lvl.${c.to}`)}</b></li>)}</ul></div>}
            <div><div className="font-semibold">{t('adm.auth.affected', { count: preview.users.length })}</div>
              {preview.users.length ? <ul className="mt-1 max-h-40 space-y-1 overflow-y-auto" data-testid="adm-preview-users">{preview.users.map((u) => <li key={u.user_id} dir="auto">{u.display_name} <span className="text-xs text-muted" dir="ltr">{u.email}</span></li>)}</ul>
                : <p className="text-muted">{t('adm.auth.noUsers')}</p>}</div>
            <p className="text-muted">{t('adm.auth.nextRequest')}</p>
          </div>
        )}
      </Dialog>
      <Dialog open={Boolean(delFor)} title={t('adm.auth.deleteTitle', { pos: delFor ?? '' })} onClose={() => setDelFor(null)}
        footer={<><Button variant="secondary" onClick={() => setDelFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="adm-pos-delete-confirm" disabled={busy}
          onClick={async () => { const c = delFor!; setDelFor(null); if (await run(() => positionDelete(c), t('adm.auth.deleted', { pos: c }))) setManage(''); }}>{t('adm.delete')}</Button></>}>
        <p className="text-sm text-ink-2">{t('adm.auth.deleteBody')}</p>
      </Dialog>
    </AdminFrame>
  );
}

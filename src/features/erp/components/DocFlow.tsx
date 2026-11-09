import { Fragment } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ChevronRight } from 'lucide-react';
import { CYCLE, useFlow, type FlowDoc } from '../salesCycle';

type Step = 'quotation' | 'order' | 'delivery' | 'invoice' | 'credit' | 'payment';
const STEP_OBJ: Record<Step, number | null> = { quotation: 23, order: 17, delivery: 15, invoice: 13, credit: 14, payment: null };

/**
 * Document flow strip (UI/UX spec §4.4): Quotation → Order → Delivery → Invoice → Payment, from the base links in both
 * directions (erp.sales_doc_flow). Done steps are green and link to their documents, the current step is indigo, future
 * steps are grey. A credit memo step appears once one exists. With no saved document (a new form) only `current` is shown.
 */
export function DocFlow({ company, obj, entry, current }: { company?: string; obj: number; entry?: number | null; current?: Step }) {
  const { t } = useTranslation();
  const flow = useFlow(company ?? '', obj, entry ?? 0, Boolean(company && entry));
  const docs: FlowDoc[] = flow.data ?? [];
  const cur: Step = current ?? (CYCLE.find((c) => c.obj === obj)?.step as Step) ?? 'order';
  const steps: Step[] = ['quotation', 'order', 'delivery', 'invoice', ...(docs.some((d) => d.obj_type === 14) || cur === 'credit' ? ['credit' as Step] : []), 'payment'];
  return (
    <ol className="mb-5 flex flex-wrap items-center gap-1.5" aria-label={t('so.flow.label')} data-testid="doc-flow">
      {steps.map((s, i) => {
        const mine = docs.filter((d) => d.obj_type === STEP_OBJ[s]);
        const isCur = s === cur;
        const done = !isCur && mine.length > 0;
        const tone = isCur ? 'border-primary bg-primary-soft text-primary-text' : done ? 'border-ok-fg/30 bg-ok-bg text-ok-fg' : 'border-line bg-surface text-muted';
        return (
          <li key={s} className="flex items-center gap-1.5">
            {i > 0 && <ChevronRight className="h-3.5 w-3.5 text-muted rtl:rotate-180" aria-hidden />}
            <span aria-current={isCur ? 'step' : undefined} data-step={s} data-state={isCur ? 'current' : done ? 'done' : 'future'}
              className={clsx('inline-flex min-h-[32px] flex-wrap items-center gap-x-1.5 rounded-full border px-3 text-[13px] font-medium', tone)}>
              {t(`so.flow.${s}`)}
              {mine.map((d, k) => {
                const kind = CYCLE.find((c) => c.obj === d.obj_type)?.kind;
                return (
                  <Fragment key={`${d.obj_type}-${d.doc_entry}`}>
                    {k > 0 && <span aria-hidden>,</span>}
                    {d.current || !kind ? <span className="font-mono text-[12px]">{d.doc_no}</span> : (
                      <Link to={`/docs/${kind}/${company}/${d.doc_entry}`} className="font-mono text-[12px] underline-offset-2 hover:underline">{d.doc_no}</Link>
                    )}
                  </Fragment>
                );
              })}
            </span>
          </li>
        );
      })}
    </ol>
  );
}

import clsx from 'clsx';
import type { ReactNode } from 'react';

export function Card({ title, actions, children, className, bodyClassName }: {
  title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string; bodyClassName?: string;
}) {
  return (
    <section className={clsx('card overflow-hidden', className)}>
      {(title || actions) && (
        <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-5 py-4">
          {title && <h2 className="text-[17px] font-semibold">{title}</h2>}
          {actions}
        </header>
      )}
      <div className={bodyClassName}>{children}</div>
    </section>
  );
}

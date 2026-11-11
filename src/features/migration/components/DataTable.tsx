import clsx from 'clsx';
import type { ReactNode } from 'react';

export interface Column<T> {
  key: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  align?: 'start' | 'end';
  mono?: boolean;
  className?: string;
}

/** Table that scrolls inside its own box (phones: wide tables never push the page). */
export function DataTable<T>({ columns, rows, rowKey, caption, onRowClick, footer, empty, minWidth = 640 }: {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string | number;
  caption?: string;
  onRowClick?: (row: T) => void;
  footer?: ReactNode;
  empty?: ReactNode;
  /** px before the table scrolls inside its box */
  minWidth?: number;
}) {
  return (
    <div className="relative overflow-x-auto">
      <table className="w-full border-collapse text-[15px]" style={{ minWidth }}>
        {caption && <caption className="sr-only">{caption}</caption>}
        <thead>
          <tr className="border-b border-line">
            {columns.map((c) => (
              <th
                key={c.key}
                scope="col"
                className={clsx('px-4 py-3 text-xs font-semibold uppercase tracking-wider text-muted', c.align === 'end' ? 'text-end' : 'text-start')}
              >
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 && empty ? (
            <tr><td colSpan={columns.length}>{empty}</td></tr>
          ) : (
            rows.map((r) => (
              <tr
                key={rowKey(r)}
                onClick={onRowClick ? () => onRowClick(r) : undefined}
                className={clsx('border-b border-line last:border-0', onRowClick && 'cursor-pointer hover:bg-page')}
              >
                {columns.map((c) => (
                  <td
                    key={c.key}
                    className={clsx('px-4 py-2.5 align-middle', c.align === 'end' && 'num whitespace-nowrap text-end', c.mono && 'font-mono text-sm', c.className)}
                  >
                    {c.cell(r)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
        {footer && <tfoot>{footer}</tfoot>}
      </table>
    </div>
  );
}


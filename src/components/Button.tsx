import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react';
import clsx from 'clsx';

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'success';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  icon?: ReactNode;
  /** Shown under a disabled button to explain why (P0 › Buttons). */
  disabledReason?: string;
}

const styles: Record<Variant, string> = {
  primary: 'bg-primary text-white hover:bg-primary-hover border border-primary',
  secondary: 'bg-surface text-ink border border-line hover:bg-page',
  ghost: 'bg-transparent text-ink hover:bg-page border border-transparent',
  danger: 'bg-surface text-crit-fg border border-crit-fg/30 hover:bg-crit-bg',
  success: 'bg-success text-white border border-success hover:brightness-110',
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'secondary', icon, disabledReason, className, children, disabled, type = 'button', ...rest },
  ref,
) {
  const btn = (
    <button
      ref={ref}
      type={type}
      disabled={disabled}
      aria-describedby={disabled && disabledReason ? rest.id && `${rest.id}-reason` : undefined}
      className={clsx(
        'inline-flex min-h-[44px] items-center justify-center gap-2 rounded-btn px-4 text-[15px] font-medium transition-colors',
        disabled ? 'cursor-not-allowed border border-transparent bg-neutral-bg text-muted' : styles[variant],
        className,
      )}
      {...rest}
    >
      {icon}
      {children}
    </button>
  );
  if (!disabled || !disabledReason) return btn;
  return (
    <div className={clsx('flex flex-col gap-1', className?.includes('w-full') && 'w-full')}>
      {btn}
      <p id={rest.id ? `${rest.id}-reason` : undefined} className="text-center text-xs text-muted">{disabledReason}</p>
    </div>
  );
});


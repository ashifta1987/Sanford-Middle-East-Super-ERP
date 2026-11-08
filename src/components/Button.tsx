import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react';
import clsx from 'clsx';

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  icon?: ReactNode;
  /** Shown under a disabled button to explain why (P0 › Buttons). */
  disabledReason?: string;
}

const styles: Record<Variant, string> = {
  primary: 'bg-primary text-white hover:bg-[#1A43BE] border border-primary',
  secondary: 'bg-white text-ink border border-line hover:bg-page',
  ghost: 'bg-transparent text-ink hover:bg-page border border-transparent',
  danger: 'bg-white text-crit-fg border border-[#F2C1C1] hover:bg-crit-bg',
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
        disabled ? 'cursor-not-allowed border border-transparent bg-[#E6E8EC] text-[#5B6270]' : styles[variant],
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

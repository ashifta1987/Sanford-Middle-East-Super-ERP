/** @type {import('tailwindcss').Config} */
// Southfield brand. Colours come from CSS variables (src/index.css) so light and dark themes share one set of class names.
// Values are "R G B" channels so opacity modifiers (bg-black/30, border-crit-fg/30) keep working.
const c = (v) => `rgb(var(--c-${v}) / <alpha-value>)`;

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"IBM Plex Sans"', '"IBM Plex Sans Arabic"', 'system-ui', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'monospace'],
        display: ['Outfit', '"IBM Plex Sans Arabic"', '"IBM Plex Sans"', 'system-ui', 'sans-serif'],
      },
      colors: {
        page: c('page'),
        surface: { DEFAULT: c('surface'), 2: c('surface-2') },
        line: { DEFAULT: c('line'), strong: c('line-strong') },
        ink: { DEFAULT: c('ink'), 2: c('ink-2') },
        muted: c('muted'),
        primary: { DEFAULT: c('primary'), hover: c('primary-hover'), soft: c('primary-soft'), text: c('primary-text'), line: c('primary-line') },
        side: { DEFAULT: c('side'), active: c('side-active'), 'active-text': c('side-active-text'), text: c('side-text'), muted: c('side-muted'), hover: c('side-hover'), line: c('side-line') },
        brand: { navy: c('brand-navy'), blue: c('brand-blue'), teal: c('brand-teal'), yellow: c('brand-yellow'), coral: c('brand-coral') },
        success: c('success'),
        ok: { bg: c('ok-bg'), fg: c('ok-fg') },
        warn: { bg: c('warn-bg'), fg: c('warn-fg') },
        crit: { bg: c('crit-bg'), fg: c('crit-fg') },
        info: { bg: c('info-bg'), fg: c('info-fg') },
        neutral: { bg: c('neutral-bg'), fg: c('neutral-fg') },
      },
      borderRadius: { card: '16px', btn: '10px' },
      boxShadow: { card: 'var(--shadow)' },
      maxWidth: { content: '1280px' },
    },
  },
  plugins: [],
};

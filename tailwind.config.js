/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"IBM Plex Sans"', '"IBM Plex Sans Arabic"', 'system-ui', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'monospace'],
      },
      colors: {
        page: '#F6F7F9',
        line: '#E2E5EA',
        ink: '#16191F',
        muted: '#5B6270',
        primary: { DEFAULT: '#1D4ED8', soft: '#E8EEFC' },
        ok: { bg: '#E7F6EC', fg: '#14532D' },
        warn: { bg: '#FFF4E5', fg: '#8A3B00' },
        crit: { bg: '#FDECEC', fg: '#8F1D1D' },
        info: { bg: '#EEF2FF', fg: '#1E3A8A' },
        neutral: { bg: '#F1F3F6', fg: '#4A5160' },
      },
      borderRadius: { card: '12px', btn: '10px' },
      maxWidth: { content: '1180px' },
    },
  },
  plugins: [],
};


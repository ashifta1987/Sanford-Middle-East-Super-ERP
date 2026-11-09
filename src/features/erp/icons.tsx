// Module icons drawn in the canvas design (24×24 outline paths).
const PATHS: Record<string, string> = {
  home: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
  administration: 'M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M14 6a2 2 0 1 0 4 0a2 2 0 1 0-4 0M8 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0M16 18a2 2 0 1 0 4 0a2 2 0 1 0-4 0',
  financials: 'M3 10l9-6 9 6M5 10v8M9.5 10v8M14.5 10v8M19 10v8M3 21h18',
  sales: 'M3 17l6-6 4 4 8-8M15 7h6v6',
  purchasing: 'M2 3h3l2.5 12h12L22 7H6.2M7.5 20a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0M16.5 20a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0',
  bp: 'M6 3h12a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM9 10a3 3 0 1 0 6 0a3 3 0 1 0-6 0M7.5 17c.8-2 2.5-3 4.5-3s3.7 1 4.5 3',
  banking: 'M5 6h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zM3 10h18M16 14h2',
  inventory: 'M3 7l9-4 9 4v10l-9 4-9-4zM3 7l9 4 9-4M12 11v10',
  production: 'M3 21V10l5 3v-3l5 3v-3l5 3V4h3v17z',
  service: 'M4 14v-2a8 8 0 0 1 16 0v2M4.5 14h1A1.5 1.5 0 0 1 7 15.5v3A1.5 1.5 0 0 1 5.5 20h-1A1.5 1.5 0 0 1 3 18.5v-3A1.5 1.5 0 0 1 4.5 14zM18.5 14h1a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-1a1.5 1.5 0 0 1-1.5-1.5v-3a1.5 1.5 0 0 1 1.5-1.5z',
  hr: 'M5.5 8a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0-7 0M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5M16 4.5a3.5 3.5 0 0 1 0 7M18 14.8c1.8.7 3 2.5 3.5 5.2',
  reports: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  control: 'M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6zM9 12l2 2 4-4',
  approvals: 'M4 4h16v12H5.2L4 17.2zM8 9l2.5 2.5L16 7',
};

export function ModuleIcon({ name, className = 'h-[18px] w-[18px]' }: { name: string; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d={PATHS[name] ?? PATHS.reports} />
    </svg>
  );
}

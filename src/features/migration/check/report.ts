// Download report: Excel (SheetJS) and PDF (@react-pdf/renderer) of every check, issue and sign-off.
// Both libraries are loaded only when the user asks for a report.

import type { MigrationReviewRow, SignoffEntry } from '@/lib/database.types';
import { issueDetail } from './derive';

export interface ReportData {
  runId: string;
  company: string;
  companyName: string;
  status: string;
  generatedAt: string;
  checks: MigrationReviewRow[];
  issues: MigrationReviewRow[];
  signoffs: SignoffEntry[];
}

const fileBase = (d: ReportData) => `sanford-migration-${d.company}-${d.runId.slice(0, 8)}-${d.generatedAt.slice(0, 10)}`;

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export async function downloadExcel(d: ReportData) {
  const XLSX = await import('xlsx');
  const wb = XLSX.utils.book_new();
  const head = [['Sanford ERP · migration report'], ['Run', d.runId], ['Company', `${d.company} ${d.companyName}`], ['Status', d.status], ['Generated', d.generatedAt], []];
  const checks = [
    ...head,
    ['Company', 'Area', 'Check', 'SAP', 'SAP copy', 'App', 'Difference', 'OK', 'SAP report', 'Report source', 'Report OK'],
    ...d.checks.map((c) => [c.company_code, c.area, c.name, c.sap_value, c.raw_value, c.app_value, c.difference, c.ok, c.report_value, c.report_source, c.report_ok]),
  ];
  const issues = [
    ...head,
    ['Company', 'Area', 'Severity', 'Title', 'Detail', 'Status', 'Note', 'Resolved at'],
    ...d.issues.map((i) => { const x = issueDetail(i); return [i.company_code, i.area, i.severity, i.name, x.detail, i.status, x.note, x.resolved_at]; }),
  ];
  const signs = [...head, ['Role', 'Decision', 'Signed by', 'Signed at', 'Comment'], ...d.signoffs.map((s) => [s.role, s.decision, s.signed_by, s.signed_at, s.comment])];
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(checks), 'Checks');
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(issues), 'Issues');
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(signs), 'Sign-offs');
  const out = XLSX.write(wb, { type: 'array', bookType: 'xlsx' });
  download(new Blob([out], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), `${fileBase(d)}.xlsx`);
}

export async function downloadPdf(d: ReportData) {
  const [{ pdf, Document, Page, Text, View, StyleSheet }, React] = await Promise.all([import('@react-pdf/renderer'), import('react')]);
  const h = React.createElement;
  const s = StyleSheet.create({
    page: { padding: 28, fontSize: 8, fontFamily: 'Helvetica', color: '#16191F' },
    h1: { fontSize: 14, marginBottom: 4, fontFamily: 'Helvetica-Bold' },
    meta: { fontSize: 8, color: '#5B6270', marginBottom: 2 },
    h2: { fontSize: 11, marginTop: 14, marginBottom: 4, fontFamily: 'Helvetica-Bold' },
    row: { flexDirection: 'row', borderBottomWidth: 0.5, borderBottomColor: '#E2E5EA', paddingVertical: 2 },
    th: { fontFamily: 'Helvetica-Bold', color: '#5B6270' },
    bad: { color: '#8F1D1D' },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const cell = (txt: unknown, w: string) => h(Text, { style: { width: w, paddingRight: 4 } as any }, txt == null ? '' : String(txt));
  const table = (cols: Array<[string, string]>, rows: unknown[][], badRow?: (i: number) => boolean) => [
    h(View, { style: [s.row, s.th], key: 'h', fixed: true }, ...cols.map(([label, w]) => cell(label, w))),
    ...rows.map((r, i) => h(View, { style: [s.row, badRow?.(i) ? s.bad : {}], key: i, wrap: false }, ...r.map((v, j) => cell(v, cols[j][1])))),
  ];
  const doc = h(Document, { title: `Migration report ${d.company}` },
    h(Page, { size: 'A4', orientation: 'landscape', style: s.page },
      h(Text, { style: s.h1 }, `Sanford ERP · migration report · ${d.company} ${d.companyName}`),
      h(Text, { style: s.meta }, `Run ${d.runId} · status ${d.status}`),
      h(Text, { style: s.meta }, `Generated ${d.generatedAt}`),
      h(Text, { style: s.h2 }, 'Sign-offs'),
      ...table([['Role', '15%'], ['Decision', '12%'], ['Signed at', '20%'], ['Comment', '53%']],
        ['finance', 'it', 'business'].map((r) => { const x = d.signoffs.find((o) => o.role === r); return [r, x?.decision ?? 'waiting', x?.signed_at ?? '', x?.comment ?? '']; })),
      h(Text, { style: s.h2 }, `Issues (${d.issues.length})`),
      ...table([['Co.', '6%'], ['Area', '9%'], ['Severity', '8%'], ['Title', '35%'], ['Status', '9%'], ['Note', '33%']],
        d.issues.map((i) => [i.company_code, i.area, i.severity, i.name, i.status, issueDetail(i).note ?? '']),
        (k) => d.issues[k].severity === 'critical' && d.issues[k].status === 'open'),
      h(Text, { style: s.h2 }, `Checks (${d.checks.length})`),
      ...table([['Co.', '6%'], ['Area', '9%'], ['Check', '33%'], ['SAP report', '11%'], ['SAP copy', '11%'], ['App', '11%'], ['Difference', '11%'], ['OK', '8%']],
        d.checks.map((c) => [c.company_code, c.area, c.name, c.report_value, c.raw_value, c.app_value, c.difference, c.ok ? 'ok' : 'NO']),
        (k) => d.checks[k].ok === false),
    ));
  const blob = await pdf(doc as Parameters<typeof pdf>[0]).toBlob();
  download(blob, `${fileBase(d)}.pdf`);
}

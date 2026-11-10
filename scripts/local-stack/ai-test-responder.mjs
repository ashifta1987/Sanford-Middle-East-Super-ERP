// LOCAL STACK ONLY. Deterministic stand-in for the AI provider used by gateway.mjs at /functions/v1/ai-assistant.
// It is NOT an AI: it turns the tool results (already read with the user's own rights by erp.ai_ask_context) into fixed
// sentences, so the Ask AI flow, sources, refusals and audit can be tested without a provider key. Never deployed.
export const LOCAL_RESPONDER = 'local-test';

const TITLES = {
  trial_balance: 'Trial balance', balance_sheet: 'Balance sheet', profit_loss: 'Profit and loss', ar_aging: 'Customer receivables aging',
  ap_aging: 'Supplier payables aging', sales_analysis: 'Sales analysis', open_items: 'Open items list',
  inventory_in_warehouse: 'Inventory in warehouse', inventory_valuation: 'Inventory valuation', document: 'This document',
};
const money = (n) => new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(n ?? 0));

function line(t) {
  const s = t.summary ?? {};
  const rows = Array.isArray(t.rows) ? t.rows : [];
  switch (t.tool) {
    case 'trial_balance':
      return `${s.accounts} accounts with amounts from ${s.from} to ${s.to}; debit ${money(s.debit)} = credit ${money(s.credit)}.`;
    case 'balance_sheet':
      return `At ${s.as_of}: assets ${money(s.assets)}, liabilities ${money(s.liabilities)}, equity incl. the current result ${money(s.equity)}.`;
    case 'profit_loss':
      return `${s.from} to ${s.to}: revenue ${money(s.revenue)}, cost of sales ${money(s.cost_of_sales)}, expenses ${money(s.expenses)}, net profit ${money(s.net_profit)}.`;
    case 'ar_aging':
    case 'ap_aging': {
      const top = rows.slice(0, 3).map((r) => `${r.card_code} ${r.card_name ?? ''} ${money(r.total)}`).join('; ');
      return `${s.partners} partners, ${money(s.total)} open, of which ${money(s.over_90)} over 90 days. Largest: ${top || 'none'}.`;
    }
    case 'sales_analysis': {
      const top = rows.slice(0, 3).map((r) => `${r.name ?? r.key} ${money(r.net_sales)}`).join('; ');
      return `By ${s.by}, ${s.from} to ${s.to}: net sales ${money(s.net_sales)}, gross profit ${money(s.gross_profit)}. Top: ${top || 'none'}.`;
    }
    case 'open_items':
      return `${s.documents} open documents, ${money(s.open_amount)} open in total.`;
    case 'inventory_in_warehouse':
      return `${s.lines} item/warehouse lines in ${s.warehouses} warehouses, ${money(s.on_hand)} units, value ${money(s.value)}.`;
    case 'inventory_valuation':
      return `${s.items} items in stock, valued at ${money(s.value)}.`;
    case 'document': {
      const h = s.history ?? {};
      return `${s.doc_no} (${s.status}) for ${s.card_code ?? '—'} ${s.card_name ?? ''}, ${s.lines} lines, total ${money(s.total)} ${s.currency ?? ''}. `
        + `In the last year this customer had ${h.documents ?? 0} other documents of this kind${h.average_total ? `, average ${money(h.average_total)}` : ''}.`;
    }
    default:
      return '';
  }
}

/** Fixed text built only from the context. */
export function localAnswer(ctx) {
  const tools = ctx.tools ?? [];
  if (tools.length === 0) {
    return 'Local test responder, not AI. I could not match the question to a report. Try asking about receivables, payables, sales, '
      + 'open orders, stock, the trial balance, the balance sheet or profit and loss.';
  }
  const parts = tools.map((t) => (t.status === 'ok'
    ? `${TITLES[t.tool] ?? t.tool}: ${line(t)}`
    : `${TITLES[t.tool] ?? t.tool}: not used. ${t.message}`));
  return ['Local test responder, not AI. From your data:', ...parts].join('\n');
}

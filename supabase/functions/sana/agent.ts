// SANA agent (S3 phase 1): modes 'now' (ranked finding cards for the open record) and 'line' (one sentence for the SANA line).
// Runtime-neutral (fetch only, erasable TypeScript): the Edge Function (index.ts) and the local gateway run this file.
//
// Order (spec rule 8): the deterministic checks run FIRST (erp.sana_checks, one RPC, with the user's JWT) and become facts; the
// model is called once with the facts (masked, rule 6) under a short budget; a slow, failed or missing model never blocks a law
// warning. Every finding is validated before it is shown or stored: evidence must resolve under the user's JWT
// (erp.sana_evidence_resolve), confidence is one of likely / possible / check this, a percentage only where a score was computed,
// and the model may not propose actions in phase 1 (proposed_action is dropped). Cards are written with
// erp.sana_findings_save (also one 'now'/'line' row in the append-only event log). Nothing here writes a business table.
import { makeRpc, redact, type Env } from './core.ts';
import { pickModel, type SanaModel } from './providers.ts';
import { maskDeep } from './mask.ts';

export const AGENT_LIMITS = { modelMs: 2000, deadlineMs: 2500, maxModelFindings: 3, maxCards: 8, maxTokens: 600 };
const RECORD_TYPES = ['document', 'payment', 'partner', 'item', 'home'];
const SEVERITY_RANK: Record<string, number> = { law: 0, risk: 1, info: 2 };
const CONFIDENCE = ['likely', 'possible', 'check_this'];

type Json = Record<string, unknown>;
export interface Evidence { table: string; id: string; label?: string; link?: string }
export interface Card {
  id?: number; rank: number; severity: 'law' | 'risk' | 'info'; code: string; title: string; body?: string | null;
  confidence: 'likely' | 'possible' | 'check_this'; score?: number | null; evidence: Evidence[]; source: 'rule' | 'model';
}
interface CheckRow { code: string; severity: string; message: string; evidence: Evidence[]; score: number | null }

const evKey = (e: Evidence) => `${e.table}:${e.id}`;
/** Rule 5: no percentages unless a score was computed. */
const noPercent = (t: string) => t.replace(/\b\d{1,3}(?:[.,]\d+)?\s?%/g, '').replace(/\s{2,}/g, ' ').trim();

export function ruleCard(r: CheckRow): Card {
  const sev = (['law', 'risk', 'info'].includes(r.severity) ? r.severity : 'info') as Card['severity'];
  const confidence: Card['confidence'] = r.score != null ? (r.score >= 90 ? 'likely' : 'possible') : sev === 'info' ? 'check_this' : 'likely';
  return { rank: 0, severity: sev, code: r.code, title: r.message, body: null, confidence, score: r.score ?? null, evidence: r.evidence ?? [], source: 'rule' };
}

/** Parse and clean what the model returned. Anything malformed is dropped, never repaired into a claim. */
export function modelCards(text: string): Card[] {
  const raw = text.replace(/^```(?:json)?/m, '').replace(/```\s*$/m, '').trim();
  let j: unknown;
  try { j = JSON.parse(raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1)); } catch { return []; }
  const list = Array.isArray((j as Json)?.findings) ? (j as { findings: unknown[] }).findings : [];
  const out: Card[] = [];
  for (const f of list.slice(0, AGENT_LIMITS.maxModelFindings)) {
    const x = f as Json;
    const sev = x.severity === 'risk' ? 'risk' : 'info';                       // the model never raises a law warning
    const conf = String(x.confidence ?? '').replace(' ', '_');
    const ev = Array.isArray(x.evidence) ? (x.evidence as Json[]).filter((e) => typeof e?.table === 'string' && typeof e?.id === 'string')
      .map((e) => ({ table: String(e.table), id: String(e.id) })) : [];
    const title = noPercent(redact(String(x.title ?? ''))).slice(0, 200);
    if (!title || !ev.length || !CONFIDENCE.includes(conf)) continue;
    const code = /^[a-z][a-z0-9_.]{1,50}$/.test(String(x.code ?? '')) ? `model.${String(x.code).replace(/^model\./, '')}` : 'model.note';
    out.push({ rank: 0, severity: sev, code, title, body: x.body ? noPercent(redact(String(x.body))).slice(0, 600) : null,
      confidence: conf as Card['confidence'], score: null, evidence: ev, source: 'model' });
  }
  return out;
}

export function rankCards(cards: Card[]): Card[] {
  return cards
    .sort((a, b) => (SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]) || (a.source === b.source ? 0 : a.source === 'rule' ? -1 : 1) || ((b.score ?? 0) - (a.score ?? 0)))
    .slice(0, AGENT_LIMITS.maxCards)
    .map((c, i) => ({ ...c, rank: i + 1 }));
}

function agentPrompt(language: string): string {
  return [
    'You are SANA, the assistant inside Southfield ERP. You review ONE record for the signed-in user.',
    'FACTS below are the record summary and the results of the company\'s rule checks. Use only FACTS. Never invent numbers, names or dates.',
    `Return JSON only: {"findings":[{"severity":"risk"|"info","code":"short_snake_case","title":"one sentence","body":"optional short reason","confidence":"likely"|"possible"|"check_this","evidence":[{"table":"…","id":"…"}]}]}`,
    `At most ${AGENT_LIMITS.maxModelFindings} findings, only ones the rule checks did not already raise. Every finding must cite evidence ids copied from FACTS.`,
    'No percentages. No law warnings (the rules already did that). You cannot change, post or approve anything; do not propose actions.',
    'If there is nothing useful to add, return {"findings":[]}.',
    `Write titles in ${language === 'ar' ? 'Arabic' : language === 'ml' ? 'Malayalam' : 'English'}; keep codes, numbers and amounts in Western digits.`,
  ].join('\n');
}

async function askModel(model: SanaModel, facts: unknown, language: string, budgetMs: number): Promise<{ cards: Card[]; ok: boolean }> {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), budgetMs);
  try {
    const turn = await model.ask({ system: agentPrompt(language), messages: [{ role: 'user', content: `FACTS:\n${JSON.stringify(facts)}` }], tools: [],
      maxTokens: AGENT_LIMITS.maxTokens, signal: ac.signal });
    return { cards: turn.refused ? [] : modelCards(turn.text), ok: !turn.refused };
  } catch (e) {
    console.error('sana agent model skipped', (e as { status?: number })?.status ?? (e as Error)?.name ?? 'error');
    return { cards: [], ok: false };
  } finally { clearTimeout(timer); }
}

export async function handleAgent(auth: string | null, body: unknown, env: Env): Promise<{ status: number; json: unknown }> {
  const t0 = Date.now();
  const fail = (status: number, error: string) => ({ status, json: { error } });
  if (!auth || !/^Bearer\s+\S+/i.test(auth)) return fail(401, 'Sign in to use Sana.');
  const b = (body ?? {}) as Json;
  const mode = b.mode === 'now' || b.mode === 'line' ? b.mode : null;
  if (!mode) return fail(400, 'Mode must be now or line.');
  const company = typeof b.company === 'string' && /^[A-Z0-9]{2,8}$/.test(b.company) && b.company !== 'GRP' ? b.company : null;
  if (!company) return fail(400, 'Choose a company first.');
  const recordType = typeof b.record_type === 'string' && RECORD_TYPES.includes(b.record_type) ? b.record_type : null;
  const recordId = typeof b.record_id === 'string' && /^[A-Za-z0-9:_.\-]{1,60}$/.test(b.record_id) ? b.record_id : recordType === 'home' ? '-' : null;
  if (!recordType || !recordId) return fail(400, 'Say which record to look at.');
  const screen = typeof b.screen === 'string' ? b.screen.replace(/[^a-z0-9_.\-/]/gi, '').slice(0, 60) : null;
  const language = typeof b.language === 'string' && /^[a-z]{2}$/.test(b.language) ? b.language : 'en';
  const draft = b.draft && typeof b.draft === 'object' && !Array.isArray(b.draft) ? b.draft : null;
  const rpc = makeRpc(env, auth);
  try {
    // deterministic first, in parallel with the profile and settings checks
    const [who, st, checks] = await Promise.all([
      rpc('sana_whoami', {}) as Promise<{ profile: boolean; companies?: Array<{ code: string }> }>,
      rpc('sana_status', { p_company: company }) as Promise<{ enabled: boolean }>,
      rpc('sana_checks', { p_company: company, p_record_type: recordType, p_record_id: recordId, p_draft: draft }) as Promise<{ findings: CheckRow[]; checked: string[]; record: Json | null }>,
    ]);
    if (!who?.profile) return fail(403, 'You need a Southfield profile to use Sana. Ask IT to add you.');
    if (!who.companies?.some((c) => c.code === company)) return fail(403, "You don't have access to that company.");
    if (!st?.enabled) return fail(403, 'Sana is switched off for your company. Ask your system admin.');
    // a record the role may not see: refused, with nothing about it (no cards, no counts)
    if ((recordType === 'document' || recordType === 'partner') && !checks?.record) {
      return { status: 200, json: { mode, company, record_type: recordType, record_id: recordId, denied: true, cards: [], line: null, ms: Date.now() - t0 } };
    }
    const rules = (checks?.findings ?? []).map(ruleCard);
    const msChecks = Date.now() - t0;

    // one model call for 'now' (facts masked); 'line' uses the rules only (it must be instant)
    const model = mode === 'now' ? pickModel(env) : null;
    let extra: Card[] = []; let modelOk = false;
    if (model) {
      const facts = maskDeep({ record_type: recordType, record_id: recordId, record: checks?.record ?? null, checked: checks?.checked ?? [],
        rule_findings: rules.map((c) => ({ code: c.code, severity: c.severity, title: c.title, evidence: c.evidence.map((e) => ({ table: e.table, id: e.id })) })),
        record_evidence: recordType === 'home' ? [] : [{ table: recordType, id: recordId }] });
      // the model gets what is left of a 2.5 s deadline (checks included), at most 2 s, so `now` stays under 3 s end to end
      const m = await askModel(model, facts, language, Math.max(300, Math.min(AGENT_LIMITS.modelMs, AGENT_LIMITS.deadlineMs - (Date.now() - t0))));
      extra = m.cards; modelOk = m.ok;
    }

    // validate: every evidence id must resolve under the user's JWT; otherwise the finding is dropped
    const all = [...rules, ...extra];
    const asked = [...new Map(all.flatMap((c) => c.evidence).map((e) => [evKey(e), { table: e.table, id: e.id }])).values()];
    const resolved = asked.length ? new Set(((await rpc('sana_evidence_resolve', { p_company: company, p_evidence: asked })) as Evidence[] ?? []).map(evKey)) : new Set<string>();
    const valid = all.filter((c) => c.evidence.length > 0 && c.evidence.every((e) => resolved.has(evKey(e))));
    const cards = rankCards(valid);

    let saved = true;
    try {
      const r = await rpc('sana_findings_save', { p_company: company, p_screen: screen, p_record_type: recordType, p_record_id: recordId,
        p_findings: cards, p_model: model && modelOk ? model.name : null, p_kind: mode }) as { ids: number[] };
      r.ids.forEach((id, i) => { if (cards[i]) cards[i].id = id; });
    } catch (e) {
      saved = false;   // the warnings still go back to the user; the failure is logged without content
      console.error('sana agent save failed', (e as { code?: string })?.code ?? 'error');
    }
    const base = { mode, company, record_type: recordType, record_id: recordId, checked: checks?.checked ?? [], saved,
      model: model ? model.name : null, model_used: modelOk, dropped: all.length - valid.length, ms: Date.now() - t0, ms_checks: msChecks };
    if (mode === 'line') {
      const top = cards[0];
      return { status: 200, json: { ...base, line: top ? top.title : null, finding_id: top?.id ?? null, severity: top?.severity ?? null } };
    }
    return { status: 200, json: { ...base, cards } };
  } catch (e) {
    const err = e as { status?: number; message?: string; code?: string };
    if (err.code === '42501' || err.status === 403) return fail(403, "You don't have access to that.");
    return fail(502, "Sana couldn't check this record right now. Try again in a moment.");
  }
}

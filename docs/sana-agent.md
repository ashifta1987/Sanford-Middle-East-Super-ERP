# SANA agent (S3)

Spec: `SANA AND UI UX UPADATE PROMPT/sana-agent-spec.md`. Prompt: `SANA AND UI UX UPADATE PROMPT/antigravity-S3-sana-agent.md`.
SANA moves from a question-and-answer assistant to an agent that reviews the record on screen. It proposes and never posts.
Phase 1 (this document) is the data model, the rules engine and the `now` / `line` modes. Phase 2 adds the panel tabs, the SANA
line and Apply. Phase 3 adds alerts and the 8 AM brief.

## Data model (`supabase/sql/46_sana_agent.sql`)

| Table | What it holds | Who reads it | Who writes it |
|---|---|---|---|
| `erp.sana_rule_default` | Rule parameters per country (AE, IN), written only by the SQL file | everyone signed in | migrations |
| `erp.sana_rule` | Rule parameters per company, seeded from the country (trigger on `erp.company`) | users of the company | `sana_rule_save` (full Administration), audited |
| `erp.sana_finding` | Cards shown to a user: severity, code, title, confidence, score, evidence, status | the user; the owner (business) for their companies | `sana_findings_save`, `sana_finding_decide` |
| `erp.sana_event_log` | Append-only: proposal, apply, ignore, answer, alert, line, now (+ before / after, evidence, model) | the user; the owner | the RPCs only; UPDATE / DELETE / TRUNCATE refused for everyone, even the table owner |
| `erp.sana_alert` | Alerts sent (phase 3), at most 5 per user per Dubai day (trigger + advisory lock) | the user; the owner | phase 3 job |
| `erp.sana_feedback` | Existing 👍/👎 table, now also for findings (`finding_id`, `correction`) | nobody directly (S1 rule) | RPCs |

IT and the system admin can edit rules, but they cannot read findings, alerts or the event log. This is the S1 rule: IT runs the
system and does not read sales or finance data.

Rules seeded today:

| Rule | AE | IN |
|---|---|---|
| VAT 5 % by tax code | on | off |
| TRN 15 digits | on | off |
| GST by HSN, GSTIN format, e-way bill above 50,000 | off | on |
| Cash receipt limit 2,00,000 (refuse) | off | on |
| Cash payment limit 10,000 (reason required) | off | on |
| MRP cap | off | on |
| MSME 45-day terms | off | on |
| Bills without GST visible to Admin and CA only | off | on |
| Credit limit (warn at 90 %) | on | on |
| Duplicate bill (score at least 70, within 90 days) | on | on |
| Licence / certificate expiry (30 days) | on | on |
| Masking | Emirates ID, passport, bank last 4 | Aadhaar, PAN, bank last 4 |

An Admin changes a threshold with `erp.sana_rule_save(company, rule, params, enabled)`. The checks use the new value straight away,
with no code change.

## Checks (`supabase/sql/47_sana_checks.sql`)

All checks are SECURITY INVOKER: they read with the caller's rights and return only what the caller may see. A switched-off rule,
or a role without the module, gives no rows. Each row is `(code, severity law|risk|info, message, evidence[], score)`. Evidence
is a list of `{table, id, label, link}` entries.

| RPC | Checks | Notes |
|---|---|---|
| `sana_check_tax(company, obj_type, doc_entry, draft?)` | unknown or inactive tax code, VAT ≠ rate × line, unusual rate | Tax codes are read through `_sana_tax_codes` (code, rate and active only), because `erp.tax_code` is readable by finance only |
| `sana_check_cash_limits(company, direction, doc_entry, draft?)` | IN cash receipt / payment limits | Needs finance or banking |
| `sana_check_mrp(…)` | MRP cap | Returns nothing: there is no MRP column yet (TODO) |
| `sana_check_credit(company, card_code, amount)` | over the limit, or near it | Customers only |
| `sana_check_duplicate_bill(company, doc_entry, draft?)` | same supplier within 90 days; score from reference (60), amount (30) and date (10) | The only check with a score (0–100) |
| `sana_check_licence_expiry(company, days?)` | `item_certificate.expires_on` | Needs inventory or purchasing |
| `sana_check_terms(company, card_code)` | MSME 45 days | Returns nothing: there is no MSME flag yet (TODO) |
| `sana_check_trn(company, card_code)` | AE TRN must be 15 digits | |
| `sana_checks(company, record_type, record_id, draft?)` | runs the checks that apply to one record, in one call | Also returns a short `record` summary for the model (never cost or supplier) |
| `sana_evidence_resolve(company, evidence)` | keeps only the evidence ids the caller can open | |
| `sana_can_see_cost()` | purchase, finance, inventory, or business (owner) | |

Record ids: a document is `obj_type:doc_entry`, a payment is `I:doc_entry` or `O:doc_entry`, a partner is its `card_code`, an item
is its `item_code`, and the home screen is `-`.

Dropped for our schema today (each TODO is in the code): GST by HSN and the MRP cap (no HSN or MRP columns), and MSME terms (no
MSME flag).

Import cost and supplier: `sana_document` and `sana_stock` (36) already strip cost unless `sana_has('finance','purchase','inventory')`,
and `sana_has` counts the business module, so the owner already sees cost. No change to 36 was needed. No SANA tool returns a
supplier field. `supabase/tests/sana_roles.sql` asserts that no tool output for sales, HR, staff or IT contains a cost or supplier
key. `sana-agent-e2e.mjs` runs 50 phrasings as the sales user and checks that none of the answers gives cost or supplier.

## `now` and `line` (Edge Function `sana`, `agent.ts`)

`POST { mode: 'now'|'line', company, record_type, record_id, screen?, language?, draft? }` with the user's token.

1. `sana_whoami`, `sana_status` and `sana_checks` run in parallel. This is the deterministic part, and it always runs first.
2. A record the role may not see (a document or partner with no summary) is refused: `denied: true`, with no cards and no counts.
3. For `now` only, the model is called once with the facts. The facts are masked by `mask.ts`: IBAN and bank accounts show only
   the last 4 digits; IDs, cards, passwords and OTPs are hidden. The call has a 2 s budget. If the model is missing, slow or
   failed, it is skipped and the rule cards still come back.
4. Every card is validated:
   - each evidence id must resolve under the user's token, or the card is dropped;
   - confidence must be likely, possible or check this;
   - percentages are removed unless a score was computed;
   - the model cannot raise a law warning or propose an action in phase 1.
5. The cards are ranked (law, then risk, then info; rules before model notes; higher score first). They are saved with
   `sana_findings_save`, which also writes one event log row, and returned. `line` returns the top card's title as one sentence.

`ask` is unchanged, including S4 streaming. With `detail: true` (the "Explain more" button in phase 2) the answer has five parts:
answer, facts with links, rule or SOP, what you can do now, check this.

## Apply path (phase 2, for reference)

Apply is a browser action. It calls the ERP's normal save or approval RPC for that action under the user's own session, with the
ERP's normal approval chain. Only on success does it call `sana_finding_decide(id, 'applied', before, after)`; on failure it shows
the ERP's error and never retries silently. Ignore calls `sana_finding_decide(id, 'ignored')`. No Edge Function writes a business
table.

## Tests

- `supabase/tests/sana_agent.sql`: rules, IN/AE cash limits, tax, credit, TRN, duplicate bill, licence expiry, dispatcher, cost
  visibility, evidence drop, RLS, decide, event log immutability, alert budget, rule edits, feedback (47 checks).
- `supabase/tests/sana_roles.sql`: plus no cost or supplier field for sales, HR, staff or IT, and cost visible for finance, owner,
  purchasing and inventory.
- `scripts/local-stack/sana-agent-e2e.mjs`: the masker on 200 sample documents, cleaning of model output, ranking, `now` p90 under
  3 s, deterministic results without a provider, `line`, refusal, the Done tab, AE cash, and the 50 phrasings.

Branch run (s3-phase1, 16 Nov 2026): 46 and 47 applied twice (safe to rerun); `sana_agent` 47/47, `sana_roles` 287/287,
`s1_sana` 61/61, `s2_sana_gemini` 64/64. `sana-agent-e2e --remote` 15/15, with `now` at p50 141 ms / p90 179 ms (no model on the
branch, by decision). Model timing is to be measured on live after go.


## Live (16 Nov 2026, go by Ashif)

Each file was run first in a transaction that was rolled back, then committed with an `erp.audit_log` row (`action = 'sql_apply'`).

| File | Dry run (rolled back) | Applied | Checks |
|---|---|---|---|
| 46_sana_agent.sql | 0.57 s | 1.12 s | 15 rules × AE01–AE05; 5 tables; event log: 2 triggers, no UPDATE for users; sana_feedback 0 rows, new PK (id), not readable by users |
| 47_sana_checks.sql | 0.46 s | 0.27 s | 12 check functions |

`sana` deployed with agent.ts, main pushed (5c65665), branch s3-phase1 deleted.

`now` with the real model (qa.finance, AE05, 10 calls each):

| Record | p50 | p90 | server p50 | checks p50 | model |
|---|---|---|---|---|---|
| purchase bill 18:22499 | 2,752 ms | 3,049 ms | 2,625 ms | 598 ms | timed out at the 2 s budget → rule cards only |
| sales invoice 13:166990 | 2,147 ms | 2,279 ms | 2,067 ms | 48 ms | used (1 model note) |

Follow-up (commit 99d2159, deploys with S4 steps 3–4): the model now gets what is left of a 2.5 s deadline (checks included), so
`now` stays under 3 s end to end. The duplicate-bill check takes about 0.6 s on AE05; an index for it would be a new SQL file (48)
and would need a go.

## Track B · what S4 leaves in place for Gemini Live (agreed 16 Nov 2026)

Gemini Live (ephemeral tokens) will be the main voice path. Steps 3–5 keep these six things in place for it:

1. **Checks stay separate from the model call.** The per-request server step (profile and role, the allowed tool list, settings and
   limits) stays apart from the model call. A Live session token is minted only after exactly these checks.
2. **Tools stay user-JWT RPCs.** Every tool stays an `erp.*` RPC called with the user's own token through the same allowed list.
   Live tool calls go through a small server relay, never straight from the browser to the database.
3. **Masking and filtering stay standalone.** The input masker (`mask.ts`) and the output filter (`redact` / `StreamRedactor` in
   core.ts) stay standalone functions, so the relay can apply them to Live transcripts.
4. **Logging stays after the reply.** `done` then `logged`, `sana_log`, the audit rows and `sana_timing_set` stay the same. A Live
   turn is logged the same way: the transcript is logged after the turn.
5. **The browser audio queue stays.** `speechQueue.ts` (Web Audio, buffers scheduled back to back, stop and clear) is the output
   layer, and it plays Live's 16-bit PCM like `pcm16`.
6. **Timing and quota stay per turn.** The Step 5 fields (ms_first_token, ms_first_audio, ms_total, model, voice engine and device)
   are recorded per Live turn. The voice budget (`TTS_DAILY_CAP`, moving to `erp.sana_settings`) becomes a Live-minutes budget per
   user.

## Rule · definer-rights helpers (agreed 17 Nov 2026)

SANA reads data with the user's own rights (SECURITY INVOKER, RLS). A SECURITY DEFINER helper is allowed for only two things:

1. **Key-only search.** `erp._sana_text_keys` (50) returns record keys (company + code, or obj_type + doc_entry), at most 50,
   from the caller's own companies (re-checked inside). The caller then reads the rows by key under its normal RLS and role rules.
2. **Counts.** `erp.sana_partner_counts` (51) returns numbers only: customers, suppliers and items by status, plus today's and
   this month's buyers and billers. It covers only the caller's companies, and only the parts the caller's role may see
   (`erp.sana_has`, read from the caller's token).

Definer helpers must **never** return row data (names, amounts, documents, people). Anything a user reads goes through
invoker functions and RLS. Both helpers exist for speed: under RLS, a text match (ILIKE, LIKE) cannot use an index, and every row
runs the access check one by one.

Later uses of the same two categories: `_sana_item_keys` / `_sana_item_similar` (52, item keys), `sana_finance_summary` stayed
invoker (55, an index was enough), `home_kpis` (56, counts and sums only, the RLS module rules checked once), and
`_my_companies` (57, the caller's company codes, used inside RLS policies).

## Rule · timers and page loads must be fast (agreed 17 Nov 2026)

**Anything that refreshes on a timer must return in under 1 s as admin on all companies.** This covers `refetchInterval`
queries, polling and the warm-up ping's targets. The same budget is the goal for the Home page, Control Tower and the Sana
panel on load. Check with the role that sees the most (admin or the owner, "All companies") on AE05-sized data before shipping.

Why: a slow timer query fails again every minute for everyone. The Home glance (56) and Control Tower (57) were each over 15 s
for admin, because RLS ran the company check `erp.can_see(company_code)` once per row.

How to stay under it:

- keep the company check out of the per-row path: policies use `company_code = ANY ((SELECT erp._my_companies())::varchar[])`
  (evaluated once per query, and an indexable equality) instead of `erp.can_see(company_code)`. 57 changed the five hottest
  tables; the other tables still use `can_see`;
- add partial indexes for the rows a check looks for (below minimum, discount above 5 %, below cost, non-SAP journals);
- use a definer helper only under the rule above (keys or counts, never row data);
- time it as admin, cfo and finance on AE05 and on all companies before it goes live.

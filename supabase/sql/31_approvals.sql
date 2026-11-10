-- =====================================================================
-- 31_approvals.sql  ·  B2 · Approval Management (Administration › Approval Process)
-- Run after 30_numbering_company.sql. Safe to run twice (IF NOT EXISTS, CREATE OR REPLACE, idempotent migration).
--
-- Decisions of 10 Nov 2026 §2 C3 and §3: approvals are configured in a separate SAP Business One style module.
--   Approval Stages     erp.apr_stage (+ apr_stage_authorizer: positions and/or users, required approvals / rejections)
--   Approval Templates  erp.apr_template per company and document kind (+ originators: positions and/or users,
--                       ordered stages, conditions with operators, active flag, version history apr_template_version)
--   Approval Status Report  approval_status_report(company, filter)
--
-- Every approval of A2–B1 now runs through the templates:
--   sales discount / credit limit / price below cost (17, 23, direct service invoices), A/R credit memo (14), journal (30),
--   outgoing payment amount and supplier bank change (46), NEW incoming payment (24), purchase order amount and price increase (22),
--   goods receipt / issue (59 / 60), stock count variance % and value (1470000065), BP credit limit and bank details (2),
--   company details (0, falls back to the owner position when no template is active).
--   Leave requests keep their built-in steps (line manager → HR approver → owner, HR Setup); they show as "built-in" here.
--   Rule evaluators (_sd_eval, _je_eval, _pay_eval, _pd_eval, _inv_eval, _count_eval, _md_rules, _sd_req_*) read
--   erp._apr_rules() instead of erp.approval_rule. Function names and messages are unchanged.
--
-- How a request moves (the rule for changes):
--   * On submit, each matching template adds one erp.approval row per stage (step = the stage's place in the template).
--     The row keeps the template (and its version), the stage and the stage's required approvals / rejections at that moment.
--     Changing a template (conditions, originators, stage list, deactivating it) only affects documents submitted afterwards.
--   * Who may decide a waiting row is read LIVE from the stage's authorizers: adding an authorizer to a stage lets that
--     person decide the requests already waiting at that stage; removing one stops them. Votes already cast stay counted.
--     A stage left without authorizers falls back to the company's owner position (admin_setting.owner_position).
--   * A stage closes when it has its required approvals (each person votes once); the required rejections reject the document.
--     Steps run in order: the lowest open step is decided first; the last approval completes the document.
--
-- Compatibility: erp.approval_rule and approval_rule_save / approval_rule_delete / approval_template_setup still work.
--   Each legacy rule chain (company, document, rule, requester position) is synchronised into one template (legacy_key).
--   Once a migrated template is edited in the Approval Templates screen, the legacy rows no longer drive it (legacy_sync off).
-- Existing ZZ99 SAMPLE rules are migrated by this file; nothing is seeded for AE01–AE05.
-- =====================================================================

-- ============ 1. Tables ============
CREATE TABLE IF NOT EXISTS erp.apr_stage (
    stage_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code        varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    name                text NOT NULL,
    description         text,
    required_approvals  smallint NOT NULL DEFAULT 1 CHECK (required_approvals BETWEEN 1 AND 20),
    required_rejections smallint NOT NULL DEFAULT 1 CHECK (required_rejections BETWEEN 1 AND 20),
    active              boolean NOT NULL DEFAULT true,
    source              text NOT NULL DEFAULT 'erp' CHECK (source IN ('erp', 'migrated', 'sample')),
    legacy_key          text,                                    -- 'pos:<position>' for stages made from approval_rule
    created_by          uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, name)
);
CREATE UNIQUE INDEX IF NOT EXISTS apr_stage_legacy_uniq ON erp.apr_stage (company_code, legacy_key) WHERE legacy_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS erp.apr_stage_authorizer (
    auth_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stage_id       bigint NOT NULL REFERENCES erp.apr_stage ON DELETE CASCADE,
    position_code  text REFERENCES erp.position,                 -- position_delete refuses while it is used here
    user_id        uuid REFERENCES erp.app_user ON DELETE CASCADE,
    CHECK (num_nonnulls(position_code, user_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS apr_stage_authorizer_uniq ON erp.apr_stage_authorizer (stage_id, (coalesce(position_code, '')), (coalesce(user_id::text, '')));

CREATE TABLE IF NOT EXISTS erp.apr_template (
    template_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    name           text NOT NULL,
    description    text,
    kind           text NOT NULL,                                -- erp._apr_kinds().kind (= approval_rule.rule_code + incoming_payment, company_details)
    obj_type       integer NOT NULL,
    active         boolean NOT NULL DEFAULT true,
    version        integer NOT NULL DEFAULT 1,
    source         text NOT NULL DEFAULT 'erp' CHECK (source IN ('erp', 'migrated', 'sample')),
    legacy_key     text,                                         -- 'rule:<obj>|<rule_code>|<position or *>'
    legacy_sync    boolean NOT NULL DEFAULT false,               -- true = still follows erp.approval_rule
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, name)
);
CREATE UNIQUE INDEX IF NOT EXISTS apr_template_legacy_uniq ON erp.apr_template (company_code, legacy_key) WHERE legacy_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS apr_template_kind_idx ON erp.apr_template (company_code, obj_type, kind) WHERE active;

CREATE TABLE IF NOT EXISTS erp.apr_template_originator (
    orig_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id    bigint NOT NULL REFERENCES erp.apr_template ON DELETE CASCADE,
    position_code  text REFERENCES erp.position,
    user_id        uuid REFERENCES erp.app_user ON DELETE CASCADE,
    CHECK (num_nonnulls(position_code, user_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS apr_template_originator_uniq ON erp.apr_template_originator (template_id, (coalesce(position_code, '')), (coalesce(user_id::text, '')));

CREATE TABLE IF NOT EXISTS erp.apr_template_stage (
    template_id    bigint NOT NULL REFERENCES erp.apr_template ON DELETE CASCADE,
    seq            smallint NOT NULL CHECK (seq BETWEEN 1 AND 9),
    stage_id       bigint NOT NULL REFERENCES erp.apr_stage,
    PRIMARY KEY (template_id, seq),
    UNIQUE (template_id, stage_id)
);

CREATE TABLE IF NOT EXISTS erp.apr_template_condition (
    template_id    bigint NOT NULL REFERENCES erp.apr_template ON DELETE CASCADE,
    cond_no        smallint NOT NULL,
    field          text NOT NULL,
    op             text NOT NULL CHECK (op IN ('gt', 'ge', 'lt', 'le', 'eq', 'ne', 'between', 'not_between')),
    value1         numeric(19,4) NOT NULL,
    value2         numeric(19,4),
    PRIMARY KEY (template_id, cond_no),
    CHECK (op NOT IN ('between', 'not_between') OR (value2 IS NOT NULL AND value2 >= value1))
);

CREATE TABLE IF NOT EXISTS erp.apr_template_version (
    template_id    bigint NOT NULL REFERENCES erp.apr_template ON DELETE CASCADE,
    version        integer NOT NULL,
    active         boolean NOT NULL,
    action         text NOT NULL,
    snapshot       jsonb NOT NULL,
    changed_by     uuid,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (template_id, version)
);

-- erp.approval: the template and stage a row was sent to (snapshot), and the stage's thresholds at submit time.
ALTER TABLE erp.approval
  ADD COLUMN IF NOT EXISTS template_id      bigint,
  ADD COLUMN IF NOT EXISTS template_version integer,
  ADD COLUMN IF NOT EXISTS template_name    text,
  ADD COLUMN IF NOT EXISTS stage_id         bigint,
  ADD COLUMN IF NOT EXISTS stage_name       text,
  ADD COLUMN IF NOT EXISTS need_approvals   smallint,
  ADD COLUMN IF NOT EXISTS need_rejections  smallint;
ALTER TABLE erp.approval ALTER COLUMN approver_position DROP NOT NULL;   -- a stage with only user authorizers / none
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'approval_template_fk') THEN
    ALTER TABLE erp.approval ADD CONSTRAINT approval_template_fk FOREIGN KEY (template_id) REFERENCES erp.apr_template ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'approval_stage_fk') THEN
    ALTER TABLE erp.approval ADD CONSTRAINT approval_stage_fk FOREIGN KEY (stage_id) REFERENCES erp.apr_stage ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS approval_stage_idx ON erp.approval (stage_id) WHERE decision IS NULL AND NOT superseded;

-- Each person's vote on an approval row (a stage may need several approvals).
CREATE TABLE IF NOT EXISTS erp.approval_vote (
    vote_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    approval_id    bigint NOT NULL REFERENCES erp.approval ON DELETE CASCADE,
    user_id        uuid NOT NULL REFERENCES erp.app_user,
    decision       text NOT NULL CHECK (decision IN ('approved', 'rejected')),
    note           text,
    voted_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (approval_id, user_id)
);

-- Incoming payments join the legacy rule catalogue too (approval_rule_save keeps working for every kind).
ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change',
                       'po_amount', 'po_price_increase', 'stock_doc_amount', 'count_variance_pct', 'count_variance_value',
                       'bp_credit_limit', 'bp_bank_detail', 'credit_memo_amount', 'incoming_payment'));

-- ============ Read access (writes only through the functions below) ============
ALTER TABLE erp.apr_stage ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_stage_authorizer ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_template_originator ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_template_stage ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_template_condition ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.apr_template_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.approval_vote ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.apr_stage, erp.apr_stage_authorizer, erp.apr_template, erp.apr_template_originator, erp.apr_template_stage,
  erp.apr_template_condition, erp.apr_template_version, erp.approval_vote FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.apr_stage, erp.apr_stage_authorizer, erp.apr_template, erp.apr_template_originator, erp.apr_template_stage,
  erp.apr_template_condition, erp.apr_template_version, erp.approval_vote TO authenticated;
DROP POLICY IF EXISTS apr_stage_read ON erp.apr_stage;
CREATE POLICY apr_stage_read ON erp.apr_stage FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS apr_stage_authorizer_read ON erp.apr_stage_authorizer;
CREATE POLICY apr_stage_authorizer_read ON erp.apr_stage_authorizer FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.apr_stage s WHERE s.stage_id = apr_stage_authorizer.stage_id AND erp.can_see(s.company_code)));
DROP POLICY IF EXISTS apr_template_read ON erp.apr_template;
CREATE POLICY apr_template_read ON erp.apr_template FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS apr_template_originator_read ON erp.apr_template_originator;
CREATE POLICY apr_template_originator_read ON erp.apr_template_originator FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.apr_template t WHERE t.template_id = apr_template_originator.template_id AND erp.can_see(t.company_code)));
DROP POLICY IF EXISTS apr_template_stage_read ON erp.apr_template_stage;
CREATE POLICY apr_template_stage_read ON erp.apr_template_stage FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.apr_template t WHERE t.template_id = apr_template_stage.template_id AND erp.can_see(t.company_code)));
DROP POLICY IF EXISTS apr_template_condition_read ON erp.apr_template_condition;
CREATE POLICY apr_template_condition_read ON erp.apr_template_condition FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.apr_template t WHERE t.template_id = apr_template_condition.template_id AND erp.can_see(t.company_code)));
DROP POLICY IF EXISTS apr_template_version_read ON erp.apr_template_version;
CREATE POLICY apr_template_version_read ON erp.apr_template_version FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.apr_template t WHERE t.template_id = apr_template_version.template_id AND erp.can_see(t.company_code)));
DROP POLICY IF EXISTS approval_vote_read ON erp.approval_vote;
CREATE POLICY approval_vote_read ON erp.approval_vote FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.approval a WHERE a.approval_id = approval_vote.approval_id AND erp.can_see(a.company_code)));

-- ============ 2. Catalogue: what each document kind supports ============
-- fields: the conditions a template of this kind may use (unit pct | amount | days; line = checked per document line).
-- primary_field / primary_op: the classic limit (what the A2–B1 rules compared); messages keep their old wording for it.
CREATE OR REPLACE FUNCTION erp._apr_kinds()
RETURNS TABLE (kind text, obj_types integer[], module text, label text, sort integer, built_in boolean, primary_field text, primary_op text, fields jsonb)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('discount_pct', ARRAY[17], 'sales', 'Sales discount (quotations, orders, direct service invoices)', 1, false, 'discount_pct', 'gt',
       '[{"field":"discount_pct","unit":"pct","line":true},{"field":"doc_total","unit":"amount"}]'::jsonb),
    ('credit_limit', ARRAY[17], 'sales', 'Customer over the credit limit (sales orders)', 2, false, NULL, NULL,
       '[{"field":"credit_over","unit":"amount"},{"field":"doc_total","unit":"amount"}]'::jsonb),
    ('below_cost', ARRAY[17], 'sales', 'Net price below cost (quotations and orders)', 3, false, NULL, NULL,
       '[{"field":"below_cost_pct","unit":"pct","line":true},{"field":"doc_total","unit":"amount"}]'::jsonb),
    ('credit_memo_amount', ARRAY[14], 'sales', 'A/R credit memo', 4, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('po_amount', ARRAY[22], 'purchasing', 'Purchase order total', 5, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('po_price_increase', ARRAY[22], 'purchasing', 'Purchase price above the last price', 6, false, 'increase_pct', 'gt',
       '[{"field":"increase_pct","unit":"pct","line":true},{"field":"amount","unit":"amount"}]'::jsonb),
    ('incoming_payment', ARRAY[24], 'banking', 'Incoming payment', 7, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('payment_amount', ARRAY[46], 'banking', 'Outgoing payment', 8, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('bank_change', ARRAY[46], 'banking', 'Outgoing payment after a supplier bank change', 9, false, 'days_since_change', 'le',
       '[{"field":"days_since_change","unit":"days"},{"field":"amount","unit":"amount"}]'::jsonb),
    ('journal_amount', ARRAY[30], 'financials', 'Journal entry', 10, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('stock_doc_amount', ARRAY[59, 60], 'inventory', 'Goods receipt / goods issue', 11, false, 'amount', 'gt', '[{"field":"amount","unit":"amount"}]'::jsonb),
    ('count_variance_pct', ARRAY[1470000065], 'inventory', 'Stock count variance % (per line)', 12, false, 'variance_pct', 'gt',
       '[{"field":"variance_pct","unit":"pct","line":true}]'::jsonb),
    ('count_variance_value', ARRAY[1470000065], 'inventory', 'Stock count variance value', 13, false, 'variance_value', 'gt',
       '[{"field":"variance_value","unit":"amount"}]'::jsonb),
    ('bp_credit_limit', ARRAY[2], 'bp', 'Business partner credit limit change', 14, false, NULL, NULL, '[]'::jsonb),
    ('bp_bank_detail', ARRAY[2], 'bp', 'Business partner bank details change', 15, false, NULL, NULL, '[]'::jsonb),
    ('company_details', ARRAY[0], 'admin', 'Company details change', 16, false, NULL, NULL, '[]'::jsonb),
    ('leave', ARRAY[171], 'hr', 'Leave request (built-in: line manager, HR approver, owner — HR Setup)', 17, true, NULL, NULL, '[]'::jsonb)
  ) AS v(kind, obj_types, module, label, sort, built_in, primary_field, primary_op, fields)
$$;

CREATE OR REPLACE FUNCTION erp._apr_kind_label(p_kind text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT k.label FROM erp._apr_kinds() k WHERE k.kind = p_kind),
                  CASE WHEN p_kind LIKE 'leave%' THEN 'Leave request (built-in)' ELSE p_kind END)
$$;

-- Short kind names (template names made from the earlier rules).
CREATE OR REPLACE FUNCTION erp._apr_kind_short(p_kind text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_kind WHEN 'discount_pct' THEN 'Sales discount' WHEN 'credit_limit' THEN 'Credit limit' WHEN 'below_cost' THEN 'Below cost'
                     WHEN 'credit_memo_amount' THEN 'Credit memo' WHEN 'po_amount' THEN 'Purchase order total' WHEN 'po_price_increase' THEN 'Purchase price increase'
                     WHEN 'incoming_payment' THEN 'Incoming payment' WHEN 'payment_amount' THEN 'Outgoing payment' WHEN 'bank_change' THEN 'Supplier bank change'
                     WHEN 'journal_amount' THEN 'Journal entry' WHEN 'stock_doc_amount' THEN 'Goods receipt / issue' WHEN 'count_variance_pct' THEN 'Count variance %'
                     WHEN 'count_variance_value' THEN 'Count variance value' WHEN 'bp_credit_limit' THEN 'BP credit limit' WHEN 'bp_bank_detail' THEN 'BP bank details'
                     WHEN 'company_details' THEN 'Company details' ELSE p_kind END
$$;

CREATE OR REPLACE FUNCTION erp._apr_field_label(p_field text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_field WHEN 'discount_pct' THEN 'discount %' WHEN 'doc_total' THEN 'document total' WHEN 'credit_over' THEN 'amount over the credit limit'
                      WHEN 'below_cost_pct' THEN '% below cost' WHEN 'amount' THEN 'amount' WHEN 'days_since_change' THEN 'days since the bank change'
                      WHEN 'increase_pct' THEN 'price increase %' WHEN 'variance_pct' THEN 'variance %' WHEN 'variance_value' THEN 'variance value'
                      ELSE p_field END
$$;

-- ============ 3. Engine ============
-- One condition: value v against op / a / b.
CREATE OR REPLACE FUNCTION erp._apr_test(p_op text, v numeric, a numeric, b numeric) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN v IS NULL THEN false ELSE CASE p_op
    WHEN 'gt' THEN v > a WHEN 'ge' THEN v >= a WHEN 'lt' THEN v < a WHEN 'le' THEN v <= a WHEN 'eq' THEN v = a WHEN 'ne' THEN v <> a
    WHEN 'between' THEN v BETWEEN a AND b WHEN 'not_between' THEN v NOT BETWEEN a AND b ELSE false END END
$$;

-- All conditions hold (no condition = always). A condition whose field the document does not give never holds.
CREATE OR REPLACE FUNCTION erp._apr_hit(p_conds jsonb, p_facts jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(bool_and(p_facts ? (c->>'field')
                           AND erp._apr_test(c->>'op', (p_facts->>(c->>'field'))::numeric, (c->>'value1')::numeric, (c->>'value2')::numeric)), true)
    FROM jsonb_array_elements(coalesce(p_conds, '[]'::jsonb)) c
$$;

-- "discount % > 10 and document total ≥ 5,000.00"
CREATE OR REPLACE FUNCTION erp._apr_cond_text(p_conds jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT string_agg(erp._apr_field_label(c->>'field') || ' ' ||
           CASE c->>'op' WHEN 'gt' THEN '> ' WHEN 'ge' THEN '≥ ' WHEN 'lt' THEN '< ' WHEN 'le' THEN '≤ ' WHEN 'eq' THEN '= ' WHEN 'ne' THEN '≠ '
                         WHEN 'between' THEN 'between ' ELSE 'not between ' END ||
           trim_scale((c->>'value1')::numeric)::text ||
           CASE WHEN c->>'op' IN ('between', 'not_between') THEN ' and ' || trim_scale((c->>'value2')::numeric)::text ELSE '' END,
         ' and ' ORDER BY ord)
    FROM jsonb_array_elements(coalesce(p_conds, '[]'::jsonb)) WITH ORDINALITY AS x(c, ord)
$$;

-- Message for a template whose conditions differ from the classic limit.
CREATE OR REPLACE FUNCTION erp._apr_msg(p_prefix text, p_template text, p_conds jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT format('%sneeds approval under template "%s"%s.', coalesce(p_prefix, ''), p_template,
                CASE WHEN jsonb_array_length(coalesce(p_conds, '[]'::jsonb)) = 0 THEN '' ELSE ' (' || erp._apr_cond_text(p_conds) || ')' END)
$$;

-- The requester whose originator rights count: erp.apr_user when set, else the signed-in user when their position is p_position.
CREATE OR REPLACE FUNCTION erp._apr_user_for(p_position text) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN nullif(current_setting('erp.apr_user', true), '') IS NOT NULL THEN current_setting('erp.apr_user', true)::uuid
              ELSE (SELECT u.user_id FROM erp.app_user u WHERE u.user_id = erp.current_user_id() AND u.position_code IS NOT DISTINCT FROM p_position) END
$$;

-- Who decides at a stage, as text ("Finance Manager or Ali Qasim"). No authorizer: the owner position.
CREATE OR REPLACE FUNCTION erp._apr_stage_who(p_stage bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(
    (SELECT string_agg(coalesce(p.name, u.display_name), ' or ' ORDER BY a.position_code IS NULL, coalesce(p.name, u.display_name))
       FROM erp.apr_stage_authorizer a LEFT JOIN erp.position p ON p.position_code = a.position_code LEFT JOIN erp.app_user u ON u.user_id = a.user_id
      WHERE a.stage_id = p_stage),
    (SELECT p.name FROM erp.apr_stage s JOIN erp.admin_setting st ON st.company_code = s.company_code JOIN erp.position p ON p.position_code = st.owner_position
      WHERE s.stage_id = p_stage))
$$;

-- The position recorded on the approval row (display and legacy readers): first position authorizer, else the first user's
-- position, else the owner position.
CREATE OR REPLACE FUNCTION erp._apr_rep(p_stage bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(
    (SELECT a.position_code FROM erp.apr_stage_authorizer a WHERE a.stage_id = p_stage AND a.position_code IS NOT NULL ORDER BY a.auth_id LIMIT 1),
    (SELECT u.position_code FROM erp.apr_stage_authorizer a JOIN erp.app_user u ON u.user_id = a.user_id WHERE a.stage_id = p_stage ORDER BY a.auth_id LIMIT 1),
    (SELECT st.owner_position FROM erp.apr_stage s JOIN erp.admin_setting st ON st.company_code = s.company_code WHERE s.stage_id = p_stage))
$$;

-- The approval steps active templates ask for: one row per (template, stage). Same shape for every evaluator:
--   rule_code (= template kind), step (= the stage's place), approver_position / approver_name (display), limit_value (the classic limit),
--   conds (all conditions), std (the template is just the classic limit, so the old message applies), template / stage, ck (base check jsonb).
CREATE OR REPLACE FUNCTION erp._apr_rules(p_company varchar, p_obj integer, p_kinds text[], p_position text)
RETURNS TABLE (rule_code text, step smallint, approver_position text, approver_name text, limit_value numeric, conds jsonb, std boolean,
               template_id bigint, template_name text, stage_id bigint, stage_name text, ck jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH me AS (SELECT erp._apr_user_for(p_position) AS uid),
  t AS (
    SELECT t.template_id, t.name, t.kind, k.primary_field, k.primary_op,
           coalesce((SELECT jsonb_agg(jsonb_build_object('field', c.field, 'op', c.op, 'value1', c.value1, 'value2', c.value2) ORDER BY c.cond_no)
                       FROM erp.apr_template_condition c WHERE c.template_id = t.template_id), '[]'::jsonb) AS conds
      FROM erp.apr_template t JOIN erp._apr_kinds() k ON k.kind = t.kind
     WHERE t.company_code = p_company AND t.obj_type = p_obj AND t.kind = ANY (p_kinds) AND t.active
       AND (NOT EXISTS (SELECT 1 FROM erp.apr_template_originator o WHERE o.template_id = t.template_id)
            OR EXISTS (SELECT 1 FROM erp.apr_template_originator o, me
                        WHERE o.template_id = t.template_id AND (o.position_code = p_position OR o.user_id = me.uid))))
  SELECT t.kind, ts.seq, x.rep, x.who, lim.v, t.conds, z.std, t.template_id, t.name, s.stage_id, s.name,
         jsonb_build_object('rule_code', t.kind, 'step', ts.seq, 'approver_position', x.rep, 'approver_name', x.who,
                            'template_id', t.template_id, 'template_name', t.name, 'stage_id', s.stage_id, 'stage_name', s.name)
    FROM t
    JOIN erp.apr_template_stage ts ON ts.template_id = t.template_id
    JOIN erp.apr_stage s ON s.stage_id = ts.stage_id
    CROSS JOIN LATERAL (SELECT erp._apr_rep(s.stage_id) AS rep, erp._apr_stage_who(s.stage_id) AS who) x
    CROSS JOIN LATERAL (SELECT (SELECT (c->>'value1')::numeric FROM jsonb_array_elements(t.conds) c WHERE c->>'field' = t.primary_field LIMIT 1) AS v) lim
    CROSS JOIN LATERAL (SELECT coalesce(jsonb_array_length(t.conds) = 1 AND t.conds->0->>'field' = t.primary_field
                                        AND t.conds->0->>'op' = t.primary_op, false) AS std) z
   ORDER BY ts.seq, t.kind, t.template_id
$$;

-- The caller's classic limit for a kind (the lowest one of the templates that cover them), for form hints.
CREATE OR REPLACE FUNCTION erp._apr_my_limit(p_company varchar, p_obj integer, p_kind text, p_position text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT min(r.limit_value) FROM erp._apr_rules(p_company, p_obj, ARRAY[p_kind], p_position) r
$$;

-- Fill the template / stage snapshot when an evaluator's check carries them (detail.checks[0]).
CREATE OR REPLACE FUNCTION erp._apr_fill() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c jsonb := NEW.detail->'checks'->0;
  t erp.apr_template;
  s erp.apr_stage;
BEGIN
  IF NEW.stage_id IS NULL AND jsonb_typeof(c) = 'object' AND nullif(c->>'stage_id', '') IS NOT NULL THEN
    SELECT * INTO s FROM erp.apr_stage WHERE stage_id = (c->>'stage_id')::bigint;
    SELECT * INTO t FROM erp.apr_template WHERE template_id = nullif(c->>'template_id', '')::bigint;
    IF s.stage_id IS NOT NULL THEN
      NEW.stage_id := s.stage_id;
      NEW.stage_name := s.name;
      NEW.need_approvals := s.required_approvals;
      NEW.need_rejections := s.required_rejections;
      NEW.template_id := t.template_id;
      NEW.template_version := t.version;
      NEW.template_name := t.name;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apr_fill ON erp.approval;
CREATE TRIGGER apr_fill BEFORE INSERT ON erp.approval FOR EACH ROW EXECUTE FUNCTION erp._apr_fill();

-- Is (user, position) an authorizer of the stage right now? A stage without authorizers: the owner position.
CREATE OR REPLACE FUNCTION erp._apr_authorizer(p_stage bigint, p_user uuid, p_position text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.apr_stage_authorizer a WHERE a.stage_id = p_stage AND (a.user_id = p_user OR a.position_code = p_position))
      OR (NOT EXISTS (SELECT 1 FROM erp.apr_stage_authorizer a WHERE a.stage_id = p_stage)
          AND p_position IS NOT NULL
          AND p_position = (SELECT st.owner_position FROM erp.apr_stage s JOIN erp.admin_setting st ON st.company_code = s.company_code WHERE s.stage_id = p_stage))
$$;

-- May this user decide this (open) row now? Rows sent before B2 (no stage) keep the position rule (and A9's for_user).
-- A person votes once per row.
CREATE OR REPLACE FUNCTION erp._apr_is_mine(p_id bigint, u erp.app_user) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((
    SELECT CASE WHEN a.stage_id IS NULL
                THEN a.approver_position = u.position_code AND (a.detail->>'for_user' IS NULL OR a.detail->>'for_user' = u.user_id::text)
                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) END
           AND NOT EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.user_id = u.user_id)
      FROM erp.approval a WHERE a.approval_id = p_id), false)
$$;

-- Is this user one of the row's approvers (now or as the one who decided)? Used for "the creator or an approver may cancel".
CREATE OR REPLACE FUNCTION erp._apr_can_act(p_id bigint, u erp.app_user) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((
    SELECT a.approver_user = u.user_id
        OR EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.user_id = u.user_id)
        OR CASE WHEN a.stage_id IS NULL THEN a.approver_position = u.position_code
                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) END
      FROM erp.approval a WHERE a.approval_id = p_id), false)
$$;

-- Record the user's vote on their rows of the current step. A row closes when its stage has the required approvals
-- (decision approved) or rejections (decision rejected). Returns 'rejected' (a row was rejected), 'approved' (all the
-- user's rows closed approved) or 'pending' (more votes needed).
CREATE OR REPLACE FUNCTION erp._apr_vote(p_ids bigint[], u erp.app_user, p_decision text, p_note text, p_extra jsonb DEFAULT '{}'::jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a     erp.approval;
  v_ok  integer;
  v_no  integer;
  v_rej boolean := false;
  v_open boolean := false;
BEGIN
  FOR a IN SELECT * FROM erp.approval WHERE approval_id = ANY (p_ids) ORDER BY approval_id FOR UPDATE LOOP
    CONTINUE WHEN a.decision IS NOT NULL OR a.superseded;
    BEGIN
      INSERT INTO erp.approval_vote (approval_id, user_id, decision, note) VALUES (a.approval_id, u.user_id, p_decision, p_note);
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'You have already decided this step. Another authorizer has to decide it now.' USING ERRCODE = 'P0001';
    END;
    SELECT count(*) FILTER (WHERE decision = 'approved'), count(*) FILTER (WHERE decision = 'rejected') INTO v_ok, v_no
      FROM erp.approval_vote WHERE approval_id = a.approval_id;
    IF p_decision = 'rejected' AND v_no >= coalesce(a.need_rejections, 1) THEN
      UPDATE erp.approval SET decision = 'rejected', approver_user = u.user_id, decided_at = now(), note = p_note,
                              detail = coalesce(detail, '{}'::jsonb) || coalesce(p_extra, '{}'::jsonb)
       WHERE approval_id = a.approval_id;
      v_rej := true;
    ELSIF p_decision = 'approved' AND v_ok >= coalesce(a.need_approvals, 1) THEN
      UPDATE erp.approval SET decision = 'approved', approver_user = u.user_id, decided_at = now(), note = p_note,
                              detail = coalesce(detail, '{}'::jsonb) || coalesce(p_extra, '{}'::jsonb)
       WHERE approval_id = a.approval_id;
    ELSE
      v_open := true;
    END IF;
  END LOOP;
  RETURN CASE WHEN v_rej THEN 'rejected' WHEN v_open THEN 'pending' ELSE 'approved' END;
END $$;

-- Who may decide the open rows of a step, as text (for "waiting for approval from …").
CREATE OR REPLACE FUNCTION erp._apr_who(p_company varchar, p_object text, p_ref text, p_step smallint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT string_agg(DISTINCT w, ' or ') FROM (
    SELECT CASE WHEN a.stage_id IS NOT NULL THEN erp._apr_stage_who(a.stage_id) ELSE p.name END AS w
      FROM erp.approval a LEFT JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref AND a.decision IS NULL AND NOT a.superseded AND a.step = p_step) s
$$;

-- Display name of who decides a row: the stage's authorizers, else the position (p_default).
CREATE OR REPLACE FUNCTION erp._apr_row_who(p_id bigint, p_default text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT erp._apr_stage_who(a.stage_id) FROM erp.approval a WHERE a.approval_id = p_id AND a.stage_id IS NOT NULL), p_default)
$$;

-- The votes cast on a row.
CREATE OR REPLACE FUNCTION erp._apr_votes(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_name', u.display_name, 'decision', v.decision, 'note', v.note, 'at', v.voted_at) ORDER BY v.voted_at, v.vote_id), '[]'::jsonb)
    FROM erp.approval_vote v LEFT JOIN erp.app_user u ON u.user_id = v.user_id
   WHERE v.approval_id = p_id
$$;

-- The approval trail of one object (template, stage, who, votes) – shown on document pages and the status report.
CREATE OR REPLACE FUNCTION erp._apr_trail(p_company varchar, p_object text, p_ref text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH cur AS (SELECT min(step) AS s FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code,
           'template_name', coalesce(a.template_name, erp._apr_kind_label(a.rule_code)), 'template_id', a.template_id, 'template_version', a.template_version,
           'stage_name', coalesce(a.stage_name, p.name), 'stage_id', a.stage_id,
           'who', CASE WHEN a.stage_id IS NOT NULL THEN erp._apr_stage_who(a.stage_id) ELSE p.name END,
           'need_approvals', coalesce(a.need_approvals, 1), 'need_rejections', coalesce(a.need_rejections, 1),
           'approvals', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'approved'),
           'rejections', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'rejected'),
           'votes', erp._apr_votes(a.approval_id), 'decision', a.decision, 'decided_at', a.decided_at,
           'decided_by_name', du.display_name, 'note', a.note, 'superseded', a.superseded,
           'current', a.decision IS NULL AND NOT a.superseded AND a.step = (SELECT s FROM cur)) ORDER BY a.step, a.approval_id), '[]'::jsonb)
    FROM erp.approval a
    LEFT JOIN erp.position p ON p.position_code = a.approver_position
    LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
   WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref
$$;

-- ============ 4. Evaluators, decisions and document pages (copied from A2–B1, now reading the templates) ============
-- ---- _je_eval: copied from 18_posting.sql:511
-- Validate a manual journal (header + lines) and the approval rules it triggers. Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    lines:[…], header:{…}, totals:{debit, credit, difference, currency}}
-- Errors with field 'period' or 'balance' do not stop a draft from being saved; they stop posting.
CREATE OR REPLACE FUNCTION erp._je_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_position text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_err   jsonb := '[]';
  v_checks jsonb := '[]';
  e       jsonb;
  v_cur   text;
  v_date  date;
  v_due   date;
  v_msg   text;
  v_d     numeric;
  v_c     numeric;
  r       record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF nullif(btrim(h->>'ref_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'ref_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'ref_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'ref_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The due date is not a valid date.');
    END IF;
  END IF;

  e := erp._je_lines_eval(p_company, p_lines, false);
  v_err := v_err || (e->'errors');
  IF (e->>'count')::integer < 2 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least two lines.');
  END IF;
  v_d := (e->>'debit')::numeric;
  v_c := (e->>'credit')::numeric;

  -- Posting-only problems (a draft may still be saved with them)
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'period', 'message', v_msg);
  END IF;
  IF v_d <> v_c THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'balance', 'message',
      format('Debits %s and credits %s don''t balance. Difference %s %s.', erp._money(v_d), erp._money(v_c), erp._money(abs(v_d - v_c)), v_cur));
  END IF;

  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 30, ARRAY['journal_amount'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_d)) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', v_d, 'limit', r.limit_value,
          'message', CASE WHEN r.std THEN format('Total %s %s is above your journal limit of %s %s. Submit it for approval.',
                                                 erp._money(v_d), v_cur, erp._money(r.limit_value), v_cur)
                          ELSE erp._apr_msg(format('Total %s %s: ', erp._money(v_d), v_cur), r.template_name, r.conds) END));
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', e->'lines',
    'header', jsonb_build_object('ref_date', v_date, 'due_date', v_due, 'memo', nullif(btrim(h->>'memo'), ''),
                                 'ref1', nullif(btrim(h->>'ref1'), ''), 'ref2', nullif(btrim(h->>'ref2'), '')),
    'totals', jsonb_build_object('debit', v_d, 'credit', v_c, 'difference', v_d - v_c, 'currency', v_cur));
END $$;

-- ---- _sd_eval: copied from 19_sales_cycle.sql:219
-- Validate, price and check one quotation (23) or order (17). Never writes. Same result shape as A2's _so_eval, plus:
--   lines[].base_obj_type/base_doc_entry/base_line (copied from a quotation), lines[].atp {available, date, rule_code},
--   atp:[{line, item_code, whs_code, qty, available, date, message}] (orders only: what is promised beyond ATP).
-- Quotations use the order's discount and below-cost rules (approval_rule obj_type 17); the credit rule is for orders only.
CREATE OR REPLACE FUNCTION erp._sd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_atp    jsonb := '[]';
  v_credit jsonb;
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  v_doc_date date;
  v_due    date;
  v_pl     integer;
  v_terms  integer;
  v_slp    integer;
  v_whs    text;
  v_branch integer;
  v_def_tax text;
  v_def_whs text;
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_item_ok boolean;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_disc   numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_ok     boolean;
  v_cost   numeric;
  v_avail  numeric;
  v_sb_cost numeric;
  v_gross  numeric := 0;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_lt     numeric;
  v_lv     numeric;
  r        record;
  x        record;
  v_open   numeric;
  v_exposure numeric;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  v_atpd   date;
  ar       erp.atp_rule;
  v_a      jsonb;
  v_used   jsonb := '{}'::jsonb;    -- item|whs → quantity already promised by earlier lines of this order
  v_key    text;
  v_prev   numeric;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT default_tax_code, default_whs_code INTO v_def_tax, v_def_whs FROM erp.sales_setting WHERE company_code = p_company;

  -- Customer
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a customer.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'customer' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a customer. Choose a customer.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is inactive. Choose an active customer.', v_card));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is billed in %s. Orders in a foreign currency come in a later stage.', v_card, bp.currency));
    ELSE
      v_bp_ok := true;
      bp.balance := coalesce(bp.balance, 0) + coalesce((SELECT b.balance FROM erp.bp_balance_erp b WHERE b.company_code = p_company AND b.card_code = v_card), 0);
    END IF;
  END IF;

  -- Dates
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_doc_date := erp._date(h->>'doc_date');
    IF v_doc_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date is not a valid date.' ELSE 'The delivery date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date can''t be before the posting date.' ELSE 'The delivery date can''t be before the posting date.' END);
    END IF;
  END IF;

  -- Price list, payment terms, salesperson: the header value, else the customer's own
  v_pl := coalesce(erp._num(h->>'price_list')::integer, CASE WHEN v_bp_ok THEN bp.price_list END);
  IF v_pl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.price_list WHERE company_code = p_company AND list_num = v_pl) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'price_list', 'message', format('Price list %s does not exist.', v_pl));
  END IF;
  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;
  v_slp := coalesce(erp._num(h->>'slp_code')::integer, CASE WHEN v_bp_ok THEN bp.slp_code END);
  IF v_slp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.salesperson WHERE company_code = p_company AND slp_code = v_slp) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'slp_code', 'message', format('Salesperson %s does not exist.', v_slp));
  END IF;

  -- Header warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), v_def_whs);
  IF v_whs IS NOT NULL THEN
    SELECT branch_id INTO v_branch FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist in company %s.', v_whs, p_company));
    ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is inactive. Choose another warehouse.', v_whs));
    END IF;
  END IF;
  v_atpd := coalesce(v_due, v_doc_date);

  -- Lines
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one line.');
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_item_ok := false;
    v_code := nullif(btrim(l->>'item_code'), '');
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'choose an item.');
      v_ok := false;
    ELSE
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('item %s does not exist. Check the item code.', v_code));
        v_ok := false;
      ELSIF NOT it.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is inactive. Choose an active item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_sold, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a sales item.', v_code));
        v_ok := false;
      ELSE
        v_item_ok := true;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_disc := CASE WHEN nullif(btrim(l->>'discount_pct'), '') IS NULL THEN 0 ELSE erp._num(l->>'discount_pct') END;
    IF v_disc IS NULL OR v_disc < 0 OR v_disc > 100 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'discount_pct', 'message', n || 'discount must be between 0 and 100%.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose a warehouse.');
      v_ok := false;
    ELSIF v_lwhs IS DISTINCT FROM v_whs THEN
      IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist in company %s.', v_lwhs, p_company));
        v_ok := false;
      ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s is inactive. Choose another warehouse.', v_lwhs));
        v_ok := false;
      END IF;
    END IF;

    v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), v_def_tax);
    v_tc := NULL;
    IF v_tax IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || 'choose a tax code.');
      v_ok := false;
    ELSE
      SELECT * INTO v_tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s does not exist.', v_tax));
        v_ok := false;
      ELSIF NOT v_tc.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is inactive.', v_tax));
        v_ok := false;
      ELSIF v_tc.category = 'I' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for purchases. Choose a sales tax code.', v_tax));
        v_ok := false;
      END IF;
    END IF;

    v_price := NULL;
    IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
      v_price := erp._num(l->>'price');
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
        v_ok := false;
      ELSIF v_price < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
        v_ok := false;
      END IF;
    ELSIF v_item_ok AND v_pl IS NULL AND NOT v_bp_ok THEN
      v_ok := false;   -- no valid customer yet, so no price list to price from (the customer problem is already listed)
    ELSIF v_item_ok THEN
      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = v_pl AND item_code = v_code;
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has no price in the customer''s price list. Enter a price.', v_code));
        v_ok := false;
      END IF;
    END IF;

    -- Copied from a quotation: the quotation must be a Super ERP one, open, for this customer and item, with enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF p_obj <> 17 OR coalesce(v_bobj, 0) <> 23 OR v_bentry IS NULL OR v_bline IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'only a sales order can be copied from a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s was not found in company %s.', v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s came from %s. Only Super ERP quotations can be copied.',
            v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s is not open, so it can''t be copied.', v_bno));
          v_ok := false;
        ELSIF bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is for customer %s. Copy it to an order for the same customer.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of quotation %s.', v_bline + 1, v_bno));
          v_ok := false;
        ELSIF v_qty IS NOT NULL AND v_qty > coalesce(bl.open_qty, 0) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on quotation %s.', trim_scale(coalesce(bl.open_qty, 0)), v_code, v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      SELECT sb.avg_cost, sb.on_hand - sb.committed INTO v_sb_cost, v_avail
        FROM erp.stock_balance sb WHERE sb.company_code = p_company AND sb.item_code = v_code AND sb.whs_code = v_lwhs;
      IF NOT FOUND THEN v_sb_cost := NULL; v_avail := NULL; END IF;
      v_cost := coalesce(v_sb_cost, it.avg_cost);
      v_lt := round(v_qty * v_price * (1 - v_disc / 100), 2);
      v_lv := round(v_lt * v_tc.rate / 100, 2);
      v_gross := v_gross + round(v_qty * v_price, 2);
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;

      -- Available-to-Promise (orders, stock items, when the company has an ATP rule for the item)
      v_a := NULL;
      IF p_obj = 17 AND coalesce(it.is_stock, false) AND v_atpd IS NOT NULL THEN
        ar := erp._atp_rule(p_company, v_code);
        IF ar.rule_id IS NOT NULL THEN
          v_a := erp._atp(p_company, v_code, v_lwhs, v_atpd, ar);
          IF NOT (v_a->>'no_check')::boolean THEN
            v_key := v_code || '|' || CASE WHEN ar.whs_scope = 'all_whs' THEN '*' ELSE v_lwhs END;
            v_prev := coalesce((v_used->>v_key)::numeric, 0);
            v_used := v_used || jsonb_build_object(v_key, v_prev + v_qty);
            IF v_prev + v_qty > (v_a->>'available')::numeric THEN
              v_atp := v_atp || jsonb_build_object('line', i, 'item_code', v_code, 'whs_code', v_lwhs, 'qty', v_prev + v_qty,
                'available', (v_a->>'available')::numeric, 'date', v_atpd, 'rule_code', ar.rule_code,
                'message', format('Line %s: you are promising %s of %s but can promise only %s by %s.', i, trim_scale(v_prev + v_qty), v_code,
                                  trim_scale(greatest((v_a->>'available')::numeric, 0)), erp._day(v_atpd)));
            END IF;
          END IF;
        END IF;
      END IF;

      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
        'discount_pct', v_disc, 'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs,
        'line_total', v_lt, 'vat', v_lv, 'cost', v_cost, 'available', v_avail, 'is_stock', coalesce(it.is_stock, false),
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN 23 END, 'base_doc_entry', v_bentry, 'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END,
        'atp', v_a);
    END IF;
  END LOOP;

  -- Credit position (orders; shown on the form even when no rule applies)
  IF v_bp_ok THEN
    SELECT coalesce(sum(total), 0) INTO v_open FROM erp.document
     WHERE company_code = p_company AND obj_type = 17 AND status = 'open' AND card_code = v_card AND (p_obj <> 17 OR doc_entry IS DISTINCT FROM p_doc_entry);
    v_credit := jsonb_build_object('limit', bp.credit_limit, 'balance', coalesce(bp.balance, 0), 'open_orders', v_open,
                                   'this_order', v_net + v_vat, 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open);
  END IF;

  -- Rule checks (only for a document that is otherwise valid)
  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 17, CASE WHEN p_obj = 17 THEN ARRAY['discount_pct', 'credit_limit', 'below_cost']
                                                              ELSE ARRAY['discount_pct', 'below_cost'] END, p_position) LOOP
      IF r.rule_code = 'discount_pct' THEN
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, discount_pct numeric, item_code text)
                  WHERE erp._apr_hit(r.conds, jsonb_build_object('discount_pct', t.discount_pct, 'doc_total', v_net + v_vat)) LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', x.discount_pct, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Line %s: Discount %s%% is above your limit of %s%%. Submit it for approval or lower the discount.',
                                                   x.line_num + 1, erp._pct(x.discount_pct), erp._pct(r.limit_value))
                            ELSE erp._apr_msg(format('Line %s: Discount %s%%: ', x.line_num + 1, erp._pct(x.discount_pct)), r.template_name, r.conds) END));
        END LOOP;
      ELSIF r.rule_code = 'credit_limit' THEN
        -- NULL credit limit = not set in SAP: the rule does not apply to this customer.
        IF bp.credit_limit IS NOT NULL THEN
          v_exposure := coalesce(bp.balance, 0) + v_open + v_net + v_vat;
          IF v_exposure > bp.credit_limit AND erp._apr_hit(r.conds, jsonb_build_object('credit_over', v_exposure - bp.credit_limit, 'doc_total', v_net + v_vat)) THEN
            v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', v_exposure, 'limit', bp.credit_limit,
              'message', format('Customer %s would be over the credit limit of %s %s: balance %s + open orders %s + this order %s = %s %s.',
                                v_card, erp._money(bp.credit_limit), v_cur, erp._money(bp.balance), erp._money(v_open),
                                erp._money(v_net + v_vat), erp._money(v_exposure), v_cur)));
          END IF;
        END IF;
      ELSIF r.rule_code = 'below_cost' THEN
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, price numeric, discount_pct numeric, cost numeric, item_code text)
                  WHERE t.cost IS NOT NULL AND round(t.price * (1 - t.discount_pct / 100), 4) < t.cost
                    AND erp._apr_hit(r.conds, jsonb_build_object('below_cost_pct', CASE WHEN t.cost > 0 THEN round((t.cost - round(t.price * (1 - t.discount_pct / 100), 4)) / t.cost * 100, 4) ELSE 0 END,
                                                                 'doc_total', v_net + v_vat)) LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', round(x.price * (1 - x.discount_pct / 100), 4), 'limit', x.cost,
            'message', format('Line %s: net price %s for %s is below its cost of %s.',
                              x.line_num + 1, erp._money(x.price * (1 - x.discount_pct / 100)), x.item_code, erp._money(x.cost))));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'atp', CASE WHEN jsonb_array_length(v_err) = 0 THEN v_atp ELSE '[]'::jsonb END,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date,
                                 'due_date', v_due, 'price_list', v_pl, 'payment_terms', v_terms, 'slp_code', v_slp, 'whs_code', v_whs,
                                 'branch_id', v_branch, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur),
    'credit', CASE WHEN p_obj = 17 THEN v_credit END);
END $$;

-- ---- _pay_eval: copied from 20_banking.sql:383
-- Validate a payment and find the approval rules it triggers. Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    header:{normalised}, lines:[{line_no, obj_type, doc_entry, doc_no, amount, sign, open}], totals:{total, applied, on_account, currency}}
-- p_header: {card_code, doc_date, memo, cash, transfer, transfer_bank, transfer_ref, cheques:[{cheque_no, bank_name, due_date, amount}],
--            cheque_bank (outgoing), card, card_ref}.  p_lines: [{obj_type, doc_entry, amount}]
CREATE OR REPLACE FUNCTION erp._pay_eval(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb, p_position text, p_draft_id integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chqin  jsonb := CASE WHEN jsonb_typeof(p_header->'cheques') = 'array' THEN p_header->'cheques' ELSE '[]'::jsonb END;
  v_in     boolean := p_dir = 'I';
  v_party  text := CASE WHEN p_dir = 'I' THEN 'customer' ELSE 'supplier' END;
  v_partyc  text := CASE WHEN p_dir = 'I' THEN 'Customer' ELSE 'Supplier' END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_chq    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_tbank  text := nullif(btrim(h->>'transfer_bank'), '');
  v_cbank  text := nullif(btrim(h->>'cheque_bank'), '');
  bp       erp.business_partner;
  st       erp.banking_setting;
  v_date   date;
  v_cash   numeric;
  v_tr     numeric;
  v_cd     numeric;
  v_ct     numeric := 0;
  v_total  numeric := 0;
  v_applied numeric := 0;
  v_amt_ok boolean := true;
  x        jsonb;
  i        integer := 0;
  n        text;
  d        erp.document;
  v_obj    integer;
  v_entry  integer;
  v_amt    numeric;
  v_open   numeric;
  v_res    numeric;
  v_no     text;
  v_noun   text;
  v_nounc   text;
  v_seen   text[] := '{}';
  v_msg    text;
  v_names  text;
  v_changed timestamptz;
  v_cno    text;
  v_cdue   date;
  v_camt   numeric;
  r        record;
  k        integer := 0;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;

  -- Business partner
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Choose a %s.', v_party));
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s does not exist in company %s. Check the code.', v_partyc, v_card, p_company));
    ELSIF bp.kind <> v_party THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a %s. Choose a %s.', v_card, v_party, v_party));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s is inactive. Choose an active %s.', v_partyc, v_card, v_party));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('%s %s is billed in %s. Payments in a foreign currency come in a later stage.', v_partyc, v_card, bp.currency));
    END IF;
  END IF;

  -- Posting date
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;

  -- Means of payment
  v_cash := CASE WHEN nullif(btrim(h->>'cash'), '') IS NULL THEN 0 ELSE erp._num(h->>'cash') END;
  v_tr   := CASE WHEN nullif(btrim(h->>'transfer'), '') IS NULL THEN 0 ELSE erp._num(h->>'transfer') END;
  v_cd   := CASE WHEN nullif(btrim(h->>'card'), '') IS NULL THEN 0 ELSE erp._num(h->>'card') END;
  IF v_cash IS NULL OR v_cash < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cash', 'message', 'Cash must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_tr IS NULL OR v_tr < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer', 'message', 'The transfer amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_cd IS NULL OR v_cd < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'The card amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  v_cash := round(coalesce(v_cash, 0), 2); v_tr := round(coalesce(v_tr, 0), 2); v_cd := round(coalesce(v_cd, 0), 2);

  IF v_tr > 0 THEN
    IF v_tbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message',
        CASE WHEN v_in THEN 'Choose the bank account the transfer was paid into.' ELSE 'Choose the bank account the transfer is paid from.' END);
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_tbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_tbank, p_company));
    END IF;
  END IF;

  FOR x IN SELECT value FROM jsonb_array_elements(v_chqin) LOOP
    k := k + 1;
    v_cno := nullif(btrim(x->>'cheque_no'), '');
    v_camt := erp._num(x->>'amount');
    v_cdue := erp._date(x->>'due_date');
    IF v_cno IS NULL AND v_camt IS NULL AND nullif(btrim(x->>'due_date'), '') IS NULL THEN CONTINUE; END IF;   -- empty row
    IF v_cno IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter the cheque number.', k));
    ELSIF v_camt IS NULL OR v_camt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter an amount above 0.', k)); v_amt_ok := false;
    ELSIF v_cdue IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter a valid due date.', k));
    ELSE
      v_ct := v_ct + round(v_camt, 2);
      v_chq := v_chq || jsonb_build_object('cheque_no', v_cno, 'bank_name', nullif(btrim(x->>'bank_name'), ''), 'due_date', v_cdue,
                                           'amount', round(v_camt, 2), 'post_dated', v_date IS NOT NULL AND v_cdue > v_date);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_chq) > 0 AND NOT v_in THEN
    IF v_cbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', 'Choose the bank account the cheques are drawn on.');
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_cbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_cbank, p_company));
    END IF;
  END IF;
  IF v_cd > 0 AND NOT v_in THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'Outgoing payments by card are not supported. Pay by transfer, cheque or cash.');
  END IF;

  v_total := round(v_cash + v_tr + v_ct + v_cd, 2);
  IF v_amt_ok AND v_total <= 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'total', 'message',
      CASE WHEN v_in THEN 'Enter the amount received: cash, transfer, cheque or card.' ELSE 'Enter the amount paid: cash, transfer or cheque.' END);
  END IF;

  -- Accounts the posting needs
  IF v_cash > 0 AND st.cash_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The cash account is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_ct > 0 AND v_in AND st.cheque_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for cheques received is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_cd > 0 AND v_in AND st.card_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for card receipts is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF erp.gl_account(p_company, CASE WHEN v_in THEN 'sales' ELSE 'purchasing' END, CASE WHEN v_in THEN 'domestic_ar' ELSE 'domestic_ap' END, false) IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message',
      format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
             CASE WHEN v_in THEN 'Domestic accounts receivable' ELSE 'Domestic accounts payable' END, p_company));
  END IF;
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'period', 'message', v_msg);
  END IF;

  -- Allocations
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_obj := erp._num(x->>'obj_type')::integer;
    v_entry := erp._num(x->>'doc_entry')::integer;
    v_amt := erp._num(x->>'amount');
    IF v_obj IS NULL OR v_entry IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'choose a document.');
      CONTINUE;
    END IF;
    IF v_in AND v_obj NOT IN (13, 14) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an incoming payment pays A/R invoices and uses A/R credit memos only.');
      CONTINUE;
    ELSIF NOT v_in AND v_obj NOT IN (18, 19, 204) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an outgoing payment pays A/P invoices and down payments and uses A/P credit memos only.');
      CONTINUE;
    END IF;
    v_noun := CASE v_obj WHEN 13 THEN 'invoice' WHEN 14 THEN 'credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'down payment' END;
    v_nounc := CASE v_obj WHEN 13 THEN 'Invoice' WHEN 14 THEN 'Credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'Down payment' END;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = v_obj AND doc_entry = v_entry;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s was not found in company %s.', v_noun, v_entry, p_company));
      CONTINUE;
    END IF;
    v_no := erp._sd_no(p_company, v_obj, v_entry);
    IF d.source = 'sap' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s came from SAP Business One. Record its payment in SAP during the soft switch.', v_noun, v_no));
    ELSIF d.source <> 'erp' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is sample test data and can''t be paid.', v_noun, v_no));
    ELSIF d.card_code IS DISTINCT FROM v_card THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s belongs to %s, not %s.', v_noun, v_no, d.card_code, coalesce(v_card, '(none)')));
    ELSIF d.status IN ('cancelled', 'cancellation') THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is cancelled.', v_noun, v_no));
    ELSIF (v_obj || ':' || v_entry) = ANY (v_seen) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is listed twice.', v_noun, v_no));
    ELSIF v_amt IS NULL OR v_amt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'enter an amount above 0.');
    ELSE
      v_amt := round(v_amt, 2);
      v_open := erp._bk_doc_open(p_company, v_obj, v_entry);
      v_res := erp._bk_reserved(p_company, v_obj, v_entry, p_draft_id);
      IF v_amt > v_open - v_res THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n ||
          CASE WHEN v_res > 0
               THEN format('%s %s is more than the %s %s still open on %s %s (%s %s is waiting in other payment drafts).',
                           erp._money(v_amt), v_cur, erp._money(greatest(v_open - v_res, 0)), v_cur, v_noun, v_no, erp._money(v_res), v_cur)
               ELSE format('%s %s is more than the %s %s still open on %s %s.', erp._money(v_amt), v_cur, erp._money(greatest(v_open, 0)), v_cur, v_noun, v_no) END);
      ELSE
        v_applied := v_applied + CASE WHEN v_obj IN (14, 19) THEN -v_amt ELSE v_amt END;
        v_out := v_out || jsonb_build_object('line_no', jsonb_array_length(v_out), 'obj_type', v_obj, 'doc_entry', v_entry, 'doc_no', v_no,
                                             'amount', v_amt, 'sign', CASE WHEN v_obj IN (14, 19) THEN -1 ELSE 1 END, 'open', v_open,
                                             'doc_date', d.doc_date, 'due_date', d.due_date, 'total', d.total);
      END IF;
    END IF;
    v_seen := v_seen || (v_obj || ':' || v_entry);
  END LOOP;
  v_applied := round(v_applied, 2);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_err) e WHERE e->>'field' IN ('amount', 'doc', 'cash', 'transfer', 'card', 'cheques')) THEN
    IF v_applied > v_total AND v_total > 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message',
        format('You applied %s %s but the payment is %s %s. Lower the applied amounts or raise the payment.', erp._money(v_applied), v_cur, erp._money(v_total), v_cur));
    ELSIF v_applied < 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message', 'The credit memos are more than the invoices you applied. Apply more invoices or less credit.');
    END IF;
  END IF;

  -- Approval rules: outgoing payments (amount, recent bank change); B2: incoming payments (template incoming_payment).
  IF v_in AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 24, ARRAY['incoming_payment'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', v_total, 'limit', r.limit_value,
          'message', erp._apr_msg(format('Incoming payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds)));
      END IF;
    END LOOP;
  END IF;
  IF NOT v_in AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 46, ARRAY['payment_amount'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', v_total, 'limit', r.limit_value,
          'message', CASE WHEN r.std THEN format('Payment %s %s is above your payment limit of %s %s.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur)
                          ELSE erp._apr_msg(format('Payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds) END));
      END IF;
    END LOOP;
    SELECT max(changed_at) INTO v_changed FROM erp.bp_bank_change WHERE company_code = p_company AND card_code = v_card;
    IF v_changed IS NOT NULL THEN
      FOR r IN SELECT * FROM erp._apr_rules(p_company, 46, ARRAY['bank_change'], p_position) LOOP
        IF erp._apr_hit(r.conds, jsonb_build_object('days_since_change', extract(epoch FROM now() - v_changed) / 86400, 'amount', v_total)) THEN
          SELECT string_agg(x.approver_name, ' and ' ORDER BY x.step) INTO v_names
            FROM erp._apr_rules(p_company, 46, ARRAY['bank_change'], p_position) x WHERE x.template_id = r.template_id;
          v_checks := v_checks || (r.ck || jsonb_build_object('value', v_changed::date, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('%s''s bank details changed on %s, within the last %s days. %s must both approve this payment.',
                                                   bp.name, erp._day(v_changed::date), trim_scale(r.limit_value), v_names)
                            ELSE erp._apr_msg(format('%s''s bank details changed on %s: ', bp.name, erp._day(v_changed::date)), r.template_name, r.conds) END));
        END IF;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', bp.name, 'doc_date', v_date, 'memo', nullif(btrim(h->>'memo'), ''),
                                 'cash', v_cash, 'transfer', v_tr, 'transfer_bank', CASE WHEN v_tr > 0 THEN v_tbank END,
                                 'transfer_ref', nullif(btrim(h->>'transfer_ref'), ''), 'cheques', v_chq, 'cheque_total', v_ct,
                                 'cheque_bank', CASE WHEN v_ct > 0 AND NOT v_in THEN v_cbank END, 'card', v_cd, 'card_ref', nullif(btrim(h->>'card_ref'), '')),
    'totals', jsonb_build_object('total', v_total, 'applied', v_applied, 'on_account', round(v_total - v_applied, 2), 'currency', v_cur));
END $$;

-- ---- _pd_eval: copied from 21_purchasing.sql:391
-- Validate, price and check one purchase request (1470000113), quotation (540000006) or order (22). Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, line, value, limit, message}],
--    lines:[…computed, with last_price], header:{…normalised}, totals:{net, vat, total, currency}}
-- Lines can be copied from a request (quotation, order) or a quotation (order): [{…, base_obj_type, base_doc_entry, base_line}].
CREATE OR REPLACE FUNCTION erp._pd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_req    boolean := p_obj = 1470000113;
  v_po     boolean := p_obj = 22;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  st       erp.purchase_setting;
  v_doc_date date;
  v_due    date;
  v_terms  integer;
  v_whs    text;
  v_branch integer;
  v_office text := nullif(btrim(h->>'china_office'), '');
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_cbm    numeric;
  v_ok     boolean;
  v_lt     numeric;
  v_lv     numeric;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_last   jsonb;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  r        record;
  x        record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;

  -- Supplier (quotations and orders; a request has none)
  IF v_req THEN
    v_card := NULL;
  ELSIF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a supplier.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'supplier' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a supplier. Choose a supplier.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s is inactive. Choose an active supplier.', v_card));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('Supplier %s is billed in %s. Purchasing in a foreign currency comes in a later stage.', v_card, bp.currency));
    ELSE
      v_bp_ok := true;
    END IF;
  END IF;

  -- Dates
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_doc_date := erp._date(h->>'doc_date');
    IF v_doc_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NULL THEN
    IF v_req THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'Choose the date the goods are needed by.');
    END IF;
  ELSE
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date is not a valid date.' WHEN v_po THEN 'The delivery date is not a valid date.' ELSE 'The valid-until date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date can''t be before the posting date.' WHEN v_po THEN 'The delivery date can''t be before the posting date.'
             ELSE 'The valid-until date can''t be before the posting date.' END);
    END IF;
  END IF;

  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;

  IF v_office IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.china_office WHERE company_code = p_company AND code = v_office AND active) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'china_office', 'message', format('China office %s is not set up for %s.', v_office, p_company));
  END IF;

  -- Header warehouse: the receiving warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), st.default_whs_code);
  IF v_whs IS NOT NULL THEN
    SELECT branch_id INTO v_branch FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist in company %s.', v_whs, p_company));
    ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is inactive. Choose another warehouse.', v_whs));
    END IF;
  END IF;

  -- Lines
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one line.');
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_code := nullif(btrim(l->>'item_code'), '');
    it := NULL;
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'choose an item.');
      v_ok := false;
    ELSE
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('item %s does not exist. Check the item code.', v_code));
        v_ok := false;
      ELSIF NOT it.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is inactive. Choose an active item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_bought, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a purchase item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_stock, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a stock item. Buying services comes in a later stage.', v_code));
        v_ok := false;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      IF v_po THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose the warehouse the goods are received into.');
        v_ok := false;
      END IF;
    ELSIF v_lwhs IS DISTINCT FROM v_whs AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist or is inactive.', v_lwhs));
      v_ok := false;
    END IF;

    v_cbm := NULL;
    IF nullif(btrim(l->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(l->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'cbm', 'message', n || 'volume (CBM) must be a number of 0 or more.');
        v_ok := false;
      END IF;
    END IF;

    v_last := CASE WHEN v_code IS NOT NULL THEN erp._pd_last_price(p_company, v_code, p_doc_entry) END;
    v_tc := NULL;
    v_tax := NULL;
    v_price := NULL;
    IF NOT v_req THEN
      v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), st.default_tax_code);
      IF v_tax IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || 'choose a tax code.');
        v_ok := false;
      ELSE
        SELECT * INTO v_tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
        IF NOT FOUND THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s does not exist.', v_tax));
          v_ok := false;
        ELSIF NOT v_tc.active THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is inactive.', v_tax));
          v_ok := false;
        ELSIF v_tc.category = 'O' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for sales. Choose a purchase tax code.', v_tax));
          v_ok := false;
        END IF;
      END IF;
      IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
        v_price := erp._num(l->>'price');
        IF v_price IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
          v_ok := false;
        ELSIF v_price < 0 THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
          v_ok := false;
        END IF;
      ELSIF v_code IS NOT NULL THEN
        v_price := (v_last->>'price')::numeric;
        IF v_price IS NULL AND it.item_code IS NOT NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has never been bought, so there is no last price. Enter a price.', v_code));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    -- Copied from a request (quotation, order) or a quotation (order): Super ERP, approved and open, same item, enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF v_req OR v_bentry IS NULL OR v_bline IS NULL OR NOT (v_bobj = 1470000113 OR (v_po AND v_bobj = 540000006)) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'a quotation is copied from a request, and an order from a request or a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s was not found in company %s.', lower(erp._pd_name(v_bobj)), v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s came from %s. Only Super ERP documents can be copied.',
            lower(erp._pd_name(v_bobj)), v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s is not open, so it can''t be copied.', lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_bobj = 540000006 AND bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is from supplier %s. Copy it to an order for the same supplier.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of %s %s.', v_bline + 1, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_po AND v_qty IS NOT NULL AND (coalesce(bl.line_status, 'O') <> 'O' OR v_qty > coalesce(bl.open_qty, 0)) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on %s %s.',
            trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END), v_code, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      v_lt := CASE WHEN v_req THEN 0 ELSE round(v_qty * v_price, 2) END;
      v_lv := CASE WHEN v_req THEN 0 ELSE round(v_lt * v_tc.rate / 100, 2) END;
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;
      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.purchase_uom, 'qty', v_qty, 'price', v_price,
        'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs, 'cbm', v_cbm, 'line_total', v_lt, 'vat', v_lv,
        'last_price', v_last->'price', 'last_doc_no', v_last->>'doc_no', 'last_doc_date', v_last->>'doc_date',
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN v_bobj END, 'base_doc_entry', v_bentry,
        'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END);
    END IF;
  END LOOP;

  -- Purchase order rules (only for an order that is otherwise valid)
  IF v_po AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 22, ARRAY['po_amount', 'po_price_increase'], p_position) LOOP
      IF r.rule_code = 'po_amount' THEN
        IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_net + v_vat)) THEN
          v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', v_net + v_vat, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Purchase order total %s %s is above your limit of %s %s.', erp._money(v_net + v_vat), v_cur, erp._money(r.limit_value), v_cur)
                            ELSE erp._apr_msg(format('Purchase order total %s %s: ', erp._money(v_net + v_vat), v_cur), r.template_name, r.conds) END));
        END IF;
      ELSE
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, item_code text, price numeric, last_price numeric, last_doc_no text)
                  WHERE t.last_price > 0 AND t.price > t.last_price
                    AND CASE WHEN r.std THEN t.price > round(t.last_price * (1 + r.limit_value / 100), 6)
                             ELSE erp._apr_hit(r.conds, jsonb_build_object('increase_pct', (t.price / t.last_price - 1) * 100, 'amount', v_net + v_vat)) END LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', round((x.price / x.last_price - 1) * 100, 2), 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Line %s: price %s for %s is %s%% above the last purchase price of %s (%s). The limit is %s%%.',
                              x.line_num + 1, erp._money(x.price), x.item_code, erp._pct(round((x.price / x.last_price - 1) * 100, 2)),
                              erp._money(x.last_price), x.last_doc_no, erp._pct(r.limit_value))
                            ELSE erp._apr_msg(format('Line %s: price %s for %s is %s%% above the last purchase price: ', x.line_num + 1, erp._money(x.price), x.item_code,
                                                     erp._pct(round((x.price / x.last_price - 1) * 100, 2))), r.template_name, r.conds) END));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date, 'due_date', v_due,
                                 'payment_terms', v_terms, 'whs_code', v_whs, 'branch_id', v_branch, 'china_office', v_office,
                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('net', v_net, 'vat', v_vat, 'total', v_net + v_vat, 'currency', v_cur));
END $$;

-- ---- _inv_eval: copied from 22_inventory.sql:495
-- Validate, cost and check one goods receipt (59) or goods issue (60). Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    lines:[{line_num, item_code, description, uom, qty, price, line_total, bin_code, lots, serial, batch, on_hand}],
--    header:{doc_date, whs_code, whs_name, bins, reason_code, reason_name, acct_code, acct_name, customer_ref, comments},
--    totals:{value, currency}}
-- p_header: {doc_date, whs_code, reason_code, acct_code (optional: the reason's account), customer_ref, comments}
-- p_lines:  [{item_code, qty, price (receipt: unit cost; empty = current average cost), bin_code, lots:[{number, qty, made_on, expires_on}]}]
-- p_position = NULL skips the approval rules (used when an approved document is posted).
CREATE OR REPLACE FUNCTION erp._inv_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_in     boolean := p_obj = 59;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_date   date;
  v_whs    text := nullif(btrim(h->>'whs_code'), '');
  wh       erp.warehouse;
  v_bins   boolean := false;
  v_rcode  text := nullif(btrim(h->>'reason_code'), '');
  rs       erp.inventory_reason;
  v_acct   text := nullif(btrim(h->>'acct_code'), '');
  ac       erp.account;
  l        jsonb;
  i        integer := 0;
  n        integer;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_bin    text;
  v_onhand numeric;
  v_avail  numeric;
  v_lc     jsonb;
  v_used   jsonb := '{}';     -- item → quantity already taken by earlier lines
  v_ubin   jsonb := '{}';     -- item|bin → quantity already taken from a bin
  v_serials text[] := '{}';
  v_lt     numeric;
  v_total  numeric := 0;
  r        record;
  v_noun   text := lower(erp._inv_name(p_obj));
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;

  IF v_whs IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', 'Choose a warehouse.');
  ELSE
    SELECT * INTO wh FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND OR NOT wh.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist or is inactive in company %s.', v_whs, p_company));
      v_whs := NULL;
    ELSIF wh.locked THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is locked. Ask Inventory to unlock it first.', v_whs));
      v_whs := NULL;
    ELSE
      SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_whs;
      v_bins := coalesce(v_bins, false);
    END IF;
  END IF;

  IF v_rcode IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message', format('Choose the reason for this %s.', v_noun));
  ELSE
    SELECT * INTO rs FROM erp.inventory_reason WHERE company_code = p_company AND code = v_rcode;
    IF NOT FOUND OR NOT rs.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message', format('Reason %s does not exist or is inactive. Choose another reason.', v_rcode));
    ELSIF rs.direction <> 'both' AND rs.direction <> (CASE WHEN v_in THEN 'in' ELSE 'out' END) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message',
        format('Reason %s is for %s only.', rs.name, CASE rs.direction WHEN 'in' THEN 'goods receipts' ELSE 'goods issues' END));
    ELSE
      v_acct := coalesce(v_acct, rs.acct_code);
    END IF;
  END IF;

  IF v_acct IS NULL THEN
    IF v_rcode IS NOT NULL AND rs.code IS NOT NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message',
        format('Reason %s has no account. Choose the account, or ask Finance to set one in Inventory Setup.', rs.name));
    END IF;
  ELSE
    SELECT * INTO ac FROM erp.account WHERE company_code = p_company AND acct_code = v_acct;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s does not exist in company %s.', v_acct, p_company));
    ELSIF NOT coalesce(ac.postable, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is a title account. Choose an account you can post to.', v_acct));
    ELSIF coalesce(ac.is_control, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is a control account (customers or suppliers). Choose another account.', v_acct));
    ELSIF coalesce(ac.frozen, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is frozen. Choose another account.', v_acct));
    END IF;
  END IF;

  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one item.');
  END IF;

  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    n := i + 1;
    v_code := nullif(btrim(l->>'item_code'), '');
    v_qty := erp._num(l->>'qty');
    v_price := erp._num(l->>'price');
    v_bin := nullif(btrim(l->>'bin_code'), '');
    it := NULL;
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: choose an item.', n));
      i := i + 1; CONTINUE;
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: item %s does not exist in company %s.', n, v_code, p_company));
      i := i + 1; CONTINUE;
    ELSIF NOT it.active THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: item %s is inactive.', n, v_code));
    ELSIF NOT coalesce(it.is_stock, false) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: %s is not a stock item, so it has no stock to move.', n, v_code));
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', format('Line %s: enter a quantity above zero.', n));
      v_qty := NULL;
    END IF;
    SELECT on_hand, avg_cost INTO r FROM erp.stock_balance WHERE company_code = p_company AND item_code = v_code AND whs_code = v_whs;
    v_onhand := coalesce(r.on_hand, 0);
    IF v_in THEN
      IF (l->>'price') IS NOT NULL AND btrim(l->>'price') <> '' AND (v_price IS NULL OR v_price < 0) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', format('Line %s: the unit cost must be zero or more.', n));
      END IF;
      v_price := coalesce(v_price, r.avg_cost, it.avg_cost, 0);
    ELSE
      v_price := coalesce(r.avg_cost, it.avg_cost, 0);
    END IF;

    IF v_qty IS NOT NULL AND v_whs IS NOT NULL THEN
      IF NOT v_in THEN
        v_avail := v_onhand - coalesce((v_used->>v_code)::numeric, 0);
        IF v_qty > v_avail THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message',
            format('Line %s: only %s of %s in stock in %s. You can''t issue %s.', n, trim_scale(greatest(v_avail, 0)), v_code, v_whs, trim_scale(v_qty)));
        END IF;
        v_used := jsonb_set(v_used, ARRAY[v_code], to_jsonb(coalesce((v_used->>v_code)::numeric, 0) + v_qty));
      END IF;
      -- Bins: put-away (receipt) needs a bin; a pick (issue) takes from the bin, or from stock outside bins.
      IF NOT v_bins THEN
        IF v_bin IS NOT NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: warehouse %s does not use bins. Clear the bin.', n, v_whs));
        END IF;
      ELSIF v_in AND v_bin IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: %s uses bins. Choose the bin to put %s away in.', n, v_whs, v_code));
      ELSIF v_bin IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = p_company AND whs_code = v_whs AND bin_code = v_bin AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: bin %s does not exist or is inactive in %s.', n, v_bin, v_whs));
      ELSIF NOT v_in THEN
        v_avail := CASE WHEN v_bin IS NULL THEN erp._inv_unbinned(p_company, v_code, v_whs)
                        ELSE coalesce((SELECT bs.qty FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                                        WHERE b.company_code = p_company AND b.bin_code = v_bin AND bs.item_code = v_code), 0) END
                   - coalesce((v_ubin->>(v_code || '|' || coalesce(v_bin, ''))::text)::numeric, 0);
        IF v_qty > v_avail THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', CASE WHEN v_bin IS NULL
            THEN format('Line %s: only %s of %s are outside bins in %s. Choose the bin to pick from.', n, trim_scale(greatest(v_avail, 0)), v_code, v_whs)
            ELSE format('Line %s: bin %s holds only %s of %s.', n, v_bin, trim_scale(greatest(v_avail, 0)), v_code) END);
        END IF;
        v_ubin := jsonb_set(v_ubin, ARRAY[v_code || '|' || coalesce(v_bin, '')], to_jsonb(coalesce((v_ubin->>(v_code || '|' || coalesce(v_bin, '')))::numeric, 0) + v_qty));
      END IF;
      -- Batches and serial numbers
      v_lc := erp._inv_lot_check(p_company, v_code, it.serial_managed, it.batch_managed, v_whs, v_qty, l->'lots', CASE WHEN v_in THEN 1 ELSE -1 END, n, v_serials);
      IF v_lc ? 'message' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'lots', 'message', v_lc->>'message');
      ELSIF it.serial_managed THEN
        v_serials := v_serials || ARRAY(SELECT v_code || ':' || (z->>'number') FROM jsonb_array_elements(v_lc->'lots') z);
      END IF;
    END IF;

    v_lt := round(coalesce(v_qty, 0) * v_price, 2);
    v_total := v_total + v_lt;
    v_out := v_out || jsonb_build_object('line_num', i, 'item_code', v_code, 'description', it.name, 'uom', it.inventory_uom, 'qty', v_qty,
                                         'price', round(v_price, 6), 'line_total', v_lt, 'bin_code', v_bin, 'lots', coalesce(v_lc->'lots', '[]'::jsonb),
                                         'serial', coalesce(it.serial_managed, false), 'batch', coalesce(it.batch_managed, false), 'on_hand', v_onhand);
    i := i + 1;
  END LOOP;

  -- Approval: value above the requester's limit for this document type (SAMPLE limits for ZZ99 only).
  IF p_position IS NOT NULL THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, p_obj, ARRAY['stock_doc_amount'], p_position) LOOP
      CONTINUE WHEN NOT (v_total > 0 AND erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)));
      v_checks := v_checks || (r.ck || jsonb_build_object('rule_code', 'stock_doc_amount', 'line', NULL, 'value', v_total, 'limit', r.limit_value,
        'message', CASE WHEN r.std THEN format('Value %s %s is above your limit of %s %s for %ss. %s approves it.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur,
                                               v_noun, r.approver_name)
                        ELSE erp._apr_msg(format('Value %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds) END));
    END LOOP;
  END IF;

  RETURN jsonb_build_object('errors', v_err, 'checks', v_checks, 'lines', v_out,
    'header', jsonb_build_object('doc_date', v_date, 'whs_code', v_whs, 'whs_name', wh.name, 'bins', v_bins, 'reason_code', rs.code, 'reason_name', rs.name,
                                 'acct_code', v_acct, 'acct_name', ac.name, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('value', v_total, 'currency', v_cur));
END $$;

-- ---- _count_eval: copied from 22_inventory.sql:1926
-- The variance report of a count, its problems and its approval checks. Never writes. p_position NULL skips the rules.
--   errors: lines not counted, stock that moved since the count started, a variance on a batch / serial item
--   checks: count_variance_pct (one per line above the % limit; system 0 with a count counts as above), count_variance_value (total)
CREATE OR REPLACE FUNCTION erp._count_eval(p_company varchar, p_count_id integer, p_position text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c        erp.inv_count;
  v_bins   boolean;
  v_cur    text;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_lines  jsonb := '[]';
  v_gain   numeric := 0;
  v_loss   numeric := 0;
  v_unc    integer := 0;
  r        record;
  ar       record;
  v_now    numeric;
  v_var    numeric;
  v_pct    numeric;
  v_cost   numeric;
  v_val    numeric;
BEGIN
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_count_id;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = c.whs_code;
  v_bins := coalesce(v_bins, false);
  FOR r IN SELECT l.*, i.name, i.serial_managed, i.batch_managed, i.avg_cost AS item_cost, b.bin_code,
                  (SELECT avg_cost FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = c.whs_code) AS whs_cost
             FROM erp.inv_count_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
             LEFT JOIN erp.bin_location b ON b.bin_id = l.bin_id
            WHERE l.company_code = p_company AND l.count_id = p_count_id ORDER BY l.line_num LOOP
    IF r.counted_qty IS NULL THEN
      v_unc := v_unc + 1;
      CONTINUE;
    END IF;
    v_now := erp._count_qty(p_company, r.item_code, c.whs_code, r.bin_id, v_bins);
    -- (A posted or cancelled count is history: the stock has moved on, so there is nothing to compare.)
    IF c.state NOT IN ('posted', 'cancelled') AND v_now <> r.system_qty THEN
      v_err := v_err || jsonb_build_object('line', r.line_num, 'field', 'system_qty', 'message',
        format('Line %s: stock of %s%s changed since the count started (%s then, %s now). Cancel this count and start a new one.',
               r.line_num + 1, r.item_code, coalesce(' in bin ' || r.bin_code, ''), trim_scale(r.system_qty), trim_scale(v_now)));
    END IF;
    v_var := r.counted_qty - r.system_qty;
    IF v_var <> 0 AND (r.serial_managed OR r.batch_managed) THEN
      v_err := v_err || jsonb_build_object('line', r.line_num, 'field', 'counted_qty', 'message',
        format('Line %s: %s is managed by %s. Post the difference with a goods receipt or goods issue that names them, then recount.',
               r.line_num + 1, r.item_code, CASE WHEN r.serial_managed THEN 'serial numbers' ELSE 'batches' END));
    END IF;
    v_pct := CASE WHEN r.system_qty <> 0 THEN round(v_var / abs(r.system_qty) * 100, 2) END;
    v_cost := coalesce(r.whs_cost, r.avg_cost, r.item_cost, 0);
    v_val := round(v_var * v_cost, 2);
    IF v_val > 0 THEN v_gain := v_gain + v_val; ELSE v_loss := v_loss - v_val; END IF;
    v_lines := v_lines || jsonb_build_object('line_num', r.line_num, 'item_code', r.item_code, 'description', r.name, 'bin_code', r.bin_code,
                                             'system_qty', r.system_qty, 'counted_qty', r.counted_qty, 'variance', v_var, 'pct', v_pct, 'cost', v_cost, 'value', v_val);
    IF p_position IS NOT NULL AND v_var <> 0 THEN
      FOR ar IN SELECT * FROM erp._apr_rules(p_company, 1470000065, ARRAY['count_variance_pct'], p_position) LOOP
        CONTINUE WHEN NOT (v_pct IS NULL OR erp._apr_hit(ar.conds, jsonb_build_object('variance_pct', abs(v_pct))));
        v_checks := v_checks || (ar.ck || jsonb_build_object('rule_code', 'count_variance_pct', 'line', r.line_num, 'value', v_pct, 'limit', ar.limit_value,
          'message', CASE WHEN ar.std OR ar.conds = '[]'::jsonb
                          THEN format('Line %s: %s counted %s, expected %s (%s), above the %s %% variance limit. %s approves it.', r.line_num + 1, r.item_code,
                            trim_scale(r.counted_qty), trim_scale(r.system_qty), CASE WHEN v_pct IS NULL THEN 'none expected' ELSE trim_scale(v_pct) || ' %' END,
                            trim_scale(coalesce(ar.limit_value, 0)), ar.approver_name)
                          ELSE erp._apr_msg(format('Line %s: %s counted %s, expected %s: ', r.line_num + 1, r.item_code, trim_scale(r.counted_qty), trim_scale(r.system_qty)),
                                            ar.template_name, ar.conds) END));
      END LOOP;
    END IF;
  END LOOP;
  IF v_unc > 0 THEN
    v_err := jsonb_build_array(jsonb_build_object('line', NULL, 'field', 'counted_qty', 'message',
               format('%s line(s) are not counted yet. Count them, or enter 0 when there is none.', v_unc))) || v_err;
  END IF;
  IF p_position IS NOT NULL AND v_gain + v_loss > 0 THEN
    FOR ar IN SELECT * FROM erp._apr_rules(p_company, 1470000065, ARRAY['count_variance_value'], p_position) LOOP
      CONTINUE WHEN NOT erp._apr_hit(ar.conds, jsonb_build_object('variance_value', v_gain + v_loss));
      v_checks := v_checks || (ar.ck || jsonb_build_object('rule_code', 'count_variance_value', 'line', NULL, 'value', v_gain + v_loss, 'limit', ar.limit_value,
        'message', CASE WHEN ar.std THEN format('The variance adds up to %s %s (gains %s, losses %s), above the limit of %s %s. %s approves it.', erp._money(v_gain + v_loss), v_cur,
                          erp._money(v_gain), erp._money(v_loss), erp._money(ar.limit_value), v_cur, ar.approver_name)
                        ELSE erp._apr_msg(format('The variance adds up to %s %s (gains %s, losses %s): ', erp._money(v_gain + v_loss), v_cur, erp._money(v_gain), erp._money(v_loss)),
                                          ar.template_name, ar.conds) END));
    END LOOP;
  END IF;
  RETURN jsonb_build_object('errors', v_err, 'checks', v_checks, 'lines', v_lines,
                            'totals', jsonb_build_object('gain', v_gain, 'loss', v_loss, 'net', v_gain - v_loss, 'currency', v_cur, 'uncounted', v_unc));
END $$;

-- ---- _md_rules: copied from 23_master_data.sql:186
-- B2: the stages of the active templates (obj_type 2) whose originators include the requester (or everyone).
CREATE OR REPLACE FUNCTION erp._md_rules(p_company varchar, p_rule text, p_position text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(r.ck ORDER BY r.step, r.template_id), '[]'::jsonb)
    FROM erp._apr_rules(p_company, 2, ARRAY[p_rule], p_position) r
$$;

-- ---- _sd_req_rules_apply: copied from 30_numbering_company.sql:2434
-- Does any approval template apply to this credit memo / invoice for the requester? (cheap test before the full check)
CREATE OR REPLACE FUNCTION erp._sd_req_rules_apply(p_company varchar, p_obj integer, p_lines jsonb, p_position text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj
    WHEN 14 THEN EXISTS (SELECT 1 FROM erp._apr_rules(p_company, 14, ARRAY['credit_memo_amount'], p_position))
    WHEN 13 THEN EXISTS (SELECT 1 FROM erp._apr_rules(p_company, 17, ARRAY['discount_pct'], p_position) r
                          WHERE r.conds = '[]'::jsonb
                             OR EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) l
                                         WHERE nullif(l->>'base_doc_entry', '') IS NULL AND coalesce(erp._num(nullif(btrim(l->>'discount_pct'), '')), 0) > 0))
    ELSE false END
$$;

-- ---- _sd_req_checks: copied from 30_numbering_company.sql:2449
-- The approvals a valid credit memo (total = p_total) or direct service invoice needs. Same shape as A2's checks.
--   credit memo: template credit_memo_amount (obj 14) – the total above the limit (no limit = always)
--   invoice:     the sales-order discount template discount_pct (obj 17) on each service line (lines without a base)
CREATE OR REPLACE FUNCTION erp._sd_req_checks(p_company varchar, p_obj integer, p_lines jsonb, p_position text, p_total numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r      record;
  x      record;
  v_out  jsonb := '[]'::jsonb;
  v_cur  text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_nbase integer;
BEGIN
  IF p_obj = 14 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 14, ARRAY['credit_memo_amount'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', p_total)) THEN
        v_out := v_out || (r.ck || jsonb_build_object('line', NULL, 'value', p_total, 'limit', r.limit_value,
          'message', CASE WHEN r.conds = '[]'::jsonb THEN format('Every credit memo needs approval from %s.', r.approver_name)
                          WHEN r.std THEN format('Credit memo total %s %s is above the limit of %s %s. It needs approval from %s.',
                                      erp._money(p_total), v_cur, erp._money(r.limit_value), v_cur, r.approver_name)
                          ELSE erp._apr_msg(format('Credit memo total %s %s: ', erp._money(p_total), v_cur), r.template_name, r.conds) END));
      END IF;
    END LOOP;
  ELSIF p_obj = 13 THEN
    SELECT count(*) INTO v_nbase FROM jsonb_array_elements(v_lines) l WHERE nullif(l->>'base_doc_entry', '') IS NOT NULL;
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 17, ARRAY['discount_pct'], p_position) LOOP
      FOR x IN SELECT v_nbase + row_number() OVER () AS n, coalesce(erp._num(nullif(btrim(l->>'discount_pct'), '')), 0) AS d
                 FROM jsonb_array_elements(v_lines) l WHERE nullif(l->>'base_doc_entry', '') IS NULL LOOP
        IF erp._apr_hit(r.conds, jsonb_build_object('discount_pct', x.d, 'doc_total', p_total)) THEN
          v_out := v_out || (r.ck || jsonb_build_object('line', x.n, 'value', x.d, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Line %s: Discount %s%% is above your limit of %s%%. Submit it for approval or lower the discount.',
                                                   x.n, erp._pct(x.d), erp._pct(r.limit_value))
                            ELSE erp._apr_msg(format('Line %s: Discount %s%%: ', x.n, erp._pct(x.d)), r.template_name, r.conds) END));
        END IF;
      END LOOP;
    END LOOP;
  END IF;
  RETURN v_out;
END $$;

-- ---- journal_setup: copied from 18_posting.sql:646
-- ============ API: manual journals ============
-- Form defaults: currency, write access, the caller's approval limit.
CREATE OR REPLACE FUNCTION erp.journal_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._je_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('finance'),
    'my_limit', erp._apr_my_limit(p_company, 30, 'journal_amount', u.position_code),
    'has_periods', EXISTS (SELECT 1 FROM erp.posting_period WHERE company_code = p_company));
END $$;

-- ---- sales_doc_setup: copied from 19_sales_cycle.sql:866
-- Lists and defaults for the quotation / order form (sales users cannot read tax_code directly, so it comes from here).
CREATE OR REPLACE FUNCTION erp.sales_doc_setup(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._so_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'tax_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'rate', rate) ORDER BY code)
                             FROM erp.tax_code WHERE company_code = p_company AND active AND coalesce(category, 'O') <> 'I'), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', whs_code, 'name', name) ORDER BY whs_code)
                              FROM erp.warehouse WHERE company_code = p_company AND active), '[]'::jsonb),
    'price_lists', coalesce((SELECT jsonb_agg(jsonb_build_object('code', list_num, 'name', name) ORDER BY list_num)
                               FROM erp.price_list WHERE company_code = p_company), '[]'::jsonb),
    'payment_terms', coalesce((SELECT jsonb_agg(jsonb_build_object('code', group_num, 'name', name, 'days', extra_days) ORDER BY group_num)
                                 FROM erp.payment_terms WHERE company_code = p_company), '[]'::jsonb),
    'salespersons', coalesce((SELECT jsonb_agg(jsonb_build_object('code', slp_code, 'name', name) ORDER BY slp_code)
                                FROM erp.salesperson WHERE company_code = p_company AND active), '[]'::jsonb),
    'default_tax_code', (SELECT default_tax_code FROM erp.sales_setting WHERE company_code = p_company),
    'default_whs_code', (SELECT default_whs_code FROM erp.sales_setting WHERE company_code = p_company),
    'numbering', (SELECT jsonb_build_object('prefix', prefix, 'next_num', next_num) FROM erp.number_series
                   WHERE company_code = p_company AND obj_type = p_obj AND active),
    'my_discount_limit', erp._apr_my_limit(p_company, 17, 'discount_pct', u.position_code),
    'atp_on', p_obj = 17 AND EXISTS (SELECT 1 FROM erp.atp_rule WHERE company_code = p_company AND active),
    'can_write', erp.can_write('sales'));
END $$;

-- ---- payment_setup: copied from 20_banking.sql:729
-- ============ API: payments ============
-- Form defaults: currency, write access, house bank accounts, which accounts are set, the caller's payment limit.
CREATE OR REPLACE FUNCTION erp.payment_setup(p_company varchar, p_dir text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.banking_setting;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('banking') OR erp.can_write('finance'),
    'banks', coalesce((SELECT jsonb_agg(jsonb_build_object('bank_code', bank_code, 'name', name, 'acct_code', acct_code, 'bank_name', bank_name) ORDER BY bank_code)
                         FROM erp.bank_account WHERE company_code = p_company AND active AND kind = 'bank'), '[]'::jsonb),
    'accounts', jsonb_build_object('cash', st.cash_acct IS NOT NULL, 'cheque', st.cheque_acct IS NOT NULL, 'card', st.card_acct IS NOT NULL),
    'numbering', EXISTS (SELECT 1 FROM erp.number_series WHERE company_code = p_company AND obj_type = CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END AND active),
    'my_limit', CASE WHEN p_dir = 'O' THEN erp._apr_my_limit(p_company, 46, 'payment_amount', u.position_code)
                   ELSE erp._apr_my_limit(p_company, 24, 'incoming_payment', u.position_code) END,
    'bank_change_days', CASE WHEN p_dir = 'O' THEN (SELECT max(r.limit_value) FROM erp._apr_rules(p_company, 46, ARRAY['bank_change'], u.position_code) r) END,
    'needs_approval', CASE WHEN p_dir = 'I' THEN EXISTS (SELECT 1 FROM erp._apr_rules(p_company, 24, ARRAY['incoming_payment'], u.position_code)) END);
END $$;

-- ---- purchase_doc_setup: copied from 21_purchasing.sql:1063
-- Lists and defaults for the purchasing forms (purchasing users cannot read tax_code directly, so it comes from here).
CREATE OR REPLACE FUNCTION erp.purchase_doc_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.purchase_setting;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'tax_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'rate', rate) ORDER BY code)
                             FROM erp.tax_code WHERE company_code = p_company AND active AND coalesce(category, 'I') <> 'O'), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', whs_code, 'name', name) ORDER BY whs_code)
                              FROM erp.warehouse WHERE company_code = p_company AND active), '[]'::jsonb),
    'payment_terms', coalesce((SELECT jsonb_agg(jsonb_build_object('code', group_num, 'name', name, 'days', extra_days) ORDER BY group_num)
                                 FROM erp.payment_terms WHERE company_code = p_company), '[]'::jsonb),
    'offices', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                           FROM erp.china_office WHERE company_code = p_company AND active), '[]'::jsonb),
    'pi_statuses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                               FROM erp.pi_status WHERE company_code = p_company AND active), '[]'::jsonb),
    'qc_checklist', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                                FROM erp.qc_checklist_item WHERE company_code = p_company AND active), '[]'::jsonb),
    'landed_cost_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'split_method', split_method) ORDER BY code)
                                     FROM erp.landed_cost_code WHERE company_code = p_company AND active), '[]'::jsonb),
    'default_tax_code', st.default_tax_code,
    'default_whs_code', st.default_whs_code,
    'require_qc_pass', coalesce(st.require_qc_pass, false),
    'numbering', (SELECT jsonb_object_agg(obj_type::text, prefix) FROM erp.number_series
                   WHERE company_code = p_company AND active AND obj_type IN (1470000113, 540000006, 22, 20, 204, 18, 69)),
    'my_po_limit', erp._apr_my_limit(p_company, 22, 'po_amount', u.position_code),
    'price_increase_pct', erp._apr_my_limit(p_company, 22, 'po_price_increase', u.position_code),
    'can_write', erp.can_write('purchase'),
    'can_request', erp.can_read('purchase'),
    'can_finance', erp.can_write('finance'));
END $$;

-- ---- inventory_setup: copied from 22_inventory.sql:1277
-- ============ API: setup ============
-- Everything the inventory screens need: warehouses (bins, stock account), bins, reasons and the accounts a goods receipt /
-- issue may use (postable, not control, not frozen), item groups, numbering, the caller's limits and the count rules.
CREATE OR REPLACE FUNCTION erp.inventory_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._inv_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', w.whs_code, 'name', w.name, 'bins', coalesce(s.bins_enabled, false),
                                                                 'stock_acct', s.stock_acct, 'allow_negative', coalesce(s.allow_negative, false),
                                                                 'locked', w.locked) ORDER BY w.whs_code)
                              FROM erp.warehouse w LEFT JOIN erp.warehouse_setting s ON s.company_code = w.company_code AND s.whs_code = w.whs_code
                             WHERE w.company_code = p_company AND w.active), '[]'::jsonb),
    'bins', coalesce((SELECT jsonb_agg(jsonb_build_object('code', b.bin_code, 'whs_code', b.whs_code, 'name', b.name, 'active', b.active,
                                                           'qty', (SELECT coalesce(sum(qty), 0) FROM erp.bin_stock bs WHERE bs.bin_id = b.bin_id)) ORDER BY b.bin_code)
                        FROM erp.bin_location b WHERE b.company_code = p_company), '[]'::jsonb),
    'reasons', coalesce((SELECT jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'direction', r.direction, 'acct_code', r.acct_code,
                                                              'acct_name', a.name, 'active', r.active, 'source', r.source) ORDER BY r.code)
                           FROM erp.inventory_reason r LEFT JOIN erp.account a ON a.company_code = r.company_code AND a.acct_code = r.acct_code
                          WHERE r.company_code = p_company), '[]'::jsonb),
    'accounts', coalesce((SELECT jsonb_agg(jsonb_build_object('code', a.acct_code, 'name', a.name) ORDER BY a.acct_code)
                            FROM erp.account a WHERE a.company_code = p_company AND a.postable AND NOT coalesce(a.is_control, false) AND NOT coalesce(a.frozen, false)), '[]'::jsonb),
    'item_groups', coalesce((SELECT jsonb_agg(jsonb_build_object('code', g.group_code, 'name', g.name) ORDER BY g.group_code)
                               FROM erp.item_group g WHERE g.company_code = p_company), '[]'::jsonb),
    'numbering', (SELECT jsonb_object_agg(obj_type::text, prefix) FROM erp.number_series WHERE company_code = p_company AND active
                     AND obj_type IN (1250000001, 67, 59, 60, 1470000065)),
    'my_limits', (SELECT jsonb_object_agg(o::text, erp._apr_my_limit(p_company, o, 'stock_doc_amount', u.position_code)) FROM unnest(ARRAY[59, 60]) o
                    WHERE erp._apr_my_limit(p_company, o, 'stock_doc_amount', u.position_code) IS NOT NULL),
    'count_rules', jsonb_build_object(
       'pct', erp._apr_my_limit(p_company, 1470000065, 'count_variance_pct', u.position_code),
       'value', erp._apr_my_limit(p_company, 1470000065, 'count_variance_value', u.position_code)),
    'blind_count', coalesce((SELECT blind_count FROM erp.inventory_setting WHERE company_code = p_company), true),
    'can_write', erp.can_write('inventory'),
    'can_finance', erp.can_write('finance'));
END $$;

-- ---- journal_decide: copied from 18_posting.sql:797
-- Approve or reject the current step. The last approval posts the journal (checks run again: the period may have closed).
CREATE OR REPLACE FUNCTION erp.journal_decide(p_company varchar, p_draft_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  j       erp.journal_draft;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_vote  text;
  v_who   text;
  v_left  integer;
  v_state text;
  v_trans integer;
  inp     jsonb;
  e       jsonb;
  sp      erp.app_user;
BEGIN
  u := erp._je_guard(p_company, true);
  j := erp._je_lock(p_company, p_draft_id);
  IF j.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This journal is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF j.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own journal.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own journal. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND erp._apr_is_mine(approval_id, u);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, 'journal', p_draft_id::text, v_step);
    RAISE EXCEPTION 'This journal is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this journal.' USING ERRCODE = 'P0001';
  END IF;

  v_vote := erp._apr_vote(v_mine, u, p_decision, v_note);

  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.journal_draft SET state = 'rejected', decided_at = now(), updated_at = now() WHERE draft_id = p_draft_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      SELECT * INTO sp FROM erp.app_user WHERE user_id = j.submitted_by;
      inp := erp._je_stored(p_draft_id);
      e := erp._je_eval(p_company, inp->'header', inp->'lines', sp.position_code);
      IF jsonb_array_length(e->'errors') > 0 THEN
        RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Nothing was posted. Reject it so the creator can fix it.';
      END IF;
      v_trans := erp._je_post_draft(p_draft_id, e);
      v_state := 'posted';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'journal_approve' ELSE 'journal_reject' END, 'journal_draft',
          p_draft_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state, 'trans_id', v_trans));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', v_state, 'trans_id', v_trans);
END $$;

-- ---- sales_doc_decide: copied from 19_sales_cycle.sql:1075
-- Approve or reject the current step. p_new_discount = "Approve at n %": lowers the flagged discounts to n and recalculates.
CREATE OR REPLACE FUNCTION erp.sales_doc_decide(p_company varchar, p_obj integer, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL,
                                                p_new_discount numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  w        erp.doc_workflow;
  v_note   text := nullif(btrim(p_note), '');
  v_step   smallint;
  v_mine   bigint[];
  v_vote   text;
  v_who    text;
  v_limit  numeric;
  v_flag   integer[];
  v_maxd   numeric;
  v_left   integer;
  v_state  text;
  v_noun   text := erp._sd_noun(p_obj);
  v_obj    text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  w := erp._sd_lock(p_company, p_obj, p_doc_entry);
  IF w.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This % is not waiting for approval.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF w.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own %.', v_noun USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own %. Cancel it instead if it is no longer needed.', v_noun USING ERRCODE = 'P0001';
  END IF;

  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND erp._apr_is_mine(approval_id, u);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, v_obj, p_doc_entry::text, v_step);
    RAISE EXCEPTION 'This % is waiting for approval from %. Your position can''t decide it.', v_noun, coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this %.', v_noun USING ERRCODE = 'P0001';
  END IF;

  IF p_new_discount IS NOT NULL THEN
    IF p_decision <> 'approved' THEN
      RAISE EXCEPTION 'Approve at a lower discount only works with approve.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT (ln.v)::integer), max((a.detail->>'max_value')::numeric) INTO v_flag, v_maxd
      FROM erp.approval a CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(a.detail->'lines', '[]'::jsonb)) AS ln(v)
     WHERE a.approval_id = ANY (v_mine) AND a.rule_code = 'discount_pct';
    IF v_flag IS NULL THEN
      RAISE EXCEPTION 'Approve at a lower discount only applies to a discount approval.' USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount < 0 OR p_new_discount > 100 THEN
      RAISE EXCEPTION 'The discount must be between 0 and 100%%.' USING ERRCODE = 'P0001';
    END IF;
    v_limit := erp._apr_my_limit(p_company, 17, 'discount_pct', u.position_code);
    IF v_limit IS NULL THEN
      RAISE EXCEPTION 'Your position has no discount limit set, so you can''t approve at a different discount. Approve or reject the % as it is.', v_noun
        USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount > v_limit THEN
      RAISE EXCEPTION '%', format('Discount %s%% is above your own limit of %s%%. Approve the %s as it is, or choose a lower discount.',
        erp._pct(p_new_discount), erp._pct(v_limit), v_noun) USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount >= v_maxd THEN
      RAISE EXCEPTION '%', format('Approve at %s%% must be lower than the requested discount of %s%%.', erp._pct(p_new_discount), erp._pct(v_maxd))
        USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.document_line l
       SET discount_pct = p_new_discount,
           line_total = round(l.quantity * l.price * (1 - p_new_discount / 100), 2),
           vat = round(round(l.quantity * l.price * (1 - p_new_discount / 100), 2)
                       * coalesce((SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code), 0) / 100, 2)
     WHERE l.company_code = p_company AND l.obj_type = p_obj AND l.doc_entry = p_doc_entry
       AND l.line_num + 1 = ANY (v_flag) AND l.discount_pct > p_new_discount;
    UPDATE erp.document d
       SET vat_total = s.vat, total = s.net + s.vat
      FROM (SELECT coalesce(sum(line_total), 0) AS net, coalesce(sum(vat), 0) AS vat FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry) s
     WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry AND d.source = 'erp';
  END IF;

  v_vote := erp._apr_vote(v_mine, u, p_decision,
                          coalesce(v_note, CASE WHEN p_new_discount IS NOT NULL THEN format('Approved at %s%%', erp._pct(p_new_discount)) END),
                          CASE WHEN p_new_discount IS NOT NULL THEN jsonb_build_object('approved_at', p_new_discount) ELSE '{}'::jsonb END);

  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    v_state := 'rejected';
    UPDATE erp.doc_workflow SET state = 'rejected', decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      v_state := 'approved';
      UPDATE erp.doc_workflow SET state = 'approved', decided_at = now(), updated_at = now()
       WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
      UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN p_decision = 'approved' THEN '_approve' ELSE '_reject' END,
          v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note,
                             'approved_at', p_new_discount, 'state', v_state));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
                            'total', (SELECT total FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry));
END $$;

-- ---- payment_decide: copied from 20_banking.sql:839
-- Approve or reject the current step. The last approval checks the payment again and posts it. Approvers need an approver
-- position on the current step and read access to Banking (the Owner approves without write access to Financials).
CREATE OR REPLACE FUNCTION erp.payment_decide(p_company varchar, p_draft_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  p       erp.payment_draft;
  sp      erp.app_user;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_vote  text;
  v_who   text;
  v_left  integer;
  v_state text;
  e       jsonb;
  r       jsonb;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO p FROM erp.payment_draft WHERE company_code = p_company AND draft_id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment draft % was not found in company %.', p_draft_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF p.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This payment is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p.created_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own payment.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own payment. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND erp._apr_is_mine(approval_id, u);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, 'payment', p_draft_id::text, v_step);
    RAISE EXCEPTION 'This payment is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this payment.' USING ERRCODE = 'P0001';
  END IF;

  v_vote := erp._apr_vote(v_mine, u, p_decision, v_note);
  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.payment_draft SET state = 'rejected', decided_at = now() WHERE draft_id = p_draft_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      SELECT * INTO sp FROM erp.app_user WHERE user_id = p.created_by;
      e := erp._pay_eval(p_company, p.direction, p.header, p.lines, sp.position_code, p_draft_id);
      IF jsonb_array_length(e->'errors') > 0 THEN
        RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Nothing was paid. Reject it so the creator can enter it again.';
      END IF;
      r := erp._pay_post(p_company, p.direction, e, p.created_by, p_draft_id);
      UPDATE erp.payment_draft SET state = 'posted', decided_at = now(), doc_entry = (r->>'doc_entry')::integer WHERE draft_id = p_draft_id;
      v_state := 'posted';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'payment_approve' ELSE 'payment_reject' END, 'payment_draft',
          p_draft_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state,
                                               'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id'));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', v_state, 'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id',
                            'direction', p.direction);
END $$;

-- ---- purchase_doc_decide: copied from 21_purchasing.sql:1270
-- Approve or reject the current step of a purchase order.
CREATE OR REPLACE FUNCTION erp.purchase_doc_decide(p_company varchar, p_obj integer, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  w        erp.doc_workflow;
  v_note   text := nullif(btrim(p_note), '');
  v_step   smallint;
  v_mine   bigint[];
  v_vote   text;
  v_who    text;
  v_left   integer;
  v_state  text;
  v_noun   text := erp._pd_noun(p_obj);
  v_obj    text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, 'approve purchase orders');
  w := erp._pd_lock(p_company, p_obj, p_doc_entry);
  IF w.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This % is not waiting for approval.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF w.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own %.', v_noun USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own %. Cancel it instead if it is no longer needed.', v_noun USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND erp._apr_is_mine(approval_id, u);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, v_obj, p_doc_entry::text, v_step);
    RAISE EXCEPTION 'This % is waiting for approval from %. Your position can''t decide it.', v_noun, coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this %.', v_noun USING ERRCODE = 'P0001';
  END IF;

  v_vote := erp._apr_vote(v_mine, u, p_decision, v_note);
  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    v_state := 'rejected';
    UPDATE erp.doc_workflow SET state = 'rejected', decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      v_state := 'approved';
      UPDATE erp.doc_workflow SET state = 'approved', decided_at = now(), updated_at = now()
       WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
      UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN p_decision = 'approved' THEN '_approve' ELSE '_reject' END, v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry));
END $$;

-- ---- _inv_decide: copied from 22_inventory.sql:1234
-- Approve or reject the current step of an approval (shared by goods receipt / issue and counts). Returns the remaining count
-- of open approvals after the decision (0 = fully approved), or -1 when rejected. Raises when the user can't decide.
CREATE OR REPLACE FUNCTION erp._inv_decide(p_company varchar, p_object text, p_ref text, p_noun text, p_submitted_by uuid, p_user erp.app_user,
                                           p_decision text, p_note text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_note text := nullif(btrim(p_note), '');
  v_step smallint;
  v_mine bigint[];
  v_vote text;
  v_who  text;
  v_left integer;
BEGIN
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p_submitted_by = p_user.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own %.', p_noun USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own %. Cancel it instead if it is no longer needed.', p_noun USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded AND step = v_step
     AND erp._apr_is_mine(approval_id, p_user);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, p_object, p_ref, v_step);
    RAISE EXCEPTION 'This % is waiting for approval from %. Your position can''t decide it.', p_noun, coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this %.', p_noun USING ERRCODE = 'P0001';
  END IF;
  v_vote := erp._apr_vote(v_mine, p_user, p_decision, v_note);
  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
    RETURN -1;
  END IF;
  SELECT count(*) INTO v_left FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
  RETURN v_left;
END $$;

-- ---- sales_doc_request_decide: copied from 30_numbering_company.sql:2605
-- Approve or reject the current step. The last approval creates the document (as its requester, from the series picked).
CREATE OR REPLACE FUNCTION erp.sales_doc_request_decide(p_company varchar, p_request_id bigint, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._sd_req_guard(p_company);
  q       erp.sales_doc_request;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_vote  text;
  v_who   text;
  v_left  integer;
  v_state text;
  r       jsonb;
BEGIN
  SELECT * INTO q FROM erp.sales_doc_request WHERE company_code = p_company AND request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request % was not found in company %.', coalesce(p_request_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF q.requested_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own request.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own request. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND erp._apr_is_mine(approval_id, u);
  IF v_mine IS NULL THEN
    v_who := erp._apr_who(p_company, 'sales_doc_request', p_request_id::text, v_step);
    RAISE EXCEPTION 'This request is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this request.' USING ERRCODE = 'P0001';
  END IF;

  v_vote := erp._apr_vote(v_mine, u, p_decision, v_note);
  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.sales_doc_request SET state = 'rejected', decided_at = now(), note = v_note WHERE request_id = p_request_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      PERFORM set_config('erp.series', coalesce(q.series_id::text, ''), true);
      PERFORM set_config('erp.series_user', q.requested_by::text, true);
      PERFORM set_config('erp.series_date', coalesce(q.header->>'doc_date', ''), true);
      r := CASE q.obj_type WHEN 13 THEN erp._sd_inv_exec(p_company, q.header, q.lines, q.requested_by)
                           ELSE erp._sd_cm_exec(p_company, q.header, q.lines, q.requested_by) END;
      PERFORM erp._series_clear();
      UPDATE erp.sales_doc_request SET state = 'approved', decided_at = now(), doc_entry = (r->>'doc_entry')::integer, doc_no = r->>'doc_no'
       WHERE request_id = p_request_id;
      v_state := 'approved';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'sales_doc_request_approve' ELSE 'sales_doc_request_reject' END,
          'sales_doc_request', p_request_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state,
                                                                      'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id'));
  RETURN jsonb_build_object('request_id', p_request_id, 'state', v_state, 'obj_type', q.obj_type, 'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no',
                            'trans_id', r->'trans_id');
END $$;

-- ---- company_details_submit: copied from 25_admin.sql:973
-- Ask for a change to the printed company details. The owner position approves it before it applies.
CREATE OR REPLACE FUNCTION erp.company_details_submit(p_company varchar, p_changes jsonb, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  c      erp.company := erp._adm_company(p_company);
  v_own  text;
  v_cur  jsonb := erp._adm_profile(p_company);
  v_new  jsonb;
  k      text;
  v_id   bigint;
  v_fy   text;
  v_tpl  jsonb;
BEGIN
  IF jsonb_typeof(p_changes) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the changed fields.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_changes) LOOP
    IF k NOT IN ('legal_name', 'trading_name', 'tax_id', 'licence_no', 'address', 'phone', 'email', 'logo_path', 'fiscal_year_start') THEN
      RAISE EXCEPTION 'Field % can''t be changed here.', k USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  -- Normalise: trimmed text, empty = NULL.
  SELECT jsonb_object_agg(key, CASE WHEN jsonb_typeof(value) = 'string' THEN to_jsonb(nullif(btrim(value #>> '{}'), '')) ELSE value END)
    INTO v_new FROM jsonb_each(p_changes);
  v_new := v_cur || coalesce(v_new, '{}'::jsonb);
  IF v_new->>'legal_name' IS NULL THEN
    RAISE EXCEPTION 'Enter the legal name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_new->>'legal_name') > 200 THEN
    RAISE EXCEPTION 'The legal name can have up to 200 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF c.country = 'AE' AND v_new->>'tax_id' IS NOT NULL AND v_new->>'tax_id' !~ '^\d{15}$' THEN
    RAISE EXCEPTION 'A UAE TRN has 15 digits. Check the number on the VAT certificate.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'email' IS NOT NULL AND v_new->>'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Enter a valid email address, for example accounts@company.com.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'phone' IS NOT NULL AND v_new->>'phone' !~ '^\+?[0-9 ()-]{6,20}$' THEN
    RAISE EXCEPTION 'Enter the phone number with digits only, for example +971 4 123 4567.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'logo_path' IS NOT NULL AND v_new->>'logo_path' NOT LIKE p_company || '/%' THEN
    RAISE EXCEPTION 'The logo must be stored under %/ in the branding bucket.', p_company USING ERRCODE = 'P0001';
  END IF;
  v_fy := v_new->>'fiscal_year_start';
  IF v_fy IS NOT NULL AND (v_fy !~ '^\d{1,2}$' OR v_fy::int NOT BETWEEN 1 AND 12) THEN
    RAISE EXCEPTION 'Choose the month the fiscal year starts (1 to 12).' USING ERRCODE = 'P0001';
  END IF;
  IF v_fy IS NOT NULL THEN
    v_new := jsonb_set(v_new, '{fiscal_year_start}', to_jsonb(v_fy::int));
  END IF;
  IF v_new = v_cur THEN
    RAISE EXCEPTION 'Nothing changed.' USING ERRCODE = 'P0001';
  END IF;
  -- B2: an active "company details" approval template decides the stages; without one the owner position approves (as before).
  v_tpl := (SELECT coalesce(jsonb_agg(r.ck ORDER BY r.step, r.template_id), '[]'::jsonb) FROM erp._apr_rules(p_company, 0, ARRAY['company_details'], me.position_code) r);
  SELECT owner_position INTO v_own FROM erp.admin_setting WHERE company_code = p_company;
  IF v_own IS NULL AND jsonb_array_length(v_tpl) = 0 THEN
    RAISE EXCEPTION 'Set the owner position for % first. The owner approves changes to company details.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.company_change_request WHERE company_code = p_company AND state = 'pending_approval') THEN
    RAISE EXCEPTION 'A change to % is already waiting for the owner''s approval. Wait for it or withdraw it first.', p_company USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.company_change_request (company_code, before, after, reason, requested_by)
  VALUES (p_company, v_cur, v_new, nullif(btrim(p_reason), ''), me.user_id)
  RETURNING request_id INTO v_id;
  IF jsonb_array_length(v_tpl) > 0 THEN
    INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
    SELECT p_company, 'company_details', v_id::text, (x->>'step')::smallint, x->>'approver_position', 'company_details', me.user_id, now(),
           jsonb_build_object('checks', jsonb_build_array(x || jsonb_build_object('message', format('Company details change needs approval (%s).', x->>'stage_name')))))
      FROM jsonb_array_elements(v_tpl) x;
    v_own := v_tpl->0->>'approver_position';
  ELSE
    INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
    VALUES (p_company, 'company_details', v_id::text, 1, v_own, 'company_details', me.user_id, now(),
            jsonb_build_object('checks', jsonb_build_array(jsonb_build_object('message', 'Company details change needs the owner''s approval.'))));
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'company_details_submit', 'company_details', v_id::text,
          jsonb_build_object('before', v_cur, 'after', v_new, 'reason', p_reason));
  RETURN jsonb_build_object('request_id', v_id, 'state', 'pending_approval', 'approver_position', v_own);
END $$;

-- ---- company_details_decide: copied from 25_admin.sql:1044
CREATE OR REPLACE FUNCTION erp.company_details_decide(p_company varchar, p_request_id bigint, p_decision text, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user;
  q  erp.company_change_request;
  a  erp.approval;
  n  jsonb;
  v_mine  bigint[];
  v_vote  text;
  v_state text;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO me FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  PERFORM erp._adm_company(p_company);
  SELECT * INTO q FROM erp.company_change_request WHERE request_id = p_request_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % not found in %.', p_request_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This change is no longer waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO a FROM erp.approval WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text
     AND decision IS NULL AND NOT superseded ORDER BY step LIMIT 1 FOR UPDATE;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text
     AND decision IS NULL AND NOT superseded AND step = a.step AND me.user_id IS NOT NULL AND erp._apr_is_mine(approval_id, me);
  IF v_mine IS NULL THEN
    IF a.stage_id IS NOT NULL THEN
      RAISE EXCEPTION 'This change is waiting for approval from %. Your position can''t decide it.',
        coalesce(erp._apr_who(p_company, 'company_details', p_request_id::text, a.step), '?') USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Only the owner position (%) can approve company detail changes.', coalesce(a.approver_position, '?') USING ERRCODE = '42501';
  END IF;
  IF q.requested_by = me.user_id THEN
    RAISE EXCEPTION 'You can''t approve your own change.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose Approve or Reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you reject the change.' USING ERRCODE = 'P0001';
  END IF;
  v_vote := erp._apr_vote(v_mine, me, p_decision, nullif(btrim(p_note), ''));
  IF v_vote = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
    v_state := 'rejected';
  ELSIF EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text
                   AND decision IS NULL AND NOT superseded) THEN
    v_state := 'pending_approval';
  ELSE
    v_state := 'approved';
  END IF;
  IF v_state <> 'pending_approval' THEN
    UPDATE erp.company_change_request SET state = v_state, decided_by = me.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
     WHERE request_id = p_request_id;
  END IF;
  IF v_state = 'approved' THEN
    n := q.after;
    INSERT INTO erp.company_profile (company_code, legal_name, trading_name, tax_id, licence_no, address, phone, email, logo_path,
                                     fiscal_year_start, updated_at, requested_by, approved_by)
    VALUES (p_company, n->>'legal_name', n->>'trading_name', n->>'tax_id', n->>'licence_no', n->>'address', n->>'phone', n->>'email',
            n->>'logo_path', (n->>'fiscal_year_start')::smallint, now(), q.requested_by, me.user_id)
    ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, trading_name = EXCLUDED.trading_name, tax_id = EXCLUDED.tax_id,
      licence_no = EXCLUDED.licence_no, address = EXCLUDED.address, phone = EXCLUDED.phone, email = EXCLUDED.email, logo_path = EXCLUDED.logo_path,
      fiscal_year_start = EXCLUDED.fiscal_year_start, updated_at = now(), requested_by = EXCLUDED.requested_by, approved_by = EXCLUDED.approved_by;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'company_details_' || p_decision, 'company_details', p_request_id::text,
          jsonb_build_object('note', p_note, 'after', q.after, 'step', a.step, 'state', v_state));
  RETURN jsonb_build_object('request_id', p_request_id, 'state', v_state);
END $$;

-- ---- journal_draft_info: copied from 18_posting.sql:902
-- Everything the draft page needs: header, lines with account names, approvals, what the caller may do, activity.
CREATE OR REPLACE FUNCTION erp.journal_draft_info(p_company varchar, p_draft_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  j       erp.journal_draft;
  v_write boolean;
  v_step  smallint;
  v_mine  boolean;
BEGIN
  u := erp._je_guard(p_company, false);
  SELECT * INTO j FROM erp.journal_draft WHERE company_code = p_company AND draft_id = p_draft_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_write := erp.can_write('finance');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  RETURN jsonb_build_object(
    'draft_id', j.draft_id, 'company_code', j.company_code, 'state', j.state,
    'ref_date', j.ref_date, 'due_date', j.due_date, 'memo', j.memo, 'ref1', j.ref1, 'ref2', j.ref2, 'total', j.total, 'currency', j.currency,
    'trans_id', j.trans_id, 'posted_at', j.posted_at, 'reason', j.reason, 'cancel_note', j.cancel_note, 'cancelled_at', j.cancelled_at,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = j.created_by), 'created_at', j.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = j.submitted_by), 'submitted_at', j.submitted_at,
    'is_creator', j.created_by = u.user_id, 'is_submitter', j.submitted_by = u.user_id,
    'can_edit', v_write AND j.created_by = u.user_id AND j.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND j.created_by = u.user_id AND j.state IN ('draft', 'rejected', 'pending_approval'),
    'can_decide', v_write AND j.state = 'pending_approval' AND j.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'acct_code', l.acct_code, 'acct_name', a.name,
                                                          'debit', l.debit, 'credit', l.credit, 'memo', l.memo) ORDER BY l.line_num)
                         FROM erp.journal_draft_line l LEFT JOIN erp.account a ON a.company_code = l.company_code AND a.acct_code = l.acct_code
                        WHERE l.draft_id = j.draft_id), '[]'::jsonb),
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', erp._apr_row_who(a.approval_id, p.name), 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id, 'requested_at', a.requested_at,
               'detail', a.detail, 'superseded', a.superseded, 'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', erp._apr_is_mine(a.approval_id, u)) ORDER BY a.approval_id)
        FROM erp.approval a LEFT JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
       WHERE a.company_code = p_company AND a.object = 'journal' AND a.object_ref = p_draft_id::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = 'journal_draft' AND l.object_ref = p_draft_id::text), '[]'::jsonb));
END $$;

-- ---- sales_doc_info: copied from 19_sales_cycle.sql:1247
-- Everything the quotation / order page needs beyond the document itself. NULL when not visible; {workflow:false} for SAP / sample.
CREATE OR REPLACE FUNCTION erp.sales_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  d        erp.document;
  w        erp.doc_workflow;
  v_write  boolean;
  v_step   smallint;
  v_mine   boolean;
  v_appr   boolean;
  v_child  boolean;
  v_live_child boolean;
  v_open   boolean;
  v_sub_pos text;
  v_obj    text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._so_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN jsonb_build_object('workflow', false, 'source', d.source); END IF;

  v_write := erp.can_write('sales');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND erp._apr_can_act(approval_id, u));
  v_child := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = p_obj AND base_doc_entry = p_doc_entry);
  v_live_child := EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                           WHERE l.company_code = p_company AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled');
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND coalesce(line_status, 'O') = 'O');
  SELECT position_code INTO v_sub_pos FROM erp.app_user WHERE user_id = w.submitted_by;

  RETURN jsonb_build_object(
    'workflow', true,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', w.doc_no,
    'state', w.state,
    'status', d.status,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'price_list', w.price_list, 'payment_terms', w.payment_terms, 'whs_code', w.whs_code,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_edit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_submit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND w.state <> 'cancelled' AND NOT (CASE WHEN p_obj = 17 THEN v_child ELSE v_live_child END)
                  AND (w.created_by = u.user_id OR v_appr),
    'can_decide', v_write AND w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_copy', v_write AND w.state = 'approved' AND d.status = 'open' AND v_open,
    'copy_block', CASE WHEN w.state <> 'approved' THEN 'not_approved' WHEN d.status <> 'open' OR NOT v_open THEN 'closed'
                       WHEN NOT v_write THEN 'read_only' END,
    'atp_reason_logged', (SELECT l.detail->'atp' FROM erp.audit_log l WHERE l.company_code = p_company AND l.object = v_obj
                            AND l.object_ref = p_doc_entry::text AND l.action = v_obj || '_submit' ORDER BY l.at DESC, l.audit_id DESC LIMIT 1),
    'my_discount_limit', erp._apr_my_limit(p_company, 17, 'discount_pct', u.position_code),
    'requester_discount_limit', erp._apr_my_limit(p_company, 17, 'discount_pct', v_sub_pos),
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', erp._apr_row_who(a.approval_id, p.name), 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id,
               'requested_by_name', ru.display_name, 'requested_at', a.requested_at, 'detail', a.detail, 'superseded', a.superseded,
               'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', erp._apr_is_mine(a.approval_id, u)) ORDER BY a.approval_id)
        FROM erp.approval a
        LEFT JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
        LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
       WHERE a.company_code = p_company AND a.object = v_obj AND a.object_ref = p_doc_entry::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l
        LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = v_obj AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- ---- sales_doc_cancel: copied from 19_sales_cycle.sql:1203
-- Cancel: the creator or one of the document's approvers, with a note. An order with a delivery, or a quotation copied
-- to a live order, can't be cancelled.
CREATE OR REPLACE FUNCTION erp.sales_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  v_note text := nullif(btrim(p_note), '');
  v_noun text := erp._sd_noun(p_obj);
  v_obj  text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  w := erp._sd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 17 AND EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = 17 AND base_doc_entry = p_doc_entry) THEN
    RAISE EXCEPTION 'This order has a delivery and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 23 AND EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                             WHERE l.company_code = p_company AND l.base_obj_type = 23 AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This quotation was copied to a sales order and can''t be cancelled. Cancel the order first.' USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (
       SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
          AND erp._apr_can_act(approval_id, u)) THEN
    RAISE EXCEPTION 'Only the person who created this % or one of its approvers can cancel it.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the % is cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note, updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.document_line SET line_status = 'C' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'from_state', w.state, 'note', v_note));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled', 'status', 'cancelled');
END $$;

-- ---- payment_draft_info: copied from 20_banking.sql:947
-- Everything the payment draft page needs.
CREATE OR REPLACE FUNCTION erp.payment_draft_info(p_company varchar, p_draft_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  p      erp.payment_draft;
  v_step smallint;
  v_mine boolean;
  v_write boolean;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO p FROM erp.payment_draft WHERE company_code = p_company AND draft_id = p_draft_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_write := erp.can_write('banking') OR erp.can_write('finance');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  RETURN jsonb_build_object(
    'draft_id', p.draft_id, 'company_code', p.company_code, 'direction', p.direction, 'state', p.state, 'doc_date', p.doc_date,
    'card_code', p.card_code, 'card_name', p.card_name, 'total', p.total, 'currency', p.currency, 'header', p.header, 'lines', p.lines,
    'checks', p.checks, 'reason', p.reason, 'doc_entry', p.doc_entry,
    'doc_no', (SELECT doc_no FROM erp.payment_extra WHERE company_code = p_company AND direction = p.direction AND doc_entry = p.doc_entry),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = p.created_by), 'created_at', p.created_at,
    'cancel_note', p.cancel_note, 'cancelled_at', p.cancelled_at, 'decided_at', p.decided_at,
    'is_creator', p.created_by = u.user_id,
    'can_cancel', v_write AND p.created_by = u.user_id AND p.state IN ('pending_approval', 'rejected'),
    'can_decide', p.state = 'pending_approval' AND p.created_by <> u.user_id AND v_mine,
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', erp._apr_row_who(a.approval_id, ps.name), 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id, 'requested_at', a.requested_at,
               'detail', a.detail, 'superseded', a.superseded, 'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', erp._apr_is_mine(a.approval_id, u)) ORDER BY a.step, a.approval_id)
        FROM erp.approval a LEFT JOIN erp.position ps ON ps.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
       WHERE a.company_code = p_company AND a.object = 'payment' AND a.object_ref = p_draft_id::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND ((l.object = 'payment_draft' AND l.object_ref = p_draft_id::text)
                                          OR (p.doc_entry IS NOT NULL AND l.object = 'payment' AND l.object_ref = p.direction || '/' || p.doc_entry))), '[]'::jsonb));
END $$;

-- ---- purchase_doc_info: copied from 21_purchasing.sql:1390
-- What the request / quotation / order page needs beyond the document. NULL when not visible; {workflow:false} for SAP / sample.
-- A purchase order also gets its proforma invoices, down payments, QC inspections and shipments.
CREATE OR REPLACE FUNCTION erp.purchase_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  d        erp.document;
  w        erp.doc_workflow;
  st       erp.purchase_setting;
  v_write  boolean;
  v_step   smallint;
  v_mine   boolean;
  v_appr   boolean;
  v_live_child boolean;
  v_open   boolean;
  v_obj    text := erp._pd_object(p_obj);
  v_lastqc text;
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN jsonb_build_object('workflow', false, 'source', d.source); END IF;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;

  v_write := erp.can_write('purchase') OR (p_obj = 1470000113 AND erp.can_read('purchase'));
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND erp._apr_can_act(approval_id, u));
  v_live_child := EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                           WHERE l.company_code = p_company AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled'
                             AND (p_obj = 22 OR l.obj_type = 22))
                  OR (p_obj = 22 AND EXISTS (SELECT 1 FROM erp.purchase_shipment WHERE company_code = p_company AND po_doc_entry = p_doc_entry));
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND coalesce(line_status, 'O') = 'O');
  SELECT result INTO v_lastqc FROM erp.qc_inspection WHERE company_code = p_company AND po_doc_entry = p_doc_entry ORDER BY qc_id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'workflow', true,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', w.doc_no,
    'state', w.state,
    'status', d.status,
    'china_office', w.china_office,
    'china_office_name', (SELECT name FROM erp.china_office WHERE company_code = p_company AND code = w.china_office),
    'whs_code', w.whs_code, 'payment_terms', w.payment_terms,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_edit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_submit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND w.state <> 'cancelled' AND NOT v_live_child AND (w.created_by = u.user_id OR v_appr),
    'can_decide', erp.can_write('purchase') AND w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_copy', erp.can_write('purchase') AND w.state = 'approved' AND d.status = 'open' AND v_open,
    'copy_block', CASE WHEN w.state <> 'approved' THEN 'not_approved' WHEN d.status <> 'open' OR NOT v_open THEN 'closed'
                       WHEN NOT erp.can_write('purchase') THEN 'read_only' END,
    'can_write', erp.can_write('purchase'),
    'can_finance', erp.can_write('finance'),
    'require_qc_pass', coalesce(st.require_qc_pass, false),
    'last_qc', v_lastqc,
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', erp._apr_row_who(a.approval_id, p.name), 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id,
               'requested_by_name', ru.display_name, 'requested_at', a.requested_at, 'detail', a.detail, 'superseded', a.superseded,
               'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', erp._apr_is_mine(a.approval_id, u)) ORDER BY a.approval_id)
        FROM erp.approval a
        LEFT JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
        LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
       WHERE a.company_code = p_company AND a.object = v_obj AND a.object_ref = p_doc_entry::text), '[]'::jsonb),
    'pis', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('pi_id', pi.pi_id, 'vendor_pi_no', pi.vendor_pi_no, 'pi_date', pi.pi_date, 'amount', pi.amount, 'eta', pi.eta,
               'status', pi.status, 'status_name', ps.name, 'deposit_doc_entry', pi.deposit_doc_entry, 'note', pi.note, 'updated_at', pi.updated_at,
               'deposit_doc_no', (SELECT doc_no FROM erp.doc_workflow WHERE company_code = pi.company_code AND obj_type = 204 AND doc_entry = pi.deposit_doc_entry))
             ORDER BY pi.pi_id)
        FROM erp.purchase_pi pi LEFT JOIN erp.pi_status ps ON ps.company_code = pi.company_code AND ps.code = pi.status
       WHERE pi.company_code = p_company AND pi.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'deposits', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('doc_entry', dd.doc_entry, 'doc_no', dw.doc_no, 'doc_date', dd.doc_date, 'total', dd.total, 'paid', coalesce(dd.paid, 0),
               'drawn', (SELECT coalesce(sum(x.amount), 0) FROM erp.ap_dp_draw x WHERE x.company_code = dd.company_code AND x.dp_entry = dd.doc_entry),
               'status', dd.status) ORDER BY dd.doc_entry)
        FROM erp.document dd JOIN erp.doc_workflow dw ON dw.company_code = dd.company_code AND dw.obj_type = dd.obj_type AND dw.doc_entry = dd.doc_entry
       WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status <> 'cancelled'
         AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = dd.company_code AND l.obj_type = 204 AND l.doc_entry = dd.doc_entry
                        AND l.base_obj_type = 22 AND l.base_doc_entry = p_doc_entry)), '[]'::jsonb) END,
    'qcs', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('qc_id', q.qc_id, 'inspected_on', q.inspected_on, 'inspector', q.inspector, 'result', q.result,
               'checklist', q.checklist, 'photos', to_jsonb(q.photos), 'note', q.note, 'created_at', q.created_at,
               'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = q.created_by)) ORDER BY q.qc_id)
        FROM erp.qc_inspection q WHERE q.company_code = p_company AND q.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'shipments', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('shipment_id', s.shipment_id, 'container_no', s.container_no, 'shipping_mark', s.shipping_mark,
               'shipment_mode', s.shipment_mode, 'etd', s.etd, 'eta', s.eta, 'status', s.status, 'note', s.note,
               'lines', (SELECT jsonb_agg(jsonb_build_object('po_line', sl.po_line, 'item_code', sl.item_code, 'whs_code', sl.whs_code,
                                                              'qty', sl.qty, 'received_qty', sl.received_qty) ORDER BY sl.po_line)
                           FROM erp.purchase_shipment_line sl WHERE sl.shipment_id = s.shipment_id)) ORDER BY s.shipment_id)
        FROM erp.purchase_shipment s WHERE s.company_code = p_company AND s.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l
        LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company
         AND ((l.object = v_obj AND l.object_ref = p_doc_entry::text)
              OR (p_obj = 22 AND l.object IN ('purchase_pi', 'qc_inspection', 'purchase_shipment') AND l.detail->>'po_doc_entry' = p_doc_entry::text))), '[]'::jsonb));
END $$;

-- ---- purchase_doc_cancel: copied from 21_purchasing.sql:1342
-- Cancel: the creator or one of the document's approvers, with a note. A document already copied on (an order with a
-- receipt, a down payment invoice or a shipment; a request or quotation in a live order) can't be cancelled.
CREATE OR REPLACE FUNCTION erp.purchase_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  v_note text := nullif(btrim(p_note), '');
  v_noun text := erp._pd_noun(p_obj);
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, 'cancel purchasing documents', false, p_obj = 1470000113);
  w := erp._pd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 22 AND EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                             WHERE l.company_code = p_company AND l.base_obj_type = 22 AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This purchase order has a goods receipt or a down payment invoice and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 22 AND EXISTS (SELECT 1 FROM erp.purchase_shipment WHERE company_code = p_company AND po_doc_entry = p_doc_entry) THEN
    RAISE EXCEPTION 'This purchase order has a shipment and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj IN (1470000113, 540000006) AND EXISTS (
       SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
        WHERE l.company_code = p_company AND l.obj_type = 22 AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This % was copied to a purchase order and can''t be cancelled. Cancel the order first.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (
       SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND erp._apr_can_act(approval_id, u)) THEN
    RAISE EXCEPTION 'Only the person who created this % or one of its approvers can cancel it.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the % is cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note, updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.document_line SET line_status = 'C' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text, jsonb_build_object('doc_no', w.doc_no, 'from_state', w.state, 'note', v_note));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled', 'status', 'cancelled');
END $$;

-- ---- _inv_approvals: copied from 22_inventory.sql:1208
-- Approvals of one object (same shape as purchase_doc_info.approvals) and its activity (audit rows).
CREATE OR REPLACE FUNCTION erp._inv_approvals(p_company varchar, p_object text, p_ref text, p_user erp.app_user) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH cur AS (SELECT min(step) AS s FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'approval_id', a.approval_id, 'step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'rule_code', a.rule_code, 'approver_position', a.approver_position,
           'approver_position_name', erp._apr_row_who(a.approval_id, p.name), 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
           'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = p_user.user_id,
           'requested_by_name', ru.display_name, 'requested_at', a.requested_at, 'detail', a.detail, 'superseded', a.superseded,
           'current', a.decision IS NULL AND NOT a.superseded AND a.step = (SELECT s FROM cur),
           'mine', erp._apr_is_mine(a.approval_id, p_user)) ORDER BY a.approval_id), '[]'::jsonb)
    FROM erp.approval a
    LEFT JOIN erp.position p ON p.position_code = a.approver_position
    LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
    LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
   WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref
$$;

-- ---- inventory_doc_cancel: copied from 22_inventory.sql:1461
-- Cancel a goods receipt / issue that has not posted (waiting for approval, or rejected): the creator or an approver, with a note.
-- A posted one can't be cancelled: enter the opposite document (issue for a receipt, receipt for an issue).
CREATE OR REPLACE FUNCTION erp.inventory_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  w     erp.doc_workflow;
  v_obj text := erp._inv_kind(p_obj);
BEGIN
  PERFORM erp._inv_check_gr(p_obj);
  u := erp._inv_guard(p_company, true, 'cancel stock documents');
  w := erp._inv_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  ELSIF w.state = 'approved' THEN
    RAISE EXCEPTION 'This % is posted, so it can''t be cancelled. Enter a % to reverse it.', lower(erp._inv_name(p_obj)),
      CASE p_obj WHEN 59 THEN 'goods issue' ELSE 'goods receipt' END USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                                                   AND erp._apr_can_act(approval_id, u)) THEN
    RAISE EXCEPTION 'Only the person who entered this % or its approver can cancel it.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are cancelling this %.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = btrim(p_note), updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text, jsonb_build_object('doc_no', w.doc_no, 'note', btrim(p_note)));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled');
END $$;

-- ---- inventory_doc_info: copied from 22_inventory.sql:1495
-- Everything an inventory document page shows (59, 60, 67, 1250000001): workflow, approvals, line details (bins, batches /
-- serials), warehouse-journal rows, the journal, the transfer flow (request ↔ transfers) and activity.
CREATE OR REPLACE FUNCTION erp.inventory_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  d      erp.document;
  w      erp.doc_workflow;
  v_obj  text := erp._inv_kind(p_obj);
  v_step smallint;
  v_mine boolean;
  v_appr boolean;
  v_trans integer;
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (59, 60, 67, 1250000001) THEN
    RAISE EXCEPTION 'Choose an inventory document.' USING ERRCODE = 'P0001';
  END IF;
  u := erp._inv_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  SELECT trans_id INTO v_trans FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND erp._apr_can_act(approval_id, u));
  RETURN jsonb_build_object(
    'workflow', w.doc_no IS NOT NULL,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', coalesce(w.doc_no, d.doc_num::text),
    'state', w.state,
    'status', d.status,
    'whs_code', w.whs_code,
    'reason_code', w.reason_code,
    'reason_name', (SELECT name FROM erp.inventory_reason WHERE company_code = p_company AND code = w.reason_code),
    'acct_code', (SELECT min(acct_code) FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
    'acct_name', (SELECT a.name FROM erp.account a WHERE a.company_code = p_company AND a.acct_code =
                   (SELECT min(acct_code) FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry)),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_decide', w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_cancel', erp.can_write('inventory') AND d.source = 'erp' AND (
                    (p_obj IN (59, 60) AND w.state IN ('pending_approval', 'rejected') AND (w.created_by = u.user_id OR v_appr))
                 OR (p_obj = 1250000001 AND d.status = 'open' AND NOT EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = p_company
                        AND l.obj_type = 1250000001 AND l.doc_entry = p_doc_entry AND l.open_qty < l.quantity))),
    'can_copy', p_obj = 1250000001 AND d.source = 'erp' AND d.status = 'open' AND erp.can_write('inventory'),
    'can_write', erp.can_write('inventory'),
    'trans_id', v_trans,
    'can_read_journal', erp.can_read('finance'),
    'approvals', erp._inv_approvals(p_company, v_obj, p_doc_entry::text, u),
    'details', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', x.line_num, 'bin_code', x.bin_code, 'from_bin_code', x.from_bin_code, 'lots', x.lots) ORDER BY x.line_num)
                           FROM erp.inv_line_detail x WHERE x.company_code = p_company AND x.obj_type = p_obj AND x.doc_entry = p_doc_entry), '[]'::jsonb),
    'movements', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_seq', m.trans_seq, 'doc_line', m.doc_line, 'item_code', m.item_code, 'whs_code', m.whs_code,
                                                                'qty_in', m.qty_in, 'qty_out', m.qty_out, 'price', m.price) ORDER BY m.trans_seq)
                             FROM erp.stock_movement m WHERE m.company_code = p_company AND m.trans_type = p_obj AND m.doc_entry = p_doc_entry), '[]'::jsonb),
    'flow', coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('obj_type', o.obj_type, 'doc_entry', o.doc_entry, 'doc_no', coalesce(ow.doc_no, o.doc_num::text),
                                                                   'doc_date', o.doc_date, 'status', o.status))
                        FROM erp.document_line l
                        JOIN erp.document o ON o.company_code = l.company_code
                         AND ((p_obj = 1250000001 AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry AND l.base_obj_type = 1250000001 AND l.base_doc_entry = p_doc_entry)
                           OR (p_obj = 67 AND l.obj_type = 67 AND l.doc_entry = p_doc_entry AND o.obj_type = 1250000001 AND o.doc_entry = l.base_doc_entry))
                        LEFT JOIN erp.doc_workflow ow ON ow.company_code = o.company_code AND ow.obj_type = o.obj_type AND ow.doc_entry = o.doc_entry
                       WHERE l.company_code = p_company AND p_obj IN (67, 1250000001)), '[]'::jsonb),
    'activity', erp._inv_activity(p_company, v_obj, p_doc_entry::text));
END $$;

-- ---- inv_count_info: copied from 22_inventory.sql:2169
-- The count sheet and variance report. During a blind count (inventory_setting.blind_count, the default) the system quantity and
-- the variance are hidden until the count is submitted.
CREATE OR REPLACE FUNCTION erp.inv_count_info(p_company varchar, p_count_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  c      erp.inv_count;
  v_blind boolean;
  v_hide boolean;
  v_step smallint;
  v_mine boolean;
  e      jsonb;
BEGIN
  u := erp._inv_guard(p_company, false);
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_count_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_blind := coalesce((SELECT blind_count FROM erp.inventory_setting WHERE company_code = p_company), true);
  v_hide := v_blind AND c.state IN ('counting', 'rejected');
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND erp._apr_is_mine(approval_id, u));
  IF NOT v_hide THEN
    e := erp._count_eval(p_company, p_count_id, NULL);
  END IF;
  RETURN jsonb_build_object(
    'count_id', c.count_id, 'doc_no', c.doc_no, 'whs_code', c.whs_code,
    'whs_name', (SELECT name FROM erp.warehouse WHERE company_code = p_company AND whs_code = c.whs_code),
    'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = c.whs_code), false),
    'item_group', c.item_group, 'item_group_name', (SELECT name FROM erp.item_group WHERE company_code = p_company AND group_code = c.item_group),
    'count_date', c.count_date, 'state', c.state, 'comments', c.comments, 'reason', c.reason, 'n_lines', c.n_lines, 'n_counted', c.n_counted,
    'gain_value', c.gain_value, 'loss_value', c.loss_value, 'trans_id', c.trans_id, 'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = c.created_by), 'created_at', c.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = c.submitted_by), 'submitted_at', c.submitted_at,
    'posted_at', c.posted_at, 'cancel_note', c.cancel_note, 'cancelled_at', c.cancelled_at,
    'blind', v_hide,
    'is_submitter', c.submitted_by = u.user_id,
    'can_count', erp.can_write('inventory') AND c.state IN ('counting', 'rejected'),
    'can_cancel', erp.can_write('inventory') AND c.state IN ('counting', 'rejected', 'pending_approval'),
    'can_decide', c.state = 'pending_approval' AND c.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_read_journal', erp.can_read('finance'),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'item_code', l.item_code, 'description', i.name, 'barcode', i.barcode,
                                                          'uom', i.inventory_uom, 'bin_code', b.bin_code, 'counted_qty', l.counted_qty, 'added', l.added,
                                                          'counted_by_name', cu.display_name, 'counted_at', l.counted_at,
                                                          'serial', coalesce(i.serial_managed, false), 'batch', coalesce(i.batch_managed, false),
                                                          'system_qty', CASE WHEN v_hide THEN NULL ELSE l.system_qty END,
                                                          'variance', CASE WHEN v_hide OR l.counted_qty IS NULL THEN NULL ELSE l.counted_qty - l.system_qty END)
                                        ORDER BY l.line_num)
                         FROM erp.inv_count_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
                         LEFT JOIN erp.bin_location b ON b.bin_id = l.bin_id
                         LEFT JOIN erp.app_user cu ON cu.user_id = l.counted_by
                        WHERE l.company_code = p_company AND l.count_id = p_count_id), '[]'::jsonb),
    'report', CASE WHEN v_hide THEN NULL ELSE jsonb_build_object('lines', e->'lines', 'totals', e->'totals', 'errors', e->'errors') END,
    'approvals', erp._inv_approvals(p_company, 'inventory_count', p_count_id::text, u),
    'activity', erp._inv_activity(p_company, 'inventory_count', p_count_id::text));
END $$;

-- ---- sales_doc_request_info: copied from 30_numbering_company.sql:2706
-- Request page: what was asked, why it needs approval, the steps and who may decide now.
CREATE OR REPLACE FUNCTION erp.sales_doc_request_info(p_company varchar, p_request_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._sd_req_guard(p_company);
  q      erp.sales_doc_request;
  v_step smallint;
BEGIN
  SELECT * INTO q FROM erp.sales_doc_request WHERE company_code = p_company AND request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request % was not found in company %.', coalesce(p_request_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
  RETURN jsonb_build_object(
    'request', to_jsonb(q) - 'series_id' || jsonb_build_object('doc_no_req', 'REQ-' || q.request_id,
                 'requested_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = q.requested_by),
                 'series', (SELECT name FROM erp.number_series WHERE series_id = q.series_id)),
    'approvals', coalesce((SELECT jsonb_agg(jsonb_build_object('step', a.step, 'template_name', a.template_name, 'stage_name', a.stage_name, 'need_approvals', a.need_approvals, 'votes', erp._apr_votes(a.approval_id), 'approver_position', a.approver_position, 'approver_name', erp._apr_row_who(a.approval_id, p.name),
                             'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', du.display_name, 'note', a.note, 'superseded', a.superseded,
                             'rule_code', a.rule_code) ORDER BY a.step, a.approval_id)
                             FROM erp.approval a LEFT JOIN erp.position p ON p.position_code = a.approver_position
                             LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
                            WHERE a.company_code = p_company AND a.object = 'sales_doc_request' AND a.object_ref = p_request_id::text), '[]'::jsonb),
    'is_requester', q.requested_by = u.user_id,
    'can_decide', q.state = 'pending_approval' AND q.requested_by <> u.user_id
                  AND EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'sales_doc_request'
                                 AND a.object_ref = p_request_id::text AND a.decision IS NULL AND NOT a.superseded AND a.step = v_step
                                 AND erp._apr_is_mine(a.approval_id, u)));
END $$;

-- ---- company_details_info: copied from 25_admin.sql:889
CREATE OR REPLACE FUNCTION erp.company_details_info(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
  c  erp.company := erp._adm_company(p_company);
  s  erp.admin_setting;
  q  erp.company_change_request;
BEGIN
  SELECT * INTO s FROM erp.admin_setting WHERE company_code = p_company;
  SELECT * INTO q FROM erp.company_change_request WHERE company_code = p_company AND state = 'pending_approval';
  RETURN jsonb_build_object(
    'company', jsonb_build_object('company_code', c.company_code, 'legal_name', c.legal_name, 'short_name', c.short_name,
                 'country', c.country, 'currency', c.currency, 'licence_type', c.licence_type, 'licence_authority', c.licence_authority),
    'profile', erp._adm_profile(p_company),
    'setting', jsonb_build_object('owner_position', s.owner_position,
                 'owner_position_name', (SELECT name FROM erp.position WHERE position_code = s.owner_position),
                 'fx_currencies', to_jsonb(coalesce(s.fx_currencies, '{USD,SAR,CNY,EUR}'::text[]))),
    'can_write', erp.can_write('admin'),
    'pending', CASE WHEN q.request_id IS NULL THEN NULL ELSE jsonb_build_object(
                 'request_id', q.request_id, 'before', q.before, 'after', q.after, 'reason', q.reason,
                 'requested_by_name', erp._adm_name(q.requested_by), 'requested_at', q.requested_at,
                 'is_requester', q.requested_by = me.user_id,
                 'approver_position', (SELECT a.approver_position FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'company_details'
                                         AND a.object_ref = q.request_id::text AND a.decision IS NULL AND NOT a.superseded ORDER BY a.step LIMIT 1),
                 'approvals', erp._apr_trail(p_company, 'company_details', q.request_id::text),
                 'can_decide', EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'company_details'
                                         AND a.object_ref = q.request_id::text AND a.decision IS NULL AND NOT a.superseded
                                         AND a.step = (SELECT min(b.step) FROM erp.approval b WHERE b.company_code = p_company AND b.object = 'company_details'
                                                         AND b.object_ref = q.request_id::text AND b.decision IS NULL AND NOT b.superseded)
                                         AND erp._apr_is_mine(a.approval_id, me))
                               AND q.requested_by <> me.user_id) END,
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object('request_id', h.request_id, 'state', h.state, 'after', h.after, 'reason', h.reason,
                 'requested_by_name', erp._adm_name(h.requested_by), 'requested_at', h.requested_at,
                 'decided_by_name', erp._adm_name(h.decided_by), 'decided_at', h.decided_at, 'note', h.note) ORDER BY h.requested_at DESC)
                 FROM (SELECT * FROM erp.company_change_request WHERE company_code = p_company AND state <> 'pending_approval'
                        ORDER BY requested_at DESC LIMIT 10) h), '[]'::jsonb));
END $$;


-- ============ 5. Approval Process screens (Administration) ============
-- Read = Administration (admin / IT / owner, _adm_guard(false)); write = Administration full.

-- Users who may see a company (authorizers / originators must be among them).
CREATE OR REPLACE FUNCTION erp._apr_company_user(p_company varchar, p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.user_company uc JOIN erp.app_user u ON u.user_id = uc.user_id
                  WHERE uc.user_id = p_user AND uc.company_code = p_company AND u.active)
$$;

-- Snapshot of a template (what the version history keeps).
CREATE OR REPLACE FUNCTION erp._apr_snapshot(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'name', t.name, 'description', t.description, 'kind', t.kind, 'obj_type', t.obj_type, 'active', t.active,
    'originators', coalesce((SELECT jsonb_agg(jsonb_build_object('position_code', o.position_code, 'user_id', o.user_id,
                                     'name', coalesce(p.name, u.display_name)) ORDER BY o.position_code NULLS LAST, u.display_name)
                               FROM erp.apr_template_originator o LEFT JOIN erp.position p ON p.position_code = o.position_code
                               LEFT JOIN erp.app_user u ON u.user_id = o.user_id WHERE o.template_id = t.template_id), '[]'::jsonb),
    'stages', coalesce((SELECT jsonb_agg(jsonb_build_object('seq', ts.seq, 'stage_id', ts.stage_id, 'name', s.name) ORDER BY ts.seq)
                          FROM erp.apr_template_stage ts JOIN erp.apr_stage s ON s.stage_id = ts.stage_id WHERE ts.template_id = t.template_id), '[]'::jsonb),
    'conditions', coalesce((SELECT jsonb_agg(jsonb_build_object('field', c.field, 'op', c.op, 'value1', c.value1, 'value2', c.value2) ORDER BY c.cond_no)
                              FROM erp.apr_template_condition c WHERE c.template_id = t.template_id), '[]'::jsonb))
    FROM erp.apr_template t WHERE t.template_id = p_id
$$;

-- Add a version row when the template changed since the last one (so re-running the migration adds nothing).
CREATE OR REPLACE FUNCTION erp._apr_version(p_id bigint, p_user uuid, p_action text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_snap jsonb := erp._apr_snapshot(p_id);
  v_last erp.apr_template_version;
  v_ver  integer;
BEGIN
  SELECT * INTO v_last FROM erp.apr_template_version WHERE template_id = p_id ORDER BY version DESC LIMIT 1;
  IF v_last.template_id IS NOT NULL AND v_last.snapshot = v_snap THEN
    RETURN v_last.version;
  END IF;
  v_ver := coalesce(v_last.version, 0) + 1;
  INSERT INTO erp.apr_template_version (template_id, version, active, action, snapshot, changed_by)
  VALUES (p_id, v_ver, (v_snap->>'active')::boolean, p_action, v_snap, p_user);
  UPDATE erp.apr_template SET version = v_ver WHERE template_id = p_id;
  RETURN v_ver;
END $$;

-- Everything the three screens need.
CREATE OR REPLACE FUNCTION erp.approval_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
  c  erp.company := erp._adm_company(p_company);
BEGIN
  RETURN jsonb_build_object(
    'company_code', c.company_code,
    'can_write', erp.can_write('admin'),
    'currency', c.currency,
    'owner_position', (SELECT owner_position FROM erp.admin_setting WHERE company_code = p_company),
    'owner_position_name', (SELECT p.name FROM erp.admin_setting s JOIN erp.position p ON p.position_code = s.owner_position WHERE s.company_code = p_company),
    'kinds', (SELECT jsonb_agg(jsonb_build_object('kind', k.kind, 'label', k.label, 'obj_types', to_jsonb(k.obj_types), 'module', k.module,
                                                  'built_in', k.built_in, 'primary_field', k.primary_field, 'primary_op', k.primary_op, 'fields', k.fields)
                               ORDER BY k.sort) FROM erp._apr_kinds() k),
    'positions', coalesce((SELECT jsonb_agg(jsonb_build_object('position_code', p.position_code, 'name', p.name) ORDER BY p.name) FROM erp.position p), '[]'::jsonb),
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', u.user_id, 'display_name', u.display_name, 'position_code', u.position_code) ORDER BY u.display_name)
                         FROM erp.app_user u WHERE u.active AND erp._apr_company_user(p_company, u.user_id)), '[]'::jsonb),
    'stages', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'stage_id', s.stage_id, 'name', s.name, 'description', s.description, 'required_approvals', s.required_approvals,
               'required_rejections', s.required_rejections, 'active', s.active, 'source', s.source, 'updated_at', s.updated_at,
               'authorizers', coalesce((SELECT jsonb_agg(jsonb_build_object('position_code', a.position_code, 'user_id', a.user_id,
                                               'name', coalesce(p.name, u.display_name), 'kind', CASE WHEN a.position_code IS NOT NULL THEN 'position' ELSE 'user' END)
                                             ORDER BY a.position_code IS NULL, coalesce(p.name, u.display_name))
                                         FROM erp.apr_stage_authorizer a LEFT JOIN erp.position p ON p.position_code = a.position_code
                                         LEFT JOIN erp.app_user u ON u.user_id = a.user_id WHERE a.stage_id = s.stage_id), '[]'::jsonb),
               'people', (SELECT count(DISTINCT u.user_id) FROM erp.app_user u
                           WHERE u.active AND erp._apr_company_user(p_company, u.user_id)
                             AND EXISTS (SELECT 1 FROM erp.apr_stage_authorizer a WHERE a.stage_id = s.stage_id AND (a.user_id = u.user_id OR a.position_code = u.position_code))),
               'templates', coalesce((SELECT jsonb_agg(t.name ORDER BY t.name) FROM erp.apr_template_stage ts JOIN erp.apr_template t ON t.template_id = ts.template_id
                                      WHERE ts.stage_id = s.stage_id), '[]'::jsonb),
               'pending', (SELECT count(*) FROM erp.approval ap WHERE ap.stage_id = s.stage_id AND ap.decision IS NULL AND NOT ap.superseded))
             ORDER BY s.name)
        FROM erp.apr_stage s WHERE s.company_code = p_company), '[]'::jsonb),
    'templates', coalesce((
      SELECT jsonb_agg(erp._apr_snapshot(t.template_id) || jsonb_build_object(
               'template_id', t.template_id, 'version', t.version, 'source', t.source, 'legacy_sync', t.legacy_sync,
               'kind_label', erp._apr_kind_label(t.kind), 'updated_at', t.updated_at, 'updated_by_name', erp._adm_name(t.updated_by),
               'pending', (SELECT count(*) FROM erp.approval ap WHERE ap.template_id = t.template_id AND ap.decision IS NULL AND NOT ap.superseded),
               'used', (SELECT count(DISTINCT (ap.object, ap.object_ref)) FROM erp.approval ap WHERE ap.template_id = t.template_id))
             ORDER BY (SELECT k.sort FROM erp._apr_kinds() k WHERE k.kind = t.kind), t.name)
        FROM erp.apr_template t WHERE t.company_code = p_company), '[]'::jsonb),
    'leave', (SELECT jsonb_build_object('long_leave_days', hs.long_leave_days, 'hr_approver_position', hs.hr_approver_position, 'owner_position', hs.owner_position,
                                        'hr_approver_name', (SELECT name FROM erp.position WHERE position_code = hs.hr_approver_position),
                                        'owner_name', (SELECT name FROM erp.position WHERE position_code = hs.owner_position))
                FROM erp.hr_setting hs WHERE hs.company_code = p_company));
END $$;

-- Validate a list of {position_code} / {user_id} entries; returns them normalised. p_what = 'authorizer' | 'originator'.
CREATE OR REPLACE FUNCTION erp._apr_people(p_company varchar, p_list jsonb, p_what text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  x     jsonb;
  v_pos text;
  v_uid uuid;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_list IS NOT NULL AND jsonb_typeof(p_list) <> 'array' THEN
    RAISE EXCEPTION 'Send the %s as a list.', p_what USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(coalesce(p_list, '[]'::jsonb)) LOOP
    v_pos := nullif(btrim(x->>'position_code'), '');
    BEGIN
      v_uid := nullif(btrim(x->>'user_id'), '')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Choose a user from the list.' USING ERRCODE = 'P0001';
    END;
    IF num_nonnulls(v_pos, v_uid) <> 1 THEN
      RAISE EXCEPTION 'Each % is either a position or a user.', p_what USING ERRCODE = 'P0001';
    END IF;
    IF v_pos IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_pos) THEN
      RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_pos USING ERRCODE = 'P0001';
    END IF;
    IF v_uid IS NOT NULL AND NOT erp._apr_company_user(p_company, v_uid) THEN
      RAISE EXCEPTION 'User % can''t be an %: they have no active access to %.',
        coalesce((SELECT display_name FROM erp.app_user WHERE user_id = v_uid), v_uid::text), p_what, p_company USING ERRCODE = 'P0001';
    END IF;
    IF v_out @> jsonb_build_array(jsonb_build_object('position_code', v_pos, 'user_id', v_uid)) THEN
      RAISE EXCEPTION '% is listed twice.', coalesce((SELECT name FROM erp.position WHERE position_code = v_pos),
                                                     (SELECT display_name FROM erp.app_user WHERE user_id = v_uid)) USING ERRCODE = 'P0001';
    END IF;
    v_out := v_out || jsonb_build_object('position_code', v_pos, 'user_id', v_uid);
  END LOOP;
  RETURN v_out;
END $$;

-- Create (no stage_id) or change an approval stage. Authorizer changes apply to requests already waiting at the stage.
CREATE OR REPLACE FUNCTION erp.approval_stage_save(p_company varchar, p_stage jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me      erp.app_user := erp._adm_guard(true);
  old     erp.apr_stage;
  v_id    bigint := nullif(p_stage->>'stage_id', '')::bigint;
  v_name  text := nullif(btrim(p_stage->>'name'), '');
  v_desc  text := nullif(btrim(p_stage->>'description'), '');
  v_app   integer;
  v_rej   integer;
  v_act   boolean := coalesce((p_stage->>'active')::boolean, true);
  v_auth  jsonb;
  v_before jsonb;
  v_used  text;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.apr_stage WHERE stage_id = v_id AND company_code = p_company FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Approval stage % was not found in %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_before := to_jsonb(old) || jsonb_build_object('authorizers', (SELECT jsonb_agg(jsonb_build_object('position_code', position_code, 'user_id', user_id) ORDER BY auth_id)
                                                                      FROM erp.apr_stage_authorizer WHERE stage_id = v_id));
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the stage name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_name) > 100 THEN
    RAISE EXCEPTION 'The stage name can have up to 100 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.apr_stage WHERE company_code = p_company AND lower(name) = lower(v_name) AND stage_id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'A stage named "%" already exists in %. Choose another name.', v_name, p_company USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_app := coalesce(nullif(p_stage->>'required_approvals', '')::integer, 1);
    v_rej := coalesce(nullif(p_stage->>'required_rejections', '')::integer, 1);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the number of approvals and rejections as whole numbers.' USING ERRCODE = 'P0001';
  END;
  IF v_app NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'Required approvals must be between 1 and 20.' USING ERRCODE = 'P0001';
  END IF;
  IF v_rej NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'Required rejections must be between 1 and 20.' USING ERRCODE = 'P0001';
  END IF;
  v_auth := erp._apr_people(p_company, p_stage->'authorizers', 'authorizer');
  IF jsonb_array_length(v_auth) = 0 THEN
    RAISE EXCEPTION 'Add at least one authorizer (a position or a user).' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_auth) < v_app AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_auth) x WHERE x->>'position_code' IS NOT NULL) THEN
    RAISE EXCEPTION 'This stage needs % approvals but lists only % user(s). Add authorizers or lower the number.', v_app, jsonb_array_length(v_auth) USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_act AND v_id IS NOT NULL THEN
    SELECT string_agg(t.name, ', ' ORDER BY t.name) INTO v_used FROM erp.apr_template_stage ts JOIN erp.apr_template t ON t.template_id = ts.template_id
     WHERE ts.stage_id = v_id AND t.active;
    IF v_used IS NOT NULL THEN
      RAISE EXCEPTION 'Stage "%" is used by active template(s) %. Remove it from those templates first.', v_name, v_used USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO erp.apr_stage (company_code, name, description, required_approvals, required_rejections, active, created_by, updated_by)
    VALUES (p_company, v_name, v_desc, v_app, v_rej, v_act, me.user_id, me.user_id) RETURNING stage_id INTO v_id;
  ELSE
    UPDATE erp.apr_stage SET name = v_name, description = v_desc, required_approvals = v_app, required_rejections = v_rej, active = v_act,
                             updated_by = me.user_id, updated_at = now()
     WHERE stage_id = v_id;
    DELETE FROM erp.apr_stage_authorizer WHERE stage_id = v_id;
  END IF;
  INSERT INTO erp.apr_stage_authorizer (stage_id, position_code, user_id)
  SELECT v_id, x->>'position_code', (x->>'user_id')::uuid FROM jsonb_array_elements(v_auth) x;
  -- Templates using this stage get a new history entry (their stage now has other authorizers / names).
  PERFORM erp._apr_version(ts.template_id, me.user_id, 'stage_changed') FROM erp.apr_template_stage ts WHERE ts.stage_id = v_id AND old.stage_id IS NOT NULL;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN old.stage_id IS NULL THEN 'approval_stage_create' ELSE 'approval_stage_change' END, 'approval_stage', v_id::text,
          jsonb_build_object('before', v_before, 'after', (SELECT to_jsonb(s) FROM erp.apr_stage s WHERE s.stage_id = v_id) || jsonb_build_object('authorizers', v_auth)));
  RETURN jsonb_build_object('stage_id', v_id,
    'pending', (SELECT count(*) FROM erp.approval WHERE stage_id = v_id AND decision IS NULL AND NOT superseded));
END $$;

CREATE OR REPLACE FUNCTION erp.approval_stage_delete(p_company varchar, p_stage_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me   erp.app_user := erp._adm_guard(true);
  s    erp.apr_stage;
  v_t  text;
  v_n  integer;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO s FROM erp.apr_stage WHERE stage_id = p_stage_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval stage % was not found in %.', p_stage_id, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT string_agg(t.name, ', ' ORDER BY t.name) INTO v_t FROM erp.apr_template_stage ts JOIN erp.apr_template t ON t.template_id = ts.template_id WHERE ts.stage_id = p_stage_id;
  IF v_t IS NOT NULL THEN
    RAISE EXCEPTION 'Stage "%" is used in template(s) %. Remove it from those templates first.', s.name, v_t USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO v_n FROM erp.approval WHERE stage_id = p_stage_id AND decision IS NULL AND NOT superseded;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Stage "%" still has % request(s) waiting. Wait until they are decided, or deactivate the stage.', s.name, v_n USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM erp.apr_stage WHERE stage_id = p_stage_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'approval_stage_delete', 'approval_stage', p_stage_id::text, jsonb_build_object('before', to_jsonb(s)));
  RETURN jsonb_build_object('stage_id', p_stage_id, 'deleted', true);
END $$;

-- Create (no template_id) or change an approval template. New documents use the change; documents already waiting keep
-- the stages they were sent to.
CREATE OR REPLACE FUNCTION erp.approval_template_save(p_company varchar, p_tpl jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me      erp.app_user := erp._adm_guard(true);
  old     erp.apr_template;
  k       record;
  v_id    bigint := nullif(p_tpl->>'template_id', '')::bigint;
  v_name  text := nullif(btrim(p_tpl->>'name'), '');
  v_desc  text := nullif(btrim(p_tpl->>'description'), '');
  v_kind  text := nullif(btrim(p_tpl->>'kind'), '');
  v_obj   integer;
  v_act   boolean := coalesce((p_tpl->>'active')::boolean, true);
  v_orig  jsonb;
  v_st    jsonb := coalesce(p_tpl->'stages', '[]'::jsonb);
  v_cond  jsonb := coalesce(p_tpl->'conditions', '[]'::jsonb);
  x       jsonb;
  s       erp.apr_stage;
  v_seq   integer := 0;
  v_seen  bigint[] := '{}';
  v_field jsonb;
  v_op    text;
  v_a     numeric;
  v_b     numeric;
  v_n     integer := 0;
  v_before jsonb;
  v_ver   integer;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.apr_template WHERE template_id = v_id AND company_code = p_company FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Approval template % was not found in %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_kind := coalesce(v_kind, old.kind);
    v_before := erp._apr_snapshot(v_id);
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the template name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_name) > 120 THEN
    RAISE EXCEPTION 'The template name can have up to 120 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.apr_template WHERE company_code = p_company AND lower(name) = lower(v_name) AND template_id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'A template named "%" already exists in %. Choose another name.', v_name, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'Choose the document the template applies to.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM erp._apr_kinds() kk WHERE kk.kind = v_kind;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval kind % is not known.', v_kind USING ERRCODE = 'P0001';
  END IF;
  IF k.built_in THEN
    RAISE EXCEPTION 'Leave approvals follow the line manager, the HR approver and the owner set in HR Setup. Change them there.' USING ERRCODE = 'P0001';
  END IF;
  IF old.template_id IS NOT NULL AND v_kind <> old.kind THEN
    RAISE EXCEPTION 'The document of a template can''t be changed. Create a new template instead.' USING ERRCODE = 'P0001';
  END IF;
  v_obj := coalesce(nullif(p_tpl->>'obj_type', '')::integer, old.obj_type, k.obj_types[1]);
  IF NOT v_obj = ANY (k.obj_types) THEN
    RAISE EXCEPTION 'This template applies to document type % only.', array_to_string(k.obj_types, ' or ') USING ERRCODE = 'P0001';
  END IF;
  v_orig := erp._apr_people(p_company, p_tpl->'originators', 'originator');

  IF jsonb_typeof(v_st) <> 'array' OR jsonb_array_length(v_st) = 0 THEN
    RAISE EXCEPTION 'Add at least one approval stage.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_st) > 9 THEN
    RAISE EXCEPTION 'A template can have up to 9 stages.' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(v_st) LOOP
    SELECT * INTO s FROM erp.apr_stage WHERE company_code = p_company AND stage_id = nullif(CASE WHEN jsonb_typeof(x) = 'object' THEN x->>'stage_id' ELSE x #>> '{}' END, '')::bigint;
    IF s.stage_id IS NULL THEN
      RAISE EXCEPTION 'Stage % was not found in %. Choose a stage from the list.', coalesce(x #>> '{}', '?'), p_company USING ERRCODE = 'P0001';
    END IF;
    IF NOT s.active THEN
      RAISE EXCEPTION 'Stage "%" is inactive. Activate it or choose another stage.', s.name USING ERRCODE = 'P0001';
    END IF;
    IF s.stage_id = ANY (v_seen) THEN
      RAISE EXCEPTION 'Stage "%" is listed twice. Each stage can be used once per template.', s.name USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || s.stage_id;
  END LOOP;

  IF jsonb_typeof(v_cond) <> 'array' THEN
    RAISE EXCEPTION 'Send the conditions as a list.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_cond) > 0 AND jsonb_array_length(k.fields) = 0 THEN
    RAISE EXCEPTION '% has no conditions: the template applies to every request from its originators.', k.label USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(v_cond) LOOP
    SELECT f INTO v_field FROM jsonb_array_elements(k.fields) f WHERE f->>'field' = x->>'field';
    IF v_field IS NULL THEN
      RAISE EXCEPTION 'The condition "%" can''t be used for %. Choose one of: %.', coalesce(x->>'field', '?'), k.label,
        (SELECT string_agg(erp._apr_field_label(f->>'field'), ', ') FROM jsonb_array_elements(k.fields) f) USING ERRCODE = 'P0001';
    END IF;
    v_op := x->>'op';
    IF v_op IS NULL OR v_op NOT IN ('gt', 'ge', 'lt', 'le', 'eq', 'ne', 'between', 'not_between') THEN
      RAISE EXCEPTION 'Choose how to compare % (greater than, less than, between …).', erp._apr_field_label(v_field->>'field') USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      v_a := nullif(btrim(x->>'value1'), '')::numeric;
      v_b := nullif(btrim(x->>'value2'), '')::numeric;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Enter % as a number.', erp._apr_field_label(v_field->>'field') USING ERRCODE = 'P0001';
    END;
    IF v_a IS NULL THEN
      RAISE EXCEPTION 'Enter the value for %.', erp._apr_field_label(v_field->>'field') USING ERRCODE = 'P0001';
    END IF;
    IF v_op IN ('between', 'not_between') AND (v_b IS NULL OR v_b < v_a) THEN
      RAISE EXCEPTION 'For "between", enter a "to" value greater than or equal to the "from" value.' USING ERRCODE = 'P0001';
    END IF;
    IF v_field->>'unit' = 'pct' AND x->>'field' IN ('discount_pct', 'below_cost_pct') AND (v_a NOT BETWEEN 0 AND 100 OR coalesce(v_b, 0) NOT BETWEEN 0 AND 100) THEN
      RAISE EXCEPTION 'Enter a percentage between 0 and 100.' USING ERRCODE = 'P0001';
    ELSIF v_field->>'unit' = 'pct' AND (v_a NOT BETWEEN 0 AND 1000 OR coalesce(v_b, 0) NOT BETWEEN 0 AND 1000) THEN
      RAISE EXCEPTION 'Enter a percentage between 0 and 1000.' USING ERRCODE = 'P0001';
    ELSIF v_field->>'unit' = 'amount' AND (v_a < 0 OR coalesce(v_b, 0) < 0) THEN
      RAISE EXCEPTION 'The amount can''t be negative.' USING ERRCODE = 'P0001';
    ELSIF v_field->>'unit' = 'days' AND (v_a <> trunc(v_a) OR v_a NOT BETWEEN 1 AND 365 OR (v_b IS NOT NULL AND (v_b <> trunc(v_b) OR v_b NOT BETWEEN 1 AND 365))) THEN
      RAISE EXCEPTION 'Enter whole days between 1 and 365.' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  IF v_id IS NULL THEN
    INSERT INTO erp.apr_template (company_code, name, description, kind, obj_type, active, source, created_by, updated_by)
    VALUES (p_company, v_name, v_desc, v_kind, v_obj, v_act, 'erp', me.user_id, me.user_id) RETURNING template_id INTO v_id;
  ELSE
    UPDATE erp.apr_template SET name = v_name, description = v_desc, obj_type = v_obj, active = v_act, legacy_sync = false,
                                updated_by = me.user_id, updated_at = now()
     WHERE template_id = v_id;
    DELETE FROM erp.apr_template_originator WHERE template_id = v_id;
    DELETE FROM erp.apr_template_stage WHERE template_id = v_id;
    DELETE FROM erp.apr_template_condition WHERE template_id = v_id;
  END IF;
  INSERT INTO erp.apr_template_originator (template_id, position_code, user_id)
  SELECT v_id, x->>'position_code', (x->>'user_id')::uuid FROM jsonb_array_elements(v_orig) x;
  FOR x IN SELECT value FROM jsonb_array_elements(v_st) LOOP
    v_seq := v_seq + 1;
    INSERT INTO erp.apr_template_stage (template_id, seq, stage_id)
    VALUES (v_id, v_seq, nullif(CASE WHEN jsonb_typeof(x) = 'object' THEN x->>'stage_id' ELSE x #>> '{}' END, '')::bigint);
  END LOOP;
  FOR x IN SELECT value FROM jsonb_array_elements(v_cond) LOOP
    v_n := v_n + 1;
    INSERT INTO erp.apr_template_condition (template_id, cond_no, field, op, value1, value2)
    VALUES (v_id, v_n, x->>'field', x->>'op', nullif(btrim(x->>'value1'), '')::numeric,
            CASE WHEN x->>'op' IN ('between', 'not_between') THEN nullif(btrim(x->>'value2'), '')::numeric END);
  END LOOP;
  v_ver := erp._apr_version(v_id, me.user_id, CASE WHEN old.template_id IS NULL THEN 'created' ELSE 'changed' END);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN old.template_id IS NULL THEN 'approval_template_create' ELSE 'approval_template_change' END,
          'approval_template', v_id::text, jsonb_build_object('before', v_before, 'after', erp._apr_snapshot(v_id), 'version', v_ver));
  RETURN jsonb_build_object('template_id', v_id, 'version', v_ver,
    'pending', (SELECT count(*) FROM erp.approval WHERE template_id = v_id AND decision IS NULL AND NOT superseded));
END $$;

-- Activate / deactivate (history kept). Waiting requests keep going; new documents follow the flag.
CREATE OR REPLACE FUNCTION erp.approval_template_set_active(p_company varchar, p_template_id bigint, p_active boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  t   erp.apr_template;
  v_ver integer;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO t FROM erp.apr_template WHERE template_id = p_template_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval template % was not found in %.', p_template_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF p_active IS NULL THEN
    RAISE EXCEPTION 'Choose active or inactive.' USING ERRCODE = 'P0001';
  END IF;
  IF p_active AND EXISTS (SELECT 1 FROM erp.apr_template_stage ts JOIN erp.apr_stage s ON s.stage_id = ts.stage_id WHERE ts.template_id = p_template_id AND NOT s.active) THEN
    RAISE EXCEPTION 'Template "%" uses an inactive stage. Activate the stage or change the template first.', t.name USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.apr_template SET active = p_active, legacy_sync = false, updated_by = me.user_id, updated_at = now() WHERE template_id = p_template_id;
  v_ver := erp._apr_version(p_template_id, me.user_id, CASE WHEN p_active THEN 'activated' ELSE 'deactivated' END);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN p_active THEN 'approval_template_activate' ELSE 'approval_template_deactivate' END,
          'approval_template', p_template_id::text, jsonb_build_object('name', t.name, 'version', v_ver));
  RETURN jsonb_build_object('template_id', p_template_id, 'active', p_active, 'version', v_ver,
    'pending', (SELECT count(*) FROM erp.approval WHERE template_id = p_template_id AND decision IS NULL AND NOT superseded));
END $$;

-- Delete a template that was never used. Used templates are deactivated instead, so their history stays.
CREATE OR REPLACE FUNCTION erp.approval_template_delete(p_company varchar, p_template_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  t   erp.apr_template;
  v_n integer;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO t FROM erp.apr_template WHERE template_id = p_template_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval template % was not found in %.', p_template_id, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT count(DISTINCT (object, object_ref)) INTO v_n FROM erp.approval WHERE template_id = p_template_id;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Template "%" was used by % request(s). Deactivate it instead, so its history is kept.', t.name, v_n USING ERRCODE = 'P0001';
  END IF;
  IF t.legacy_key IS NOT NULL THEN
    RAISE EXCEPTION 'Template "%" was created from the earlier approval rules. Deactivate it instead, so its history is kept.', t.name USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'approval_template_delete', 'approval_template', p_template_id::text, jsonb_build_object('before', erp._apr_snapshot(p_template_id)));
  DELETE FROM erp.apr_template WHERE template_id = p_template_id;
  RETURN jsonb_build_object('template_id', p_template_id, 'deleted', true);
END $$;

-- Version history of a template.
CREATE OR REPLACE FUNCTION erp.approval_template_history(p_company varchar, p_template_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  IF NOT EXISTS (SELECT 1 FROM erp.apr_template WHERE template_id = p_template_id AND company_code = p_company) THEN
    RAISE EXCEPTION 'Approval template % was not found in %.', p_template_id, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('version', v.version, 'active', v.active, 'action', v.action, 'snapshot', v.snapshot,
                                                       'changed_by_name', coalesce(erp._adm_name(v.changed_by), 'System'), 'changed_at', v.changed_at)
                                    ORDER BY v.version DESC)
                     FROM erp.apr_template_version v WHERE v.template_id = p_template_id), '[]'::jsonb);
END $$;

-- ============ 6. All approval requests (inbox + status report) ============
-- One row per erp.approval row the caller may see, with its document. Module read rights as in A2–B1.
CREATE OR REPLACE FUNCTION erp._apr_base()
RETURNS TABLE (approval_id bigint, company_code varchar, object text, object_ref text, step smallint, approver_position text, approver_user uuid,
               decision text, note text, decided_at timestamptz, rule_code text, requested_by uuid, requested_at timestamptz, detail jsonb, superseded boolean,
               template_id bigint, template_version integer, template_name text, stage_id bigint, stage_name text, need_approvals smallint, need_rejections smallint,
               kind text, doc_no text, state text, reason text, submitted_by uuid, doc_entry integer, card_code varchar, card_name text, total numeric, currency varchar)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT a.approval_id, a.company_code, a.object, a.object_ref, a.step, a.approver_position, a.approver_user, a.decision, a.note, a.decided_at,
         a.rule_code, a.requested_by, a.requested_at, a.detail, a.superseded, a.template_id, a.template_version, a.template_name, a.stage_id,
         a.stage_name, a.need_approvals, a.need_rejections, b.*
    FROM erp.approval a
    CROSS JOIN LATERAL (
      SELECT 'sales_order'::text, w.doc_no::text, w.state::text, w.reason, w.submitted_by, d.doc_entry, d.card_code::varchar, d.card_name::text, d.total, d.currency::varchar
        FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_order' AND w.company_code = a.company_code AND w.obj_type = 17 AND w.doc_entry::text = a.object_ref
      UNION ALL
      SELECT 'sales_quotation', w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_quotation' AND w.company_code = a.company_code AND w.obj_type = 23 AND w.doc_entry::text = a.object_ref
      UNION ALL
      SELECT 'journal', j.draft_id::text, j.state, j.reason, j.submitted_by, j.draft_id, NULL::varchar, j.memo, j.total, j.currency
        FROM erp.journal_draft j
       WHERE a.object = 'journal' AND erp.can_read('finance') AND j.company_code = a.company_code AND j.draft_id::text = a.object_ref
      UNION ALL
      SELECT 'payment', p.draft_id::text, p.state, p.reason, p.created_by, p.draft_id, p.card_code, p.card_name, p.total, p.currency
        FROM erp.payment_draft p
       WHERE a.object = 'payment' AND (erp.can_read('banking') OR erp.can_read('finance')) AND p.company_code = a.company_code AND p.draft_id::text = a.object_ref
      UNION ALL
      SELECT 'purchase_order', w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'purchase_order' AND (erp.can_read('purchase') OR erp.can_read('finance'))
         AND w.company_code = a.company_code AND w.obj_type = 22 AND w.doc_entry::text = a.object_ref
      UNION ALL
      SELECT a.object, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, w.whs_code::varchar,
             (SELECT r.name FROM erp.inventory_reason r WHERE r.company_code = w.company_code AND r.code = w.reason_code), d.total, d.currency
        FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object IN ('goods_receipt', 'goods_issue') AND erp.can_read('inventory') AND w.company_code = a.company_code
         AND w.obj_type = CASE a.object WHEN 'goods_receipt' THEN 59 ELSE 60 END AND w.doc_entry::text = a.object_ref
      UNION ALL
      SELECT 'inventory_count', c.doc_no, c.state, c.reason, c.submitted_by, c.count_id, c.whs_code::varchar,
             (SELECT wh.name FROM erp.warehouse wh WHERE wh.company_code = c.company_code AND wh.whs_code = c.whs_code),
             coalesce(c.gain_value, 0) + coalesce(c.loss_value, 0), (SELECT co.currency FROM erp.company co WHERE co.company_code = c.company_code)
        FROM erp.inv_count c
       WHERE a.object = 'inventory_count' AND erp.can_read('inventory') AND c.company_code = a.company_code AND c.count_id::text = a.object_ref
      UNION ALL
      SELECT 'bp_change', q.card_code::text, q.state, q.reason, q.requested_by, q.request_id, q.card_code::varchar, bp.name,
             CASE WHEN q.kind = 'credit_limit' THEN (q.after->>'credit_limit')::numeric END, bp.currency
        FROM erp.bp_change_request q JOIN erp.business_partner bp ON bp.company_code = q.company_code AND bp.card_code = q.card_code
       WHERE a.object = 'bp_change' AND (erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance') OR erp.can_read('banking'))
         AND q.company_code = a.company_code AND q.request_id::text = a.object_ref
      UNION ALL
      SELECT 'leave', q.request_id::text, q.state, q.reason, q.requested_by, q.request_id, e.hr_code::varchar, concat_ws(' ', e.first_name, e.last_name), q.days, NULL::varchar
        FROM erp.leave_request q JOIN erp.employee e ON e.company_code = q.company_code AND e.emp_id = q.emp_id
       WHERE a.object = 'leave' AND q.company_code = a.company_code AND q.request_id::text = a.object_ref
      UNION ALL
      SELECT 'company_details', q.request_id::text, q.state, q.reason, q.requested_by, q.request_id, q.company_code::varchar, co.legal_name, NULL::numeric, NULL::varchar
        FROM erp.company_change_request q JOIN erp.company co ON co.company_code = q.company_code
       WHERE a.object = 'company_details' AND q.company_code = a.company_code AND q.request_id::text = a.object_ref
      UNION ALL
      SELECT 'sales_doc_request', 'REQ-' || q.request_id, q.state, q.reason, q.requested_by, q.request_id::integer, q.card_code, q.card_name, q.total, q.currency
        FROM erp.sales_doc_request q
       WHERE a.object = 'sales_doc_request' AND (erp.can_read('sales') OR erp.can_read('finance')) AND q.company_code = a.company_code AND q.request_id::text = a.object_ref
    ) b
   WHERE erp.can_see(a.company_code)
$$;

-- ============ Approvals inbox (copied from 30: the 13 kinds; B2 adds the template, the stage and the votes, and the
-- waiting list follows the stages' live authorizers) ============
CREATE OR REPLACE FUNCTION erp.approval_inbox() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_approver', false, 'waiting', '[]'::jsonb, 'sent', '[]'::jsonb, 'decided', '[]'::jsonb);
  END IF;
  RETURN (
    WITH a AS (
      SELECT b.*, b.detail->>'for_user' AS for_user, p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
             min(b.step) FILTER (WHERE b.decision IS NULL AND NOT b.superseded) OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS current_step,
             max(b.step) OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS last_step
        FROM erp._apr_base() b
        LEFT JOIN erp.position p ON p.position_code = b.approver_position
        LEFT JOIN erp.app_user ru ON ru.user_id = b.requested_by
        LEFT JOIN erp.app_user du ON du.user_id = b.approver_user
    ), r AS (
      SELECT a.*, jsonb_build_object(
               'approval_id', a.approval_id, 'company_code', a.company_code, 'kind', a.kind, 'doc_entry', a.doc_entry,
               'doc_no', a.doc_no, 'rule_code', a.rule_code, 'step', a.step, 'card_code', a.card_code, 'card_name', a.card_name,
               'total', a.total, 'currency', a.currency, 'requested_by_name', a.requested_by_name, 'requested_at', a.requested_at,
               'reason', a.reason, 'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', a.decided_by_name,
               'note', a.note, 'state', a.state, 'superseded', a.superseded,
               'approver_position_name', CASE WHEN a.stage_id IS NOT NULL THEN erp._apr_stage_who(a.stage_id) ELSE a.approver_position_name END,
               'template_name', coalesce(a.template_name, erp._apr_kind_label(a.rule_code)), 'template_id', a.template_id,
               'stage_name', coalesce(a.stage_name, a.approver_position_name), 'stage_id', a.stage_id, 'stages', a.last_step,
               'need_approvals', coalesce(a.need_approvals, 1),
               'approvals', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'approved'),
               'built_in', a.stage_id IS NULL,
               'message', a.detail->'checks'->0->>'message') AS j
        FROM a
    )
    SELECT jsonb_build_object(
      'is_approver', EXISTS (SELECT 1 FROM erp.apr_stage_authorizer sa JOIN erp.apr_stage s ON s.stage_id = sa.stage_id
                              WHERE (sa.position_code = u.position_code OR sa.user_id = u.user_id) AND s.active AND erp.can_see(s.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.approver_position = u.position_code AND ar.active AND erp.can_see(ar.company_code))
                     OR EXISTS (SELECT 1 FROM erp.hr_setting hs WHERE u.position_code IN (hs.hr_approver_position, hs.owner_position) AND erp.can_see(hs.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval ap WHERE ap.detail->>'for_user' = u.user_id::text)
                     OR EXISTS (SELECT 1 FROM erp.admin_setting s WHERE s.owner_position = u.position_code AND erp.can_see(s.company_code)),
      'waiting', coalesce((SELECT jsonb_agg(j ORDER BY requested_at) FROM r
                            WHERE decision IS NULL AND NOT superseded AND state = 'pending_approval' AND step = current_step
                              AND submitted_by IS DISTINCT FROM u.user_id AND erp._apr_is_mine(approval_id, u)), '[]'::jsonb),
      'sent', coalesce((SELECT jsonb_agg(j ORDER BY requested_at DESC, approval_id) FROM (SELECT * FROM r WHERE requested_by = u.user_id
                         ORDER BY requested_at DESC LIMIT 100) s), '[]'::jsonb),
      'decided', coalesce((SELECT jsonb_agg(j ORDER BY decided_at DESC) FROM (
                            SELECT r.*, coalesce((SELECT max(v.voted_at) FROM erp.approval_vote v WHERE v.approval_id = r.approval_id AND v.user_id = u.user_id), r.decided_at) AS my_at
                              FROM r WHERE (approver_user = u.user_id AND decision IS NOT NULL)
                                 OR EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = r.approval_id AND v.user_id = u.user_id)
                             ORDER BY my_at DESC NULLS LAST LIMIT 100) s), '[]'::jsonb)));
END $$;

-- Approval Status Report: one row per request (document) of a company, with its template(s), the current stage and its state.
-- filter: {status: pending | approved | rejected | cancelled | all, kind, template_id, from, to}
CREATE OR REPLACE FUNCTION erp.approval_status_report(p_company varchar, p_filter jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  f        jsonb := coalesce(p_filter, '{}'::jsonb);
  v_status text := coalesce(nullif(f->>'status', ''), 'all');
  v_kind   text := nullif(f->>'kind', '');
  v_tpl    bigint;
  v_from   date;
  v_to     date;
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  IF v_status NOT IN ('pending', 'approved', 'rejected', 'cancelled', 'all') THEN
    RAISE EXCEPTION 'Choose a status: waiting, approved, rejected, cancelled or all.' USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_tpl := nullif(f->>'template_id', '')::bigint;
    v_from := nullif(f->>'from', '')::date;
    v_to := nullif(f->>'to', '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Check the filter: the dates must be valid dates.' USING ERRCODE = 'P0001';
  END;
  IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to < v_from THEN
    RAISE EXCEPTION 'The "to" date is before the "from" date.' USING ERRCODE = 'P0001';
  END IF;
  RETURN (
    WITH b AS (SELECT * FROM erp._apr_base() x WHERE x.company_code = p_company),
    g AS (
      SELECT b.object, b.object_ref, min(b.kind) AS kind, min(b.doc_no) AS doc_no, min(b.doc_entry) AS doc_entry, min(b.state) AS state,
             min(b.card_code) AS card_code, min(b.card_name) AS card_name, min(b.total) AS total, min(b.currency) AS currency,
             min(b.requested_at) AS requested_at, (array_agg(b.requested_by ORDER BY b.requested_at))[1] AS requested_by,
             string_agg(DISTINCT coalesce(b.template_name, erp._apr_kind_label(b.rule_code)), ', ') AS templates,
             min(b.step) FILTER (WHERE b.decision IS NULL AND NOT b.superseded) AS current_step,
             max(b.step) AS steps,
             max(b.decided_at) AS last_decided_at,
             bool_or(b.template_id = v_tpl) AS has_tpl,
             max(b.requested_at) FILTER (WHERE b.decision IS NULL AND NOT b.superseded) AS open_since
        FROM b GROUP BY b.object, b.object_ref
    ), s AS (
      SELECT g.*, CASE WHEN g.state = 'pending_approval' THEN 'pending' WHEN g.state IN ('approved', 'posted') THEN 'approved'
                       WHEN g.state = 'rejected' THEN 'rejected' WHEN g.state = 'cancelled' THEN 'cancelled' ELSE g.state END AS status
        FROM g
    )
    SELECT jsonb_build_object(
      'counts', jsonb_build_object('pending', (SELECT count(*) FROM s WHERE status = 'pending'), 'approved', (SELECT count(*) FROM s WHERE status = 'approved'),
                                   'rejected', (SELECT count(*) FROM s WHERE status = 'rejected'), 'cancelled', (SELECT count(*) FROM s WHERE status = 'cancelled')),
      'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'object', s.object, 'object_ref', s.object_ref, 'kind', s.kind, 'doc_no', s.doc_no, 'doc_entry', s.doc_entry, 'company_code', p_company,
                'status', s.status, 'state', s.state, 'card_code', s.card_code, 'card_name', s.card_name, 'total', s.total, 'currency', s.currency,
                'requested_at', s.requested_at, 'requested_by_name', erp._adm_name(s.requested_by), 'templates', s.templates,
                'current_step', s.current_step, 'steps', s.steps, 'last_decided_at', s.last_decided_at,
                'waiting_days', CASE WHEN s.status = 'pending' THEN floor(extract(epoch FROM now() - coalesce(
                                   (SELECT max(x.decided_at) FROM b x WHERE x.object = s.object AND x.object_ref = s.object_ref AND x.decision IS NOT NULL AND NOT x.superseded),
                                   s.requested_at)) / 86400) END,
                'current_stage', (SELECT string_agg(DISTINCT coalesce(x.stage_name, p.name), ', ') FROM b x LEFT JOIN erp.position p ON p.position_code = x.approver_position
                                   WHERE x.object = s.object AND x.object_ref = s.object_ref AND x.step = s.current_step AND x.decision IS NULL AND NOT x.superseded),
                'current_who', (SELECT erp._apr_who(p_company, s.object, s.object_ref, s.current_step::smallint)),
                'trail', erp._apr_trail(p_company, s.object, s.object_ref)) ORDER BY s.requested_at DESC)
              FROM s
             WHERE (v_status = 'all' OR s.status = v_status)
               AND (v_kind IS NULL OR s.kind = v_kind OR s.object = v_kind)
               AND (v_tpl IS NULL OR s.has_tpl)
               AND (v_from IS NULL OR s.requested_at::date >= v_from)
               AND (v_to IS NULL OR s.requested_at::date <= v_to)), '[]'::jsonb));
END $$;

-- ============ 7. Compatibility: approval_rule (A2–B1) synchronised into templates ============
-- Rule catalogue (copied from 30 + incoming_payment).
CREATE OR REPLACE FUNCTION erp._adm_rule_spec() RETURNS TABLE (rule_code text, obj_types integer[], position_required boolean, limit_kind text, sort integer)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('discount_pct', ARRAY[17], true, 'pct', 1), ('credit_limit', ARRAY[17], false, 'none', 2), ('below_cost', ARRAY[17], false, 'none', 3),
    ('po_amount', ARRAY[22], false, 'amount', 4), ('po_price_increase', ARRAY[22], false, 'pct_any', 5),
    ('payment_amount', ARRAY[46], false, 'amount', 6), ('bank_change', ARRAY[46], false, 'days', 7),
    ('journal_amount', ARRAY[30], false, 'amount', 8),
    ('stock_doc_amount', ARRAY[59, 60], false, 'amount', 9),
    ('count_variance_pct', ARRAY[1470000065], false, 'pct', 10), ('count_variance_value', ARRAY[1470000065], false, 'amount', 11),
    ('bp_credit_limit', ARRAY[2], false, 'none', 12), ('bp_bank_detail', ARRAY[2], false, 'none', 13),
    ('credit_memo_amount', ARRAY[14], false, 'amount', 14),
    ('incoming_payment', ARRAY[24], false, 'amount', 15)
  ) AS v(rule_code, obj_types, position_required, limit_kind, sort)
$$;

-- The stage "Approval by <position>" made for a legacy approver position.
CREATE OR REPLACE FUNCTION erp._apr_legacy_stage(p_company varchar, p_position text, p_user uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_id   bigint;
  v_name text;
BEGIN
  SELECT stage_id INTO v_id FROM erp.apr_stage WHERE company_code = p_company AND legacy_key = 'pos:' || p_position;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;
  v_name := 'Approval by ' || coalesce((SELECT name FROM erp.position WHERE position_code = p_position), p_position);
  IF EXISTS (SELECT 1 FROM erp.apr_stage WHERE company_code = p_company AND lower(name) = lower(v_name)) THEN
    v_name := v_name || ' (' || p_position || ')';
  END IF;
  INSERT INTO erp.apr_stage (company_code, name, description, required_approvals, required_rejections, source, legacy_key, created_by, updated_by)
  VALUES (p_company, v_name, 'Created from the approval rules of A2–B1.', 1, 1, 'migrated', 'pos:' || p_position, p_user, p_user)
  RETURNING stage_id INTO v_id;
  INSERT INTO erp.apr_stage_authorizer (stage_id, position_code) VALUES (v_id, p_position);
  RETURN v_id;
END $$;

-- Rebuild the template of one legacy rule chain (company, document, rule, requester position) from erp.approval_rule.
-- A chain whose template was edited in the Approval Templates screen (legacy_sync off) is left alone.
CREATE OR REPLACE FUNCTION erp._apr_sync_legacy(p_company varchar, p_obj integer, p_rule text, p_pos text, p_user uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_key  text := format('rule:%s|%s|%s', p_obj, p_rule, coalesce(p_pos, '*'));
  t      erp.apr_template;
  k      record;
  v_n    integer;
  v_act  boolean;
  v_lim  numeric;
  v_name text;
  v_new  boolean := false;
  v_seq  integer := 0;
  v_stage bigint;
  r      record;
BEGIN
  SELECT * INTO t FROM erp.apr_template WHERE company_code = p_company AND legacy_key = v_key FOR UPDATE;
  IF t.template_id IS NOT NULL AND NOT t.legacy_sync THEN
    RETURN t.template_id;
  END IF;
  SELECT count(*), bool_or(active) INTO v_n, v_act FROM erp.approval_rule
   WHERE company_code = p_company AND obj_type = p_obj AND rule_code = p_rule AND position_code IS NOT DISTINCT FROM p_pos;
  IF v_n = 0 THEN
    IF t.template_id IS NOT NULL AND t.active THEN
      UPDATE erp.apr_template SET active = false, updated_by = p_user, updated_at = now() WHERE template_id = t.template_id;
      PERFORM erp._apr_version(t.template_id, p_user, 'legacy_rule_deleted');
    END IF;
    RETURN t.template_id;
  END IF;
  SELECT * INTO k FROM erp._apr_kinds() kk WHERE kk.kind = p_rule;
  SELECT limit_value INTO v_lim FROM erp.approval_rule
   WHERE company_code = p_company AND obj_type = p_obj AND rule_code = p_rule AND position_code IS NOT DISTINCT FROM p_pos
   ORDER BY NOT active, step, rule_id LIMIT 1;
  IF t.template_id IS NULL THEN
    v_name := format('%s · %s%s', erp._apr_kind_short(p_rule), coalesce((SELECT name FROM erp.position WHERE position_code = p_pos), 'everyone'),
                     CASE p_obj WHEN 59 THEN ' · goods receipts' WHEN 60 THEN ' · goods issues' ELSE '' END);
    IF EXISTS (SELECT 1 FROM erp.apr_template WHERE company_code = p_company AND lower(name) = lower(v_name)) THEN
      v_name := v_name || ' (' || coalesce(p_pos, '*') || ')';
    END IF;
    INSERT INTO erp.apr_template (company_code, name, description, kind, obj_type, active, source, legacy_key, legacy_sync, created_by, updated_by)
    VALUES (p_company, v_name, 'Created from the approval rules of A2–B1.', p_rule, p_obj, v_act,
            CASE WHEN EXISTS (SELECT 1 FROM erp.approval_rule WHERE company_code = p_company AND obj_type = p_obj AND rule_code = p_rule
                                AND position_code IS NOT DISTINCT FROM p_pos AND note ILIKE '%sample%') THEN 'sample' ELSE 'migrated' END,
            v_key, true, p_user, p_user)
    RETURNING * INTO t;
    v_new := true;
  ELSE
    UPDATE erp.apr_template SET active = v_act, updated_by = coalesce(p_user, updated_by), updated_at = now() WHERE template_id = t.template_id AND active IS DISTINCT FROM v_act;
  END IF;
  DELETE FROM erp.apr_template_stage WHERE template_id = t.template_id;
  FOR r IN SELECT approver_position FROM erp.approval_rule
            WHERE company_code = p_company AND obj_type = p_obj AND rule_code = p_rule AND position_code IS NOT DISTINCT FROM p_pos
              AND (active OR NOT v_act)
            ORDER BY step, rule_id LOOP
    v_stage := erp._apr_legacy_stage(p_company, r.approver_position, p_user);
    IF NOT EXISTS (SELECT 1 FROM erp.apr_template_stage WHERE template_id = t.template_id AND stage_id = v_stage) THEN
      v_seq := v_seq + 1;
      INSERT INTO erp.apr_template_stage (template_id, seq, stage_id) VALUES (t.template_id, v_seq, v_stage);
    END IF;
  END LOOP;
  DELETE FROM erp.apr_template_originator WHERE template_id = t.template_id;
  IF p_pos IS NOT NULL THEN
    INSERT INTO erp.apr_template_originator (template_id, position_code) VALUES (t.template_id, p_pos);
  END IF;
  DELETE FROM erp.apr_template_condition WHERE template_id = t.template_id;
  IF v_lim IS NOT NULL AND k.primary_field IS NOT NULL THEN
    INSERT INTO erp.apr_template_condition (template_id, cond_no, field, op, value1) VALUES (t.template_id, 1, k.primary_field, k.primary_op, v_lim);
  END IF;
  PERFORM erp._apr_version(t.template_id, p_user, CASE WHEN v_new THEN 'migrated' ELSE 'legacy_rule_changed' END);
  RETURN t.template_id;
END $$;

-- ---- approval_template_setup: copied from 25_admin.sql:665 (+ templates and stages counts)
CREATE OR REPLACE FUNCTION erp.approval_template_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'catalogue', (SELECT jsonb_agg(jsonb_build_object('rule_code', s.rule_code, 'obj_types', to_jsonb(s.obj_types),
                    'position_required', s.position_required, 'limit_kind', s.limit_kind) ORDER BY s.sort) FROM erp._adm_rule_spec() s),
    'positions', (SELECT coalesce(jsonb_agg(jsonb_build_object('position_code', position_code, 'name', name) ORDER BY name), '[]'::jsonb) FROM erp.position),
    'rules', coalesce((
      SELECT jsonb_agg(jsonb_build_object('rule_id', r.rule_id, 'obj_type', r.obj_type, 'rule_code', r.rule_code,
               'position_code', r.position_code, 'position_name', p.name, 'limit_value', r.limit_value,
               'approver_position', r.approver_position, 'approver_name', a.name, 'step', r.step, 'active', r.active, 'note', r.note,
               'template_id', (SELECT t.template_id FROM erp.apr_template t WHERE t.company_code = r.company_code
                                 AND t.legacy_key = format('rule:%s|%s|%s', r.obj_type, r.rule_code, coalesce(r.position_code, '*'))))
             ORDER BY s.sort, r.obj_type, r.position_code NULLS FIRST, r.step)
        FROM erp.approval_rule r
        JOIN erp._adm_rule_spec() s ON s.rule_code = r.rule_code
        LEFT JOIN erp.position p ON p.position_code = r.position_code
        JOIN erp.position a ON a.position_code = r.approver_position
       WHERE r.company_code = p_company), '[]'::jsonb),
    'templates', (SELECT count(*) FROM erp.apr_template WHERE company_code = p_company),
    'stages', (SELECT count(*) FROM erp.apr_stage WHERE company_code = p_company),
    'pending', (SELECT count(*) FROM erp.approval ap WHERE ap.company_code = p_company AND ap.decision IS NULL AND NOT ap.superseded),
    'leave', (SELECT jsonb_build_object('long_leave_days', hs.long_leave_days, 'hr_approver_position', hs.hr_approver_position, 'owner_position', hs.owner_position)
                FROM erp.hr_setting hs WHERE hs.company_code = p_company));
END $$;

-- ---- approval_rule_save: copied from 25_admin.sql:692 (+ B2: the chain's template is rebuilt; refused once the template is
-- managed in the Approval Templates screen)
CREATE OR REPLACE FUNCTION erp.approval_rule_save(p_company varchar, p_rule jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  s      record;
  old    erp.approval_rule;
  v_id   bigint := nullif(p_rule->>'rule_id', '')::bigint;
  v_code text := nullif(p_rule->>'rule_code', '');
  v_obj  integer;
  v_pos  text := nullif(btrim(p_rule->>'position_code'), '');
  v_appr text := nullif(btrim(p_rule->>'approver_position'), '');
  v_lim  numeric;
  v_step integer := coalesce(nullif(p_rule->>'step', '')::integer, 1);
  v_act  boolean := coalesce((p_rule->>'active')::boolean, true);
  v_note text := nullif(btrim(p_rule->>'note'), '');
  v_tpl  text;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.approval_rule WHERE rule_id = v_id AND company_code = p_company FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Approval rule % not found in %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_code := coalesce(v_code, old.rule_code);
  END IF;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Choose the approval rule.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM erp._adm_rule_spec() x WHERE x.rule_code = v_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rule % is not a known approval rule.', v_code USING ERRCODE = 'P0001';
  END IF;
  v_obj := coalesce(nullif(p_rule->>'obj_type', '')::integer, old.obj_type, s.obj_types[1]);
  IF NOT v_obj = ANY (s.obj_types) THEN
    RAISE EXCEPTION 'This rule applies to document type % only.', array_to_string(s.obj_types, ' or ') USING ERRCODE = 'P0001';
  END IF;
  IF s.position_required AND v_pos IS NULL THEN
    RAISE EXCEPTION 'This limit is set per position. Choose the requester''s position.' USING ERRCODE = 'P0001';
  END IF;
  IF v_pos IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_pos) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_pos USING ERRCODE = 'P0001';
  END IF;
  IF v_appr IS NULL THEN
    RAISE EXCEPTION 'Choose who approves.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_appr) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_appr USING ERRCODE = 'P0001';
  END IF;
  IF v_step NOT BETWEEN 1 AND 9 THEN
    RAISE EXCEPTION 'The step must be between 1 and 9.' USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_lim := nullif(p_rule->>'limit_value', '')::numeric;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the limit as a number.' USING ERRCODE = 'P0001';
  END;
  IF s.limit_kind = 'none' THEN
    v_lim := NULL;
  ELSIF v_lim IS NULL THEN
    RAISE EXCEPTION 'Enter the limit for this rule.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'pct' AND v_lim NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'Enter a percentage between 0 and 100.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'pct_any' AND (v_lim <= 0 OR v_lim > 1000) THEN
    RAISE EXCEPTION 'Enter a percentage above 0 and up to 1000.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'amount' AND v_lim < 0 THEN
    RAISE EXCEPTION 'The amount can''t be negative.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'days' AND (v_lim <> trunc(v_lim) OR v_lim NOT BETWEEN 1 AND 365) THEN
    RAISE EXCEPTION 'Enter whole days between 1 and 365.' USING ERRCODE = 'P0001';
  END IF;
  SELECT t.name INTO v_tpl FROM erp.apr_template t
   WHERE t.company_code = p_company AND NOT t.legacy_sync
     AND t.legacy_key IN (format('rule:%s|%s|%s', v_obj, v_code, coalesce(v_pos, '*')),
                          format('rule:%s|%s|%s', old.obj_type, old.rule_code, coalesce(old.position_code, '*')));
  IF v_tpl IS NOT NULL THEN
    RAISE EXCEPTION 'This rule is now managed in Approval Templates (template "%"). Change it there.', v_tpl USING ERRCODE = 'P0001';
  END IF;

  BEGIN
    IF v_id IS NULL THEN
      INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, active, note)
      VALUES (p_company, v_obj, v_code, v_pos, v_lim, v_appr, v_step, v_act, v_note)
      RETURNING rule_id INTO v_id;
    ELSE
      UPDATE erp.approval_rule
         SET obj_type = v_obj, rule_code = v_code, position_code = v_pos, limit_value = v_lim, approver_position = v_appr,
             step = v_step, active = v_act, note = v_note
       WHERE rule_id = v_id;
    END IF;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'This rule already exists for that position and step. Change the existing rule instead.' USING ERRCODE = 'P0001';
  END;
  PERFORM erp._apr_sync_legacy(p_company, v_obj, v_code, v_pos, me.user_id);
  IF old.rule_id IS NOT NULL AND (old.obj_type, old.rule_code, coalesce(old.position_code, '*')) IS DISTINCT FROM (v_obj, v_code, coalesce(v_pos, '*')) THEN
    PERFORM erp._apr_sync_legacy(p_company, old.obj_type, old.rule_code, old.position_code, me.user_id);
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN old.rule_id IS NULL THEN 'approval_rule_create' ELSE 'approval_rule_change' END,
          'approval_rule', v_id::text,
          jsonb_build_object('before', CASE WHEN old.rule_id IS NULL THEN NULL ELSE to_jsonb(old) END,
                             'after', (SELECT to_jsonb(r) FROM erp.approval_rule r WHERE r.rule_id = v_id)));
  RETURN jsonb_build_object('rule_id', v_id);
END $$;

-- ---- approval_rule_delete: copied from 25_admin.sql:783 (+ B2 template sync)
CREATE OR REPLACE FUNCTION erp.approval_rule_delete(p_company varchar, p_rule_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  old erp.approval_rule;
  v_tpl text;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO old FROM erp.approval_rule WHERE rule_id = p_rule_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval rule % not found in %.', p_rule_id, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT t.name INTO v_tpl FROM erp.apr_template t
   WHERE t.company_code = p_company AND NOT t.legacy_sync AND t.legacy_key = format('rule:%s|%s|%s', old.obj_type, old.rule_code, coalesce(old.position_code, '*'));
  IF v_tpl IS NOT NULL THEN
    RAISE EXCEPTION 'This rule is now managed in Approval Templates (template "%"). Change it there.', v_tpl USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM erp.approval_rule WHERE rule_id = p_rule_id;
  PERFORM erp._apr_sync_legacy(p_company, old.obj_type, old.rule_code, old.position_code, me.user_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'approval_rule_delete', 'approval_rule', p_rule_id::text, jsonb_build_object('before', to_jsonb(old)));
  RETURN jsonb_build_object('rule_id', p_rule_id, 'deleted', true);
END $$;

-- ---- admin_positions: copied from 25_admin.sql:510 ('rules' also counts templates and stages)
CREATE OR REPLACE FUNCTION erp.admin_positions() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
BEGIN
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'), 'my_position', me.position_code, 'modules', to_jsonb(erp._adm_modules()),
    'positions', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'position_code', p.position_code, 'name', p.name,
               'levels', (SELECT coalesce(jsonb_object_agg(m, erp._adm_level(p.position_code, m)) FILTER (WHERE erp._adm_level(p.position_code, m) IS NOT NULL), '{}'::jsonb)
                            FROM unnest(erp._adm_modules()) m),
               'users', (SELECT count(*) FROM erp.app_user u WHERE u.position_code = p.position_code AND u.active),
               'rules', (SELECT count(*) FROM erp.approval_rule r WHERE p.position_code IN (r.position_code, r.approver_position))
                        + (SELECT count(*) FROM erp.apr_template_originator o WHERE o.position_code = p.position_code)
                        + (SELECT count(*) FROM erp.apr_stage_authorizer a WHERE a.position_code = p.position_code))
             ORDER BY p.name)
        FROM erp.position p), '[]'::jsonb));
END $$;

-- ---- position_delete: copied from 25_admin.sql:563 (+ templates and stages)
CREATE OR REPLACE FUNCTION erp.position_delete(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  n   integer;
  v_name text;
BEGIN
  SELECT name INTO v_name FROM erp.position WHERE position_code = p_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', p_code USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO n FROM erp.app_user WHERE position_code = p_code;
  IF n > 0 THEN
    RAISE EXCEPTION 'Position % still has % user(s). Move them to another position first.', p_code, n USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO n FROM erp.approval_rule WHERE p_code IN (position_code, approver_position);
  IF n > 0 THEN
    RAISE EXCEPTION 'Position % is used in % approval rule(s). Change those rules first.', p_code, n USING ERRCODE = 'P0001';
  END IF;
  SELECT (SELECT count(*) FROM erp.apr_template_originator WHERE position_code = p_code) + (SELECT count(*) FROM erp.apr_stage_authorizer WHERE position_code = p_code) INTO n;
  IF n > 0 THEN
    RAISE EXCEPTION 'Position % is used in % approval template(s) or stage(s). Change those first.', p_code, n USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    DELETE FROM erp.position WHERE position_code = p_code;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Position % is still used elsewhere (approvals, user invitations or settings), so it can''t be deleted.', p_code USING ERRCODE = 'P0001';
  END;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, NULL, 'position_delete', 'position', p_code, jsonb_build_object('name', v_name));
  RETURN jsonb_build_object('position_code', p_code, 'deleted', true);
END $$;

-- ============ 8. Migration of the existing rules (idempotent) and the ZZ99 sample ============
SELECT count(erp._apr_sync_legacy(x.company_code, x.obj_type, x.rule_code, x.position_code, NULL)) AS b2_rule_chains_synced
  FROM (SELECT DISTINCT company_code, obj_type, rule_code, position_code FROM erp.approval_rule) x;

-- SAMPLE (ZZ99 only, inactive): an incoming-payment template to show the new kind. Activating it makes incoming payments
-- above 100,000 AED wait for the finance manager.
DO $$
DECLARE
  v_t bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99') AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_FIN_MGR')
     AND NOT EXISTS (SELECT 1 FROM erp.apr_template WHERE company_code = 'ZZ99' AND name = 'SAMPLE · Incoming payments above 100,000') THEN
    INSERT INTO erp.apr_template (company_code, name, description, kind, obj_type, active, source)
    VALUES ('ZZ99', 'SAMPLE · Incoming payments above 100,000', 'SAMPLE for test company ZZ99 only. Inactive.', 'incoming_payment', 24, false, 'sample')
    RETURNING template_id INTO v_t;
    INSERT INTO erp.apr_template_stage (template_id, seq, stage_id) VALUES (v_t, 1, erp._apr_legacy_stage('ZZ99', 'QA_FIN_MGR', NULL));
    INSERT INTO erp.apr_template_condition (template_id, cond_no, field, op, value1) VALUES (v_t, 1, 'amount', 'gt', 100000);
    PERFORM erp._apr_version(v_t, NULL, 'created');
  END IF;
END $$;

-- ============ System health: marker for this file (copied from 30) ============
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save'), ('31_approvals.sql', 'approval_template_save')
  ) AS v(file_name, object)
$$;

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._apr_kinds(), erp._apr_kind_label(text), erp._apr_kind_short(text), erp._apr_field_label(text), erp._apr_test(text, numeric, numeric, numeric),
  erp._apr_hit(jsonb, jsonb), erp._apr_cond_text(jsonb), erp._apr_msg(text, text, jsonb), erp._apr_user_for(text), erp._apr_stage_who(bigint),
  erp._apr_rep(bigint), erp._apr_rules(varchar, integer, text[], text), erp._apr_my_limit(varchar, integer, text, text), erp._apr_fill(),
  erp._apr_authorizer(bigint, uuid, text), erp._apr_is_mine(bigint, erp.app_user), erp._apr_can_act(bigint, erp.app_user),
  erp._apr_vote(bigint[], erp.app_user, text, text, jsonb), erp._apr_who(varchar, text, text, smallint), erp._apr_row_who(bigint, text),
  erp._apr_votes(bigint), erp._apr_trail(varchar, text, text), erp._apr_company_user(varchar, uuid), erp._apr_snapshot(bigint),
  erp._apr_version(bigint, uuid, text), erp._apr_people(varchar, jsonb, text), erp._apr_base(), erp._apr_legacy_stage(varchar, text, uuid),
  erp._apr_sync_legacy(varchar, integer, text, text, uuid), erp._adm_rule_spec(), erp._health_files()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.approval_setup(varchar), erp.approval_stage_save(varchar, jsonb), erp.approval_stage_delete(varchar, bigint),
  erp.approval_template_save(varchar, jsonb), erp.approval_template_set_active(varchar, bigint, boolean), erp.approval_template_delete(varchar, bigint),
  erp.approval_template_history(varchar, bigint), erp.approval_status_report(varchar, jsonb), erp.approval_inbox(),
  erp.approval_template_setup(varchar), erp.approval_rule_save(varchar, jsonb), erp.approval_rule_delete(varchar, bigint),
  erp.admin_positions(), erp.position_delete(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.approval_setup(varchar), erp.approval_stage_save(varchar, jsonb), erp.approval_stage_delete(varchar, bigint),
  erp.approval_template_save(varchar, jsonb), erp.approval_template_set_active(varchar, bigint, boolean), erp.approval_template_delete(varchar, bigint),
  erp.approval_template_history(varchar, bigint), erp.approval_status_report(varchar, jsonb), erp.approval_inbox(),
  erp.approval_template_setup(varchar), erp.approval_rule_save(varchar, jsonb), erp.approval_rule_delete(varchar, bigint),
  erp.admin_positions(), erp.position_delete(text)
  TO authenticated;

COMMENT ON TABLE erp.apr_stage IS 'B2 Approval Stages: who decides (positions / users, live) and how many approvals or rejections close the stage.';
COMMENT ON TABLE erp.apr_template IS 'B2 Approval Templates: per company and document kind; originators, ordered stages, conditions, active flag, version history.';
COMMENT ON TABLE erp.approval_vote IS 'B2: each authorizer''s vote on an erp.approval row (a stage may need several approvals).';

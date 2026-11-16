-- 46 · SANA agent, phase 1 (S3): rules per country, findings, append-only event log, alerts with a daily budget, feedback on
-- findings. Spec: "SANA AND UI UX UPADATE PROMPT/sana-agent-spec.md"; plan agreed 16 Nov 2026.
--
-- Rules
--   * Law rules are keyed by erp.company.country, never hard-coded: erp.sana_rule_default (per country, written only here)
--     seeds erp.sana_rule (per company, Admin may change thresholds without code). All live companies are AE today; the IN
--     defaults are seeded for the Indian companies and tested on a temporary IN company (rolled back).
--   * Nothing here writes business data. SANA proposes; Apply (phase 2) is the ERP's own save RPC under the user's session.
--   * Writes go through SECURITY DEFINER RPCs that fill user_id / role server-side; users have SELECT only (RLS: own rows).
--     The owner (business module) sees every finding and alert for their companies. IT and system admin do NOT (S1 rule:
--     IT runs the system, it does not read sales or finance) — they only edit rules.
--   * erp.sana_event_log is append-only: no UPDATE / DELETE / TRUNCATE privilege for anyone, plus triggers that raise even for
--     the table owner.
--   * erp.sana_alert: at most 5 per user per (Dubai) day, enforced by a trigger under an advisory lock.
-- Safe to run twice. Not applied to live until Ashif says go (branch first).

-- ============ 1. Rules ============
CREATE TABLE IF NOT EXISTS erp.sana_rule_default (
    country     char(2) NOT NULL,
    rule_code   text NOT NULL CHECK (rule_code ~ '^[a-z][a-z0-9_]{1,40}$'),
    params      jsonb NOT NULL DEFAULT '{}',
    enabled     boolean NOT NULL DEFAULT true,
    note        text,
    PRIMARY KEY (country, rule_code)
);
CREATE TABLE IF NOT EXISTS erp.sana_rule (
    company_code varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    rule_code    text NOT NULL CHECK (rule_code ~ '^[a-z][a-z0-9_]{1,40}$'),
    params       jsonb NOT NULL DEFAULT '{}',
    enabled      boolean NOT NULL DEFAULT true,
    updated_by   uuid,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, rule_code)
);

INSERT INTO erp.sana_rule_default (country, rule_code, params, enabled, note) VALUES
  -- UAE
  ('AE', 'vat_rate',               '{"rate": 5, "by": "tax_code"}', true,  'Standard VAT 5 % by tax code'),
  ('AE', 'trn_format',             '{"digits": 15}', true,               'Supplier / customer TRN: 15 digits'),
  ('AE', 'gst_rate',               '{}', false, NULL),
  ('AE', 'gstin_format',           '{}', false, NULL),
  ('AE', 'cash_receipt_limit',     '{}', false, 'No cash limit rule in the UAE'),
  ('AE', 'cash_payment_limit',     '{}', false, 'No cash limit rule in the UAE'),
  ('AE', 'eway_bill',              '{}', false, NULL),
  ('AE', 'mrp_cap',                '{}', false, 'No MRP cap in the UAE'),
  ('AE', 'msme_terms',             '{}', false, NULL),
  ('AE', 'no_gst_bill_visibility', '{}', false, NULL),
  ('AE', 'credit_limit',           '{"warn_pct": 90}', true, 'Warn at 90 % of the credit limit, law: none'),
  ('AE', 'duplicate_bill',         '{"min_score": 70, "window_days": 90}', true, NULL),
  ('AE', 'licence_expiry',         '{"days": 30}', true, 'item_certificate.expires_on'),
  ('AE', 'masking',                '{"ids": ["emirates_id", "passport"], "bank": "last4"}', true, NULL),
  ('AE', 'number_format',          '{"grouping": "3", "currency": "AED"}', true, NULL),
  -- India
  ('IN', 'vat_rate',               '{}', false, NULL),
  ('IN', 'trn_format',             '{}', false, NULL),
  ('IN', 'gst_rate',               '{"by": "hsn"}', true, 'GST rate by HSN'),
  ('IN', 'gstin_format',           '{"pattern": "^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$"}', true, NULL),
  ('IN', 'cash_receipt_limit',     '{"amount": 200000, "action": "refuse"}', true, 'Income Tax Act 269ST: cash receipt of 2,00,000 or more'),
  ('IN', 'cash_payment_limit',     '{"amount": 10000, "action": "warn_reason"}', true, '40A(3): cash payment above 10,000 needs a reason'),
  ('IN', 'eway_bill',              '{"amount": 50000}', true, NULL),
  ('IN', 'mrp_cap',                '{}', true, 'Sale price may not exceed MRP'),
  ('IN', 'msme_terms',             '{"days": 45}', true, 'MSMED Act: pay MSME suppliers within 45 days'),
  ('IN', 'no_gst_bill_visibility', '{"roles": ["admin", "ca"]}', true, NULL),
  ('IN', 'credit_limit',           '{"warn_pct": 90}', true, NULL),
  ('IN', 'duplicate_bill',         '{"min_score": 70, "window_days": 90}', true, NULL),
  ('IN', 'licence_expiry',         '{"days": 30}', true, NULL),
  ('IN', 'masking',                '{"ids": ["aadhaar", "pan"], "bank": "last4"}', true, NULL),
  ('IN', 'number_format',          '{"grouping": "indian", "currency": "INR"}', true, NULL)
ON CONFLICT (country, rule_code) DO UPDATE SET params = EXCLUDED.params, enabled = EXCLUDED.enabled, note = EXCLUDED.note;

-- Seed every company from its country's defaults (keeps what an Admin already changed).
CREATE OR REPLACE FUNCTION erp._sana_rule_seed(p_company varchar) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH ins AS (
    INSERT INTO erp.sana_rule (company_code, rule_code, params, enabled)
    SELECT c.company_code, d.rule_code, d.params, d.enabled
      FROM erp.company c JOIN erp.sana_rule_default d ON d.country = upper(c.country)
     WHERE c.company_code = p_company
    ON CONFLICT (company_code, rule_code) DO NOTHING RETURNING 1)
  SELECT count(*)::integer FROM ins
$$;
SELECT erp._sana_rule_seed(company_code) FROM erp.company;

CREATE OR REPLACE FUNCTION erp._sana_rule_seed_trg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN PERFORM erp._sana_rule_seed(NEW.company_code); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS sana_rule_seed ON erp.company;
CREATE TRIGGER sana_rule_seed AFTER INSERT OR UPDATE OF country ON erp.company FOR EACH ROW EXECUTE FUNCTION erp._sana_rule_seed_trg();

-- The rule for a company (NULL when the company has no such rule or it is switched off). Used by the check RPCs (47).
CREATE OR REPLACE FUNCTION erp.sana_rule_params(p_company varchar, p_rule text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT r.params FROM erp.sana_rule r WHERE r.company_code = p_company AND r.rule_code = p_rule AND r.enabled AND erp.can_see(p_company)
$$;

ALTER TABLE erp.sana_rule_default ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sana_rule ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_rule_default, erp.sana_rule FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sana_rule_default, erp.sana_rule TO authenticated;
DROP POLICY IF EXISTS sana_rule_default_read ON erp.sana_rule_default;
CREATE POLICY sana_rule_default_read ON erp.sana_rule_default FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS sana_rule_read ON erp.sana_rule;
CREATE POLICY sana_rule_read ON erp.sana_rule FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- ============ 2. Findings, event log, alerts, feedback ============
CREATE TABLE IF NOT EXISTS erp.sana_finding (
    id              bigserial PRIMARY KEY,
    company_code    varchar(8) NOT NULL REFERENCES erp.company,
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    screen          text CHECK (length(screen) <= 60),
    record_type     text NOT NULL CHECK (record_type IN ('document', 'payment', 'partner', 'item', 'home')),
    record_id       text NOT NULL CHECK (length(record_id) <= 60),
    rank            integer NOT NULL DEFAULT 0,
    severity        text NOT NULL CHECK (severity IN ('law', 'risk', 'info')),
    code            text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_.]{1,60}$'),
    title           text NOT NULL CHECK (length(title) <= 200),
    body            text CHECK (length(body) <= 2000),
    confidence      text NOT NULL DEFAULT 'check_this' CHECK (confidence IN ('likely', 'possible', 'check_this')),
    score           integer CHECK (score BETWEEN 0 AND 100),
    evidence        jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(evidence) = 'array'),
    proposed_action jsonb CHECK (proposed_action IS NULL OR jsonb_typeof(proposed_action) = 'object'),
    source          text NOT NULL CHECK (source IN ('rule', 'model')),
    status          text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'applied', 'ignored')),
    decided_by      uuid,
    decided_at      timestamptz,
    model_version   text CHECK (length(model_version) <= 80),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sana_finding_user_record ON erp.sana_finding (user_id, record_type, record_id, created_at DESC);
CREATE INDEX IF NOT EXISTS sana_finding_company ON erp.sana_finding (company_code, created_at DESC);

CREATE TABLE IF NOT EXISTS erp.sana_event_log (
    id              bigserial PRIMARY KEY,
    company_code    varchar(8) NOT NULL REFERENCES erp.company,
    kind            text NOT NULL CHECK (kind IN ('proposal', 'apply', 'ignore', 'answer', 'alert', 'line', 'now')),
    record_type     text CHECK (record_type IN ('document', 'payment', 'partner', 'item', 'home')),
    record_id       text CHECK (length(record_id) <= 60),
    finding_id      bigint REFERENCES erp.sana_finding ON DELETE RESTRICT,
    before          jsonb,
    after           jsonb,
    user_id         uuid NOT NULL,
    role            text,
    screen          text CHECK (length(screen) <= 60),
    evidence        jsonb NOT NULL DEFAULT '[]',
    model_version   text CHECK (length(model_version) <= 80),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sana_event_user_record ON erp.sana_event_log (user_id, record_type, record_id, created_at DESC);
CREATE INDEX IF NOT EXISTS sana_event_company ON erp.sana_event_log (company_code, created_at DESC);

CREATE OR REPLACE FUNCTION erp._sana_event_log_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'The SANA event log is append-only (% is not allowed).', TG_OP USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS sana_event_log_no_change ON erp.sana_event_log;
CREATE TRIGGER sana_event_log_no_change BEFORE UPDATE OR DELETE ON erp.sana_event_log FOR EACH ROW EXECUTE FUNCTION erp._sana_event_log_immutable();
DROP TRIGGER IF EXISTS sana_event_log_no_truncate ON erp.sana_event_log;
CREATE TRIGGER sana_event_log_no_truncate BEFORE TRUNCATE ON erp.sana_event_log FOR EACH STATEMENT EXECUTE FUNCTION erp._sana_event_log_immutable();

CREATE TABLE IF NOT EXISTS erp.sana_alert (
    id              bigserial PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code    varchar(8) NOT NULL REFERENCES erp.company,
    finding_id      bigint REFERENCES erp.sana_finding ON DELETE CASCADE,
    channel         text NOT NULL DEFAULT 'banner' CHECK (channel IN ('banner', 'push', 'whatsapp')),   -- whatsapp: later phase (TODO)
    sent_at         timestamptz NOT NULL DEFAULT now(),
    dismissed_at    timestamptz
);
CREATE INDEX IF NOT EXISTS sana_alert_user_day ON erp.sana_alert (user_id, sent_at DESC);

-- At most 5 alerts per user per Dubai day. A CHECK constraint cannot count rows, so: trigger + advisory lock per user, so two
-- parallel inserts cannot both see 4. Law warnings at the point of entry are findings, not alerts, and do not count.
CREATE OR REPLACE FUNCTION erp._sana_alert_budget() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE n integer; day date := (coalesce(NEW.sent_at, now()) AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('sana_alert:' || NEW.user_id::text, 0));
  SELECT count(*) INTO n FROM erp.sana_alert a
   WHERE a.user_id = NEW.user_id AND (a.sent_at AT TIME ZONE 'Asia/Dubai')::date = day;
  IF n >= 5 THEN
    RAISE EXCEPTION 'SANA alert budget: % already has 5 alerts today.', NEW.user_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sana_alert_budget ON erp.sana_alert;
CREATE TRIGGER sana_alert_budget BEFORE INSERT ON erp.sana_alert FOR EACH ROW EXECUTE FUNCTION erp._sana_alert_budget();

-- Feedback: the existing table (answers) also takes findings. message_id stays unique (sana_feedback_set keeps working).
ALTER TABLE erp.sana_feedback ADD COLUMN IF NOT EXISTS id bigserial;
ALTER TABLE erp.sana_feedback ADD COLUMN IF NOT EXISTS finding_id bigint REFERENCES erp.sana_finding ON DELETE CASCADE;
ALTER TABLE erp.sana_feedback ADD COLUMN IF NOT EXISTS correction text CHECK (length(correction) <= 1000);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sana_feedback_pkey' AND conrelid = 'erp.sana_feedback'::regclass
              AND pg_get_constraintdef(oid) LIKE '%(message_id)%') THEN
    ALTER TABLE erp.sana_feedback DROP CONSTRAINT sana_feedback_pkey;
    ALTER TABLE erp.sana_feedback ADD CONSTRAINT sana_feedback_pkey PRIMARY KEY (id);
    ALTER TABLE erp.sana_feedback ADD CONSTRAINT sana_feedback_message_key UNIQUE (message_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sana_feedback_one_target' AND conrelid = 'erp.sana_feedback'::regclass) THEN
    ALTER TABLE erp.sana_feedback ADD CONSTRAINT sana_feedback_one_target CHECK (num_nonnulls(message_id, finding_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sana_feedback_finding_user' AND conrelid = 'erp.sana_feedback'::regclass) THEN
    ALTER TABLE erp.sana_feedback ADD CONSTRAINT sana_feedback_finding_user UNIQUE (finding_id, user_id);
  END IF;
END $$;
ALTER TABLE erp.sana_feedback ALTER COLUMN message_id DROP NOT NULL;

-- RLS: own rows; the owner (business) sees all rows of their companies. SELECT only — writes through the RPCs below.
ALTER TABLE erp.sana_finding ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sana_event_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sana_alert ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_finding, erp.sana_event_log, erp.sana_alert FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE erp.sana_finding_id_seq, erp.sana_event_log_id_seq, erp.sana_alert_id_seq FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sana_finding, erp.sana_event_log, erp.sana_alert TO authenticated;
DROP POLICY IF EXISTS sana_finding_read ON erp.sana_finding;
CREATE POLICY sana_finding_read ON erp.sana_finding FOR SELECT TO authenticated
  USING (user_id = erp.current_user_id() OR (erp.can_see(company_code) AND (SELECT erp.module_level('business')) IS NOT NULL));
DROP POLICY IF EXISTS sana_event_read ON erp.sana_event_log;
CREATE POLICY sana_event_read ON erp.sana_event_log FOR SELECT TO authenticated
  USING (user_id = erp.current_user_id() OR (erp.can_see(company_code) AND (SELECT erp.module_level('business')) IS NOT NULL));
DROP POLICY IF EXISTS sana_alert_read ON erp.sana_alert;
CREATE POLICY sana_alert_read ON erp.sana_alert FOR SELECT TO authenticated
  USING (user_id = erp.current_user_id() OR (erp.can_see(company_code) AND (SELECT erp.module_level('business')) IS NOT NULL));
-- sana_feedback stays unreadable for users (S1 rule: written and read only through the RPCs).
REVOKE ALL ON erp.sana_feedback FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS sana_feedback_own ON erp.sana_feedback;

-- ============ 3. RPCs ============
CREATE OR REPLACE FUNCTION erp._sana_me() RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE u erp.app_user;
BEGIN
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501'; END IF;
  RETURN u;
END $$;

-- Effective rules for a company the caller may see.
CREATE OR REPLACE FUNCTION erp.sana_rules(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE c erp.company;
BEGIN
  PERFORM erp._sana_me();
  SELECT * INTO c FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND OR NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object('company', c.company_code, 'country', c.country,
    'rules', (SELECT coalesce(jsonb_agg(jsonb_build_object('rule', r.rule_code, 'params', r.params, 'enabled', r.enabled, 'updated_at', r.updated_at) ORDER BY r.rule_code), '[]')
                FROM erp.sana_rule r WHERE r.company_code = p_company));
END $$;

-- Admin (full Administration) changes a threshold or switches a rule. Only rules that exist for the company's country.
CREATE OR REPLACE FUNCTION erp.sana_rule_save(p_company varchar, p_rule text, p_params jsonb, p_enabled boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._adm_guard(true); old erp.sana_rule; new_row erp.sana_rule;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO old FROM erp.sana_rule WHERE company_code = p_company AND rule_code = p_rule;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no SANA rule % for %.', p_rule, p_company USING ERRCODE = 'P0002'; END IF;
  IF p_params IS NOT NULL AND jsonb_typeof(p_params) <> 'object' THEN RAISE EXCEPTION 'Rule settings must be an object.' USING ERRCODE = 'P0001'; END IF;
  UPDATE erp.sana_rule SET params = coalesce(p_params, params), enabled = coalesce(p_enabled, enabled), updated_by = me.user_id, updated_at = now()
   WHERE company_code = p_company AND rule_code = p_rule RETURNING * INTO new_row;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (me.user_id::text, p_company, 'sana_rule_save', 'sana_rule', p_rule,
            jsonb_build_object('before', jsonb_build_object('params', old.params, 'enabled', old.enabled), 'after', jsonb_build_object('params', new_row.params, 'enabled', new_row.enabled)));
  RETURN jsonb_build_object('rule', new_row.rule_code, 'params', new_row.params, 'enabled', new_row.enabled);
END $$;

-- The Edge Function stores the validated cards for this user (one 'now' or 'line' event row). Returns the ids in order.
CREATE OR REPLACE FUNCTION erp.sana_findings_save(p_company varchar, p_screen text, p_record_type text, p_record_id text,
                                                  p_findings jsonb, p_model text DEFAULT NULL, p_kind text DEFAULT 'now') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._sana_me(); f jsonb; ids bigint[] := '{}'; fid bigint; i integer := 0;
BEGIN
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501'; END IF;
  IF p_kind NOT IN ('now', 'line') THEN RAISE EXCEPTION 'Kind must be now or line.' USING ERRCODE = 'P0001'; END IF;
  IF jsonb_typeof(coalesce(p_findings, '[]')) <> 'array' OR jsonb_array_length(coalesce(p_findings, '[]')) > 20 THEN
    RAISE EXCEPTION 'Send at most 20 findings as a list.' USING ERRCODE = 'P0001';
  END IF;
  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(p_findings, '[]')) LOOP
    i := i + 1;
    INSERT INTO erp.sana_finding (company_code, user_id, screen, record_type, record_id, rank, severity, code, title, body, confidence, score,
                                  evidence, proposed_action, source, model_version)
    VALUES (p_company, me.user_id, left(p_screen, 60), p_record_type, p_record_id, coalesce((f ->> 'rank')::integer, i), f ->> 'severity', f ->> 'code',
            left(f ->> 'title', 200), left(f ->> 'body', 2000), coalesce(f ->> 'confidence', 'check_this'), (f ->> 'score')::integer,
            coalesce(f -> 'evidence', '[]'), f -> 'proposed_action', coalesce(f ->> 'source', 'rule'), left(p_model, 80))
    RETURNING id INTO fid;
    ids := ids || fid;
  END LOOP;
  INSERT INTO erp.sana_event_log (company_code, kind, record_type, record_id, user_id, role, screen, evidence, model_version, after)
    VALUES (p_company, p_kind, p_record_type, p_record_id, me.user_id, me.position_code, left(p_screen, 60),
            (SELECT coalesce(jsonb_agg(e), '[]') FROM jsonb_array_elements(coalesce(p_findings, '[]')) x, jsonb_array_elements(coalesce(x -> 'evidence', '[]')) e),
            left(p_model, 80), jsonb_build_object('findings', to_jsonb(ids)));
  RETURN jsonb_build_object('ids', to_jsonb(ids));
END $$;

-- Apply / Ignore (phase 2 calls this after the ERP's own save RPC succeeded). Own findings only; one decision per finding.
CREATE OR REPLACE FUNCTION erp.sana_finding_decide(p_id bigint, p_status text, p_before jsonb DEFAULT NULL, p_after jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._sana_me(); f erp.sana_finding;
BEGIN
  IF p_status NOT IN ('applied', 'ignored') THEN RAISE EXCEPTION 'Status must be applied or ignored.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO f FROM erp.sana_finding WHERE id = p_id AND user_id = me.user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Suggestion not found.' USING ERRCODE = 'P0002'; END IF;
  IF f.status <> 'proposed' THEN RAISE EXCEPTION 'This suggestion was already %.', f.status USING ERRCODE = 'P0001'; END IF;
  UPDATE erp.sana_finding SET status = p_status, decided_by = me.user_id, decided_at = now() WHERE id = p_id;
  INSERT INTO erp.sana_event_log (company_code, kind, record_type, record_id, finding_id, before, after, user_id, role, screen, evidence, model_version)
    VALUES (f.company_code, CASE p_status WHEN 'applied' THEN 'apply' ELSE 'ignore' END, f.record_type, f.record_id, f.id, p_before, p_after,
            me.user_id, me.position_code, f.screen, f.evidence, f.model_version);
  RETURN jsonb_build_object('id', p_id, 'status', p_status);
END $$;

-- Other events (answer, proposal, alert) from the Edge Function or the panel.
CREATE OR REPLACE FUNCTION erp.sana_event_add(p_company varchar, p_kind text, p_record_type text, p_record_id text,
                                              p_evidence jsonb DEFAULT '[]', p_model text DEFAULT NULL, p_screen text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._sana_me(); eid bigint;
BEGIN
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501'; END IF;
  IF p_kind NOT IN ('proposal', 'answer', 'alert') THEN RAISE EXCEPTION 'Use sana_findings_save or sana_finding_decide for %.', p_kind USING ERRCODE = 'P0001'; END IF;
  INSERT INTO erp.sana_event_log (company_code, kind, record_type, record_id, user_id, role, screen, evidence, model_version)
    VALUES (p_company, p_kind, p_record_type, p_record_id, me.user_id, me.position_code, left(p_screen, 60), coalesce(p_evidence, '[]'), left(p_model, 80))
    RETURNING id INTO eid;
  RETURN eid;
END $$;

-- Done tab: this user's events for one record (RLS also lets the owner read others' rows, but this RPC shows the caller's own).
CREATE OR REPLACE FUNCTION erp.sana_events(p_company varchar, p_record_type text, p_record_id text, p_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'finding_id', e.finding_id, 'before', e.before, 'after', e.after,
                                               'evidence', e.evidence, 'at', e.created_at) ORDER BY e.created_at DESC), '[]')
    FROM (SELECT * FROM erp.sana_event_log e
           WHERE e.company_code = p_company AND e.record_type = p_record_type AND e.record_id = p_record_id AND e.user_id = erp.current_user_id()
           ORDER BY e.created_at DESC LIMIT least(greatest(coalesce(p_limit, 50), 1), 200)) e
$$;

REVOKE ALL ON FUNCTION erp._sana_rule_seed(varchar), erp._sana_rule_seed_trg(), erp._sana_event_log_immutable(), erp._sana_alert_budget(), erp._sana_me()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.sana_rule_params(varchar, text), erp.sana_rules(varchar), erp.sana_rule_save(varchar, text, jsonb, boolean),
  erp.sana_findings_save(varchar, text, text, text, jsonb, text, text), erp.sana_finding_decide(bigint, text, jsonb, jsonb),
  erp.sana_event_add(varchar, text, text, text, jsonb, text, text), erp.sana_events(varchar, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._sana_me() TO authenticated;
GRANT EXECUTE ON FUNCTION erp.sana_rule_params(varchar, text), erp.sana_rules(varchar), erp.sana_rule_save(varchar, text, jsonb, boolean),
  erp.sana_findings_save(varchar, text, text, text, jsonb, text, text), erp.sana_finding_decide(bigint, text, jsonb, jsonb),
  erp.sana_event_add(varchar, text, text, text, jsonb, text, text), erp.sana_events(varchar, text, text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

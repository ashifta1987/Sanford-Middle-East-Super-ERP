-- 36_sana.sql · S1 · SANA, the Southfield AI Neural Assistant: settings, private conversation log, usage counters, feedback
-- and the read-only "tools" Sana may call. Replaces the first version (15_sana.sql in the Southfield bundle, never applied on
-- Supabase) and A11's "Ask AI" (26_reports.sql ai_* functions and A10's ai_setting stay in place, unused by the UI).
--
-- How role limits are enforced (three layers, each enough on its own for the data it covers):
--   1. Every tool below is SECURITY INVOKER: it runs as the signed-in user, so the row-level rules of 12 / 16 (A1 restrictive
--      module policies) / 24 (HR) apply to every row it reads.
--   2. Every tool checks the user's position modules itself (erp.sana_has) and returns {"denied": true} instead of data when
--      the role does not cover the topic. A1 levels: Read or Full both count (read-only users may ask about their modules).
--      'admin' / 'it' do NOT unlock business data in Sana (S1 rule; IT runs the system, it does not read sales or finance).
--   3. The Edge Function only offers the model the tools the user's modules allow, and the model is told to refuse the rest.
-- Field limits: cost prices only for finance / purchasing / inventory; commercial terms only for finance; ID numbers, passport,
-- birth date, salary, bank accounts and IBANs are never returned by any Sana tool.
-- Nothing here writes business data. Writes (log, feedback, delete own conversation, settings) are SECURITY DEFINER,
-- search_path = erp, pg_temp, audited. Safe to run twice.

-- ---------- The first version's signatures (15_sana.sql), in case it was applied somewhere ----------
DROP FUNCTION IF EXISTS erp.sana_document(text, integer, varchar);
DROP FUNCTION IF EXISTS erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text);
DROP FUNCTION IF EXISTS erp.sana_usage_today();

-- ============ 1. Settings (per company; Administration › Add-Ons › AI Assistant (Sana)) ============
-- No row = on, voice on, 200 questions per user per day, all 11 languages. The provider key is never stored here:
-- it is the Supabase secret ANTHROPIC_API_KEY, read only by the sana Edge Function.
CREATE TABLE IF NOT EXISTS erp.sana_settings (
    company_code    varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    enabled         boolean NOT NULL DEFAULT true,
    voice_enabled   boolean NOT NULL DEFAULT true,
    daily_limit     integer NOT NULL DEFAULT 200 CHECK (daily_limit BETWEEN 0 AND 5000),  -- questions per user per day
    languages       text[]  NOT NULL DEFAULT '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}',
    updated_by      uuid,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.sana_settings ADD COLUMN IF NOT EXISTS updated_by uuid;
ALTER TABLE erp.sana_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sana_settings TO authenticated;
DROP POLICY IF EXISTS sana_settings_read ON erp.sana_settings;
CREATE POLICY sana_settings_read ON erp.sana_settings FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- A10 / A11 "AI Assistant" switch → Sana. Only the on/off choice carries over (provider, model, tables and the monthly limit
-- belonged to the old pipeline). Runs once per company: an existing Sana row is never overwritten.
INSERT INTO erp.sana_settings (company_code, enabled, updated_by, updated_at)
SELECT a.company_code, a.enabled, a.updated_by, a.updated_at FROM erp.ai_setting a
ON CONFLICT (company_code) DO NOTHING;

-- ============ 2. Conversations (each person sees only their own) ============
CREATE TABLE IF NOT EXISTS erp.sana_conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code    varchar(8),
    title           text NOT NULL DEFAULT '',
    language        text,
    started_at      timestamptz NOT NULL DEFAULT now(),
    last_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS erp.sana_message (
    message_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES erp.sana_conversation ON DELETE CASCADE,
    role            text NOT NULL CHECK (role IN ('user', 'assistant')),
    content         text NOT NULL,
    tools           jsonb NOT NULL DEFAULT '[]',      -- tool names and arguments used for this answer
    sources         jsonb NOT NULL DEFAULT '[]',      -- links shown under the answer
    denied          boolean NOT NULL DEFAULT false,   -- the question needed data outside the user's role
    mode            text,                             -- 'ai' (model) or 'basic' (no model connected / model failed)
    via             text CHECK (via IN ('text', 'voice')),
    created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS language text;
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS context jsonb;              -- page context hint ({type, kind, company, number|code})
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS fallback boolean NOT NULL DEFAULT false;  -- AI mode failed, basic mode answered
CREATE INDEX IF NOT EXISTS sana_message_conv ON erp.sana_message (conversation_id, message_id);
CREATE INDEX IF NOT EXISTS sana_conversation_user ON erp.sana_conversation (user_id, last_at DESC);
ALTER TABLE erp.sana_conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sana_message ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_conversation, erp.sana_message FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sana_conversation, erp.sana_message TO authenticated;
DROP POLICY IF EXISTS sana_conv_own ON erp.sana_conversation;
CREATE POLICY sana_conv_own ON erp.sana_conversation FOR SELECT TO authenticated USING (user_id = erp.current_user_id());
DROP POLICY IF EXISTS sana_msg_own ON erp.sana_message;
CREATE POLICY sana_msg_own ON erp.sana_message FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.sana_conversation c WHERE c.conversation_id = sana_message.conversation_id AND c.user_id = erp.current_user_id()));

-- 👍 / 👎 per answer (owner only; admins see counts only, through sana_setup).
CREATE TABLE IF NOT EXISTS erp.sana_feedback (
    message_id      bigint PRIMARY KEY REFERENCES erp.sana_message ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code    varchar(8),
    value           smallint NOT NULL CHECK (value IN (-1, 1)),
    note            text CHECK (length(note) <= 500),
    at              timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.sana_feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_feedback FROM PUBLIC, anon, authenticated;

-- Usage counters per company, user and (Dubai) day: the daily limit and the admin's counts. Kept apart from the conversations,
-- so deleting a conversation never resets today's limit and admins never need to read anyone's questions.
CREATE TABLE IF NOT EXISTS erp.sana_usage (
    company_code    varchar(8) NOT NULL,
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    day             date NOT NULL,
    questions       integer NOT NULL DEFAULT 0,
    refused         integer NOT NULL DEFAULT 0,
    voice           integer NOT NULL DEFAULT 0,
    ai              integer NOT NULL DEFAULT 0,
    basic           integer NOT NULL DEFAULT 0,
    fallback        integer NOT NULL DEFAULT 0,
    PRIMARY KEY (company_code, user_id, day)
);
ALTER TABLE erp.sana_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_usage FROM PUBLIC, anon, authenticated;

-- ============ 3. Helpers ============
-- Owner/MD ('business') may ask about everything; everyone else about their position's modules at Read or Full (A1).
-- 'admin' / 'it' are not business modules here, so IT never unlocks sales, finance or HR data through Sana.
CREATE OR REPLACE FUNCTION erp.sana_has(VARIADIC p_modules text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT erp.module_level('business') IS NOT NULL
      OR EXISTS (SELECT 1 FROM unnest(p_modules) m WHERE m NOT IN ('admin', 'it') AND erp.module_level(m) IS NOT NULL)
$$;
CREATE OR REPLACE FUNCTION erp.sana_denied(p_topic text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$ SELECT jsonb_build_object('denied', true, 'topic', p_topic) $$;

CREATE OR REPLACE FUNCTION erp._sana_today() RETURNS date LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT (now() AT TIME ZONE 'Asia/Dubai')::date
$$;

-- Which document kinds a user may ask about (same split as the modules: sales, purchasing, inventory).
CREATE OR REPLACE FUNCTION erp.sana_doc_allowed(p_kind text) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT CASE
    WHEN p_kind IN ('sales_quotation','sales_order','delivery','sales_return','ar_down_payment','ar_invoice','ar_credit_note') THEN erp.sana_has('sales','finance')
    WHEN p_kind IN ('purchase_request','purchase_quotation','purchase_order','goods_receipt_po','goods_return','ap_down_payment','ap_invoice','ap_credit_note') THEN erp.sana_has('purchase','finance')
    WHEN p_kind IN ('transfer_request','inventory_transfer','goods_receipt','goods_issue') THEN erp.sana_has('inventory')
    ELSE false END
$$;

CREATE OR REPLACE FUNCTION erp.sana_doc_link(p_kind text, p_company text, p_entry integer) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$ SELECT '/docs/' || p_kind || '/' || p_company || '/' || p_entry $$;

-- The number people see: the Southfield number (SO-26-00042) when there is one, else SAP's DocNum.
CREATE OR REPLACE FUNCTION erp._sana_doc_no(p_company varchar, p_obj integer, p_entry integer, p_num integer) RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT w.doc_no FROM erp.doc_workflow w WHERE w.company_code = p_company AND w.obj_type = p_obj AND w.doc_entry = p_entry), p_num::text)
$$;

-- ============ 4. Tools (all read only, all SECURITY INVOKER) ============

-- Who is asking, and what Sana may talk to them about.
CREATE OR REPLACE FUNCTION erp.sana_whoami() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN u.user_id IS NULL THEN jsonb_build_object('profile', false) ELSE jsonb_build_object(
    'profile', true,
    'name', u.display_name,
    'position', p.name,
    'modules', (SELECT coalesce(jsonb_agg(m ORDER BY m), '[]') FROM unnest(ARRAY['admin','it','finance','sales','purchase','bp','banking','inventory','production','service','hr','reports','business']) m WHERE erp.module_level(m) IS NOT NULL),
    'language', u.language,
    'home_company', u.company_code,
    'companies', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', c.company_code, 'name', c.legal_name, 'currency', c.currency) ORDER BY c.company_code), '[]')
                    FROM erp.company c WHERE erp.can_see(c.company_code)),
    'topics', jsonb_build_object(
      'sales', erp.sana_has('sales','finance'), 'purchasing', erp.sana_has('purchase','finance'), 'inventory', erp.sana_has('inventory'),
      'stock', erp.sana_has('inventory','sales','purchase'), 'partners', erp.sana_has('sales','purchase','finance','bp'),
      'receivables', erp.sana_has('sales','finance'), 'payables', erp.sana_has('purchase','finance'),
      'finance', erp.sana_has('finance'), 'banking', erp.sana_has('banking','finance'), 'hr', erp.sana_has('hr'),
      'cost_prices', erp.sana_has('finance','purchase','inventory'), 'commercial_terms', erp.sana_has('finance'),
      'approvals', true, 'own_employee_record', true))
  END
  FROM (SELECT 1) one
  LEFT JOIN erp.app_user u ON u.user_id = erp.current_user_id() AND u.active
  LEFT JOIN erp.position p ON p.position_code = u.position_code
$$;

-- Search partners, items and documents the user may see.
CREATE OR REPLACE FUNCTION erp.sana_find(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE q text := '%' || replace(replace(replace(left(btrim(coalesce(p_query, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        t text := btrim(coalesce(p_query, ''));
        out jsonb := '{}';
BEGIN
  IF length(t) < 2 THEN RETURN jsonb_build_object('error', 'Search text is too short'); END IF;
  IF erp.sana_has('sales','purchase','finance','bp') THEN
    out := out || jsonb_build_object('partners', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
      SELECT b.company_code AS company, b.card_code AS code, b.name, b.kind, '/bp/' || b.company_code || '/' || b.card_code AS link
        FROM erp.business_partner b
       WHERE (p_company IS NULL OR b.company_code = p_company) AND (b.card_code ILIKE q OR b.name ILIKE q OR b.foreign_name ILIKE q)
         AND (b.kind <> 'customer' OR erp.sana_has('sales','finance','bp')) AND (b.kind <> 'supplier' OR erp.sana_has('purchase','finance','bp'))
       ORDER BY b.name LIMIT 8) x));
  END IF;
  IF erp.sana_has('inventory','sales','purchase') THEN
    out := out || jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
      SELECT i.company_code AS company, i.item_code AS code, i.name, '/items/' || i.company_code || '/' || i.item_code AS link
        FROM erp.item i WHERE (p_company IS NULL OR i.company_code = p_company) AND (i.item_code ILIKE q OR i.name ILIKE q OR i.barcode ILIKE q)
       ORDER BY i.item_code LIMIT 8) x));
  END IF;
  out := out || jsonb_build_object('documents', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT d.company_code AS company, d.doc_kind AS kind, erp._sana_doc_no(d.company_code, d.obj_type, d.doc_entry, d.doc_num) AS number,
           d.card_name AS partner, d.doc_date AS date, d.status, d.total, d.currency, erp._doc_link(d.company_code, d.obj_type, d.doc_entry) AS link
      FROM erp.document d
      LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
     WHERE (p_company IS NULL OR d.company_code = p_company) AND erp.sana_doc_allowed(d.doc_kind)
       AND (d.doc_num::text = t OR w.doc_no ILIKE t OR d.card_name ILIKE q OR d.customer_ref ILIKE q)
     ORDER BY d.doc_date DESC LIMIT 8) x));
  RETURN out;
END $$;

-- One document with its lines. p_number = SAP DocNum or the Southfield number (SO-26-00042).
CREATE OR REPLACE FUNCTION erp.sana_document(p_kind text, p_number text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE d erp.document; w erp.doc_workflow; cost boolean := erp.sana_has('finance','purchase','inventory');
        n text := btrim(coalesce(p_number, ''));
BEGIN
  IF NOT erp.sana_doc_allowed(p_kind) THEN RETURN erp.sana_denied(p_kind); END IF;
  SELECT x.* INTO d FROM erp.document x
    LEFT JOIN erp.doc_workflow y ON y.company_code = x.company_code AND y.obj_type = x.obj_type AND y.doc_entry = x.doc_entry
   WHERE x.doc_kind = p_kind AND (x.doc_num::text = n OR y.doc_no ILIKE n) AND (p_company IS NULL OR x.company_code = p_company)
   ORDER BY x.doc_date DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = d.company_code AND obj_type = d.obj_type AND doc_entry = d.doc_entry;
  RETURN jsonb_build_object('found', true, 'company', d.company_code, 'kind', d.doc_kind, 'number', coalesce(w.doc_no, d.doc_num::text),
    'status', d.status, 'approval_state', w.state,
    'date', d.doc_date, 'due_date', d.due_date, 'partner_code', d.card_code, 'partner', d.card_name, 'reference', d.customer_ref,
    'currency', d.currency, 'total', d.total, 'vat', d.vat_total, 'paid', d.paid,
    'source', CASE d.source WHEN 'sap' THEN 'SAP Business One' WHEN 'sample' THEN 'Sample test data' ELSE 'Southfield' END,
    'link', erp._doc_link(d.company_code, d.obj_type, d.doc_entry),
    'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('line', l.line_num + 1, 'item', l.item_code, 'description', l.description,
                'quantity', l.quantity, 'open_quantity', l.open_qty, 'price', l.price, 'discount_pct', l.discount_pct, 'line_total', l.line_total,
                'warehouse', l.whs_code) || CASE WHEN cost THEN jsonb_build_object('cost', l.stock_price) ELSE '{}' END ORDER BY l.line_num), '[]')
              FROM (SELECT * FROM erp.document_line WHERE company_code = d.company_code AND obj_type = d.obj_type AND doc_entry = d.doc_entry ORDER BY line_num LIMIT 40) l));
END $$;

-- A list of documents with totals (e.g. "open sales orders this month").
CREATE OR REPLACE FUNCTION erp.sana_documents(p_kind text, p_status text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                              p_partner text DEFAULT NULL, p_company varchar DEFAULT NULL, p_limit integer DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_doc_allowed(p_kind) THEN RETURN erp.sana_denied(p_kind); END IF;
  RETURN (WITH f AS (
      SELECT * FROM erp.document d
       WHERE d.doc_kind = p_kind AND (p_company IS NULL OR d.company_code = p_company) AND (p_status IS NULL OR d.status = p_status)
         AND (p_from IS NULL OR d.doc_date >= p_from) AND (p_to IS NULL OR d.doc_date <= p_to)
         AND (p_partner IS NULL OR d.card_code ILIKE p_partner OR d.card_name ILIKE '%' || p_partner || '%'))
    SELECT jsonb_build_object('kind', p_kind, 'count', (SELECT count(*) FROM f), 'total', (SELECT coalesce(sum(total), 0) FROM f),
      'open_amount', (SELECT coalesce(sum(total - coalesce(paid, 0)), 0) FROM f),
      'list_link', '/docs/' || p_kind || CASE WHEN p_status IS NOT NULL THEN '?f_status=' || p_status ELSE '' END,
      'latest', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
         SELECT company_code AS company, erp._sana_doc_no(company_code, obj_type, doc_entry, doc_num) AS number, doc_date AS date,
                card_name AS partner, status, total, currency, erp._doc_link(company_code, obj_type, doc_entry) AS link
           FROM f ORDER BY doc_date DESC, doc_num DESC LIMIT least(greatest(coalesce(p_limit, 10), 1), 25)) x)));
END $$;

-- Sales overview for a period (invoices minus credit memos, top customers and items, open orders).
CREATE OR REPLACE FUNCTION erp.sana_sales_summary(p_from date, p_to date, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('sales','finance') THEN RETURN erp.sana_denied('sales'); END IF;
  RETURN (WITH s AS (
      SELECT d.*, CASE WHEN d.doc_kind = 'ar_credit_note' THEN -1 ELSE 1 END AS sg FROM erp.document d
       WHERE d.doc_kind IN ('ar_invoice','ar_credit_note') AND d.status <> 'cancelled'
         AND d.doc_date BETWEEN p_from AND p_to AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object('from', p_from, 'to', p_to,
      'net_sales', (SELECT coalesce(sum(sg * (total - coalesce(vat_total, 0))), 0) FROM s),
      'invoices', (SELECT count(*) FROM s WHERE sg = 1), 'credit_memos', (SELECT count(*) FROM s WHERE sg = -1),
      'top_customers', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS name, sum(sg * (total - coalesce(vat_total,0))) AS net
                          FROM s GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 5) x),
      'top_items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT l.item_code AS code, max(l.description) AS name, sum(s.sg * l.quantity) AS quantity, sum(s.sg * l.line_total) AS net
                      FROM s JOIN erp.document_line l ON l.company_code = s.company_code AND l.obj_type = s.obj_type AND l.doc_entry = s.doc_entry
                     GROUP BY l.item_code ORDER BY 4 DESC LIMIT 5) x),
      'open_orders', (SELECT jsonb_build_object('count', count(*), 'value', coalesce(sum(total), 0)) FROM erp.document
                       WHERE doc_kind = 'sales_order' AND status = 'open' AND (p_company IS NULL OR company_code = p_company)),
      'list_link', '/docs/ar_invoice'));
END $$;

-- Purchasing overview for a period (A/P invoices minus credit memos, top suppliers, open orders and requests).
CREATE OR REPLACE FUNCTION erp.sana_purchase_summary(p_from date, p_to date, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('purchase','finance') THEN RETURN erp.sana_denied('purchasing'); END IF;
  RETURN (WITH s AS (
      SELECT d.*, CASE WHEN d.doc_kind = 'ap_credit_note' THEN -1 ELSE 1 END AS sg FROM erp.document d
       WHERE d.doc_kind IN ('ap_invoice','ap_credit_note') AND d.status <> 'cancelled'
         AND d.doc_date BETWEEN p_from AND p_to AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object('from', p_from, 'to', p_to,
      'net_purchases', (SELECT coalesce(sum(sg * (total - coalesce(vat_total, 0))), 0) FROM s),
      'invoices', (SELECT count(*) FROM s WHERE sg = 1), 'credit_memos', (SELECT count(*) FROM s WHERE sg = -1),
      'top_suppliers', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS name, sum(sg * (total - coalesce(vat_total,0))) AS net
                          FROM s GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 5) x),
      'open_orders', (SELECT jsonb_build_object('count', count(*), 'value', coalesce(sum(total), 0)) FROM erp.document
                       WHERE doc_kind = 'purchase_order' AND status = 'open' AND (p_company IS NULL OR company_code = p_company)),
      'open_requests', (SELECT count(*) FROM erp.document
                       WHERE doc_kind = 'purchase_request' AND status = 'open' AND (p_company IS NULL OR company_code = p_company)),
      'list_link', '/docs/purchase_order?f_status=open'));
END $$;

-- Inventory overview: items in stock, items below their minimum, stock movements of the last 30 days, open transfer requests.
CREATE OR REPLACE FUNCTION erp.sana_inventory_summary(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('inventory') THEN RETURN erp.sana_denied('inventory'); END IF;
  RETURN jsonb_build_object(
    'items_in_stock', (SELECT count(DISTINCT (s.company_code, s.item_code)) FROM erp.stock_balance s WHERE s.on_hand > 0 AND (p_company IS NULL OR s.company_code = p_company)),
    'below_minimum', (SELECT count(*) FROM erp.stock_balance s WHERE s.min_stock > 0 AND s.on_hand < s.min_stock AND (p_company IS NULL OR s.company_code = p_company)),
    'warehouses', (SELECT count(DISTINCT (s.company_code, s.whs_code)) FROM erp.stock_balance s WHERE (p_company IS NULL OR s.company_code = p_company)),
    'last_30_days', (SELECT coalesce(jsonb_object_agg(k, n), '{}') FROM (SELECT doc_kind AS k, count(*) AS n FROM erp.document
                      WHERE doc_kind IN ('goods_receipt','goods_issue','inventory_transfer','goods_receipt_po','delivery') AND status <> 'cancelled'
                        AND doc_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company) GROUP BY 1) x),
    'open_transfer_requests', (SELECT count(*) FROM erp.document WHERE doc_kind = 'transfer_request' AND status = 'open' AND (p_company IS NULL OR company_code = p_company)),
    'list_link', '/inventory/stock');
END $$;

-- A customer or supplier: balance, credit and latest documents. Commercial terms only for finance/owner.
CREATE OR REPLACE FUNCTION erp.sana_partner(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE b erp.business_partner; t text := btrim(coalesce(p_query, ''));
BEGIN
  IF NOT erp.sana_has('sales','purchase','finance','bp') THEN RETURN erp.sana_denied('partners'); END IF;
  IF length(t) < 2 THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT * INTO b FROM erp.business_partner
   WHERE (p_company IS NULL OR company_code = p_company) AND (card_code ILIKE t OR name ILIKE '%' || t || '%')
     AND (kind <> 'customer' OR erp.sana_has('sales','finance','bp')) AND (kind <> 'supplier' OR erp.sana_has('purchase','finance','bp'))
   ORDER BY (card_code ILIKE t) DESC, name LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  RETURN jsonb_build_object('found', true, 'company', b.company_code, 'code', b.card_code, 'name', b.name, 'kind', b.kind, 'currency', b.currency,
      'balance', b.balance, 'credit_limit', b.credit_limit,
      'credit_left', CASE WHEN b.credit_limit > 0 THEN b.credit_limit - b.balance END,
      'phone', b.phone, 'email', b.email, 'city', b.city, 'country', b.country, 'active', b.active,
      'link', '/bp/' || b.company_code || '/' || b.card_code,
      'latest_documents', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
          SELECT d.doc_kind AS kind, erp._sana_doc_no(d.company_code, d.obj_type, d.doc_entry, d.doc_num) AS number, d.doc_date AS date, d.status, d.total,
                 erp._doc_link(d.company_code, d.obj_type, d.doc_entry) AS link
            FROM erp.document d WHERE d.company_code = b.company_code AND d.card_code = b.card_code AND erp.sana_doc_allowed(d.doc_kind)
           ORDER BY d.doc_date DESC LIMIT 6) x))
    || CASE WHEN erp.sana_has('finance') THEN jsonb_build_object('payment_terms', b.payment_terms, 'discount_terms', b.discount_terms,
            'incentive_terms', b.incentive_terms, 'rent_terms', b.rent_terms) ELSE '{}' END;
END $$;

-- Stock by warehouse for items matching a code, name or barcode. Cost only for finance, purchasing, inventory.
CREATE OR REPLACE FUNCTION erp.sana_stock(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE cost boolean := erp.sana_has('finance','purchase','inventory'); t text := btrim(coalesce(p_query, ''));
BEGIN
  IF NOT erp.sana_has('inventory','sales','purchase') THEN RETURN erp.sana_denied('inventory'); END IF;
  IF length(t) < 2 THEN RETURN jsonb_build_object('items', '[]'::jsonb, 'cost_visible', cost); END IF;
  RETURN jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT i.company_code AS company, i.item_code AS code, i.name, i.inventory_uom AS unit, '/items/' || i.company_code || '/' || i.item_code AS link,
           (SELECT coalesce(jsonb_agg(jsonb_build_object('warehouse', s.whs_code, 'on_hand', s.on_hand, 'committed', s.committed, 'ordered', s.on_order,
                    'available', s.on_hand - s.committed, 'below_minimum', s.min_stock > 0 AND s.on_hand < s.min_stock) ORDER BY s.whs_code), '[]')
              FROM erp.stock_balance s WHERE s.company_code = i.company_code AND s.item_code = i.item_code) AS warehouses,
           CASE WHEN cost THEN i.avg_cost END AS average_cost
      FROM erp.item i
     WHERE (p_company IS NULL OR i.company_code = p_company)
       AND (i.item_code ILIKE t OR i.name ILIKE '%' || t || '%' OR i.barcode = t)
     ORDER BY (i.item_code ILIKE t) DESC, i.item_code LIMIT 5) x), 'cost_visible', cost);
END $$;

-- Overdue customer invoices (aging).
CREATE OR REPLACE FUNCTION erp.sana_receivables(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('sales','finance') THEN RETURN erp.sana_denied('receivables'); END IF;
  RETURN (WITH o AS (
      SELECT d.*, total - coalesce(paid, 0) AS open_amt, current_date - due_date AS days FROM erp.document d
       WHERE d.doc_kind = 'ar_invoice' AND d.status = 'open' AND total > coalesce(paid, 0) AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object(
      'open_total', (SELECT coalesce(sum(open_amt), 0) FROM o),
      'not_due', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days <= 0),
      'd1_30', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 1 AND 30),
      'd31_60', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 31 AND 60),
      'd61_90', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 61 AND 90),
      'over_90', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days > 90),
      'top_overdue', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS customer, sum(open_amt) AS overdue, max(days) AS oldest_days
                        FROM o WHERE days > 0 GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 8) x),
      'list_link', '/docs/ar_invoice?f_status=open'));
END $$;

-- Open supplier invoices (aging), purchasing or finance.
CREATE OR REPLACE FUNCTION erp.sana_payables(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('purchase','finance') THEN RETURN erp.sana_denied('payables'); END IF;
  RETURN (WITH o AS (
      SELECT d.*, total - coalesce(paid, 0) AS open_amt, current_date - due_date AS days FROM erp.document d
       WHERE d.doc_kind = 'ap_invoice' AND d.status = 'open' AND total > coalesce(paid, 0) AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object(
      'open_total', (SELECT coalesce(sum(open_amt), 0) FROM o),
      'due_7_days', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN -7 AND 0),
      'overdue', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days > 0),
      'top_suppliers', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS supplier, sum(open_amt) AS open, max(days) AS oldest_days
                        FROM o GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 8) x),
      'list_link', '/docs/ap_invoice?f_status=open'));
END $$;

-- Finance overview: totals by account drawer (SAP balances + Southfield journals) and supplier invoices due. Finance only.
CREATE OR REPLACE FUNCTION erp.sana_finance_summary(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('finance') THEN RETURN erp.sana_denied('finance'); END IF;
  RETURN jsonb_build_object(
    'by_drawer', (SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM (
       SELECT CASE a.group_mask WHEN 1 THEN 'assets' WHEN 2 THEN 'liabilities' WHEN 3 THEN 'equity' WHEN 4 THEN 'revenue'
                                WHEN 5 THEN 'cost_of_sales' WHEN 6 THEN 'expenses' ELSE 'other' END AS k,
              sum(coalesce(a.balance_local, 0) + coalesce((SELECT sum(jl.debit - jl.credit) FROM erp.journal_line jl
                    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
                   WHERE jl.company_code = a.company_code AND jl.acct_code = a.acct_code AND je.source <> 'sap'), 0)) AS v
         FROM erp.account a WHERE a.postable AND (p_company IS NULL OR a.company_code = p_company) GROUP BY 1) a),
    'payables_due_7_days', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(total - coalesce(paid,0)), 0)) FROM erp.document
       WHERE doc_kind = 'ap_invoice' AND status = 'open' AND due_date <= current_date + 7 AND (p_company IS NULL OR company_code = p_company)),
    'journals_last_30_days', (SELECT count(*) FROM erp.journal_entry WHERE ref_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company)),
    'links', jsonb_build_array(jsonb_build_object('label', 'Chart of accounts', 'link', '/financials/accounts'),
                               jsonb_build_object('label', 'Journal entries', 'link', '/financials/journals')));
END $$;

-- Banking: house bank / cash balances (never the IBAN), payments of the last 30 days, payments waiting for approval.
CREATE OR REPLACE FUNCTION erp.sana_banking(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE c record; cp jsonb; accts jsonb := '[]';
BEGIN
  IF NOT erp.sana_has('banking','finance') THEN RETURN erp.sana_denied('banking'); END IF;
  FOR c IN SELECT company_code FROM erp.company WHERE erp.can_see(company_code) AND (p_company IS NULL OR company_code = p_company) ORDER BY 1 LOOP
    BEGIN
      cp := erp.cash_position(c.company_code);
      accts := accts || coalesce((SELECT jsonb_agg(jsonb_build_object('company', c.company_code, 'bank', a ->> 'bank_code', 'name', a ->> 'name',
                 'kind', a ->> 'kind', 'currency', coalesce(a ->> 'currency', cp ->> 'currency'), 'balance', (a ->> 'balance')::numeric,
                 'unmatched_statement_lines', (a ->> 'unmatched')::integer))
               FROM jsonb_array_elements(cp -> 'accounts') a), '[]');
    EXCEPTION WHEN insufficient_privilege OR raise_exception THEN NULL;   -- no Banking rights in this company: skip it
    END;
  END LOOP;
  RETURN jsonb_build_object(
    'accounts', accts,
    'payments_last_30_days', (SELECT jsonb_build_object(
        'incoming', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'I'), 'amount', coalesce(sum(total) FILTER (WHERE direction = 'I'), 0)),
        'outgoing', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'O'), 'amount', coalesce(sum(total) FILTER (WHERE direction = 'O'), 0)))
      FROM erp.payment_list WHERE NOT coalesce(cancelled, false) AND doc_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company)),
    'waiting_for_approval', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(total), 0)) FROM erp.payment_draft_list
       WHERE state = 'pending_approval' AND (p_company IS NULL OR company_code = p_company)),
    'links', jsonb_build_array(jsonb_build_object('label', 'Cash position', 'link', '/banking/cash-position'),
                               jsonb_build_object('label', 'Payment drafts', 'link', '/banking/payment-drafts')));
END $$;

-- Rule-based exceptions (Control Tower, incl. A11's rules), limited to the topics the role covers.
CREATE OR REPLACE FUNCTION erp.sana_alerts(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  RETURN (SELECT jsonb_build_object('alerts', coalesce(jsonb_agg(jsonb_build_object('check', c.check_code, 'severity', c.severity, 'company', c.company_code,
            'subject', c.title, 'detail', c.detail, 'amount', c.amount, 'link', c.link)), '[]'), 'link', '/control', 'kind', 'rules')
    FROM (SELECT * FROM erp.control_findings(p_company) LIMIT 300) c
   WHERE CASE c.check_code
           WHEN 'low_stock'         THEN erp.sana_has('inventory','sales','purchase')
           WHEN 'below_cost'        THEN erp.sana_has('finance','purchase','inventory')   -- its detail shows cost prices
           WHEN 'count_variance'    THEN erp.sana_has('inventory','finance')
           WHEN 'bank_change'       THEN erp.sana_has('banking','finance','purchase')
           WHEN 'price_increase'    THEN erp.sana_has('purchase','finance')
           WHEN 'duplicate_invoice' THEN erp.sana_has('purchase','finance')
           WHEN 'checkin_outside'   THEN erp.sana_has('hr')
           WHEN 'credit_limit'      THEN erp.sana_has('sales','finance')
           WHEN 'high_discount'     THEN erp.sana_has('sales','finance')
           ELSE erp.sana_has('finance') END);
EXCEPTION WHEN insufficient_privilege THEN
  RETURN jsonb_build_object('alerts', '[]'::jsonb, 'link', '/control', 'kind', 'rules');
END $$;

-- The asker's own employee record (basic, non-sensitive fields only).
CREATE OR REPLACE FUNCTION erp.sana_my_employee() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT jsonb_build_object('found', true, 'name', concat_ws(' ', e.first_name, e.last_name), 'job_title', e.job_title,
            'department', e.division, 'joined_on', e.joined_on, 'email', e.email,
            'manager', (SELECT concat_ws(' ', m.first_name, m.last_name) FROM erp.employee m WHERE m.company_code = e.company_code AND m.emp_id = e.manager_emp_id),
            'link', '/portal')
     FROM erp.app_user u JOIN erp.employee e ON e.company_code = u.company_code AND e.emp_id = u.emp_id
    WHERE u.user_id = erp.current_user_id()), jsonb_build_object('found', false))
$$;

-- HR: headcount and people by department or name (no salary, ID, passport or birth date ever).
CREATE OR REPLACE FUNCTION erp.sana_people(p_query text DEFAULT NULL, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE t text := nullif(btrim(coalesce(p_query, '')), '');
BEGIN
  IF NOT erp.sana_has('hr') THEN RETURN erp.sana_denied('hr'); END IF;
  RETURN jsonb_build_object(
    'headcount', (SELECT count(*) FROM erp.employee WHERE active AND (p_company IS NULL OR company_code = p_company)),
    'by_department', (SELECT coalesce(jsonb_object_agg(coalesce(division, '—'), n), '{}') FROM (SELECT division, count(*) n FROM erp.employee
                       WHERE active AND (p_company IS NULL OR company_code = p_company) GROUP BY division) x),
    'matches', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT concat_ws(' ', first_name, last_name) AS name, job_title, division AS department, joined_on,
                  '/hr/employees/' || company_code || '/' || emp_id AS link
                  FROM erp.employee WHERE active AND (p_company IS NULL OR company_code = p_company) AND t IS NOT NULL
                   AND (first_name ILIKE '%' || t || '%' OR last_name ILIKE '%' || t || '%' OR division ILIKE '%' || t || '%' OR job_title ILIKE '%' || t || '%')
                  ORDER BY last_name LIMIT 10) x),
    'list_link', '/hr/employees');
END $$;

-- Approvals waiting for me (any position; only the requests the user may decide, from the shared inbox).
CREATE OR REPLACE FUNCTION erp.sana_my_approvals() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE ib jsonb := erp.approval_inbox();
BEGIN
  RETURN jsonb_build_object('is_approver', coalesce((ib ->> 'is_approver')::boolean, false),
    'waiting_count', jsonb_array_length(coalesce(ib -> 'waiting', '[]')),
    'waiting', (SELECT coalesce(jsonb_agg(jsonb_build_object('company', w ->> 'company_code', 'kind', w ->> 'kind', 'number', w ->> 'doc_no',
                    'partner', w ->> 'card_name', 'total', (w ->> 'total')::numeric, 'currency', w ->> 'currency', 'template', w ->> 'template_name',
                    'requested_by', w ->> 'requested_by_name', 'requested_at', w ->> 'requested_at')), '[]')
                  FROM (SELECT w FROM jsonb_array_elements(coalesce(ib -> 'waiting', '[]')) w LIMIT 15) x),
    'sent_waiting', (SELECT count(*) FROM jsonb_array_elements(coalesce(ib -> 'sent', '[]')) s WHERE s ->> 'state' = 'pending_approval'),
    'list_link', '/approvals');
END $$;

-- ============ 5. Status, logging and limits (called by the Edge Function with the user's own token) ============
-- The company Sana works for: the one asked about when the user may see it, else the user's home company.
CREATE OR REPLACE FUNCTION erp._sana_company(p_company varchar) RETURNS varchar
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_company IS NOT NULL AND erp.can_see(p_company) THEN p_company
              ELSE (SELECT u.company_code FROM erp.app_user u WHERE u.user_id = erp.current_user_id()) END
$$;

-- Is Sana on for me here, what may I use (voice, languages) and how many questions are left today.
CREATE OR REPLACE FUNCTION erp.sana_status(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); co varchar; s erp.sana_settings; used integer;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RETURN jsonb_build_object('profile', false, 'enabled', false);
  END IF;
  co := erp._sana_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = co;
  SELECT coalesce(sum(questions), 0) INTO used FROM erp.sana_usage WHERE user_id = uid AND day = erp._sana_today();
  RETURN jsonb_build_object('profile', true, 'company', co,
    'enabled', coalesce(s.enabled, true), 'voice_enabled', coalesce(s.voice_enabled, true),
    'daily_limit', coalesce(s.daily_limit, 200), 'used', used,
    'languages', to_jsonb(coalesce(s.languages, '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[])));
END $$;

-- One question and its answer: conversation, both messages, usage counters and the audit row (tools, refused, mode, voice,
-- language, page context kind — never the question text). Returns the ids the panel needs for history and feedback.
CREATE OR REPLACE FUNCTION erp.sana_log(p_conversation uuid, p_company varchar, p_language text, p_question text, p_answer text,
                                        p_tools jsonb, p_sources jsonb, p_denied boolean, p_mode text, p_via text,
                                        p_context jsonb DEFAULT NULL, p_fallback boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); cid uuid := p_conversation; co varchar; s erp.sana_settings; used integer;
        mid bigint; qid bigint; ctx jsonb; v_via text := coalesce(p_via, 'text'); v_mode text := coalesce(p_mode, 'basic');
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NOT NULL AND NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', p_company USING ERRCODE = '42501';
  END IF;
  IF btrim(coalesce(p_question, '')) = '' THEN
    RAISE EXCEPTION 'Type or say a question first.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mode NOT IN ('ai', 'basic') OR v_via NOT IN ('text', 'voice') THEN
    RAISE EXCEPTION 'Mode must be ai or basic, and via text or voice.' USING ERRCODE = 'P0001';
  END IF;
  co := erp._sana_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = co;
  IF NOT coalesce(s.enabled, true) THEN
    RAISE EXCEPTION 'Sana is switched off for %. Ask your system admin.', co USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(sum(questions), 0) INTO used FROM erp.sana_usage WHERE user_id = uid AND day = erp._sana_today();
  IF used >= coalesce(s.daily_limit, 200) THEN
    RAISE EXCEPTION 'You''ve reached today''s limit of % questions. It resets at midnight.', coalesce(s.daily_limit, 200) USING ERRCODE = 'P0001';
  END IF;
  -- Page context: only the known keys, short strings (it is a hint; the tools still check every record).
  IF jsonb_typeof(p_context) = 'object' THEN
    SELECT nullif(jsonb_object_agg(key, left(p_context ->> key, 60)), '{}') INTO ctx FROM jsonb_object_keys(p_context) key
     WHERE key IN ('type', 'kind', 'company', 'number', 'code', 'label') AND jsonb_typeof(p_context -> key) IN ('string', 'number');
  END IF;
  IF cid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.sana_conversation WHERE conversation_id = cid AND user_id = uid) THEN
    INSERT INTO erp.sana_conversation (user_id, company_code, title, language) VALUES (uid, co, left(btrim(p_question), 80), p_language)
    RETURNING conversation_id INTO cid;
  ELSE
    UPDATE erp.sana_conversation SET last_at = now() WHERE conversation_id = cid;
  END IF;
  INSERT INTO erp.sana_message (conversation_id, role, content, via, language, context)
    VALUES (cid, 'user', left(p_question, 4000), v_via, p_language, ctx) RETURNING message_id INTO qid;
  INSERT INTO erp.sana_message (conversation_id, role, content, tools, sources, denied, mode, language, fallback)
    VALUES (cid, 'assistant', left(coalesce(p_answer, ''), 8000), coalesce(p_tools, '[]'), coalesce(p_sources, '[]'), coalesce(p_denied, false), v_mode,
            p_language, coalesce(p_fallback, false))
    RETURNING message_id INTO mid;
  INSERT INTO erp.sana_usage AS x (company_code, user_id, day, questions, refused, voice, ai, basic, fallback)
    VALUES (co, uid, erp._sana_today(), 1, CASE WHEN p_denied THEN 1 ELSE 0 END, CASE WHEN v_via = 'voice' THEN 1 ELSE 0 END,
            CASE WHEN v_mode = 'ai' THEN 1 ELSE 0 END, CASE WHEN v_mode = 'basic' THEN 1 ELSE 0 END, CASE WHEN p_fallback THEN 1 ELSE 0 END)
  ON CONFLICT (company_code, user_id, day) DO UPDATE SET questions = x.questions + 1, refused = x.refused + EXCLUDED.refused,
    voice = x.voice + EXCLUDED.voice, ai = x.ai + EXCLUDED.ai, basic = x.basic + EXCLUDED.basic, fallback = x.fallback + EXCLUDED.fallback;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', co, 'sana.ask', 'sana_conversation', cid::text,
            jsonb_build_object('user_id', uid,
              'tools', (SELECT coalesce(jsonb_agg(DISTINCT t ->> 'tool'), '[]') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_tools) = 'array' THEN p_tools ELSE '[]' END) t),
              'denied', coalesce(p_denied, false), 'mode', v_mode, 'fallback', coalesce(p_fallback, false), 'via', v_via, 'language', p_language,
              'context', ctx ->> 'type'));
  RETURN jsonb_build_object('conversation_id', cid, 'message_id', mid, 'question_id', qid);
END $$;

-- My conversations, newest first (title, company, dates). Nobody sees anyone else's.
CREATE OR REPLACE FUNCTION erp.sana_conversations(p_limit integer DEFAULT 30) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('conversation_id', c.conversation_id, 'title', c.title, 'company', c.company_code,
           'language', c.language, 'started_at', c.started_at, 'last_at', c.last_at,
           'messages', (SELECT count(*) FROM erp.sana_message m WHERE m.conversation_id = c.conversation_id)) ORDER BY c.last_at DESC), '[]')
    FROM (SELECT * FROM erp.sana_conversation WHERE user_id = erp.current_user_id() ORDER BY last_at DESC
           LIMIT least(greatest(coalesce(p_limit, 30), 1), 100)) c
$$;

-- The messages of one of my conversations (with my 👍/👎). Someone else's conversation gives the same answer as a missing one.
CREATE OR REPLACE FUNCTION erp.sana_messages(p_conversation uuid, p_limit integer DEFAULT 200) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE c erp.sana_conversation;
BEGIN
  SELECT * INTO c FROM erp.sana_conversation WHERE conversation_id = p_conversation AND user_id = erp.current_user_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Conversation not found.' USING ERRCODE = 'P0002'; END IF;
  RETURN jsonb_build_object('conversation_id', c.conversation_id, 'title', c.title, 'company', c.company_code,
    'messages', (SELECT coalesce(jsonb_agg(jsonb_build_object('message_id', m.message_id, 'role', m.role, 'content', m.content, 'sources', m.sources,
                   'denied', m.denied, 'mode', m.mode, 'via', m.via, 'language', m.language, 'fallback', m.fallback, 'created_at', m.created_at,
                   'feedback', f.value) ORDER BY m.message_id), '[]')
                 FROM (SELECT * FROM erp.sana_message WHERE conversation_id = c.conversation_id ORDER BY message_id DESC
                        LIMIT least(greatest(coalesce(p_limit, 200), 1), 500)) m
                 LEFT JOIN erp.sana_feedback f ON f.message_id = m.message_id));
END $$;

-- Delete one of my conversations (messages and feedback go with it). Audited without content. Usage counts stay.
CREATE OR REPLACE FUNCTION erp.sana_delete_conversation(p_conversation uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); c erp.sana_conversation; n integer;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  SELECT * INTO c FROM erp.sana_conversation WHERE conversation_id = p_conversation AND user_id = uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Conversation not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT count(*) INTO n FROM erp.sana_message WHERE conversation_id = c.conversation_id;
  DELETE FROM erp.sana_conversation WHERE conversation_id = c.conversation_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (uid::text, c.company_code, 'sana.delete_conversation', 'sana_conversation', c.conversation_id::text, jsonb_build_object('messages', n));
  RETURN jsonb_build_object('deleted', true, 'messages', n);
END $$;

-- 👍 (1) / 👎 (-1) on one of my answers; 0 or NULL takes it back. Optional short note.
CREATE OR REPLACE FUNCTION erp.sana_feedback_set(p_message bigint, p_value integer, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); m erp.sana_message; c erp.sana_conversation;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  SELECT * INTO m FROM erp.sana_message WHERE message_id = p_message;
  SELECT * INTO c FROM erp.sana_conversation WHERE conversation_id = m.conversation_id AND user_id = uid;
  IF m.message_id IS NULL OR c.conversation_id IS NULL OR m.role <> 'assistant' THEN
    RAISE EXCEPTION 'Answer not found.' USING ERRCODE = 'P0002';
  END IF;
  IF p_value IS NOT NULL AND p_value NOT IN (-1, 0, 1) THEN
    RAISE EXCEPTION 'Feedback is 1 (helpful) or -1 (not helpful).' USING ERRCODE = 'P0001';
  END IF;
  IF length(coalesce(p_note, '')) > 500 THEN
    RAISE EXCEPTION 'Keep the note under 500 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(p_value, 0) = 0 THEN
    DELETE FROM erp.sana_feedback WHERE message_id = m.message_id;
  ELSE
    INSERT INTO erp.sana_feedback (message_id, user_id, company_code, value, note) VALUES (m.message_id, uid, c.company_code, p_value, nullif(btrim(p_note), ''))
    ON CONFLICT (message_id) DO UPDATE SET value = EXCLUDED.value, note = EXCLUDED.note, at = now();
  END IF;
  RETURN jsonb_build_object('message_id', m.message_id, 'feedback', nullif(coalesce(p_value, 0), 0));
END $$;

-- ============ 6. Administration › Add-Ons › AI Assistant (Sana) ============
-- Settings plus usage, as counts only (never question text, never per-person content).
CREATE OR REPLACE FUNCTION erp.sana_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE s erp.sana_settings;
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = p_company;
  RETURN jsonb_build_object('company', p_company,
    'settings', jsonb_build_object('enabled', coalesce(s.enabled, true), 'voice_enabled', coalesce(s.voice_enabled, true),
       'daily_limit', coalesce(s.daily_limit, 200), 'languages', to_jsonb(coalesce(s.languages, '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[])),
       'saved', s.company_code IS NOT NULL, 'updated_at', s.updated_at, 'updated_by', erp._adm_name(s.updated_by)),
    'all_languages', to_jsonb('{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[]),
    'can_edit', erp.can_write('admin'),
    'usage', jsonb_build_object(
      'days', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', day, 'questions', q, 'refused', r, 'voice', v, 'ai', a, 'basic', b, 'users', n) ORDER BY day DESC), '[]')
                 FROM (SELECT day, sum(questions) q, sum(refused) r, sum(voice) v, sum(ai) a, sum(basic) b, count(DISTINCT user_id) n
                         FROM erp.sana_usage WHERE company_code = p_company AND day > erp._sana_today() - 30 GROUP BY day) d),
      'total_30_days', (SELECT jsonb_build_object('questions', coalesce(sum(questions), 0), 'refused', coalesce(sum(refused), 0),
                          'voice', coalesce(sum(voice), 0), 'ai', coalesce(sum(ai), 0), 'basic', coalesce(sum(basic), 0),
                          'fallback', coalesce(sum(fallback), 0), 'users', count(DISTINCT user_id))
                          FROM erp.sana_usage WHERE company_code = p_company AND day > erp._sana_today() - 30),
      'feedback', (SELECT jsonb_build_object('up', count(*) FILTER (WHERE value = 1), 'down', count(*) FILTER (WHERE value = -1))
                     FROM erp.sana_feedback WHERE company_code = p_company AND at > now() - interval '30 days')));
END $$;

CREATE OR REPLACE FUNCTION erp.sana_settings_save(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._adm_guard(true); old erp.sana_settings; k text;
        v_on boolean; v_voice boolean; v_lim integer; v_langs text[];
        all_langs text[] := '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}';
BEGIN
  PERFORM erp._adm_company(p_company);
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the settings.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k ~* '(key|secret|token|password|credential)' THEN
      RAISE EXCEPTION 'API keys are never stored in the database. IT sets the Supabase secret ANTHROPIC_API_KEY; only the sana server function reads it.'
        USING ERRCODE = 'P0001';
    END IF;
    IF k NOT IN ('enabled', 'voice_enabled', 'daily_limit', 'languages') THEN
      RAISE EXCEPTION 'Unknown Sana setting %.', k USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  SELECT * INTO old FROM erp.sana_settings WHERE company_code = p_company FOR UPDATE;
  BEGIN
    v_on    := CASE WHEN p ? 'enabled' THEN (p ->> 'enabled')::boolean ELSE coalesce(old.enabled, true) END;
    v_voice := CASE WHEN p ? 'voice_enabled' THEN (p ->> 'voice_enabled')::boolean ELSE coalesce(old.voice_enabled, true) END;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Sana on/off and voice on/off must be yes or no.' USING ERRCODE = 'P0001';
  END;
  IF v_on IS NULL OR v_voice IS NULL THEN
    RAISE EXCEPTION 'Sana on/off and voice on/off must be yes or no.' USING ERRCODE = 'P0001';
  END IF;
  IF p ? 'daily_limit' THEN
    IF coalesce(p ->> 'daily_limit', '') !~ '^\d{1,4}$' OR (p ->> 'daily_limit')::integer > 5000 THEN
      RAISE EXCEPTION 'Enter a daily limit from 0 to 5,000 questions per person.' USING ERRCODE = 'P0001';
    END IF;
    v_lim := (p ->> 'daily_limit')::integer;
  ELSE
    v_lim := coalesce(old.daily_limit, 200);
  END IF;
  IF p ? 'languages' THEN
    IF jsonb_typeof(p -> 'languages') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Choose at least one language.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT l ORDER BY l) INTO v_langs FROM jsonb_array_elements_text(p -> 'languages') l;
    IF v_langs IS NULL THEN
      RAISE EXCEPTION 'Choose at least one language.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_langs <@ all_langs THEN
      RAISE EXCEPTION 'Sana supports these languages: en, ar, hi, ur, ml, ta, bn, tl, zh, fr, ru.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(l ORDER BY array_position(all_langs, l)) INTO v_langs FROM unnest(v_langs) l;
  ELSE
    v_langs := coalesce(old.languages, all_langs);
  END IF;
  INSERT INTO erp.sana_settings (company_code, enabled, voice_enabled, daily_limit, languages, updated_by, updated_at)
  VALUES (p_company, v_on, v_voice, v_lim, v_langs, me.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET enabled = EXCLUDED.enabled, voice_enabled = EXCLUDED.voice_enabled, daily_limit = EXCLUDED.daily_limit,
    languages = EXCLUDED.languages, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'sana_settings_save', 'sana_settings', p_company,
          jsonb_build_object('from', CASE WHEN old.company_code IS NULL THEN NULL ELSE jsonb_build_object('enabled', old.enabled, 'voice_enabled', old.voice_enabled,
                               'daily_limit', old.daily_limit, 'languages', old.languages) END,
                             'to', jsonb_build_object('enabled', v_on, 'voice_enabled', v_voice, 'daily_limit', v_lim, 'languages', v_langs)));
  RETURN jsonb_build_object('company', p_company, 'enabled', v_on, 'voice_enabled', v_voice, 'daily_limit', v_lim, 'languages', to_jsonb(v_langs));
END $$;

-- ============ 7. System health (A14): copied from 35 + 36_sana.sql ============
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save'), ('31_approvals.sql', 'approval_template_save'),
    ('32_gl_setup.sql', 'gl_setup'),
    ('33_multicurrency.sql', 'currency_rate'),
    ('34_open_items.sql', 'fx_revaluation_post'),
    ('35_final_items.sql', 'conversion_diff_post'),
    ('36_sana.sql', 'sana_settings_save')
  ) AS v(file_name, object)
$$;
-- U0+S1: + 36_sana.sql (marker sana_settings_save).

-- ============ 8. Grants ============
REVOKE ALL ON FUNCTION erp.sana_whoami(), erp.sana_find(text, varchar), erp.sana_document(text, text, varchar),
  erp.sana_documents(text, text, date, date, text, varchar, integer), erp.sana_sales_summary(date, date, varchar),
  erp.sana_purchase_summary(date, date, varchar), erp.sana_inventory_summary(varchar), erp.sana_partner(text, varchar),
  erp.sana_stock(text, varchar), erp.sana_receivables(varchar), erp.sana_payables(varchar), erp.sana_finance_summary(varchar),
  erp.sana_banking(varchar), erp.sana_alerts(varchar), erp.sana_my_employee(), erp.sana_people(text, varchar), erp.sana_my_approvals(),
  erp.sana_status(varchar), erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text, jsonb, boolean),
  erp.sana_conversations(integer), erp.sana_messages(uuid, integer), erp.sana_delete_conversation(uuid), erp.sana_feedback_set(bigint, integer, text),
  erp.sana_setup(varchar), erp.sana_settings_save(varchar, jsonb),
  erp.sana_has(text[]), erp.sana_denied(text), erp.sana_doc_allowed(text), erp.sana_doc_link(text, text, integer), erp._sana_doc_no(varchar, integer, integer, integer),
  erp._sana_today(), erp._sana_company(varchar)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_whoami(), erp.sana_find(text, varchar), erp.sana_document(text, text, varchar),
  erp.sana_documents(text, text, date, date, text, varchar, integer), erp.sana_sales_summary(date, date, varchar),
  erp.sana_purchase_summary(date, date, varchar), erp.sana_inventory_summary(varchar), erp.sana_partner(text, varchar),
  erp.sana_stock(text, varchar), erp.sana_receivables(varchar), erp.sana_payables(varchar), erp.sana_finance_summary(varchar),
  erp.sana_banking(varchar), erp.sana_alerts(varchar), erp.sana_my_employee(), erp.sana_people(text, varchar), erp.sana_my_approvals(),
  erp.sana_status(varchar), erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text, jsonb, boolean),
  erp.sana_conversations(integer), erp.sana_messages(uuid, integer), erp.sana_delete_conversation(uuid), erp.sana_feedback_set(bigint, integer, text),
  erp.sana_setup(varchar), erp.sana_settings_save(varchar, jsonb),
  erp.sana_has(text[]), erp.sana_denied(text), erp.sana_doc_allowed(text), erp.sana_doc_link(text, text, integer), erp._sana_doc_no(varchar, integer, integer, integer),
  erp._sana_today()
  TO authenticated;
-- _sana_company is SECURITY DEFINER and internal: only sana_status / sana_log (owner rights) call it.
REVOKE ALL ON FUNCTION erp._sana_company(varchar) FROM authenticated;

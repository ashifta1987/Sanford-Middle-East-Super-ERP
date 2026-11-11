-- 15_sana.sql · SANA, the Southfield AI Neural Assistant: conversation log, settings and the read-only "tools" it may call.
--
-- How role limits are enforced (three layers, each enough on its own for the data it covers):
--   1. Every tool below is SECURITY INVOKER: it runs as the signed-in user, so the row-level rules in 12_erp_security.sql
--      (company access, HR privacy) apply to every row it reads.
--   2. Every tool checks the user's position modules itself (erp.sana_has) and returns {"denied": true} instead of data when
--      the role does not cover the topic. This is stricter than the current table policies (see docs/sana-assistant.md).
--   3. The Edge Function only offers the model the tools the user's modules allow, and the model is told to refuse the rest.
-- Field-level limits: cost prices, commercial terms and partner bank data are returned only to roles that need them;
-- ID numbers, passport, birth date and salary are never returned by any Sana tool.
-- Nothing here writes business data. Safe to run again.

-- ---------- Settings (per company; edited by admins in Administration › Add-Ons › AI Assistant, A10) ----------
CREATE TABLE IF NOT EXISTS erp.sana_settings (
    company_code    varchar(8) PRIMARY KEY REFERENCES erp.company,
    enabled         boolean NOT NULL DEFAULT true,
    voice_enabled   boolean NOT NULL DEFAULT true,
    daily_limit     integer NOT NULL DEFAULT 200 CHECK (daily_limit BETWEEN 0 AND 5000),  -- questions per user per day
    languages       text[]  NOT NULL DEFAULT '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}',
    updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.sana_settings ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.sana_settings TO authenticated;
DROP POLICY IF EXISTS sana_settings_read ON erp.sana_settings;
CREATE POLICY sana_settings_read ON erp.sana_settings FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- ---------- Conversations (each person sees only their own) ----------
CREATE TABLE IF NOT EXISTS erp.sana_conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES erp.app_user,
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
    mode            text,                             -- 'ai' (model) or 'basic' (no model connected)
    via             text CHECK (via IN ('text', 'voice')),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sana_message_conv ON erp.sana_message (conversation_id, message_id);
CREATE INDEX IF NOT EXISTS sana_conversation_user ON erp.sana_conversation (user_id, last_at DESC);
ALTER TABLE erp.sana_conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sana_message ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.sana_conversation, erp.sana_message TO authenticated;
DROP POLICY IF EXISTS sana_conv_own ON erp.sana_conversation;
CREATE POLICY sana_conv_own ON erp.sana_conversation FOR SELECT TO authenticated USING (user_id = erp.current_user_id());
DROP POLICY IF EXISTS sana_msg_own ON erp.sana_message;
CREATE POLICY sana_msg_own ON erp.sana_message FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.sana_conversation c WHERE c.conversation_id = sana_message.conversation_id AND c.user_id = erp.current_user_id()));

-- ---------- Helpers ----------
-- Owner/MD ('business') may ask about everything; everyone else only about their position's modules.
-- Note: unlike the screens, 'admin'/'it' do NOT unlock business data in Sana. IT runs the system; it does not read sales or finance.
CREATE OR REPLACE FUNCTION erp.sana_has(VARIADIC p_modules text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT erp.has_module('business') OR EXISTS (SELECT 1 FROM unnest(p_modules) m WHERE erp.has_module(m))
$$;
CREATE OR REPLACE FUNCTION erp.sana_denied(p_topic text) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT jsonb_build_object('denied', true, 'topic', p_topic) $$;

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
LANGUAGE sql IMMUTABLE AS $$ SELECT '/docs/' || p_kind || '/' || p_company || '/' || p_entry $$;

-- ---------- Tools (all read only) ----------

-- Who is asking, and what Sana may talk to them about.
CREATE OR REPLACE FUNCTION erp.sana_whoami() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN u.user_id IS NULL THEN jsonb_build_object('profile', false) ELSE jsonb_build_object(
    'profile', true,
    'name', u.display_name,
    'position', p.name,
    'modules', p.module_access,
    'language', u.language,
    'home_company', u.company_code,
    'companies', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', c.company_code, 'name', c.legal_name, 'currency', c.currency) ORDER BY c.company_code), '[]')
                    FROM erp.company c WHERE erp.can_see(c.company_code)),
    'topics', jsonb_build_object(
      'sales', erp.sana_has('sales','finance'), 'purchasing', erp.sana_has('purchase','finance'), 'inventory', erp.sana_has('inventory','sales','purchase'),
      'partners', erp.sana_has('sales','purchase','finance'), 'finance', erp.sana_has('finance'), 'banking', erp.sana_has('finance','banking'),
      'hr', erp.sana_has('hr'), 'cost_prices', erp.sana_has('finance','purchase','inventory'), 'own_employee_record', true))
  END
  FROM (SELECT 1) one
  LEFT JOIN erp.app_user u ON u.user_id = erp.current_user_id() AND u.active
  LEFT JOIN erp.position p ON p.position_code = u.position_code
$$;

-- Search partners, items and documents the user may see.
CREATE OR REPLACE FUNCTION erp.sana_find(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE q text := '%' || replace(replace(left(trim(coalesce(p_query, '')), 80), '%', ''), '_', '\_') || '%';
        n integer := CASE WHEN trim(coalesce(p_query,'')) ~ '^\d{1,9}$' THEN trim(p_query)::integer END;
        out jsonb := '{}';
BEGIN
  IF length(trim(coalesce(p_query, ''))) < 2 THEN RETURN jsonb_build_object('error', 'Search text is too short'); END IF;
  IF erp.sana_has('sales','purchase','finance') THEN
    out := out || jsonb_build_object('partners', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
      SELECT b.company_code AS company, b.card_code AS code, b.name, b.kind, '/bp/' || b.company_code || '/' || b.card_code AS link
        FROM erp.business_partner b
       WHERE (p_company IS NULL OR b.company_code = p_company) AND (b.card_code ILIKE q OR b.name ILIKE q OR b.foreign_name ILIKE q)
         AND (b.kind <> 'customer' OR erp.sana_has('sales','finance')) AND (b.kind <> 'supplier' OR erp.sana_has('purchase','finance'))
       ORDER BY b.name LIMIT 8) x));
  END IF;
  IF erp.sana_has('inventory','sales','purchase') THEN
    out := out || jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
      SELECT i.company_code AS company, i.item_code AS code, i.name, '/items/' || i.company_code || '/' || i.item_code AS link
        FROM erp.item i WHERE (p_company IS NULL OR i.company_code = p_company) AND (i.item_code ILIKE q OR i.name ILIKE q OR i.barcode ILIKE q)
       ORDER BY i.item_code LIMIT 8) x));
  END IF;
  out := out || jsonb_build_object('documents', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT d.company_code AS company, d.doc_kind AS kind, d.doc_num AS number, d.card_name AS partner, d.doc_date AS date, d.status, d.total, d.currency,
           erp.sana_doc_link(d.doc_kind, d.company_code, d.doc_entry) AS link
      FROM erp.document d
     WHERE (p_company IS NULL OR d.company_code = p_company) AND erp.sana_doc_allowed(d.doc_kind)
       AND (d.doc_num = n OR d.card_name ILIKE q OR d.customer_ref ILIKE q)
     ORDER BY d.doc_date DESC LIMIT 8) x));
  RETURN out;
END $$;

-- One document with its lines.
CREATE OR REPLACE FUNCTION erp.sana_document(p_kind text, p_number integer, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE d erp.document; cost boolean := erp.sana_has('finance','purchase','inventory');
BEGIN
  IF NOT erp.sana_doc_allowed(p_kind) THEN RETURN erp.sana_denied(p_kind); END IF;
  SELECT * INTO d FROM erp.document WHERE doc_kind = p_kind AND doc_num = p_number AND (p_company IS NULL OR company_code = p_company)
   ORDER BY doc_date DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  RETURN jsonb_build_object('found', true, 'company', d.company_code, 'kind', d.doc_kind, 'number', d.doc_num, 'status', d.status,
    'date', d.doc_date, 'due_date', d.due_date, 'partner_code', d.card_code, 'partner', d.card_name, 'reference', d.customer_ref,
    'currency', d.currency, 'total', d.total, 'vat', d.vat_total, 'paid', d.paid, 'source', d.source,
    'link', erp.sana_doc_link(d.doc_kind, d.company_code, d.doc_entry),
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
         SELECT company_code AS company, doc_num AS number, doc_date AS date, card_name AS partner, status, total, currency,
                erp.sana_doc_link(doc_kind, company_code, doc_entry) AS link
           FROM f ORDER BY doc_date DESC, doc_num DESC LIMIT least(greatest(coalesce(p_limit, 10), 1), 25)) x)));
END $$;

-- Sales overview for a period (invoices minus credit memos, top customers and items).
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

-- A customer or supplier: balance, credit and latest documents. Commercial terms only for finance/owner.
CREATE OR REPLACE FUNCTION erp.sana_partner(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE b erp.business_partner;
BEGIN
  IF NOT erp.sana_has('sales','purchase','finance') THEN RETURN erp.sana_denied('partners'); END IF;
  SELECT * INTO b FROM erp.business_partner
   WHERE (p_company IS NULL OR company_code = p_company) AND (card_code ILIKE p_query OR name ILIKE '%' || p_query || '%')
     AND (kind <> 'customer' OR erp.sana_has('sales','finance')) AND (kind <> 'supplier' OR erp.sana_has('purchase','finance'))
   ORDER BY (card_code ILIKE p_query) DESC, name LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  RETURN jsonb_build_object('found', true, 'company', b.company_code, 'code', b.card_code, 'name', b.name, 'kind', b.kind, 'currency', b.currency,
      'balance', b.balance, 'credit_limit', b.credit_limit,
      'credit_left', CASE WHEN b.credit_limit > 0 THEN b.credit_limit - b.balance END,
      'phone', b.phone, 'email', b.email, 'city', b.city, 'country', b.country, 'active', b.active,
      'link', '/bp/' || b.company_code || '/' || b.card_code,
      'latest_documents', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
          SELECT d.doc_kind AS kind, d.doc_num AS number, d.doc_date AS date, d.status, d.total, erp.sana_doc_link(d.doc_kind, d.company_code, d.doc_entry) AS link
            FROM erp.document d WHERE d.company_code = b.company_code AND d.card_code = b.card_code AND erp.sana_doc_allowed(d.doc_kind)
           ORDER BY d.doc_date DESC LIMIT 6) x))
    || CASE WHEN erp.sana_has('finance') THEN jsonb_build_object('payment_terms', b.payment_terms, 'discount_terms', b.discount_terms,
            'incentive_terms', b.incentive_terms, 'rent_terms', b.rent_terms) ELSE '{}' END;
END $$;

-- Stock by warehouse for items matching a code, name or barcode. Cost only for finance, purchasing, inventory.
CREATE OR REPLACE FUNCTION erp.sana_stock(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE cost boolean := erp.sana_has('finance','purchase','inventory');
BEGIN
  IF NOT erp.sana_has('inventory','sales','purchase') THEN RETURN erp.sana_denied('inventory'); END IF;
  RETURN jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT i.company_code AS company, i.item_code AS code, i.name, i.inventory_uom AS unit, '/items/' || i.company_code || '/' || i.item_code AS link,
           (SELECT coalesce(jsonb_agg(jsonb_build_object('warehouse', s.whs_code, 'on_hand', s.on_hand, 'committed', s.committed, 'ordered', s.on_order,
                    'available', s.on_hand - s.committed + s.on_order, 'below_minimum', s.min_stock > 0 AND s.on_hand < s.min_stock) ORDER BY s.whs_code), '[]')
              FROM erp.stock_balance s WHERE s.company_code = i.company_code AND s.item_code = i.item_code) AS warehouses,
           CASE WHEN cost THEN i.avg_cost END AS average_cost
      FROM erp.item i
     WHERE (p_company IS NULL OR i.company_code = p_company)
       AND (i.item_code ILIKE p_query OR i.name ILIKE '%' || p_query || '%' OR i.barcode = p_query)
     ORDER BY (i.item_code ILIKE p_query) DESC, i.item_code LIMIT 5) x), 'cost_visible', cost);
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

-- Finance overview: totals by account drawer and supplier invoices due. Finance only.
CREATE OR REPLACE FUNCTION erp.sana_finance_summary(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('finance') THEN RETURN erp.sana_denied('finance'); END IF;
  RETURN jsonb_build_object(
    'by_drawer', (SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM (
       SELECT CASE group_mask WHEN 1 THEN 'assets' WHEN 2 THEN 'liabilities' WHEN 3 THEN 'equity' WHEN 4 THEN 'revenue'
                              WHEN 5 THEN 'cost_of_sales' WHEN 6 THEN 'expenses' ELSE 'other' END AS k, sum(balance_local) AS v
         FROM erp.account WHERE postable AND (p_company IS NULL OR company_code = p_company) GROUP BY 1) a),
    'payables_due_7_days', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(total - coalesce(paid,0)), 0)) FROM erp.document
       WHERE doc_kind = 'ap_invoice' AND status = 'open' AND due_date <= current_date + 7 AND (p_company IS NULL OR company_code = p_company)),
    'journals_last_30_days', (SELECT count(*) FROM erp.journal_entry WHERE ref_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company)),
    'links', jsonb_build_array('/financials/accounts', '/financials/journals'));
END $$;

-- Rule-based exceptions (Control Tower), limited to the topics the role covers.
CREATE OR REPLACE FUNCTION erp.sana_alerts(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('alerts', coalesce(jsonb_agg(jsonb_build_object('check', c.check_code, 'severity', c.severity, 'company', c.company_code,
            'subject', c.title, 'detail', c.detail, 'amount', c.amount)), '[]'), 'link', '/control')
    FROM (SELECT * FROM erp.control_checks(p_company) LIMIT 200) c
   WHERE CASE WHEN c.check_code = 'low_stock' THEN erp.sana_has('inventory','sales','purchase')
              WHEN c.check_code = 'below_cost' THEN erp.sana_has('finance','purchase','inventory')   -- its detail shows cost prices
              ELSE erp.sana_has('sales','finance') END
$$;

-- The asker's own employee record (basic, non-sensitive fields only).
CREATE OR REPLACE FUNCTION erp.sana_my_employee() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT jsonb_build_object('found', true, 'name', concat_ws(' ', e.first_name, e.last_name), 'job_title', e.job_title,
            'department', e.division, 'joined_on', e.joined_on, 'email', e.email,
            'manager', (SELECT concat_ws(' ', m.first_name, m.last_name) FROM erp.employee m WHERE m.company_code = e.company_code AND m.emp_id = e.manager_emp_id))
     FROM erp.app_user u JOIN erp.employee e ON e.company_code = u.company_code AND e.emp_id = u.emp_id
    WHERE u.user_id = erp.current_user_id()), jsonb_build_object('found', false))
$$;

-- HR: headcount and people by department or name (no salary, ID, passport or birth date ever).
CREATE OR REPLACE FUNCTION erp.sana_people(p_query text DEFAULT NULL, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('hr') THEN RETURN erp.sana_denied('hr'); END IF;
  RETURN jsonb_build_object(
    'headcount', (SELECT count(*) FROM erp.employee WHERE active AND (p_company IS NULL OR company_code = p_company)),
    'by_department', (SELECT coalesce(jsonb_object_agg(coalesce(division, '—'), n), '{}') FROM (SELECT division, count(*) n FROM erp.employee
                       WHERE active AND (p_company IS NULL OR company_code = p_company) GROUP BY division) x),
    'matches', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT concat_ws(' ', first_name, last_name) AS name, job_title, division AS department, joined_on
                  FROM erp.employee WHERE active AND (p_company IS NULL OR company_code = p_company) AND p_query IS NOT NULL
                   AND (first_name ILIKE '%' || p_query || '%' OR last_name ILIKE '%' || p_query || '%' OR division ILIKE '%' || p_query || '%' OR job_title ILIKE '%' || p_query || '%')
                  ORDER BY last_name LIMIT 10) x),
    'link', '/hr/employees');
END $$;

-- ---------- Logging and limits (called by the Edge Function with the user's own token) ----------
CREATE OR REPLACE FUNCTION erp.sana_usage_today() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('used', (SELECT count(*) FROM erp.sana_message m JOIN erp.sana_conversation c USING (conversation_id)
                                      WHERE c.user_id = erp.current_user_id() AND m.role = 'user' AND m.created_at >= date_trunc('day', now())),
         'limit', coalesce((SELECT s.daily_limit FROM erp.sana_settings s JOIN erp.app_user u ON u.company_code = s.company_code WHERE u.user_id = erp.current_user_id()), 200),
         'enabled', coalesce((SELECT s.enabled FROM erp.sana_settings s JOIN erp.app_user u ON u.company_code = s.company_code WHERE u.user_id = erp.current_user_id()), true))
$$;

CREATE OR REPLACE FUNCTION erp.sana_log(p_conversation uuid, p_company varchar, p_language text, p_question text, p_answer text,
                                        p_tools jsonb, p_sources jsonb, p_denied boolean, p_mode text, p_via text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); cid uuid := p_conversation;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501';
  END IF;
  IF cid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.sana_conversation WHERE conversation_id = cid AND user_id = uid) THEN
    INSERT INTO erp.sana_conversation (user_id, company_code, title, language) VALUES (uid, p_company, left(p_question, 80), p_language)
    RETURNING conversation_id INTO cid;
  ELSE
    UPDATE erp.sana_conversation SET last_at = now() WHERE conversation_id = cid;
  END IF;
  INSERT INTO erp.sana_message (conversation_id, role, content, via) VALUES (cid, 'user', left(p_question, 4000), p_via);
  INSERT INTO erp.sana_message (conversation_id, role, content, tools, sources, denied, mode)
    VALUES (cid, 'assistant', left(p_answer, 8000), coalesce(p_tools, '[]'), coalesce(p_sources, '[]'), coalesce(p_denied, false), p_mode);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana for ' || uid, p_company, 'sana.ask', 'sana_conversation', cid::text,
            jsonb_build_object('tools', coalesce(p_tools, '[]'), 'denied', coalesce(p_denied, false), 'mode', p_mode, 'via', p_via, 'language', p_language));
  RETURN cid;
END $$;

-- ---------- Grants ----------
REVOKE ALL ON FUNCTION erp.sana_whoami(), erp.sana_find(text, varchar), erp.sana_document(text, integer, varchar),
  erp.sana_documents(text, text, date, date, text, varchar, integer), erp.sana_sales_summary(date, date, varchar), erp.sana_partner(text, varchar),
  erp.sana_stock(text, varchar), erp.sana_receivables(varchar), erp.sana_finance_summary(varchar), erp.sana_alerts(varchar),
  erp.sana_my_employee(), erp.sana_people(text, varchar), erp.sana_usage_today(),
  erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_whoami(), erp.sana_find(text, varchar), erp.sana_document(text, integer, varchar),
  erp.sana_documents(text, text, date, date, text, varchar, integer), erp.sana_sales_summary(date, date, varchar), erp.sana_partner(text, varchar),
  erp.sana_stock(text, varchar), erp.sana_receivables(varchar), erp.sana_finance_summary(varchar), erp.sana_alerts(varchar),
  erp.sana_my_employee(), erp.sana_people(text, varchar), erp.sana_usage_today(),
  erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION erp.sana_has(text[]), erp.sana_denied(text), erp.sana_doc_allowed(text), erp.sana_doc_link(text, text, integer) TO authenticated;

-- Sana role matrix (S1 › role matrix, 36_sana.sql). LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Every erp.sana_* tool is called as each role; allowed topics return data, the rest return {"denied": true} and nothing else.
-- Test users (main's ids): qa.admin 1 (all modules incl. business), qa.sales 2, qa.nobody 3 (no profile), qa.finance 4,
-- qa.owner 5 (business), qa.salesread 6 (sales read-only), qa.bankread 9, qa.purchase 10, qa.stock 13, qa.stockread 15, qa.bp 16,
-- qa.hr 18, qa.hrread 19, qa.emp 20 (staff, E0006), qa.it 23 (IT only). A system admin without business modules is created
-- inside the transaction (rolled back) to prove admin/it never unlock business data.
-- Run on a FRESH rebuild. One transaction, rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE sr_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON sr_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO sr_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
CREATE FUNCTION pg_temp.denied(j jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((j ->> 'denied')::boolean, false) AND (SELECT count(*) FROM jsonb_object_keys(j)) = 2   -- {"denied", "topic"} and nothing else
$$;
-- every tool for one user: name → result
CREATE FUNCTION pg_temp.tools(n integer) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u uuid := pg_temp.u(n); so text; out jsonb := '{}';
BEGIN
  SELECT doc_num::text INTO so FROM erp.document WHERE company_code = 'ZZ99' AND doc_kind = 'sales_order' ORDER BY doc_num LIMIT 1;
  out := out || jsonb_build_object(
    'whoami', pg_temp.call(u, 'SELECT erp.sana_whoami()'),
    'find_s', pg_temp.call(u, 'SELECT erp.sana_find(''S000'', ''ZZ99'')'),
    'find_c', pg_temp.call(u, 'SELECT erp.sana_find(''C000'', ''ZZ99'')'),
    'so_doc', pg_temp.call(u, format('SELECT erp.sana_document(''sales_order'', %L, ''ZZ99'')', so)),
    'so_list', pg_temp.call(u, 'SELECT erp.sana_documents(''sales_order'', NULL, NULL, NULL, NULL, ''ZZ99'')'),
    'po_list', pg_temp.call(u, 'SELECT erp.sana_documents(''purchase_order'', NULL, NULL, NULL, NULL, ''ZZ99'')'),
    'tr_list', pg_temp.call(u, 'SELECT erp.sana_documents(''inventory_transfer'', NULL, NULL, NULL, NULL, ''ZZ99'')'),
    'sales', pg_temp.call(u, 'SELECT erp.sana_sales_summary(current_date - 730, current_date, ''ZZ99'')'),
    'purchase', pg_temp.call(u, 'SELECT erp.sana_purchase_summary(current_date - 730, current_date, ''ZZ99'')'),
    'inventory', pg_temp.call(u, 'SELECT erp.sana_inventory_summary(''ZZ99'')'),
    'customer', pg_temp.call(u, 'SELECT erp.sana_partner(''C0001'', ''ZZ99'')'),
    'supplier', pg_temp.call(u, 'SELECT erp.sana_partner(''S0001'', ''ZZ99'')'),
    'stock', pg_temp.call(u, 'SELECT erp.sana_stock(''SMP-1010'', ''ZZ99'')'),
    'ar', pg_temp.call(u, 'SELECT erp.sana_receivables(''ZZ99'')'),
    'ap', pg_temp.call(u, 'SELECT erp.sana_payables(''ZZ99'')'),
    'finance', pg_temp.call(u, 'SELECT erp.sana_finance_summary(''ZZ99'')'),
    'banking', pg_temp.call(u, 'SELECT erp.sana_banking(''ZZ99'')'),
    'alerts', pg_temp.call(u, 'SELECT erp.sana_alerts(''ZZ99'')'),
    'me', pg_temp.call(u, 'SELECT erp.sana_my_employee()'),
    'people', pg_temp.call(u, 'SELECT erp.sana_people(''a'', ''ZZ99'')'),
    'approvals', pg_temp.call(u, 'SELECT erp.sana_my_approvals()'));
  RETURN out;
END $$;
-- Allowed = data back (no error, not denied). Denied = exactly {"denied": true, "topic": …}.
CREATE FUNCTION pg_temp.matrix(p_role text, n integer, p_allowed text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb := pg_temp.tools(n); k text;
        all_tools text[] := ARRAY['so_doc','so_list','po_list','tr_list','sales','purchase','inventory','customer','supplier','stock','ar','ap','finance','banking','people'];
BEGIN
  FOREACH k IN ARRAY all_tools LOOP
    IF k = ANY (p_allowed) THEN
      PERFORM pg_temp.check((r -> k ->> 'error') IS NULL AND NOT coalesce((r -> k ->> 'denied')::boolean, false), p_role || ': ' || k || ' answered', left((r -> k)::text, 200));
    ELSIF k IN ('customer', 'supplier') AND (r -> 'whoami' -> 'topics' ->> 'partners')::boolean THEN
      -- partners of the other kind: the same answer as a missing partner (never confirms that it exists)
      PERFORM pg_temp.check(r -> k = '{"found": false}'::jsonb, p_role || ': ' || k || ' hidden ({"found": false}, never confirmed)', left((r -> k)::text, 200));
    ELSE
      PERFORM pg_temp.check(pg_temp.denied(r -> k), p_role || ': ' || k || ' refused with {"denied": true} only', left((r -> k)::text, 200));
    END IF;
  END LOOP;
  -- always available
  PERFORM pg_temp.check((r -> 'alerts' ->> 'error') IS NULL AND r -> 'alerts' ? 'alerts', p_role || ': alerts answered (rules)', left((r -> 'alerts')::text, 200));
  PERFORM pg_temp.check((r -> 'me' ->> 'error') IS NULL AND r -> 'me' ? 'found', p_role || ': own employee record answered', left((r -> 'me')::text, 200));
  PERFORM pg_temp.check((r -> 'approvals' ->> 'error') IS NULL AND r -> 'approvals' ? 'waiting', p_role || ': approvals waiting for me answered', left((r -> 'approvals')::text, 200));
END $$;

-- A system admin with Administration + IT full and no business module (rolled back with the test).
INSERT INTO erp.position (position_code, name, module_access) VALUES ('QA_SYSADM_T', 'QA · system admin (test only)', '{admin,it}') ON CONFLICT DO NOTHING;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active)
VALUES ('00000000-0000-4000-8000-000000000099', 'ZZ99', 'QA Sysadmin (test)', 'qa.sysadm.t@sample.test', 'QA_SYSADM_T', 'en', true) ON CONFLICT DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES ('00000000-0000-4000-8000-000000000099', 'ZZ99') ON CONFLICT DO NOTHING;

DO $$
DECLARE r jsonb; w jsonb;
BEGIN
  -- ---------- the matrix ----------
  PERFORM pg_temp.matrix('sales', 2, ARRAY['so_doc','so_list','sales','customer','stock','ar']);
  PERFORM pg_temp.matrix('sales read-only', 6, ARRAY['so_doc','so_list','sales','customer','stock','ar']);
  PERFORM pg_temp.matrix('finance', 4, ARRAY['so_doc','so_list','po_list','sales','purchase','customer','supplier','ar','ap','finance','banking']);
  PERFORM pg_temp.matrix('purchasing', 10, ARRAY['po_list','purchase','supplier','stock','ap']);
  PERFORM pg_temp.matrix('inventory', 13, ARRAY['tr_list','inventory','stock']);
  PERFORM pg_temp.matrix('inventory read-only', 15, ARRAY['tr_list','inventory','stock']);
  PERFORM pg_temp.matrix('banking read-only', 9, ARRAY['banking']);
  PERFORM pg_temp.matrix('business partners', 16, ARRAY['customer','supplier']);
  PERFORM pg_temp.matrix('hr', 18, ARRAY['people']);
  PERFORM pg_temp.matrix('hr read-only', 19, ARRAY['people']);
  PERFORM pg_temp.matrix('staff (portal only)', 20, ARRAY[]::text[]);
  PERFORM pg_temp.matrix('owner', 5, ARRAY['so_doc','so_list','po_list','tr_list','sales','purchase','inventory','customer','supplier','stock','ar','ap','finance','banking','people']);
  PERFORM pg_temp.matrix('IT support', 23, ARRAY[]::text[]);
  PERFORM pg_temp.matrix('system admin (admin + it, no business)', 99, ARRAY[]::text[]);

  -- ---------- whoami / topics ----------
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_whoami()');
  PERFORM pg_temp.check((r ->> 'profile')::boolean AND (r -> 'topics' ->> 'sales')::boolean AND NOT (r -> 'topics' ->> 'finance')::boolean
                        AND NOT (r -> 'topics' ->> 'hr')::boolean AND NOT (r -> 'topics' ->> 'cost_prices')::boolean, 'whoami: sales covers sales, not finance / HR / cost', r::text);
  r := pg_temp.call(pg_temp.u(6), 'SELECT erp.sana_whoami()');
  PERFORM pg_temp.check((r -> 'topics' ->> 'sales')::boolean AND r -> 'modules' ? 'sales', 'whoami: read-only sales still covers sales (A1 read level)', r::text);
  r := pg_temp.call(pg_temp.u(99), 'SELECT erp.sana_whoami()');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_each_text(r -> 'topics') t WHERE t.value = 'true' AND t.key NOT IN ('approvals', 'own_employee_record')),
                        'whoami: admin + it unlock no business topic', r::text);
  r := pg_temp.call(pg_temp.u(3), 'SELECT erp.sana_whoami()');
  PERFORM pg_temp.check(r = '{"profile": false}'::jsonb, 'whoami: no profile → {"profile": false} only', r::text);
  r := pg_temp.call(pg_temp.u(3), 'SELECT erp.sana_documents(''sales_order'')');
  PERFORM pg_temp.check(pg_temp.denied(r), 'no profile: documents refused', r::text);
  r := pg_temp.call(pg_temp.u(3), 'SELECT erp.sana_find(''SMP'')');
  PERFORM pg_temp.check(r = '{"documents": []}'::jsonb, 'no profile: find returns nothing', r::text);

  -- ---------- field limits ----------
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_stock(''SMP-1010'', ''ZZ99'')');
  PERFORM pg_temp.check(NOT (r ->> 'cost_visible')::boolean AND r -> 'items' -> 0 ->> 'average_cost' IS NULL AND jsonb_array_length(r -> 'items') > 0,
                        'sales: stock without cost', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(13), 'SELECT erp.sana_stock(''SMP-1010'', ''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'cost_visible')::boolean, 'inventory: stock with cost', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_document(''sales_order'', %L, ''ZZ99'')',
                    (SELECT doc_num::text FROM erp.document WHERE company_code = 'ZZ99' AND doc_kind = 'sales_order' ORDER BY doc_num LIMIT 1)));
  PERFORM pg_temp.check((r ->> 'found')::boolean AND NOT (r -> 'lines' -> 0 ? 'cost'), 'sales: document lines carry no cost', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_document(''sales_order'', %L, ''ZZ99'')',
                    (SELECT doc_num::text FROM erp.document WHERE company_code = 'ZZ99' AND doc_kind = 'sales_order' ORDER BY doc_num LIMIT 1)));
  PERFORM pg_temp.check(r -> 'lines' -> 0 ? 'cost', 'finance: document lines carry cost', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_partner(''C0001'', ''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'found')::boolean AND NOT (r ? 'discount_terms') AND NOT (r ? 'payment_terms'), 'sales: customer without commercial terms', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(4), 'SELECT erp.sana_partner(''C0001'', ''ZZ99'')');
  PERFORM pg_temp.check(r ? 'discount_terms', 'finance: customer with commercial terms', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_partner(''S0001'', ''ZZ99'')');
  PERFORM pg_temp.check(pg_temp.denied(r) IS FALSE AND r = '{"found": false}'::jsonb, 'sales: a supplier is "not found", never shown', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''S000'', ''ZZ99'')');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'partners') p WHERE p ->> 'kind' = 'supplier'), 'sales: suppliers not searchable', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(10), 'SELECT erp.sana_find(''C000'', ''ZZ99'')');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'partners') p WHERE p ->> 'kind' = 'customer'), 'purchasing: customers not searchable', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_alerts(''ZZ99'')');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'alerts') a WHERE a ->> 'check' IN ('below_cost', 'checkin_outside', 'duplicate_invoice', 'price_increase')),
                        'sales: no below-cost / HR / purchasing rule findings', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(23), 'SELECT erp.sana_alerts(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'alerts') = 0, 'IT: no rule findings at all', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(5), 'SELECT erp.sana_alerts(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'alerts') > 0 AND (r ->> 'kind') = 'rules', 'owner: rule findings, labelled as rules', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(18), 'SELECT erp.sana_people(''a'', ''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'headcount')::int > 0 AND r::text !~* '(passport|gov_id|emirates|birth|salary|iban|basic_pay|bank)', 'hr: people without ID, salary or bank fields', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(4), 'SELECT erp.sana_banking(''ZZ99'')');
  PERFORM pg_temp.check(r ? 'accounts' AND r::text !~* '(iban|account_no|swift|AE\d{2}\d{4})', 'finance: banking without IBAN or account numbers', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(9), 'SELECT erp.sana_banking(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'accounts') > 0, 'banking read-only: house bank balances', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(20), 'SELECT erp.sana_my_employee()');
  PERFORM pg_temp.check((r ->> 'found')::boolean AND r::text !~* '(passport|gov_id|birth|salary)', 'staff: own employee record, no sensitive fields', r::text);
  r := pg_temp.call(pg_temp.u(20), 'SELECT erp.sana_people(''a'', ''ZZ99'')');
  PERFORM pg_temp.check(pg_temp.denied(r), 'staff: other people refused', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''100'', ''ZZ99'')');
  w := pg_temp.call(pg_temp.u(23), 'SELECT erp.sana_find(''100'', ''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(w -> 'documents') = 0 AND NOT (w ? 'partners') AND NOT (w ? 'items'), 'IT: find returns no documents, partners or items', w::text);
  -- Southfield document numbers: a sales user can ask by the number on the screen (SO-…) as well as SAP's DocNum
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_document(''sales_order'', ''no-such-number'', ''ZZ99'')');
  PERFORM pg_temp.check(r = '{"found": false}'::jsonb, 'unknown number: found false', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_documents(''sales_order'', ''open'', NULL, NULL, NULL, ''ZZ99'', 3)');
  PERFORM pg_temp.check((r ->> 'list_link') = '/docs/sales_order?f_status=open' AND jsonb_array_length(r -> 'latest') <= 3
                        AND coalesce((r -> 'latest' -> 0 ->> 'link') LIKE '/docs/sales_order/ZZ99/%', true), 'documents: list and record links point at the real screens', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(5), 'SELECT erp.sana_my_approvals()');
  PERFORM pg_temp.check(r ? 'waiting_count' AND (r ->> 'list_link') = '/approvals', 'approvals: waiting count and inbox link', left(r::text, 200));
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM sr_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM sr_result;
ROLLBACK;

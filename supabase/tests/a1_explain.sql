-- A1 · performance check (LOCAL ONLY). Adds 1M synthetic sales orders inside a transaction, explains the list query
-- as the sales user, then rolls everything back.
BEGIN;
SET LOCAL erp.sync = 'on';
INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, source)
SELECT 'ZZ99', 17, 5000000 + g, 5000000 + g, 'sales_order', CASE WHEN g % 3 = 0 THEN 'closed' ELSE 'open' END,
       date '2020-01-01' + (g % 2400), 'C' || lpad((g % 500)::text, 4, '0'), 'Perf customer', 'AED', 'sample'
  FROM generate_series(1, 1000000) g;
ANALYZE erp.document;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT company_code, obj_type, doc_entry, doc_num, status, doc_date, card_name, total
  FROM erp.document
 WHERE company_code = 'ZZ99' AND obj_type = 17 AND status = 'open'
 ORDER BY doc_date DESC LIMIT 25;
EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT count(*) FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17;
RESET ROLE;
ROLLBACK;

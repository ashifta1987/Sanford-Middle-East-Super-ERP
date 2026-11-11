-- Sana role tests (local stack, sample company ZZ99). Each block runs as one test user; every line prints PASS or FAIL.
\set QUIET on
\pset tuples_only on
\pset format unaligned
CREATE OR REPLACE FUNCTION pg_temp.t(name text, ok boolean) RETURNS text LANGUAGE sql AS $$ SELECT CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END || name $$;

-- Sales only
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000002"}', true);
SELECT pg_temp.t('sales: whoami has a profile', (erp.sana_whoami()->>'profile')::boolean);
SELECT pg_temp.t('sales: topics say no finance, no hr', NOT (erp.sana_whoami()->'topics'->>'finance')::boolean AND NOT (erp.sana_whoami()->'topics'->>'hr')::boolean);
SELECT pg_temp.t('sales: can list sales orders', (erp.sana_documents('sales_order')->>'count')::int > 0);
SELECT pg_temp.t('sales: purchase orders denied', (erp.sana_documents('purchase_order')->>'denied')::boolean);
SELECT pg_temp.t('sales: finance summary denied', (erp.sana_finance_summary()->>'denied')::boolean);
SELECT pg_temp.t('sales: people (HR) denied', (erp.sana_people('a')->>'denied')::boolean);
SELECT pg_temp.t('sales: stock visible but no cost', (erp.sana_stock('SMP')->>'cost_visible')::boolean = false AND erp.sana_stock('SMP')->'items'->0->>'average_cost' IS NULL);
SELECT pg_temp.t('sales: document lines carry no cost', NOT (erp.sana_document('sales_order', (SELECT doc_num FROM erp.document WHERE doc_kind='sales_order' LIMIT 1))->'lines'->0 ? 'cost'));
SELECT pg_temp.t('sales: partner has no commercial terms', NOT (erp.sana_partner('C0001') ? 'discount_terms'));
SELECT pg_temp.t('sales: suppliers not searchable', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(erp.sana_find('S000')->'partners') p WHERE p->>'kind' = 'supplier'));
SELECT pg_temp.t('sales: no below-cost alerts (they show cost)', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(erp.sana_alerts()->'alerts') a WHERE a->>'check' = 'below_cost'));
SELECT pg_temp.t('sales: receivables allowed', erp.sana_receivables() ? 'open_total');
ROLLBACK;

-- Finance only
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000004"}', true);
SELECT pg_temp.t('finance: finance summary allowed', erp.sana_finance_summary() ? 'by_drawer');
SELECT pg_temp.t('finance: sales and purchase docs allowed', (erp.sana_documents('ap_invoice')->>'count') IS NOT NULL AND (erp.sana_documents('ar_invoice')->>'count') IS NOT NULL);
SELECT pg_temp.t('finance: inventory transfers denied', (erp.sana_documents('inventory_transfer')->>'denied')::boolean);
SELECT pg_temp.t('finance: stock denied', (erp.sana_stock('SMP')->>'denied')::boolean);
SELECT pg_temp.t('finance: partner terms visible', erp.sana_partner('C0001') ? 'discount_terms');
SELECT pg_temp.t('finance: HR denied', (erp.sana_people()->>'denied')::boolean);
ROLLBACK;

-- IT admin: runs the system, does not read business data through Sana
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000005"}', true);
SELECT pg_temp.t('it: sales orders denied', (erp.sana_documents('sales_order')->>'denied')::boolean);
SELECT pg_temp.t('it: finance denied', (erp.sana_finance_summary()->>'denied')::boolean);
SELECT pg_temp.t('it: find returns no documents', jsonb_array_length(erp.sana_find('100')->'documents') = 0 AND NOT (erp.sana_find('100') ? 'partners'));
ROLLBACK;

-- Owner / all modules
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001"}', true);
SELECT pg_temp.t('owner: HR headcount allowed', (erp.sana_people()->>'headcount')::int > 0);
SELECT pg_temp.t('owner: people never include ID or salary fields', NOT (erp.sana_people('a')::text ~* 'passport|gov_id|birth|salary'));
SELECT pg_temp.t('owner: cost visible', (erp.sana_stock('SMP')->>'cost_visible')::boolean);
SELECT pg_temp.t('owner: sales summary', (erp.sana_sales_summary(current_date - 365, current_date)->>'invoices')::int > 0);
SELECT pg_temp.t('owner: log creates a private conversation', erp.sana_log(NULL, 'ZZ99', 'en', 'test question', 'test answer', '[]', '[]', false, 'basic', 'text') IS NOT NULL);
ROLLBACK;

-- Signed in, no profile
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000003"}', true);
SELECT pg_temp.t('no profile: whoami says no profile', NOT (erp.sana_whoami()->>'profile')::boolean);
SELECT pg_temp.t('no profile: documents denied', (erp.sana_documents('sales_order')->>'denied')::boolean);
DO $$ BEGIN PERFORM erp.sana_log(NULL, 'ZZ99', 'en', 'q', 'a', '[]', '[]', false, 'basic', 'text'); RAISE NOTICE 'FAIL no profile: log refused';
   EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS no profile: log refused'; END $$;
ROLLBACK;

-- Conversations are private: sales cannot read the owner's conversation
BEGIN;
SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001"}', true);
SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'owner private question', 'answer', '[]', '[]', false, 'basic', 'text') \gset cid_
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000002"}', true);
SELECT pg_temp.t('privacy: sales sees none of the owner''s messages', (SELECT count(*) FROM erp.sana_message WHERE content = 'owner private question') = 0);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001"}', true);
SELECT pg_temp.t('privacy: owner sees own messages', (SELECT count(*) FROM erp.sana_message WHERE content = 'owner private question') = 1);
ROLLBACK;

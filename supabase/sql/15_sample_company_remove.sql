-- 15_sample_company_remove.sql · removes the fictional test company ZZ99 only
BEGIN;
-- Remove sample company ZZ99 and everything in it (children first). Real companies are never touched.
DELETE FROM erp.user_company WHERE company_code = 'ZZ99';
DELETE FROM erp.app_user WHERE company_code = 'ZZ99';
DELETE FROM erp.approval WHERE company_code = 'ZZ99';
SET LOCAL erp.sync = 'on';  -- posted journals are locked; this lets the sample ones be removed
DELETE FROM erp.journal_line WHERE company_code = 'ZZ99';
DELETE FROM erp.journal_entry WHERE company_code = 'ZZ99';
RESET erp.sync;
DELETE FROM erp.payment WHERE company_code = 'ZZ99';
DELETE FROM erp.document_line WHERE company_code = 'ZZ99';
DELETE FROM erp.document WHERE company_code = 'ZZ99';
DELETE FROM erp.stock_balance WHERE company_code = 'ZZ99';
DELETE FROM erp.item_price WHERE company_code = 'ZZ99';
DELETE FROM erp.price_list WHERE company_code = 'ZZ99';
DELETE FROM erp.item WHERE company_code = 'ZZ99';
DELETE FROM erp.item_group WHERE company_code = 'ZZ99';
DELETE FROM erp.business_partner WHERE company_code = 'ZZ99';
DELETE FROM erp.bp_group WHERE company_code = 'ZZ99';
DELETE FROM erp.payment_terms WHERE company_code = 'ZZ99';
DELETE FROM erp.salesperson WHERE company_code = 'ZZ99';
DELETE FROM erp.tax_code WHERE company_code = 'ZZ99';
DELETE FROM erp.account WHERE company_code = 'ZZ99';
DELETE FROM erp.employee WHERE company_code = 'ZZ99';
DELETE FROM erp.warehouse WHERE company_code = 'ZZ99';
DELETE FROM erp.branch WHERE company_code = 'ZZ99';
DELETE FROM erp.company WHERE company_code = 'ZZ99';
COMMIT;

-- Sanford ERP - sync from the raw SAP layer into the app layer. Generated from the real SAP column lists.
-- Run:  SELECT erp.sync_company('AE01');   then   SELECT * FROM erp.check_sync('AE01');
-- Every function is an upsert keyed on SAP codes, so it can run again after a re-load.

CREATE OR REPLACE FUNCTION erp.sync_branches(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.branch AS t (company_code, branch_id, name, foreign_name, tax_id, address, is_main, active)
  SELECT s.company_code AS company_code,
         s."BPLId" AS branch_id,
         s."BPLName" AS name,
         s."BPLFrName" AS foreign_name,
         s."TaxIdNum" AS tax_id,
         s."Address" AS address,
         (coalesce(s."MainBPL", 'N') = 'Y') AS is_main,
         (coalesce(s."Disabled", 'N') <> 'Y') AS active
    FROM sap."OBPL" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, branch_id) DO UPDATE SET name = EXCLUDED.name, foreign_name = EXCLUDED.foreign_name, tax_id = EXCLUDED.tax_id, address = EXCLUDED.address, is_main = EXCLUDED.is_main, active = EXCLUDED.active WHERE (t.name, t.foreign_name, t.tax_id, t.address, t.is_main, t.active) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.foreign_name, EXCLUDED.tax_id, EXCLUDED.address, EXCLUDED.is_main, EXCLUDED.active);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_accounts(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.account AS t (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local)
  SELECT s.company_code AS company_code,
         s."AcctCode" AS acct_code,
         s."FormatCode" AS format_code,
         s."AcctName" AS name,
         s."FatherNum" AS parent_code,
         s."Levels"::smallint AS level,
         (coalesce(s."Postable", 'N') = 'Y') AS postable,
         s."ActType" AS account_type,
         s."GroupMask"::smallint AS group_mask,
         s."ActCurr" AS currency,
         (coalesce(s."LocManTran", 'N') = 'Y') AS is_control,
         (coalesce(s."FrozenFor", 'N') = 'Y') AS frozen,
         s."CurrTotal" AS balance_local
    FROM sap."OACT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, acct_code) DO UPDATE SET format_code = EXCLUDED.format_code, name = EXCLUDED.name, parent_code = EXCLUDED.parent_code, level = EXCLUDED.level, postable = EXCLUDED.postable, account_type = EXCLUDED.account_type, group_mask = EXCLUDED.group_mask, currency = EXCLUDED.currency, is_control = EXCLUDED.is_control, frozen = EXCLUDED.frozen, balance_local = EXCLUDED.balance_local WHERE (t.format_code, t.name, t.parent_code, t.level, t.postable, t.account_type, t.group_mask, t.currency, t.is_control, t.frozen, t.balance_local) IS DISTINCT FROM (EXCLUDED.format_code, EXCLUDED.name, EXCLUDED.parent_code, EXCLUDED.level, EXCLUDED.postable, EXCLUDED.account_type, EXCLUDED.group_mask, EXCLUDED.currency, EXCLUDED.is_control, EXCLUDED.frozen, EXCLUDED.balance_local);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_cost_centres(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.cost_centre AS t (company_code, code, name, dimension, active)
  SELECT s.company_code AS company_code,
         s."PrcCode" AS code,
         coalesce(nullif(s."PrcName", ''), s."PrcCode") AS name,   -- SAP allows a cost centre without a name (AE05 ABUDHABI)
         s."DimCode"::smallint AS dimension,
         (coalesce(s."Active", 'Y') = 'Y') AS active
    FROM sap."OPRC" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, dimension = EXCLUDED.dimension, active = EXCLUDED.active WHERE (t.name, t.dimension, t.active) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.dimension, EXCLUDED.active);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_tax_codes(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.tax_code AS t (company_code, code, name, rate, category, active)
  SELECT s.company_code AS company_code,
         s."Code" AS code,
         s."Name" AS name,
         coalesce(s."Rate", 0) AS rate,   -- SAP allows a tax group without a rate (AE05 VATIn); reported by the worker
         s."Category" AS category,
         (coalesce(s."Inactive", 'N') <> 'Y') AS active
    FROM sap."OVTG" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, rate = EXCLUDED.rate, category = EXCLUDED.category, active = EXCLUDED.active WHERE (t.name, t.rate, t.category, t.active) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.rate, EXCLUDED.category, EXCLUDED.active);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_fx_rates(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.fx_rate AS t (company_code, rate_date, currency, rate)
  SELECT s.company_code AS company_code,
         s."RateDate"::date AS rate_date,
         s."Currency" AS currency,
         s."Rate" AS rate
    FROM sap."ORTT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, rate_date, currency) DO UPDATE SET rate = EXCLUDED.rate WHERE (t.rate) IS DISTINCT FROM (EXCLUDED.rate);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_salespeople(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.salesperson AS t (company_code, slp_code, name, email, mobile, commission_pct, active)
  SELECT s.company_code AS company_code,
         s."SlpCode" AS slp_code,
         s."SlpName" AS name,
         s."Email" AS email,
         s."Mobil" AS mobile,
         s."Commission" AS commission_pct,
         (coalesce(s."Active", 'Y') = 'Y') AS active
    FROM sap."OSLP" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, slp_code) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email, mobile = EXCLUDED.mobile, commission_pct = EXCLUDED.commission_pct, active = EXCLUDED.active WHERE (t.name, t.email, t.mobile, t.commission_pct, t.active) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.email, EXCLUDED.mobile, EXCLUDED.commission_pct, EXCLUDED.active);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payment_terms(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.payment_terms AS t (company_code, group_num, name, extra_days, extra_months)
  SELECT s.company_code AS company_code,
         s."GroupNum" AS group_num,
         s."PymntGroup" AS name,
         s."ExtraDays" AS extra_days,
         s."ExtraMonth" AS extra_months
    FROM sap."OCTG" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, group_num) DO UPDATE SET name = EXCLUDED.name, extra_days = EXCLUDED.extra_days, extra_months = EXCLUDED.extra_months WHERE (t.name, t.extra_days, t.extra_months) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.extra_days, EXCLUDED.extra_months);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_bp_groups(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.bp_group AS t (company_code, group_code, name, kind)
  SELECT s.company_code AS company_code,
         s."GroupCode" AS group_code,
         s."GroupName" AS name,
         s."GroupType" AS kind
    FROM sap."OCRG" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, group_code) DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind WHERE (t.name, t.kind) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.kind);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_business_partners(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.business_partner AS t (company_code, card_code, kind, name, foreign_name, group_code, bp_category, currency, credit_limit, balance, trn, phone, mobile, email, slp_code, price_list, payment_terms, region, city, province, country, territory, ic_partner_company, salesforce_id, inflow_target, outflow_target, rent_terms, incentive_terms, discount_terms, tpl_storage_rate, tpl_handling_fee, active, created_on, source)
  SELECT s.company_code AS company_code,
         s."CardCode" AS card_code,
         CASE s."CardType" WHEN 'S' THEN 'supplier' WHEN 'L' THEN 'lead' ELSE 'customer' END AS kind,
         coalesce(s."CardName", s."CardCode") AS name,
         s."CardFName" AS foreign_name,
         s."GroupCode" AS group_code,
         s."U_BP_Category" AS bp_category,
         s."Currency" AS currency,
         s."CreditLine" AS credit_limit,
         s."Balance" AS balance,
         s."LicTradNum" AS trn,
         s."Phone1" AS phone,
         s."Cellular" AS mobile,
         s."E_Mail" AS email,
         s."SlpCode" AS slp_code,
         s."ListNum" AS price_list,
         s."GroupNum" AS payment_terms,
         s."U_Region" AS region,
         coalesce(s."U_City", s."City") AS city,
         s."U_Province" AS province,
         coalesce(s."U_Country", s."Country") AS country,
         s."Territory" AS territory,
         left(s."U_CTX_ICPC", 8) AS ic_partner_company,
         s."U_SFID" AS salesforce_id,
         s."U_InflowTarget" AS inflow_target,
         s."U_OutflowTarget" AS outflow_target,
         s."U_Rent" AS rent_terms,
         s."U_Incentive" AS incentive_terms,
         s."U_Discount" AS discount_terms,
         s."U_TPL_StorageRate" AS tpl_storage_rate,
         s."U_TPL_HandlingFee" AS tpl_handling_fee,
         (NOT (coalesce(s."frozenFor", 'N') = 'Y' AND coalesce(s."frozenFrom"::date, DATE '1900-01-01') <= current_date AND coalesce(s."frozenTo"::date, DATE '9999-12-31') >= current_date) AND NOT (coalesce(s."validFor", 'N') = 'Y' AND (coalesce(s."validFrom"::date, DATE '1900-01-01') > current_date OR coalesce(s."validTo"::date, DATE '9999-12-31') < current_date))) AS active,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OCRD" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, card_code) DO UPDATE SET kind = EXCLUDED.kind, name = EXCLUDED.name, foreign_name = EXCLUDED.foreign_name, group_code = EXCLUDED.group_code, bp_category = EXCLUDED.bp_category, currency = EXCLUDED.currency, credit_limit = EXCLUDED.credit_limit, balance = EXCLUDED.balance, trn = EXCLUDED.trn, phone = EXCLUDED.phone, mobile = EXCLUDED.mobile, email = EXCLUDED.email, slp_code = EXCLUDED.slp_code, price_list = EXCLUDED.price_list, payment_terms = EXCLUDED.payment_terms, region = EXCLUDED.region, city = EXCLUDED.city, province = EXCLUDED.province, country = EXCLUDED.country, territory = EXCLUDED.territory, ic_partner_company = EXCLUDED.ic_partner_company, salesforce_id = EXCLUDED.salesforce_id, inflow_target = EXCLUDED.inflow_target, outflow_target = EXCLUDED.outflow_target, rent_terms = EXCLUDED.rent_terms, incentive_terms = EXCLUDED.incentive_terms, discount_terms = EXCLUDED.discount_terms, tpl_storage_rate = EXCLUDED.tpl_storage_rate, tpl_handling_fee = EXCLUDED.tpl_handling_fee, active = EXCLUDED.active, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.kind, t.name, t.foreign_name, t.group_code, t.bp_category, t.currency, t.credit_limit, t.balance, t.trn, t.phone, t.mobile, t.email, t.slp_code, t.price_list, t.payment_terms, t.region, t.city, t.province, t.country, t.territory, t.ic_partner_company, t.salesforce_id, t.inflow_target, t.outflow_target, t.rent_terms, t.incentive_terms, t.discount_terms, t.tpl_storage_rate, t.tpl_handling_fee, t.active, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.kind, EXCLUDED.name, EXCLUDED.foreign_name, EXCLUDED.group_code, EXCLUDED.bp_category, EXCLUDED.currency, EXCLUDED.credit_limit, EXCLUDED.balance, EXCLUDED.trn, EXCLUDED.phone, EXCLUDED.mobile, EXCLUDED.email, EXCLUDED.slp_code, EXCLUDED.price_list, EXCLUDED.payment_terms, EXCLUDED.region, EXCLUDED.city, EXCLUDED.province, EXCLUDED.country, EXCLUDED.territory, EXCLUDED.ic_partner_company, EXCLUDED.salesforce_id, EXCLUDED.inflow_target, EXCLUDED.outflow_target, EXCLUDED.rent_terms, EXCLUDED.incentive_terms, EXCLUDED.discount_terms, EXCLUDED.tpl_storage_rate, EXCLUDED.tpl_handling_fee, EXCLUDED.active, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_bp_addresses(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.bp_address AS t (company_code, card_code, address_name, kind, street, block, building, city, state, zip, country)
  SELECT s.company_code AS company_code,
         s."CardCode" AS card_code,
         s."Address" AS address_name,
         s."AdresType" AS kind,
         s."Street" AS street,
         s."Block" AS block,
         s."Building" AS building,
         s."City" AS city,
         s."State" AS state,
         s."ZipCode" AS zip,
         s."Country" AS country
    FROM sap."CRD1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, card_code, address_name, kind) DO UPDATE SET street = EXCLUDED.street, block = EXCLUDED.block, building = EXCLUDED.building, city = EXCLUDED.city, state = EXCLUDED.state, zip = EXCLUDED.zip, country = EXCLUDED.country WHERE (t.street, t.block, t.building, t.city, t.state, t.zip, t.country) IS DISTINCT FROM (EXCLUDED.street, EXCLUDED.block, EXCLUDED.building, EXCLUDED.city, EXCLUDED.state, EXCLUDED.zip, EXCLUDED.country);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_bp_merchandisers(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- SAP keeps only the current merchandiser per slot; history starts from the first sync.
  INSERT INTO erp.bp_merchandiser AS t (company_code, card_code, slot, merchandiser_code, merchandiser_name, valid_from)
  SELECT m.company_code, m."CardCode", m.slot, m.code, m.name, DATE '2000-01-01'
    FROM (SELECT company_code, "CardCode", 1 AS slot, "U_Merchandiser_Code" AS code, "U_Merchandiser" AS name FROM sap."OCRD" WHERE company_code = p_company AND nullif(trim("U_Merchandiser_Code"), '') IS NOT NULL UNION ALL SELECT company_code, "CardCode", 2 AS slot, "U_Merchandiser_Code2" AS code, "U_Merchandiser2" AS name FROM sap."OCRD" WHERE company_code = p_company AND nullif(trim("U_Merchandiser_Code2"), '') IS NOT NULL UNION ALL SELECT company_code, "CardCode", 3 AS slot, "U_Merchandiser_Code3" AS code, "U_Merchandiser3" AS name FROM sap."OCRD" WHERE company_code = p_company AND nullif(trim("U_Merchandiser_Code3"), '') IS NOT NULL UNION ALL SELECT company_code, "CardCode", 4 AS slot, "U_Merchandiser_Code4" AS code, "U_Merchandiser4" AS name FROM sap."OCRD" WHERE company_code = p_company AND nullif(trim("U_Merchandiser_Code4"), '') IS NOT NULL) m
  ON CONFLICT (company_code, card_code, slot, valid_from) DO UPDATE
     SET merchandiser_code = EXCLUDED.merchandiser_code, merchandiser_name = EXCLUDED.merchandiser_name WHERE (t.merchandiser_code, t.merchandiser_name) IS DISTINCT FROM (EXCLUDED.merchandiser_code, EXCLUDED.merchandiser_name);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_item_groups(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.item_group AS t (company_code, group_code, name)
  SELECT s.company_code AS company_code,
         s."ItmsGrpCod" AS group_code,
         s."ItmsGrpNam" AS name
    FROM sap."OITB" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, group_code) DO UPDATE SET name = EXCLUDED.name WHERE (t.name) IS DISTINCT FROM (EXCLUDED.name);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_brands(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.brand AS t (company_code, firm_code, name)
  SELECT s.company_code AS company_code,
         s."FirmCode" AS firm_code,
         s."FirmName" AS name
    FROM sap."OMRC" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, firm_code) DO UPDATE SET name = EXCLUDED.name WHERE (t.name) IS DISTINCT FROM (EXCLUDED.name);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_group_items(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- U_ConsolidateMasterCode ties the same product together across the 12 companies.
  INSERT INTO erp.group_item (master_item_code, name, category, subcategory)
  SELECT DISTINCT ON (k) k, coalesce(nullif(s."ItemName", ''), k), s."U_Category", s."U_SubCategory"
    FROM (SELECT coalesce(nullif(trim("U_ConsolidateMasterCode"), ''), nullif(trim("U_MasterItemCode"), '')) AS k, *
            FROM sap."OITM" WHERE company_code = p_company) s
   WHERE k IS NOT NULL
   ORDER BY k, (nullif(s."ItemName", '') IS NULL), s."ItemCode"   -- prefer an item with a name; else the master code (AE05 SF4316EL)
  ON CONFLICT (master_item_code) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_items(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.item AS t (company_code, item_code, name, foreign_name, group_code, firm_code, master_item_code, category, subcategory, level1, level2, level3, segment, odm_division, sourcing_type, item_type, movement_status, hs_code, moq, artwork_ref, barcode, sales_uom, purchase_uom, inventory_uom, is_stock, is_sold, is_bought, batch_managed, serial_managed, pcs_20gp, pcs_40gp, pcs_40hq, rated_voltage, capacity, avg_cost, preferred_supplier, supplier_part_no, active, created_on, source)
  SELECT s.company_code AS company_code,
         s."ItemCode" AS item_code,
         coalesce(s."ItemName", s."ItemCode") AS name,
         s."FrgnName" AS foreign_name,
         s."ItmsGrpCod" AS group_code,
         s."FirmCode" AS firm_code,
         coalesce(nullif(trim(s."U_ConsolidateMasterCode"), ''), nullif(trim(s."U_MasterItemCode"), '')) AS master_item_code,
         s."U_Category" AS category,
         s."U_SubCategory" AS subcategory,
         s."U_Level1" AS level1,
         s."U_Level2" AS level2,
         s."U_Level3" AS level3,
         s."U_Item_Segment" AS segment,
         s."U_ODMDivi" AS odm_division,
         s."U_SourcingType" AS sourcing_type,
         s."U_ItemType" AS item_type,
         s."U_MovementStatus" AS movement_status,
         s."U_HSCodes" AS hs_code,
         s."U_MOQ" AS moq,
         s."U_ArtWork" AS artwork_ref,
         s."CodeBars" AS barcode,
         s."SalUnitMsr" AS sales_uom,
         s."BuyUnitMsr" AS purchase_uom,
         s."InvntryUom" AS inventory_uom,
         (coalesce(s."InvntItem", 'N') = 'Y') AS is_stock,
         (coalesce(s."SellItem", 'N') = 'Y') AS is_sold,
         (coalesce(s."PrchseItem", 'N') = 'Y') AS is_bought,
         coalesce((coalesce(s."ManBtchNum", 'N') = 'Y'), false) AS batch_managed,
         coalesce((coalesce(s."ManSerNum", 'N') = 'Y'), false) AS serial_managed,
         nullif(regexp_replace(s."U_PcsStuffed20GP", '[^0-9]', '', 'g'), '')::integer AS pcs_20gp,
         nullif(regexp_replace(s."U_PcsStuffed40GP", '[^0-9]', '', 'g'), '')::integer AS pcs_40gp,
         nullif(regexp_replace(s."U_PcsStuffed40HQ", '[^0-9]', '', 'g'), '')::integer AS pcs_40hq,
         s."U_RatedVoltage" AS rated_voltage,
         s."U_ProductCapacity" AS capacity,
         s."AvgPrice" AS avg_cost,
         s."CardCode" AS preferred_supplier,
         s."SuppCatNum" AS supplier_part_no,
         (NOT (coalesce(s."frozenFor", 'N') = 'Y' AND coalesce(s."frozenFrom"::date, DATE '1900-01-01') <= current_date AND coalesce(s."frozenTo"::date, DATE '9999-12-31') >= current_date) AND NOT (coalesce(s."validFor", 'N') = 'Y' AND (coalesce(s."validFrom"::date, DATE '1900-01-01') > current_date OR coalesce(s."validTo"::date, DATE '9999-12-31') < current_date))) AS active,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OITM" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, item_code) DO UPDATE SET name = EXCLUDED.name, foreign_name = EXCLUDED.foreign_name, group_code = EXCLUDED.group_code, firm_code = EXCLUDED.firm_code, master_item_code = EXCLUDED.master_item_code, category = EXCLUDED.category, subcategory = EXCLUDED.subcategory, level1 = EXCLUDED.level1, level2 = EXCLUDED.level2, level3 = EXCLUDED.level3, segment = EXCLUDED.segment, odm_division = EXCLUDED.odm_division, sourcing_type = EXCLUDED.sourcing_type, item_type = EXCLUDED.item_type, movement_status = EXCLUDED.movement_status, hs_code = EXCLUDED.hs_code, moq = EXCLUDED.moq, artwork_ref = EXCLUDED.artwork_ref, barcode = EXCLUDED.barcode, sales_uom = EXCLUDED.sales_uom, purchase_uom = EXCLUDED.purchase_uom, inventory_uom = EXCLUDED.inventory_uom, is_stock = EXCLUDED.is_stock, is_sold = EXCLUDED.is_sold, is_bought = EXCLUDED.is_bought, batch_managed = EXCLUDED.batch_managed, serial_managed = EXCLUDED.serial_managed, pcs_20gp = EXCLUDED.pcs_20gp, pcs_40gp = EXCLUDED.pcs_40gp, pcs_40hq = EXCLUDED.pcs_40hq, rated_voltage = EXCLUDED.rated_voltage, capacity = EXCLUDED.capacity, avg_cost = EXCLUDED.avg_cost, preferred_supplier = EXCLUDED.preferred_supplier, supplier_part_no = EXCLUDED.supplier_part_no, active = EXCLUDED.active, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.name, t.foreign_name, t.group_code, t.firm_code, t.master_item_code, t.category, t.subcategory, t.level1, t.level2, t.level3, t.segment, t.odm_division, t.sourcing_type, t.item_type, t.movement_status, t.hs_code, t.moq, t.artwork_ref, t.barcode, t.sales_uom, t.purchase_uom, t.inventory_uom, t.is_stock, t.is_sold, t.is_bought, t.batch_managed, t.serial_managed, t.pcs_20gp, t.pcs_40gp, t.pcs_40hq, t.rated_voltage, t.capacity, t.avg_cost, t.preferred_supplier, t.supplier_part_no, t.active, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.foreign_name, EXCLUDED.group_code, EXCLUDED.firm_code, EXCLUDED.master_item_code, EXCLUDED.category, EXCLUDED.subcategory, EXCLUDED.level1, EXCLUDED.level2, EXCLUDED.level3, EXCLUDED.segment, EXCLUDED.odm_division, EXCLUDED.sourcing_type, EXCLUDED.item_type, EXCLUDED.movement_status, EXCLUDED.hs_code, EXCLUDED.moq, EXCLUDED.artwork_ref, EXCLUDED.barcode, EXCLUDED.sales_uom, EXCLUDED.purchase_uom, EXCLUDED.inventory_uom, EXCLUDED.is_stock, EXCLUDED.is_sold, EXCLUDED.is_bought, EXCLUDED.batch_managed, EXCLUDED.serial_managed, EXCLUDED.pcs_20gp, EXCLUDED.pcs_40gp, EXCLUDED.pcs_40hq, EXCLUDED.rated_voltage, EXCLUDED.capacity, EXCLUDED.avg_cost, EXCLUDED.preferred_supplier, EXCLUDED.supplier_part_no, EXCLUDED.active, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_item_certificates(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- OITM keeps ESMA, SABER, G-Mark, RoHS, SASO, CB and DHA in user fields; here each becomes one row.
  INSERT INTO erp.item_certificate AS t (company_code, item_code, scheme, status, certificate_no, application_no, applied_on, expires_on, rejected_on, remarks)
  SELECT i.company_code, i."ItemCode", c.scheme, c.status, c.cert_no, c.app_no, c.applied, c.expires, c.rejected, c.remarks
    FROM sap."OITM" i
   CROSS JOIN LATERAL (VALUES
      ('ESMA', i."U_EsmaStatus"::text, i."U_EsmaCrtNo"::text, i."U_EsmaAppNo"::text, i."U_EsmaAppDt"::date, i."U_EsmaExpDate"::date, i."U_EsmaRejDate"::date, i."U_EsmaRemarks"::text),
      ('SABER', i."U_SABER_Status"::text, i."U_SABERCrtNo"::text, NULL::text, i."U_SABER_Issued"::date, i."U_SABER_Expiry"::date, NULL::date, NULL::text),
      ('GMARK', i."U_GmarkStatus"::text, i."U_GmarkCrtNo"::text, i."U_GmarkAppNo"::text, i."U_GmarkAppDt"::date, i."U_GmarkExpDate"::date, i."U_GmarkRejDate"::date, i."U_GmarkRemarks"::text),
      ('ROHS', i."U_ROHSStatus"::text, i."U_ROHSCrtNo"::text, NULL::text, NULL::date, i."U_ROHSExpDate"::date, NULL::date, i."U_ROHSRemarks"::text),
      ('SASO', i."U_Saso_App"::text, NULL::text, NULL::text, i."U_Saso_Appd"::date, NULL::date, NULL::date, NULL::text),
      ('CB', i."U_CBStatus"::text, NULL::text, NULL::text, i."U_CBDate"::date, NULL::date, NULL::date, NULL::text),
      ('DHA', i."U_DHACertified"::text, NULL::text, NULL::text, NULL::date, NULL::date, NULL::date, NULL::text)) AS c(scheme, status, cert_no, app_no, applied, expires, rejected, remarks)
   WHERE i.company_code = p_company
     AND (upper(coalesce(trim(c.status), '')) NOT IN ('', 'N', 'NO', 'NA', 'N/A') OR nullif(trim(c.cert_no), '') IS NOT NULL OR c.expires IS NOT NULL)
  ON CONFLICT (company_code, item_code, scheme) DO UPDATE
     SET status = EXCLUDED.status, certificate_no = EXCLUDED.certificate_no, application_no = EXCLUDED.application_no,
         applied_on = EXCLUDED.applied_on, expires_on = EXCLUDED.expires_on, rejected_on = EXCLUDED.rejected_on, remarks = EXCLUDED.remarks WHERE (t.status, t.certificate_no, t.application_no, t.applied_on, t.expires_on, t.rejected_on, t.remarks) IS DISTINCT FROM (EXCLUDED.status, EXCLUDED.certificate_no, EXCLUDED.application_no, EXCLUDED.applied_on, EXCLUDED.expires_on, EXCLUDED.rejected_on, EXCLUDED.remarks);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_item_market_prices(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.item_market_price AS t (company_code, item_code, market, price)
  SELECT i.company_code, i."ItemCode", m.market, m.price
    FROM sap."OITM" i
   CROSS JOIN LATERAL (VALUES
      ('UAE', i."U_UAE_MR"),
      ('KSA', i."U_KSA_MR"),
      ('KWT', i."U_KWT_MR"),
      ('QTR', i."U_QTR_MR"),
      ('BHR', i."U_BHR_MR"),
      ('OMN', i."U_OMN_MR"),
      ('SHOP', i."U_SHOP_MR"),
      ('EXPORT', i."U_EXPORT_MR")) AS m(market, price)
   WHERE i.company_code = p_company AND coalesce(m.price, 0) <> 0
  ON CONFLICT (company_code, item_code, market) DO UPDATE SET price = EXCLUDED.price WHERE (t.price) IS DISTINCT FROM (EXCLUDED.price);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_item_tags(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- @TOP_100.Code holds the item code (confirmed 6 Nov 2026).
  INSERT INTO erp.item_tag (company_code, item_code, tag)
  SELECT t.company_code, t."Code", 'TOP_100'
    FROM sap."@TOP_100" t
    JOIN erp.item i ON i.company_code = t.company_code AND i.item_code = t."Code"
   WHERE t.company_code = p_company
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_price_lists(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.price_list AS t (company_code, list_num, name, base_list, factor)
  SELECT s.company_code AS company_code,
         s."ListNum" AS list_num,
         s."ListName" AS name,
         s."BASE_NUM" AS base_list,
         s."Factor" AS factor
    FROM sap."OPLN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, list_num) DO UPDATE SET name = EXCLUDED.name, base_list = EXCLUDED.base_list, factor = EXCLUDED.factor WHERE (t.name, t.base_list, t.factor) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.base_list, EXCLUDED.factor);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_item_prices(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.item_price AS t (company_code, list_num, item_code, price, currency)
  SELECT s.company_code AS company_code,
         s."PriceList" AS list_num,
         s."ItemCode" AS item_code,
         s."Price" AS price,
         s."Currency" AS currency
    FROM sap."ITM1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, list_num, item_code) DO UPDATE SET price = EXCLUDED.price, currency = EXCLUDED.currency WHERE (t.price, t.currency) IS DISTINCT FROM (EXCLUDED.price, EXCLUDED.currency);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_warehouses(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.warehouse AS t (company_code, whs_code, name, branch_id, classification, city, country, locked, active)
  SELECT s.company_code AS company_code,
         s."WhsCode" AS whs_code,
         coalesce(s."WhsName", s."WhsCode") AS name,
         s."BPLid" AS branch_id,
         s."U_Classifications" AS classification,
         s."City" AS city,
         s."Country" AS country,
         coalesce((coalesce(s."Locked", 'N') = 'Y'), false) AS locked,
         (coalesce(s."Inactive", 'N') <> 'Y') AS active
    FROM sap."OWHS" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, whs_code) DO UPDATE SET name = EXCLUDED.name, branch_id = EXCLUDED.branch_id, classification = EXCLUDED.classification, city = EXCLUDED.city, country = EXCLUDED.country, locked = EXCLUDED.locked, active = EXCLUDED.active WHERE (t.name, t.branch_id, t.classification, t.city, t.country, t.locked, t.active) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.branch_id, EXCLUDED.classification, EXCLUDED.city, EXCLUDED.country, EXCLUDED.locked, EXCLUDED.active);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_stock_balances(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.stock_balance AS t (company_code, item_code, whs_code, on_hand, committed, on_order, avg_cost, min_stock, max_stock)
  SELECT s.company_code AS company_code,
         s."ItemCode" AS item_code,
         s."WhsCode" AS whs_code,
         coalesce(s."OnHand", 0) AS on_hand,
         coalesce(s."IsCommited", 0) AS committed,
         coalesce(s."OnOrder", 0) AS on_order,
         s."AvgPrice" AS avg_cost,
         s."MinStock" AS min_stock,
         s."MaxStock" AS max_stock
    FROM sap."OITW" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, item_code, whs_code) DO UPDATE SET on_hand = EXCLUDED.on_hand, committed = EXCLUDED.committed, on_order = EXCLUDED.on_order, avg_cost = EXCLUDED.avg_cost, min_stock = EXCLUDED.min_stock, max_stock = EXCLUDED.max_stock WHERE (t.on_hand, t.committed, t.on_order, t.avg_cost, t.min_stock, t.max_stock) IS DISTINCT FROM (EXCLUDED.on_hand, EXCLUDED.committed, EXCLUDED.on_order, EXCLUDED.avg_cost, EXCLUDED.min_stock, EXCLUDED.max_stock);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_batches(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.batch AS t (company_code, kind, abs_entry, item_code, number, sys_number, made_on, received_on, expires_on, status)
  SELECT s.company_code AS company_code,
         'B' AS kind,
         s."AbsEntry" AS abs_entry,
         s."ItemCode" AS item_code,
         s."DistNumber" AS number,
         s."SysNumber" AS sys_number,
         s."MnfDate"::date AS made_on,
         s."InDate"::date AS received_on,
         s."ExpDate"::date AS expires_on,
         s."Status" AS status
    FROM sap."OBTN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, kind, abs_entry) DO UPDATE SET item_code = EXCLUDED.item_code, number = EXCLUDED.number, sys_number = EXCLUDED.sys_number, made_on = EXCLUDED.made_on, received_on = EXCLUDED.received_on, expires_on = EXCLUDED.expires_on, status = EXCLUDED.status WHERE (t.item_code, t.number, t.sys_number, t.made_on, t.received_on, t.expires_on, t.status) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.number, EXCLUDED.sys_number, EXCLUDED.made_on, EXCLUDED.received_on, EXCLUDED.expires_on, EXCLUDED.status);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_serials(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.batch AS t (company_code, kind, abs_entry, item_code, number, sys_number, made_on, received_on, expires_on, status)
  SELECT s.company_code AS company_code,
         'S' AS kind,
         s."AbsEntry" AS abs_entry,
         s."ItemCode" AS item_code,
         s."DistNumber" AS number,
         s."SysNumber" AS sys_number,
         s."MnfDate"::date AS made_on,
         s."InDate"::date AS received_on,
         s."ExpDate"::date AS expires_on,
         s."Status" AS status
    FROM sap."OSRN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, kind, abs_entry) DO UPDATE SET item_code = EXCLUDED.item_code, number = EXCLUDED.number, sys_number = EXCLUDED.sys_number, made_on = EXCLUDED.made_on, received_on = EXCLUDED.received_on, expires_on = EXCLUDED.expires_on, status = EXCLUDED.status WHERE (t.item_code, t.number, t.sys_number, t.made_on, t.received_on, t.expires_on, t.status) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.number, EXCLUDED.sys_number, EXCLUDED.made_on, EXCLUDED.received_on, EXCLUDED.expires_on, EXCLUDED.status);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_stock_movements(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.stock_movement AS t (company_code, trans_seq, trans_type, doc_entry, doc_line, doc_date, item_code, whs_code, qty_in, qty_out, price, currency)
  SELECT s.company_code AS company_code,
         s."TransSeq" AS trans_seq,
         s."TransType" AS trans_type,
         s."CreatedBy" AS doc_entry,
         s."DocLineNum" AS doc_line,
         s."DocDate"::date AS doc_date,
         s."ItemCode" AS item_code,
         s."LocCode" AS whs_code,
         coalesce(s."InQty", 0) AS qty_in,
         coalesce(s."OutQty", 0) AS qty_out,
         s."Price" AS price,
         s."Currency" AS currency
    FROM sap."OIVL" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, trans_seq) DO UPDATE SET trans_type = EXCLUDED.trans_type, doc_entry = EXCLUDED.doc_entry, doc_line = EXCLUDED.doc_line, doc_date = EXCLUDED.doc_date, item_code = EXCLUDED.item_code, whs_code = EXCLUDED.whs_code, qty_in = EXCLUDED.qty_in, qty_out = EXCLUDED.qty_out, price = EXCLUDED.price, currency = EXCLUDED.currency WHERE (t.trans_type, t.doc_entry, t.doc_line, t.doc_date, t.item_code, t.whs_code, t.qty_in, t.qty_out, t.price, t.currency) IS DISTINCT FROM (EXCLUDED.trans_type, EXCLUDED.doc_entry, EXCLUDED.doc_line, EXCLUDED.doc_date, EXCLUDED.item_code, EXCLUDED.whs_code, EXCLUDED.qty_in, EXCLUDED.qty_out, EXCLUDED.price, EXCLUDED.currency);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_quotation(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         23 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'sales_quotation' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OQUT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_quotation_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         23 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."QUT1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_order(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         17 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'sales_order' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ORDR" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_order_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         17 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."RDR1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_delivery(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         15 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'delivery' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ODLN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_delivery_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         15 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."DLN1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_return(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         16 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'sales_return' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ORDN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_sales_return_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         16 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."RDN1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_invoice(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         13 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ar_invoice' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OINV" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_invoice_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         13 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."INV1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_credit_note(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         14 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ar_credit_note' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ORIN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_credit_note_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         14 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."RIN1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_down_payment(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         203 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ar_down_payment' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ODPI" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ar_down_payment_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         203 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."DPI1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_request(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         1470000113 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'purchase_request' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OPRQ" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_request_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         1470000113 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."PRQ1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_quotation(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         540000006 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'purchase_quotation' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OPQT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_quotation_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         540000006 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."PQT1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_order(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         22 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'purchase_order' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OPOR" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_purchase_order_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         22 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."POR1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_receipt_po(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         20 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'goods_receipt_po' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OPDN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_receipt_po_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         20 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."PDN1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_return(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         21 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'goods_return' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ORPD" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_return_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         21 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."RPD1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_invoice(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         18 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ap_invoice' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OPCH" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_invoice_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         18 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."PCH1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_credit_note(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         19 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ap_credit_note' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ORPC" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_credit_note_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         19 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."RPC1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_down_payment(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         204 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'ap_down_payment' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."ODPO" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_ap_down_payment_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         204 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."DPO1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_transfer_request(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         1250000001 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'transfer_request' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OWTQ" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_transfer_request_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         1250000001 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."WTQ1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_inventory_transfer(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         67 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'inventory_transfer' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OWTR" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_inventory_transfer_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         67 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."WTR1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_receipt(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         59 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'goods_receipt' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OIGN" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_receipt_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         59 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."IGN1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_issue(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, series, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name, customer_ref, currency, fx_rate, total, total_fc, vat_total, paid, slp_code, branch_id, project, from_whs, to_whs, comments, salesforce_order_id, shipping_mark, shipment_mode, container_no, tpl_job_no, ic_reference, created_on, source)
  SELECT s.company_code AS company_code,
         60 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Series" AS series,
         'goods_issue' AS doc_kind,
         CASE s."CANCELED" WHEN 'Y' THEN 'cancelled' WHEN 'C' THEN 'cancellation' ELSE CASE WHEN s."DocStatus" = 'C' THEN 'closed' ELSE 'open' END END AS status,
         s."DocDate"::date AS doc_date,
         s."DocDueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."NumAtCard" AS customer_ref,
         s."DocCur" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."DocTotalFC" AS total_fc,
         s."VatSum" AS vat_total,
         s."PaidToDate" AS paid,
         s."SlpCode" AS slp_code,
         s."BPLId" AS branch_id,
         s."Project" AS project,
         s."Filler" AS from_whs,
         s."ToWhsCode" AS to_whs,
         s."Comments" AS comments,
         s."U_SOID" AS salesforce_order_id,
         s."U_ShippingMark" AS shipping_mark,
         s."U_Shipment_Mode" AS shipment_mode,
         s."U_ContainerNum" AS container_no,
         s."U_TPL_JobNumber" AS tpl_job_no,
         s."U_InterComReference" AS ic_reference,
         s."CreateDate"::date AS created_on,
         'sap' AS source
    FROM sap."OIGE" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, series = EXCLUDED.series, doc_kind = EXCLUDED.doc_kind, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, customer_ref = EXCLUDED.customer_ref, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, total_fc = EXCLUDED.total_fc, vat_total = EXCLUDED.vat_total, paid = EXCLUDED.paid, slp_code = EXCLUDED.slp_code, branch_id = EXCLUDED.branch_id, project = EXCLUDED.project, from_whs = EXCLUDED.from_whs, to_whs = EXCLUDED.to_whs, comments = EXCLUDED.comments, salesforce_order_id = EXCLUDED.salesforce_order_id, shipping_mark = EXCLUDED.shipping_mark, shipment_mode = EXCLUDED.shipment_mode, container_no = EXCLUDED.container_no, tpl_job_no = EXCLUDED.tpl_job_no, ic_reference = EXCLUDED.ic_reference, created_on = EXCLUDED.created_on, source = EXCLUDED.source WHERE (t.doc_num, t.series, t.doc_kind, t.status, t.doc_date, t.due_date, t.tax_date, t.card_code, t.card_name, t.customer_ref, t.currency, t.fx_rate, t.total, t.total_fc, t.vat_total, t.paid, t.slp_code, t.branch_id, t.project, t.from_whs, t.to_whs, t.comments, t.salesforce_order_id, t.shipping_mark, t.shipment_mode, t.container_no, t.tpl_job_no, t.ic_reference, t.created_on, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.series, EXCLUDED.doc_kind, EXCLUDED.status, EXCLUDED.doc_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.customer_ref, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.total_fc, EXCLUDED.vat_total, EXCLUDED.paid, EXCLUDED.slp_code, EXCLUDED.branch_id, EXCLUDED.project, EXCLUDED.from_whs, EXCLUDED.to_whs, EXCLUDED.comments, EXCLUDED.salesforce_order_id, EXCLUDED.shipping_mark, EXCLUDED.shipment_mode, EXCLUDED.container_no, EXCLUDED.tpl_job_no, EXCLUDED.ic_reference, EXCLUDED.created_on, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_docs_goods_issue_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.document_line AS t (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency, discount_pct, line_total, line_total_fc, tax_code, vat, whs_code, from_whs, acct_code, cost_centre, cost_centre2, project, base_obj_type, base_doc_entry, base_line, line_status, gross_buy_price, stock_price, slp_code, cbm, hs_code, salesforce_line_id)
  SELECT s.company_code AS company_code,
         60 AS obj_type,
         s."DocEntry" AS doc_entry,
         s."LineNum" AS line_num,
         s."ItemCode" AS item_code,
         s."Dscription" AS description,
         s."Quantity" AS quantity,
         s."OpenQty" AS open_qty,
         s."unitMsr" AS uom,
         s."Price" AS price,
         s."Currency" AS currency,
         s."DiscPrcnt" AS discount_pct,
         s."LineTotal" AS line_total,
         s."TotalFrgn" AS line_total_fc,
         s."VatGroup" AS tax_code,
         s."VatSum" AS vat,
         s."WhsCode" AS whs_code,
         s."FromWhsCod" AS from_whs,
         s."AcctCode" AS acct_code,
         s."OcrCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."Project" AS project,
         nullif(s."BaseType", -1) AS base_obj_type,
         s."BaseEntry" AS base_doc_entry,
         s."BaseLine" AS base_line,
         s."LineStatus" AS line_status,
         s."GrossBuyPr" AS gross_buy_price,
         s."StockPrice" AS stock_price,
         s."SlpCode" AS slp_code,
         s."U_CBM" AS cbm,
         s."U_HSCodes" AS hs_code,
         s."U_SFLineId" AS salesforce_line_id
    FROM sap."IGE1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, obj_type, doc_entry, line_num) DO UPDATE SET item_code = EXCLUDED.item_code, description = EXCLUDED.description, quantity = EXCLUDED.quantity, open_qty = EXCLUDED.open_qty, uom = EXCLUDED.uom, price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, line_total = EXCLUDED.line_total, line_total_fc = EXCLUDED.line_total_fc, tax_code = EXCLUDED.tax_code, vat = EXCLUDED.vat, whs_code = EXCLUDED.whs_code, from_whs = EXCLUDED.from_whs, acct_code = EXCLUDED.acct_code, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, project = EXCLUDED.project, base_obj_type = EXCLUDED.base_obj_type, base_doc_entry = EXCLUDED.base_doc_entry, base_line = EXCLUDED.base_line, line_status = EXCLUDED.line_status, gross_buy_price = EXCLUDED.gross_buy_price, stock_price = EXCLUDED.stock_price, slp_code = EXCLUDED.slp_code, cbm = EXCLUDED.cbm, hs_code = EXCLUDED.hs_code, salesforce_line_id = EXCLUDED.salesforce_line_id WHERE (t.item_code, t.description, t.quantity, t.open_qty, t.uom, t.price, t.currency, t.discount_pct, t.line_total, t.line_total_fc, t.tax_code, t.vat, t.whs_code, t.from_whs, t.acct_code, t.cost_centre, t.cost_centre2, t.project, t.base_obj_type, t.base_doc_entry, t.base_line, t.line_status, t.gross_buy_price, t.stock_price, t.slp_code, t.cbm, t.hs_code, t.salesforce_line_id) IS DISTINCT FROM (EXCLUDED.item_code, EXCLUDED.description, EXCLUDED.quantity, EXCLUDED.open_qty, EXCLUDED.uom, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.line_total, EXCLUDED.line_total_fc, EXCLUDED.tax_code, EXCLUDED.vat, EXCLUDED.whs_code, EXCLUDED.from_whs, EXCLUDED.acct_code, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.project, EXCLUDED.base_obj_type, EXCLUDED.base_doc_entry, EXCLUDED.base_line, EXCLUDED.line_status, EXCLUDED.gross_buy_price, EXCLUDED.stock_price, EXCLUDED.slp_code, EXCLUDED.cbm, EXCLUDED.hs_code, EXCLUDED.salesforce_line_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_journals(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.journal_entry AS t (company_code, trans_id, number, ref_date, due_date, tax_date, memo, ref1, ref2, ref3, trans_type, base_ref, trans_code, total_local, total_sys, currency, reversal_of, project, source, created_on)
  SELECT s.company_code AS company_code,
         s."TransId" AS trans_id,
         s."Number" AS number,
         s."RefDate"::date AS ref_date,
         s."DueDate"::date AS due_date,
         s."TaxDate"::date AS tax_date,
         s."Memo" AS memo,
         s."Ref1" AS ref1,
         s."Ref2" AS ref2,
         s."Ref3" AS ref3,
         s."TransType"::integer AS trans_type,
         s."BaseRef" AS base_ref,
         s."TransCode" AS trans_code,
         s."LocTotal" AS total_local,
         s."SysTotal" AS total_sys,
         s."TransCurr" AS currency,
         s."StornoToTr" AS reversal_of,
         s."Project" AS project,
         'sap' AS source,
         s."CreateDate"::date AS created_on
    FROM sap."OJDT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, trans_id) DO UPDATE SET number = EXCLUDED.number, ref_date = EXCLUDED.ref_date, due_date = EXCLUDED.due_date, tax_date = EXCLUDED.tax_date, memo = EXCLUDED.memo, ref1 = EXCLUDED.ref1, ref2 = EXCLUDED.ref2, ref3 = EXCLUDED.ref3, trans_type = EXCLUDED.trans_type, base_ref = EXCLUDED.base_ref, trans_code = EXCLUDED.trans_code, total_local = EXCLUDED.total_local, total_sys = EXCLUDED.total_sys, currency = EXCLUDED.currency, reversal_of = EXCLUDED.reversal_of, project = EXCLUDED.project, source = EXCLUDED.source, created_on = EXCLUDED.created_on WHERE (t.number, t.ref_date, t.due_date, t.tax_date, t.memo, t.ref1, t.ref2, t.ref3, t.trans_type, t.base_ref, t.trans_code, t.total_local, t.total_sys, t.currency, t.reversal_of, t.project, t.source, t.created_on) IS DISTINCT FROM (EXCLUDED.number, EXCLUDED.ref_date, EXCLUDED.due_date, EXCLUDED.tax_date, EXCLUDED.memo, EXCLUDED.ref1, EXCLUDED.ref2, EXCLUDED.ref3, EXCLUDED.trans_type, EXCLUDED.base_ref, EXCLUDED.trans_code, EXCLUDED.total_local, EXCLUDED.total_sys, EXCLUDED.currency, EXCLUDED.reversal_of, EXCLUDED.project, EXCLUDED.source, EXCLUDED.created_on);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_journal_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.journal_line AS t (company_code, trans_id, line_id, acct_code, short_name, contra_acct, debit, credit, fc_debit, fc_credit, fc_currency, sys_debit, sys_credit, memo, cost_centre, cost_centre2, cost_centre3, project, ref_date, due_date, branch_id, tax_code, match_no)
  SELECT s.company_code AS company_code,
         s."TransId" AS trans_id,
         s."Line_ID" AS line_id,
         s."Account" AS acct_code,
         nullif(s."ShortName", s."Account") AS short_name,
         s."ContraAct" AS contra_acct,
         coalesce(s."Debit", 0) AS debit,
         coalesce(s."Credit", 0) AS credit,
         s."FCDebit" AS fc_debit,
         s."FCCredit" AS fc_credit,
         s."FCCurrency" AS fc_currency,
         s."SYSDeb" AS sys_debit,
         s."SYSCred" AS sys_credit,
         s."LineMemo" AS memo,
         s."ProfitCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."OcrCode3" AS cost_centre3,
         s."Project" AS project,
         s."RefDate"::date AS ref_date,
         s."DueDate"::date AS due_date,
         s."BPLId" AS branch_id,
         s."VatGroup" AS tax_code,
         s."IntrnMatch" AS match_no
    FROM sap."JDT1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, trans_id, line_id) DO UPDATE SET acct_code = EXCLUDED.acct_code, short_name = EXCLUDED.short_name, contra_acct = EXCLUDED.contra_acct, debit = EXCLUDED.debit, credit = EXCLUDED.credit, fc_debit = EXCLUDED.fc_debit, fc_credit = EXCLUDED.fc_credit, fc_currency = EXCLUDED.fc_currency, sys_debit = EXCLUDED.sys_debit, sys_credit = EXCLUDED.sys_credit, memo = EXCLUDED.memo, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, cost_centre3 = EXCLUDED.cost_centre3, project = EXCLUDED.project, ref_date = EXCLUDED.ref_date, due_date = EXCLUDED.due_date, branch_id = EXCLUDED.branch_id, tax_code = EXCLUDED.tax_code, match_no = EXCLUDED.match_no WHERE (t.acct_code, t.short_name, t.contra_acct, t.debit, t.credit, t.fc_debit, t.fc_credit, t.fc_currency, t.sys_debit, t.sys_credit, t.memo, t.cost_centre, t.cost_centre2, t.cost_centre3, t.project, t.ref_date, t.due_date, t.branch_id, t.tax_code, t.match_no) IS DISTINCT FROM (EXCLUDED.acct_code, EXCLUDED.short_name, EXCLUDED.contra_acct, EXCLUDED.debit, EXCLUDED.credit, EXCLUDED.fc_debit, EXCLUDED.fc_credit, EXCLUDED.fc_currency, EXCLUDED.sys_debit, EXCLUDED.sys_credit, EXCLUDED.memo, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.cost_centre3, EXCLUDED.project, EXCLUDED.ref_date, EXCLUDED.due_date, EXCLUDED.branch_id, EXCLUDED.tax_code, EXCLUDED.match_no);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payments_incoming(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.payment AS t (company_code, direction, doc_entry, doc_num, doc_type, doc_date, card_code, card_name, currency, fx_rate, total, cash, transfer, cheque, card, on_account, cancelled, trans_id, branch_id, memo, source)
  SELECT s.company_code AS company_code,
         'I' AS direction,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."DocType" AS doc_type,
         s."DocDate"::date AS doc_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."DocCurr" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."CashSum" AS cash,
         s."TrsfrSum" AS transfer,
         s."CheckSum" AS cheque,
         s."CreditSum" AS card,
         s."NoDocSum" AS on_account,
         coalesce((coalesce(s."Canceled", 'N') = 'Y'), false) AS cancelled,
         s."TransId" AS trans_id,
         s."BPLId" AS branch_id,
         s."JrnlMemo" AS memo,
         'sap' AS source
    FROM sap."ORCT" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, direction, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, doc_type = EXCLUDED.doc_type, doc_date = EXCLUDED.doc_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, cash = EXCLUDED.cash, transfer = EXCLUDED.transfer, cheque = EXCLUDED.cheque, card = EXCLUDED.card, on_account = EXCLUDED.on_account, cancelled = EXCLUDED.cancelled, trans_id = EXCLUDED.trans_id, branch_id = EXCLUDED.branch_id, memo = EXCLUDED.memo, source = EXCLUDED.source WHERE (t.doc_num, t.doc_type, t.doc_date, t.card_code, t.card_name, t.currency, t.fx_rate, t.total, t.cash, t.transfer, t.cheque, t.card, t.on_account, t.cancelled, t.trans_id, t.branch_id, t.memo, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.doc_type, EXCLUDED.doc_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.cash, EXCLUDED.transfer, EXCLUDED.cheque, EXCLUDED.card, EXCLUDED.on_account, EXCLUDED.cancelled, EXCLUDED.trans_id, EXCLUDED.branch_id, EXCLUDED.memo, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payment_allocations_incoming(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.payment_allocation AS t (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, target_line, applied, applied_fc)
  SELECT s.company_code AS company_code,
         'I' AS direction,
         s."DocNum" AS doc_entry,
         s."InvoiceId" AS line_no,
         s."InvType"::integer AS target_obj_type,
         s."DocEntry" AS target_doc_entry,
         s."DocLine" AS target_line,
         s."SumApplied" AS applied,
         s."AppliedFC" AS applied_fc
    FROM sap."RCT2" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, direction, doc_entry, line_no) DO UPDATE SET target_obj_type = EXCLUDED.target_obj_type, target_doc_entry = EXCLUDED.target_doc_entry, target_line = EXCLUDED.target_line, applied = EXCLUDED.applied, applied_fc = EXCLUDED.applied_fc WHERE (t.target_obj_type, t.target_doc_entry, t.target_line, t.applied, t.applied_fc) IS DISTINCT FROM (EXCLUDED.target_obj_type, EXCLUDED.target_doc_entry, EXCLUDED.target_line, EXCLUDED.applied, EXCLUDED.applied_fc);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payments_outgoing(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.payment AS t (company_code, direction, doc_entry, doc_num, doc_type, doc_date, card_code, card_name, currency, fx_rate, total, cash, transfer, cheque, card, on_account, cancelled, trans_id, branch_id, memo, source)
  SELECT s.company_code AS company_code,
         'O' AS direction,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."DocType" AS doc_type,
         s."DocDate"::date AS doc_date,
         s."CardCode" AS card_code,
         s."CardName" AS card_name,
         s."DocCurr" AS currency,
         s."DocRate" AS fx_rate,
         s."DocTotal" AS total,
         s."CashSum" AS cash,
         s."TrsfrSum" AS transfer,
         s."CheckSum" AS cheque,
         s."CreditSum" AS card,
         s."NoDocSum" AS on_account,
         coalesce((coalesce(s."Canceled", 'N') = 'Y'), false) AS cancelled,
         s."TransId" AS trans_id,
         s."BPLId" AS branch_id,
         s."JrnlMemo" AS memo,
         'sap' AS source
    FROM sap."OVPM" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, direction, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, doc_type = EXCLUDED.doc_type, doc_date = EXCLUDED.doc_date, card_code = EXCLUDED.card_code, card_name = EXCLUDED.card_name, currency = EXCLUDED.currency, fx_rate = EXCLUDED.fx_rate, total = EXCLUDED.total, cash = EXCLUDED.cash, transfer = EXCLUDED.transfer, cheque = EXCLUDED.cheque, card = EXCLUDED.card, on_account = EXCLUDED.on_account, cancelled = EXCLUDED.cancelled, trans_id = EXCLUDED.trans_id, branch_id = EXCLUDED.branch_id, memo = EXCLUDED.memo, source = EXCLUDED.source WHERE (t.doc_num, t.doc_type, t.doc_date, t.card_code, t.card_name, t.currency, t.fx_rate, t.total, t.cash, t.transfer, t.cheque, t.card, t.on_account, t.cancelled, t.trans_id, t.branch_id, t.memo, t.source) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.doc_type, EXCLUDED.doc_date, EXCLUDED.card_code, EXCLUDED.card_name, EXCLUDED.currency, EXCLUDED.fx_rate, EXCLUDED.total, EXCLUDED.cash, EXCLUDED.transfer, EXCLUDED.cheque, EXCLUDED.card, EXCLUDED.on_account, EXCLUDED.cancelled, EXCLUDED.trans_id, EXCLUDED.branch_id, EXCLUDED.memo, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payment_allocations_outgoing(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.payment_allocation AS t (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, target_line, applied, applied_fc)
  SELECT s.company_code AS company_code,
         'O' AS direction,
         s."DocNum" AS doc_entry,
         s."InvoiceId" AS line_no,
         s."InvType"::integer AS target_obj_type,
         s."DocEntry" AS target_doc_entry,
         s."DocLine" AS target_line,
         s."SumApplied" AS applied,
         s."AppliedFC" AS applied_fc
    FROM sap."VPM2" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, direction, doc_entry, line_no) DO UPDATE SET target_obj_type = EXCLUDED.target_obj_type, target_doc_entry = EXCLUDED.target_doc_entry, target_line = EXCLUDED.target_line, applied = EXCLUDED.applied, applied_fc = EXCLUDED.applied_fc WHERE (t.target_obj_type, t.target_doc_entry, t.target_line, t.applied, t.applied_fc) IS DISTINCT FROM (EXCLUDED.target_obj_type, EXCLUDED.target_doc_entry, EXCLUDED.target_line, EXCLUDED.applied, EXCLUDED.applied_fc);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_ic_account_map(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.ic_account_map AS t (company_code, acct_code, group_acct_code, group_acct_name)
  SELECT s.company_code AS company_code,
         s."U_CTX_OACC" AS acct_code,
         s."U_CTX_MACC" AS group_acct_code,
         s."U_CTX_MANM" AS group_acct_name
    FROM (SELECT DISTINCT ON (company_code, "U_CTX_OACC") * FROM sap."@CTX_ACCMAP" WHERE company_code = p_company AND "U_CTX_OACC" IS NOT NULL AND "U_CTX_MACC" IS NOT NULL ORDER BY company_code, "U_CTX_OACC", "Code" DESC) s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, acct_code) DO UPDATE SET group_acct_code = EXCLUDED.group_acct_code, group_acct_name = EXCLUDED.group_acct_name WHERE (t.group_acct_code, t.group_acct_name) IS DISTINCT FROM (EXCLUDED.group_acct_code, EXCLUDED.group_acct_name);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_hr_org(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.hr_org_unit AS t (company_code, kind, code, name, parent_code, attrs)
  SELECT s.company_code, 'payroll_area', s."Code", s."Name", NULL, jsonb_build_object('year', s."U_ALTYEAR", 'frequency', s."U_ALTFRQ", 'starts', s."U_ALTSDATE") FROM sap."@ALT_HR_PAYR" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'personnel_area', s."Code", s."Name", NULL, '{}'::jsonb FROM sap."@ALT_HR_PARE" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'personnel_subarea', s."Code", s."Name", s."U_ALTPAREA", '{}'::jsonb FROM sap."@ALT_HR_PSAR" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'division', s."Code", s."Name", NULL, '{}'::jsonb FROM sap."@ALT_HR_DIV" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'subdivision', s."Code", s."Name", s."U_ALTDIV", '{}'::jsonb FROM sap."@ALT_HR_SDIV" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'employee_group', s."Code", s."Name", NULL, '{}'::jsonb FROM sap."@ALT_HR_EGRP" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'employee_subgroup', s."Code", s."Name", s."U_ALTEGRP", '{}'::jsonb FROM sap."@ALT_HR_ESGP" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'grade', s."Code", s."Name", NULL, '{}'::jsonb FROM sap."@ALT_HR_GRADE" s WHERE s.company_code = p_company
  UNION ALL SELECT s.company_code, 'position', s."Code", coalesce(s."U_AltShrDs", s."Name"), NULL, '{}'::jsonb FROM sap."@ALT_HR_POSITION" s WHERE s.company_code = p_company
  ON CONFLICT (company_code, kind, code) DO UPDATE SET name = EXCLUDED.name, parent_code = EXCLUDED.parent_code, attrs = EXCLUDED.attrs WHERE (t.name, t.parent_code, t.attrs) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.parent_code, EXCLUDED.attrs);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_employees(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.employee AS t (company_code, emp_id, hr_code, first_name, middle_name, last_name, job_title, position_code, department, branch_id, manager_emp_id, slp_code, mobile, office_phone, email, gender, birth_date, nationality, passport_no, passport_expires, gov_id, joined_on, left_on, status, payroll_area, personnel_area, personnel_subarea, division, subdivision, sponsor, pay_currency, active, source)
  SELECT s.company_code AS company_code,
         s."empID" AS emp_id,
         nullif(trim(s."U_ALTEMPID"), '') AS hr_code,
         s."firstName" AS first_name,
         s."middleName" AS middle_name,
         s."lastName" AS last_name,
         s."jobTitle" AS job_title,
         s."position"::text AS position_code,
         s."dept" AS department,
         s."BPLId" AS branch_id,
         s."manager" AS manager_emp_id,
         s."salesPrson" AS slp_code,
         s."mobile" AS mobile,
         s."officeTel" AS office_phone,
         s."email" AS email,
         s."sex" AS gender,
         s."birthDate"::date AS birth_date,
         s."citizenshp" AS nationality,
         s."passportNo" AS passport_no,
         s."passportEx"::date AS passport_expires,
         s."govID" AS gov_id,
         coalesce(e."U_ALTDOH"::date, s."startDate"::date) AS joined_on,
         s."termDate"::date AS left_on,
         coalesce(e."U_ALTSTATS", s."status"::text) AS status,
         e."U_ALTPYARE" AS payroll_area,
         e."U_ALTPAREA" AS personnel_area,
         e."U_ALTPSARE" AS personnel_subarea,
         e."U_ALTDIV" AS division,
         e."U_ALTSDIV" AS subdivision,
         e."U_ALTSPON" AS sponsor,
         e."U_ALTCURR" AS pay_currency,
         (coalesce(s."Active", 'Y') = 'Y') AS active,
         'sap' AS source
    FROM sap."OHEM" s LEFT JOIN sap."@ALT_HR_EMD" e ON e.company_code = s.company_code AND e."Code" = s."U_ALTEMPID"
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, emp_id) DO UPDATE SET hr_code = EXCLUDED.hr_code, first_name = EXCLUDED.first_name, middle_name = EXCLUDED.middle_name, last_name = EXCLUDED.last_name, job_title = EXCLUDED.job_title, position_code = EXCLUDED.position_code, department = EXCLUDED.department, branch_id = EXCLUDED.branch_id, manager_emp_id = EXCLUDED.manager_emp_id, slp_code = EXCLUDED.slp_code, mobile = EXCLUDED.mobile, office_phone = EXCLUDED.office_phone, email = EXCLUDED.email, gender = EXCLUDED.gender, birth_date = EXCLUDED.birth_date, nationality = EXCLUDED.nationality, passport_no = EXCLUDED.passport_no, passport_expires = EXCLUDED.passport_expires, gov_id = EXCLUDED.gov_id, joined_on = EXCLUDED.joined_on, left_on = EXCLUDED.left_on, status = EXCLUDED.status, payroll_area = EXCLUDED.payroll_area, personnel_area = EXCLUDED.personnel_area, personnel_subarea = EXCLUDED.personnel_subarea, division = EXCLUDED.division, subdivision = EXCLUDED.subdivision, sponsor = EXCLUDED.sponsor, pay_currency = EXCLUDED.pay_currency, active = EXCLUDED.active, source = EXCLUDED.source WHERE (t.hr_code, t.first_name, t.middle_name, t.last_name, t.job_title, t.position_code, t.department, t.branch_id, t.manager_emp_id, t.slp_code, t.mobile, t.office_phone, t.email, t.gender, t.birth_date, t.nationality, t.passport_no, t.passport_expires, t.gov_id, t.joined_on, t.left_on, t.status, t.payroll_area, t.personnel_area, t.personnel_subarea, t.division, t.subdivision, t.sponsor, t.pay_currency, t.active, t.source) IS DISTINCT FROM (EXCLUDED.hr_code, EXCLUDED.first_name, EXCLUDED.middle_name, EXCLUDED.last_name, EXCLUDED.job_title, EXCLUDED.position_code, EXCLUDED.department, EXCLUDED.branch_id, EXCLUDED.manager_emp_id, EXCLUDED.slp_code, EXCLUDED.mobile, EXCLUDED.office_phone, EXCLUDED.email, EXCLUDED.gender, EXCLUDED.birth_date, EXCLUDED.nationality, EXCLUDED.passport_no, EXCLUDED.passport_expires, EXCLUDED.gov_id, EXCLUDED.joined_on, EXCLUDED.left_on, EXCLUDED.status, EXCLUDED.payroll_area, EXCLUDED.personnel_area, EXCLUDED.personnel_subarea, EXCLUDED.division, EXCLUDED.subdivision, EXCLUDED.sponsor, EXCLUDED.pay_currency, EXCLUDED.active, EXCLUDED.source);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_employee_documents(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.employee_document AS t (company_code, hr_code, doc_type, doc_no, issued_on, expires_on, issued_by)
  SELECT DISTINCT ON (h.company_code, h."U_AltEmpID", d."U_AltIDTYP", coalesce(d."U_AltIDNO", ''))
         h.company_code, h."U_AltEmpID", d."U_AltIDTYP", coalesce(d."U_AltIDNO", ''), d."U_AltIDate"::date, d."U_AltEDate"::date, d."U_AltIssBy"
    FROM sap."@ALT_HR_IDENDETH" h
    JOIN sap."@ALT_HR_IDENDETD" d ON d.company_code = h.company_code AND d."DocEntry" = h."DocEntry"
   WHERE h.company_code = p_company AND h."U_AltEmpID" IS NOT NULL AND d."U_AltIDTYP" IS NOT NULL
   ORDER BY h.company_code, h."U_AltEmpID", d."U_AltIDTYP", coalesce(d."U_AltIDNO", ''), d."U_AltEDate" DESC NULLS LAST
  ON CONFLICT (company_code, hr_code, doc_type, doc_no) DO UPDATE
     SET issued_on = EXCLUDED.issued_on, expires_on = EXCLUDED.expires_on, issued_by = EXCLUDED.issued_by WHERE (t.issued_on, t.expires_on, t.issued_by) IS DISTINCT FROM (EXCLUDED.issued_on, EXCLUDED.expires_on, EXCLUDED.issued_by);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_wage_types(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.wage_type AS t (company_code, code, name, is_earning, is_deduction, is_loan, calc_type, gl_account)
  SELECT s.company_code AS company_code,
         s."Code" AS code,
         s."Name" AS name,
         (coalesce(s."U_AltEarn", 'N') = 'Y') AS is_earning,
         (coalesce(s."U_AltDedu", 'N') = 'Y') AS is_deduction,
         (coalesce(s."U_AltLoan", 'N') = 'Y') AS is_loan,
         s."U_AltCalTy" AS calc_type,
         s."U_AltGLAct" AS gl_account
    FROM sap."@ALT_HR_WAGETYPE" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, is_earning = EXCLUDED.is_earning, is_deduction = EXCLUDED.is_deduction, is_loan = EXCLUDED.is_loan, calc_type = EXCLUDED.calc_type, gl_account = EXCLUDED.gl_account WHERE (t.name, t.is_earning, t.is_deduction, t.is_loan, t.calc_type, t.gl_account) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.is_earning, EXCLUDED.is_deduction, EXCLUDED.is_loan, EXCLUDED.calc_type, EXCLUDED.gl_account);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_employee_pay(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- Basic pay per employee from @ALT_HR_BASICPAYL (@ALT_HR_WAGE is not used at Sanford).
  -- Allowances and other wage codes are in erp.payroll_result, month by month.
  INSERT INTO erp.employee_pay AS t (company_code, hr_code, wage_type, amount, currency, valid_from)
  SELECT DISTINCT ON (b.company_code, b."U_AltEmpCd", coalesce(b."U_AltStrDt"::date, DATE '1900-01-01'))
         b.company_code, b."U_AltEmpCd", 'BASIC', coalesce(b."U_AltMntBc", b."U_AltAnBsc" / 12, 0), e.pay_currency,
         coalesce(b."U_AltStrDt"::date, DATE '1900-01-01')
    FROM sap."@ALT_HR_BASICPAYL" b
    LEFT JOIN erp.employee e ON e.company_code = b.company_code AND e.hr_code = b."U_AltEmpCd"
   WHERE b.company_code = p_company AND b."U_AltEmpCd" IS NOT NULL AND coalesce(b."U_AltCancl", 'N') <> 'Y'
   ORDER BY b.company_code, b."U_AltEmpCd", coalesce(b."U_AltStrDt"::date, DATE '1900-01-01'), b."Code" DESC
  ON CONFLICT (company_code, hr_code, wage_type, valid_from) DO UPDATE SET amount = EXCLUDED.amount, currency = EXCLUDED.currency WHERE (t.amount, t.currency) IS DISTINCT FROM (EXCLUDED.amount, EXCLUDED.currency);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_leave_types(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.leave_type AS t (company_code, code, name, paid, unit, max_days, min_days, loss_of_pay, counts_for_eos)
  SELECT s.company_code AS company_code,
         s."Code" AS code,
         s."Name" AS name,
         (coalesce(s."U_ALTUPAID", 'N') <> 'Y') AS paid,
         s."U_ALTUNITS" AS unit,
         s."U_ALTMAXD"::numeric AS max_days,
         s."U_ALTMIND"::numeric AS min_days,
         (coalesce(s."U_ALTLOP", 'N') = 'Y') AS loss_of_pay,
         (coalesce(s."U_ALTNCEOS", 'N') <> 'Y') AS counts_for_eos
    FROM sap."@ALT_HR_ABSTYPE" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, paid = EXCLUDED.paid, unit = EXCLUDED.unit, max_days = EXCLUDED.max_days, min_days = EXCLUDED.min_days, loss_of_pay = EXCLUDED.loss_of_pay, counts_for_eos = EXCLUDED.counts_for_eos WHERE (t.name, t.paid, t.unit, t.max_days, t.min_days, t.loss_of_pay, t.counts_for_eos) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.paid, EXCLUDED.unit, EXCLUDED.max_days, EXCLUDED.min_days, EXCLUDED.loss_of_pay, EXCLUDED.counts_for_eos);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_payroll_results(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  -- @ALT_HR_PRRT has one column per wage code (U_ALT1008, U_ALTI550 ...); turn them into rows.
  INSERT INTO erp.payroll_result AS t (company_code, period, hr_code, wage_code, amount)
  SELECT r.company_code, r."U_ALTINPRD", r."U_ALTEMPID", substr(kv.key, 6), sum(kv.value::numeric)
    FROM sap."@ALT_HR_PRRT" r
   CROSS JOIN LATERAL jsonb_each_text(to_jsonb(r)) kv
   WHERE r.company_code = p_company AND r."U_ALTEMPID" IS NOT NULL AND r."U_ALTINPRD" IS NOT NULL
     AND kv.key ~ '^U_ALT(I?[0-9]{3,4}|L[PB][0-9]{2}|IN[0-9]{2})$'
     AND kv.value ~ '^-?[0-9.]+$' AND kv.value::numeric <> 0
   GROUP BY 1, 2, 3, 4
  ON CONFLICT (company_code, period, hr_code, wage_code) DO UPDATE SET amount = EXCLUDED.amount WHERE (t.amount) IS DISTINCT FROM (EXCLUDED.amount);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_air_tickets(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.air_ticket_accrual AS t (company_code, doc_entry, hr_code, home_city, eligible, tickets, opening, closing, next_due)
  SELECT s.company_code AS company_code,
         s."DocEntry" AS doc_entry,
         s."U_ALTEMPID" AS hr_code,
         s."U_ALTHMCTY" AS home_city,
         s."U_ALTELGBT" AS eligible,
         s."U_ALTNTKTS"::numeric AS tickets,
         s."U_ALTOPNBL"::numeric AS opening,
         s."U_ALTCLSBL"::numeric AS closing,
         s."U_ALTNXPDT"::date AS next_due
    FROM sap."@ALT_HR_TKTACRL" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, doc_entry) DO UPDATE SET hr_code = EXCLUDED.hr_code, home_city = EXCLUDED.home_city, eligible = EXCLUDED.eligible, tickets = EXCLUDED.tickets, opening = EXCLUDED.opening, closing = EXCLUDED.closing, next_due = EXCLUDED.next_due WHERE (t.hr_code, t.home_city, t.eligible, t.tickets, t.opening, t.closing, t.next_due) IS DISTINCT FROM (EXCLUDED.hr_code, EXCLUDED.home_city, EXCLUDED.eligible, EXCLUDED.tickets, EXCLUDED.opening, EXCLUDED.closing, EXCLUDED.next_due);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_tpl_contracts(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.tpl_contract AS t (company_code, job_code, client_code, client_name, status, active, starts_on, ends_on, extended_to, storage_fee, min_storage_fee, min_handling_fee, fixed_handling, handling_rates, slp_code)
  SELECT s.company_code AS company_code,
         s."Code" AS job_code,
         coalesce(s."U_TPL_ClientCode", s."U_TPL_JobClentCode") AS client_code,
         s."U_TPL_ClientName" AS client_name,
         s."U_TPL_JobStatus" AS status,
         (coalesce(s."U_TPL_JobActive", 'N') = 'Y') AS active,
         s."U_TPL_ContractStartDate"::date AS starts_on,
         s."U_TPL_ContractEndDate"::date AS ends_on,
         s."U_TPL_ContractExtendedUpto"::date AS extended_to,
         s."U_TPL_JobStorageFee" AS storage_fee,
         s."U_TPL_MinStorageFee" AS min_storage_fee,
         s."U_TPL_MinHandlingFee" AS min_handling_fee,
         (coalesce(s."U_TPL_JobIsFxdHndlngFee", 'N') = 'Y') AS fixed_handling,
         jsonb_strip_nulls(jsonb_build_object('in40hcnp', s."U_TPL_JobHandlingFeeIn40HcNP", 'out40np', s."U_TPL_JobHandlingFeeOut40NP", 'outlclnp', s."U_TPL_JobHandlingFeeOutLCLNP", 'outlcl', s."U_TPL_JobHandlingFeeOutLCL", 'inlcl', s."U_TPL_JobHandlingFeeInLCL", 'out40hc', s."U_TPL_JobHandlingFeeOut40Hc", 'in40np', s."U_TPL_JobHandlingFeeIn40NP", 'in', s."U_TPL_JobHandlingFeeIn", 'in20', s."U_TPL_JobHandlingFeeIn20", 'out40hcnp', s."U_TPL_JobHandlingFeeOut40HcNP", 'in40', s."U_TPL_JobHandlingFeeIn40", 'out', s."U_TPL_JobHandlingFeeOut", 'out40', s."U_TPL_JobHandlingFeeOut40", 'out20', s."U_TPL_JobHandlingFeeOut20", 'in20np', s."U_TPL_JobHandlingFeeIn20NP", 'inlclnp', s."U_TPL_JobHandlingFeeInLCLNP", 'in40hc', s."U_TPL_JobHandlingFeeIn40Hc", 'out20np', s."U_TPL_JobHandlingFeeOut20NP")) AS handling_rates,
         s."U_TPL_SlpCode" AS slp_code
    FROM sap."@TPL_JOBS" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, job_code) DO UPDATE SET client_code = EXCLUDED.client_code, client_name = EXCLUDED.client_name, status = EXCLUDED.status, active = EXCLUDED.active, starts_on = EXCLUDED.starts_on, ends_on = EXCLUDED.ends_on, extended_to = EXCLUDED.extended_to, storage_fee = EXCLUDED.storage_fee, min_storage_fee = EXCLUDED.min_storage_fee, min_handling_fee = EXCLUDED.min_handling_fee, fixed_handling = EXCLUDED.fixed_handling, handling_rates = EXCLUDED.handling_rates, slp_code = EXCLUDED.slp_code WHERE (t.client_code, t.client_name, t.status, t.active, t.starts_on, t.ends_on, t.extended_to, t.storage_fee, t.min_storage_fee, t.min_handling_fee, t.fixed_handling, t.handling_rates, t.slp_code) IS DISTINCT FROM (EXCLUDED.client_code, EXCLUDED.client_name, EXCLUDED.status, EXCLUDED.active, EXCLUDED.starts_on, EXCLUDED.ends_on, EXCLUDED.extended_to, EXCLUDED.storage_fee, EXCLUDED.min_storage_fee, EXCLUDED.min_handling_fee, EXCLUDED.fixed_handling, EXCLUDED.handling_rates, EXCLUDED.slp_code);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_artwork(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.artwork_request AS t (company_code, doc_entry, doc_num, status, po_doc_num, po_date, po_amount, contact, remark, created_on)
  SELECT s.company_code AS company_code,
         s."DocEntry" AS doc_entry,
         s."DocNum" AS doc_num,
         s."Status" AS status,
         s."U_SAP_PO" AS po_doc_num,
         s."U_SAP_PODTE"::date AS po_date,
         s."U_PO_Amount" AS po_amount,
         s."U_Contact_P" AS contact,
         s."Remark" AS remark,
         s."CreateDate"::date AS created_on
    FROM sap."@ARTWORKMASTER" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, doc_entry) DO UPDATE SET doc_num = EXCLUDED.doc_num, status = EXCLUDED.status, po_doc_num = EXCLUDED.po_doc_num, po_date = EXCLUDED.po_date, po_amount = EXCLUDED.po_amount, contact = EXCLUDED.contact, remark = EXCLUDED.remark, created_on = EXCLUDED.created_on WHERE (t.doc_num, t.status, t.po_doc_num, t.po_date, t.po_amount, t.contact, t.remark, t.created_on) IS DISTINCT FROM (EXCLUDED.doc_num, EXCLUDED.status, EXCLUDED.po_doc_num, EXCLUDED.po_date, EXCLUDED.po_amount, EXCLUDED.contact, EXCLUDED.remark, EXCLUDED.created_on);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_artwork_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.artwork_line AS t (company_code, doc_entry, part, line_id, model_no, image_ref, status, approved_by, approved_on)
  SELECT g.company_code, g."DocEntry", 'gift_box', g."LineId", g."U_Model_No", g."U_Gift_Box_Image", g."U_GiftBoxsts", g."U_Gift_BoxApp_By", g."U_Gift_BoxApDate"::date
    FROM sap."@ARTWORKMASTER_GIFTB" g WHERE g.company_code = p_company
  UNION ALL
  SELECT m.company_code, m."DocEntry", 'master_carton', m."LineId", NULL, NULL, m."U_Master_CartonS", NULL, NULL
    FROM sap."@ARTWORKMASTER_MCT" m WHERE m.company_code = p_company
  ON CONFLICT (company_code, doc_entry, part, line_id) DO UPDATE
     SET model_no = EXCLUDED.model_no, image_ref = EXCLUDED.image_ref, status = EXCLUDED.status, approved_by = EXCLUDED.approved_by, approved_on = EXCLUDED.approved_on WHERE (t.model_no, t.image_ref, t.status, t.approved_by, t.approved_on) IS DISTINCT FROM (EXCLUDED.model_no, EXCLUDED.image_ref, EXCLUDED.status, EXCLUDED.approved_by, EXCLUDED.approved_on);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_supplier_pi(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.supplier_pi AS t (company_code, code, vendor_pi_no, vendor_name, item_code, product_name, pi_qty, qty, eta, status, doc_date)
  SELECT s.company_code AS company_code,
         s."Code" AS code,
         s."U_VPINumber" AS vendor_pi_no,
         s."U_Vname" AS vendor_name,
         s."U_ProductCode" AS item_code,
         s."U_ProductName" AS product_name,
         s."U_PIQty" AS pi_qty,
         s."U_Qunatity" AS qty,
         s."U_ETA" AS eta,
         s."U_Status" AS status,
         s."U_DocDate"::date AS doc_date
    FROM sap."@PISTATUS" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET vendor_pi_no = EXCLUDED.vendor_pi_no, vendor_name = EXCLUDED.vendor_name, item_code = EXCLUDED.item_code, product_name = EXCLUDED.product_name, pi_qty = EXCLUDED.pi_qty, qty = EXCLUDED.qty, eta = EXCLUDED.eta, status = EXCLUDED.status, doc_date = EXCLUDED.doc_date WHERE (t.vendor_pi_no, t.vendor_name, t.item_code, t.product_name, t.pi_qty, t.qty, t.eta, t.status, t.doc_date) IS DISTINCT FROM (EXCLUDED.vendor_pi_no, EXCLUDED.vendor_name, EXCLUDED.item_code, EXCLUDED.product_name, EXCLUDED.pi_qty, EXCLUDED.qty, EXCLUDED.eta, EXCLUDED.status, EXCLUDED.doc_date);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_trademarks(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.trademark AS t (company_code, code, trademark_no, description, class, country, valid_from, valid_to)
  SELECT s.company_code AS company_code,
         s."Code" AS code,
         s."U_Trademark_Code" AS trademark_no,
         s."U_Description" AS description,
         s."U_Class" AS class,
         s."U_Country" AS country,
         s."U_Valid_From"::date AS valid_from,
         s."U_Valid_To"::date AS valid_to
    FROM sap."@TRADEMARK" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, code) DO UPDATE SET trademark_no = EXCLUDED.trademark_no, description = EXCLUDED.description, class = EXCLUDED.class, country = EXCLUDED.country, valid_from = EXCLUDED.valid_from, valid_to = EXCLUDED.valid_to WHERE (t.trademark_no, t.description, t.class, t.country, t.valid_from, t.valid_to) IS DISTINCT FROM (EXCLUDED.trademark_no, EXCLUDED.description, EXCLUDED.class, EXCLUDED.country, EXCLUDED.valid_from, EXCLUDED.valid_to);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

-- Runs every step for one company in dependency order, committing after each step,
-- so a failure keeps the steps already done:  CALL erp.sync_company('AE01');
-- Then read erp.sync_log and run SELECT * FROM erp.check_sync('AE01').
CREATE OR REPLACE PROCEDURE erp.sync_company(p_company varchar) LANGUAGE plpgsql AS $f$
DECLARE n bigint; t timestamptz;
BEGIN
  PERFORM set_config('erp.sync', 'on', false);
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema)
  SELECT c.company_code, c.legal_name, c.legal_name, c.country, c.currency, c.licence_type, c.sap_schema FROM sap._company c WHERE c.company_code = p_company
  ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, country = EXCLUDED.country, currency = EXCLUDED.currency,
       licence_type = EXCLUDED.licence_type, sap_schema = EXCLUDED.sap_schema;
  COMMIT;
  t := clock_timestamp(); n := erp.sync_branches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_branches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_accounts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_accounts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_cost_centres(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_cost_centres', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tax_codes(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tax_codes', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_fx_rates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_fx_rates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_salespeople(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_salespeople', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_terms(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_terms', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_business_partners(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_business_partners', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_addresses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_addresses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_merchandisers(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_merchandisers', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_brands(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_brands', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_group_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_group_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_certificates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_certificates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_market_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_market_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_tags(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_tags', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_price_lists(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_price_lists', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_warehouses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_warehouses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_balances(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_balances', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_batches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_batches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_serials(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_serials', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_movements(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_movements', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journals(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journals', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journal_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journal_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_ic_account_map(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_ic_account_map', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_hr_org(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_hr_org', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employees(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employees', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_documents(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_documents', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_wage_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_wage_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_pay(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_pay', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_leave_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_leave_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payroll_results(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payroll_results', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_air_tickets(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_air_tickets', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tpl_contracts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tpl_contracts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_supplier_pi(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_supplier_pi', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_trademarks(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_trademarks', n, t); COMMIT;
  PERFORM set_config('erp.sync', 'off', false);
END $f$;

-- Rows that came from SAP but are no longer in the raw copy (deleted in SAP before a re-load).
-- The sync only adds and updates; review these before removing them.
CREATE OR REPLACE FUNCTION erp.check_deleted(p_company varchar) RETURNS TABLE (what text, rows bigint) LANGUAGE sql STABLE AS $f$
  SELECT * FROM (SELECT 'business_partner'::text, count(*) FROM erp.business_partner e WHERE e.company_code = p_company AND e.source = 'sap' AND NOT EXISTS (SELECT 1 FROM sap."OCRD" s WHERE s.company_code = e.company_code AND s."CardCode" = e.card_code)
  UNION ALL SELECT 'item'::text, count(*) FROM erp.item e WHERE e.company_code = p_company AND e.source = 'sap' AND NOT EXISTS (SELECT 1 FROM sap."OITM" s WHERE s.company_code = e.company_code AND s."ItemCode" = e.item_code)
  UNION ALL SELECT 'journal_entry'::text, count(*) FROM erp.journal_entry e WHERE e.company_code = p_company AND e.source = 'sap' AND NOT EXISTS (SELECT 1 FROM sap."OJDT" s WHERE s.company_code = e.company_code AND s."TransId" = e.trans_id)
  UNION ALL SELECT 'document OQUT'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 23 AND NOT EXISTS (SELECT 1 FROM sap."OQUT" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ORDR'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 17 AND NOT EXISTS (SELECT 1 FROM sap."ORDR" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ODLN'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 15 AND NOT EXISTS (SELECT 1 FROM sap."ODLN" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ORDN'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 16 AND NOT EXISTS (SELECT 1 FROM sap."ORDN" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OINV'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 13 AND NOT EXISTS (SELECT 1 FROM sap."OINV" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ORIN'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 14 AND NOT EXISTS (SELECT 1 FROM sap."ORIN" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ODPI'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 203 AND NOT EXISTS (SELECT 1 FROM sap."ODPI" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OPRQ'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 1470000113 AND NOT EXISTS (SELECT 1 FROM sap."OPRQ" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OPQT'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 540000006 AND NOT EXISTS (SELECT 1 FROM sap."OPQT" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OPOR'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 22 AND NOT EXISTS (SELECT 1 FROM sap."OPOR" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OPDN'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 20 AND NOT EXISTS (SELECT 1 FROM sap."OPDN" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ORPD'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 21 AND NOT EXISTS (SELECT 1 FROM sap."ORPD" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OPCH'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 18 AND NOT EXISTS (SELECT 1 FROM sap."OPCH" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ORPC'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 19 AND NOT EXISTS (SELECT 1 FROM sap."ORPC" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document ODPO'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 204 AND NOT EXISTS (SELECT 1 FROM sap."ODPO" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OWTQ'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 1250000001 AND NOT EXISTS (SELECT 1 FROM sap."OWTQ" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OWTR'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 67 AND NOT EXISTS (SELECT 1 FROM sap."OWTR" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OIGN'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 59 AND NOT EXISTS (SELECT 1 FROM sap."OIGN" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)
  UNION ALL SELECT 'document OIGE'::text, count(*) FROM erp.document e WHERE e.company_code = p_company AND e.source = 'sap' AND e.obj_type = 60 AND NOT EXISTS (SELECT 1 FROM sap."OIGE" s WHERE s.company_code = e.company_code AND s."DocEntry" = e.doc_entry)) x WHERE x.count > 0
$f$;

-- Compares the app layer (rows that came from SAP) with the raw SAP layer for one company. Every row should say ok.
CREATE OR REPLACE FUNCTION erp.check_sync(p_company varchar) RETURNS TABLE (check_name text, sap_value numeric, erp_value numeric, ok boolean)
LANGUAGE sql STABLE AS $f$
  WITH c AS (
    SELECT 'customers and suppliers' AS k, (SELECT count(*) FROM sap."OCRD" WHERE company_code = p_company)::numeric AS a,
           (SELECT count(*) FROM erp.business_partner WHERE company_code = p_company AND source = 'sap')::numeric AS b
    UNION ALL SELECT 'items', (SELECT count(*) FROM sap."OITM" WHERE company_code = p_company), (SELECT count(*) FROM erp.item WHERE company_code = p_company AND source = 'sap')
    UNION ALL SELECT 'A/R invoices', (SELECT count(*) FROM sap."OINV" WHERE company_code = p_company), (SELECT count(*) FROM erp.document WHERE company_code = p_company AND obj_type = 13 AND source = 'sap')
    UNION ALL SELECT 'A/R invoice total', (SELECT coalesce(sum("DocTotal"), 0) FROM sap."OINV" WHERE company_code = p_company), (SELECT coalesce(sum(total), 0) FROM erp.document WHERE company_code = p_company AND obj_type = 13 AND source = 'sap')
    UNION ALL SELECT 'journal lines', (SELECT count(*) FROM sap."JDT1" WHERE company_code = p_company), (SELECT count(*) FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id) WHERE l.company_code = p_company AND e.source = 'sap')
    UNION ALL SELECT 'debits', (SELECT coalesce(sum("Debit"), 0) FROM sap."JDT1" WHERE company_code = p_company), (SELECT coalesce(sum(l.debit), 0) FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id) WHERE l.company_code = p_company AND e.source = 'sap')
    UNION ALL SELECT 'credits', (SELECT coalesce(sum("Credit"), 0) FROM sap."JDT1" WHERE company_code = p_company), (SELECT coalesce(sum(l.credit), 0) FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id) WHERE l.company_code = p_company AND e.source = 'sap')
    UNION ALL SELECT 'debits minus credits (must be 0)', 0, (SELECT coalesce(sum(debit - credit), 0) FROM erp.journal_line WHERE company_code = p_company)
    UNION ALL SELECT 'stock on hand', (SELECT coalesce(sum("OnHand"), 0) FROM sap."OITW" WHERE company_code = p_company), (SELECT coalesce(sum(on_hand), 0) FROM erp.stock_balance WHERE company_code = p_company)
    UNION ALL SELECT 'employees', (SELECT count(*) FROM sap."OHEM" WHERE company_code = p_company), (SELECT count(*) FROM erp.employee WHERE company_code = p_company AND source = 'sap')
  )
  SELECT k, a, b, round(a, 2) = round(b, 2) FROM c
$f$;

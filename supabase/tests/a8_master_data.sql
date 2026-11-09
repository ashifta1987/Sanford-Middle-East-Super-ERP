-- A8 · Master data tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 23_master_data.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a8_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a8_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a8_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.save(p_user uuid, p_bp jsonb, p_dup text DEFAULT NULL, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.bp_save(%L, %L::jsonb, %L, %L)', 'ZZ99', p_bp, p_dup, p_reason))
$$;
CREATE FUNCTION pg_temp.chk(p_user uuid, p_bp jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.bp_checks(%L, %L::jsonb)', 'ZZ99', p_bp))
$$;
-- the message of the first error for a field in a bp_checks / item_checks result
CREATE FUNCTION pg_temp.err(p_res jsonb, p_field text) RETURNS text LANGUAGE sql AS $$
  SELECT e->>'message' FROM jsonb_array_elements(coalesce(p_res->'errors', '[]'::jsonb)) e WHERE e->>'field' = p_field LIMIT 1
$$;
CREATE FUNCTION pg_temp.isave(p_user uuid, p_item jsonb, p_dup text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.item_save(%L, %L::jsonb, %L)', 'ZZ99', p_item, p_dup))
$$;
CREATE FUNCTION pg_temp.ichk(p_user uuid, p_item jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.item_checks(%L, %L::jsonb)', 'ZZ99', p_item))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_req integer, p_dec text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.bp_change_decide(%L, %s, %L, %L)', 'ZZ99', p_req, p_dec, p_note))
$$;
CREATE FUNCTION pg_temp.su(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN EXECUTE p_sql INTO v; RETURN v; END $$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  sread  uuid := '00000000-0000-4000-8000-000000000006';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  stread uuid := '00000000-0000-4000-8000-000000000015';
  bp     uuid := '00000000-0000-4000-8000-000000000016';
  bpread uuid := '00000000-0000-4000-8000-000000000017';
  r jsonb; r2 jsonb; c1 text; c2 text; s1 text; l1 text; q1 integer; q2 integer; q3 integer; b1 integer; v_n integer;
  base jsonb := '{"kind":"customer","name":"Zenith Home Appliances LLC","foreign_name":"زينيث للأجهزة المنزلية","group_code":100,"payment_terms":2,
                  "currency":"AED","country":"AE","city":"Dubai","trn":"100 2345 6789 0003","phone":"+971 4 555 0101","email":"Buyer@Zenith.test",
                  "price_list":1,"slp_code":2,
                  "contacts":[{"name":"Sara Buyer","role":"Purchasing","mobile":"+971 50 555 0101","email":"sara@zenith.test","is_default":true}],
                  "addresses":[{"address_name":"Head office","kind":"B","street":"Sheikh Zayed Road","city":"Dubai","country":"AE"},
                               {"address_name":"Warehouse","kind":"S","street":"Al Quoz 3","city":"Dubai","country":"AE"}]}';
  it jsonb := '{"item_code":"a8-kettle-01","name":"Glass kettle 1.7 L","foreign_name":"غلاية زجاجية","group_code":101,"barcode":"6291000000017",
                "hs_code":"8516.79.00","moq":300,"pcs_20gp":1500,"pcs_40gp":3100,"pcs_40hq":3600,"sourcing_type":"odm","preferred_supplier":"S0001",
                "supplier_part_no":"FS-GK-17","tax_code":"SR","sales_uom":"pcs","purchase_uom":"ctn","inventory_uom":"pcs",
                "is_stock":true,"is_sold":true,"is_bought":true,"batch_managed":false,"serial_managed":true}';
BEGIN
  -- ---------- Access ----------
  r := pg_temp.call(nobody, $q$SELECT erp.master_data_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'user without a profile refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(bp, $q$SELECT erp.bp_info('AE01', 'C0001')$q$), 'You don''t have access to company AE01.', 'other company refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.bp_checks('ZZ99', '{}')$q$),
    'Your position does not include Business Partners. Ask the system admin if you need it.', 'inventory-only user can''t open partners');
  PERFORM pg_temp.expect(pg_temp.save(bpread, base),
    'You have read-only access to Business Partners. Ask the system admin for full access to create or change partners.', 'read-only BP user can''t create a partner');
  PERFORM pg_temp.expect(pg_temp.save(sread, base),
    'You have read-only access to Business Partners. Ask the system admin for full access to create or change partners.', 'read-only sales user can''t create a partner');
  PERFORM pg_temp.expect(pg_temp.save(sales, base || '{"kind":"supplier","group_code":201}'),
    'Your position can create and change customers and leads only. Ask a Business Partners or Purchasing user to change suppliers.', 'sales user can''t create a supplier');
  PERFORM pg_temp.expect(pg_temp.save(purch, base),
    'Your position can create and change suppliers only. Ask a Business Partners or Sales user to change customers and leads.', 'purchasing user can''t create a customer');
  PERFORM pg_temp.expect(pg_temp.save(owner, base),
    'You have read-only access to Business Partners. Ask the system admin for full access to create or change partners.', 'owner (read on every module, no write) can''t create a partner');
  r := pg_temp.call(bp, $q$SELECT erp.master_data_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->'numbering'->>'customer' = 'C00001' AND jsonb_array_length(r->'bp_groups') = 5 AND (r->'can_write_bp'->>'supplier')::boolean
                        AND NOT (r->>'can_write_items')::boolean AND jsonb_array_length(r->'credit_approvers') = 1
                        AND r->'bank_approvers'->0->>'approver_position' = 'QA_FIN_MGR' AND r->'bp_required' = '["group_code", "payment_terms"]',
                        'setup: numbering, groups, rights, approvers, mandatory fields', left(r::text, 300));

  -- ---------- Partner validations ----------
  r := pg_temp.chk(bp, '{}');
  PERFORM pg_temp.check(pg_temp.err(r, 'kind') = 'Choose the partner type: customer, supplier or lead.', 'type required', r->>'errors');
  PERFORM pg_temp.check(pg_temp.err(r, 'name') = 'Enter the partner name.', 'name required');
  PERFORM pg_temp.check(pg_temp.err(r, 'group_code') = 'Enter the group. It is mandatory in company ZZ99.', 'company-mandatory group');
  PERFORM pg_temp.check(pg_temp.err(r, 'payment_terms') = 'Enter the payment terms. It is mandatory in company ZZ99.', 'company-mandatory payment terms');
  r := pg_temp.chk(bp, base || jsonb_build_object('name', repeat('x', 101)));
  PERFORM pg_temp.check(pg_temp.err(r, 'name') = 'The name is too long (100 characters at most).', 'name too long');
  r := pg_temp.chk(bp, base || '{"trn":"10023456789"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'trn') = 'The TRN must be 15 digits for a UAE partner, e.g. 100123456700003.', 'UAE TRN must be 15 digits', r->>'errors');
  r := pg_temp.chk(bp, base || '{"trn":"10023456789000A"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'trn') = 'The TRN must be 15 digits for a UAE partner, e.g. 100123456700003.', 'UAE TRN digits only');
  r := pg_temp.chk(bp, base || '{"country":"OM","trn":"OM1100012345"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'trn') IS NULL, 'non-UAE tax number not held to the UAE format');
  r := pg_temp.chk(bp, base || '{"group_code":200}');
  PERFORM pg_temp.check(pg_temp.err(r, 'group_code') = 'Group China factories is for suppliers. Choose a customer group.', 'group must match the type', r->>'errors');
  r := pg_temp.chk(bp, base || '{"group_code":999}');
  PERFORM pg_temp.check(pg_temp.err(r, 'group_code') = 'Group 999 does not exist in company ZZ99.', 'unknown group');
  r := pg_temp.chk(bp, base || '{"currency":"EURO"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'currency') = 'Currency must be a 3-letter code, e.g. AED or USD.', 'currency format');
  r := pg_temp.chk(bp, base || '{"currency":"JPY"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'currency') = 'Currency JPY is not used in company ZZ99. Ask Finance to add its exchange rate first.', 'unknown currency');
  r := pg_temp.chk(bp, base || '{"country":"UAE"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'country') = 'Country must be a 2-letter code, e.g. AE.', 'country code');
  r := pg_temp.chk(bp, base || '{"phone":"call me","mobile":"12"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'phone') = 'Enter the phone number with digits only, e.g. +971 4 123 4567.'
                        AND pg_temp.err(r, 'mobile') = 'Enter the mobile number with digits only, e.g. +971 50 123 4567.', 'phone and mobile format');
  r := pg_temp.chk(bp, base || '{"email":"buyer@zenith"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'email') = 'The e-mail address buyer@zenith is not valid.', 'e-mail format');
  r := pg_temp.chk(bp, base || '{"payment_terms":77,"price_list":9,"slp_code":99}');
  PERFORM pg_temp.check(pg_temp.err(r, 'payment_terms') = 'Payment terms 77 do not exist in company ZZ99.' AND pg_temp.err(r, 'price_list') = 'Price list 9 does not exist in company ZZ99.'
                        AND pg_temp.err(r, 'slp_code') = 'Salesperson 99 does not exist or is inactive.', 'payment terms, price list, salesperson must exist');
  r := pg_temp.chk(bp, base || '{"credit_limit":"lots"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'credit_limit') = 'Enter the credit limit as a number.', 'credit limit must be a number');
  r := pg_temp.chk(bp, base || '{"credit_limit":-5}');
  PERFORM pg_temp.check(pg_temp.err(r, 'credit_limit') = 'The credit limit can''t be negative.', 'credit limit not negative');
  r := pg_temp.chk(bp, base || '{"contacts":[{"name":"","email":"x"},{"name":"B","is_default":true},{"name":"C","is_default":true,"phone":"12"}]}');
  PERFORM pg_temp.check(r->'errors' @> '[{"field":"contacts","message":"Contact 1: enter the name."}]'
                        AND r->'errors' @> '[{"field":"contacts","message":"Contact 1: the e-mail address x is not valid."}]'
                        AND r->'errors' @> '[{"field":"contacts","message":"Only one contact can be the main contact."}]'
                        AND r->'errors' @> '[{"field":"contacts","message":"Contact 3: enter the phone number with digits only."}]', 'contact checks', r->>'errors');
  r := pg_temp.chk(bp, base || '{"addresses":[{"address_name":"","kind":"B"},{"address_name":"Shop","kind":"X"},{"address_name":"Shop","kind":"S"},{"address_name":"shop","kind":"S","country":"Dubai"}]}');
  PERFORM pg_temp.check(r->'errors' @> '[{"message":"Address 1: enter the address name, e.g. Head office."}]'
                        AND r->'errors' @> '[{"message":"Address 2: choose bill-to or ship-to."}]'
                        AND r->'errors' @> '[{"message":"Address 4: \"shop\" is already used for another ship-to address."}]'
                        AND r->'errors' @> '[{"message":"Address 4: country must be a 2-letter code, e.g. AE."}]', 'address checks', r->>'errors');
  PERFORM pg_temp.expect(pg_temp.save(bp, base || '{"email":"nope"}'), 'The e-mail address nope is not valid.', 'save refuses with the first problem');

  -- ---------- Create: series code, credit limit waits for approval ----------
  r := pg_temp.chk(bp, base || '{"credit_limit":75000}');
  PERFORM pg_temp.check(jsonb_array_length(r->'errors') = 0 AND jsonb_array_length(r->'duplicates') = 0
                        AND r->'approvals'->0->>'message' = 'Credit limit 75,000.00 AED (was none) needs approval from QA · finance manager.',
                        'checks show the credit limit approval before saving', left(r::text, 300));
  r := pg_temp.save(bp, base || '{"credit_limit":75000}', NULL, 'New hypermarket account');
  c1 := r->>'card_code'; q1 := (r->'credit_request'->>'request_id')::integer;
  PERFORM pg_temp.check(c1 = 'C00001' AND (r->>'created')::boolean AND q1 IS NOT NULL, 'customer created with the next C code; limit request opened', left(r::text, 200));
  PERFORM pg_temp.check((SELECT source = 'erp' AND credit_limit = 0 AND trn = '100234567890003' AND email = 'buyer@zenith.test' AND kind = 'customer'
                           AND foreign_name = 'زينيث للأجهزة المنزلية' FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = c1),
                        'new partner: source erp, credit limit 0 until approved, TRN digits, e-mail lower case');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.bp_contact WHERE company_code = 'ZZ99' AND card_code = c1) = 1
                        AND (SELECT count(*) FROM erp.bp_address WHERE company_code = 'ZZ99' AND card_code = c1) = 2, 'contacts and addresses saved');
  PERFORM pg_temp.check((SELECT string_agg(step || ':' || approver_position || ':' || rule_code, ',') FROM erp.approval WHERE object = 'bp_change' AND object_ref = q1::text)
                        = '1:QA_FIN_MGR:bp_credit_limit', 'credit limit request waits for QA · finance manager');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'bp_create' AND object_ref = c1)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'bp_credit_limit_request' AND object_ref = c1 AND detail->>'to' = '75000.00'),
                        'create and limit request in the audit log');
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'bp_change' AND (w->>'doc_entry')::integer = q1
                                   AND w->>'card_code' = c1 AND (w->>'total')::numeric = 75000 AND w->>'reason' = 'New hypermarket account'),
                        'finance manager sees it in Waiting for me', left(r->>'waiting', 300));
  r := pg_temp.call(bp, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sent') w WHERE w->>'kind' = 'bp_change' AND (w->>'doc_entry')::integer = q1), 'requester sees it in Sent by me');
  PERFORM pg_temp.expect(pg_temp.decide(bp, q1, 'approved'), 'You can''t approve your own change request.', 'requester can''t approve');
  PERFORM pg_temp.expect(pg_temp.decide(fin, q1, 'approved'), 'This change request is waiting for approval from QA · finance manager. Your position can''t decide it.',
    'finance user (not the approver) can''t approve');
  PERFORM pg_temp.expect(pg_temp.decide(stock, q1, 'approved'), 'Your position does not include Business Partners. Ask the system admin if you need it.',
    'inventory user can''t decide');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, q1, 'rejected'), 'Add a note saying why you are rejecting this change request.', 'reject needs a note');
  r := pg_temp.decide(fmgr, q1, 'approved', 'Checked trade references');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND (SELECT credit_limit FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = c1) = 75000
                        AND (SELECT state FROM erp.bp_change_request WHERE request_id = q1) = 'approved', 'approval applies the credit limit', left(r::text, 200));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'bp_credit_limit_change' AND object_ref = c1 AND actor = fmgr::text),
                        'credit limit change kept in the audit log');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, q1, 'approved'), 'This change request is not waiting for approval.', 'decided request can''t be decided again');

  -- ---------- Edit: credit limit change waits; other fields apply ----------
  r := pg_temp.save(bp, jsonb_build_object('card_code', c1, 'credit_limit', 120000, 'city', 'Sharjah'), NULL, 'Bigger orders from Q1');
  q2 := (r->'credit_request'->>'request_id')::integer;
  PERFORM pg_temp.check(q2 IS NOT NULL AND r->'changed' ? 'city' AND NOT r->'changed' ? 'credit_limit'
                        AND (SELECT credit_limit = 75000 AND city = 'Sharjah' FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = c1),
                        'credit limit change waits; city changes at once', left(r::text, 200));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.bp_contact WHERE company_code = 'ZZ99' AND card_code = c1) = 1, 'edit without contacts keeps them');
  r := pg_temp.chk(bp, jsonb_build_object('card_code', c1, 'credit_limit', 130000));
  PERFORM pg_temp.check(pg_temp.err(r, 'credit_limit') = 'A credit limit change for C00001 is already waiting for approval. Wait for the decision or cancel it.',
                        'second credit limit change refused while one waits');
  r := pg_temp.decide(fmgr, q2, 'rejected', 'Balance overdue');
  PERFORM pg_temp.check(r->>'state' = 'rejected' AND (SELECT credit_limit FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = c1) = 75000,
                        'rejected change leaves the limit as it was');
  r := pg_temp.save(bp, jsonb_build_object('card_code', c1, 'credit_limit', 90000));
  q3 := (r->'credit_request'->>'request_id')::integer;
  PERFORM pg_temp.expect(pg_temp.call(bpread, format($q$SELECT erp.bp_change_cancel('ZZ99', %s)$q$, q3)),
    'You have read-only access to Business Partners. Ask the system admin for full access to create or change partners.', 'read-only user can''t cancel someone''s request');
  r := pg_temp.call(bp, format($q$SELECT erp.bp_change_cancel('ZZ99', %s, 'Not needed')$q$, q3));
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND NOT EXISTS (SELECT 1 FROM erp.approval WHERE object = 'bp_change' AND object_ref = q3::text AND decision IS NULL AND NOT superseded),
                        'requester cancels; approvals closed');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, q3, 'approved'), 'This change request is not waiting for approval.', 'cancelled request can''t be approved');
  r := pg_temp.call(fmgr, format($q$SELECT erp.bp_save('ZZ99', '{"card_code":"%s","phone":"+971 4 555 0199"}')$q$, c1));
  PERFORM pg_temp.check(r->>'card_code' = c1, 'Financials full access may also edit partners', r::text);

  -- ---------- Type changes, currency ----------
  r := pg_temp.save(bp, '{"kind":"lead","name":"Orbit Electronics Prospect","group_code":101,"payment_terms":1,"phone":"+971 4 777 0303"}');
  l1 := r->>'card_code';
  PERFORM pg_temp.check(l1 = 'L00001', 'lead gets an L code', r::text);
  PERFORM pg_temp.expect(pg_temp.save(bp, jsonb_build_object('card_code', l1, 'kind', 'supplier', 'group_code', 201)),
    'A partner''s type can only change from lead to customer.', 'lead can''t become a supplier');
  r := pg_temp.save(bp, jsonb_build_object('card_code', l1, 'kind', 'customer'));
  PERFORM pg_temp.check((SELECT kind FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = l1) = 'customer', 'lead converted to customer (code kept)', r::text);
  PERFORM pg_temp.expect(pg_temp.save(bp, jsonb_build_object('card_code', c1, 'kind', 'lead')), 'A partner''s type can only change from lead to customer.', 'customer can''t go back to lead');
  PERFORM pg_temp.su(format($q$WITH x AS (INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, total, source)
                               VALUES ('ZZ99', 13, 999800001, 999800001, 'ar_invoice', 'open', '2026-11-10', '%s', 'x', 'AED', 1, 'erp') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$, c1));
  PERFORM pg_temp.expect(pg_temp.save(bp, jsonb_build_object('card_code', c1, 'currency', 'USD')),
    'C00001 already has documents in AED. Its currency can''t change.', 'currency fixed once documents exist');

  -- ---------- Duplicate warnings ----------
  r := pg_temp.chk(bp, '{"kind":"customer","name":"Zenith Home Appliance LLC","group_code":100,"payment_terms":2}');
  PERFORM pg_temp.check(r->'duplicates'->0->>'card_code' = c1 AND r->'duplicates'->0->>'match' = 'name' AND (r->'duplicates'->0->>'similarity')::numeric > 0.8,
                        'similar name found (trigram similarity above 0.8)', r->>'duplicates');
  PERFORM pg_temp.check(erp._md_trgm_sim('Zenith Home Appliances LLC', 'Zenith Home Appliance LLC') BETWEEN 0.8 AND 0.95
                        AND erp._md_trgm_sim('word', 'two words') = 0.3636 AND erp._md_trgm_sim('abc', 'abc') = 1,
                        'trigram similarity matches pg_trgm values', erp._md_trgm_sim('word', 'two words')::text);
  r := pg_temp.chk(bp, '{"kind":"customer","name":"Totally Different Co","country":"AE","trn":"100234567890003","group_code":100,"payment_terms":2}');
  PERFORM pg_temp.check(r->'duplicates'->0->>'card_code' = c1 AND r->'duplicates'->0->>'match' = 'trn', 'same TRN found', r->>'duplicates');
  r := pg_temp.chk(bp, '{"kind":"supplier","name":"Another Name Trading","mobile":"00971-4-555-0101x","phone":"+971 (4) 555 0199","group_code":201,"payment_terms":2}');
  PERFORM pg_temp.check(r->'duplicates' @> jsonb_build_array(jsonb_build_object('card_code', c1, 'match', 'phone')), 'same phone found (formatting ignored)', r->>'duplicates');
  r := pg_temp.chk(bp, '{"kind":"customer","name":"Quiet Unique Name","phone":"+971 4 999 1234","group_code":100,"payment_terms":2}');
  PERFORM pg_temp.check(jsonb_array_length(r->'duplicates') = 0, 'no false duplicate', r->>'duplicates');
  PERFORM pg_temp.expect(pg_temp.save(bp, '{"kind":"customer","name":"Zenith Home Appliance LLC","group_code":100,"payment_terms":2}'),
    'This partner may already exist: C00001 · Zenith Home Appliances LLC (similar name). Check the list and confirm with a reason to save it anyway.',
    'duplicate warning stops the save without a reason');
  r := pg_temp.save(bp, '{"kind":"customer","name":"Zenith Home Appliance LLC","group_code":100,"payment_terms":2}', 'Separate branch with its own TRN');
  c2 := r->>'card_code';
  PERFORM pg_temp.check(c2 = 'C00002' AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'bp_duplicate_confirmed' AND object_ref = c2
                                                   AND detail->>'reason' = 'Separate branch with its own TRN'), 'confirmed duplicate saved with the reason logged', r::text);
  r := pg_temp.save(bp, jsonb_build_object('card_code', c2, 'email', 'ops@zenith-branch.test'));
  PERFORM pg_temp.check(r->>'card_code' = c2, 'editing other fields doesn''t warn again', r::text);

  -- ---------- Series skips existing codes; supplier ----------
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.business_partner (company_code, card_code, kind, name, source) VALUES ('ZZ99', 'S00001', 'supplier', 'Code taken', 'erp') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  r := pg_temp.save(purch, '{"kind":"supplier","name":"Ningbo Kettle Works","group_code":200,"payment_terms":4,"currency":"AED","country":"CN","phone":"+86 574 1234 5678"}');
  s1 := r->>'card_code';
  PERFORM pg_temp.check(s1 = 'S00002', 'purchasing user creates a supplier; series skips a code in use', r::text);

  -- ---------- SAP / sample partners are read-only ----------
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.business_partner (company_code, card_code, kind, name, source) VALUES ('ZZ99', 'CSAP01', 'customer', 'SAP customer', 'sap') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.save(bp, '{"card_code":"CSAP01","name":"Renamed"}'),
    'This partner comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP.', 'SAP partner can''t be edited');
  PERFORM pg_temp.expect(pg_temp.save(bp, '{"card_code":"C0001","credit_limit":1}'),
    'This partner comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP.', 'sample (SAP stand-in) partner can''t be edited');
  PERFORM pg_temp.check((SELECT name FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'CSAP01') = 'SAP customer', 'SAP row unchanged');
  r := pg_temp.call(bp, $q$SELECT erp.bp_info('ZZ99', 'CSAP01')$q$);
  PERFORM pg_temp.check(NOT (r->>'can_edit')::boolean AND r->>'edit_reason' = 'This partner comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP.',
                        'partner page explains why the SAP partner is read-only');
  PERFORM pg_temp.expect(pg_temp.save(bp, '{"card_code":"NOPE1","name":"x"}'), 'Business partner NOPE1 does not exist in company ZZ99. Check the code.', 'unknown code refused');
  r := pg_temp.call(bpread, format($q$SELECT erp.bp_info('ZZ99', '%s')$q$, c1));
  PERFORM pg_temp.check(NOT (r->>'can_edit')::boolean AND r->>'edit_reason' LIKE 'You have read-only access%' AND jsonb_array_length(r->'history') >= 4
                        AND jsonb_array_length(r->'requests') = 3, 'read-only user sees partner, requests and history but can''t edit', left(r::text, 200));

  -- ---------- Bank details: approval, then A5's 30-day payment block ----------
  PERFORM pg_temp.expect(pg_temp.call(bpread, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bank_name":"Emirates Sample Bank","iban":"AE070331234567890123456"}')$q$, s1)),
    'You have read-only access. Ask the system admin for full access to change bank details.', 'read-only user can''t change bank details');
  PERFORM pg_temp.expect(pg_temp.call(bp, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bank_name":"Emirates Sample Bank","iban":"AE12"}')$q$, s1)),
    'The IBAN AE12 is not valid. It starts with the country code and two check digits, e.g. AE07 0331 2345 6789 0123 456.', 'A5 IBAN check kept');
  r := pg_temp.call(bp, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bank_name":"Emirates Sample Bank","iban":"AE07 0331 2345 6789 0123 456","holder":"Ningbo Kettle Works","reason":"Supplier letter 12 Nov"}')$q$, s1));
  q1 := (r->>'request_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->>'change' = 'added' AND NOT EXISTS (SELECT 1 FROM erp.bp_bank_account WHERE company_code = 'ZZ99' AND card_code = s1)
                        AND NOT EXISTS (SELECT 1 FROM erp.bp_bank_change WHERE company_code = 'ZZ99' AND card_code = s1),
                        'bank details by QA · business partners wait for approval (nothing used yet)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(bp, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bank_name":"Other","account_no":"1"}')$q$, s1)),
    'A bank detail change for S00002 is already waiting for approval. Wait for the decision or cancel it.', 'second bank change refused while one waits');
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'bp_change' AND (w->>'doc_entry')::integer = q1 AND w->>'rule_code' = 'bp_bank_detail'
                                   AND w->>'message' = 'New bank details for S00002 (Ningbo Kettle Works) need approval from QA · finance manager before they are used.'),
                        'bank change in the finance manager''s inbox with its message');
  r := pg_temp.decide(fmgr, q1, 'approved');
  b1 := (r->>'bp_bank_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'change' = 'added' AND b1 IS NOT NULL
                        AND EXISTS (SELECT 1 FROM erp.bp_bank_account WHERE bp_bank_id = b1 AND iban = 'AE070331234567890123456' AND source = 'erp' AND updated_by = bp)
                        AND EXISTS (SELECT 1 FROM erp.bp_bank_change WHERE company_code = 'ZZ99' AND card_code = s1 AND change_kind = 'added' AND changed_by = bp AND changed_at > now() - interval '1 minute'),
                        'approval writes the account and A5''s change log (requester as changer)', left(r::text, 200));
  r := pg_temp.call(fin, format($q$SELECT erp.payment_checks('ZZ99', 'O', '{"card_code":"%s","doc_date":"2026-11-09","transfer":100,"transfer_bank":"BNK-AED"}', '[]')$q$, s1));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') x WHERE x->>'rule_code' = 'bank_change'),
                        'A5 30-day bank-change rule now applies to payments to this supplier', left(r::text, 300));
  r := pg_temp.call(bp, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bp_bank_id":%s,"bank_name":"Emirates Sample Bank","iban":"AE070331234567890123456","holder":"Ningbo Kettle Works Ltd"}')$q$, s1, b1));
  q2 := (r->>'request_id')::integer;
  PERFORM pg_temp.check(r->>'change' = 'changed' AND r->>'state' = 'pending_approval', 'change of an account also waits', left(r::text, 200));
  PERFORM pg_temp.su(format($q$WITH x AS (UPDATE erp.bp_bank_account SET swift = 'XXXXAEAD' WHERE bp_bank_id = %s RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$, coalesce(b1, -1)));
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, q2, 'approved'),
    'The bank details of S00002 changed after this request was made. Reject it and ask for a new request.', 'stale bank request refused at approval');
  r := pg_temp.decide(fmgr, q2, 'rejected', 'Details changed meanwhile');
  PERFORM pg_temp.check(r->>'state' = 'rejected' AND (SELECT holder FROM erp.bp_bank_account WHERE bp_bank_id = b1) = 'Ningbo Kettle Works', 'rejected bank change not applied');
  r := pg_temp.call(fin, format($q$SELECT erp.bp_bank_account_save('ZZ99', '%s', '{"bp_bank_id":%s,"bank_name":"Emirates Sample Bank","iban":"AE070331234567890123456","holder":"NKW","swift":"XXXXAEAD"}')$q$, s1, b1));
  PERFORM pg_temp.check(r->>'change' = 'changed' AND r->>'request_id' IS NULL, 'no rule for QA · finance: applied at once (A5 behaviour)', left(r::text, 200));

  -- ---------- Items ----------
  PERFORM pg_temp.expect(pg_temp.isave(bp, it), 'Your position does not include Inventory. Ask the system admin if you need it.', 'BP-only user can''t create items');
  PERFORM pg_temp.expect(pg_temp.isave(stread, it), 'You have read-only access to items. Ask the system admin for full Inventory access to create or change items.', 'read-only inventory user refused');
  PERFORM pg_temp.expect(pg_temp.isave(sales, it), 'You have read-only access to items. Ask the system admin for full Inventory access to create or change items.', 'sales user can''t create items');
  r := pg_temp.ichk(stock, '{}');
  PERFORM pg_temp.check(pg_temp.err(r, 'item_code') = 'Enter the item code.' AND pg_temp.err(r, 'name') = 'Enter the item description.'
                        AND pg_temp.err(r, 'group_code') = 'Enter the group. It is mandatory in company ZZ99.'
                        AND pg_temp.err(r, 'inventory_uom') = 'Enter the inventory unit. It is mandatory in company ZZ99.', 'item required fields', r->>'errors');
  r := pg_temp.ichk(stock, it || '{"item_code":"bad code!","group_code":5,"firm_code":9,"barcode":"12 34","hs_code":"85A","moq":-1,"pcs_20gp":1.5,"sourcing_type":"JIT",
                                   "preferred_supplier":"C0001","tax_code":"ZZ","sales_uom":"a-very-long-unit-name-x"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'item_code') = 'The item code may use letters, digits, dot, dash, slash and underscore (50 characters at most).'
                        AND pg_temp.err(r, 'group_code') = 'Item group 5 does not exist in company ZZ99.'
                        AND pg_temp.err(r, 'firm_code') = 'Brand 9 does not exist in company ZZ99.'
                        AND pg_temp.err(r, 'barcode') = 'The barcode may use letters, digits and dashes only (4 to 50 characters).'
                        AND pg_temp.err(r, 'hs_code') = 'The HS code must have 6 to 12 digits, e.g. 8516.61.00.'
                        AND pg_temp.err(r, 'moq') = 'Enter the MOQ as a number of 0 or more.'
                        AND pg_temp.err(r, 'pcs_20gp') = 'Enter the 20GP container quantity as a whole number of 0 or more.'
                        AND pg_temp.err(r, 'sourcing_type') = 'Sourcing type must be one of: OEM, ODM.'
                        AND pg_temp.err(r, 'preferred_supplier') = 'Preferred supplier C0001 is not a supplier in company ZZ99.'
                        AND pg_temp.err(r, 'tax_code') = 'Tax code ZZ does not exist or is inactive in company ZZ99.'
                        AND pg_temp.err(r, 'sales_uom') = 'The sales unit is too long (20 characters at most).', 'every item field validated', r->>'errors');
  r := pg_temp.ichk(stock, it || '{"batch_managed":true,"serial_managed":true}');
  PERFORM pg_temp.check(pg_temp.err(r, 'serial_managed') = 'An item is managed by batches or by serial numbers, not both.', 'batch and serial exclusive');
  r := pg_temp.ichk(stock, it || '{"is_stock":false}');
  PERFORM pg_temp.check(pg_temp.err(r, 'is_stock') = 'Only inventory items can be managed by batches or serial numbers.', 'serials only for stock items');
  r := pg_temp.ichk(stock, it || '{"barcode":"6299448074725"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'barcode') = 'Barcode 6299448074725 is already used by item SMP-1010 · Rice cooker 1.8 L. A barcode must be unique in the company.',
                        'barcode unique per company', r->>'errors');
  PERFORM pg_temp.expect(pg_temp.isave(stock, it || '{"item_code":"SMP-1010"}'), 'Item SMP-1010 already exists in company ZZ99.', 'item code must be new');
  r := pg_temp.isave(stock, it);
  PERFORM pg_temp.check(r->>'item_code' = 'A8-KETTLE-01' AND (SELECT source = 'erp' AND sourcing_type = 'ODM' AND sales_uom = 'PCS' AND tax_code = 'SR' AND serial_managed
                                                               AND pcs_40hq = 3600 AND category = 'Kitchen appliances'
                                                          FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'A8-KETTLE-01'),
                        'item created (code upper case, units, tax code, serials)', r::text);
  r := pg_temp.ichk(purch, it || '{"item_code":"A8-KETTLE-02","barcode":"6291000000024","supplier_part_no":"fs-gk-17"}');
  PERFORM pg_temp.check(r->'duplicates'->0->>'item_code' = 'A8-KETTLE-01' AND r->'duplicates'->0->>'match' = 'supplier_part_no', 'same supplier part number warned', r->>'duplicates');
  PERFORM pg_temp.expect(pg_temp.isave(purch, it || '{"item_code":"A8-KETTLE-02","barcode":"6291000000024","supplier_part_no":"fs-gk-17"}'),
    'Supplier part number fs-gk-17 is already used by item A8-KETTLE-01 · Glass kettle 1.7 L. Check it and confirm with a reason to save anyway.', 'duplicate part number needs a reason');
  r := pg_temp.isave(purch, it || '{"item_code":"A8-KETTLE-02","barcode":"6291000000024","supplier_part_no":"fs-gk-17"}', 'Same part, different colour');
  PERFORM pg_temp.check(r->>'item_code' = 'A8-KETTLE-02' AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'item_duplicate_confirmed' AND object_ref = 'A8-KETTLE-02'),
                        'purchasing user saves with a reason (logged)', r::text);
  r := pg_temp.isave(stock, '{"item_code":"A8-KETTLE-01","edit":true,"name":"Glass kettle 1.7 L (blue)","moq":500}');
  PERFORM pg_temp.check((r->'changed') ?& ARRAY['name', 'moq'] AND NOT (r->'changed') ? 'barcode'
                        AND (SELECT moq = 500 AND barcode = '6291000000017' FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'A8-KETTLE-01'),
                        'item edit changes only what was sent', r::text);
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_hand, committed, on_order) VALUES ('ZZ99', 'A8-KETTLE-01', 'WH01', 5, 0, 0) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.isave(stock, '{"item_code":"A8-KETTLE-01","edit":true,"serial_managed":false}'),
    'A8-KETTLE-01 has stock on hand. Its batch / serial management can''t change until the stock is zero.', 'serial management fixed while stock exists');
  PERFORM pg_temp.expect(pg_temp.isave(stock, '{"item_code":"A8-KETTLE-01","edit":true,"is_stock":false,"serial_managed":false}'),
    'A8-KETTLE-01 has stock on hand. Its batch / serial management can''t change until the stock is zero.', 'stock item stays stock item while stock exists');
  PERFORM pg_temp.expect(pg_temp.isave(stock, '{"item_code":"SMP-1010","edit":true,"name":"x"}'),
    'This item comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP.', 'SAP / sample item can''t be edited');
  r := pg_temp.call(stread, $q$SELECT erp.item_info('ZZ99', 'A8-KETTLE-01')$q$);
  PERFORM pg_temp.check(NOT (r->>'can_edit')::boolean AND r->'item'->>'tax_name' = 'Standard rated 5%' AND jsonb_array_length(r->'history') = 2,
                        'item page: read-only reason, code names, history', left(r::text, 200));
  r := pg_temp.call(stock, $q$SELECT erp.item_info('ZZ99', 'SMP-1010')$q$);
  PERFORM pg_temp.check(r->>'edit_reason' = 'This item comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP.', 'item page explains SAP read-only');

  -- ---------- Settings ----------
  PERFORM pg_temp.expect(pg_temp.call(bp, $q$SELECT erp.master_setting_set('ZZ99', '{"bp_required":["trn"]}')$q$),
    'Only a system admin with full Administration access can change master data settings.', 'settings need Administration');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.master_setting_set('ZZ99', '{"bp_required":["balance"]}')$q$),
    'Partner field balance can''t be made mandatory.', 'unknown mandatory field refused');
  r := pg_temp.call(admin, $q$SELECT erp.master_setting_set('ZZ99', '{"bp_required":["group_code","payment_terms","trn"]}')$q$);
  r2 := pg_temp.chk(bp, base || '{"trn":null}');
  PERFORM pg_temp.check(pg_temp.err(r2, 'trn') = 'Enter the TRN. It is mandatory in company ZZ99.' AND r->>'dup_name_similarity' = '0.800', 'admin makes TRN mandatory', left(r::text, 200));

  -- ---------- Direct writes stay closed; trademark list ----------
  r := pg_temp.call(bp, $q$WITH x AS (UPDATE erp.business_partner SET credit_limit = 1 WHERE company_code = 'ZZ99' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct table writes', r::text);
  r := pg_temp.call(bp, $q$WITH x AS (INSERT INTO erp.bp_change_request (company_code, card_code, kind, after, requested_by) VALUES ('ZZ99', 'C00001', 'credit_limit', '{}', gen_random_uuid()) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct request writes', r::text);
  r := pg_temp.call(bp, $q$SELECT to_jsonb(count(*)) FROM erp.trademark WHERE company_code = 'ZZ99'$q$);
  PERFORM pg_temp.check((r #>> '{}')::int = 2, 'Trademark Master readable (migrated rows)', r::text);
  r := pg_temp.call(stock, $q$SELECT to_jsonb(count(*)) FROM erp.bp_change_request$q$);
  PERFORM pg_temp.check((r #>> '{}')::int = 0, 'inventory user can''t read partner change requests', r::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = 'ZZ99' AND source IN ('sap', 'sample')
                                      AND card_code IN (SELECT object_ref FROM erp.audit_log WHERE action IN ('bp_update', 'bp_credit_limit_change'))),
                        'no SAP or sample partner changed');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a8_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a8_result;
ROLLBACK;

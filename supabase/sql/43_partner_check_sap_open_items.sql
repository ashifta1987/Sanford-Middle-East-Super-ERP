-- 43 · partner check on SAP's own open items (14 Nov 2026, AE05 review). Replaces erp._mc_partners from 27_migration_more.sql.
-- SAP's open item per partner is the open part of its journal lines (JDT1 BalDueDeb - BalDueCred), not DocTotal - PaidToDate
-- of the documents: invoices settled by a journal entry or an internal reconciliation stay "open" as documents, and balances
-- posted by journal entries have no document. Control accounts are the partners' OCRD.DebPayAcct, not every account a partner
-- line touched. Checks per partner: OCRD balance = SAP journal = SAP open journal lines = app journal lines.
-- Partners whose open documents differ from the open journal lines are reported once (the app's aging still reads documents).
CREATE OR REPLACE FUNCTION erp._mc_partners(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; d record; parts text[] := '{}'; r record; k text; v_ok boolean; q text; v_open text;
        n_bad int := 0; n_docs int := 0; s record; v_ctl numeric; v_ctl_app numeric; v_accts text[];
BEGIN
  IF NOT erp._mig_has('OCRD', 'CardCode', 'CardType', 'Balance') OR NOT erp._mig_has('JDT1', 'Account', 'ShortName', 'Debit', 'Credit') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'partners', 'partner balances = open items', 'needs OCRD (CardCode, CardType, Balance) and JDT1 in the SAP copy')];
  END IF;
  -- SAP open items: open part of the journal lines; without BalDue columns fall back to the journal balance
  v_open := CASE WHEN erp._mig_has('JDT1', 'BalDueDeb', 'BalDueCred') THEN 'coalesce("BalDueDeb", 0) - coalesce("BalDueCred", 0)'
                 ELSE 'coalesce("Debit", 0) - coalesce("Credit", 0)' END;
  -- open documents (for the aging note only)
  FOR d IN SELECT * FROM (VALUES ('OINV', 1), ('ODPI', 1), ('ORIN', -1), ('OPCH', -1), ('ODPO', -1), ('ORPC', 1)) x(t, m) LOOP
    IF erp._mig_has(d.t, 'CardCode', 'DocTotal', 'PaidToDate', 'CANCELED', 'DocStatus') THEN
      parts := parts || format('SELECT "CardCode" c, %s * ("DocTotal" - coalesce("PaidToDate", 0)) v FROM sap.%I WHERE company_code = $1 '
                               'AND coalesce("CANCELED", ''N'') NOT IN (''Y'', ''C'') AND coalesce("DocStatus", ''O'') <> ''C''', d.m, d.t);
    END IF;
  END LOOP;
  q := format($q$
    WITH bp AS (SELECT "CardCode" c, "CardType" k, coalesce("Balance", 0) b FROM sap."OCRD" WHERE company_code = $1 AND "CardType" IN ('C', 'S')),
         jr AS (SELECT "ShortName" c, sum(coalesce("Debit", 0) - coalesce("Credit", 0)) j, sum(%s) o FROM sap."JDT1"
                 WHERE company_code = $1 AND "ShortName" IS DISTINCT FROM "Account" GROUP BY 1),
         aj AS (SELECT l.short_name c, sum(coalesce(l.debit, 0) - coalesce(l.credit, 0)) v FROM erp.journal_line l
                  JOIN erp.journal_entry e USING (company_code, trans_id)
                 WHERE l.company_code = $1 AND e.source = 'sap' AND l.short_name IS DISTINCT FROM l.acct_code GROUP BY 1),
         dc AS (SELECT c, sum(v) v FROM (%s) x GROUP BY 1)
    SELECT bp.c, bp.k, bp.b, coalesce(jr.j, 0) jrv, coalesce(jr.o, 0) rv, coalesce(aj.v, 0) av, coalesce(dc.v, 0) dv
      FROM bp LEFT JOIN jr ON jr.c = bp.c LEFT JOIN aj ON aj.c = bp.c LEFT JOIN dc ON dc.c = bp.c ORDER BY bp.k, bp.c $q$,
    v_open, CASE WHEN cardinality(parts) = 0 THEN 'SELECT NULL::text c, 0::numeric v WHERE false' ELSE array_to_string(parts, ' UNION ALL ') END);
  CREATE TEMP TABLE IF NOT EXISTS _mc_bp2 (c text, kind text, b numeric, jrv numeric, rv numeric, av numeric, dv numeric, ok boolean) ON COMMIT DROP;
  TRUNCATE _mc_bp2;
  FOR r IN EXECUTE q USING co LOOP
    v_ok := erp._mig_eq(r.b, r.jrv) AND erp._mig_eq(r.jrv, r.rv) AND erp._mig_eq(r.av, r.jrv);
    INSERT INTO _mc_bp2 VALUES (r.c, r.k, r.b, r.jrv, r.rv, r.av, r.dv, v_ok);
    IF NOT erp._mig_eq(r.dv, r.rv) THEN n_docs := n_docs + 1; END IF;
    IF NOT v_ok THEN
      n_bad := n_bad + 1;
      IF n_bad <= 500 THEN
        PERFORM erp._mig_check(p_run, co, 'partners', 'partner balance ' || r.c, r.b, r.rv, r.av, false,
                               jsonb_build_object('card_code', r.c, 'kind', r.k, 'journal_balance', r.jrv, 'open_documents', r.dv));
      END IF;
      IF n_bad <= 100 THEN
        k := 'bp:' || co || ':' || r.c; f := f || k;
        PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: balance of %s does not match its open items', co, r.c),
                format('SAP balance (OCRD) %s, SAP journal %s, SAP open journal lines %s, app journal lines %s', r.b, r.jrv, r.rv, r.av), 'OCRD');
      END IF;
    END IF;
  END LOOP;
  IF n_bad > 100 THEN
    k := 'bp_more:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: %s more partners do not match their open items', co, n_bad - 100),
            'Only the first 100 are listed one by one. Export the check list for all of them.', 'OCRD');
  END IF;
  IF n_docs > 0 THEN
    k := 'bp_docs:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'warning', 'partners', k,
            format('%s: %s partners have open documents that differ from SAP''s open items', co, n_docs),
            'Settled in SAP by journal entries or internal reconciliation while the invoices stay open, or balances posted by journal entries. '
            'SAP''s open items (journal lines) are used for the balances; the app''s A/R and A/P aging still reads open documents.', 'OCRD');
  END IF;
  -- per kind totals and the control accounts (the partners' own control accounts)
  FOR s IN SELECT x.k, x.label, x.ctl FROM (VALUES ('C', 'customer balances = open items', 'A/R control accounts = open customer items'),
                                                ('S', 'supplier balances = open items', 'A/P control accounts = open supplier items')) x(k, label, ctl) LOOP
    SELECT count(*) n, count(*) FILTER (WHERE NOT _mc_bp2.ok) bad, coalesce(sum(b), 0) b, coalesce(sum(rv), 0) rv, coalesce(sum(av), 0) av INTO r FROM _mc_bp2 WHERE _mc_bp2.kind = s.k;
    PERFORM erp._mig_check(p_run, co, 'partners', s.label, r.b, r.rv, r.av, r.bad = 0, jsonb_build_object('partners', r.n, 'differing', r.bad));
    IF erp._mig_has('OCRD', 'DebPayAcct') THEN
      EXECUTE 'SELECT array_agg(DISTINCT "DebPayAcct") FROM sap."OCRD" WHERE company_code = $1 AND "CardType" = $2 AND "DebPayAcct" IS NOT NULL'
        INTO v_accts USING co, s.k;
    ELSE
      EXECUTE 'SELECT array_agg(DISTINCT j."Account") FROM sap."JDT1" j JOIN sap."OCRD" b ON b.company_code = j.company_code AND b."CardCode" = j."ShortName"
                WHERE j.company_code = $1 AND j."ShortName" <> j."Account" AND b."CardType" = $2' INTO v_accts USING co, s.k;
    END IF;
    EXECUTE 'SELECT coalesce(sum(coalesce("Debit", 0) - coalesce("Credit", 0)), 0) FROM sap."JDT1" WHERE company_code = $1 AND "Account" = ANY ($2)'
      INTO v_ctl USING co, coalesce(v_accts, '{}');
    SELECT coalesce(sum(l.debit - l.credit), 0) INTO v_ctl_app FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
     WHERE l.company_code = co AND e.source = 'sap' AND l.acct_code = ANY (coalesce(v_accts, '{}'));
    v_ok := erp._mig_eq(v_ctl, r.rv) AND erp._mig_eq(v_ctl_app, v_ctl);
    PERFORM erp._mig_check(p_run, co, 'partners', s.ctl, v_ctl, r.rv, v_ctl_app, v_ok,
                           jsonb_build_object('accounts', to_jsonb(coalesce(v_accts, '{}')), 'sap', 'control account balance (JDT1)',
                                              'raw', 'open items in SAP (open journal lines)', 'app', 'control account balance (app journals)'));
    IF NOT v_ok THEN
      k := 'ctl:' || co || ':' || s.k; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: %s do not match', co, s.ctl),
              format('control accounts %s: SAP %s, app %s; open items in SAP %s', array_to_string(coalesce(v_accts, '{}'), ', '), v_ctl, v_ctl_app, r.rv));
    END IF;
  END LOOP;
  RETURN f;
END $$;

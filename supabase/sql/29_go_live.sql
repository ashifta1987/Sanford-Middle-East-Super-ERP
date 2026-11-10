-- A14 · Deploy and go-live. Safe to run twice. Does not edit 10–28.
-- Replaces (CREATE OR REPLACE): erp.company_go_live (all earlier checks and messages kept, plus: checklist steps 2–5 done).
--
-- Go-live checklist per company (A14 prompt, "Go-live per company"):
--   1 Migration run signed off by Finance, IT and Business ......... worked out: a signed_off erp.migration_run
--   2 Ashif's written approval to import production data ............ ticked by an admin, with the approval reference
--   3 Users invited, positions and limits set, test sign-in done .... ticked; needs >= 1 active user with access
--   4 Opening balances reconciled (plan §5) .......................... ticked
--   5 SAP posting frozen; final backup → final run → reconcile → sign  ticked, with the final backup reference
--   6 Go-live date recorded (erp.company_cutover) ................... worked out; set by erp.company_go_live (CFO)
--   7 Hypercare (2 weeks): daily reconciliation, issue list ......... ticked after 14 days with no open issue
-- Steps are done in order. Steps 2–5 lock when the company goes live.
--
-- Access: read = Administration, IT or owner (erp._adm_guard(false)) on a company the user can see.
--         write = Administration full (erp._adm_guard(true)). Go-live itself stays with the business (CFO) signer.
--
-- Also: erp.schema_release (which SQL file went to which environment, when, by whom; written only by the service role
-- or the SQL editor via erp.schema_release_record) and erp.system_health() (read-only monitoring for admin / IT).
-- Hardening: SECURITY DEFINER helpers from 12 and 27 are no longer executable by anon (authenticated keeps them).

GRANT USAGE ON SCHEMA erp TO service_role;

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.go_live_step (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    step           smallint NOT NULL CHECK (step IN (2, 3, 4, 5, 7)),
    done           boolean NOT NULL DEFAULT false,
    note           text,
    evidence       text,
    done_by        uuid,
    done_at        timestamptz,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, step)
);

CREATE TABLE IF NOT EXISTS erp.go_live_issue (
    issue_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    title          text NOT NULL,
    severity       text NOT NULL DEFAULT 'normal' CHECK (severity IN ('critical', 'normal')),
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'fixed')),
    raised_by      uuid NOT NULL,
    raised_at      timestamptz NOT NULL DEFAULT now(),
    fixed_by       uuid,
    fixed_at       timestamptz,
    fix_note       text
);
CREATE INDEX IF NOT EXISTS go_live_issue_company_idx ON erp.go_live_issue (company_code, status);

CREATE TABLE IF NOT EXISTS erp.schema_release (
    release_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_name      text NOT NULL CHECK (file_name ~ '^[0-9]{2}_[a-z0-9_]+\.sql$'),
    environment    text NOT NULL CHECK (environment IN ('local', 'branch', 'test', 'live')),
    applied_at     timestamptz NOT NULL DEFAULT now(),
    applied_by     text NOT NULL,
    note           text
);

ALTER TABLE erp.go_live_step ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.go_live_issue ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.schema_release ENABLE ROW LEVEL SECURITY;
-- Read and write only through the functions below.
REVOKE ALL ON erp.go_live_step, erp.go_live_issue, erp.schema_release FROM PUBLIC, anon, authenticated;
GRANT ALL ON erp.go_live_step, erp.go_live_issue, erp.schema_release TO service_role;

-- ============ Hardening: definer helpers not callable by anon ============
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'erp' AND p.proname IN ('has_module', 'my_emp', 'my_hr_code', '_sync_keep_own', '_sync_keep_child')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f);
    IF f::text NOT LIKE 'erp._sync_keep%' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
END $$;

-- ============ Helpers ============
CREATE OR REPLACE FUNCTION erp._gl_titles() RETURNS TABLE (step smallint, title text, auto boolean)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    (1::smallint, 'Migration run signed off by Finance, IT and Business', true),
    (2::smallint, 'Ashif''s written approval to import production data', false),
    (3::smallint, 'Users invited, positions and limits set, test sign-in done', false),
    (4::smallint, 'Opening balances reconciled', false),
    (5::smallint, 'SAP posting frozen, final backup, final run, reconciled and signed', false),
    (6::smallint, 'Go-live date recorded', true),
    (7::smallint, 'Hypercare finished (2 weeks)', false)) AS v(step, title, auto)
$$;

-- Done state of all 7 steps for a company (no access check: callers check first).
CREATE OR REPLACE FUNCTION erp._gl_done(p_company varchar) RETURNS TABLE (step smallint, done boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT t.step,
         CASE t.step
           WHEN 1 THEN EXISTS (SELECT 1 FROM erp.migration_run r WHERE r.company_code = p_company AND r.status = 'signed_off')
           WHEN 6 THEN EXISTS (SELECT 1 FROM erp.company_cutover k WHERE k.company_code = p_company)
           ELSE coalesce((SELECT s.done FROM erp.go_live_step s WHERE s.company_code = p_company AND s.step = t.step), false)
         END
    FROM erp._gl_titles() t
$$;

-- First step before p_step that is not done (NULL when all earlier steps are done).
CREATE OR REPLACE FUNCTION erp._gl_missing(p_company varchar, p_step smallint) RETURNS smallint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT min(d.step) FROM erp._gl_done(p_company) d WHERE d.step < p_step AND NOT d.done
$$;

CREATE OR REPLACE FUNCTION erp._gl_title(p_step smallint) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT title FROM erp._gl_titles() WHERE step = p_step
$$;

CREATE OR REPLACE FUNCTION erp._gl_fmt(p_d timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT to_char(p_d AT TIME ZONE 'Asia/Dubai', 'DD Mon YYYY')
$$;

REVOKE ALL ON FUNCTION erp._gl_titles(), erp._gl_done(varchar), erp._gl_missing(varchar, smallint), erp._gl_title(smallint),
                       erp._gl_fmt(timestamptz) FROM PUBLIC, anon, authenticated;

-- ============ Read: overview of every company the user can see ============
CREATE OR REPLACE FUNCTION erp.go_live_overview() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'company_code', c.company_code, 'company_name', c.legal_name, 'active', c.active,
             'steps_done', (SELECT count(*) FROM erp._gl_done(c.company_code) d WHERE d.done),
             'steps_total', 7,
             'next_step', (SELECT min(d.step) FROM erp._gl_done(c.company_code) d WHERE NOT d.done),
             'go_live_at', k.go_live_at,
             'hypercare_until', k.go_live_at + interval '14 days',
             'open_issues', (SELECT count(*) FROM erp.go_live_issue i WHERE i.company_code = c.company_code AND i.status = 'open'))
           ORDER BY c.company_code)
      FROM erp.company c
      LEFT JOIN erp.company_cutover k ON k.company_code = c.company_code
     WHERE erp.can_see(c.company_code)), '[]'::jsonb);
END $$;

-- ============ Read: checklist of one company ============
CREATE OR REPLACE FUNCTION erp.go_live_checklist(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c erp.company;
  k erp.company_cutover;
  v_run jsonb;
  v_users jsonb;
BEGIN
  PERFORM erp._adm_guard(false);
  c := erp._adm_company(p_company);
  SELECT * INTO k FROM erp.company_cutover WHERE company_code = p_company;

  SELECT jsonb_build_object('run_id', r.run_id, 'status', r.status, 'kind', r.kind, 'created_at', r.created_at, 'finished_at', r.finished_at,
           'signoffs', coalesce((SELECT jsonb_agg(jsonb_build_object('role', s.role, 'decision', s.decision, 'signed_at', s.signed_at,
                                                                     'signed_by', erp._adm_name(s.signed_by)) ORDER BY s.role)
                                  FROM erp.migration_signoff s WHERE s.run_id = r.run_id), '[]'::jsonb))
    INTO v_run
    FROM erp.migration_run r
   WHERE r.company_code = p_company
   ORDER BY (r.status = 'signed_off') DESC, r.created_at DESC
   LIMIT 1;

  SELECT jsonb_build_object(
           'active', count(*) FILTER (WHERE u.active),
           'positions', count(DISTINCT u.position_code) FILTER (WHERE u.active),
           'pending_invites', (SELECT count(*) FROM erp.user_invite i WHERE i.company_code = p_company AND i.state IN ('pending', 'sent') AND i.user_id IS NULL))
    INTO v_users
    FROM erp.user_company uc JOIN erp.app_user u ON u.user_id = uc.user_id
   WHERE uc.company_code = p_company;

  RETURN jsonb_build_object(
    'company_code', c.company_code, 'company_name', c.legal_name,
    'can_write', erp.can_write('admin'),
    'can_go_live', erp.migration_can_sign('business'),
    'live', k.company_code IS NOT NULL,
    'go_live_at', k.go_live_at, 'go_live_by', erp._adm_name(k.go_live_by), 'go_live_run', k.go_live_run,
    'hypercare_until', k.go_live_at + interval '14 days',
    'run', v_run,
    'users', v_users,
    'steps', (SELECT jsonb_agg(jsonb_build_object(
                'step', t.step, 'title', t.title, 'auto', t.auto, 'done', d.done,
                'note', s.note, 'evidence', s.evidence, 'done_at', CASE WHEN t.step = 6 THEN k.go_live_at ELSE s.done_at END,
                'done_by', CASE WHEN t.step = 6 THEN erp._adm_name(k.go_live_by) ELSE erp._adm_name(s.done_by) END,
                'updated_at', s.updated_at,
                'waiting_for', (SELECT min(d2.step) FROM erp._gl_done(p_company) d2 WHERE d2.step < t.step AND NOT d2.done))
              ORDER BY t.step)
                FROM erp._gl_titles() t
                JOIN erp._gl_done(p_company) d ON d.step = t.step
                LEFT JOIN erp.go_live_step s ON s.company_code = p_company AND s.step = t.step),
    'issues', coalesce((SELECT jsonb_agg(jsonb_build_object('issue_id', i.issue_id, 'title', i.title, 'severity', i.severity, 'status', i.status,
                                 'raised_by', erp._adm_name(i.raised_by), 'raised_at', i.raised_at,
                                 'fixed_by', erp._adm_name(i.fixed_by), 'fixed_at', i.fixed_at, 'fix_note', i.fix_note)
                               ORDER BY (i.status = 'open') DESC, i.raised_at DESC)
                          FROM erp.go_live_issue i WHERE i.company_code = p_company), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(x ORDER BY x->>'at' DESC) FROM (
                  SELECT jsonb_build_object('at', a.at, 'action', a.action, 'by', erp._adm_name(nullif(a.actor, '')::uuid), 'detail', a.detail) x
                    FROM erp.audit_log a
                   WHERE a.company_code = p_company AND a.action IN ('go_live_step_done', 'go_live_step_reopened', 'company_go_live',
                                                                      'go_live_issue_raised', 'go_live_issue_fixed')
                     AND a.actor ~ '^[0-9a-f-]{36}$'
                   ORDER BY a.at DESC LIMIT 30) q), '[]'::jsonb));
END $$;

-- ============ Write: tick or reopen a step ============
CREATE OR REPLACE FUNCTION erp.go_live_step_set(p_company varchar, p_step integer, p_done boolean, p_note text DEFAULT NULL, p_evidence text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.company;
  k erp.company_cutover;
  v_step smallint;
  v_cur boolean;
  v_missing smallint;
  v_later smallint;
  v_open bigint;
  v_note text := nullif(btrim(p_note), '');
  v_ev text := nullif(btrim(p_evidence), '');
BEGIN
  u := erp._adm_guard(true);
  c := erp._adm_company(p_company);
  IF p_step IS NULL OR p_step NOT BETWEEN 1 AND 7 THEN
    RAISE EXCEPTION 'There is no step %. The checklist has steps 1 to 7.', coalesce(p_step::text, '(none)') USING ERRCODE = 'P0001';
  END IF;
  v_step := p_step;
  IF v_step IN (1, 6) THEN
    RAISE EXCEPTION 'Step % is worked out by the system and can''t be ticked by hand.', v_step USING ERRCODE = 'P0001',
      HINT = CASE v_step WHEN 1 THEN 'Sign off the migration run in the console.' ELSE 'The CFO records go-live with the Go live button.' END;
  END IF;
  IF p_done IS NULL THEN
    RAISE EXCEPTION 'Say whether the step is done or reopened.' USING ERRCODE = 'P0001';
  END IF;
  IF length(coalesce(v_note, '')) > 1000 OR length(coalesce(v_ev, '')) > 500 THEN
    RAISE EXCEPTION 'The note is too long. Keep it under 1,000 characters (reference under 500).' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;   -- one checklist change at a time per company
  SELECT * INTO k FROM erp.company_cutover WHERE company_code = p_company;
  SELECT s.done INTO v_cur FROM erp.go_live_step s WHERE s.company_code = p_company AND s.step = v_step;
  v_cur := coalesce(v_cur, false);

  IF v_step BETWEEN 2 AND 5 AND k.company_code IS NOT NULL THEN
    RAISE EXCEPTION '% is already live, so steps before go-live can no longer change.', p_company USING ERRCODE = 'P0001';
  END IF;

  IF p_done THEN
    IF v_cur THEN
      RAISE EXCEPTION 'Step % is already done.', v_step USING ERRCODE = 'P0001';
    END IF;
    v_missing := erp._gl_missing(p_company, v_step);
    IF v_step = 7 AND k.company_code IS NULL THEN
      RAISE EXCEPTION 'Hypercare starts at go-live. % is not live yet.', p_company USING ERRCODE = 'P0001';
    END IF;
    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'Finish step % first: %.', v_missing, erp._gl_title(v_missing) USING ERRCODE = 'P0001';
    END IF;
    IF v_step = 2 AND v_ev IS NULL THEN
      RAISE EXCEPTION 'Add where Ashif''s written approval is kept (for example the email date and subject).' USING ERRCODE = 'P0001';
    END IF;
    IF v_step = 3 THEN
      IF NOT EXISTS (SELECT 1 FROM erp.user_company uc JOIN erp.app_user au ON au.user_id = uc.user_id
                      WHERE uc.company_code = p_company AND au.active AND au.position_code IS NOT NULL AND au.user_id <> u.user_id) THEN
        RAISE EXCEPTION 'No other active user has access to % yet. Invite the department heads and give them positions first.', p_company
          USING ERRCODE = 'P0001';
      END IF;
      SELECT count(*) INTO v_open FROM erp.user_invite i
       WHERE i.company_code = p_company AND i.state IN ('pending', 'sent') AND i.user_id IS NULL;
      IF v_open > 0 THEN
        RAISE EXCEPTION '% invitation(s) for % are still waiting to be accepted. Wait for them or cancel them first.', v_open, p_company
          USING ERRCODE = 'P0001';
      END IF;
    END IF;
    IF v_step = 5 AND v_ev IS NULL THEN
      RAISE EXCEPTION 'Add the final backup reference (backup name or time) before marking this step done.' USING ERRCODE = 'P0001';
    END IF;
    IF v_step = 7 THEN
      IF now() < k.go_live_at + interval '14 days' THEN
        RAISE EXCEPTION 'Hypercare runs for 2 weeks after go-live, until %.', erp._gl_fmt(k.go_live_at + interval '14 days') USING ERRCODE = 'P0001';
      END IF;
      SELECT count(*) INTO v_open FROM erp.go_live_issue WHERE company_code = p_company AND status = 'open';
      IF v_open > 0 THEN
        RAISE EXCEPTION 'Close the % open hypercare issue(s) first.', v_open USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSE
    IF NOT v_cur THEN
      RAISE EXCEPTION 'Step % is not done yet.', v_step USING ERRCODE = 'P0001';
    END IF;
    IF v_note IS NULL THEN
      RAISE EXCEPTION 'Say why this step is being reopened.' USING ERRCODE = 'P0001';
    END IF;
    SELECT max(s.step) INTO v_later FROM erp.go_live_step s WHERE s.company_code = p_company AND s.step > v_step AND s.done;
    IF v_later IS NOT NULL THEN
      RAISE EXCEPTION 'Reopen step % first: it comes after this one.', v_later USING ERRCODE = 'P0001';
    END IF;
  END IF;

  INSERT INTO erp.go_live_step AS s (company_code, step, done, note, evidence, done_by, done_at, updated_by, updated_at)
  VALUES (p_company, v_step, p_done, v_note, CASE WHEN p_done THEN v_ev END,
          CASE WHEN p_done THEN u.user_id END, CASE WHEN p_done THEN now() END, u.user_id, now())
  ON CONFLICT (company_code, step) DO UPDATE
     SET done = EXCLUDED.done, note = EXCLUDED.note,
         evidence = CASE WHEN EXCLUDED.done THEN EXCLUDED.evidence ELSE s.evidence END,
         done_by = EXCLUDED.done_by, done_at = EXCLUDED.done_at, updated_by = EXCLUDED.updated_by, updated_at = now();

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_done THEN 'go_live_step_done' ELSE 'go_live_step_reopened' END, 'go_live_step', v_step::text,
          jsonb_build_object('step', v_step, 'title', erp._gl_title(v_step), 'note', v_note, 'evidence', v_ev));

  RETURN jsonb_build_object('company_code', p_company, 'step', v_step, 'done', p_done);
END $$;

-- ============ Write: hypercare issues ============
CREATE OR REPLACE FUNCTION erp.go_live_issue_save(p_company varchar, p_issue jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.company;
  v_title text := nullif(btrim(p_issue->>'title'), '');
  v_sev text := coalesce(nullif(btrim(p_issue->>'severity'), ''), 'normal');
  v_id bigint;
BEGIN
  u := erp._adm_guard(true);
  c := erp._adm_company(p_company);
  IF NOT EXISTS (SELECT 1 FROM erp.company_cutover WHERE company_code = p_company) THEN
    RAISE EXCEPTION 'Hypercare issues can be logged once % is live. Before that, use the migration issue list.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'Describe the issue in a few words.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_title) > 300 THEN
    RAISE EXCEPTION 'Keep the issue under 300 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF v_sev NOT IN ('critical', 'normal') THEN
    RAISE EXCEPTION 'Severity must be critical or normal.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.go_live_issue (company_code, title, severity, raised_by) VALUES (p_company, v_title, v_sev, u.user_id)
  RETURNING issue_id INTO v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'go_live_issue_raised', 'go_live_issue', v_id::text, jsonb_build_object('title', v_title, 'severity', v_sev));
  RETURN jsonb_build_object('issue_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION erp.go_live_issue_close(p_company varchar, p_issue_id bigint, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.company;
  i erp.go_live_issue;
  v_note text := nullif(btrim(p_note), '');
BEGIN
  u := erp._adm_guard(true);
  c := erp._adm_company(p_company);
  SELECT * INTO i FROM erp.go_live_issue WHERE issue_id = p_issue_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Issue % was not found for %.', coalesce(p_issue_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF i.status = 'fixed' THEN
    RAISE EXCEPTION 'Issue % is already closed.', p_issue_id USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Say how the issue was fixed.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.go_live_issue SET status = 'fixed', fixed_by = u.user_id, fixed_at = now(), fix_note = left(v_note, 1000) WHERE issue_id = p_issue_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'go_live_issue_fixed', 'go_live_issue', p_issue_id::text, jsonb_build_object('note', v_note));
  RETURN jsonb_build_object('issue_id', p_issue_id, 'status', 'fixed');
END $$;

-- ============ Go live: same as 14_console_views.sql, plus the checklist gate ============
CREATE OR REPLACE FUNCTION erp.company_go_live(p_company varchar, p_run uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE r erp.migration_run; v_at timestamptz; v_missing smallint;
BEGIN
  IF erp.current_user_id() IS NULL THEN RAISE EXCEPTION 'go-live needs a signed-in user' USING ERRCODE = '42501'; END IF;
  IF NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'company % is not in your company list', p_company USING ERRCODE = '42501'; END IF;
  IF NOT erp.migration_can_sign('business') THEN
    RAISE EXCEPTION 'only the business (CFO) signer can take a company live' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO r FROM erp.migration_run WHERE run_id = p_run FOR UPDATE;
  IF NOT FOUND OR r.company_code <> p_company THEN RAISE EXCEPTION 'run % is not a run of %', p_run, p_company; END IF;
  IF r.status <> 'signed_off' THEN RAISE EXCEPTION 'run is %, go-live needs a signed-off run', r.status; END IF;
  PERFORM 1 FROM erp.company_cutover WHERE company_code = p_company FOR UPDATE;
  IF FOUND THEN RAISE EXCEPTION 'company % is already live', p_company; END IF;
  -- A14: the go-live checklist (steps 2–5; step 1 is the signed-off run checked above) must be complete.
  v_missing := erp._gl_missing(p_company, 6::smallint);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Finish the go-live checklist first: step % (%) is not done.', v_missing, erp._gl_title(v_missing)
      USING ERRCODE = 'P0001', HINT = 'Administration › Implementation Center › Go-live checklist.';
  END IF;
  INSERT INTO erp.company_cutover (company_code, go_live_at, go_live_run, go_live_by)
  VALUES (p_company, now(), p_run, erp.current_user_id())
  RETURNING go_live_at INTO v_at;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'company_go_live', 'migration_run', p_run::text,
          jsonb_build_object('go_live_at', v_at));
  RETURN v_at;
END $$;
REVOKE ALL ON FUNCTION erp.company_go_live(varchar, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.company_go_live(varchar, uuid) TO authenticated, service_role;

-- ============ Release log ============
-- Run from the Supabase SQL editor (role postgres) or with the service role after each file is applied:
--   SELECT erp.schema_release_record('29_go_live.sql', 'branch', 'Ashif', 'applied from docs/go-live.md');
CREATE OR REPLACE FUNCTION erp.schema_release_record(p_file text, p_environment text, p_by text, p_note text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF p_file IS NULL OR p_file !~ '^[0-9]{2}_[a-z0-9_]+\.sql$' THEN
    RAISE EXCEPTION 'Give the SQL file name as it is in supabase/sql, for example 29_go_live.sql.' USING ERRCODE = 'P0001';
  END IF;
  IF p_environment IS NULL OR p_environment NOT IN ('local', 'branch', 'test', 'live') THEN
    RAISE EXCEPTION 'Environment must be local, branch, test or live.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_by), '') IS NULL THEN
    RAISE EXCEPTION 'Say who applied the file.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.schema_release (file_name, environment, applied_by, note) VALUES (p_file, p_environment, btrim(p_by), p_note)
  RETURNING release_id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION erp.schema_release_record(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp.schema_release_record(text, text, text, text) TO service_role;

-- ============ Monitoring: read-only health ============
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health')
  ) AS v(file_name, object)
$$;
REVOKE ALL ON FUNCTION erp._health_files() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION erp.system_health() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_files jsonb; v_missing text[];
  v_norls text[]; v_grants text[]; v_nopath text[]; v_anon text[];
  v_checks jsonb; v_status text;
BEGIN
  PERFORM erp._adm_guard(false);

  SELECT jsonb_agg(jsonb_build_object('file', f.file_name, 'object', 'erp.' || f.object,
                   'present', EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'erp' AND p.proname = f.object))
                   ORDER BY f.file_name),
         array_agg(f.file_name ORDER BY f.file_name) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                                                             WHERE n.nspname = 'erp' AND p.proname = f.object))
    INTO v_files, v_missing FROM erp._health_files() f;

  SELECT array_agg(c.relname ORDER BY c.relname) INTO v_norls
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'erp' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;

  SELECT array_agg(DISTINCT c.relname || ' (' || r.rol || ')' ORDER BY c.relname || ' (' || r.rol || ')') INTO v_grants
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   CROSS JOIN (VALUES ('authenticated'), ('anon')) r(rol)
   WHERE n.nspname = 'erp' AND c.relkind IN ('r', 'p', 'v', 'm')
     AND (has_table_privilege(r.rol, c.oid, 'INSERT') OR has_table_privilege(r.rol, c.oid, 'UPDATE') OR has_table_privilege(r.rol, c.oid, 'DELETE'));

  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.proname) INTO v_nopath
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'erp' AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) x WHERE x LIKE 'search_path=%');

  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.proname) INTO v_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'erp' AND p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE');

  v_checks := jsonb_build_array(
    jsonb_build_object('key', 'files_missing', 'status', CASE WHEN v_missing IS NULL THEN 'ok' ELSE 'error' END,
                       'count', coalesce(cardinality(v_missing), 0), 'items', to_jsonb(coalesce(v_missing, '{}'))),
    jsonb_build_object('key', 'tables_without_rls', 'status', CASE WHEN v_norls IS NULL THEN 'ok' ELSE 'error' END,
                       'count', coalesce(cardinality(v_norls), 0), 'items', to_jsonb(coalesce(v_norls, '{}'))),
    jsonb_build_object('key', 'definer_without_search_path', 'status', CASE WHEN v_nopath IS NULL THEN 'ok' ELSE 'error' END,
                       'count', coalesce(cardinality(v_nopath), 0), 'items', to_jsonb(coalesce(v_nopath, '{}'))),
    jsonb_build_object('key', 'definer_anon_execute', 'status', CASE WHEN v_anon IS NULL THEN 'ok' ELSE 'error' END,
                       'count', coalesce(cardinality(v_anon), 0), 'items', to_jsonb(coalesce(v_anon, '{}'))),
    -- 12_erp_security.sql grants RLS-guarded own-row writes (field visits, trade requests, trip stops). Shown as a warning.
    jsonb_build_object('key', 'direct_write_grants', 'status', CASE WHEN v_grants IS NULL THEN 'ok' ELSE 'warn' END,
                       'count', coalesce(cardinality(v_grants), 0), 'items', to_jsonb(coalesce(v_grants, '{}'))));

  v_status := CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) e WHERE e->>'status' = 'error') THEN 'error'
                   WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) e WHERE e->>'status' = 'warn') THEN 'warn'
                   ELSE 'ok' END;

  RETURN jsonb_build_object(
    'status', v_status,
    'server_time', now(),
    'database', jsonb_build_object('version', current_setting('server_version'),
                                   'size_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
                                   'max_locks_per_transaction', current_setting('max_locks_per_transaction')),
    'files', v_files,
    'releases', coalesce((SELECT jsonb_agg(jsonb_build_object('file', r.file_name, 'environment', r.environment, 'applied_at', r.applied_at,
                                                             'applied_by', r.applied_by, 'note', r.note) ORDER BY r.applied_at DESC, r.release_id DESC)
                            FROM (SELECT * FROM erp.schema_release ORDER BY applied_at DESC, release_id DESC LIMIT 30) r), '[]'::jsonb),
    'checks', v_checks,
    'companies', coalesce((SELECT jsonb_agg(jsonb_build_object(
                    'company_code', c.company_code, 'company_name', c.legal_name,
                    'last_sap_load', (SELECT max(l.loaded_at) FROM sap._load_log l WHERE l.company_code = c.company_code),
                    'go_live_at', k.go_live_at,
                    'checklist_done', (SELECT count(*) FROM erp._gl_done(c.company_code) d WHERE d.done),
                    'open_issues', (SELECT count(*) FROM erp.go_live_issue i WHERE i.company_code = c.company_code AND i.status = 'open'))
                  ORDER BY c.company_code)
                  FROM erp.company c LEFT JOIN erp.company_cutover k ON k.company_code = c.company_code
                 WHERE erp.can_see(c.company_code)), '[]'::jsonb));
END $$;

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp.go_live_overview(), erp.go_live_checklist(varchar), erp.go_live_step_set(varchar, integer, boolean, text, text),
                       erp.go_live_issue_save(varchar, jsonb), erp.go_live_issue_close(varchar, bigint, text), erp.system_health()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.go_live_overview(), erp.go_live_checklist(varchar), erp.go_live_step_set(varchar, integer, boolean, text, text),
                          erp.go_live_issue_save(varchar, jsonb), erp.go_live_issue_close(varchar, bigint, text), erp.system_health()
  TO authenticated, service_role;

COMMENT ON TABLE erp.go_live_step IS 'A14 go-live checklist ticks (steps 2, 3, 4, 5, 7). Steps 1 and 6 come from migration_run and company_cutover.';
COMMENT ON TABLE erp.go_live_issue IS 'A14 hypercare issue list (after go-live).';
COMMENT ON TABLE erp.schema_release IS 'A14 release log: which SQL file was applied to which environment, when and by whom (erp.schema_release_record).';

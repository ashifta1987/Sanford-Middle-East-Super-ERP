-- B5 · Open items: substitute authorizers, landed costs in a foreign currency, credit memos across rates, foreign-currency
-- totals on lists, period-end exchange rate revaluation. Safe to run twice. Does not edit 10–33: earlier behaviour is changed
-- here with CREATE OR REPLACE, keeping the earlier tests passing.
--
-- GENERATED from supabase/sql/src/34_open_items (part1/2/3.sql + asserted patches of earlier functions in build.py).
-- Edit the sources and run `python3 supabase/sql/src/34_open_items/build.py`; `--check` verifies the committed file.
--
-- Sections
--   1. Substitute authorizers (Administration › Approval Process › Substitute Authorizer, SAP B1 style)
--   2. Approval engine patches: a substitute decides in the authorizer's place, votes record "on behalf of"
--   3. Credit memos copying invoices with other rates (each copied line keeps its invoice's rate)
--   4. Landed costs in a foreign currency (+ the linked broker A/P invoice)
--   5. Foreign-currency totals on lists (new *_list_fc views; the earlier views are not touched)
--   6. Period-end exchange rate revaluation (Financials › Exchange Rate Differences)
--
-- Nothing company-specific is seeded for AE01–AE05. ZZ99 gets SAMPLE revaluation accounts (7110 / 7210) only.

-- ============ 1. Substitute authorizers ============
-- An authorizer (a user who belongs to an approval stage, by name or by position) names a substitute for a date range.
-- While it is active (today between from_date and to_date, not ended), the substitute may decide the requests waiting at
-- every stage the authorizer belongs to. The vote records "on behalf of" the authorizer, so the authorizer and the
-- substitute together count as one person. Substitutions don't chain (a substitute's own substitute gets nothing).
-- Built-in leave approvals (no stage) are not covered.
CREATE TABLE IF NOT EXISTS erp.apr_substitute (
    sub_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    user_id        uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,       -- the authorizer who is away
    substitute_id  uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,       -- who decides in their place
    from_date      date NOT NULL,
    to_date        date NOT NULL,
    note           text,
    active         boolean NOT NULL DEFAULT true,                                 -- false = ended early
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    ended_by       uuid,
    ended_at       timestamptz,
    CHECK (user_id <> substitute_id),
    CHECK (to_date >= from_date)
);
CREATE INDEX IF NOT EXISTS apr_substitute_sub_idx ON erp.apr_substitute (substitute_id, company_code) WHERE active;
CREATE INDEX IF NOT EXISTS apr_substitute_user_idx ON erp.apr_substitute (user_id, company_code) WHERE active;

ALTER TABLE erp.approval_vote ADD COLUMN IF NOT EXISTS on_behalf_of uuid REFERENCES erp.app_user;
ALTER TABLE erp.approval ADD COLUMN IF NOT EXISTS on_behalf_of uuid;

ALTER TABLE erp.apr_substitute ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.apr_substitute FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.apr_substitute TO authenticated;
DROP POLICY IF EXISTS apr_substitute_read ON erp.apr_substitute;
CREATE POLICY apr_substitute_read ON erp.apr_substitute FOR SELECT TO authenticated
  USING (erp.can_see(company_code)
         AND (user_id = erp.current_user_id() OR substitute_id = erp.current_user_id()
              OR erp.module_level('admin') IS NOT NULL OR erp.module_level('it') IS NOT NULL OR erp.module_level('business') IS NOT NULL));

-- The authorizer a user stands in for on an open approval row today: the stage must list the authorizer (by name or by
-- position, as B2 reads it live), the authorizer must not have voted on the row (nor anyone on their behalf), and they must
-- not be the requester. NULL = not a substitute for this row.
CREATE OR REPLACE FUNCTION erp._apr_sub_principal(p_id bigint, p_user uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT s.user_id
    FROM erp.approval a
    JOIN erp.apr_substitute s ON s.company_code = a.company_code AND s.substitute_id = p_user AND s.active
                             AND current_date BETWEEN s.from_date AND s.to_date
    JOIN erp.app_user pu ON pu.user_id = s.user_id AND pu.active
   WHERE a.approval_id = p_id AND a.stage_id IS NOT NULL
     AND a.requested_by IS DISTINCT FROM s.user_id
     AND erp._apr_authorizer(a.stage_id, pu.user_id, pu.position_code)
     AND NOT EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND (v.user_id = s.user_id OR v.on_behalf_of = s.user_id))
   ORDER BY s.from_date, s.sub_id
   LIMIT 1
$$;

-- Is the user, today, the substitute of someone who belongs to this stage? (cancel rights, as for the authorizers)
CREATE OR REPLACE FUNCTION erp._apr_sub_of_stage(p_stage bigint, p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM erp.apr_stage st
      JOIN erp.apr_substitute s ON s.company_code = st.company_code AND s.substitute_id = p_user AND s.active
                               AND current_date BETWEEN s.from_date AND s.to_date
      JOIN erp.app_user pu ON pu.user_id = s.user_id AND pu.active
     WHERE st.stage_id = p_stage AND erp._apr_authorizer(st.stage_id, pu.user_id, pu.position_code))
$$;

-- The stages (names) a user belongs to in a company, by name or by position.
CREATE OR REPLACE FUNCTION erp._apr_user_stages(p_company varchar, p_user uuid) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(DISTINCT s.name ORDER BY s.name), '{}'::text[])
    FROM erp.apr_stage s JOIN erp.apr_stage_authorizer a ON a.stage_id = s.stage_id
    JOIN erp.app_user u ON u.user_id = p_user
   WHERE s.company_code = p_company AND s.active AND (a.user_id = u.user_id OR a.position_code = u.position_code)
$$;

-- A vote cast by a substitute records the authorizer it stands for (direct authorizers vote for themselves).
CREATE OR REPLACE FUNCTION erp._apr_vote_behalf() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a  erp.approval;
  me erp.app_user;
BEGIN
  IF NEW.on_behalf_of IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO a FROM erp.approval WHERE approval_id = NEW.approval_id;
  IF a.stage_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO me FROM erp.app_user WHERE user_id = NEW.user_id;
  IF erp._apr_authorizer(a.stage_id, me.user_id, me.position_code) THEN
    RETURN NEW;
  END IF;
  NEW.on_behalf_of := erp._apr_sub_principal(NEW.approval_id, NEW.user_id);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apr_vote_behalf ON erp.approval_vote;
CREATE TRIGGER apr_vote_behalf BEFORE INSERT ON erp.approval_vote FOR EACH ROW EXECUTE FUNCTION erp._apr_vote_behalf();

-- Audit every vote cast on someone's behalf.
CREATE OR REPLACE FUNCTION erp._apr_vote_behalf_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a erp.approval;
BEGIN
  SELECT * INTO a FROM erp.approval WHERE approval_id = NEW.approval_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (NEW.user_id::text, a.company_code, 'approval_vote_on_behalf', 'approval', NEW.approval_id::text,
          jsonb_build_object('decision', NEW.decision, 'on_behalf_of', NEW.on_behalf_of,
                             'on_behalf_of_name', (SELECT display_name FROM erp.app_user WHERE user_id = NEW.on_behalf_of),
                             'object', a.object, 'object_ref', a.object_ref, 'stage_id', a.stage_id, 'stage_name', a.stage_name, 'note', NEW.note));
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apr_vote_behalf_audit ON erp.approval_vote;
CREATE TRIGGER apr_vote_behalf_audit AFTER INSERT ON erp.approval_vote FOR EACH ROW WHEN (NEW.on_behalf_of IS NOT NULL)
  EXECUTE FUNCTION erp._apr_vote_behalf_audit();

-- The row's decision keeps "on behalf of" when the deciding vote was a substitute's.
CREATE OR REPLACE FUNCTION erp._apr_decided_behalf() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF OLD.decision IS NULL AND NEW.decision IS NOT NULL AND NEW.approver_user IS NOT NULL THEN
    NEW.on_behalf_of := (SELECT v.on_behalf_of FROM erp.approval_vote v WHERE v.approval_id = NEW.approval_id AND v.user_id = NEW.approver_user);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apr_decided_behalf ON erp.approval;
CREATE TRIGGER apr_decided_behalf BEFORE UPDATE OF decision ON erp.approval FOR EACH ROW EXECUTE FUNCTION erp._apr_decided_behalf();

-- Sign-in, profile and company checks shared by the substitute functions. Returns the caller.
CREATE OR REPLACE FUNCTION erp._sub_guard(p_company varchar) RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION erp._sub_status(s erp.apr_substitute) RETURNS text LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN NOT s.active THEN 'ended' WHEN current_date < s.from_date THEN 'planned' WHEN current_date > s.to_date THEN 'expired' ELSE 'active' END
$$;

-- Everything the Substitute Authorizer screen needs. Administration (read) sees every substitution of the company; anyone
-- else sees their own (as the authorizer or as the substitute).
CREATE OR REPLACE FUNCTION erp.approval_substitute_list(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me      erp.app_user := erp._sub_guard(p_company);
  v_admin boolean := erp.module_level('admin') IS NOT NULL OR erp.module_level('it') IS NOT NULL OR erp.module_level('business') IS NOT NULL;
BEGIN
  RETURN jsonb_build_object(
    'company_code', p_company,
    'can_admin', erp.can_write('admin'),
    'sees_all', v_admin,
    'today', current_date,
    'me', jsonb_build_object('user_id', me.user_id, 'display_name', me.display_name, 'stages', to_jsonb(erp._apr_user_stages(p_company, me.user_id))),
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', u.user_id, 'display_name', u.display_name, 'position_code', u.position_code,
                                                           'position_name', (SELECT name FROM erp.position WHERE position_code = u.position_code),
                                                           'stages', to_jsonb(erp._apr_user_stages(p_company, u.user_id)))
                                        ORDER BY u.display_name)
                         FROM erp.app_user u WHERE u.active AND erp._apr_company_user(p_company, u.user_id)), '[]'::jsonb),
    'rows', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'sub_id', s.sub_id, 'user_id', s.user_id, 'user_name', au.display_name, 'substitute_id', s.substitute_id, 'substitute_name', su.display_name,
               'from_date', s.from_date, 'to_date', s.to_date, 'note', s.note, 'active', s.active, 'status', erp._sub_status(s),
               'stages', to_jsonb(erp._apr_user_stages(p_company, s.user_id)),
               'decided', (SELECT count(*) FROM erp.approval_vote v JOIN erp.approval a ON a.approval_id = v.approval_id
                            WHERE a.company_code = s.company_code AND v.user_id = s.substitute_id AND v.on_behalf_of = s.user_id
                              AND v.voted_at::date BETWEEN s.from_date AND s.to_date),
               'created_by_name', erp._adm_name(s.created_by), 'created_at', s.created_at,
               'ended_by_name', erp._adm_name(s.ended_by), 'ended_at', s.ended_at,
               'can_edit', s.active AND current_date <= s.to_date AND (erp.can_write('admin') OR s.user_id = me.user_id))
             ORDER BY (erp._sub_status(s) IN ('active', 'planned')) DESC, s.from_date DESC, s.sub_id DESC)
        FROM erp.apr_substitute s
        JOIN erp.app_user au ON au.user_id = s.user_id
        JOIN erp.app_user su ON su.user_id = s.substitute_id
       WHERE s.company_code = p_company AND (v_admin OR s.user_id = me.user_id OR s.substitute_id = me.user_id)), '[]'::jsonb));
END $$;

-- Name (no sub_id) or change a substitute. p_sub: {sub_id, user_id (the authorizer; empty = me), substitute_id, from_date,
-- to_date, note}. Administration (full) for anyone of the company; any user for themself.
CREATE OR REPLACE FUNCTION erp.approval_substitute_save(p_company varchar, p_sub jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me      erp.app_user := erp._sub_guard(p_company);
  p       jsonb := coalesce(p_sub, '{}'::jsonb);
  v_id    bigint;
  old     erp.apr_substitute;
  v_user  uuid;
  v_subst uuid;
  v_from  date;
  v_to    date;
  v_note  text := nullif(btrim(p->>'note'), '');
  au      erp.app_user;
  su      erp.app_user;
  o       erp.apr_substitute;
  n       erp.apr_substitute;
BEGIN
  BEGIN
    v_id := nullif(btrim(p->>'sub_id'), '')::bigint;
    v_user := coalesce(nullif(btrim(p->>'user_id'), '')::uuid, me.user_id);
    v_subst := nullif(btrim(p->>'substitute_id'), '')::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Choose the users from the list.' USING ERRCODE = 'P0001';
  END;
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.apr_substitute WHERE sub_id = v_id AND company_code = p_company FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Substitution % was not found in %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_user := old.user_id;
  END IF;
  IF v_user <> me.user_id AND NOT erp.can_write('admin') THEN
    RAISE EXCEPTION 'Only Administration (full access) can name a substitute for someone else. You can set your own substitute.' USING ERRCODE = '42501';
  END IF;
  IF old.sub_id IS NOT NULL AND NOT old.active THEN
    RAISE EXCEPTION 'This substitution has ended. Add a new one instead.' USING ERRCODE = 'P0001';
  END IF;
  IF old.sub_id IS NOT NULL AND old.to_date < current_date THEN
    RAISE EXCEPTION 'This substitution has expired. Add a new one instead.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO au FROM erp.app_user WHERE user_id = v_user;
  IF NOT erp._apr_company_user(p_company, v_user) THEN
    RAISE EXCEPTION '% has no active access to %.', coalesce(au.display_name, v_user::text), p_company USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(erp._apr_user_stages(p_company, v_user)) = 0 THEN
    RAISE EXCEPTION '% is not an authorizer of any approval stage in %, so there is nothing to hand over.', au.display_name, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_subst IS NULL THEN
    RAISE EXCEPTION 'Choose the substitute.' USING ERRCODE = 'P0001';
  END IF;
  IF v_subst = v_user THEN
    RAISE EXCEPTION 'An authorizer can''t be their own substitute. Choose someone else.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO su FROM erp.app_user WHERE user_id = v_subst;
  IF NOT erp._apr_company_user(p_company, v_subst) THEN
    RAISE EXCEPTION '% has no active access to %, so they can''t be a substitute.', coalesce(su.display_name, v_subst::text), p_company USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_from := nullif(btrim(p->>'from_date'), '')::date;
    v_to := nullif(btrim(p->>'to_date'), '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the dates as YYYY-MM-DD.' USING ERRCODE = 'P0001';
  END;
  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'Enter the start and end dates.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to < v_from THEN
    RAISE EXCEPTION 'The end date is before the start date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to < current_date THEN
    RAISE EXCEPTION 'The end date has already passed. Choose an end date from today on.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to - v_from > 366 THEN
    RAISE EXCEPTION 'A substitution can last up to one year. Split longer absences.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO o FROM erp.apr_substitute s
   WHERE s.company_code = p_company AND s.user_id = v_user AND s.active AND s.sub_id IS DISTINCT FROM v_id
     AND s.from_date <= v_to AND s.to_date >= v_from
   ORDER BY s.from_date LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% already has a substitute from % to % (%). Change or end that one first.', au.display_name, erp._day(o.from_date), erp._day(o.to_date),
      (SELECT display_name FROM erp.app_user WHERE user_id = o.substitute_id) USING ERRCODE = 'P0001';
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO erp.apr_substitute (company_code, user_id, substitute_id, from_date, to_date, note, created_by, updated_by)
    VALUES (p_company, v_user, v_subst, v_from, v_to, v_note, me.user_id, me.user_id) RETURNING * INTO n;
  ELSE
    UPDATE erp.apr_substitute SET substitute_id = v_subst, from_date = v_from, to_date = v_to, note = v_note, updated_by = me.user_id, updated_at = now()
     WHERE sub_id = v_id RETURNING * INTO n;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN v_id IS NULL THEN 'approval_substitute_create' ELSE 'approval_substitute_change' END, 'approval_substitute', n.sub_id::text,
          jsonb_build_object('before', CASE WHEN v_id IS NOT NULL THEN to_jsonb(old) END, 'after', to_jsonb(n),
                             'authorizer_name', au.display_name, 'substitute_name', su.display_name, 'own', v_user = me.user_id));
  RETURN jsonb_build_object('sub_id', n.sub_id, 'status', erp._sub_status(n), 'user_name', au.display_name, 'substitute_name', su.display_name,
                            'from_date', n.from_date, 'to_date', n.to_date);
END $$;

-- End a substitution now (the substitute stops at once; votes already cast stay).
CREATE OR REPLACE FUNCTION erp.approval_substitute_end(p_company varchar, p_sub_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._sub_guard(p_company);
  s  erp.apr_substitute;
BEGIN
  SELECT * INTO s FROM erp.apr_substitute WHERE sub_id = p_sub_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Substitution % was not found in %.', coalesce(p_sub_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF s.user_id <> me.user_id AND NOT erp.can_write('admin') THEN
    RAISE EXCEPTION 'Only Administration (full access) can end someone else''s substitution.' USING ERRCODE = '42501';
  END IF;
  IF NOT s.active THEN
    RAISE EXCEPTION 'This substitution has already ended.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.apr_substitute SET active = false, ended_by = me.user_id, ended_at = now(), updated_by = me.user_id, updated_at = now() WHERE sub_id = p_sub_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'approval_substitute_end', 'approval_substitute', p_sub_id::text,
          jsonb_build_object('before', to_jsonb(s), 'authorizer_name', (SELECT display_name FROM erp.app_user WHERE user_id = s.user_id),
                             'substitute_name', (SELECT display_name FROM erp.app_user WHERE user_id = s.substitute_id)));
  RETURN jsonb_build_object('sub_id', p_sub_id, 'status', 'ended');
END $$;


-- ============ 2. Approval engine: a substitute decides in the authorizer's place ============

-- ---- _apr_is_mine: copied from 31_approvals.sql:384.
CREATE OR REPLACE FUNCTION erp._apr_is_mine(p_id bigint, u erp.app_user) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((
    SELECT CASE WHEN a.stage_id IS NULL
                THEN a.approver_position = u.position_code AND (a.detail->>'for_user' IS NULL OR a.detail->>'for_user' = u.user_id::text)
                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) OR erp._apr_sub_principal(a.approval_id, u.user_id) IS NOT NULL END
           AND NOT EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND (v.user_id = u.user_id OR v.on_behalf_of = u.user_id))
      FROM erp.approval a WHERE a.approval_id = p_id), false)
$$;
-- B5: an active substitute of a stage authorizer may decide too; a person whose substitute already voted on the row can't
-- vote again (and the other way round).

-- ---- _apr_can_act: copied from 31_approvals.sql:395.
CREATE OR REPLACE FUNCTION erp._apr_can_act(p_id bigint, u erp.app_user) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((
    SELECT a.approver_user = u.user_id
        OR EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.user_id = u.user_id)
        OR CASE WHEN a.stage_id IS NULL THEN a.approver_position = u.position_code
                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) OR erp._apr_sub_of_stage(a.stage_id, u.user_id) END
      FROM erp.approval a WHERE a.approval_id = p_id), false)
$$;
-- B5: + active substitutes of the stage's authorizers.

-- ---- _apr_votes: copied from 31_approvals.sql:458.
CREATE OR REPLACE FUNCTION erp._apr_votes(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_name', u.display_name, 'decision', v.decision, 'note', v.note, 'at', v.voted_at,
                                       'on_behalf_of_name', (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = v.on_behalf_of)) ORDER BY v.voted_at, v.vote_id), '[]'::jsonb)
    FROM erp.approval_vote v LEFT JOIN erp.app_user u ON u.user_id = v.user_id
   WHERE v.approval_id = p_id
$$;
-- B5: + on_behalf_of_name (a substitute's vote).

-- ---- _apr_trail: copied from 31_approvals.sql:466.
CREATE OR REPLACE FUNCTION erp._apr_trail(p_company varchar, p_object text, p_ref text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH cur AS (SELECT min(step) AS s FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code,
           'template_name', coalesce(a.template_name, erp._apr_kind_label(a.rule_code)), 'template_id', a.template_id, 'template_version', a.template_version,
           'stage_name', coalesce(a.stage_name, p.name), 'stage_id', a.stage_id,
           'who', CASE WHEN a.stage_id IS NOT NULL THEN erp._apr_stage_who(a.stage_id) ELSE p.name END,
           'need_approvals', coalesce(a.need_approvals, 1), 'need_rejections', coalesce(a.need_rejections, 1),
           'approvals', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'approved'),
           'rejections', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'rejected'),
           'votes', erp._apr_votes(a.approval_id), 'decision', a.decision, 'decided_at', a.decided_at,
           'decided_by_name', du.display_name, 'note', a.note,
           'decided_on_behalf_of_name', (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = a.on_behalf_of), 'superseded', a.superseded,
           'current', a.decision IS NULL AND NOT a.superseded AND a.step = (SELECT s FROM cur)) ORDER BY a.step, a.approval_id), '[]'::jsonb)
    FROM erp.approval a
    LEFT JOIN erp.position p ON p.position_code = a.approver_position
    LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
   WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref
$$;
-- B5: + decided_on_behalf_of_name.

-- ---- approval_inbox: copied from 31_approvals.sql:3841.
CREATE OR REPLACE FUNCTION erp.approval_inbox() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_approver', false, 'waiting', '[]'::jsonb, 'sent', '[]'::jsonb, 'decided', '[]'::jsonb);
  END IF;
  RETURN (
    WITH a AS (
      SELECT b.*, b.detail->>'for_user' AS for_user, p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
             min(b.step) FILTER (WHERE b.decision IS NULL AND NOT b.superseded) OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS current_step,
             max(b.step) OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS last_step
        FROM erp._apr_base() b
        LEFT JOIN erp.position p ON p.position_code = b.approver_position
        LEFT JOIN erp.app_user ru ON ru.user_id = b.requested_by
        LEFT JOIN erp.app_user du ON du.user_id = b.approver_user
    ), r AS (
      SELECT a.*, jsonb_build_object(
               'approval_id', a.approval_id, 'company_code', a.company_code, 'kind', a.kind, 'doc_entry', a.doc_entry,
               'doc_no', a.doc_no, 'rule_code', a.rule_code, 'step', a.step, 'card_code', a.card_code, 'card_name', a.card_name,
               'total', a.total, 'currency', a.currency, 'requested_by_name', a.requested_by_name, 'requested_at', a.requested_at,
               'reason', a.reason, 'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', a.decided_by_name,
               'note', a.note, 'state', a.state, 'superseded', a.superseded,
               'approver_position_name', CASE WHEN a.stage_id IS NOT NULL THEN erp._apr_stage_who(a.stage_id) ELSE a.approver_position_name END,
               'template_name', coalesce(a.template_name, erp._apr_kind_label(a.rule_code)), 'template_id', a.template_id,
               'stage_name', coalesce(a.stage_name, a.approver_position_name), 'stage_id', a.stage_id, 'stages', a.last_step,
               'need_approvals', coalesce(a.need_approvals, 1),
               'approvals', (SELECT count(*) FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.decision = 'approved'),
               'built_in', a.stage_id IS NULL,
               'message', a.detail->'checks'->0->>'message') AS j
        FROM a
    )
    SELECT jsonb_build_object(
      'is_approver', EXISTS (SELECT 1 FROM erp.apr_stage_authorizer sa JOIN erp.apr_stage s ON s.stage_id = sa.stage_id
                              WHERE (sa.position_code = u.position_code OR sa.user_id = u.user_id) AND s.active AND erp.can_see(s.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.approver_position = u.position_code AND ar.active AND erp.can_see(ar.company_code))
                     OR EXISTS (SELECT 1 FROM erp.hr_setting hs WHERE u.position_code IN (hs.hr_approver_position, hs.owner_position) AND erp.can_see(hs.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval ap WHERE ap.detail->>'for_user' = u.user_id::text)
                     OR EXISTS (SELECT 1 FROM erp.admin_setting s WHERE s.owner_position = u.position_code AND erp.can_see(s.company_code))
                     OR EXISTS (SELECT 1 FROM erp.apr_substitute ss WHERE ss.substitute_id = u.user_id AND ss.active
                                   AND current_date BETWEEN ss.from_date AND ss.to_date AND erp.can_see(ss.company_code)),
      'waiting', coalesce((SELECT jsonb_agg(j || jsonb_build_object('on_behalf_of_name',
                                    CASE WHEN stage_id IS NOT NULL AND NOT erp._apr_authorizer(stage_id, u.user_id, u.position_code)
                                         THEN (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = erp._apr_sub_principal(approval_id, u.user_id)) END)
                                  ORDER BY requested_at) FROM r
                            WHERE decision IS NULL AND NOT superseded AND state = 'pending_approval' AND step = current_step
                              AND submitted_by IS DISTINCT FROM u.user_id AND erp._apr_is_mine(approval_id, u)), '[]'::jsonb),
      'sent', coalesce((SELECT jsonb_agg(j ORDER BY requested_at DESC, approval_id) FROM (SELECT * FROM r WHERE requested_by = u.user_id
                         ORDER BY requested_at DESC LIMIT 100) s), '[]'::jsonb),
      'decided', coalesce((SELECT jsonb_agg(j ORDER BY decided_at DESC) FROM (
                            SELECT r.*, coalesce((SELECT max(v.voted_at) FROM erp.approval_vote v WHERE v.approval_id = r.approval_id AND v.user_id = u.user_id), r.decided_at) AS my_at
                              FROM r WHERE (approver_user = u.user_id AND decision IS NOT NULL)
                                 OR EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = r.approval_id AND v.user_id = u.user_id)
                             ORDER BY my_at DESC NULLS LAST LIMIT 100) s), '[]'::jsonb)));
END $$;
-- B5: substitutes count as approvers while their substitution is active; waiting rows they decide for someone else name that
-- person (on_behalf_of_name).

-- ============ 3. Credit memos copying invoices with other rates ============
-- SAP Business One: a credit memo copied from an A/R invoice reverses it at the invoice's rate, so the reversal is exact in
-- LC. B4 refused a typed rate and invoices with different rates on one credit memo; now each copied line keeps the rate of
-- its own invoice (trigger cur_line_fc), a typed rate is not used for copied lines, and the header shows the invoice's rate
-- (several invoices with different rates: the average of the copied lines, LC total / FC total).

-- ---- _cur_ctx_base: copied from 33_multicurrency.sql:166.
CREATE OR REPLACE FUNCTION erp._cur_ctx_base(p_company varchar, p_obj integer, p_bl jsonb, p_date date, p_header jsonb) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_base  integer := CASE p_obj WHEN 15 THEN 17 WHEN 13 THEN 15 WHEN 14 THEN 13 WHEN 20 THEN 22 WHEN 18 THEN 20 END;
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_curs  text[];
  v_rates numeric[];
  v_cur   text;
  v_rate  numeric;
  v_head  text := upper(nullif(btrim(p_header->>'currency'), ''));
  v_typed numeric := erp._num(nullif(btrim(p_header->>'fx_rate'), ''));
  v_noun  text := erp._cur_noun(p_obj);
  e       jsonb;
BEGIN
  SELECT array_agg(DISTINCT coalesce(d.currency, v_lc) ORDER BY coalesce(d.currency, v_lc)),
         array_agg(DISTINCT coalesce(d.fx_rate, 1) ORDER BY coalesce(d.fx_rate, 1))
    INTO v_curs, v_rates
    FROM erp.document d
   WHERE d.company_code = p_company AND d.obj_type = v_base
     AND d.doc_entry IN (SELECT (x->>'base_doc_entry')::integer FROM jsonb_array_elements(coalesce(p_bl, '[]'::jsonb)) x);
  IF coalesce(array_length(v_curs, 1), 0) = 0 THEN
    PERFORM erp._cur_ctx_set(NULL, NULL);
    RETURN 1;
  END IF;
  IF array_length(v_curs, 1) > 1 THEN
    RAISE EXCEPTION 'The lines you copy are in more than one currency (%). Copy the documents of one currency at a time.', array_to_string(v_curs, ', ')
      USING ERRCODE = 'P0001';
  END IF;
  v_cur := v_curs[1];
  IF v_head IS NOT NULL AND v_head <> v_cur THEN
    RAISE EXCEPTION 'The lines you copy are in %, so this % is in % too. The currency can''t be changed on a copy.', v_cur, v_noun, v_cur
      USING ERRCODE = 'P0001';
  END IF;
  IF v_cur = v_lc THEN
    PERFORM erp._cur_ctx_set(v_lc, 1);
    RETURN 1;
  END IF;
  IF p_obj = 14 THEN
    -- B5: each copied line keeps its own invoice's rate (cur_line_fc); the header starts with the first one.
    v_rate := v_rates[1];
  ELSIF p_obj IN (15, 20) THEN
    -- Keeps the rate of the document it is copied from.
    IF array_length(v_rates, 1) > 1 THEN
      RAISE EXCEPTION 'The lines you copy have different exchange rates (%). Copy the documents of one rate at a time.',
        (SELECT string_agg(trim_scale(r)::text, ', ') FROM unnest(v_rates) r) USING ERRCODE = 'P0001';
    END IF;
    v_rate := v_rates[1];
    IF v_typed IS NOT NULL AND v_typed <> v_rate THEN
      RAISE EXCEPTION 'This % keeps the exchange rate of the document it is copied from (%).', v_noun, trim_scale(v_rate) USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- Own posting date's rate (A/R invoice, A/P invoice).
    e := erp._cur_pick(p_company, NULL, NULL, v_cur, p_header->>'fx_rate', p_date, '');
    IF e->>'error' IS NOT NULL THEN
      RAISE EXCEPTION '%', e->>'error' USING ERRCODE = 'P0001';
    END IF;
    v_rate := (e->>'rate')::numeric;
  END IF;
  PERFORM erp._cur_ctx_set(v_cur, v_rate);
  RETURN v_rate;
END $$;
-- B5: credit memos accept invoices with different rates and ignore a typed rate (lines keep their invoice's rate).

-- ---- _cur_line_fc: copied from 33_multicurrency.sql:243.
CREATE OR REPLACE FUNCTION erp._cur_line_fc() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d      record;
  v_rate numeric;
  v_base numeric;
BEGIN
  SELECT doc.currency, doc.fx_rate, doc.source, c.currency AS lc INTO d
    FROM erp.document doc JOIN erp.company c ON c.company_code = doc.company_code
   WHERE doc.company_code = NEW.company_code AND doc.obj_type = NEW.obj_type AND doc.doc_entry = NEW.doc_entry;
  IF d.source = 'erp' AND d.currency IS NOT NULL AND d.currency <> d.lc AND coalesce(d.fx_rate, 0) > 0 AND NEW.line_total_fc IS NULL THEN
    v_rate := d.fx_rate;
    -- B5: a credit memo line copied from an A/R invoice keeps that invoice's rate (exact reversal in LC).
    IF NEW.obj_type = 14 AND NEW.base_obj_type = 13 AND NEW.base_doc_entry IS NOT NULL THEN
      SELECT b.fx_rate INTO v_base FROM erp.document b
       WHERE b.company_code = NEW.company_code AND b.obj_type = 13 AND b.doc_entry = NEW.base_doc_entry AND b.currency = d.currency;
      v_rate := coalesce(nullif(v_base, 0), v_rate);
    END IF;
    NEW.currency := d.currency;
    NEW.line_total_fc := NEW.line_total;
    NEW.vat_fc := NEW.vat;
    NEW.line_total := round(NEW.line_total_fc * v_rate, 2);
    NEW.vat := CASE WHEN NEW.vat_fc IS NULL THEN NULL ELSE round(NEW.vat_fc * v_rate, 2) END;
  END IF;
  RETURN NEW;
END $$;
-- B5: credit memo lines copied from an invoice use the invoice's rate.

-- ---- _sd_cm_exec: copied from 33_multicurrency.sql:874.
CREATE OR REPLACE FUNCTION erp._sd_cm_exec(p_company varchar, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_ret   boolean := coalesce((h->>'return_stock')::boolean, false);
  v_hwhs  text := nullif(btrim(h->>'whs_code'), '');
  bl      jsonb;
  v_out   jsonb := '[]';
  x       jsonb;
  it      erp.item;
  v_date  date;
  v_whs   text;
  v_lt    numeric;
  v_rate  numeric;
  v_cost  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_cur   text;
  i       integer := 0;
BEGIN
  SELECT * INTO u FROM erp.app_user WHERE user_id = p_user;
  v_date := erp._sd_doc_date(h);
  bl := erp._sd_base_lines(p_company, 14, 13, p_lines, 'credit');
  PERFORM erp._cur_ctx_base(p_company, 14, bl, v_date, h);   -- B4: the invoice's currency and rate
  IF v_ret AND v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = x->>'item_code';
    v_whs := CASE WHEN v_ret AND coalesce(it.is_stock, false) THEN coalesce(v_hwhs, x->>'base_whs') ELSE x->>'base_whs' END;
    v_cost := (x->>'cost')::numeric;
    IF v_ret AND coalesce(it.is_stock, false) THEN
      IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
        RAISE EXCEPTION 'Line %: choose an active warehouse for the returned goods.', x->>'n' USING ERRCODE = 'P0001';
      END IF;
      IF v_cost IS NULL THEN
        v_cost := coalesce((SELECT avg_cost FROM erp.stock_balance WHERE company_code = p_company AND item_code = it.item_code AND whs_code = v_whs), it.avg_cost, 0);
      END IF;
    END IF;
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    -- Crediting the whole remaining quantity of a line returns exactly what is left of its amount.
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('whs', v_whs, 'cost', v_cost, 'stock_back', v_ret AND coalesce(it.is_stock, false),
                                              'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  nb := erp._sd_new_doc(p_company, 14, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        (bl->0->>'slp_code')::integer, (bl->0->>'branch_id')::integer, CASE WHEN v_ret THEN v_hwhs END, v_ret);
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 14, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, 0, x->>'uom',
            (x->>'price')::numeric, v_cur, (x->>'discount_pct')::numeric, (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric,
            x->>'whs', 'C', (x->>'cost')::numeric, (x->>'cost')::numeric, (x->>'slp_code')::integer, 13, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    IF (x->>'stock_back')::boolean THEN
      PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs', (x->>'qty')::numeric, 0, (x->>'cost')::numeric, 14, v_entry, i, v_date);
    END IF;
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 14, v_entry);
  -- B5: invoices with different rates: the header shows the average rate of the copied lines (LC total / FC total).
  UPDATE erp.document d SET fx_rate = round(d.total / d.total_fc, 6)
   WHERE d.company_code = p_company AND d.obj_type = 14 AND d.doc_entry = v_entry AND coalesce(d.total_fc, 0) <> 0
     AND (SELECT count(DISTINCT b.fx_rate) FROM erp.document_line l
            JOIN erp.document b ON b.company_code = l.company_code AND b.obj_type = 13 AND b.doc_entry = l.base_doc_entry
           WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = v_entry AND l.base_obj_type = 13) > 1;
  PERFORM erp._sd_consume(p_company, 13, bl);
  v_trans := erp.post_document(p_company, 14, v_entry);
  PERFORM erp._bp_balance_add(p_company, bl->0->>'card_code', -v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ar_credit_memo_create', 'ar_credit_memo', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'return_stock', v_ret, 'invoices', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y),
                             'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans,
                            'fx_rate', (SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = 14 AND doc_entry = v_entry));
END $$;
-- B5: average header rate for invoices with different rates; + fx_rate in the result.

-- ============ 4. Landed costs in a foreign currency ============
-- A charge line may be in another currency than the company's: its rate is fx_rate_list on the landed cost date (only
-- Financials may type another one, as on documents). The split and the posting are in LC; the FC amount and the rate are kept.
-- A charge may name the broker's / forwarder's A/P invoice that bills it (same currency). The clearing account is then
-- credited at that invoice's own LC value, so it clears exactly what the invoice debited; the difference to the LC that was
-- capitalised is a rate difference (purchasing / fx_loss, sales / fx_gain), as B4 does for an A/P invoice against its GRPO.
-- The value split of a goods receipt in a foreign currency now uses the receipt's LC value (B4 used the price in its currency).
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS currency varchar(3);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS amount_fc numeric(19,2);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS fx_rate numeric(19,6);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS ap_invoice_entry integer;
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS clear_amount numeric(19,2);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS fx_diff numeric(19,2);
CREATE INDEX IF NOT EXISTS landed_cost_charge_ap_idx ON erp.landed_cost_charge (company_code, ap_invoice_entry) WHERE ap_invoice_entry IS NOT NULL;


-- ---- _lc_eval: copied from 32_gl_setup.sql:1029.
CREATE OR REPLACE FUNCTION erp._lc_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chg    jsonb := CASE WHEN jsonb_typeof(p_charges) = 'array' THEN p_charges ELSE '[]'::jsonb END;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_date   date;
  v_cur    text;
  x        jsonb;
  ln       jsonb;
  d        erp.document;
  gl       erp.document_line;
  lc       erp.landed_cost_code;
  v_out    jsonb := '[]';
  v_charges jsonb := '[]';
  v_allocs jsonb := '[]';
  v_seen   text[] := '{}';
  v_codes  text[] := '{}';
  v_no     text;
  v_w      numeric;
  v_cbm    numeric;
  i        integer := 0;
  k        integer := 0;
  v_amt    numeric;
  v_sum    numeric;
  v_last   integer;
  v_acc    numeric;
  v_a      numeric;
  v_b      numeric;
  v_alloc  numeric[];
  v_total  numeric := 0;
  v_key    text;
  v_pool   jsonb := '{}';
  v_avgm   jsonb := '{}';
  v_oh     numeric;
  v_avg    numeric;
  v_share  numeric;
  v_inv    numeric;
  v_after  numeric;
  v_ti     numeric := 0;
  v_tc     numeric := 0;
  v_res    jsonb := '[]';
  j        integer;
  v_ccur   text;
  v_famt   numeric;
  v_frate  numeric;
  v_clear  numeric;
  v_irate  numeric;
  v_linked numeric;
  v_aptot  numeric;
  v_apno   text;
  v_apmap  jsonb := '{}';
  fx       jsonb;
  ap       erp.document;
  v_ctot   numeric := 0;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  v_date := erp._sd_doc_date(h);
  IF v_card IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'supplier') THEN
    RAISE EXCEPTION 'Supplier % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one goods receipt line.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_chg) = 0 THEN
    RAISE EXCEPTION 'Add at least one landed cost.' USING ERRCODE = 'P0001';
  END IF;

  -- Lines
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 20 AND doc_entry = erp._num(x->>'grpo_entry')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % was not found in company %.', i, coalesce(x->>'grpo_entry', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_no := erp._sd_no(p_company, 20, d.doc_entry);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION 'Line %: goods receipt % came from %. Landed costs work on Super ERP goods receipts only.', i, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    ELSIF d.status = 'cancelled' THEN
      RAISE EXCEPTION 'Line %: goods receipt % is cancelled.', i, v_no USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO gl FROM erp.document_line WHERE company_code = p_company AND obj_type = 20 AND doc_entry = d.doc_entry
                                                AND line_num = erp._num(x->>'grpo_line')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % has no line %.', i, v_no, coalesce((erp._num(x->>'grpo_line') + 1)::text, '(none)') USING ERRCODE = 'P0001';
    END IF;
    IF (d.doc_entry || ':' || gl.line_num) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Line %: line % of goods receipt % is listed twice.', i, gl.line_num + 1, v_no USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || (d.doc_entry || ':' || gl.line_num);
    v_w := NULL;
    IF nullif(btrim(x->>'weight'), '') IS NOT NULL THEN
      v_w := erp._num(x->>'weight');
      IF v_w IS NULL OR v_w < 0 THEN
        RAISE EXCEPTION 'Line %: weight must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_cbm := gl.cbm;
    IF nullif(btrim(x->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(x->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        RAISE EXCEPTION 'Line %: volume (CBM) must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_out := v_out || jsonb_build_object('line_num', i - 1, 'grpo_entry', d.doc_entry, 'grpo_line', gl.line_num, 'grpo_no', v_no,
      'item_code', gl.item_code, 'description', gl.description, 'whs_code', gl.whs_code, 'qty', gl.quantity,
      'value', CASE WHEN gl.line_total_fc IS NOT NULL THEN round(gl.quantity * coalesce(gl.stock_price, gl.price * coalesce(d.fx_rate, 1)), 2)
                    ELSE round(gl.quantity * gl.price, 2) END,
      'cbm', v_cbm, 'weight', v_w,
      'price', CASE WHEN gl.line_total_fc IS NOT NULL THEN coalesce(gl.stock_price, round(gl.price * coalesce(d.fx_rate, 1), 6)) ELSE gl.price END);
  END LOOP;

  -- Charges: split each one exactly.
  FOR x IN SELECT value FROM jsonb_array_elements(v_chg) LOOP
    k := k + 1;
    SELECT * INTO lc FROM erp.landed_cost_code WHERE company_code = p_company AND code = nullif(btrim(x->>'code'), '');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Landed cost %: code % is not set up for %. Ask Purchasing to add it in Purchasing › Purchasing Setup.',
        k, coalesce(nullif(btrim(x->>'code'), ''), '(none)'), p_company USING ERRCODE = 'P0001';
    ELSIF NOT lc.active THEN
      RAISE EXCEPTION 'Landed cost %: code % is inactive.', k, lc.code USING ERRCODE = 'P0001';
    ELSIF lc.code = ANY (v_codes) THEN
      RAISE EXCEPTION 'Landed cost %: code % is listed twice. Add the amounts together.', k, lc.code USING ERRCODE = 'P0001';
    END IF;
    v_codes := v_codes || lc.code::text;
    v_amt := erp._num(x->>'amount');
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%): enter an amount above 0.', k, lc.name USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_amt, 2);
    -- B5: the charge's currency (rate of the landed cost date) and the broker's A/P invoice it is billed on.
    v_ccur := upper(coalesce(nullif(btrim(x->>'currency'), ''), v_cur));
    v_famt := NULL;
    v_frate := NULL;
    IF v_ccur <> v_cur THEN
      fx := erp._cur_pick(p_company, NULL, NULL, v_ccur, x->>'fx_rate', v_date, '');
      IF fx->>'error' IS NOT NULL THEN
        RAISE EXCEPTION 'Landed cost % (%): %', k, lc.name, fx->>'error' USING ERRCODE = 'P0001';
      END IF;
      v_frate := (fx->>'rate')::numeric;
      v_famt := v_amt;
      v_amt := round(v_famt * v_frate, 2);
    END IF;
    v_clear := v_amt;
    v_apno := NULL;
    ap := NULL;
    IF nullif(btrim(x->>'ap_invoice_entry'), '') IS NOT NULL THEN
      SELECT * INTO ap FROM erp.document WHERE company_code = p_company AND obj_type = 18 AND doc_entry = erp._num(x->>'ap_invoice_entry')::integer;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % was not found in %.', k, lc.name, x->>'ap_invoice_entry', p_company USING ERRCODE = 'P0001';
      END IF;
      v_apno := erp._sd_no(p_company, 18, ap.doc_entry);
      IF ap.status IN ('cancelled', 'cancellation') THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is cancelled.', k, lc.name, v_apno USING ERRCODE = 'P0001';
      ELSIF v_card IS NOT NULL AND ap.card_code <> v_card THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is from %, not from the broker %.', k, lc.name, v_apno, ap.card_code, v_card USING ERRCODE = 'P0001';
      ELSIF coalesce(ap.currency, v_cur) <> v_ccur THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is in %, but this charge is in %. Enter the charge in the invoice''s currency.',
          k, lc.name, v_apno, coalesce(ap.currency, v_cur), v_ccur USING ERRCODE = 'P0001';
      END IF;
      -- Net of VAT, in the invoice's currency; what other landed costs (and earlier lines of this one) already took.
      v_aptot := CASE WHEN v_ccur <> v_cur THEN coalesce(ap.total_fc, 0) - coalesce(ap.vat_total_fc, 0) ELSE ap.total - coalesce(ap.vat_total, 0) END;
      v_linked := coalesce((SELECT sum(coalesce(c.amount_fc, c.amount)) FROM erp.landed_cost_charge c WHERE c.company_code = p_company AND c.ap_invoice_entry = ap.doc_entry), 0)
                  + coalesce((v_apmap->>ap.doc_entry::text)::numeric, 0);
      IF v_linked + coalesce(v_famt, v_amt) > v_aptot THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % has % % left to link (net of VAT), less than % %.', k, lc.name, v_apno,
          erp._money(greatest(v_aptot - v_linked, 0)), v_ccur, erp._money(coalesce(v_famt, v_amt)), v_ccur USING ERRCODE = 'P0001';
      END IF;
      v_apmap := v_apmap || jsonb_build_object(ap.doc_entry::text, coalesce((v_apmap->>ap.doc_entry::text)::numeric, 0) + coalesce(v_famt, v_amt));
      v_irate := CASE WHEN v_ccur <> v_cur THEN coalesce(nullif(ap.fx_rate, 0), v_frate) ELSE 1 END;
      v_clear := round(coalesce(v_famt, v_amt) * v_irate, 2);
    END IF;
    v_ctot := v_ctot + v_clear;
    v_sum := 0;
    v_last := NULL;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
      v_sum := v_sum + v_b;
      IF v_b > 0 THEN v_last := j; END IF;
    END LOOP;
    IF v_sum <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%) is split by %, but none of the lines has %. Enter it on the lines.', k, lc.name,
        CASE lc.split_method WHEN 'cbm' THEN 'volume (CBM)' WHEN 'qty' THEN 'quantity' WHEN 'value' THEN 'value' ELSE 'weight' END,
        CASE lc.split_method WHEN 'cbm' THEN 'a volume' WHEN 'qty' THEN 'a quantity' WHEN 'value' THEN 'a value' ELSE 'a weight' END USING ERRCODE = 'P0001';
    END IF;
    v_acc := 0;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
      IF j = v_last THEN
        v_a := v_amt - v_acc;                      -- the rounding remainder
      ELSE
        v_a := round(v_amt * v_b / v_sum, 2);
      END IF;
      v_acc := v_acc + v_a;
      v_allocs := v_allocs || jsonb_build_object('charge_no', k - 1, 'line_num', j, 'basis', v_b, 'amount', v_a);
    END LOOP;
    v_charges := v_charges || (jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,
                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)))
                               || jsonb_build_object('currency', v_ccur, 'amount_fc', v_famt, 'fx_rate', v_frate, 'ap_invoice_entry', ap.doc_entry,
                                                     'ap_invoice_no', v_apno, 'clear_amount', v_clear, 'fx_diff', v_clear - v_amt));
    v_total := v_total + v_amt;
  END LOOP;

  -- Per line: allocated, the on-hand share to inventory (average cost), the rest to cost of goods sold.
  FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
    ln := v_out->j;
    SELECT coalesce(sum((a->>'amount')::numeric), 0) INTO v_a FROM jsonb_array_elements(v_allocs) a WHERE (a->>'line_num')::integer = j;
    v_key := (ln->>'item_code') || '|' || (ln->>'whs_code');
    SELECT sb.on_hand, sb.avg_cost INTO v_oh, v_avg FROM erp.stock_balance sb
     WHERE sb.company_code = p_company AND sb.item_code = ln->>'item_code' AND sb.whs_code = ln->>'whs_code';
    v_oh := greatest(coalesce(v_oh, 0), 0);
    IF NOT (v_pool ? v_key) THEN
      v_pool := v_pool || jsonb_build_object(v_key, v_oh);
      v_avgm := v_avgm || jsonb_build_object(v_key, coalesce(v_avg, (ln->>'price')::numeric));
    END IF;
    v_share := least((v_pool->>v_key)::numeric, (ln->>'qty')::numeric);
    v_pool := v_pool || jsonb_build_object(v_key, (v_pool->>v_key)::numeric - v_share);
    v_inv := CASE WHEN v_share >= (ln->>'qty')::numeric THEN v_a ELSE round(v_a * v_share / (ln->>'qty')::numeric, 2) END;
    v_avg := (v_avgm->>v_key)::numeric;
    v_after := CASE WHEN v_oh > 0 THEN round((v_oh * v_avg + v_inv) / v_oh, 6) ELSE v_avg END;
    v_avgm := v_avgm || jsonb_build_object(v_key, v_after);
    v_ti := v_ti + v_inv;
    v_tc := v_tc + (v_a - v_inv);
    v_res := v_res || (ln || jsonb_build_object('allocated', v_a, 'to_inventory', v_inv, 'to_cogs', v_a - v_inv, 'on_hand', v_oh,
                                                'avg_before', v_avg, 'avg_after', v_after));
  END LOOP;

  RETURN jsonb_build_object('header', jsonb_build_object('doc_date', v_date, 'card_code', v_card, 'reference', nullif(btrim(h->>'reference'), ''),
                                                         'comments', nullif(btrim(h->>'comments'), '')),
                            'lines', v_res, 'charges', v_charges, 'allocs', v_allocs,
                            'totals', jsonb_build_object('total', v_total, 'to_inventory', v_ti, 'to_cogs', v_tc, 'currency', v_cur,
                                                         'clearing', v_ctot, 'fx_diff', v_ctot - v_total));
END $$;
-- B5: charges in a foreign currency (rate of the landed cost date) and the linked broker A/P invoice (clearing at its LC);
-- the value split of a foreign-currency receipt uses its LC value.

-- ---- landed_cost_create: copied from 32_gl_setup.sql:1210.
CREATE OR REPLACE FUNCTION erp.landed_cost_create(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  nb      jsonb;
  v_entry integer;
  v_lines jsonb := '[]';
  v_trans integer;
  v_inv   text;
  v_cogs  text;
  v_clr   text;
  v_ti    numeric;
  v_tc    numeric;
  v_tot   numeric;
  x       jsonb;
BEGIN
  u := erp._pd_guard(p_company, true, 'post landed costs', true);
  -- Lock the stock rows the split reads, then split.
  PERFORM 1 FROM erp.stock_balance sb
    JOIN erp.document_line gl ON gl.company_code = sb.company_code AND gl.item_code = sb.item_code AND gl.whs_code = sb.whs_code AND gl.obj_type = 20
   WHERE sb.company_code = p_company
     AND (gl.doc_entry, gl.line_num) IN (SELECT erp._num(y->>'grpo_entry')::integer, erp._num(y->>'grpo_line')::integer
                                           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) y)
   FOR UPDATE OF sb;
  e := erp._lc_eval(p_company, p_header, p_lines, p_charges);
  v_ti := (e->'totals'->>'to_inventory')::numeric;
  v_tc := (e->'totals'->>'to_cogs')::numeric;
  v_tot := (e->'totals'->>'total')::numeric;
  -- B3: every account is checked before anything is written, in the same order as before: stock (per line), landed cost
  -- clearing (only when a type has no account of its own), price difference (per line with goods already sold).
  PERFORM erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') FROM jsonb_array_elements(e->'lines') y;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'charges') ch WHERE ch->>'acct_code' IS NULL) THEN
    v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  END IF;
  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
  END IF;
  -- B5: the rate difference against linked broker invoices (B4's accounts).
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    PERFORM erp.gl_account(p_company, 'purchasing', 'fx_loss');
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    PERFORM erp.gl_account(p_company, 'sales', 'fx_gain');
  END IF;

  nb := erp._pd_number(p_company, 69);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.landed_cost (company_code, doc_entry, doc_no, doc_date, card_code, reference, comments, total, to_inventory, to_cogs, currency, created_by)
  VALUES (p_company, v_entry, nb->>'no', (e->'header'->>'doc_date')::date, e->'header'->>'card_code', e->'header'->>'reference',
          e->'header'->>'comments', v_tot, v_ti, v_tc, e->'totals'->>'currency', u.user_id);
  INSERT INTO erp.landed_cost_line (company_code, doc_entry, line_num, grpo_entry, grpo_line, item_code, whs_code, qty, value, cbm, weight,
                                    allocated, to_inventory, to_cogs, on_hand, avg_before, avg_after)
  SELECT p_company, v_entry, y.line_num, y.grpo_entry, y.grpo_line, y.item_code, y.whs_code, y.qty, y.value, y.cbm, y.weight,
         y.allocated, y.to_inventory, y.to_cogs, y.on_hand, y.avg_before, y.avg_after
    FROM jsonb_to_recordset(e->'lines') AS y(line_num int, grpo_entry int, grpo_line int, item_code text, whs_code text, qty numeric, value numeric,
                                             cbm numeric, weight numeric, allocated numeric, to_inventory numeric, to_cogs numeric, on_hand numeric,
                                             avg_before numeric, avg_after numeric);
  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code,
                                      currency, amount_fc, fx_rate, ap_invoice_entry, clear_amount, fx_diff)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code,
         y.currency, y.amount_fc, y.fx_rate, y.ap_invoice_entry, y.clear_amount, y.fx_diff
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text,
                                               currency text, amount_fc numeric, fx_rate numeric, ap_invoice_entry int, clear_amount numeric, fx_diff numeric);
  INSERT INTO erp.landed_cost_alloc (company_code, doc_entry, charge_no, line_num, basis, amount)
  SELECT p_company, v_entry, y.charge_no, y.line_num, y.basis, y.amount
    FROM jsonb_to_recordset(e->'allocs') AS y(charge_no int, line_num int, basis numeric, amount numeric);

  -- Average cost: lines are chained per item and warehouse, so the last line of each carries the final value.
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') ORDER BY (value->>'line_num')::integer LOOP
    IF (x->>'to_inventory')::numeric > 0 THEN
      UPDATE erp.stock_balance SET avg_cost = (x->>'avg_after')::numeric
       WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'whs_code';
    END IF;
  END LOOP;

  -- Stock share and sold share per line (the item's group, the receipt's warehouse); credit per landed cost type account.
  IF v_ti > 0 THEN
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt, 'memo', 'Landed costs on stock') ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') AS acct, sum((y->>'to_inventory')::numeric) AS amt
              FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_inventory')::numeric <> 0 GROUP BY 1) a);
  END IF;
  IF v_tc > 0 THEN
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt, 'memo', 'Landed costs on goods already sold (price difference)') ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code') AS acct, sum((y->>'to_cogs')::numeric) AS amt
              FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0 GROUP BY 1) a);
  END IF;
  v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.first_charge)
    FROM (SELECT coalesce(ch->>'acct_code', v_clr) AS acct, sum((ch->>'clear_amount')::numeric) AS amt, min((ch->>'charge_no')::integer) AS first_charge
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);
  -- B5: clearing credited at the linked invoices' LC; the difference to what was capitalised is a rate difference.
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'purchasing', 'fx_loss'),
                                                               'debit', (e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'sales', 'fx_gain'),
                                                               'credit', -(e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  END IF;
  v_trans := erp.post_journal(p_company, (e->'header'->>'doc_date')::date, format('Landed costs %s', nb->>'no'), v_lines,
    jsonb_build_object('trans_type', 69, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', e->'header'->>'reference', 'allow_control', true,
                       'action', 'document_post', 'object', 'landed_cost', 'object_ref', v_entry::text));
  UPDATE erp.landed_cost SET trans_id = v_trans WHERE company_code = p_company AND doc_entry = v_entry;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 69, v_entry, v_trans);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'landed_cost_create', 'landed_cost', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'lines', jsonb_array_length(e->'lines'),
                             'charges', e->'charges', 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'trans_id', v_trans,
                            'fx_diff', (e->'totals'->>'fx_diff')::numeric);
END $$;
-- B5: charges keep currency / FC amount / rate / linked invoice; clearing at the linked invoice's LC, difference to
-- purchasing / fx_loss or sales / fx_gain.

-- ---- landed_cost_info: copied from 21_purchasing.sql:2587.
CREATE OR REPLACE FUNCTION erp.landed_cost_info(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  lc erp.landed_cost;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO lc FROM erp.landed_cost WHERE company_code = p_company AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'doc_entry', lc.doc_entry, 'doc_no', lc.doc_no, 'doc_date', lc.doc_date, 'card_code', lc.card_code,
    'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = lc.card_code),
    'reference', lc.reference, 'comments', lc.comments, 'total', lc.total, 'to_inventory', lc.to_inventory, 'to_cogs', lc.to_cogs,
    'currency', lc.currency, 'trans_id', lc.trans_id, 'can_read_journal', erp.can_read('finance'),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = lc.created_by), 'created_at', lc.created_at,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'grpo_entry', l.grpo_entry, 'grpo_line', l.grpo_line,
                                         'grpo_no', erp._sd_no(p_company, 20, l.grpo_entry), 'item_code', l.item_code,
                                         'description', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = l.item_code),
                                         'whs_code', l.whs_code, 'qty', l.qty, 'value', l.value, 'cbm', l.cbm, 'weight', l.weight,
                                         'allocated', l.allocated, 'to_inventory', l.to_inventory, 'to_cogs', l.to_cogs, 'on_hand', l.on_hand,
                                         'avg_before', l.avg_before, 'avg_after', l.avg_after,
                                         'allocs', (SELECT jsonb_object_agg(a.charge_no::text, a.amount) FROM erp.landed_cost_alloc a
                                                     WHERE a.company_code = l.company_code AND a.doc_entry = l.doc_entry AND a.line_num = l.line_num))
                                       ORDER BY l.line_num)
                         FROM erp.landed_cost_line l WHERE l.company_code = p_company AND l.doc_entry = p_doc_entry), '[]'::jsonb),
    'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('charge_no', c.charge_no, 'code', c.code, 'name', c.name, 'split_method', c.split_method,
                                           'amount', c.amount, 'currency', coalesce(c.currency, lc.currency), 'amount_fc', c.amount_fc, 'fx_rate', c.fx_rate,
                                           'ap_invoice_entry', c.ap_invoice_entry,
                                           'ap_invoice_no', CASE WHEN c.ap_invoice_entry IS NOT NULL THEN erp._sd_no(p_company, 18, c.ap_invoice_entry) END,
                                           'clear_amount', coalesce(c.clear_amount, c.amount), 'fx_diff', coalesce(c.fx_diff, 0)) ORDER BY c.charge_no)
                           FROM erp.landed_cost_charge c WHERE c.company_code = p_company AND c.doc_entry = p_doc_entry), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor)) ORDER BY l.at, l.audit_id)
                            FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                           WHERE l.company_code = p_company AND l.object = 'landed_cost' AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;
-- B5: charges with currency, FC amount, rate, linked A/P invoice, clearing amount and rate difference.

-- ---- _health_files: copied from 33_multicurrency.sql:3499.
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
    ('34_open_items.sql', 'fx_revaluation_post')
  ) AS v(file_name, object)
$$;
-- B5: + 34_open_items.sql (marker fx_revaluation_post).

-- ============ 5. Foreign-currency totals on lists ============
-- New views next to the earlier ones (sales_order_list / sales_doc_list 19, purchase_doc_list 21, payment_list 20), built
-- from the base tables so that re-running 19–21 never meets a dependent view. Same columns as the earlier views, then:
-- local_currency, fx_rate, total_fc / paid_fc (only for documents in another currency than the company's).
CREATE OR REPLACE VIEW erp.sales_doc_list_fc WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status, w.state,
       d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total, d.paid, d.source, d.created_on,
       c.currency AS local_currency,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.fx_rate END AS fx_rate,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.total_fc END AS total_fc,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.paid_fc END AS paid_fc
  FROM erp.document d
  LEFT JOIN erp.company c ON c.company_code = d.company_code
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (23, 17, 15, 13, 14);

CREATE OR REPLACE VIEW erp.purchase_doc_list_fc WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status, w.state, w.china_office,
       d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total, d.paid, d.container_no, d.source,
       d.created_on,
       c.currency AS local_currency,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.fx_rate END AS fx_rate,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.total_fc END AS total_fc,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.paid_fc END AS paid_fc
  FROM erp.document d
  LEFT JOIN erp.company c ON c.company_code = d.company_code
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19);

CREATE OR REPLACE VIEW erp.payment_list_fc WITH (security_invoker = true) AS
SELECT p.company_code, p.direction, p.doc_entry, p.doc_num, coalesce(x.doc_no, p.doc_num::text) AS doc_no, p.doc_type, p.doc_date, p.card_code,
       p.card_name, p.currency, p.total, p.cash, p.transfer, p.cheque, p.card, p.on_account, p.cancelled, p.trans_id, p.memo, p.source,
       c.currency AS local_currency,
       CASE WHEN p.currency IS NOT NULL AND p.currency <> c.currency THEN p.fx_rate END AS fx_rate,
       CASE WHEN p.currency IS NOT NULL AND p.currency <> c.currency THEN p.total_fc END AS total_fc,
       p.fx_diff
  FROM erp.payment p
  LEFT JOIN erp.company c ON c.company_code = p.company_code
  LEFT JOIN erp.payment_extra x ON x.company_code = p.company_code AND x.direction = p.direction AND x.doc_entry = p.doc_entry;

REVOKE ALL ON erp.sales_doc_list_fc, erp.purchase_doc_list_fc, erp.payment_list_fc FROM PUBLIC, anon;
GRANT SELECT ON erp.sales_doc_list_fc, erp.purchase_doc_list_fc, erp.payment_list_fc TO authenticated;

-- ============ 6. Period-end exchange rate revaluation (Financials › Exchange Rate Differences) ============
-- Open A/R and A/P items of Super ERP documents in a foreign currency, as of the revaluation date (payments and credit memos
-- dated on or before it), are revalued per partner and currency at the date's rate (fx_rate_list; Financials may type another
-- one). The book value includes earlier revaluations that are still in force on that date. One journal through post_journal:
-- each partner's control account (A/R: sales / domestic_ar, A/P: purchasing / domestic_ap, with the partner as short name)
-- against general / fx_reval_gain or general / fx_reval_loss. Optional automatic reversal on the first day of the next
-- posting period (SAP default). One revaluation per date (cancel it to run it again); a later revaluation blocks earlier
-- dates. The posting periods decide whether the dates are open (post_journal). No approval; Financials full.
-- SAP Business One documents are never revalued here (SAP posts its own).
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort, tab, ctx, store, control_ok, used_in) VALUES
  ('general', 'fx_reval_gain', 'Exchange rate differences – gain (revaluation)', 82, 'general', false, NULL, false,
     'Financials › Exchange Rate Differences: period-end revaluation of open foreign-currency items'),
  ('general', 'fx_reval_loss', 'Exchange rate differences – loss (revaluation)', 83, 'general', false, NULL, false,
     'Financials › Exchange Rate Differences: period-end revaluation of open foreign-currency items')
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, tab = EXCLUDED.tab, ctx = EXCLUDED.ctx,
  store = EXCLUDED.store, control_ok = EXCLUDED.control_ok, used_in = EXCLUDED.used_in;

-- SAMPLE accounts for the test company ZZ99 only (real companies enter theirs in G/L Account Determination › General).
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', v.acct, v.acct, v.name, v.parent, 2, true, 'other', 7, 'AED', false, false, 0, 'sample'
  FROM (VALUES ('7110', 'Unrealised exchange gains (SAMPLE)', '4000'), ('7210', 'Unrealised exchange losses (SAMPLE)', '6000')) AS v(acct, name, parent)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'general', v.k, v.acct, 'sample'
  FROM (VALUES ('fx_reval_gain', '7110'), ('fx_reval_loss', '7210')) AS v(k, acct)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS erp.fx_revaluation (
    reval_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_no         text,
    reval_date     date NOT NULL,
    currencies     text[] NOT NULL,
    rates          jsonb NOT NULL,                                -- {"USD": {"rate": 3.7, "list_rate": 3.7, "overridden": false}}
    auto_reverse   boolean NOT NULL DEFAULT true,
    reverse_date   date,
    trans_id       integer,
    reverse_trans_id integer,
    gain           numeric(19,2) NOT NULL DEFAULT 0,              -- LC, company's view
    loss           numeric(19,2) NOT NULL DEFAULT 0,
    memo           text,
    state          text NOT NULL DEFAULT 'posted' CHECK (state IN ('posted', 'cancelled')),
    cancel_trans_ids integer[],
    cancel_reason  text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_by   uuid,
    cancelled_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS fx_revaluation_once ON erp.fx_revaluation (company_code, reval_date) WHERE state = 'posted';

CREATE TABLE IF NOT EXISTS erp.fx_revaluation_line (
    reval_id       bigint NOT NULL REFERENCES erp.fx_revaluation ON DELETE CASCADE,
    line_no        integer NOT NULL,
    card_code      varchar(15) NOT NULL,
    card_name      text,
    side           text NOT NULL CHECK (side IN ('receivable', 'payable')),
    currency       varchar(3) NOT NULL,
    docs           integer NOT NULL,
    open_fc        numeric(19,2) NOT NULL,
    book_lc        numeric(19,2) NOT NULL,
    rate           numeric(19,6) NOT NULL,
    new_lc         numeric(19,2) NOT NULL,
    diff           numeric(19,2) NOT NULL,                        -- new_lc − book_lc (the balance's change in LC)
    gain           numeric(19,2) NOT NULL,                        -- company's gain (+) / loss (−)
    acct_code      varchar(15),
    PRIMARY KEY (reval_id, line_no)
);

ALTER TABLE erp.fx_revaluation ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.fx_revaluation_line ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.fx_revaluation, erp.fx_revaluation_line FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.fx_revaluation, erp.fx_revaluation_line TO authenticated;
DROP POLICY IF EXISTS fx_revaluation_read ON erp.fx_revaluation;
CREATE POLICY fx_revaluation_read ON erp.fx_revaluation FOR SELECT TO authenticated USING (erp.can_see(company_code) AND erp.can_read('finance'));
DROP POLICY IF EXISTS fx_revaluation_line_read ON erp.fx_revaluation_line;
CREATE POLICY fx_revaluation_line_read ON erp.fx_revaluation_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.fx_revaluation r WHERE r.reval_id = fx_revaluation_line.reval_id AND erp.can_see(r.company_code) AND erp.can_read('finance')));

CREATE OR REPLACE VIEW erp.fx_revaluation_list WITH (security_invoker = true) AS
SELECT r.reval_id, r.company_code, coalesce(r.doc_no, 'FXR-' || r.reval_id) AS doc_no, r.reval_date, r.currencies, r.auto_reverse, r.reverse_date, r.trans_id,
       r.reverse_trans_id, r.gain, r.loss, r.gain - r.loss AS net, r.state, r.memo, r.created_at,
       (SELECT display_name FROM erp.app_user WHERE user_id = r.created_by) AS created_by_name,
       (SELECT count(*) FROM erp.fx_revaluation_line l WHERE l.reval_id = r.reval_id) AS lines
  FROM erp.fx_revaluation r;
REVOKE ALL ON erp.fx_revaluation_list FROM PUBLIC, anon;
GRANT SELECT ON erp.fx_revaluation_list TO authenticated;

-- Open foreign-currency items per partner, side and currency as of a date (Super ERP documents; the same netting as
-- bp_balance_fc / _bk_doc_open, limited to payments and credit memos dated on or before the date).
CREATE OR REPLACE FUNCTION erp._fxr_open(p_company varchar, p_date date, p_curs text[])
RETURNS TABLE (card_code varchar, card_name text, side text, currency varchar, docs bigint, open_fc numeric, open_lc numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH d AS (
    SELECT d.*, CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END AS sg
      FROM erp.document d JOIN erp.company c ON c.company_code = d.company_code
     WHERE d.company_code = p_company AND d.source = 'erp' AND d.obj_type IN (13, 14, 18, 19, 204)
       AND d.status NOT IN ('cancelled', 'cancellation', 'draft') AND d.doc_date <= p_date
       AND d.total_fc IS NOT NULL AND d.currency IS NOT NULL AND d.currency <> c.currency
       AND (p_curs IS NULL OR cardinality(p_curs) = 0 OR d.currency = ANY (p_curs))
  ), x AS (
    SELECT d.card_code, d.card_name, CASE WHEN d.obj_type IN (13, 14) THEN 'receivable' ELSE 'payable' END AS side, d.currency, d.sg,
           coalesce(d.total_fc, 0) - pay.fc - cm.fc AS ofc,
           coalesce(d.total, 0) - pay.lc - cm.lc AS olc
      FROM d
      CROSS JOIN LATERAL (
        SELECT coalesce(sum(coalesce(pa.applied_fc, 0)), 0) AS fc, coalesce(sum(pa.applied), 0) AS lc
          FROM erp.payment_allocation pa
          JOIN erp.payment p ON p.company_code = pa.company_code AND p.direction = pa.direction AND p.doc_entry = pa.doc_entry
         WHERE pa.company_code = d.company_code AND pa.target_obj_type = d.obj_type AND pa.target_doc_entry = d.doc_entry
           AND NOT coalesce(p.cancelled, false) AND p.doc_date <= p_date) pay
      CROSS JOIN LATERAL (
        SELECT coalesce(sum(coalesce(cl.line_total_fc, 0) + coalesce(cl.vat_fc, 0)), 0) AS fc, coalesce(sum(cl.line_total + coalesce(cl.vat, 0)), 0) AS lc
          FROM erp.document_line cl
          JOIN erp.document c ON c.company_code = cl.company_code AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
         WHERE cl.company_code = d.company_code
           AND ((d.obj_type IN (13, 18) AND cl.obj_type = d.obj_type + 1 AND cl.base_obj_type = d.obj_type AND cl.base_doc_entry = d.doc_entry
                 AND c.status NOT IN ('cancelled', 'cancellation') AND c.doc_date <= p_date)
             OR (d.obj_type IN (14, 19) AND cl.obj_type = d.obj_type AND cl.doc_entry = d.doc_entry AND cl.base_obj_type = d.obj_type - 1))) cm
  )
  SELECT x.card_code, max(x.card_name), x.side, x.currency, count(*) FILTER (WHERE x.ofc <> 0 OR x.olc <> 0), round(sum(x.sg * x.ofc), 2), round(sum(x.sg * x.olc), 2)
    FROM x GROUP BY x.card_code, x.side, x.currency
$$;

-- Validate a revaluation request and compute its lines. Never writes. p_in: {date, currencies: [..] (empty = every foreign
-- currency with open items), rates: {USD: 3.7} (empty = fx_rate_list)}. Raises the first problem.
CREATE OR REPLACE FUNCTION erp._fxr_eval(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_date  date;
  v_curs  text[];
  v_all   boolean;
  c       text;
  v_rate  numeric;
  v_list  numeric;
  v_typed numeric;
  v_rates jsonb := '{}';
  v_rows  jsonb;
  v_rev   date;
  pp      erp.posting_period;
BEGIN
  BEGIN
    v_date := nullif(btrim(v_in->>'date'), '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the date as YYYY-MM-DD.' USING ERRCODE = 'P0001';
  END;
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose the revaluation date.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(v_in->'currencies') = 'array' THEN
    SELECT coalesce(array_agg(DISTINCT upper(btrim(x)) ORDER BY upper(btrim(x))) FILTER (WHERE nullif(btrim(x), '') IS NOT NULL), '{}')
      INTO v_curs FROM jsonb_array_elements_text(v_in->'currencies') x;
  ELSE
    v_curs := '{}';
  END IF;
  v_all := cardinality(v_curs) = 0;
  IF v_lc = ANY (v_curs) THEN
    RAISE EXCEPTION '% is the company currency of %. Choose foreign currencies only.', v_lc, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_all THEN
    SELECT coalesce(array_agg(DISTINCT o.currency::text ORDER BY o.currency::text), '{}') INTO v_curs FROM erp._fxr_open(p_company, v_date, NULL) o WHERE o.open_fc <> 0;
  END IF;
  IF cardinality(v_curs) = 0 THEN
    RAISE EXCEPTION 'There are no open foreign-currency items in % on %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  FOREACH c IN ARRAY v_curs LOOP
    v_list := erp._cur_rate(p_company, c, v_date);
    BEGIN
      v_typed := nullif(btrim(v_in->'rates'->>c), '')::numeric;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Enter the exchange rate for % as a number.', c USING ERRCODE = 'P0001';
    END;
    IF v_typed IS NOT NULL AND v_typed <= 0 THEN
      RAISE EXCEPTION 'The exchange rate for % must be more than 0.', c USING ERRCODE = 'P0001';
    END IF;
    v_rate := coalesce(v_typed, v_list);
    IF v_rate IS NULL THEN
      RAISE EXCEPTION '%', erp._cur_no_rate(c, v_date) USING ERRCODE = 'P0001';
    END IF;
    v_rates := v_rates || jsonb_build_object(c, jsonb_build_object('rate', v_rate, 'list_rate', v_list, 'overridden', v_typed IS NOT NULL AND v_typed IS DISTINCT FROM v_list));
  END LOOP;

  WITH o AS (SELECT * FROM erp._fxr_open(p_company, v_date, v_curs)),
  prior AS (
    SELECT l.card_code, l.side, l.currency, sum(l.diff) AS adj
      FROM erp.fx_revaluation_line l JOIN erp.fx_revaluation r ON r.reval_id = l.reval_id
     WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date < v_date AND (r.reverse_date IS NULL OR r.reverse_date > v_date)
     GROUP BY 1, 2, 3),
  y AS (
    SELECT o.card_code, o.card_name, o.side, o.currency, o.docs, o.open_fc, o.open_lc + coalesce(p.adj, 0) AS book_lc,
           (v_rates->o.currency->>'rate')::numeric AS rate
      FROM o LEFT JOIN prior p ON p.card_code = o.card_code AND p.side = o.side AND p.currency = o.currency
     WHERE o.open_fc <> 0 OR o.open_lc + coalesce(p.adj, 0) <> 0),
  z AS (SELECT y.*, round(y.open_fc * y.rate, 2) AS new_lc FROM y)
  SELECT coalesce(jsonb_agg(jsonb_build_object('card_code', z.card_code, 'card_name', z.card_name, 'side', z.side, 'currency', z.currency, 'docs', z.docs,
                                               'open_fc', z.open_fc, 'book_lc', z.book_lc, 'rate', z.rate, 'new_lc', z.new_lc, 'diff', z.new_lc - z.book_lc,
                                               'gain', CASE WHEN z.side = 'receivable' THEN z.new_lc - z.book_lc ELSE z.book_lc - z.new_lc END)
                            ORDER BY z.side DESC, z.currency, z.card_code), '[]'::jsonb)
    INTO v_rows FROM z;

  SELECT * INTO pp FROM erp.posting_period WHERE company_code = p_company AND v_date BETWEEN from_date AND to_date ORDER BY from_date LIMIT 1;
  v_rev := coalesce(pp.to_date + 1, (date_trunc('month', v_date) + interval '1 month')::date);

  RETURN jsonb_build_object(
    'date', v_date, 'currencies', to_jsonb(v_curs), 'rates', v_rates, 'local_currency', v_lc, 'reverse_date', v_rev, 'rows', v_rows,
    'totals', jsonb_build_object(
      'gain', coalesce((SELECT sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'gain')::numeric > 0), 0),
      'loss', coalesce((SELECT -sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'gain')::numeric < 0), 0),
      'net', coalesce((SELECT sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r), 0),
      'partners', jsonb_array_length(v_rows)),
    'already', (SELECT jsonb_build_object('reval_id', r.reval_id, 'doc_no', r.doc_no, 'date', r.reval_date) FROM erp.fx_revaluation r
                 WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date = v_date),
    'later', (SELECT jsonb_build_object('reval_id', r.reval_id, 'doc_no', r.doc_no, 'date', r.reval_date) FROM erp.fx_revaluation r
               WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date > v_date ORDER BY r.reval_date DESC LIMIT 1));
END $$;

-- Setup for the screen: currencies with open items today, the two accounts, the rates list, history.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'revalue foreign-currency balances');
BEGIN
  RETURN jsonb_build_object(
    'company_code', p_company,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('finance'),
    'currencies', to_jsonb(erp._cur_list(p_company)),
    'open_currencies', coalesce((SELECT jsonb_agg(DISTINCT o.currency ORDER BY o.currency) FROM erp._fxr_open(p_company, current_date, NULL) o WHERE o.open_fc <> 0), '[]'::jsonb),
    'gain_acct', erp.gl_account(p_company, 'general', 'fx_reval_gain', false),
    'loss_acct', erp.gl_account(p_company, 'general', 'fx_reval_loss', false),
    'history', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.reval_date DESC, l.reval_id DESC) FROM erp.fx_revaluation_list l WHERE l.company_code = p_company), '[]'::jsonb));
END $$;

-- Preview (Financials full): the lines and totals that posting would create.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_preview(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
BEGIN
  RETURN erp._fxr_eval(p_company, p_in);
END $$;

-- Post the revaluation journal (and its automatic reversal when asked). p_in: preview input + {auto_reverse (default true), memo}.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_post(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  e       jsonb;
  r       jsonb;
  v_date  date;
  v_auto  boolean := coalesce((v_in->>'auto_reverse')::boolean, true);
  v_memo  text := nullif(btrim(v_in->>'memo'), '');
  v_id    bigint;
  v_no    text;
  v_ar    text;
  v_ap    text;
  v_gacct text;
  v_lacct text;
  v_lines jsonb := '[]';
  v_gain  numeric;
  v_loss  numeric;
  v_trans integer;
  v_rtrans integer;
  v_rev   date;
  x       record;
  i       integer := 0;
BEGIN
  -- One revaluation at a time per company (the date checks below must see each other's rows).
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  e := erp._fxr_eval(p_company, v_in);
  v_date := (e->>'date')::date;
  IF e->'already' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Open items on % are already revalued (%). Cancel that revaluation first if you need to run it again.', erp._day(v_date), e->'already'->>'doc_no'
      USING ERRCODE = 'P0001';
  END IF;
  IF e->'later' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'A later revaluation (% on %) is already posted. Cancel it first, or choose a date after %.', e->'later'->>'doc_no',
      erp._day((e->'later'->>'date')::date), erp._day((e->'later'->>'date')::date) USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(e->'rows') = 0 THEN
    RAISE EXCEPTION 'There are no open foreign-currency items in % on %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE (y->>'diff')::numeric <> 0) THEN
    RAISE EXCEPTION 'The open items are already at these rates on %. Nothing to post.', erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  v_gain := (e->'totals'->>'gain')::numeric;
  v_loss := (e->'totals'->>'loss')::numeric;
  -- Accounts first (the A3 "not set" messages), only those this run needs.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE y->>'side' = 'receivable' AND (y->>'diff')::numeric <> 0) THEN
    v_ar := erp.gl_account(p_company, 'sales', 'domestic_ar');
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE y->>'side' = 'payable' AND (y->>'diff')::numeric <> 0) THEN
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
  END IF;
  IF v_gain > 0 THEN v_gacct := erp.gl_account(p_company, 'general', 'fx_reval_gain'); END IF;
  IF v_loss > 0 THEN v_lacct := erp.gl_account(p_company, 'general', 'fx_reval_loss'); END IF;

  INSERT INTO erp.fx_revaluation (company_code, reval_date, currencies, rates, auto_reverse, gain, loss, memo, created_by)
  SELECT p_company, v_date, ARRAY(SELECT jsonb_array_elements_text(e->'currencies')), e->'rates', v_auto, v_gain, v_loss, v_memo, u.user_id
  RETURNING reval_id INTO v_id;
  v_no := 'FXR-' || v_id;
  UPDATE erp.fx_revaluation SET doc_no = v_no WHERE reval_id = v_id;

  FOR x IN SELECT * FROM jsonb_to_recordset(e->'rows') AS y(card_code text, card_name text, side text, currency text, docs integer, open_fc numeric,
                                                           book_lc numeric, rate numeric, new_lc numeric, diff numeric, gain numeric) LOOP
    i := i + 1;
    INSERT INTO erp.fx_revaluation_line (reval_id, line_no, card_code, card_name, side, currency, docs, open_fc, book_lc, rate, new_lc, diff, gain, acct_code)
    VALUES (v_id, i, x.card_code, x.card_name, x.side, x.currency, x.docs, x.open_fc, x.book_lc, x.rate, x.new_lc, x.diff, x.gain,
            CASE WHEN x.side = 'receivable' THEN v_ar ELSE v_ap END);
    CONTINUE WHEN x.diff = 0;
    -- A receivable that grew is debited; a payable that grew is credited.
    v_lines := v_lines || jsonb_build_object('acct_code', CASE WHEN x.side = 'receivable' THEN v_ar ELSE v_ap END, 'short_name', x.card_code,
      CASE WHEN (x.side = 'receivable') = (x.diff > 0) THEN 'debit' ELSE 'credit' END, abs(x.diff),
      'memo', format('Revaluation %s %s %s at %s', x.card_code, erp._money(x.open_fc), x.currency, trim_scale(x.rate)));
  END LOOP;
  IF v_gain > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_gacct, 'credit', v_gain, 'memo', 'Exchange rate differences – gain');
  END IF;
  IF v_loss > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_lacct, 'debit', v_loss, 'memo', 'Exchange rate differences – loss');
  END IF;
  v_trans := erp.post_journal(p_company, v_date, coalesce(v_memo, format('Exchange rate differences %s · %s', erp._day(v_date), array_to_string(ARRAY(SELECT jsonb_array_elements_text(e->'currencies')), ', '))),
    v_lines, jsonb_build_object('trans_type', 30, 'ref1', v_no, 'ref2', 'FX revaluation', 'base_ref', v_no, 'allow_control', true,
                                'action', 'fx_revaluation_journal', 'object', 'fx_revaluation', 'object_ref', v_id::text));
  IF v_auto THEN
    v_rev := (e->>'reverse_date')::date;
    v_rtrans := erp._reverse_journal(p_company, v_trans, v_rev, format('Reversal of %s (exchange rate differences %s)', v_no, erp._day(v_date)), 'fx_revaluation_reverse');
  END IF;
  UPDATE erp.fx_revaluation SET trans_id = v_trans, reverse_date = v_rev, reverse_trans_id = v_rtrans WHERE reval_id = v_id;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'fx_revaluation_post', 'fx_revaluation', v_id::text,
          jsonb_build_object('doc_no', v_no, 'date', v_date, 'currencies', e->'currencies', 'rates', e->'rates', 'gain', v_gain, 'loss', v_loss,
                             'partners', jsonb_array_length(e->'rows'), 'trans_id', v_trans, 'auto_reverse', v_auto, 'reverse_date', v_rev, 'reverse_trans_id', v_rtrans));
  RETURN jsonb_build_object('reval_id', v_id, 'doc_no', v_no, 'date', v_date, 'trans_id', v_trans, 'reverse_date', v_rev, 'reverse_trans_id', v_rtrans,
                            'gain', v_gain, 'loss', v_loss, 'net', v_gain - v_loss, 'lines', i);
END $$;

-- A mirror journal of p_trans on p_date (debits and credits swapped), used to cancel a revaluation.
CREATE OR REPLACE FUNCTION erp._fxr_mirror(p_company varchar, p_trans integer, p_date date, p_memo text, p_ref text, p_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  RETURN erp.post_journal(p_company, p_date, p_memo,
    (SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'short_name', l.short_name, 'debit', l.credit, 'credit', l.debit, 'memo', l.memo) ORDER BY l.line_id)
       FROM erp.journal_line l WHERE l.company_code = p_company AND l.trans_id = p_trans),
    jsonb_build_object('trans_type', 30, 'ref1', p_ref, 'ref2', 'FX revaluation cancelled', 'base_ref', p_trans::text, 'allow_control', true,
                       'action', 'fx_revaluation_cancel', 'object', 'fx_revaluation', 'object_ref', p_id::text));
END $$;

-- Cancel a revaluation: mirrors its journal (on its date) and the automatic reversal (on that date). The posting periods of
-- both dates must be open. The latest revaluation goes first.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_cancel(p_company varchar, p_reval_id bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
  r      erp.fx_revaluation;
  l      erp.fx_revaluation;
  v_note text := nullif(btrim(p_reason), '');
  v_t1   integer;
  v_t2   integer;
BEGIN
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  SELECT * INTO r FROM erp.fx_revaluation WHERE reval_id = p_reval_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Revaluation % was not found in %.', coalesce(p_reval_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF r.state = 'cancelled' THEN
    RAISE EXCEPTION 'Revaluation % is already cancelled.', r.doc_no USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a reason for cancelling the revaluation.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO l FROM erp.fx_revaluation WHERE company_code = p_company AND state = 'posted' AND reval_date > r.reval_date ORDER BY reval_date DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Cancel the later revaluation % (%) first.', l.doc_no, erp._day(l.reval_date) USING ERRCODE = 'P0001';
  END IF;
  -- Mirror journals (the automatic reversal already is the reversal of record of the revaluation journal).
  v_t1 := erp._fxr_mirror(p_company, r.trans_id, r.reval_date, format('Cancellation of %s: %s', r.doc_no, v_note), r.doc_no, r.reval_id);
  IF r.reverse_trans_id IS NOT NULL THEN
    v_t2 := erp._fxr_mirror(p_company, r.reverse_trans_id, r.reverse_date, format('Cancellation of %s (its reversal): %s', r.doc_no, v_note), r.doc_no, r.reval_id);
  END IF;
  UPDATE erp.fx_revaluation SET state = 'cancelled', cancel_trans_ids = array_remove(ARRAY[v_t1, v_t2], NULL), cancel_reason = v_note,
                                cancelled_by = u.user_id, cancelled_at = now()
   WHERE reval_id = p_reval_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'fx_revaluation_cancel', 'fx_revaluation', p_reval_id::text,
          jsonb_build_object('doc_no', r.doc_no, 'date', r.reval_date, 'reason', v_note, 'trans_ids', to_jsonb(array_remove(ARRAY[v_t1, v_t2], NULL))));
  RETURN jsonb_build_object('reval_id', p_reval_id, 'doc_no', r.doc_no, 'state', 'cancelled', 'trans_ids', to_jsonb(array_remove(ARRAY[v_t1, v_t2], NULL)));
END $$;

-- One revaluation with its lines, journals and activity (Financials read).
CREATE OR REPLACE FUNCTION erp.fx_revaluation_info(p_company varchar, p_reval_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'revalue foreign-currency balances');
  r erp.fx_revaluation;
BEGIN
  SELECT * INTO r FROM erp.fx_revaluation WHERE reval_id = p_reval_id AND company_code = p_company;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(r) || jsonb_build_object(
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'net', r.gain - r.loss,
    'created_by_name', erp._adm_name(r.created_by), 'cancelled_by_name', erp._adm_name(r.cancelled_by),
    'can_cancel', r.state = 'posted' AND erp.can_write('finance')
                  AND NOT EXISTS (SELECT 1 FROM erp.fx_revaluation l WHERE l.company_code = p_company AND l.state = 'posted' AND l.reval_date > r.reval_date),
    'lines', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM erp.fx_revaluation_line l WHERE l.reval_id = r.reval_id), '[]'::jsonb),
    'journals', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'ref_date', j.ref_date, 'memo', j.memo, 'total', j.total_local,
                                                              'lines', (SELECT jsonb_agg(jsonb_build_object('acct_code', jl.acct_code, 'short_name', jl.short_name,
                                                                                                             'debit', jl.debit, 'credit', jl.credit, 'memo', jl.memo) ORDER BY jl.line_id)
                                                                          FROM erp.journal_line jl WHERE jl.company_code = j.company_code AND jl.trans_id = j.trans_id))
                                           ORDER BY j.ref_date, j.trans_id)
                            FROM erp.journal_entry j
                           WHERE j.company_code = p_company AND j.trans_id = ANY (array_remove(ARRAY[r.trans_id, r.reverse_trans_id] || coalesce(r.cancel_trans_ids, '{}'), NULL))), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', coalesce(au.display_name, a.actor)) ORDER BY a.at, a.audit_id)
                            FROM erp.audit_log a LEFT JOIN erp.app_user au ON au.user_id::text = a.actor
                           WHERE a.company_code = p_company AND a.object = 'fx_revaluation' AND a.object_ref = r.reval_id::text), '[]'::jsonb));
END $$;

-- ============ 7. Grants ============
REVOKE ALL ON FUNCTION
  erp._apr_sub_principal(bigint, uuid), erp._apr_sub_of_stage(bigint, uuid), erp._apr_user_stages(varchar, uuid), erp._apr_vote_behalf(),
  erp._apr_vote_behalf_audit(), erp._apr_decided_behalf(), erp._sub_guard(varchar), erp._sub_status(erp.apr_substitute),
  erp._fxr_open(varchar, date, text[]), erp._fxr_eval(varchar, jsonb), erp._fxr_mirror(varchar, integer, date, text, text, bigint)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  erp.approval_substitute_list(varchar), erp.approval_substitute_save(varchar, jsonb), erp.approval_substitute_end(varchar, bigint),
  erp.fx_revaluation_setup(varchar), erp.fx_revaluation_preview(varchar, jsonb), erp.fx_revaluation_post(varchar, jsonb),
  erp.fx_revaluation_cancel(varchar, bigint, text), erp.fx_revaluation_info(varchar, bigint)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  erp.approval_substitute_list(varchar), erp.approval_substitute_save(varchar, jsonb), erp.approval_substitute_end(varchar, bigint),
  erp.fx_revaluation_setup(varchar), erp.fx_revaluation_preview(varchar, jsonb), erp.fx_revaluation_post(varchar, jsonb),
  erp.fx_revaluation_cancel(varchar, bigint, text), erp.fx_revaluation_info(varchar, bigint)
TO authenticated;

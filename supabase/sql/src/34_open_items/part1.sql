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

-- 49 · SANA timing and voice tracking (S4 step 5, go by Ashif 16 Nov 2026).
-- Per answer: ms to the first token, ms to `done`, tool rounds, the models used (written by the sana Edge Function after `logged`,
-- with the user's own token), and ms to the first audio + which voice spoke (device / gemini) on which kind of device
-- (phone / desktop), sent by the browser as a small beacon. Administration › Add-Ons › AI Assistant › Usage shows p50 / p90 per
-- day. No question or answer text is involved; admins see numbers only.
-- Rules: own messages only, each field set once (a second write is ignored), values range-checked. Audited ('sana.timing').
-- Safe to run twice.

ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS ms_first_token integer CHECK (ms_first_token BETWEEN 0 AND 600000);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS ms_total integer CHECK (ms_total BETWEEN 0 AND 600000);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS tool_rounds smallint CHECK (tool_rounds BETWEEN 0 AND 20);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS model_fast text CHECK (length(model_fast) <= 80);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS ms_first_audio integer CHECK (ms_first_audio BETWEEN 0 AND 600000);
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS voice_engine text CHECK (voice_engine IN ('device', 'gemini'));
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS voice_device text CHECK (voice_device IN ('phone', 'desktop'));

-- The message must be mine (my conversation) and an answer.
CREATE OR REPLACE FUNCTION erp._sana_my_answer(p_message bigint) RETURNS erp.sana_message
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE m erp.sana_message;
BEGIN
  SELECT x.* INTO m FROM erp.sana_message x JOIN erp.sana_conversation c ON c.conversation_id = x.conversation_id
   WHERE x.message_id = p_message AND x.role = 'assistant' AND c.user_id = erp.current_user_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Answer not found.' USING ERRCODE = 'P0002'; END IF;
  RETURN m;
END $$;

-- Edge Function, after `logged`: {ms_first_token, ms_total, tool_rounds, model_fast}.
CREATE OR REPLACE FUNCTION erp.sana_timing_set(p_message bigint, p_timing jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE m erp.sana_message := erp._sana_my_answer(p_message); c erp.sana_conversation;
        ft integer := least(greatest((p_timing ->> 'ms_first_token')::numeric, 0), 600000)::integer;
        tt integer := least(greatest((p_timing ->> 'ms_total')::numeric, 0), 600000)::integer;
        tr integer := least(greatest((p_timing ->> 'tool_rounds')::numeric, 0), 20)::integer;
        mf text := CASE WHEN (p_timing ->> 'model_fast') ~ '^[A-Za-z0-9._:/-]{1,80}$' THEN p_timing ->> 'model_fast' END;
BEGIN
  IF m.ms_total IS NOT NULL THEN RETURN jsonb_build_object('message_id', p_message, 'set', false); END IF;   -- once only
  UPDATE erp.sana_message SET ms_first_token = ft, ms_total = tt, tool_rounds = tr, model_fast = mf WHERE message_id = p_message;
  SELECT * INTO c FROM erp.sana_conversation WHERE conversation_id = m.conversation_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', c.company_code, 'sana.timing', 'sana_message', p_message::text,
            jsonb_build_object('user_id', c.user_id, 'ms_first_token', ft, 'ms_total', tt, 'tool_rounds', tr, 'model', m.model, 'model_fast', mf));
  RETURN jsonb_build_object('message_id', p_message, 'set', true);
END $$;

-- Browser beacon when the first sound of an answer starts: {ms_first_audio, engine: device|gemini, device: phone|desktop}.
CREATE OR REPLACE FUNCTION erp.sana_audio_beacon(p_message bigint, p_ms_first_audio integer, p_engine text, p_device text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE m erp.sana_message := erp._sana_my_answer(p_message); c erp.sana_conversation;
BEGIN
  IF p_engine NOT IN ('device', 'gemini') OR p_device NOT IN ('phone', 'desktop') OR p_ms_first_audio IS NULL OR p_ms_first_audio NOT BETWEEN 0 AND 600000 THEN
    RAISE EXCEPTION 'Send ms_first_audio (0–600000), engine device|gemini and device phone|desktop.' USING ERRCODE = 'P0001';
  END IF;
  IF m.ms_first_audio IS NOT NULL THEN RETURN jsonb_build_object('message_id', p_message, 'set', false); END IF;   -- first play only
  UPDATE erp.sana_message SET ms_first_audio = p_ms_first_audio, voice_engine = p_engine, voice_device = p_device WHERE message_id = p_message;
  SELECT * INTO c FROM erp.sana_conversation WHERE conversation_id = m.conversation_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', c.company_code, 'sana.timing', 'sana_message', p_message::text,
            jsonb_build_object('user_id', c.user_id, 'ms_first_audio', p_ms_first_audio, 'voice_engine', p_engine, 'voice_device', p_device));
  RETURN jsonb_build_object('message_id', p_message, 'set', true);
END $$;

-- Usage › speed: p50 / p90 per (Dubai) day, numbers only. Administration read (admin, IT or owner) for a company they may see.
CREATE OR REPLACE FUNCTION erp.sana_timing_usage(p_company varchar, p_days integer DEFAULT 14) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN (SELECT coalesce(jsonb_agg(d ORDER BY d ->> 'day' DESC), '[]') FROM (
    SELECT jsonb_build_object('day', day, 'answers', count(*),
      'first_token_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_first_token), 'first_token_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_first_token),
      'total_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_total), 'total_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_total),
      'first_audio_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_first_audio), 'first_audio_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_first_audio),
      'tool_rounds_avg', round(avg(tool_rounds), 2),
      'voice_device', count(*) FILTER (WHERE voice_engine = 'device'), 'voice_gemini', count(*) FILTER (WHERE voice_engine = 'gemini'),
      'voice_phone', count(*) FILTER (WHERE voice_device = 'phone')) AS d
      FROM (SELECT (m.created_at AT TIME ZONE 'Asia/Dubai')::date AS day, m.* FROM erp.sana_message m
              JOIN erp.sana_conversation c ON c.conversation_id = m.conversation_id
             WHERE c.company_code = p_company AND m.role = 'assistant' AND m.ms_total IS NOT NULL
               AND m.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 14), 1), 90))) x
     GROUP BY day) t);
END $$;

REVOKE ALL ON FUNCTION erp._sana_my_answer(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.sana_timing_set(bigint, jsonb), erp.sana_audio_beacon(bigint, integer, text, text), erp.sana_timing_usage(varchar, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_timing_set(bigint, jsonb), erp.sana_audio_beacon(bigint, integer, text, text), erp.sana_timing_usage(varchar, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';


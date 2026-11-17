-- 54_sana_live_usage.sql · S5 M3: Administration › AI Assistant › Speed gains Sana Live columns
-- sana_timing_usage (49) per Dubai day, now with:
--   · the existing Ask / voice columns WITHOUT Live turns (a Live turn's "first text" is its first audio, which would mix them up);
--   · live_turns, live_first_audio_p50 / p90 (ms from the end of the user's speech to Sana's first audio, from log_turn);
--   · live_sessions, live_minutes (from erp.sana_live_session: closed sessions their seconds, open ones up to now, never past the
--     token expiry), live_users.
-- A Live turn is an answer whose question row is via = 'live' (sana_log writes the question and the answer together).
-- Same guard as before: Administration read + the company.

CREATE OR REPLACE FUNCTION erp.sana_timing_usage(p_company varchar, p_days integer DEFAULT 14) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE d integer := least(greatest(coalesce(p_days, 14), 1), 90);
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN (SELECT coalesce(jsonb_agg(x.j ORDER BY x.day DESC), '[]') FROM (
    SELECT coalesce(a.day, l.day) AS day,
           coalesce(a.j, jsonb_build_object('answers', 0)) || jsonb_build_object('day', coalesce(a.day, l.day))
             || coalesce(l.j, jsonb_build_object('live_sessions', 0, 'live_minutes', 0, 'live_users', 0)) AS j
      FROM (
        SELECT day, jsonb_build_object('answers', count(*) FILTER (WHERE NOT is_live),
          'first_token_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_first_token) FILTER (WHERE NOT is_live),
          'first_token_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_first_token) FILTER (WHERE NOT is_live),
          'total_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_total) FILTER (WHERE NOT is_live),
          'total_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_total) FILTER (WHERE NOT is_live),
          'first_audio_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_first_audio) FILTER (WHERE NOT is_live),
          'first_audio_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_first_audio) FILTER (WHERE NOT is_live),
          'tool_rounds_avg', round(avg(tool_rounds) FILTER (WHERE NOT is_live), 2),
          'voice_device', count(*) FILTER (WHERE voice_engine = 'device' AND NOT is_live), 'voice_gemini', count(*) FILTER (WHERE voice_engine = 'gemini' AND NOT is_live),
          'voice_phone', count(*) FILTER (WHERE voice_device = 'phone' AND NOT is_live),
          'live_turns', count(*) FILTER (WHERE is_live),
          'live_first_audio_p50', percentile_disc(0.5) WITHIN GROUP (ORDER BY ms_first_audio) FILTER (WHERE is_live),
          'live_first_audio_p90', percentile_disc(0.9) WITHIN GROUP (ORDER BY ms_first_audio) FILTER (WHERE is_live)) AS j
          FROM (SELECT (m.created_at AT TIME ZONE 'Asia/Dubai')::date AS day, m.ms_first_token, m.ms_total, m.ms_first_audio, m.tool_rounds,
                       m.voice_engine, m.voice_device,
                       coalesce((SELECT q.via = 'live' FROM erp.sana_message q
                                  WHERE q.conversation_id = m.conversation_id AND q.role = 'user' AND q.message_id < m.message_id
                                  ORDER BY q.message_id DESC LIMIT 1), false) AS is_live
                  FROM erp.sana_message m
                  JOIN erp.sana_conversation c ON c.conversation_id = m.conversation_id
                 WHERE c.company_code = p_company AND m.role = 'assistant' AND m.ms_total IS NOT NULL
                   AND m.created_at > now() - make_interval(days => d)) t
         GROUP BY day) a
      FULL JOIN (
        SELECT (s.started_at AT TIME ZONE 'Asia/Dubai')::date AS day,
               jsonb_build_object('live_sessions', count(*), 'live_minutes', round(sum(erp._sana_live_seconds(s)) / 60.0, 1),
                                  'live_users', count(DISTINCT s.user_id)) AS j
          FROM erp.sana_live_session s
         WHERE s.company_code = p_company AND s.started_at > now() - make_interval(days => d)
         GROUP BY 1) l ON l.day = a.day) x);
END $$;

REVOKE ALL ON FUNCTION erp.sana_timing_usage(varchar, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_timing_usage(varchar, integer) TO authenticated;
NOTIFY pgrst, 'reload schema';


-- 53_sana_fixes.sql · S5 fixes after the first real Live run (17 Nov 2026)
-- 1. Empty vs denied in search: when the caller's role may not see items (or customers/suppliers), sana_find now returns that
--    part as {"denied": true} instead of leaving it out. Sana then says it is not available for the role, never "not found"
--    (the same empty-vs-denied rule as Ask). Same keys, same RLS, same queries; only the output of the hidden part changes.
-- 2. Warm-up ping: a pg_cron job calls sana-live-token and sana-live-tool every 5 minutes with {"ping": true} (no auth, no
--    data; the functions answer before any check) so a user's first Live call does not pay the Edge cold start (2.2 s measured).
--    Only where pg_cron and pg_net exist (Supabase); the local stack has neither and skips it.

-- ============ 1. sana_find: a hidden part is {"denied": true} ============
CREATE OR REPLACE FUNCTION erp._sana_find_out(p_see_p boolean, p_see_i boolean, p_partners jsonb, p_items jsonb, p_docs jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('partners', CASE WHEN p_see_p THEN p_partners ELSE '{"denied": true}'::jsonb END,
                            'items',    CASE WHEN p_see_i THEN p_items    ELSE '{"denied": true}'::jsonb END,
                            'documents', p_docs)
$$;

-- ============ 2. Warm-up ping for the Live functions (Supabase only) ============
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
    CREATE EXTENSION IF NOT EXISTS pg_net;
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'sana-live-warm';
    PERFORM cron.schedule('sana-live-warm', '*/5 * * * *', $job$
      SELECT net.http_post(url := 'https://xhsfkbbcejgwvqxpqdgq.supabase.co/functions/v1/' || f,
                           body := '{"ping": true}'::jsonb, headers := '{"content-type": "application/json"}'::jsonb, timeout_milliseconds := 5000)
        FROM unnest(ARRAY['sana-live-token', 'sana-live-tool']) AS f
    $job$);
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
      VALUES ('53_sana_fixes.sql', NULL, 'cron.schedule', 'cron.job', 'sana-live-warm',
              jsonb_build_object('schedule', '*/5 * * * *', 'calls', jsonb_build_array('sana-live-token', 'sana-live-tool'), 'body', '{"ping": true}'));
  ELSE
    RAISE NOTICE 'pg_cron / pg_net not available here: no warm-up job (local stack).';
  END IF;
END $$;

-- Sanford ERP - 14_realtime.sql
-- Publishes the migration console tables to Supabase Realtime so B7/B8 update live.
-- Safe to run again: a table that is already in the publication is skipped.
-- RLS still applies to Realtime: a user only receives rows they could SELECT.

DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;

  FOREACH t IN ARRAY ARRAY['migration_run', 'migration_step', 'migration_check', 'migration_issue'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'erp' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE erp.%I', t);
    END IF;
  END LOOP;
END $$;

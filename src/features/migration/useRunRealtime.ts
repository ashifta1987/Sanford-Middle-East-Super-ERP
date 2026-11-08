import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { migrationApi } from './api';
import { mk } from './queries';

/**
 * Live updates for one run: listens to migration_run / _step / _check / _issue filtered by run_id
 * and invalidates the run's queries. If the channel errors or closes, polls migration_status every 5 s.
 * Returns 'live' | 'polling' | 'connecting'.
 */
export function useRunRealtime(runId?: string) {
  const qc = useQueryClient();
  const [mode, setMode] = useState<'connecting' | 'live' | 'polling'>('connecting');

  useEffect(() => {
    if (!runId) return;
    let poll: ReturnType<typeof setInterval> | undefined;
    const invalidate = () => qc.invalidateQueries({ queryKey: mk.run(runId) });

    const startPolling = () => {
      setMode('polling');
      if (poll) return;
      poll = setInterval(async () => {
        try {
          const rows = await migrationApi.status(runId);
          qc.setQueryData(mk.status(runId), rows);
          void invalidate();
        } catch { /* keep polling */ }
      }, 5000);
    };

    const filter = `run_id=eq.${runId}`;
    const channel = supabase.channel(`migration-run-${runId}`);
    for (const table of ['migration_run', 'migration_step', 'migration_check', 'migration_issue']) {
      channel.on('postgres_changes', { event: '*', schema: 'erp', table, filter }, () => { void invalidate(); });
    }
    channel.subscribe((status) => {
      if (status === 'SUBSCRIBED') {
        setMode('live');
        if (poll) { clearInterval(poll); poll = undefined; }
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        startPolling();
      }
    });

    return () => {
      if (poll) clearInterval(poll);
      void supabase.removeChannel(channel);
    };
  }, [runId, qc]);

  return mode;
}

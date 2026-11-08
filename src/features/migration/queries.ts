import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { migrationApi } from './api';
import type { Decision, IssueStatus, RunKind, RunStatus, SignRole } from '@/lib/database.types';

export const mk = {
  all: ['migration'] as const,
  overview: () => [...mk.all, 'overview'] as const,
  openIssues: () => [...mk.all, 'openIssues'] as const,
  run: (id: string) => [...mk.all, 'run', id] as const,
  status: (id: string) => [...mk.all, 'run', id, 'status'] as const,
  steps: (id: string) => [...mk.all, 'run', id, 'steps'] as const,
  files: (id: string) => [...mk.all, 'run', id, 'files'] as const,
  review: (id: string, area?: string | null) => [...mk.all, 'run', id, 'review', area ?? 'all'] as const,
};

export const RUNNING: RunStatus[] = ['queued', 'validating', 'loading', 'rebuilding', 'checking'];

export const useOverview = () => useQuery({ queryKey: mk.overview(), queryFn: migrationApi.overview });
export const useOpenIssues = () => useQuery({ queryKey: mk.openIssues(), queryFn: () => migrationApi.openIssues() });

export const useRun = (id?: string) =>
  useQuery({ queryKey: mk.run(id ?? ''), queryFn: () => migrationApi.run(id!), enabled: Boolean(id) });

export const useStatus = (id?: string, opts?: { pollMs?: number | false }) =>
  useQuery({ queryKey: mk.status(id ?? ''), queryFn: () => migrationApi.status(id!), enabled: Boolean(id), refetchInterval: opts?.pollMs ?? false });

export const useSteps = (id?: string) =>
  useQuery({ queryKey: mk.steps(id ?? ''), queryFn: () => migrationApi.steps(id!), enabled: Boolean(id) });

export const useFiles = (id?: string) =>
  useQuery({ queryKey: mk.files(id ?? ''), queryFn: () => migrationApi.files(id!), enabled: Boolean(id) });

export const useReview = (id?: string, area?: string | null) =>
  useQuery({ queryKey: mk.review(id ?? '', area), queryFn: () => migrationApi.review(id!, area), enabled: Boolean(id) });

function useInvalidateRun() {
  const qc = useQueryClient();
  return (run?: string) => {
    if (run) void qc.invalidateQueries({ queryKey: mk.run(run) });
    void qc.invalidateQueries({ queryKey: mk.overview() });
    void qc.invalidateQueries({ queryKey: mk.openIssues() });
  };
}

export function useRequestRun() {
  const inv = useInvalidateRun();
  return useMutation({
    mutationFn: (a: { company: string; kind: RunKind; notes?: string }) => migrationApi.request(a.company, a.kind, a.notes),
    onSuccess: (run) => inv(run),
  });
}

export function useSubmitRun() {
  const inv = useInvalidateRun();
  return useMutation({ mutationFn: (run: string) => migrationApi.submit(run), onSuccess: (_d, run) => inv(run) });
}

export function useCancelRun() {
  const inv = useInvalidateRun();
  return useMutation({ mutationFn: (run: string) => migrationApi.cancel(run), onSuccess: (_d, run) => inv(run) });
}

export function useSetReportFigure(run: string) {
  const inv = useInvalidateRun();
  return useMutation({
    mutationFn: (a: { company: string; area: string; checkName: string; value: number | string | null; source?: string | null }) =>
      migrationApi.setReportFigure({ run, ...a }),
    onSuccess: () => inv(run),
  });
}

export function useResolveIssue(run: string) {
  const inv = useInvalidateRun();
  return useMutation({
    mutationFn: (a: { issue: number; status: IssueStatus; note?: string | null }) => migrationApi.resolveIssue(a.issue, a.status, a.note),
    onSuccess: () => inv(run),
  });
}

export function useSign(run: string) {
  const inv = useInvalidateRun();
  return useMutation({
    mutationFn: (a: { role: SignRole; decision: Decision; comment?: string | null }) => migrationApi.sign(run, a.role, a.decision, a.comment),
    onSuccess: () => inv(run),
  });
}

export function useGoLive(run: string) {
  const inv = useInvalidateRun();
  return useMutation({ mutationFn: (company: string) => migrationApi.goLive(company, run), onSuccess: () => inv(run) });
}


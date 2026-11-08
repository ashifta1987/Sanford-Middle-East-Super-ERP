import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { useAuth } from './AuthProvider';
import { PageLoading } from '@/components/States';

export type Access = 'signedIn' | 'migrationAdmin' | 'migrationReviewer';

/** Route guard (P0 › Who sees what). The database still enforces every rule with RLS. */
export function RequireAccess({ access, children }: { access: Access; children: ReactNode }) {
  const { session, ready, profile, profileLoading, isMigrationAdmin, signRoles } = useAuth();
  const loc = useLocation();

  if (!ready || profileLoading) return <PageLoading />;
  if (!session) return <Navigate to="/login" replace state={{ from: loc.pathname + loc.search }} />;
  if (access === 'signedIn') return <>{children}</>;
  if (!profile?.user) return <Navigate to="/no-access" replace />;

  const ok =
    access === 'migrationAdmin' ? isMigrationAdmin : isMigrationAdmin || signRoles.length > 0;
  return ok ? <>{children}</> : <Navigate to="/no-access" replace />;
}

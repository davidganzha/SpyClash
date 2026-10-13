import { AppServiceError, requireUUID } from './contracts.ts';

/** Shared by every writer; deletion takes the exclusive form of this lock. */
export async function accountGate(tx: any, userID: string, exclusive = false) {
  requireUUID(userID, 'actor');
  const key = 'spyclash-account:' + userID;
  if (exclusive) await tx`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`;
  else await tx`select pg_advisory_xact_lock_shared(hashtextextended(${key}, 0))`;
  const [profile] = await tx`select state,data from app_private.profiles where user_id=${userID}`;
  if (profile && profile.state !== 'active') {
    throw new AppServiceError('account_unavailable', 'This account is being deleted or has been deleted.', 403);
  }
  if (!exclusive) {
    // Keep the standalone core compatible before the application schema exists.
    const [schema] = await tx`select to_regclass('app_private.legacy_import_runs') is not null as available`;
    if (schema.available) {
      const pending = await tx`select 1 from app_private.legacy_import_runs where user_id=${userID} and status='pending' limit 1`;
      if (pending.length) throw new AppServiceError('legacy_import_pending', 'Your saved data is still being transferred. Sign in again to continue.', 503, true);
    }
  }
  return profile;
}

/** Auth verifies this exact bearer first. session_id is then used only as a DB key. */
export function verifiedSessionID(token: string): string {
  try {
    const segment = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(segment.padEnd(Math.ceil(segment.length / 4) * 4, '=')));
    return requireUUID(claims.session_id, 'session');
  } catch { throw new AppServiceError('invalid_session', 'Sign in again to continue.', 401); }
}

export async function sessionGate(db: any, userID: string, sessionID: string) {
  const rows = await db`select created_at > clock_timestamp()-interval '65 minutes' as recent
    from auth.sessions where id=${sessionID} and user_id=${userID}
    and (not_after is null or not_after > clock_timestamp())`;
  if (!rows.length) throw new AppServiceError('session_revoked', 'Sign in again to continue.', 401);
  if (!rows[0].recent) {
    const [schema] = await db`select to_regclass('app_private.legacy_session_accounts') is not null as available`;
    if (schema.available && (await db`select 1 from app_private.legacy_session_accounts where user_id=${userID}`).length) {
      // A direct Supabase refresh must not extend legacy-backed access forever
      // after the source account was revoked. Native re-exchanges before its
      // one-hour token expires; the extra five minutes tolerate clock skew.
      throw new AppServiceError('legacy_session_revalidation_required', 'Sign in again to verify your Base44 account.', 401);
    }
  }
}

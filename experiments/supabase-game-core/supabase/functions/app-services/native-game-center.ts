import {AppServiceError} from './contracts.ts';

/** Server-owned identity only. Neither client provider flags nor editable Auth
 * user_metadata can opt an existing Base44 account out of its ownership rules.
 * Caller holds the account lock; every writer of either mapping uses that lock. */
export async function nativeGameCenterAccount(tx:any,userID:string) {
  const [schema] = await tx`select to_regclass('game_center_private.accounts') is not null as present`;
  if (!schema.present) return undefined;
  const [account] = await tx`select identity_key,user_id,state from game_center_private.accounts where user_id=${userID}`;
  if (!account) return undefined;
  const conflicting = await tx`select 1 from app_private.legacy_links where user_id=${userID}
    union all select 1 from app_private.legacy_session_accounts where user_id=${userID}
    union all select 1 from app_private.main_account_deletions where user_id=${userID} limit 1`;
  if (conflicting.length) throw new AppServiceError('game_center_identity_conflict','Account ownership needs to be verified before continuing.',409);
  if (!['ready','deleted'].includes(account.state)) throw new AppServiceError('game_center_account_pending','Account setup is not complete. Try signing in again.',503,true);
  return account;
}

export async function resolveNativeGameCenterAccount(db:any,userID:string) {
  return await db.begin(async (tx:any) => {
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    return await nativeGameCenterAccount(tx,userID);
  });
}

/** Called after authenticated native ownership and the account lock. Apple
 * canonical freshness is reconciled by the HTTP handler before consumption. */
export async function nativeGameCenterHasMembership(tx:any,userID:string) {
  const rows=await tx`select 1 from app_private.entitlements where user_id=${userID} and active and expires_at>clock_timestamp()
    union all select 1 from app_private.membership_grants where user_id=${userID} and active and (expires_at is null or expires_at>clock_timestamp()) limit 1`;
  return rows.length>0;
}

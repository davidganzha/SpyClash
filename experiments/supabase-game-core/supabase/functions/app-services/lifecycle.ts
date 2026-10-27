import type { AppContext } from './contracts.ts';
import { AppServiceError, requireUUID } from './contracts.ts';
import { cleanupBillingPush } from './membership.ts';
import { assertMainDeletionEvidence } from './main-account-deletion.ts';
import { eraseAccountArchives } from './deletion-archive.ts';

/** Called only while holding the actor's exclusive account gate. */
export async function deleteAccount(ctx: AppContext, body: any) {
  const mainDeletion = await assertMainDeletionEvidence(ctx, body);
  const { tx, actor, now } = ctx;
  await eraseAccountArchives(ctx,mainDeletion);
  await tx`insert into app_private.profiles(user_id,state,contact_email,data) values(${actor.id},'deleting','','{}') on conflict(user_id) do update set state='deleting',updated_at=${now}`;
  // Lock shared rooms in a stable order, then end them atomically. No peer can
  // observe a partially scrubbed roster or continue a deleted player's turn.
  const rooms = await tx`select r.id,r.code,r.revision from full_game_private.rooms r
    where exists(select 1 from full_game_private.members m where m.room_id=r.id and m.user_id=${actor.id})
    order by r.id for update`;
  for (const room of rooms) {
    const revision = Number(room.revision) + 1;
    const state = { id: room.id, code: room.code, status: 'ended', closed: true, players: [], room_revision: revision, updated_date: now.toISOString() };
    await tx`update full_game_private.rooms set state=${tx.json(state)},closed=true,revision=${revision},updated_at=${now} where id=${room.id}`;
    await tx`delete from full_game_private.members where room_id=${room.id}`;
    await tx`insert into public.full_game_room_signals(room_id,revision,updated_at) values(${room.id},${revision},${now}) on conflict(room_id) do update set revision=excluded.revision,updated_at=excluded.updated_at`;
    await tx`insert into full_game_private.outbox(id,room_id,event) values(${'account-deleted:'+actor.id+':'+room.id},${room.id},${tx.json({type:'room_closed',room_id:room.id,revision,reason:'account_deleted'})}) on conflict(id) do nothing`;
  }
  await tx`delete from full_game_private.word_packs where owner_id=${actor.id}`;
  await tx`delete from full_game_private.history where player_id=${actor.id}`;
  await tx`delete from full_game_private.receipts where actor_id=${actor.id}`;
  await tx`delete from app_private.receipts where actor_id=${actor.id}`;
  await tx`update app_private.community_reports set comment_id=null where comment_id in (select id from app_private.profile_comments where author_user_id=${actor.id} or target_user_id=${actor.id})`;
  await tx`update app_private.community_reports set reporter_user_id=null where reporter_user_id=${actor.id}`;
  await tx`update app_private.community_reports set reported_user_id=null,data='{}' where reported_user_id=${actor.id}`;
  await tx`delete from app_private.profile_comments where author_user_id=${actor.id} or target_user_id=${actor.id}`;
  await tx`delete from app_private.friendships where requester_id=${actor.id} or addressee_id=${actor.id}`;
  await tx`delete from app_private.room_invites where sender_user_id=${actor.id} or recipient_user_id=${actor.id}`;
  await tx`delete from app_private.notification_events where actor_id=${actor.id} or recipient_id=${actor.id}`;
  await tx`delete from app_private.notification_read_receipts where user_id=${actor.id}`;
  await tx`delete from app_private.profile_watchers where viewer_id=${actor.id} or profile_id=${actor.id}`;
  await tx`delete from public.app_profile_signals where recipient_user_id=${actor.id} or profile_user_id=${actor.id}`;
  await tx`delete from public.app_user_signals where recipient_user_id=${actor.id}`;
  await tx`delete from app_private.legacy_pending_social where owner_id=${actor.id}
    or peer_legacy_id in (select legacy_user_id from app_private.legacy_links where user_id=${actor.id})`;
  await tx`delete from app_private.legacy_import_history_stage where user_id=${actor.id}`;
  await tx`delete from app_private.legacy_import_rows where user_id=${actor.id}`;
  await tx`delete from app_private.legacy_import_runs where user_id=${actor.id}`;
  // Provider ownership tombstones survive; content and deliverable tokens do not.
  await cleanupBillingPush(ctx);
  await tx`update app_private.profiles set state='deleted',contact_email='',spy_id=null,data='{}',updated_at=${now} where user_id=${actor.id}`;
  // JWTs cannot reopen application access: accountGate rejects the tombstone.
  // The worker removes the Auth identity and refresh sessions through Auth's
  // supported admin API, retried durably if its network response is lost.
  await tx`insert into app_private.lifecycle_jobs(user_id) values(${actor.id}) on conflict(user_id) do nothing`;
  if (mainDeletion?.native_account) {
    await tx`delete from game_center_private.generation_requests where user_id=${actor.id}`;
    await tx`update game_center_private.accounts set state='deleted',lease_id=null,lease_until=null,updated_at=${now}
      where user_id=${actor.id} and identity_key=${mainDeletion.identity_key}`;
  } else if (mainDeletion) await tx`update app_private.main_account_deletions set phase='complete',erasure_proof='{}',updated_at=${now} where user_id=${actor.id}`;
  return { success: true, deleted: true, auth_cleanup_pending: true,
    ...(mainDeletion?.native_account ? {native_account_deleted:true}
      : mainDeletion ? {original_account_deleted:true,manual_apple_revocation_required:mainDeletion.manual_apple_revocation_required} : {}) };
}

/** Idempotent, bounded maintenance pass; only an authenticated internal worker calls it. */
export async function processAccountDeletionJobs(db: any, config: Record<string, string | undefined>, fetcher: typeof fetch = fetch, targetUserID?: string) {
  if (targetUserID) requireUUID(targetUserID, 'user_id');
  const origin = config.SUPABASE_URL || '';
  if (origin !== 'https://bbkfsgnordtdiblgdzkg.supabase.co' && !/^http:\/\/127\.0\.0\.1:56321$/.test(origin)) throw new AppServiceError('unsafe_auth_origin','Unexpected Auth origin.',503);
  const key = config.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new AppServiceError('auth_admin_unconfigured','Auth cleanup is not configured.',503);
  const jobs = await db.begin(async (tx: any) => await tx`update app_private.lifecycle_jobs set lease_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '90 seconds',attempts=attempts+1
    where user_id in (select user_id from app_private.lifecycle_jobs where phase<>'complete' and next_attempt_at<=clock_timestamp() and (lease_until is null or lease_until<clock_timestamp())
      ${targetUserID ? tx`and user_id=${targetUserID}` : tx``}
      order by created_at limit 3 for update skip locked) returning user_id,attempts,lease_id`);
  let completed = 0;
  for (const job of jobs) {
    const owned = await db`update app_private.lifecycle_jobs set lease_until=clock_timestamp()+interval '90 seconds'
      where user_id=${job.user_id} and lease_id=${job.lease_id} and phase<>'complete' returning user_id`;
    if (!owned.length) continue;
    try {
      const response = await fetcher(origin + '/auth/v1/admin/users/' + job.user_id, { method:'DELETE', headers:{ apikey:key,Authorization:'Bearer '+key }, signal:AbortSignal.timeout(10000) });
      if (!response.ok && response.status !== 404) throw new Error('auth_cleanup_' + response.status);
      await db`update app_private.lifecycle_jobs set phase='complete',lease_until=null,last_error=null,updated_at=clock_timestamp() where user_id=${job.user_id} and lease_id=${job.lease_id} and phase<>'complete'`;
      completed++;
    } catch {
      const delay = Math.min(3600, 2 ** Math.min(Number(job.attempts), 10));
      await db`update app_private.lifecycle_jobs set lease_until=null,next_attempt_at=clock_timestamp()+${delay}*interval '1 second',last_error='auth_cleanup_retry',updated_at=clock_timestamp() where user_id=${job.user_id} and lease_id=${job.lease_id} and phase<>'complete'`;
    }
  }
  return { attempted:jobs.length,completed };
}

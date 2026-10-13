import { AppServiceError, requireUUID } from './contracts.ts';
import type { AppActor, AppContext } from './contracts.ts';
import { accountGate } from './account-gate.ts';
import { ensureProfile, dispatchProfile } from './profile.ts';
import { dispatchCommunity } from './community.ts';
import { dispatchInbox } from './inbox.ts';
import { dispatchMembership } from './membership.ts';
import { dispatchPush } from './push.ts';
import { dispatchLegacy } from './legacy.ts';
import { deleteAccount } from './lifecycle.ts';
import { commandHash } from '../full-game-core/service.ts';

const readActions: Record<string, Set<string>> = {
  profile: new Set(['current']),
  community: new Set(['state', 'directory', 'search', 'profile']),
  notifications: new Set(['summary', 'list']),
  membership: new Set(['check', 'check_subscription']),
  push: new Set(),
  legacy: new Set(['status', 'legacy_status']),
};
async function appCommandHash(body:any) {
  // Legacy bearer rotation does not change the logical command. Its immutable
  // linked provider identity is verified separately; credentials are not data.
  const logical = { ...body };
  if (body.service === 'legacy') delete logical.base44_access_token;
  return await commandHash(logical);
}
export function validateCommand(body: any) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || !readActions[body.service]) {
    throw new AppServiceError('invalid_service', 'Unknown application service.');
  }
  if (typeof body.action !== 'string' || body.action.length > 80) throw new AppServiceError('invalid_action', 'Invalid action.');
  const mutation = !readActions[body.service].has(body.action);
  if (mutation) requireUUID(body.request_id, 'request_id');
  // Client JSON must never become trusted external verification evidence.
  if ('evidence' in body || 'actor' in body || 'config' in body) throw new AppServiceError('reserved_field', 'Reserved request field.');
  return mutation;
}

export async function replayAppReceipt(db: any, actor: AppActor, body: any) {
  if (!validateCommand(body)) return null;
  const hash = await appCommandHash(body);
  return await db.begin(async (tx: any) => {
    await accountGate(tx, actor.id);
    const [prior] = await tx`select request_hash,status,response from app_private.receipts where actor_id=${actor.id} and request_id=${body.request_id}`;
    if (!prior) return null;
    if (prior.request_hash !== hash) return { status: 409, body: { code: 'request_id_reused', message: 'This request ID belongs to a different action.', retryable: false } };
    return { status: prior.status, body: prior.response };
  });
}

async function dispatch(ctx: AppContext, body: any) {
  switch (body.service) {
    case 'profile': return body.action === 'delete' ? await deleteAccount(ctx, body) : await dispatchProfile(ctx, body);
    case 'community': return await dispatchCommunity(ctx, body);
    case 'notifications': return await dispatchInbox(ctx, body);
    case 'membership': return await dispatchMembership(ctx, body);
    case 'push': return await dispatchPush(ctx, body);
    case 'legacy': return await dispatchLegacy(ctx, body);
    default: throw new AppServiceError('invalid_service', 'Unknown application service.');
  }
}

export async function executeApp(db: any, actor: AppActor, body: any,
  config: Record<string, string | undefined> = {}, evidence?: any) {
  requireUUID(actor.id, 'actor');
  if (actor.email !== actor.id + '@example.test') throw new AppServiceError('invalid_actor', 'Invalid account.', 401);
  const mutation = validateCommand(body);
  const hash = mutation ? await appCommandHash(body) : null;
  return await db.begin(async (tx: any) => {
    await tx`set local statement_timeout = '8s'`;
    await tx`set local lock_timeout = '6s'`;
    // Fixed ordering: account gate -> receipt -> domain rows. Account deletion
    // cannot race a writer that has already passed authentication.
    const deleting = body.service === 'profile' && body.action === 'delete';
    if (deleting) {
      await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:' + actor.id}, 0))`;
    } else await accountGate(tx, actor.id);
    if (mutation) {
      await tx`select pg_advisory_xact_lock(hashtextextended(${'app-request:' + actor.id + ':' + body.request_id}, 0))`;
      const [prior] = await tx`select request_hash,status,response from app_private.receipts where actor_id=${actor.id} and request_id=${body.request_id}`;
      if (prior) {
        if (prior.request_hash !== hash) return { status: 409, body: { code: 'request_id_reused', message: 'This request ID belongs to a different action.', retryable: false } };
        return { status: prior.status, body: prior.response };
      }
    }
    const [{ now }] = await tx`select clock_timestamp() as now`;
    const ctx: AppContext = { tx, actor, now: new Date(now), config, evidence };
    if (!deleting) await ensureProfile(ctx);
    let result: {status: number; body: any};
    try {
      // A rejected business command must roll back *all* domain writes before
      // the rejection itself becomes an immutable receipt.
      const response = await tx.savepoint(async (savepoint: any) => await dispatch({ ...ctx, tx: savepoint }, body));
      result = { status: 200, body: response };
    } catch (error: any) {
      if (!(error instanceof AppServiceError) || error.status >= 500 || error.retryable) throw error;
      result = { status: error.status, body: { code: error.code, message: error.message, retryable: false } };
    }
    if (mutation) {
      await tx`insert into app_private.receipts(actor_id,request_id,request_hash,status,response)
        values (${actor.id},${body.request_id},${hash},${result.status},${tx.json(result.body)})`;
    }
    return result;
  });
}

import { randomUUID } from 'node:crypto';
import { GameCenterError } from './assertion.mjs';
const busy = () => new GameCenterError('game_center_busy', 'Another sign-in is being completed. Please retry.', 409, true);
const unavailableAccount = () => new GameCenterError('game_center_account_unavailable', 'This account is unavailable.', 410);

export function createRepository(db, {ensureProfile}) {
  async function available(tx, id) {
    // Same lock order as account deletion in app-services.
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:' + id},0))`;
    const [profile] = await tx`select state from app_private.profiles where user_id=${id}`;
    if (profile && profile.state !== 'active') throw unavailableAccount();
  }
  async function owned(tx, account) {
    await available(tx, account.user_id);
    const [row] = await tx`select * from gc000_private.accounts where identity_key=${account.identity_key}
      and lease_id=${account.lease_id} and lease_until>clock_timestamp() for update`;
    if (!row) throw busy();
    if (row.state === 'deleted') throw unavailableAccount();
    return row;
  }
  return {
    async reserve(assertion) {
      return await db.begin(async tx => {
        // Validate cryptography before calling this method. Invalid traffic cannot
        // write replay rows or reserve accounts. Expired proof keys are disposable.
        await tx`delete from gc000_private.used_assertions where expires_at<clock_timestamp()`;
        const proof = await tx`insert into gc000_private.used_assertions(replay_key,expires_at)
          values(${assertion.replayKey},${new Date(assertion.timestamp + 330_000)}) on conflict do nothing returning replay_key`;
        if (!proof.length) throw new GameCenterError('game_center_assertion_replayed', 'Request a new Game Center verification.', 409);
        // The only identity lookup is the digest of signed teamPlayerID + fixed app.
        await tx`insert into gc000_private.accounts(identity_key,user_id,shadow_email)
          values(${assertion.identityKey},${randomUUID()},${randomUUID().replaceAll('-', '') + '@gc000.spyclash.invalid'})
          on conflict(identity_key) do nothing`;
        const [account] = await tx`select * from gc000_private.accounts where identity_key=${assertion.identityKey}`;
        await available(tx, account.user_id);
        if (account.state === 'deleted') throw unavailableAccount();
        const [leased] = await tx`update gc000_private.accounts set lease_id=${randomUUID()},lease_until=clock_timestamp()+interval '60 seconds',updated_at=clock_timestamp()
          where identity_key=${assertion.identityKey} and (lease_until is null or lease_until<=clock_timestamp()) returning *`;
        if (!leased) throw busy();
        return leased;
      });
    },
    async renew(account) {
      await db.begin(async tx => {
        await owned(tx, account);
        await tx`update gc000_private.accounts set lease_until=clock_timestamp()+interval '60 seconds',updated_at=clock_timestamp()
          where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
      });
    },
    async provisionProfile(account, displayName) {
      await db.begin(async tx => {
        await owned(tx, account);
        await ensureProfile({tx, now: new Date(), config: {}, actor: {id: account.user_id,
          email: account.user_id + '@example.test', contactEmail: '', full_name: displayName, metadata: {}}});
      });
    },
    async complete(account, sessionID) {
      await db.begin(async tx => {
        await owned(tx, account);
        const sessions = await tx`select id from auth.sessions where id=${sessionID} and user_id=${account.user_id}
          and (not_after is null or not_after>clock_timestamp())`;
        if (!sessions.length) throw unavailableAccount();
        await tx`update gc000_private.accounts set state='ready',lease_id=null,lease_until=null,updated_at=clock_timestamp()
          where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
      });
    },
    async release(account) {
      await db`update gc000_private.accounts set lease_id=null,lease_until=null,updated_at=clock_timestamp()
        where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
    },
  };
}

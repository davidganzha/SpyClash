import {AppleSessionError, type AppleConfig, type Assertion, clientID, mismatch} from './contracts.ts';
const busy=()=>new AppleSessionError('apple_session_busy',409,true);
const unavailableAccount=()=>new AppleSessionError('apple_account_unavailable',410);
export function createAppleRepository(db: any, config: AppleConfig, ensureProfile: (context:any)=>Promise<unknown>) {
  async function locks(tx:any, account:any) {
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+account.user_id},0))`;
    await tx`select pg_advisory_xact_lock(hashtextextended(${'apple-identity:'+account.identity_key},0))`;
  }
  async function available(tx:any, account:any) {
    const [profile]=await tx`select state from app_private.profiles where user_id=${account.user_id}`;
    if (profile && profile.state!=='active') throw unavailableAccount();
    if (account.state==='deleted' || account.state==='deleting') throw unavailableAccount();
    if (!account.migration_complete) throw new AppleSessionError('apple_migration_pending',503,true);
  }
  async function owned(tx:any, account:any) {
    await locks(tx,account);
    const [row]=await tx`select * from apple_private.accounts where identity_key=${account.identity_key} and lease_id=${account.lease_id} and lease_until>clock_timestamp() for update`;
    if (!row) throw busy();
    await available(tx,row); return row;
  }
  return {
    async reserve(assertion:Assertion) {
      return await db.begin(async(tx:any)=>{
        let [account]=await tx`select * from apple_private.accounts where identity_key=${assertion.identityKey}`;
        if (!account) {
          if (!config.newAccountsEnabled || !config.migrationCoverageVerified) throw new AppleSessionError('apple_migration_pending',503,true);
          const candidate={identity_key:assertion.identityKey,user_id:crypto.randomUUID()};
          await locks(tx,candidate);
          await tx`insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,migration_version,migration_complete)
            values(${assertion.identityKey},${assertion.subjectKey},${clientID},${candidate.user_id},${crypto.randomUUID().replaceAll('-','')+'@apple.spyclash.invalid'},1,true) on conflict(identity_key) do nothing`;
          [account]=await tx`select * from apple_private.accounts where identity_key=${assertion.identityKey}`;
          // A concurrent new identity reservation must retry using its winner's
          // account-before-identity lock order rather than invert that order.
          if (account.user_id!==candidate.user_id) throw busy();
        } else {
          await locks(tx,account);
          [account]=await tx`select * from apple_private.accounts where identity_key=${assertion.identityKey} for update`;
        }
        if (account.subject_key!==assertion.subjectKey || account.client_id!==clientID) throw mismatch();
        await available(tx,account);
        // An unresolved older grant remains a deletion obligation, not an
        // authentication veto. The account lease serializes live issuers; a
        // fresh independently verified code can recover sign-in after an outage.
        const [leased]=await tx`update apple_private.accounts set lease_id=${crypto.randomUUID()},lease_until=clock_timestamp()+interval '120 seconds',updated_at=clock_timestamp()
          where identity_key=${account.identity_key} and (lease_until is null or lease_until<=clock_timestamp()) returning *`;
        if (!leased) throw busy();
        const proof=await tx`insert into apple_private.attempts(request_id,identity_key,nonce_hash,code_hash,state,expires_at)
          values(${assertion.requestID},${assertion.identityKey},${assertion.nonceHash},${assertion.codeHash},'reserved',clock_timestamp()+interval '10 minutes') on conflict do nothing returning request_id`;
        if (!proof.length) throw new AppleSessionError('apple_assertion_replayed',409);
        return {...leased,request_id:assertion.requestID};
      });
    },
    async renew(account:any) {
      await db.begin(async(tx:any)=>{
        await owned(tx,account);
        await tx`update apple_private.accounts set lease_until=clock_timestamp()+interval '120 seconds',updated_at=clock_timestamp() where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
      });
    },
    async beginExchange(account:any) {
      await db.begin(async(tx:any)=>{
        await owned(tx,account);
        const rows=await tx`update apple_private.attempts set state='exchanging',updated_at=clock_timestamp() where request_id=${account.request_id} and identity_key=${account.identity_key} and state='reserved' returning request_id`;
        if (!rows.length) throw busy();
      });
    },
    async trackGrant(account:any, grant:any) {
      await db.begin(async(tx:any)=>{
        // Durable issuance boundary survives worker lease expiry. Deletion
        // refuses exchanging/uncertain attempts until this grant is tracked.
        await locks(tx,account);
        const [attempt]=await tx`select state from apple_private.attempts where request_id=${account.request_id} and identity_key=${account.identity_key} for update`;
        if (!attempt || !['exchanging','uncertain'].includes(attempt.state)) throw busy();
        await tx`insert into apple_private.grants(id,user_id,client_id,ciphertext,iv,encryption_version,binding)
          values(${grant.id},${account.user_id},${clientID},${grant.ciphertext},${grant.iv},${grant.encryption_version},${grant.binding})`;
        await tx`update apple_private.attempts set state='grant_stored',updated_at=clock_timestamp() where request_id=${account.request_id}`;
      });
    },
    async revoked(grantID:string) {
      await db`update apple_private.grants set state='revoked',revoked_at=clock_timestamp(),updated_at=clock_timestamp(),revision=${crypto.randomUUID()},ciphertext='',iv='' where id=${grantID}`;
    },
    async settleFailure(account:any, uncertain:boolean) {
      await db`update apple_private.attempts set state=${uncertain?'uncertain':'failed'},updated_at=clock_timestamp() where request_id=${account.request_id} and identity_key=${account.identity_key} and state<>'complete'`;
    },
    async provisionProfile(account:any, displayName:string) {
      await db.begin(async(tx:any)=>{
        const row=await owned(tx,account);
        // An imported account must keep its profile and purchases intact.
        if (!row.legacy_user_id) await ensureProfile({tx,now:new Date(),config:{},actor:{id:account.user_id,email:account.user_id+'@example.test',contactEmail:'',full_name:displayName,metadata:{}}});
      });
    },
    async complete(account:any, sessionID:string) {
      await db.begin(async(tx:any)=>{
        await owned(tx,account);
        const sessions=await tx`select id from auth.sessions where id=${sessionID} and user_id=${account.user_id} and (not_after is null or not_after>clock_timestamp())`;
        if (!sessions.length) throw unavailableAccount();
        const completed=await tx`update apple_private.attempts set state='complete',updated_at=clock_timestamp() where request_id=${account.request_id} and state='grant_stored' returning request_id`;
        if (!completed.length) throw busy();
        await tx`update apple_private.accounts set state='ready',lease_id=null,lease_until=null,updated_at=clock_timestamp() where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
      });
    },
    async release(account:any) {
      await db`update apple_private.accounts set lease_id=null,lease_until=null,updated_at=clock_timestamp() where identity_key=${account.identity_key} and lease_id=${account.lease_id}`;
    },
  };
}

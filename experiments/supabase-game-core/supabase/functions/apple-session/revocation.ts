import {createAppleAPI} from './apple.ts';
import {decryptGrant} from './crypto.ts';
import {AppleSessionError, type AppleConfig, unavailable} from './contracts.ts';
/** Caller first places the account in deleting state under the exclusive
 * spyclash-account:<uuid> gate. No network transaction holds a database lock. */
export async function revokeAllAppleGrants(db:any, config:Pick<AppleConfig,'teamID'|'keyID'|'privateKeyPEM'|'encryptionKey'>, userID:string, fetcher:typeof fetch=fetch) {
  const apple=createAppleAPI(config,fetcher); let revoked=0;
  const assertBoundary=async(tx:any)=>{
    await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+userID},0))`;
    const [account]=await tx`select state from apple_private.accounts where user_id=${userID} for update`;
    if(!account || account.state!=='deleting')throw new AppleSessionError('apple_deletion_boundary_required',409);
    const pending=await tx`select a.request_id from apple_private.attempts a join apple_private.accounts p on p.identity_key=a.identity_key where p.user_id=${userID} and a.state in ('exchanging','uncertain') limit 1`;
    if(pending.length)throw new AppleSessionError('apple_issuance_unresolved',409,true);
  };
  for(let count=0;count<1000;count++) {
    const grant=await db.begin(async(tx:any)=>{
      await assertBoundary(tx);
      const [row]=await tx`select * from apple_private.grants where user_id=${userID} and state in ('active','revoking') order by created_at,id limit 1 for update`;
      if(!row)return undefined;
      const revision=crypto.randomUUID();
      await tx`update apple_private.grants set state='revoking',revision=${revision},updated_at=clock_timestamp() where id=${row.id}`;
      return {...row,revision};
    });
    if(!grant)return {revoked};
    const token=await decryptGrant(grant,config.encryptionKey);
    await apple.revoke(token,grant.client_id);
    await db.begin(async(tx:any)=>{
      await assertBoundary(tx);
      // Revocation is idempotent. Never erase a replacement credential or undo
      // another worker's newer revision while acknowledging this exact grant.
      const rows=await tx`update apple_private.grants set state='revoked',ciphertext='',iv='',revoked_at=clock_timestamp(),updated_at=clock_timestamp() where id=${grant.id} and user_id=${userID} and revision=${grant.revision} and state='revoking' returning id`;
      if(rows.length)revoked++;
    });
  }
  throw unavailable();
}

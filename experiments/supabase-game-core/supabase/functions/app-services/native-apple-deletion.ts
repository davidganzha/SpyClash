import {AppServiceError,requireUUID,type AppActor} from './contracts.ts';
import {nativeAccount} from './native-account.ts';
import {canonicalBase44Configuration,boundedLegacyJSON} from './legacy-provider.ts';
import {signedArchiveErasureRequest,verifiedArchiveErasureProof} from './deletion-archive-proof.ts';
import {signedAppleSourceErasureRequest} from './apple-source-erasure.ts';
import {digest} from './integration-crypto.ts';
import type {revokeAllAppleGrants} from '../apple-session/revocation.ts';

type Config=Record<string,string|undefined>;
const pending=()=>new AppServiceError('apple_account_deletion_pending','Account deletion is still being confirmed. Retry the same request.',503,true);
function revocationConfig(config:Config) {
  const teamID=config.APPLE_TEAM_ID||'',keyID=config.APPLE_KEY_ID||'',encryptionKey=config.APPLE_GRANT_ENCRYPTION_KEY||config.PUSH_TOKEN_ENCRYPTION_KEY||'';
  let privateKeyPEM='';try{privateKeyPEM=atob(config.APPLE_PRIVATE_KEY_P8_B64||'');}catch{/* validated below */}
  if(!/^[A-Z0-9]{10}$/.test(teamID)||!/^[A-Z0-9]{10}$/.test(keyID)||!encryptionKey||!privateKeyPEM.includes('-----BEGIN PRIVATE KEY-----'))
    throw new AppServiceError('apple_revocation_unconfigured','Apple account revocation is not configured.',503);
  return {teamID,keyID,encryptionKey,privateKeyPEM};
}
async function recoveryToken(config:Config,userID:string,requestID:string) {
  const secret=config.APP_DELETION_RECEIPT_SECRET;
  if(!secret||!/^[a-f0-9]{64}$/i.test(secret))throw new AppServiceError('deletion_recovery_unconfigured','Deletion recovery is not configured.',503);
  const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const bytes=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('spyclash-delete-recovery-v1:'+userID+':'+requestID));
  return [...new Uint8Array(bytes)].map(v=>v.toString(16).padStart(2,'0')).join('');
}

/** Durable deletion intent fences both issuance and app writers before network
 * revocation/erasure. Lost responses leave a retryable intent, never success. */
export async function prepareNativeAppleDeletion(input:{actor:AppActor,body:Record<string,any>,config:Config},deps:{db:any,fetch?:typeof fetch,revoke?:typeof revokeAllAppleGrants}) {
  const {db}=deps,fetcher=deps.fetch||fetch,userID=input.actor.id,commandID=requireUUID(input.body.request_id,'request_id');
  const configured=revocationConfig(input.config);
  const account=await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    return await nativeAccount(tx,userID);
  });
  if(account?.legacy_user_id) {
    const [prior]=await db`select 1 from apple_private.deletions where user_id=${userID}`;
    if(!prior) {
      const destination=canonicalBase44Configuration(input.config);
      const response=await fetcher(destination.origin+'/api/apps/'+destination.appID+'/functions/deleteAccountPublic',{
        method:'POST',headers:{'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'},
        body:JSON.stringify({action:'deletion_capabilities'}),credentials:'omit',redirect:'error',signal:AbortSignal.timeout(10_000)});
      if(!response.ok||(await boundedLegacyJSON(response))?.apple_source_erasure_protocol!=='spyclash-apple-source-erasure-v1')
        throw new AppServiceError('apple_source_erasure_unconfigured','Historical account erasure is not configured.',503);
      await signedArchiveErasureRequest(db,input.config,userID,account.legacy_user_id,commandID);
    }
  }
  const intent=await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+userID},0))`;
    const account=await nativeAccount(tx,userID);
    if(account?.provider!=='apple')throw pending();
    let [existing]=await tx`select * from apple_private.deletions where user_id=${userID} for update`;
    if(existing?.phase==='complete')return {...existing,account};
    if(account.state==='deleted')throw pending();
    if(!existing) [existing]=await tx`insert into apple_private.deletions(user_id,request_id) values(${userID},${commandID}) returning *`;
    if(account.legacy_user_id) {
      const destination=canonicalBase44Configuration(input.config);
      await recoveryToken(input.config,userID,existing.request_id);
      const [link]=await tx`select legacy_user_id,source_origin from app_private.legacy_links where user_id=${userID}`;
      if(!link||link.legacy_user_id!==account.legacy_user_id||link.source_origin!==destination.origin)throw pending();
      await tx`insert into app_private.main_account_deletions(user_id,request_id,legacy_user_id,source_origin,source_app_id)
        values(${userID},${existing.request_id},${account.legacy_user_id},${destination.origin},${destination.appID}) on conflict(user_id) do nothing`;
      const [source]=await tx`select * from app_private.main_account_deletions where user_id=${userID}`;
      if(source.legacy_user_id!==account.legacy_user_id||source.request_id!==existing.request_id||source.source_origin!==destination.origin||source.source_app_id!==destination.appID)throw pending();
    }
    await tx`update apple_private.accounts set state='deleting',lease_id=null,lease_until=null,updated_at=clock_timestamp() where user_id=${userID}`;
    await tx`update app_private.profiles set state='deleting',updated_at=clock_timestamp() where user_id=${userID}`;
    await tx`update apple_private.attempts set state='failed',updated_at=clock_timestamp() where identity_key=${account.identity_key} and state='reserved'`;
    return {...existing,account};
  });
  if(intent.phase==='complete')return intent;
  try {
    const revoke=deps.revoke||(await import('../apple-session/revocation.ts')).revokeAllAppleGrants;
    await revoke(db,configured,userID,fetcher);
    if(intent.account.legacy_user_id) {
      const [source]=await db`select * from app_private.main_account_deletions where user_id=${userID}`;
      if(!['legacy_deleted','complete'].includes(source.phase)) {
        const destination=canonicalBase44Configuration(input.config),requestID=intent.request_id,legacyID=intent.account.legacy_user_id;
        const recovery=await recoveryToken(input.config,userID,requestID);
        const archive=await signedArchiveErasureRequest(db,input.config,userID,legacyID,requestID);
        const proof=await signedAppleSourceErasureRequest(db,input.config,userID,legacyID,requestID,recovery,archive);
        const response=await fetcher(destination.origin+'/api/apps/'+destination.appID+'/functions/deleteAccountPublic',{
          method:'POST',headers:{'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'},
          body:JSON.stringify({action:'apple_source_erasure',request_id:requestID,recovery_token:recovery,archive_erasure_request:archive,apple_source_erasure_request:proof}),
          credentials:'omit',redirect:'error',signal:AbortSignal.timeout(60_000),
        });
        if(!response.ok)throw pending();
        const result=await boundedLegacyJSON(response),receipt=result?.deletion_receipt;
        if(result.success!==true||receipt?.complete!==true||receipt.request_id!==requestID||receipt.subject_hash!==await digest('spyclash-delete-user-v1:'+legacyID)
            ||result.manual_apple_revocation_required===true||receipt.manual_apple_revocation_required===true)throw pending();
        const erasure=await verifiedArchiveErasureProof(receipt.erasure_proof,archive.aliases);
        await db`update app_private.main_account_deletions set phase='legacy_deleted',erasure_proof=${db.json(erasure)},manual_apple_revocation_required=false,updated_at=clock_timestamp()
          where user_id=${userID} and request_id=${requestID} and phase='pending'`;
      }
    }
    await db.begin(async(tx:any)=>{
      await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+userID},0))`;
      await assertAppleRevocationComplete(tx,userID);
      await tx`update apple_private.deletions set phase='verified',updated_at=clock_timestamp() where user_id=${userID} and phase='pending'`;
    });
    return intent;
  } catch {throw pending();}
}

export async function assertAppleRevocationComplete(tx:any,userID:string) {
  const unresolved=await tx`select 1 from apple_private.grants where user_id=${userID} and state<>'revoked'
    union all select 1 from apple_private.attempts t join apple_private.accounts a on a.identity_key=t.identity_key
      where a.user_id=${userID} and t.state in ('exchanging','uncertain') limit 1`;
  if(unresolved.length)throw pending();
}

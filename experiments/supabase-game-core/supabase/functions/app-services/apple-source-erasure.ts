import {AppServiceError,requireUUID} from './contracts.ts';
import {digest} from './integration-crypto.ts';
import {canonicalBase44Configuration,CANONICAL_BASE44_APP_ID} from './legacy-provider.ts';

/** Build server authorization only from the preserved, completed Apple
 * migration and its durable deletion intent. All arguments are rechecked
 * against private ownership rows while holding the same account lock. */
export async function signedAppleSourceErasureRequest(db:any,config:Record<string,string|undefined>,userID:string,
  legacyID:string,requestID:string,recoveryToken:string,archiveRequest:Record<string,any>) {
  requireUUID(userID,'actor');requireUUID(requestID,'request_id');
  const destination=canonicalBase44Configuration(config),secret=config.APP_DELETION_ARCHIVE_SECRET;
  if(destination.appID!==CANONICAL_BASE44_APP_ID||!secret||!/^[a-f0-9]{64}$/i.test(secret))
    throw new AppServiceError('apple_source_erasure_unconfigured','Historical account erasure is not configured.',503,true);
  if(!/^[a-f0-9]{64}$/.test(recoveryToken)||!/^[a-f0-9]{64}$/.test(archiveRequest?.signature||'')
    ||archiveRequest.subject_hash!==await digest('spyclash-delete-user-v1:'+legacyID))
    throw new AppServiceError('apple_source_erasure_invalid','Historical account ownership could not be verified.',409);
  return await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    const [account]=await tx`select subject_key,legacy_user_id,state,migration_complete from apple_private.accounts where user_id=${userID}`;
    const [intent]=await tx`select request_id,legacy_user_id,source_origin,source_app_id from app_private.main_account_deletions where user_id=${userID}`;
    const links=await tx`select legacy_user_id from app_private.legacy_links where user_id=${userID}
      union all select legacy_user_id from app_private.legacy_session_accounts where user_id=${userID}`;
    if(!account||account.state!=='deleting'||account.migration_complete!==true||account.legacy_user_id!==legacyID
      ||!/^apple-subject:[a-f0-9]{64}$/.test(account.subject_key)||!links.length||links.some((row:any)=>row.legacy_user_id!==legacyID)
      ||intent?.request_id!==requestID||intent.legacy_user_id!==legacyID||intent.source_origin!==destination.origin||intent.source_app_id!==destination.appID)
      throw new AppServiceError('apple_source_erasure_identity_conflict','Historical account ownership could not be verified.',409);
    const issued_at=Date.now(),expires_at=issued_at+300_000;
    const proof={version:1,actor_id:userID,legacy_user_id:legacyID,subject_key:account.subject_key,issued_at,expires_at};
    const message=JSON.stringify(['spyclash-apple-source-erasure-v1',destination.appID,userID,legacyID,account.subject_key,
      requestID,await digest(recoveryToken),archiveRequest.signature,issued_at,expires_at]);
    const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
    const signature=[...new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(message)))].map(v=>v.toString(16).padStart(2,'0')).join('');
    return {...proof,signature};
  });
}

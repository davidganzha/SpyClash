import { AppServiceError, requireUUID, type AppActor, type AppContext } from './contracts.ts';
import { verifyLegacyCredential, boundedLegacyJSON, canonicalBase44Configuration, type LegacyConfig } from './legacy-provider.ts';
import {digest} from './integration-crypto.ts';
import {signedArchiveErasureRequest,verifiedArchiveErasureProof} from './deletion-archive-proof.ts';
import {nativeGameCenterAccount} from './native-game-center.ts';

type Input = {actor: AppActor; body: Record<string, any>; config: LegacyConfig};
const evidenceSet = new WeakSet<object>();
const pending = () => new AppServiceError('account_deletion_pending', 'Account deletion is not yet confirmed. Retry the same request; contact support if the original sign-in no longer works.', 503, true);
const mismatch = () => new AppServiceError('legacy_owner_mismatch', 'The original account does not match this game account.', 409);
function evidenceFor(actor: string, requestID: string, intentRequestID = requestID) {
  const evidence={actor,requestID,intentRequestID};evidenceSet.add(evidence);return evidence;
}
const nativeEvidenceSet = new WeakSet<object>();
async function recoveryToken(config: LegacyConfig, actor: string, requestID: string) {
  const secret=config.APP_DELETION_RECEIPT_SECRET;
  if(!secret||!/^[a-f0-9]{64}$/i.test(secret))throw new AppServiceError('deletion_recovery_unconfigured','Deletion recovery is not configured.',503);
  const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const value=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('spyclash-delete-recovery-v1:'+actor+':'+requestID));
  return [...new Uint8Array(value)].map(v=>v.toString(16).padStart(2,'0')).join('');
}
async function reconcileReceipt(db: any, config: LegacyConfig, prior: any, fetcher: typeof fetch) {
  const destination=canonicalBase44Configuration(config);
  const archiveRequest=await signedArchiveErasureRequest(db,config,prior.user_id,prior.legacy_user_id,prior.request_id);
  if(prior.source_origin!==destination.origin||prior.source_app_id!==destination.appID)throw mismatch();
  const response=await fetcher(destination.origin+'/api/apps/'+destination.appID+'/functions/deleteAccount',{
    method:'POST',headers:{'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'},
    body:JSON.stringify({action:'deletion_status',request_id:prior.request_id,recovery_token:await recoveryToken(config,prior.user_id,prior.request_id),archive_erasure_request:archiveRequest}),
    credentials:'omit',redirect:'error',signal:AbortSignal.timeout(10_000),
  });
  if(!response.ok)return false;
  const result=await boundedLegacyJSON(response);
  if(result?.request_id!==prior.request_id||result?.subject_hash!==await digest('spyclash-delete-user-v1:'+prior.legacy_user_id))throw mismatch();
  if(result.complete!==true)return false;
  const erasureProof=await verifiedArchiveErasureProof(result.erasure_proof,archiveRequest.aliases);
  const updated=await db`update app_private.main_account_deletions set phase='legacy_deleted',erasure_proof=${db.json(erasureProof)},manual_apple_revocation_required=${result.manual_apple_revocation_required===true},last_error=null,updated_at=clock_timestamp()
    where user_id=${prior.user_id} and request_id=${prior.request_id} and phase='pending' returning user_id`;
  return updated.length>0;
}

/** External deletion is opt-in and requires a deployed recovery receipt
 * endpoint. A revoked bearer is never substituted for deletion proof. */
export async function prepareMainAccountDeletion(input: Input, dependencies: {db: any; fetch?: typeof fetch}) {
  if (input.body.deletion_scope === undefined) return undefined;
  if (input.body.deletion_scope !== 'account') throw new AppServiceError('invalid_deletion_scope', 'Unknown deletion scope.');
  const native = await dependencies.db.begin(async (tx:any) => {
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+input.actor.id},0))`;
    return await nativeGameCenterAccount(tx,input.actor.id);
  });
  if (native) {
    const evidence = {actor:input.actor.id,requestID:requireUUID(input.body.request_id,'request_id'),identityKey:native.identity_key};
    nativeEvidenceSet.add(evidence);
    return evidence;
  }
  if (input.config.APP_MAIN_ACCOUNT_DELETION_ENABLED !== 'true') throw new AppServiceError('account_deletion_unconfigured', 'Full account deletion is not enabled for this build yet.', 503);
  const commandID = requireUUID(input.body.request_id, 'request_id');
  // Validate configuration before reserving any intent. A restored client may
  // supply a new command UUID; the provider capability always retains the
  // original, server-owned intent UUID.
  await recoveryToken(input.config,input.actor.id,commandID);
  const {db} = dependencies;
  const fetcher = dependencies.fetch || fetch;
  let [prior] = await db`select * from app_private.main_account_deletions where user_id=${input.actor.id}`;
  const makeEvidence = () => evidenceFor(input.actor.id,commandID,prior?.request_id || commandID);
  if (prior && ['legacy_deleted','complete'].includes(prior.phase)) return makeEvidence();
  if(prior) {
    try { if(await reconcileReceipt(db,input.config,prior,fetcher))return makeEvidence(); }
    catch { /* Retain the intent until exact provider proof becomes available. */ }
  }
  const destination=canonicalBase44Configuration(input.config);
  const capabilityResponse=await fetcher(destination.origin+'/api/apps/'+destination.appID+'/functions/deleteAccount',{
    method:'POST',headers:{'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'},
    body:JSON.stringify({action:'deletion_capabilities'}),credentials:'omit',redirect:'error',signal:AbortSignal.timeout(10_000),
  });
  if(!capabilityResponse.ok||(await boundedLegacyJSON(capabilityResponse))?.protocol!=='spyclash-deletion-receipt-v2') {
    throw new AppServiceError('deletion_recovery_unconfigured','The original account recovery protocol has not been deployed.',503);
  }
  let verified;
  try { verified = await verifyLegacyCredential(input.config, input.body.base44_access_token, fetcher); }
  catch (error) {
    // Revocation, deletion and a stale credential can all produce 401.
    if (prior) throw pending();
    throw error;
  }
  const role = String(verified.identity.role || '').trim().toLowerCase();
  if (role === 'admin') throw new AppServiceError('account_deletion_admin_transfer_required', 'Transfer administrator access before deleting this account.', 409);
  if (role !== 'user') throw new AppServiceError('account_deletion_role_unavailable', 'The original account role could not be verified.', 503, true);
  // Fail before fencing the account if archive ownership/configuration is not ready.
  await signedArchiveErasureRequest(db,input.config,input.actor.id,verified.identity.id,prior?.request_id||commandID);
  const leaseID = crypto.randomUUID();
  prior = await db.begin(async (tx: any) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+input.actor.id},0))`;
    const [profile] = await tx`select state from app_private.profiles where user_id=${input.actor.id}`;
    const [link] = await tx`select * from app_private.legacy_links where user_id=${input.actor.id} for update`;
    if (!link || link.state !== 'active' || link.legacy_user_id !== verified.identity.id || link.source_origin !== verified.origin) throw mismatch();
    const [existing] = await tx`select * from app_private.main_account_deletions where user_id=${input.actor.id} for update`;
    if (!existing && (!profile || profile.state !== 'active')) throw new AppServiceError('account_unavailable', 'This account is unavailable.', 403);
    if (existing && (existing.legacy_user_id !== verified.identity.id || existing.source_origin !== verified.origin || existing.source_app_id !== verified.appID)) throw mismatch();
    if (existing && ['legacy_deleted','complete'].includes(existing.phase)) return existing;
    if (!existing) await tx`insert into app_private.main_account_deletions(user_id,request_id,legacy_user_id,source_origin,source_app_id)
      values(${input.actor.id},${commandID},${verified.identity.id},${verified.origin},${verified.appID})`;
    const [leased] = await tx`update app_private.main_account_deletions set lease_id=${leaseID},lease_until=clock_timestamp()+interval '90 seconds',updated_at=clock_timestamp()
      where user_id=${input.actor.id} and (lease_until is null or lease_until<clock_timestamp()) returning *`;
    if (!leased) throw pending();
    await tx`update app_private.profiles set state='deleting',updated_at=clock_timestamp() where user_id=${input.actor.id}`;
    return leased;
  });
  if (['legacy_deleted','complete'].includes(prior.phase)) return makeEvidence();
  const requestID = prior.request_id;
  const recovery = await recoveryToken(input.config,input.actor.id,requestID);
  try {
    const archiveRequest=await signedArchiveErasureRequest(db,input.config,input.actor.id,verified.identity.id,requestID);
    const response = await fetcher(verified.origin+'/api/apps/'+verified.appID+'/functions/deleteAccount', {
      method:'POST', headers:{Authorization:'Bearer '+verified.credential,'X-App-Id':verified.appID,Origin:verified.origin,'Content-Type':'application/json'},
      body:JSON.stringify({request_id:requestID,recovery_token:recovery,archive_erasure_request:archiveRequest}), redirect:'error', signal:AbortSignal.timeout(60_000),
    });
    if (!response.ok) throw pending();
    const result = await boundedLegacyJSON(response);
    if (result?.success !== true || result.deletion_receipt?.complete!==true || result.deletion_receipt?.request_id!==requestID
      || result.deletion_receipt?.subject_hash!==await digest('spyclash-delete-user-v1:'+verified.identity.id)) throw pending();
    const erasureProof=await verifiedArchiveErasureProof(result.deletion_receipt.erasure_proof,archiveRequest.aliases);
    const updated = await db`update app_private.main_account_deletions set phase='legacy_deleted',erasure_proof=${db.json(erasureProof)},manual_apple_revocation_required=${result.manual_apple_revocation_required === true},last_error=null,updated_at=clock_timestamp()
      where user_id=${input.actor.id} and request_id=${requestID} and lease_id=${leaseID} and phase='pending' returning user_id`;
    if (!updated.length) throw pending();
    return makeEvidence();
  } catch {
    await db`update app_private.main_account_deletions set last_error='provider_confirmation_pending',updated_at=clock_timestamp() where user_id=${input.actor.id} and lease_id=${leaseID} and phase='pending'`;
    throw pending();
  } finally {
    await db`update app_private.main_account_deletions set lease_id=null,lease_until=null where user_id=${input.actor.id} and lease_id=${leaseID}`;
  }
}

/** No user credential or native session is needed to finish an already
 * requested deletion. The capability can only read its private provider proof. */
export async function processMainAccountDeletionJobs(db: any, config: LegacyConfig, fetcher: typeof fetch = fetch) {
  if(config.APP_MAIN_ACCOUNT_DELETION_ENABLED!=='true')return {configured:false,attempted:0,completed:0};
  const jobs=await db.begin(async(tx:any)=>await tx`update app_private.main_account_deletions
    set lease_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '60 seconds',attempts=attempts+1,next_attempt_at=clock_timestamp()+interval '30 seconds'
    where user_id in (select user_id from app_private.main_account_deletions where phase<>'complete' and next_attempt_at<=clock_timestamp()
      and (lease_until is null or lease_until<clock_timestamp()) order by next_attempt_at,created_at limit 3 for update skip locked) returning *`);
  let completed=0;
  for(const job of jobs) {
    try {
      const confirmed=job.phase==='legacy_deleted'||await reconcileReceipt(db,config,job,fetcher);
      if(!confirmed)continue;
      const {executeApp}=await import('./dispatcher.ts');
      const actor={id:job.user_id,email:job.user_id+'@example.test',contactEmail:'',full_name:'',metadata:{}};
      const body={service:'profile',action:'delete',deletion_scope:'account',request_id:job.request_id};
      const result=await executeApp(db,actor,body,config,evidenceFor(job.user_id,job.request_id));
      if(result.status===200)completed++;
    } catch { /* Stable intent is retried by the next bounded maintenance pass. */ }
    finally { await db`update app_private.main_account_deletions set lease_id=null,lease_until=null where user_id=${job.user_id} and lease_id=${job.lease_id}`; }
  }
  return {configured:true,attempted:jobs.length,completed};
}

/** Called within the exclusive account transaction; callers cannot forge proof. */
export async function assertMainDeletionEvidence(ctx: AppContext, body: Record<string, any>) {
  const native = await nativeGameCenterAccount(ctx.tx,ctx.actor.id);
  if (native) {
    const evidence = ctx.evidence;
    if (body.deletion_scope !== 'account' || !evidence || !nativeEvidenceSet.has(evidence) ||
        evidence.actor !== ctx.actor.id || evidence.requestID !== body.request_id || evidence.identityKey !== native.identity_key) {
      throw new AppServiceError('native_account_deletion_proof_required','Confirm deletion of this Game Center account.',409);
    }
    return {native_account:true,identity_key:native.identity_key};
  }
  const [intent] = await ctx.tx`select * from app_private.main_account_deletions where user_id=${ctx.actor.id}`;
  if (body.deletion_scope === undefined && !intent) return undefined;
  if (body.deletion_scope !== 'account') throw new AppServiceError('account_deletion_pending', 'Continue full account deletion before clearing its local copy.', 503, true);
  const evidence = ctx.evidence;
  if (!evidence || !evidenceSet.has(evidence) || evidence.actor !== ctx.actor.id || evidence.requestID !== body.request_id
    || !intent || intent.request_id !== evidence.intentRequestID || !['legacy_deleted','complete'].includes(intent.phase)) throw pending();
  return intent;
}

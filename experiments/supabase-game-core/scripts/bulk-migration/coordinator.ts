import {canonical,digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import {assertPlanReady,reserveCoreAccounts,applyCorePlan,assertProvisionedAccount,type Row,type AccountPlan} from './core.ts';
import {applyAncillaryPlan} from './ancillary.ts';
import {archiveSnapshot,readJournalState,diffJournal,JOURNAL_TABLES,buildDispositionManifest} from './archive.ts';

type Dependencies={db:any;origin:string;serviceKey:string;fetch?:typeof fetch;now?:()=>Date};
const safeCode=(error:unknown)=>error instanceof Error&&/^(bulk_|archive_|ancillary_)[a-z0-9_:]+$/.test(error.message)?error.message:'bulk_step_failed';
async function boundedBody(request:Request,limit:number) {
  const reader=request.body?.getReader();if(!reader)throw new Error('bulk_missing_body');
  const chunks:Uint8Array[]=[];let size=0;
  while(true){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>limit){await reader.cancel();throw new Error('bulk_body_too_large');}chunks.push(part.value);}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  return new TextDecoder().decode(bytes);
}
function checkPayload(payload:Row) {
  assertPlanReady(payload.core);
  if(payload.ancillary.issues.length)throw new Error('bulk_ancillary_conflicts');
  if(payload.snapshot.digest!==payload.core.sourceDigest||payload.snapshot.digest!==payload.ancillary.sourceDigest)throw new Error('bulk_payload_source_mismatch');
  if(canonical(payload.manifest)!==canonical(buildDispositionManifest(payload.snapshot,payload.core,payload.ancillary)))throw new Error('archive_manifest_mismatch');
}
async function authUser(deps:Dependencies,account:AccountPlan) {
  const request=async(path:string,method='GET',body?:Row)=>{
    const response=await(deps.fetch||fetch)(deps.origin+'/auth/v1'+path,{method,headers:{apikey:deps.serviceKey,Authorization:'Bearer '+deps.serviceKey,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),redirect:'error',signal:AbortSignal.timeout(10000)});
    if(response.status===404&&method==='GET')return null;
    if(!response.ok)throw new Error('bulk_auth_unavailable');
    return response.json();
  };
  let user=await request('/admin/users/'+account.user_id);
  if(!user) {
    if(!account.needs_auth)throw new Error('bulk_existing_auth_disappeared');
    try {user=await request('/admin/users','POST',{id:account.user_id,email:account.shadow_email,email_confirm:true,app_metadata:{legacy_provider:'base44',legacy_identity_key:account.identity_key},user_metadata:{full_name:account.profile.data.full_name}});}
    catch(error){user=await request('/admin/users/'+account.user_id);if(!user)throw error;}
  }
  assertProvisionedAccount(account,user);
}

/** Temporary operator endpoint. The only input is a job UUID and a random
 * 256-bit bearer capability delivered outside logs/URL. The immutable payload
 * and authorization digest live in a non-exposed private table. Each request
 * provisions at most five dormant identities, permitting bounded recovery. */
export function createMigrationHandler(deps:Dependencies) {
  const now=deps.now||(()=>new Date());
  return async(request:Request)=>{
    const response=(status:number,value:Row)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
    if(request.method!=='POST')return response(405,{error:'method_not_allowed'});
    const token=request.headers.get('x-migration-token')||'';
    if(!/^[0-9a-f]{64}$/.test(token))return response(401,{error:'unauthorized'});
    if(new URL(request.url).pathname.endsWith('/upload')) {
      const id=request.headers.get('x-migration-job')||'';
      if(!/^[0-9a-f-]{36}$/.test(id))return response(400,{error:'invalid_request'});
      const hash=await digest(token);
      const [authorized]=await deps.db`select plan_digest,source_digest from app_private.bulk_migration_jobs where id=${id} and token_digest=${hash} and token_expires_at>clock_timestamp() and status='ready' and payload='{}'::jsonb`;
      if(!authorized)return response(401,{error:'unauthorized'});
      try {
        // Stream limit bounds memory before JSON parsing; source credentials are
        // never included in responses or exception logs.
        const payload=JSON.parse(await boundedBody(request,5_000_000));
        if(await digest(canonical(payload))!==authorized.plan_digest||payload.snapshot.digest!==authorized.source_digest)throw new Error('bulk_plan_digest_mismatch');
        checkPayload(payload);
        const rows=await deps.db`update app_private.bulk_migration_jobs set payload=${deps.db.json(payload)},updated_at=clock_timestamp() where id=${id} and token_digest=${hash} and token_expires_at>clock_timestamp() and status='ready' and payload='{}'::jsonb returning id`;
        return rows.length?response(200,{status:'uploaded'}):response(409,{error:'bulk_upload_changed'});
      }catch(error){return response(409,{error:safeCode(error)});}
    }
    let body:any;try {body=JSON.parse(await boundedBody(request,256));}catch{return response(400,{error:'invalid_request'});}
    if(!/^[0-9a-f-]{36}$/.test(body?.job_id||'')||Object.keys(body).some(k=>k!=='job_id'))return response(400,{error:'invalid_request'});
    const hash=await digest(token),leaseID=crypto.randomUUID();
    let job:Row|undefined;
    try {
      // Failed authentication never reveals whether the requested job exists.
      [job]=await deps.db`update app_private.bulk_migration_jobs set lease_id=${leaseID},lease_until=clock_timestamp()+interval '180 seconds',updated_at=clock_timestamp() where id=${body.job_id} and token_digest=${hash} and token_expires_at>clock_timestamp() and (lease_until is null or lease_until<clock_timestamp()) returning *`;
      if(!job)return response(401,{error:'unauthorized_or_busy'});
      if(job.status==='applied')return response(200,{status:'applied',summary:job.summary});
      if(job.status==='rolled_back')throw new Error('bulk_job_already_rolled_back');
      if(await digest(canonical(job.payload))!==job.plan_digest)throw new Error('bulk_plan_digest_mismatch');
      const {snapshot,core,ancillary}=job.payload;checkPayload(job.payload);
      const {digest:sourceDigest,...sourceValue}=snapshot;
      if(await digest(canonical(sourceValue))!==sourceDigest||sourceDigest!==job.source_digest)throw new Error('bulk_source_digest_mismatch');
      // A stale source cannot be silently applied; refresh/review a new job.
      if(now().getTime()-Date.parse(snapshot.verifiedAt)>30*60*1000)throw new Error('bulk_source_snapshot_expired');
      if(job.status==='ready') {
        await deps.db.begin(async(tx:any)=>{
          await tx`set local lock_timeout='5s'`;await tx`set local statement_timeout='45s'`;
          await reserveCoreAccounts(tx,core);
          await tx`update app_private.bulk_migration_jobs set status='reserved',updated_at=clock_timestamp() where id=${job!.id} and lease_id=${leaseID}`;
        });
        return response(200,{status:'reserved',accounts:core.accounts.length});
      }
      const pending=[];
      for(const account of core.accounts) {
        const [user]=await deps.db`select id,email,role,raw_app_meta_data from auth.users where id=${account.user_id}`;
        if(!user)pending.push(account);else assertProvisionedAccount(account,{...user,app_metadata:user.raw_app_meta_data});
      }
      if(pending.length) {
        for(const account of pending.slice(0,5)) {
          // Same ownership/deletion gate as login before every Auth operation.
          await deps.db.begin((tx:any)=>reserveCoreAccounts(tx,{...core,accounts:[account]}));
          await authUser(deps,account);
        }
        await deps.db`update app_private.bulk_migration_jobs set status='provisioning',updated_at=clock_timestamp() where id=${job.id} and lease_id=${leaseID}`;
        return response(200,{status:'provisioning',remaining:Math.max(0,pending.length-5)});
      }
      const contentDigest=await digest(canonical({source:snapshot.source,entities:snapshot.entities,schemas:snapshot.sourceSchemas}));
      if(contentDigest!==job.source_content_digest)throw new Error('bulk_source_content_mismatch');
      // The operator must independently re-export Base44 AFTER provisioning and
      // attest the same source content through the administrative SQL channel.
      // Age alone is not a source-drift check. No client endpoint can attest it.
      if(job.source_attested_digest!==contentDigest||!job.source_attested_at||now().getTime()-new Date(job.source_attested_at).getTime()>60_000)return response(200,{status:'source_verification_required'});
      const summary=await deps.db.begin(async(tx:any)=>{
        await tx`set local lock_timeout='5s'`;await tx`set local statement_timeout='120s'`;
        const [locked]=await tx`select * from app_private.bulk_migration_jobs where id=${job!.id} and lease_id=${leaseID} and lease_until>clock_timestamp() and token_expires_at>clock_timestamp() for update`;
        if(!locked)throw new Error('bulk_job_lease_expired');
        if(locked.source_attested_digest!==contentDigest||!locked.source_attested_at||now().getTime()-new Date(locked.source_attested_at).getTime()>60_000)throw new Error('bulk_source_attestation_expired');
        for(const account of [...core.accounts].sort((a:AccountPlan,b:AccountPlan)=>a.user_id.localeCompare(b.user_id)))await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+account.user_id},0))`;
        await tx.unsafe('lock table '+Object.keys(JOURNAL_TABLES).join(',')+' in share row exclusive mode');
        const before=await readJournalState(tx);
        // Core owns identity locks and rechecks its complete reviewed baseline.
        const coreResult=await applyCorePlan(tx,core);
        const ancillaryResult=await applyAncillaryPlan(tx,ancillary);
        const archived=await archiveSnapshot(tx,job!.id,snapshot,job!.payload.manifest);
        // Reservation UUIDs and dormant Auth users survive rollback together;
        // importing later must reuse the same identity rather than orphan it.
        const journal=diffJournal(before,await readJournalState(tx));
        const value={core:coreResult,ancillary:ancillaryResult,archived_rows:archived};
        await tx`update app_private.bulk_migration_jobs set status='applied',applied_at=clock_timestamp(),summary=${tx.json(value)},rollback_journal=${tx.json({changes:journal})},updated_at=clock_timestamp() where id=${job!.id}`;
        return value;
      });
      return response(200,{status:'applied',summary});
    }catch(error){return response(409,{error:safeCode(error)});}
    finally{if(job)await deps.db`update app_private.bulk_migration_jobs set lease_id=null,lease_until=null where id=${job.id} and lease_id=${leaseID}`.catch(()=>{});}
  };
}

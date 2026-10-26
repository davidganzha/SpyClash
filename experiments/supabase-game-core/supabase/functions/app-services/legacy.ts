import { AppServiceError, requireUUID, type AppContext, type AppActor } from './contracts.ts';
import { canonical, digest } from './integration-crypto.ts';
import { canonicalBase44Configuration as configuration, verifyLegacyCredential, boundedLegacyJSON as boundedJSON } from './legacy-provider.ts';
import {nativeGameCenterAccount,resolveNativeGameCenterAccount} from './native-game-center.ts';
import {nativeGenerationCapabilities,prepareNativeGeneration,dispatchNativeGeneration} from './native-generation.ts';
type Config=Record<string,string|undefined>;
type Input={actor:AppActor,body:Record<string,any>,config:Config};
const verifiedEvidence=new WeakSet<object>();
export function legacyCapabilities(config:Config) {
  try { configuration(config);return {generator_provider:'base44',configured:true,requires_legacy_session:true}; }
  catch {return {generator_provider:'base44',configured:false,requires_legacy_session:true};}
}
function generatorBody(body:Record<string,any>) {
  if(typeof body.theme!=='string'||!body.theme.trim()||body.theme.length>80)throw new AppServiceError('invalid_theme','A theme of at most 80 characters is required.');
  if(!Number.isInteger(body.count)||body.count<2||body.count>200)throw new AppServiceError('invalid_count','The word count must be between 2 and 200.');
  const excluded=body.exclude_words||[];
  if(!Array.isArray(excluded)||excluded.length>200||excluded.some(w=>typeof w!=='string'||w.length>120))throw new AppServiceError('invalid_exclusions','Invalid excluded words.');
  return {theme:body.theme.trim(),count:body.count,exclude_words:excluded,prefer_fresh:body.prefer_fresh===true,request_id:requireUUID(body.request_id,'request_id')};
}

/** Performs no generator call. The authenticated legacy credential is verified
 * against the configured existing Base44 app before its ID can become a durable mapping. */
export async function prepareLegacyExternal(input:Input,dependencies:{fetch?:typeof fetch,db?:any}={}) {
  const action=({legacy_status:'status',link_legacy_account:'link',generate_word_pack:'generate'} as Record<string,string>)[input.body.action]||input.body.action;
  if(action==='status')return undefined;
  if(!['link','generate'].includes(action))throw new AppServiceError('invalid_action','Unknown legacy action.');
  if(dependencies.db&&await resolveNativeGameCenterAccount(dependencies.db,input.actor.id)) {
    if(action==='link')throw new AppServiceError('game_center_legacy_link_unsupported','This Game Center account cannot replace an existing account.',409);
    return await prepareNativeGeneration(input,{db:dependencies.db,fetch:dependencies.fetch});
  }
  const fetcher=dependencies.fetch||fetch;
  const verified=await verifyLegacyCredential(input.config,input.body.base44_access_token,fetcher);
  const {identity,credential,...destination}=verified;
  const headers={Authorization:'Bearer '+credential,'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'};
  const evidence:any={actor:input.actor.id,legacyID:identity.id,origin:destination.origin,action,verifiedAt:Date.now()};
  if(action==='generate') {
    if(!dependencies.db)throw new AppServiceError('generation_reservation_required','Generation requires a durable request reservation.',503);
    const request=generatorBody(input.body),hash=await digest(canonical(request));
    const prior=await reserveGeneration(dependencies.db,input.actor,identity.id,request.request_id,hash,destination.origin);
    if(prior){evidence.result=prior;}else {
      // Base44 already owns provider idempotency by legacy user + this immutable
      // request UUID. A lost ACK leaves our reservation and retries this exact ID.
      const response=await fetcher(destination.origin+'/api/apps/'+destination.appID+'/functions/generateWordPack',{
        method:'POST',headers,redirect:'error',body:JSON.stringify(request),signal:AbortSignal.timeout(60_000)});
      if(!response.ok)throw new AppServiceError('legacy_generation_unavailable','Base44 did not complete the word generation. Retry the saved request.',response.status>=500?503:response.status,response.status>=500);
      const generated=await boundedJSON(response);
      if(typeof generated.category!=='string'||!Array.isArray(generated.words)||!generated.words.length||generated.words.length>200
        ||generated.words.some((w:unknown)=>typeof w!=='string'||!w.trim()||w.length>200))throw new AppServiceError('invalid_generated_pack','Base44 returned an invalid word pack.',502,true);
      evidence.result={name:String(generated.name||generated.category).slice(0,120),category:generated.category.slice(0,120),words:generated.words,
        ...Object.fromEntries(['ai_limit','ai_generations_today','ai_remaining'].filter(k=>Number.isInteger(generated[k])&&generated[k]>=0).map(k=>[k,generated[k]]))};
    }
    evidence.requestID=request.request_id;evidence.requestHash=hash;
  }
  verifiedEvidence.add(evidence);return evidence;
}
async function reserveGeneration(db:any,actor:AppActor,legacyID:string,requestID:string,hash:string,origin:string) {
  return await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+actor.id},0))`;
    const [profile]=await tx`select state from app_private.profiles where user_id=${actor.id} for share`;
    if(!profile||profile.state!=='active')throw new AppServiceError('account_unavailable','This account is not active.',403);
    const [link]=await tx`select legacy_user_id,source_origin,state from app_private.legacy_links where user_id=${actor.id} for share`;
    if(!link||link.state!=='active'||link.legacy_user_id!==legacyID||link.source_origin!==origin)throw new AppServiceError('legacy_link_required','Link this Base44 account before generating words.',409);
    await tx`select pg_advisory_xact_lock(hashtextextended(${actor.id+':legacy:'+requestID},0))`;
    const [prior]=await tx`select * from app_private.legacy_operations where user_id=${actor.id} and request_id=${requestID} for update`;
    if(prior&&(prior.request_hash!==hash||prior.legacy_user_id!==legacyID))throw new AppServiceError('request_id_reused','This request ID belongs to another generation.',409);
    if(!prior)await tx`insert into app_private.legacy_operations(user_id,request_id,request_hash,legacy_user_id) values(${actor.id},${requestID},${hash},${legacyID})`;
    return prior?.state==='complete'?prior.response:null;
  });
}

export async function dispatchLegacy(ctx:AppContext,body:Record<string,any>) {
  const action=({legacy_status:'status',link_legacy_account:'link',generate_word_pack:'generate'} as Record<string,string>)[body.action]||body.action;
  if(await nativeGameCenterAccount(ctx.tx,ctx.actor.id)) {
    if(action==='status')return nativeGenerationCapabilities(ctx.config);
    if(action==='generate')return await dispatchNativeGeneration(ctx,body);
    throw new AppServiceError('game_center_legacy_link_unsupported','This Game Center account cannot replace an existing account.',409);
  }
  if(action==='status') {
    const [link]=await ctx.tx`select legacy_user_id,state from app_private.legacy_links where user_id=${ctx.actor.id}`;
    return {...legacyCapabilities(ctx.config),linked:link?.state==='active',legacy_user_id:link?.state==='active'?link.legacy_user_id:null};
  }
  const evidence=ctx.evidence;
  if(!evidence||!verifiedEvidence.has(evidence)||evidence.actor!==ctx.actor.id||evidence.action!==action||Date.now()-evidence.verifiedAt>120_000)throw new AppServiceError('legacy_verification_required','A verified Base44 session is required.',401);
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'legacy:'+evidence.legacyID},0))`;
  const existing=await ctx.tx`select * from app_private.legacy_links where user_id=${ctx.actor.id} or legacy_user_id=${evidence.legacyID} for update`;
  if(existing.some((row:any)=>row.user_id!==ctx.actor.id||row.legacy_user_id!==evidence.legacyID||row.state!=='active'))throw new AppServiceError('legacy_owner_mismatch','This Base44 account already has a different owner.',409);
  if(action==='link') {
    await ctx.tx`insert into app_private.legacy_links(user_id,legacy_user_id,verified_at,source_origin) values(${ctx.actor.id},${evidence.legacyID},${ctx.now},${evidence.origin}) on conflict(user_id) do update set verified_at=excluded.verified_at`;
    return {linked:true,legacy_user_id:evidence.legacyID};
  }
  if(action!=='generate'||!existing.length)throw new AppServiceError('legacy_link_required','Link the Base44 account first.',409);
  const request=generatorBody(body);
  if(evidence.requestID!==request.request_id||evidence.requestHash!==await digest(canonical(request)))throw new AppServiceError('request_id_reused','The generation request changed.',409);
  const updated=await ctx.tx`update app_private.legacy_operations set state='complete',response=${ctx.tx.json(evidence.result)}
    where user_id=${ctx.actor.id} and request_id=${evidence.requestID} and request_hash=${evidence.requestHash} returning request_id`;
  if(!updated.length)throw new AppServiceError('generation_reservation_missing','Generation reservation is missing.',409);
  return evidence.result;
}

/** No imports are applied here. Reject ambiguous ownership before any future
 * privileged migration writes; contact-email equality is never ownership. */
export function validateLegacyImport(rows: Array<{legacyID:string,userID:string,sourceID:string,digest:string}>) {
  const ownership=new Map<string,string>(),targets=new Map<string,string>(),sourceRows=new Map<string,string>();
  for(const row of rows) {
    requireUUID(row.userID,'user_id');
    if(!row.legacyID||!row.sourceID||!/^[a-f0-9]{64}$/.test(row.digest))throw new AppServiceError('invalid_import_row','Invalid legacy import manifest.');
    if(ownership.has(row.legacyID)&&ownership.get(row.legacyID)!==row.userID)throw new AppServiceError('ambiguous_legacy_owner','Legacy identity has conflicting target owners.',409);
    if(targets.has(row.userID)&&targets.get(row.userID)!==row.legacyID)throw new AppServiceError('ambiguous_target_owner','Target account has conflicting legacy identities.',409);
    if(sourceRows.has(row.sourceID)&&sourceRows.get(row.sourceID)!==row.digest)throw new AppServiceError('conflicting_source_row','Legacy source row has conflicting content.',409);
    ownership.set(row.legacyID,row.userID);targets.set(row.userID,row.legacyID);sourceRows.set(row.sourceID,row.digest);
  }
  return {valid:true,accounts:ownership.size,rows:sourceRows.size,dry_run:true};
}

export async function dryRunLegacyImport(db:any,manifest:Array<{entity:string,source_id:string,legacy_user_id:string,digest:string}>) {
  if(!Array.isArray(manifest)||manifest.length>10_000)throw new AppServiceError('invalid_import_manifest','Use a bounded import manifest.');
  const links=await db`select user_id,legacy_user_id from app_private.legacy_links where state='active'`;
  const ownership=new Map<string,string>(links.map((row:any)=>[row.legacy_user_id,row.user_id]));
  const sourceDigests=new Map<string,string>();
  const supported=new Set(['User','WordPack','GameHistory','Friendship','ProfileComment','Entitlement','AppStoreAccount','MembershipGrant']);
  const ready:Array<{entity:string,source_id:string,user_id:string,digest:string}>=[];
  const unresolved:Array<{entity:string,source_id:string,reason:string}>=[];
  for(const row of manifest){
    const source=typeof row?.source_id==='string'?row.source_id.slice(0,200):'';
    const entity=typeof row?.entity==='string'?row.entity.slice(0,80):'';
    const key=entity+':'+source;
    let reason:string|undefined;
    if(!source||!supported.has(entity)||!/^[a-f0-9]{64}$/.test(row.digest||''))reason='invalid_source_manifest';
    else if(!ownership.has(row.legacy_user_id))reason='verified_identity_mapping_required';
    else if(sourceDigests.has(key)&&sourceDigests.get(key)!==row.digest)reason='source_digest_conflict';
    if(reason){unresolved.push({entity,source_id:source,reason});continue;}
    if(sourceDigests.has(key))continue;
    sourceDigests.set(key,row.digest);ready.push({entity,source_id:source,user_id:ownership.get(row.legacy_user_id)!,digest:row.digest});
  }
  return {dry_run:true,ready_count:ready.length,unresolved_count:unresolved.length,ready,unresolved};
}

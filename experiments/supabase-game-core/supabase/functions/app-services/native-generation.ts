import {AppServiceError,requireUUID,type AppActor,type AppContext} from './contracts.ts';
import {accountGate} from './account-gate.ts';
import {nativeGameCenterAccount,nativeGameCenterHasMembership} from './native-game-center.ts';
import {canonical,digest} from './integration-crypto.ts';
import {createOpenAIWordPackProvider,assertNoKnownNamedThemeDrift,WORD_PACK_PROMPT_VERSION,WORD_PACK_CACHE_VERSION} from './word-generation/openai-word-pack-provider.ts';
import {filterSafeCommunityStrings,requireSafeCommunityText} from './word-generation/content-safety.ts';
import {normalizeGeneratedWordPack,wordPackComparisonKey} from './word-generation/generation-cache.ts';
import {nativeRelayConfigured,createNativeAIRelayProvider,nativeRelayHasUnknownOutcome,settleNativeRelayFailure,terminalNativeAIOutcome,failedNativeAIOutcome} from './native-ai-relay.ts';
import {generationRewardMetadata,lockGenerationQuota,nativeRewardStatus,reserveRewardGeneration,rewardedGenerationEnabled} from './generation-reward-ledger.ts';
import {createDurableNativeDirectProvider} from './native-direct-generation.ts';
import {createSharedWordPackSQLStore} from './shared-word-pack-store.ts';
import {prepareSharedWordPackRequest,buildSharedWordPackVariant,sharedWordPackLibraryEnabled} from './word-generation/shared-word-pack-library.ts';

type Config=Record<string,string|undefined>;
type Input={actor:AppActor,body:Record<string,any>,config:Config};
const evidenceSet=new WeakSet<object>();
export const NATIVE_AI_DAILY_LIMIT=10;
const busy=()=>new AppServiceError('generation_in_progress','This word pack is still being prepared. Retry the same request.',503,true);
function nativeGenerationProviderConfigured(config:Config) {
  const provider=config.APP_NATIVE_GAME_CENTER_AI_PROVIDER||'base44-managed';
  return provider==='base44-managed'?nativeRelayConfigured(config):provider==='openai'&&config.APP_NATIVE_GAME_CENTER_AI_ENABLED==='true'&&Boolean(config.OPENAI_API_KEY?.trim());
}
export function nativeGenerationCapabilities(config:Config) {
  const provider=config.APP_NATIVE_GAME_CENTER_AI_PROVIDER||'base44-managed';
  const configured=nativeGenerationProviderConfigured(config)||sharedWordPackLibraryEnabled(config);
  return {generator_provider:provider,configured,requires_legacy_session:false,linked:false};
}
function command(body:Record<string,any>) {
  if(typeof body.theme!=='string'||!body.theme.trim()||body.theme.length>80)throw new AppServiceError('invalid_theme','A theme of at most 80 characters is required.');
  if(!Number.isInteger(body.count)||body.count<2||body.count>100)throw new AppServiceError('invalid_count','The word count must be between 2 and 100.');
  const excluded=body.exclude_words||[];
  if(!Array.isArray(excluded)||excluded.length>200||excluded.some(w=>typeof w!=='string'||w.length>120))throw new AppServiceError('invalid_exclusions','Invalid excluded words.');
  let theme:string;
  try{theme=requireSafeCommunityText(body.theme,'theme');}catch{throw new AppServiceError('objectionable_content','Choose another word pack theme.',422);}
  return {theme,count:body.count,exclude_words:excluded,prefer_fresh:body.prefer_fresh===true,request_id:requireUUID(body.request_id,'request_id')};
}
async function requestHash(body:Record<string,any>){return await digest(canonical({version:WORD_PACK_PROMPT_VERSION,...command(body)}));}
async function requireNative(tx:any,userID:string) {
  await accountGate(tx,userID);
  if((await nativeGameCenterAccount(tx,userID))?.state!=='ready')throw new AppServiceError('native_account_required','This feature requires the signed-in Game Center account.',403);
}
/** The reservation is committed before provider work. The same UUID always
 * owns one quota charge and one durable result, including after a lost ACK.
 * Relay claims survive an expired worker lease: paid work is never repeated. */
export async function prepareNativeGeneration(input:Input,dependencies:{db:any,fetch?:typeof fetch}) {
  const rewardsEnabled=rewardedGenerationEnabled(input.config);
  const sharedEnabled=sharedWordPackLibraryEnabled(input.config);
  if(!nativeGenerationCapabilities(input.config).configured)throw new AppServiceError('native_generation_unconfigured','Word generation is not available yet. Try again later.',503,true);
  const request=command(input.body),hash=await requestHash(input.body),db=dependencies.db,leaseID=crypto.randomUUID();
  const sharedRequest=sharedEnabled?await prepareSharedWordPackRequest({theme:request.theme,language:'und',promptVersion:WORD_PACK_CACHE_VERSION,requestedCount:request.count,exclusions:request.exclude_words}):null;
  const sharedStore=sharedRequest?createSharedWordPackSQLStore(db):null;
  const evidenceFor=(result:any)=>{const evidence={actor:input.actor.id,requestID:request.request_id,hash,result};evidenceSet.add(evidence);return evidence;};
  const reservation=await db.begin(async(tx:any)=>{
    await requireNative(tx,input.actor.id);
    await lockGenerationQuota(tx,input.actor.id);
    const [prior]=await tx`select *,lease_until>clock_timestamp() as leased from game_center_private.generation_requests
      where user_id=${input.actor.id} and request_id=${request.request_id} for update`;
    if(prior&&prior.request_hash!==hash)throw new AppServiceError('request_id_reused','This request belongs to another word pack.',409);
    if(prior?.state==='complete')return {result:prior.result};
    if(prior?.leased)throw busy();
    if(prior?.error_code==='generation_quality_failed')throw failedNativeAIOutcome('quality_failed');
    if(prior?.error_code==='generation_provider_failed')throw failedNativeAIOutcome('provider_failed');
    if(prior&&await nativeRelayHasUnknownOutcome(tx,input.actor.id,request.request_id)){
      await tx`update game_center_private.generation_requests set state='failed',charged=true,lease_id=null,lease_until=null,error_code='generation_outcome_unknown',updated_at=clock_timestamp()
        where user_id=${input.actor.id} and request_id=${request.request_id}`;
      return {unknown:true,metered:Boolean(prior.charge_source&&prior.charge_source!=='legacy')};
    }
    const [{today}]=await tx`select (clock_timestamp() at time zone 'UTC')::date::text as today`;
    const unlimited=await nativeGameCenterHasMembership(tx,input.actor.id);
    const [{used}]=await tx`select count(*)::int as used from game_center_private.generation_requests where user_id=${input.actor.id} and usage_date=${today} and charged`;
    const keepsCharge=prior?.charged===true;
    const rewardReservation=rewardsEnabled?await reserveRewardGeneration(tx,input.actor.id,request.request_id,prior,input.config):null;
    if(!rewardsEnabled&&!unlimited&&!keepsCharge&&used>=NATIVE_AI_DAILY_LIMIT)throw new AppServiceError('ai_limit_reached','Today’s word generation limit has been reached.',429,false);
    await tx`insert into game_center_private.generation_requests(user_id,request_id,request_hash,usage_date,charged,state,lease_id,lease_until,charge_source)
      values(${input.actor.id},${request.request_id},${hash},${today},true,'pending',${leaseID},clock_timestamp()+interval '120 seconds',${rewardReservation?.source||(keepsCharge?prior.charge_source:'legacy')})
      on conflict(user_id,request_id) do update set state='pending',charged=true,
        usage_date=case when game_center_private.generation_requests.charged then game_center_private.generation_requests.usage_date else excluded.usage_date end,
        lease_id=excluded.lease_id,lease_until=excluded.lease_until,charge_source=excluded.charge_source,error_code=null,updated_at=clock_timestamp()`;
    return {unlimited,used:used+(keepsCharge?0:1),metered:rewardsEnabled||Boolean(prior?.charged&&prior?.charge_source&&prior.charge_source!=='legacy')};
  });
  if(reservation.unknown)throw rewardsEnabled||reservation.metered||sharedEnabled?busy():terminalNativeAIOutcome();
  if(reservation.result)return evidenceFor(reservation.result);
  let qualityRejected=false;
  let sharedClaimed=false;
  let retainSharedClaim=false;
  const validate=<T>(operation:()=>T):T=>{
    try{return operation();}catch(error){qualityRejected=true;throw error;}
  };
  try{
    // A library result is a normal, charged generation. Even an explicit
    // regeneration first tries unused words; request replay remains above the
    // reservation and cannot spend another point.
    let hit=sharedStore&&sharedRequest?await sharedStore.read(sharedRequest):null;
    if(sharedStore&&sharedRequest&&!hit){
      sharedClaimed=await sharedStore.claim(sharedRequest.cacheKey,leaseID);
      hit=await sharedStore.read(sharedRequest);
      if(!hit&&!sharedClaimed)throw new AppServiceError('shared_generation_in_progress','This topic is being prepared. Retry this request shortly.',503,true);
    }
    let words:string[]=hit?.words||[],exhausted=hit?.exhausted||false;
    if(!hit){
    if(!nativeGenerationProviderConfigured(input.config))throw new AppServiceError('native_generation_unconfigured','Word generation is not available yet. Try again later.',503,true);
    const provider=input.config.APP_NATIVE_GAME_CENTER_AI_PROVIDER==='base44-managed'
      ?createNativeAIRelayProvider({db,config:input.config,actorID:input.actor.id,requestID:request.request_id,requestHash:hash,leaseID,fetch:dependencies.fetch})
      :reservation.metered||sharedEnabled?createDurableNativeDirectProvider({db,config:input.config,actorID:input.actor.id,requestID:request.request_id,leaseID,fetch:dependencies.fetch})
        :createOpenAIWordPackProvider({apiKey:input.config.OPENAI_API_KEY!,model:input.config.SPYCLASH_OPENAI_MODEL,timeoutMilliseconds:45_000,fetch:dependencies.fetch});
    const generate=async(count:number,excluded:string[])=>{
      // Recheck ownership before each external call; never continue provider
      // work on an account deleted while the first call was in flight.
      await db.begin(async(tx:any)=>{
        await requireNative(tx,input.actor.id);
        const rows=await tx`update game_center_private.generation_requests set lease_until=clock_timestamp()+interval '120 seconds'
          where user_id=${input.actor.id} and request_id=${request.request_id} and lease_id=${leaseID} and lease_until>clock_timestamp() and state='pending' returning request_id`;
        if(!rows.length)throw busy();
      });
      const generated=await provider.generate({theme:request.theme,count,alreadyUsed:excluded});
      return validate(()=>{
        const denied=new Set(excluded.map(wordPackComparisonKey));
        const safe=filterSafeCommunityStrings(generated.words).filter(w=>!denied.has(wordPackComparisonKey(w)));
        assertNoKnownNamedThemeDrift(request.theme,safe);
        return {...generated,words:safe};
      });
    };
    const first=await generate(request.count,request.exclude_words);
    words=first.words;exhausted=first.exhausted&&words.length<request.count;
    if(exhausted){
      const second=await generate(Math.max(2,request.count-words.length),[...request.exclude_words,...words]);
      words=[...words,...second.words];exhausted=second.exhausted&&words.length<request.count;
    }
    }
    const normalized=validate(()=>{
      const pack=normalizeGeneratedWordPack({category:request.theme,words:words.slice(0,request.count),exhausted});
      if(pack.words.length<request.count&&!pack.exhausted)throw new Error('quality');
      return pack;
    });
    const sharedVariant=sharedRequest&&!hit?await buildSharedWordPackVariant({request:sharedRequest,result:normalized}):null;
    let result:any={name:request.theme,...normalized,...(sharedEnabled?{cache_hit:Boolean(hit)}:{}),ai_limit:reservation.unlimited?null:NATIVE_AI_DAILY_LIMIT,
      ai_generations_today:reservation.used,ai_remaining:reservation.unlimited?null:Math.max(0,NATIVE_AI_DAILY_LIMIT-reservation.used)};
    await db.begin(async(tx:any)=>{
      await requireNative(tx,input.actor.id);
      // Publishing and completing the charged request commit together. A lost
      // acknowledgement is reconciled from the durable request/provider result.
      if(sharedVariant&&!await createSharedWordPackSQLStore(tx).publish(sharedVariant,leaseID))throw busy();
      if(rewardsEnabled){
        await lockGenerationQuota(tx,input.actor.id);
        result={...result,...generationRewardMetadata(await nativeRewardStatus(tx,input.actor.id,input.config))};
      }
      const rows=await tx`update game_center_private.generation_requests set state='complete',result=${tx.json(result)},lease_id=null,lease_until=null,updated_at=clock_timestamp()
        where user_id=${input.actor.id} and request_id=${request.request_id} and request_hash=${hash} and lease_id=${leaseID} and lease_until>clock_timestamp() and state='pending' returning request_id`;
      if(!rows.length)throw busy();
    });
    return evidenceFor(result);
  }catch(error){
    if(input.config.APP_NATIVE_GAME_CENTER_AI_PROVIDER==='base44-managed'||reservation.metered||sharedEnabled){
      const outcome=await settleNativeRelayFailure(db,input.actor.id,request.request_id,leaseID,qualityRejected,sharedEnabled).catch(()=> 'unknown');
      if(outcome==='unknown'){
        // The external request may still be running. Retain the bounded topic
        // lease so another account cannot immediately start the same paid work.
        retainSharedClaim=true;
        throw new AppServiceError('generation_in_progress','This attempt is awaiting confirmation. Retry the same request later.',503,true);
      }
      if(outcome==='quality')throw failedNativeAIOutcome('quality_failed');
      if(outcome==='failed')throw failedNativeAIOutcome('provider_failed');
      if(outcome==='replayable')throw new AppServiceError('generation_persistence_retry','The generated words are saved. Retry this same request to recover them.',503,true);
      if(error instanceof AppServiceError&&error.code!=='generation_outcome_unknown')throw error;
      throw new AppServiceError('ai_provider_unavailable','Word generation could not start. Retry the same request.',503,true);
    }
    // Only the worker still owning this request may release its reservation.
    // Deletion removes these rows; this update can never recreate them.
    await db`update game_center_private.generation_requests set state='failed',charged=false,lease_id=null,lease_until=null,error_code='generation_failed',updated_at=clock_timestamp()
      where user_id=${input.actor.id} and request_id=${request.request_id} and lease_id=${leaseID} and state='pending'`.catch(()=>{});
    if(error instanceof AppServiceError)throw error;
    throw new AppServiceError('ai_provider_unavailable','Word generation could not be completed. Retry the same request.',503,true);
  }finally{
    // Token fencing prevents a stale worker from releasing a newer claim. A
    // release outage is bounded by the lease and must not erase a valid result.
    if(sharedClaimed&&!retainSharedClaim&&sharedStore&&sharedRequest)await sharedStore.release(sharedRequest.cacheKey,leaseID).catch(()=>{});
  }
}
export async function dispatchNativeGeneration(ctx:AppContext,body:Record<string,any>) {
  const evidence=ctx.evidence,hash=await requestHash(body);
  if(!evidence||!evidenceSet.has(evidence)||evidence.actor!==ctx.actor.id||evidence.requestID!==body.request_id||evidence.hash!==hash)throw new AppServiceError('generation_verification_required','A server-generated word pack is required.',409);
  const [row]=await ctx.tx`select result from game_center_private.generation_requests where user_id=${ctx.actor.id} and request_id=${body.request_id} and request_hash=${hash} and state='complete'`;
  if(!row)throw busy();
  return row.result;
}

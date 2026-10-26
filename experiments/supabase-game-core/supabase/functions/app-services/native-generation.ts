import {AppServiceError,requireUUID,type AppActor,type AppContext} from './contracts.ts';
import {accountGate} from './account-gate.ts';
import {nativeGameCenterAccount,nativeGameCenterHasMembership} from './native-game-center.ts';
import {canonical,digest} from './integration-crypto.ts';
import {createOpenAIWordPackProvider,assertNoKnownNamedThemeDrift,WORD_PACK_PROMPT_VERSION} from './word-generation/openai-word-pack-provider.ts';
import {filterSafeCommunityStrings,requireSafeCommunityText} from './word-generation/content-safety.ts';
import {normalizeGeneratedWordPack,wordPackComparisonKey} from './word-generation/generation-cache.ts';

type Config=Record<string,string|undefined>;
type Input={actor:AppActor,body:Record<string,any>,config:Config};
const evidenceSet=new WeakSet<object>();
export const NATIVE_AI_DAILY_LIMIT=10;
const busy=()=>new AppServiceError('generation_in_progress','This word pack is still being prepared. Retry the same request.',503,true);
export function nativeGenerationCapabilities(config:Config) {
  return {generator_provider:'openai',configured:config.APP_NATIVE_GAME_CENTER_AI_ENABLED==='true'&&Boolean(config.OPENAI_API_KEY?.trim()),requires_legacy_session:false,linked:false};
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
 * An expired provider lease may be retried, but never grants another quota. */
export async function prepareNativeGeneration(input:Input,dependencies:{db:any,fetch?:typeof fetch}) {
  if(!nativeGenerationCapabilities(input.config).configured)throw new AppServiceError('native_generation_unconfigured','Word generation is not available yet. Try again later.',503,true);
  const request=command(input.body),hash=await requestHash(input.body),db=dependencies.db,leaseID=crypto.randomUUID();
  const evidenceFor=(result:any)=>{const evidence={actor:input.actor.id,requestID:request.request_id,hash,result};evidenceSet.add(evidence);return evidence;};
  const reservation=await db.begin(async(tx:any)=>{
    await requireNative(tx,input.actor.id);
    await tx`select pg_advisory_xact_lock(hashtextextended(${input.actor.id+':native-ai-quota'},0))`;
    const [prior]=await tx`select *,lease_until>clock_timestamp() as leased from game_center_private.generation_requests
      where user_id=${input.actor.id} and request_id=${request.request_id} for update`;
    if(prior&&prior.request_hash!==hash)throw new AppServiceError('request_id_reused','This request belongs to another word pack.',409);
    if(prior?.state==='complete')return {result:prior.result};
    if(prior?.leased)throw busy();
    const [{today}]=await tx`select (clock_timestamp() at time zone 'UTC')::date::text as today`;
    const unlimited=await nativeGameCenterHasMembership(tx,input.actor.id);
    const [{used}]=await tx`select count(*)::int as used from game_center_private.generation_requests where user_id=${input.actor.id} and usage_date=${today} and charged`;
    const keepsCharge=prior?.charged===true;
    if(!unlimited&&!keepsCharge&&used>=NATIVE_AI_DAILY_LIMIT)throw new AppServiceError('ai_limit_reached','Today’s word generation limit has been reached.',429,false);
    await tx`insert into game_center_private.generation_requests(user_id,request_id,request_hash,usage_date,charged,state,lease_id,lease_until)
      values(${input.actor.id},${request.request_id},${hash},${today},true,'pending',${leaseID},clock_timestamp()+interval '120 seconds')
      on conflict(user_id,request_id) do update set state='pending',charged=true,
        usage_date=case when game_center_private.generation_requests.charged then game_center_private.generation_requests.usage_date else excluded.usage_date end,
        lease_id=excluded.lease_id,lease_until=excluded.lease_until,error_code=null,updated_at=clock_timestamp()`;
    return {unlimited,used:used+(keepsCharge?0:1)};
  });
  if(reservation.result)return evidenceFor(reservation.result);
  try{
    const provider=createOpenAIWordPackProvider({apiKey:input.config.OPENAI_API_KEY!,model:input.config.SPYCLASH_OPENAI_MODEL,
      timeoutMilliseconds:45_000,fetch:dependencies.fetch});
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
      const denied=new Set(excluded.map(wordPackComparisonKey));
      const safe=filterSafeCommunityStrings(generated.words).filter(w=>!denied.has(wordPackComparisonKey(w)));
      assertNoKnownNamedThemeDrift(request.theme,safe);
      return {...generated,words:safe};
    };
    const first=await generate(request.count,request.exclude_words);
    let words=first.words,exhausted=first.exhausted&&words.length<request.count;
    if(exhausted){
      const second=await generate(Math.max(2,request.count-words.length),[...request.exclude_words,...words]);
      words=[...words,...second.words];exhausted=second.exhausted&&words.length<request.count;
    }
    const normalized=normalizeGeneratedWordPack({category:request.theme,words:words.slice(0,request.count),exhausted});
    if(normalized.words.length<request.count&&!normalized.exhausted)throw new Error('quality');
    const result={name:request.theme,...normalized,ai_limit:reservation.unlimited?null:NATIVE_AI_DAILY_LIMIT,
      ai_generations_today:reservation.used,ai_remaining:reservation.unlimited?null:Math.max(0,NATIVE_AI_DAILY_LIMIT-reservation.used)};
    await db.begin(async(tx:any)=>{
      await requireNative(tx,input.actor.id);
      const rows=await tx`update game_center_private.generation_requests set state='complete',result=${tx.json(result)},lease_id=null,lease_until=null,updated_at=clock_timestamp()
        where user_id=${input.actor.id} and request_id=${request.request_id} and request_hash=${hash} and lease_id=${leaseID} and lease_until>clock_timestamp() and state='pending' returning request_id`;
      if(!rows.length)throw busy();
    });
    return evidenceFor(result);
  }catch(error){
    // Only the worker still owning this request may release its reservation.
    // Deletion removes these rows; this update can never recreate them.
    await db`update game_center_private.generation_requests set state='failed',charged=false,lease_id=null,lease_until=null,error_code='generation_failed',updated_at=clock_timestamp()
      where user_id=${input.actor.id} and request_id=${request.request_id} and lease_id=${leaseID} and state='pending'`.catch(()=>{});
    if(error instanceof AppServiceError)throw error;
    throw new AppServiceError('ai_provider_unavailable','Word generation could not be completed. Retry the same request.',503,true);
  }
}
export async function dispatchNativeGeneration(ctx:AppContext,body:Record<string,any>) {
  const evidence=ctx.evidence,hash=await requestHash(body);
  if(!evidence||!evidenceSet.has(evidence)||evidence.actor!==ctx.actor.id||evidence.requestID!==body.request_id||evidence.hash!==hash)throw new AppServiceError('generation_verification_required','A server-generated word pack is required.',409);
  const [row]=await ctx.tx`select result from game_center_private.generation_requests where user_id=${ctx.actor.id} and request_id=${body.request_id} and request_hash=${hash} and state='complete'`;
  if(!row)throw busy();
  return row.result;
}

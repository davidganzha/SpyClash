import {AppServiceError} from './contracts.ts';
import {accountGate} from './account-gate.ts';
import {nativeGameCenterAccount} from './native-game-center.ts';
import {RELAY_BASE44_URL,RELAY_PROMPT_VERSION,RelayProtocolError,readRelayRequest,relayHeaders,relayCanonical,relayDigest,relaySecretConfigured,validateRelayTicket,validateRelayResult,type RelayTicket,type RelayInput} from './native-ai-relay-protocol.ts';
type Config=Record<string,string|undefined>;
export const unknownNativeAIOutcome=()=>new AppServiceError('generation_outcome_unknown','The previous AI attempt was not confirmed. It was not repeated or charged again.',503,false);
const stale=()=>new AppServiceError('relay_lease_expired','This generation attempt is no longer active.',409,false);
export function nativeRelayConfigured(config:Config){return config.APP_NATIVE_GAME_CENTER_AI_ENABLED==='true'&&config.APP_NATIVE_GAME_CENTER_AI_PROVIDER==='base44-managed'&&relaySecretConfigured(config.SPYCLASH_NATIVE_AI_RELAY_SECRET);}
async function account(tx:any,id:string){
  const profile=await accountGate(tx,id);
  if(!profile||(await nativeGameCenterAccount(tx,id))?.state!=='ready')throw new AppServiceError('account_unavailable','This account is unavailable.',403);
}
// Lock ordering is account -> generation request -> provider call everywhere.
async function activeRequest(tx:any,ticket:RelayTicket){
  await account(tx,ticket.actor_id);
  const [request]=await tx`select *,lease_until>clock_timestamp() as leased from game_center_private.generation_requests
    where user_id=${ticket.actor_id} and request_id=${ticket.request_id} for update`;
  if(!request||request.request_hash!==ticket.request_hash||request.state!=='pending'||request.lease_id!==ticket.lease_id||!request.leased)throw stale();
  return request;
}
export function createNativeAIRelayHandler(db:any,config:Config){
  return async(request:Request)=>{
    try{
      if(!nativeRelayConfigured(config))throw new RelayProtocolError('relay_unconfigured',503);
      const path=new URL(request.url).pathname;
      const action=path.endsWith('/native-ai-relay/claim')?'claim':path.endsWith('/native-ai-relay/complete')?'complete':null;
      if(!action)throw new RelayProtocolError('not_found',404);
      const body=await readRelayRequest(request,config.SPYCLASH_NATIVE_AI_RELAY_SECRET!,action);
      const ticket=await validateRelayTicket(action==='claim'?body:body.ticket);
      if(action==='complete'&&(!body||Object.keys(body).sort().join(',')!=='claim_id,result,ticket'||typeof body.claim_id!=='string'))throw new RelayProtocolError('invalid_relay_payload',400);
      const result=action==='complete'?validateRelayResult(body.result):undefined;
      const resultHash=result?await relayDigest(relayCanonical(result)):null;
      const reply=await db.begin(async(tx:any)=>{
        await activeRequest(tx,ticket);
        const [call]=await tx`select * from game_center_private.generation_provider_calls where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index} for update`;
        if(!call||call.input_hash!==ticket.input_hash||call.lease_id!==ticket.lease_id)throw stale();
        if(action==='claim'){
          if(call.state==='complete')return {state:'complete'};
          if(call.state!=='prepared')throw unknownNativeAIOutcome();
          const claimID=crypto.randomUUID();
          await tx`update game_center_private.generation_provider_calls set state='started',claim_id=${claimID},updated_at=clock_timestamp()
            where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index}`;
          return {state:'started',claim_id:claimID};
        }
        if(call.claim_id!==body.claim_id)throw stale();
        if(call.state==='complete'){
          if(call.result_hash!==resultHash)throw new AppServiceError('relay_result_conflict','This result has already been recorded.',409);
          return {state:'complete'};
        }
        if(call.state!=='started')throw stale();
        await tx`update game_center_private.generation_provider_calls set state='complete',result=${tx.json(result)},result_hash=${resultHash},updated_at=clock_timestamp()
          where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index}`;
        return {state:'complete'};
      });
      return Response.json(reply);
    }catch(error){
      const expected=error instanceof AppServiceError||error instanceof RelayProtocolError;
      return Response.json({code:expected?error.code:'relay_unavailable'},{status:expected?error.status:503});
    }
  };
}

/** HTTP replies are acknowledgements only: only the durable authenticated
 * completion record can supply words to the native generation engine. */
export function createNativeAIRelayProvider(options:{db:any,config:Config,actorID:string,requestID:string,requestHash:string,leaseID:string,fetch?:typeof fetch}){
  let index=0;
  return {generate:async(input:RelayInput)=>{
    const callIndex=index++;
    const ticket=await validateRelayTicket({actor_id:options.actorID,request_id:options.requestID,request_hash:options.requestHash,
      lease_id:options.leaseID,call_index:callIndex,input_hash:await relayDigest(relayCanonical({version:RELAY_PROMPT_VERSION,...input})),input});
    const cached=await options.db.begin(async(tx:any)=>{
      await activeRequest(tx,ticket);
      const [prior]=await tx`select * from game_center_private.generation_provider_calls where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${callIndex} for update`;
      if(prior&&prior.input_hash!==ticket.input_hash)throw new AppServiceError('relay_input_conflict','This attempt belongs to different words.',409);
      if(prior?.state==='complete')return validateRelayResult(prior.result);
      if(prior?.state==='started')throw unknownNativeAIOutcome();
      await tx`insert into game_center_private.generation_provider_calls(user_id,request_id,call_index,input_hash,lease_id,state)
        values(${ticket.actor_id},${ticket.request_id},${callIndex},${ticket.input_hash},${ticket.lease_id},'prepared')
        on conflict(user_id,request_id,call_index) do update set lease_id=excluded.lease_id,updated_at=clock_timestamp()`;
      return null;
    });
    if(cached)return cached;
    const body=JSON.stringify(ticket);
    try{
      await (options.fetch||fetch)(RELAY_BASE44_URL,{method:'POST',headers:await relayHeaders(options.config.SPYCLASH_NATIVE_AI_RELAY_SECRET!,'invoke',body),body,redirect:'error',signal:AbortSignal.timeout(60_000)});
    }catch{/* A lost acknowledgement never authorizes another provider call. */}
    const [completed]=await options.db`select result from game_center_private.generation_provider_calls
      where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${callIndex} and input_hash=${ticket.input_hash} and state='complete'`;
    if(completed)return validateRelayResult(completed.result);
    throw unknownNativeAIOutcome();
  }};
}

/** Called inside the reservation transaction after its old lease expires. */
export async function nativeRelayHasUnknownOutcome(tx:any,userID:string,requestID:string){
  return (await tx`select 1 from game_center_private.generation_provider_calls where user_id=${userID} and request_id=${requestID} and state='started' limit 1`).length>0;
}
/** The request lock fences a late claim against releasing an unspent quota.
 * Started work keeps its lease so an in-flight completion can still be saved. */
export async function settleNativeRelayFailure(db:any,userID:string,requestID:string,leaseID:string){
  return await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    const [row]=await tx`select * from game_center_private.generation_requests where user_id=${userID} and request_id=${requestID} and lease_id=${leaseID} and state='pending' for update`;
    if(!row)return 'stale';
    const calls=await tx`select state from game_center_private.generation_provider_calls where user_id=${userID} and request_id=${requestID}`;
    if(calls.some((call:any)=>call.state==='started'))return 'unknown';
    const spent=calls.some((call:any)=>call.state==='complete');
    await tx`update game_center_private.generation_requests set state='failed',charged=${spent},lease_id=null,lease_until=null,
      error_code=${spent?'generation_quality_failed':'generation_failed'},updated_at=clock_timestamp()
      where user_id=${userID} and request_id=${requestID} and lease_id=${leaseID} and state='pending'`;
    return spent?'quality':'unspent';
  });
}

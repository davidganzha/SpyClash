import {AppServiceError} from './contracts.ts';
import {accountGate} from './account-gate.ts';
import {nativeGameCenterAccount} from './native-game-center.ts';
import {RELAY_BASE44_URL,RELAY_PROMPT_VERSION,RelayProtocolError,readRelayRequest,relayHeaders,relayCanonical,relayDigest,relaySecretConfigured,validateRelayTicket,validateRelayResult,type RelayTicket,type RelayInput} from './native-ai-relay-protocol.ts';
import {lockGenerationQuota,releaseRewardGeneration} from './generation-reward-ledger.ts';
type Config=Record<string,string|undefined>;
export const unknownNativeAIOutcome=()=>new AppServiceError('generation_outcome_unknown','The previous AI attempt was not confirmed. It was not repeated or charged again.',503,false);
// 422 settles the installed app's durable write journal. An unrecoverable
// provider claim must not masquerade as a retryable infrastructure outage.
// Build 200 replaces generation_outcome_unknown messages with guidance that
// only works with a 503. Use a distinct wire code for this terminal 422.
export const terminalNativeAIOutcome=()=>new AppServiceError('generation_attempt_closed','This generation could not be confirmed. Close and reopen the generator to start a new attempt.',422,false);
export const failedNativeAIOutcome=(reason:string)=>new AppServiceError(
  reason==='quality_failed'?'generation_quality_failed':'generation_failed',
  reason==='quality_failed'?'The generated words did not meet the quality check. Close and reopen the generator to try again.':'This generation did not finish. Close and reopen the generator to start a new attempt.',422,false);
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
      const action=path.endsWith('/native-ai-relay/claim')?'claim':path.endsWith('/native-ai-relay/complete')?'complete':path.endsWith('/native-ai-relay/fail')?'fail':null;
      if(!action)throw new RelayProtocolError('not_found',404);
      const body=await readRelayRequest(request,config.SPYCLASH_NATIVE_AI_RELAY_SECRET!,action);
      const ticket=await validateRelayTicket(action==='claim'?body:body.ticket);
      if(action==='complete'&&(!body||Object.keys(body).sort().join(',')!=='claim_id,result,ticket'||typeof body.claim_id!=='string'))throw new RelayProtocolError('invalid_relay_payload',400);
      if(action==='fail'&&(!body||Object.keys(body).sort().join(',')!=='claim_id,failure,ticket'||typeof body.claim_id!=='string'||!['provider_failed','quality_failed'].includes(body.failure)))throw new RelayProtocolError('invalid_relay_payload',400);
      const result=action==='complete'?validateRelayResult(body.result):undefined;
      const resultHash=result?await relayDigest(relayCanonical(result)):null;
      const reply=await db.begin(async(tx:any)=>{
        await account(tx,ticket.actor_id);
        await lockGenerationQuota(tx,ticket.actor_id);
        const [generation]=await tx`select *,lease_until>clock_timestamp() as leased from game_center_private.generation_requests
          where user_id=${ticket.actor_id} and request_id=${ticket.request_id} for update`;
        if(!generation||generation.request_hash!==ticket.request_hash)throw stale();
        const [call]=await tx`select * from game_center_private.generation_provider_calls where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index} for update`;
        if(!call||call.input_hash!==ticket.input_hash||call.lease_id!==ticket.lease_id)throw stale();
        // An acknowledgement may be lost after either transaction commits.
        // Read-only replay remains valid after the generation itself finishes.
        if(action!=='claim'){
          if(call.claim_id!==body.claim_id)throw stale();
          if(action==='complete'&&call.state==='complete'){
            if(call.result_hash!==resultHash)throw new AppServiceError('relay_result_conflict','This result has already been recorded.',409);
            return {state:'complete'};
          }
          if(action==='fail'&&call.state==='failed'){
            if(call.error_code!==body.failure)throw new AppServiceError('relay_result_conflict','This outcome has already been recorded.',409);
            return {state:'failed'};
          }
          if(call.state!=='started')throw stale();
        }
        // New metered attempts retain the provider claim across a worker lease
        // expiry. Accept the same signed claim's late terminal outcome so its
        // credit/result can recover without another advertisement/provider call.
        const lateRewardOutcome=action!=='claim'&&generation.charge_source&&generation.charge_source!=='legacy'
          &&call.state==='started'&&generation.state!=='complete';
        if(!lateRewardOutcome&&(generation.state!=='pending'||generation.lease_id!==ticket.lease_id||!generation.leased))throw stale();
        if(action==='claim'){
          if(call.state==='complete')return {state:'complete'};
          if(call.state!=='prepared')throw unknownNativeAIOutcome();
          const claimID=crypto.randomUUID();
          await tx`update game_center_private.generation_provider_calls set state='started',claim_id=${claimID},updated_at=clock_timestamp()
            where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index}`;
          return {state:'started',claim_id:claimID};
        }
        if(action==='fail'){
          await tx`update game_center_private.generation_provider_calls set state='failed',error_code=${body.failure},updated_at=clock_timestamp()
            where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${ticket.call_index}`;
          if(generation.charge_source&&generation.charge_source!=='legacy'){
            await releaseRewardGeneration(tx,ticket.actor_id,ticket.request_id,generation);
            await tx`update game_center_private.generation_requests set state='failed',lease_id=null,lease_until=null,
              error_code=${body.failure==='quality_failed'?'generation_quality_failed':'generation_provider_failed'},updated_at=clock_timestamp()
              where user_id=${ticket.actor_id} and request_id=${ticket.request_id}`;
          }
          return {state:'failed'};
        }
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
      if(prior?.state==='failed')throw failedNativeAIOutcome(prior.error_code);
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
    const [completed]=await options.db`select state,result,error_code from game_center_private.generation_provider_calls
      where user_id=${ticket.actor_id} and request_id=${ticket.request_id} and call_index=${callIndex} and input_hash=${ticket.input_hash}`;
    if(completed?.state==='complete')return validateRelayResult(completed.result);
    if(completed?.state==='failed')throw failedNativeAIOutcome(completed.error_code);
    throw unknownNativeAIOutcome();
  }};
}

/** Called inside the reservation transaction after its old lease expires. */
export async function nativeRelayHasUnknownOutcome(tx:any,userID:string,requestID:string){
  return (await tx`select 1 from game_center_private.generation_provider_calls where user_id=${userID} and request_id=${requestID} and state='started' limit 1`).length>0;
}
/** The request lock fences a late claim against releasing an unspent quota.
 * Started work keeps its lease so an in-flight completion can still be saved. */
export async function settleNativeRelayFailure(db:any,userID:string,requestID:string,leaseID:string,qualityRejected=false,refundDefinitiveLegacyFailure=false){
  return await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    await lockGenerationQuota(tx,userID);
    const [row]=await tx`select * from game_center_private.generation_requests where user_id=${userID} and request_id=${requestID} and lease_id=${leaseID} and state='pending' for update`;
    if(!row){
      const [settled]=await tx`select error_code from game_center_private.generation_requests where user_id=${userID} and request_id=${requestID} and not charged and charge_source<>'legacy'`;
      if(settled?.error_code==='generation_quality_failed')return 'quality';
      if(settled?.error_code==='generation_provider_failed')return 'failed';
      return 'stale';
    }
    const calls=await tx`select state,error_code from game_center_private.generation_provider_calls where user_id=${userID} and request_id=${requestID}`;
    if(calls.some((call:any)=>call.state==='started'))return 'unknown';
    const failure=calls.find((call:any)=>call.state==='failed');
    const spent=calls.some((call:any)=>call.state==='complete'||call.state==='failed');
    const quality=qualityRejected||failure?.error_code==='quality_failed';
    // A completed provider result is not evidence of a quality rejection.
    // Release only our worker lease and replay cached output after DB outages.
    const outcome=quality?'quality':failure?'failed':spent?'replayable':'unspent';
    const errorCode=quality?'generation_quality_failed':failure?'generation_provider_failed':spent?'generation_persistence_retry':'generation_failed';
    // Shared-library requests also journal direct provider work under the
    // existing legacy quota. Definite failure refunds that quota without
    // changing its source, limit, or handling an unknown outcome as failure.
    const refundable=row.charge_source&&(row.charge_source!=='legacy'||refundDefinitiveLegacyFailure)&&(quality||Boolean(failure)||!spent);
    if(refundable)await releaseRewardGeneration(tx,userID,requestID,row);
    await tx`update game_center_private.generation_requests set state='failed',charged=${spent&&!refundable},lease_id=null,lease_until=null,
      error_code=${errorCode},updated_at=clock_timestamp()
      where user_id=${userID} and request_id=${requestID} and lease_id=${leaseID} and state='pending'`;
    return outcome;
  });
}

import {RELAY_CALLBACK_URL,RelayProtocolError,readRelayRequest,relayHeaders,relaySecretConfigured,validateRelayTicket,validateRelayResult,type RelayAction,type RelayResult} from './relay-protocol.ts';
import {BASE44_WORD_PACK_MODEL,buildWordPackPrompt,wordPackResponseSchema} from './openai-word-pack-provider.ts';
import {applyWordPackSelfAudit} from './word-pack-quality.ts';
import {canonicalBase44Request} from './base44-context.ts';

type RelayStage = 'configuration'|'authenticate'|'validate_ticket'|'claim_signing'|'claim_options'|'claim_transport'|'claim_response'|'claim_result'|'provider'|'validate_result'|'complete_signing'|'complete_options'|'complete_transport'|'complete_response'|'fail_signing'|'fail_options'|'fail_transport'|'fail_response';
export type RelayDiagnostic = {stage:RelayStage;callback_status?:number};
const RESULT_RETRY_DELAYS = [250,750];
const RETRYABLE_CALLBACK_STATUSES = new Set([408,425,429,500,502,503,504]);

/** No user session, quota, entitlement or arbitrary prompt enters this function.
 * The durable Supabase claim, committed before InvokeLLM, permits exactly one call. */
export function relayGatewayTokenValid(token:string){
  try{
    const parts=token.split('.');if(parts.length!==3)return false;
    const part=parts[1].replace(/-/g,'+').replace(/_/g,'/');
    const claims=JSON.parse(atob(part.padEnd(Math.ceil(part.length/4)*4,'=')));
    return claims.role==='anon'&&claims.ref==='bbkfsgnordtdiblgdzkg';
  }catch{return false;}
}
export function createNativeWordPackRelay(options:{secret:string,gatewayToken:string,invoke:(request:Request,input:any)=>Promise<any>,fetch?:typeof fetch,diagnose?:(event:RelayDiagnostic)=>void,delay?:(milliseconds:number)=>Promise<void>,now?:()=>number}) {
  const fetcher=options.fetch||fetch;
  const delay=options.delay||((milliseconds:number)=>new Promise<void>(resolve=>setTimeout(resolve,milliseconds)));
  return async(request:Request)=>{
    let stage:RelayStage='configuration',callbackStatus:number|undefined;
    const diagnose=()=>{
      try{options.diagnose?.({stage,...(callbackStatus===undefined?{}:{callback_status:callbackStatus})});}catch{/* Diagnostics must not change the protocol response. */}
    };
    try{
      if(!relaySecretConfigured(options.secret)||!relayGatewayTokenValid(options.gatewayToken))throw new RelayProtocolError('relay_unconfigured',503);
      stage='authenticate';
      const payload=await readRelayRequest(request,options.secret,'invoke');
      stage='validate_ticket';
      const ticket=await validateRelayTicket(payload);
      const callback=async(action:Extract<RelayAction,'claim'|'complete'|'fail'>,payload:any)=>{
        const body=JSON.stringify(payload);
        // Outcome writes are idempotent and bound to the exact claim and value.
        // Retrying their acknowledgement cannot repeat provider work. A claim is
        // intentionally single-shot: its lost response may already own paid work.
        const delays=action==='claim'?[]:RESULT_RETRY_DELAYS;
        for(let attempt=0;;attempt++){
          callbackStatus=undefined;
          stage=`${action}_signing`;
          const headers={...await relayHeaders(options.secret,action,body,options.now?.()??Date.now()),Authorization:'Bearer '+options.gatewayToken,apikey:options.gatewayToken};
          stage=`${action}_options`;
          const signal=AbortSignal.timeout(10_000);
          stage=`${action}_transport`;
          let response:Response;
          try{
            // Manual never forwards credentials. Redirects are rejected below.
            response=await fetcher(RELAY_CALLBACK_URL+'/'+action,{method:'POST',headers,body,redirect:'manual',signal});
          }catch(error){
            if(attempt>=delays.length)throw error;
            await delay(delays[attempt]);continue;
          }
          callbackStatus=response.status;
          stage=`${action}_response`;
          if(!response.ok){
            if(attempt<delays.length&&RETRYABLE_CALLBACK_STATUSES.has(response.status)){
              await response.body?.cancel().catch(()=>{});
              await delay(delays[attempt]);continue;
            }
            throw new RelayProtocolError('relay_callback_unavailable',503);
          }
          let result:any;
          try{result=await response.json();}catch(error){
            // A lost/truncated acknowledgement can follow a committed result.
            if(attempt>=delays.length)throw error;
            await delay(delays[attempt]);continue;
          }
          if(action!=='claim'&&result?.state!==(action==='complete'?'complete':'failed'))throw new RelayProtocolError('relay_callback_unavailable',503);
          return result;
        }
      };
      const claim=await callback('claim',ticket);
      stage='claim_result';
      if(claim.state==='complete')return Response.json({ok:true});
      if(claim.state!=='started'||typeof claim.claim_id!=='string')throw new RelayProtocolError('relay_claim_unavailable',503);
      const reportFailure=async(failure:'provider_failed'|'quality_failed')=>{
        const originalStage=stage;
        try{await callback('fail',{ticket,claim_id:claim.claim_id,failure});}catch{diagnose();}
        // A failed callback leaves the durable claim ambiguous. Never claim an
        // unspent request, retry the provider, or replace the original failure.
        stage=originalStage;callbackStatus=undefined;
      };
      // Deliberately no provider retries or fallback after this point: failure
      // may mean the paid provider executed and its acknowledgement was lost.
      stage='provider';callbackStatus=undefined;
      let candidate:any;
      try{
        candidate=await options.invoke(canonicalBase44Request(request),{model:BASE44_WORD_PACK_MODEL,
          prompt:buildWordPackPrompt(ticket.input),response_json_schema:wordPackResponseSchema(ticket.input.theme,ticket.input.count)});
      }catch(error){await reportFailure('provider_failed');throw error;}
      stage='validate_result';
      let result:RelayResult;
      try{
        const audited=applyWordPackSelfAudit(candidate,ticket.input.count,ticket.input.alreadyUsed);
        result=validateRelayResult({words:audited.words,category:audited.category,exhausted:audited.exhausted});
      }catch(error){await reportFailure('quality_failed');throw error;}
      // A completion outage must only retry these same valid words, never
      // report failure and discard a result which may already be committed.
      await callback('complete',{ticket,claim_id:claim.claim_id,result});
      return Response.json({ok:true});
    }catch(error){
      // Only fixed stage names and a numeric HTTP status may leave this scope.
      // Never log upstream bodies, headers, tickets, prompts or exception text.
      diagnose();
      const status=error instanceof RelayProtocolError?error.status:503;
      return Response.json({ok:false,code:status===401?'invalid_relay_request':'relay_unavailable'},{status});
    }
  };
}

import {RELAY_CALLBACK_URL,RelayProtocolError,readRelayRequest,relayHeaders,relaySecretConfigured,validateRelayTicket,validateRelayResult,type RelayAction} from './relay-protocol.ts';
import {BASE44_WORD_PACK_MODEL,buildWordPackPrompt,wordPackResponseSchema} from './openai-word-pack-provider.ts';
import {applyWordPackSelfAudit} from './word-pack-quality.ts';
import {canonicalBase44Request} from './base44-context.ts';

type RelayStage = 'configuration'|'authenticate'|'validate_ticket'|'claim_signing'|'claim_options'|'claim_transport'|'claim_response'|'claim_result'|'provider'|'validate_result'|'complete_signing'|'complete_options'|'complete_transport'|'complete_response';
export type RelayDiagnostic = {stage:RelayStage;callback_status?:number};

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
export function createNativeWordPackRelay(options:{secret:string,gatewayToken:string,invoke:(request:Request,input:any)=>Promise<any>,fetch?:typeof fetch,diagnose?:(event:RelayDiagnostic)=>void}) {
  const fetcher=options.fetch||fetch;
  return async(request:Request)=>{
    let stage:RelayStage='configuration',callbackStatus:number|undefined;
    try{
      if(!relaySecretConfigured(options.secret)||!relayGatewayTokenValid(options.gatewayToken))throw new RelayProtocolError('relay_unconfigured',503);
      stage='authenticate';
      const payload=await readRelayRequest(request,options.secret,'invoke');
      stage='validate_ticket';
      const ticket=await validateRelayTicket(payload);
      const callback=async(action:Extract<RelayAction,'claim'|'complete'>,payload:any)=>{
        callbackStatus=undefined;
        stage=action==='claim'?'claim_signing':'complete_signing';
        const body=JSON.stringify(payload);
        const headers={...await relayHeaders(options.secret,action,body),Authorization:'Bearer '+options.gatewayToken,apikey:options.gatewayToken};
        stage=action==='claim'?'claim_options':'complete_options';
        const signal=AbortSignal.timeout(10_000);
        stage=action==='claim'?'claim_transport':'complete_transport';
        // Workers rejects redirect:'error' before sending. Manual never forwards
        // credentials; every 3xx is rejected by the non-2xx check below.
        const response=await fetcher(RELAY_CALLBACK_URL+'/'+action,{method:'POST',headers,body,redirect:'manual',signal});
        callbackStatus=response.status;
        stage=action==='claim'?'claim_response':'complete_response';
        if(!response.ok)throw new RelayProtocolError('relay_claim_unavailable',503);
        return await response.json();
      };
      const claim=await callback('claim',ticket);
      stage='claim_result';
      if(claim.state==='complete')return Response.json({ok:true});
      if(claim.state!=='started'||typeof claim.claim_id!=='string')throw new RelayProtocolError('relay_claim_unavailable',503);
      // Deliberately no provider retries or fallback after this point: failure
      // may mean the paid provider executed and its acknowledgement was lost.
      stage='provider';callbackStatus=undefined;
      const candidate=await options.invoke(canonicalBase44Request(request),{model:BASE44_WORD_PACK_MODEL,
        prompt:buildWordPackPrompt(ticket.input),response_json_schema:wordPackResponseSchema(ticket.input.theme,ticket.input.count)});
      stage='validate_result';
      const audited=applyWordPackSelfAudit(candidate,ticket.input.count,ticket.input.alreadyUsed);
      const result=validateRelayResult({words:audited.words,category:audited.category,exhausted:audited.exhausted});
      await callback('complete',{ticket,claim_id:claim.claim_id,result});
      return Response.json({ok:true});
    }catch(error){
      // Only fixed stage names and a numeric HTTP status may leave this scope.
      // Never log upstream bodies, headers, tickets, prompts or exception text.
      try{options.diagnose?.({stage,...(callbackStatus===undefined?{}:{callback_status:callbackStatus})});}catch{/* Diagnostics must not change the protocol response. */}
      const status=error instanceof RelayProtocolError?error.status:503;
      return Response.json({ok:false,code:status===401?'invalid_relay_request':'relay_unavailable'},{status});
    }
  };
}

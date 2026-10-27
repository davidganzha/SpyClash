import {RELAY_CALLBACK_URL,RelayProtocolError,readRelayRequest,relayHeaders,relaySecretConfigured,validateRelayTicket,validateRelayResult,type RelayAction} from './relay-protocol.ts';
import {BASE44_WORD_PACK_MODEL,buildWordPackPrompt,wordPackResponseSchema} from './openai-word-pack-provider.ts';
import {applyWordPackSelfAudit} from './word-pack-quality.ts';
import {canonicalBase44Request} from './base44-context.ts';

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
export function createNativeWordPackRelay(options:{secret:string,gatewayToken:string,invoke:(request:Request,input:any)=>Promise<any>,fetch?:typeof fetch}) {
  const fetcher=options.fetch||fetch;
  return async(request:Request)=>{
    try{
      if(!relaySecretConfigured(options.secret)||!relayGatewayTokenValid(options.gatewayToken))throw new RelayProtocolError('relay_unconfigured',503);
      const ticket=await validateRelayTicket(await readRelayRequest(request,options.secret,'invoke'));
      const callback=async(action:RelayAction,payload:any)=>{
        const body=JSON.stringify(payload);
        const headers={...await relayHeaders(options.secret,action,body),Authorization:'Bearer '+options.gatewayToken,apikey:options.gatewayToken};
        const response=await fetcher(RELAY_CALLBACK_URL+'/'+action,{method:'POST',headers,body,redirect:'error',signal:AbortSignal.timeout(10_000)});
        if(!response.ok)throw new RelayProtocolError('relay_claim_unavailable',503);
        return await response.json();
      };
      const claim=await callback('claim',ticket);
      if(claim.state==='complete')return Response.json({ok:true});
      if(claim.state!=='started'||typeof claim.claim_id!=='string')throw new RelayProtocolError('relay_claim_unavailable',503);
      // Deliberately no provider retries or fallback after this point: failure
      // may mean the paid provider executed and its acknowledgement was lost.
      const candidate=await options.invoke(canonicalBase44Request(request),{model:BASE44_WORD_PACK_MODEL,
        prompt:buildWordPackPrompt(ticket.input),response_json_schema:wordPackResponseSchema(ticket.input.theme,ticket.input.count)});
      const audited=applyWordPackSelfAudit(candidate,ticket.input.count,ticket.input.alreadyUsed);
      const result=validateRelayResult({words:audited.words,category:audited.category,exhausted:audited.exhausted});
      await callback('complete',{ticket,claim_id:claim.claim_id,result});
      return Response.json({ok:true});
    }catch(error){
      const status=error instanceof RelayProtocolError?error.status:503;
      return Response.json({ok:false,code:status===401?'invalid_relay_request':'relay_unavailable'},{status});
    }
  };
}

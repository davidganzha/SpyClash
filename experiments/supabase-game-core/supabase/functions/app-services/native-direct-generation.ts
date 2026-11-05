import {accountGate} from './account-gate.ts';
import {AppServiceError} from './contracts.ts';
import {canonical,digest} from './integration-crypto.ts';
import {createOpenAIWordPackProvider} from './word-generation/openai-word-pack-provider.ts';
import {failedNativeAIOutcome,unknownNativeAIOutcome} from './native-ai-relay.ts';

/** Durable direct-provider claims use the same journal as the signed relay.
 * A lost network result never authorizes repeating paid work. A still-running
 * worker can save its late result; the next same-ID retry replays that result. */
export function createDurableNativeDirectProvider(options:{db:any,config:Record<string,string|undefined>,actorID:string,requestID:string,leaseID:string,fetch?:typeof fetch}){
  let index=0;
  return {generate:async(input:{theme:string,count:number,alreadyUsed:string[]})=>{
    const callIndex=index++,hash=await digest(canonical(input));
    const cached=await options.db.begin(async(tx:any)=>{
      await accountGate(tx,options.actorID);
      const [request]=await tx`select * from game_center_private.generation_requests where user_id=${options.actorID} and request_id=${options.requestID} for update`;
      if(!request||request.state!=='pending'||request.lease_id!==options.leaseID)throw unknownNativeAIOutcome();
      const [prior]=await tx`select * from game_center_private.generation_provider_calls where user_id=${options.actorID} and request_id=${options.requestID} and call_index=${callIndex} for update`;
      if(prior&&prior.input_hash!==hash)throw new AppServiceError('relay_input_conflict','This request belongs to different words.',409);
      if(prior?.state==='complete')return prior.result;
      if(prior?.state==='started')throw unknownNativeAIOutcome();
      if(prior?.state==='failed')throw failedNativeAIOutcome(prior.error_code);
      await tx`insert into game_center_private.generation_provider_calls(user_id,request_id,call_index,input_hash,lease_id,claim_id,state)
        values(${options.actorID},${options.requestID},${callIndex},${hash},${options.leaseID},${crypto.randomUUID()},'started')`;
      return null;
    });
    if(cached)return cached;
    let receivedCompleteResponse=false;
    const observedFetch:typeof fetch=async(input,init)=>{
      const response=await (options.fetch||fetch)(input,init);
      // Headers alone do not establish an outcome. Read the complete body
      // while the provider timeout is still armed; a broken stream remains an
      // unknown result and must not release this request's reserved credit.
      const body=await response.text();
      receivedCompleteResponse=true;
      return new Response(body||null,{status:response.status,statusText:response.statusText,headers:response.headers});
    };
    const provider=createOpenAIWordPackProvider({apiKey:options.config.OPENAI_API_KEY!,model:options.config.SPYCLASH_OPENAI_MODEL,timeoutMilliseconds:45_000,fetch:observedFetch});
    let result;
    try{
      result=await provider.generate(input);
    }catch(error){
      // Only a fully received rejected/invalid provider response is definitive.
      // Persistence errors occur outside this block and never become a failure.
      if(receivedCompleteResponse)await options.db`update game_center_private.generation_provider_calls set state='failed',error_code='provider_failed',updated_at=clock_timestamp()
        where user_id=${options.actorID} and request_id=${options.requestID} and call_index=${callIndex} and lease_id=${options.leaseID} and state='started'`.catch(()=>{});
      throw error;
    }
    const resultHash=await digest(canonical(result));
    // Retry only delivery of this already-generated result, never the provider.
    // A commit with a lost ACK is reconciled by the same immutable result hash.
    for(let attempt=0;attempt<3;attempt++){
      try{
        await options.db.begin(async(tx:any)=>{
          await accountGate(tx,options.actorID);
          const [stored]=await tx`select state,result_hash,lease_id,input_hash from game_center_private.generation_provider_calls
            where user_id=${options.actorID} and request_id=${options.requestID} and call_index=${callIndex} for update`;
          if(stored?.state==='complete'&&stored.result_hash===resultHash)return;
          if(!stored||stored.state!=='started'||stored.lease_id!==options.leaseID||stored.input_hash!==hash)throw unknownNativeAIOutcome();
          await tx`update game_center_private.generation_provider_calls set state='complete',result=${tx.json(result)},result_hash=${resultHash},updated_at=clock_timestamp()
            where user_id=${options.actorID} and request_id=${options.requestID} and call_index=${callIndex} and lease_id=${options.leaseID} and state='started'`;
        });
        return result;
      }catch(error){
        if(error instanceof AppServiceError&&error.code==='account_unavailable')throw error;
        if(attempt===2)throw new AppServiceError('generation_persistence_retry','The result is awaiting confirmation. Retry this same request.',503,true);
      }
    }
    throw unknownNativeAIOutcome();
  }};
}

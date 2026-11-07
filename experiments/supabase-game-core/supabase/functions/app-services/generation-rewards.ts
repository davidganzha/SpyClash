import {AppServiceError,requireUUID,type AppActor,type AppContext} from './contracts.ts';
import {accountGate} from './account-gate.ts';
import {nativeGameCenterAccount,resolveNativeGameCenterAccount} from './native-game-center.ts';
import {verifyLegacyCredential,boundedLegacyJSON} from './legacy-provider.ts';
import {lockGenerationQuota,nativeRewardStatus,rewardedAdUnit,rewardedGenerationEnabled,type RewardConfig} from './generation-reward-ledger.ts';
import {verifyAdMobCallback,AdMobVerificationError} from './admob-ssv.ts';
const evidenceSet=new WeakSet<object>();
const actions=new Set(['status','prepare','claim_status']);
const randomToken=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),v=>v.toString(16).padStart(2,'0')).join('');
function validate(body:Record<string,any>){
  if(!actions.has(body.action))throw new AppServiceError('invalid_action','Unknown generation reward action.');
  if(body.action==='prepare')requireUUID(body.request_id,'request_id');
  if(body.action==='claim_status')requireUUID(body.attempt_id,'attempt_id');
}
/** Legacy quotas remain owned by Base44. Never create a second reward wallet
 * for the same user on the proxy backend. Credentials are verified and mapped
 * before any external action, then checked again before accepting its result. */
export async function prepareGenerationRewards(input:{actor:AppActor,body:Record<string,any>,config:RewardConfig},deps:{db:any,fetch?:typeof fetch}){
  validate(input.body);
  if(await resolveNativeGameCenterAccount(deps.db,input.actor.id))return undefined;
  const verified=await verifyLegacyCredential(input.config,input.body.base44_access_token,deps.fetch||fetch);
  const {identity,credential,...destination}=verified;
  await deps.db.begin(async(tx:any)=>{
    await accountGate(tx,input.actor.id);
    const [link]=await tx`select legacy_user_id,source_origin,state from app_private.legacy_links where user_id=${input.actor.id}`;
    if(!link||link.state!=='active'||link.legacy_user_id!==identity.id||link.source_origin!==destination.origin)
      throw new AppServiceError('legacy_link_required','Verify this account before continuing.',409);
  });
  const body={action:input.body.action,...(input.body.action==='prepare'?{request_id:input.body.request_id}:{}),
    ...(input.body.action==='claim_status'?{attempt_id:input.body.attempt_id}:{})};
  const response=await (deps.fetch||fetch)(destination.origin+'/api/apps/'+destination.appID+'/functions/generationRewardAction',{
    method:'POST',headers:{Authorization:'Bearer '+credential,'X-App-Id':destination.appID,Origin:destination.origin,'Content-Type':'application/json'},
    redirect:'error',body:JSON.stringify(body),signal:AbortSignal.timeout(20_000)});
  const result=await boundedLegacyJSON(response);
  if(!response.ok)throw new AppServiceError(typeof result.code==='string'?result.code:'generation_reward_unavailable',
    'The reward could not be confirmed. Try again shortly.',response.status>=500?503:response.status,response.status>=500);
  if(typeof result.enabled!=='boolean'&&typeof result.status?.enabled!=='boolean')throw new AppServiceError('invalid_reward_status','The reward status could not be verified.',502,true);
  const evidence={actor:input.actor.id,legacyID:identity.id,origin:destination.origin,action:body.action,requestID:input.body.request_id,
    attemptID:input.body.attempt_id,result,createdAt:Date.now()};
  evidenceSet.add(evidence);return evidence;
}
export async function dispatchGenerationRewards(ctx:AppContext,body:Record<string,any>){
  validate(body);
  const native=await nativeGameCenterAccount(ctx.tx,ctx.actor.id);
  if(!native){
    const evidence=ctx.evidence;
    if(!evidence||!evidenceSet.has(evidence)||evidence.actor!==ctx.actor.id||evidence.action!==body.action||evidence.requestID!==body.request_id
      ||evidence.attemptID!==body.attempt_id||Date.now()-evidence.createdAt>60_000)throw new AppServiceError('reward_verification_required','A verified reward status is required.',401);
    const [link]=await ctx.tx`select legacy_user_id,source_origin,state from app_private.legacy_links where user_id=${ctx.actor.id} for share`;
    if(link?.state!=='active'||link.legacy_user_id!==evidence.legacyID||link.source_origin!==evidence.origin)throw new AppServiceError('legacy_owner_mismatch','Account ownership changed.',409);
    return evidence.result;
  }
  if(native.state!=='ready')throw new AppServiceError('account_unavailable','This account is unavailable.',403);
  await lockGenerationQuota(ctx.tx,ctx.actor.id);
  const status=await nativeRewardStatus(ctx.tx,ctx.actor.id,ctx.config);
  if(body.action==='status')return status;
  if(body.action==='claim_status'){
    const [attempt]=await ctx.tx`select state,expires_at from game_center_private.generation_reward_attempts where user_id=${ctx.actor.id} and attempt_id=${body.attempt_id}`;
    if(!attempt)throw new AppServiceError('reward_attempt_not_found','This reward attempt was not found.',404);
    // Stop UI polling after a delivery grace period; keep the issued attempt so
    // a delayed, valid signed event can still credit the general balance later.
    return {...status,state:attempt.state==='earned'?'earned':new Date(attempt.expires_at).getTime()+300_000<=ctx.now.getTime()?'expired':'pending'};
  }
  const requestID=requireUUID(body.request_id,'request_id');
  const [existing]=await ctx.tx`select * from game_center_private.generation_reward_attempts where user_id=${ctx.actor.id} and attempt_id=${requestID}`;
  if(!existing&&(status.unlimited||(status.free_remaining||0)>0||status.bonus_credits>0))
    throw new AppServiceError('reward_not_needed','A generation is already available. Refresh your allowance to continue.',409);
  if(!rewardedGenerationEnabled(ctx.config)||!status.ad_available)throw new AppServiceError('reward_unavailable','A rewarded ad is not available right now.',409);
  const attempt=existing||{attempt_id:requestID,custom_data:requestID+'.native.'+randomToken(),ad_unit_id:rewardedAdUnit(ctx.config)!};
  if(!existing)await ctx.tx`insert into game_center_private.generation_reward_attempts(user_id,attempt_id,custom_data,ad_unit_id)
    values(${ctx.actor.id},${attempt.attempt_id},${attempt.custom_data},${attempt.ad_unit_id})`;
  return {...status,attempt_id:attempt.attempt_id,custom_data:attempt.custom_data,ad_unit_id:attempt.ad_unit_id,user_id:ctx.actor.id,ssv_user_id:ctx.actor.id};
}
/** No user SDK callback reaches this credit path. The signed Google event and
 * issued user/token/unit/reward must all match in one locked transaction. */
export function createGenerationRewardSSVHandler(db:any,fetcher:typeof fetch=fetch){
  return async(request:Request)=>{
    try{
      if(request.method!=='GET')return Response.json({code:'method_not_allowed'},{status:405});
      const event=await verifyAdMobCallback(request.url,fetcher);
      const userID=requireUUID(event.userID,'user_id');
      const attemptID=requireUUID(event.customData.split('.')[0],'attempt_id');
      await db.begin(async(tx:any)=>{
        await accountGate(tx,userID);
        if((await nativeGameCenterAccount(tx,userID))?.state!=='ready')throw new AppServiceError('account_unavailable','This account is unavailable.',403);
        await lockGenerationQuota(tx,userID);
        const [attempt]=await tx`select * from game_center_private.generation_reward_attempts where user_id=${userID} and attempt_id=${attemptID} for update`;
        const unit=attempt?.ad_unit_id;
        const timestamp=event.timestamp;
        if(!attempt||attempt.custom_data!==event.customData||!(event.adUnit===unit||event.adUnit===unit?.split('/')[1])||event.rewardAmount!==1||event.rewardItem!=='generation'
          ||timestamp<new Date(attempt.created_at).getTime()-60_000||timestamp>new Date(attempt.expires_at).getTime()||timestamp>Date.now()+60_000)
          throw new AppServiceError('invalid_reward_claim','The reward claim did not match its issued attempt.',400);
        if(attempt.state==='earned'){
          if(attempt.transaction_id!==event.transactionID)throw new AppServiceError('reward_already_earned','This attempt already earned its reward.',409);
          return;
        }
        const duplicate=await tx`select 1 from game_center_private.generation_reward_attempts where transaction_id=${event.transactionID}`;
        if(duplicate.length)throw new AppServiceError('reward_transaction_reused','This reward event has already been used.',409);
        await tx`update game_center_private.generation_reward_attempts set state='earned',transaction_id=${event.transactionID},reward_at=${new Date(timestamp)}
          where user_id=${userID} and attempt_id=${attemptID} and state='pending'`;
      });
      return Response.json({received:true});
    }catch(error){
      const expected=error instanceof AppServiceError||error instanceof AdMobVerificationError;
      return Response.json({code:expected?error.code:'reward_callback_unavailable'},{status:expected?error.status:503});
    }
  };
}

import {AppServiceError} from './contracts.ts';
import {nativeGameCenterHasMembership} from './native-game-center.ts';

export type RewardConfig=Record<string,string|undefined>;
export const REWARDED_AI_DAILY_LIMIT=3;
export const rewardedGenerationEnabled=(config:RewardConfig)=>config.SPYCLASH_REWARDED_GENERATION_ENABLED==='true';
/** Pass only the authenticated, server-owned account ID. This test capability
 * never enables the generation quota or changes membership benefits. */
export function isGenerationRewardTester(config:RewardConfig,userID:string):boolean {
  return Boolean(userID)&&Boolean(config.SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS?.split(',').some(id=>id.trim()===userID));
}
export function rewardedAdUnit(config:RewardConfig):string|null {
  const unit=config.ADMOB_REWARDED_AD_UNIT_ID?.trim()||'';
  // Google's demo units cannot deliver SSV to our own backend. Never pretend
  // their local SDK callback has earned a server credit.
  return /^ca-app-pub-\d{16}\/\d{10}$/.test(unit)&&!unit.startsWith('ca-app-pub-3940256099942544/')?unit:null;
}
export async function lockGenerationQuota(tx:any,userID:string){
  await tx`select pg_advisory_xact_lock(hashtextextended(${userID+':native-ai-quota'},0))`;
}
export async function nativeRewardStatus(tx:any,userID:string,config:RewardConfig){
  const unlimited=await nativeGameCenterHasMembership(tx,userID);
  const [{today,resets_at}]=await tx`select (clock_timestamp() at time zone 'UTC')::date::text as today,
    (((clock_timestamp() at time zone 'UTC')::date+1)::timestamp at time zone 'UTC') as resets_at`;
  const enabled=rewardedGenerationEnabled(config);
  if(!enabled){
    const tester=isGenerationRewardTester(config,userID);
    const [{credits}]=tester?await tx`select count(*)::int as credits from game_center_private.generation_reward_attempts
      where user_id=${userID} and state='earned' and consumed_request_id is null`:[{credits:0}];
    return {enabled:false,unlimited,daily_limit:REWARDED_AI_DAILY_LIMIT,free_remaining:null,bonus_credits:credits,
      resets_at:new Date(resets_at).toISOString(),ad_available:false,...(tester?{test_ad_available:Boolean(rewardedAdUnit(config))}:{})};
  }
  const [{used}]=await tx`select count(*)::int as used from game_center_private.generation_requests
    where user_id=${userID} and usage_date=${today} and charged and charge_source in ('legacy','free')`;
  const [{credits}]=await tx`select count(*)::int as credits from game_center_private.generation_reward_attempts
    where user_id=${userID} and state='earned' and consumed_request_id is null`;
  return {enabled:true,unlimited,daily_limit:REWARDED_AI_DAILY_LIMIT,free_remaining:unlimited?null:Math.max(0,REWARDED_AI_DAILY_LIMIT-used),
    bonus_credits:credits,resets_at:new Date(resets_at).toISOString(),ad_available:!unlimited&&Boolean(rewardedAdUnit(config))};
}
/** Caller holds account and quota lock, then the generation request lock. The
 * request row is committed in the same transaction as its bonus reservation. */
export async function reserveRewardGeneration(tx:any,userID:string,requestID:string,prior:any,config:RewardConfig){
  const status=await nativeRewardStatus(tx,userID,config);
  if(prior?.charged)return {source:prior.charge_source as string,status};
  if(status.unlimited)return {source:'unlimited',status};
  if((status.free_remaining||0)>0)return {source:'free',status};
  const [credit]=await tx`select attempt_id from game_center_private.generation_reward_attempts
    where user_id=${userID} and state='earned' and consumed_request_id is null order by created_at,attempt_id limit 1 for update`;
  if(!credit)throw new AppServiceError('ai_limit_reached','Your 3 free generations are used. Watch an optional ad for one more, or return after the daily reset.',429,false);
  await tx`update game_center_private.generation_reward_attempts set consumed_request_id=${requestID}
    where user_id=${userID} and attempt_id=${credit.attempt_id}`;
  return {source:'bonus',status};
}
/** Exactly once: only the owner of a charged request may refund its credit.
 * No callback can recreate deleted rows. Caller holds the request lock. */
export async function releaseRewardGeneration(tx:any,userID:string,requestID:string,row:any){
  if(!row?.charged||row.charge_source==='legacy')return;
  if(row.charge_source==='bonus')await tx`update game_center_private.generation_reward_attempts set consumed_request_id=null
    where user_id=${userID} and consumed_request_id=${requestID}`;
  await tx`update game_center_private.generation_requests set charged=false where user_id=${userID} and request_id=${requestID} and charged`;
}
export function generationRewardMetadata(status:Awaited<ReturnType<typeof nativeRewardStatus>>){
  return {ai_limit:status.unlimited?null:status.daily_limit,ai_remaining:status.unlimited?null:(status.free_remaining||0)+status.bonus_credits,
    ai_free_remaining:status.free_remaining,ai_bonus_credits:status.bonus_credits,ai_resets_at:status.resets_at,ai_unlimited:status.unlimited,
    ai_generations_today:status.unlimited?null:status.daily_limit-(status.free_remaining||0)};
}

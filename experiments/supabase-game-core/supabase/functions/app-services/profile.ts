import { AppServiceError, type AppContext, requireUUID } from './contracts.ts';
import { stableSpyID, isReservedManualSpyID, publicProfile } from './policies/community.ts';
import { safeCommunityAvatar, safeCommunityDisplayName } from './policies/community-safety.ts';
import { requiresPremiumProfileChange } from './policies/profile-membership.ts';
import { aggregateCompetitiveStats, aggregateCompetitiveRoleStats } from '../full-game-core/rules/competitive-stats.ts';

export const clean = (value: unknown): string => String(value ?? '').trim();
const languages = new Set(['en','ru','uk','es']);
const acquisitionSources = new Set(['chatgpt','app_store_search','web_search','social_media','friends_or_family','other']);
export function isAppAdmin(ctx: AppContext, profile?: any): boolean {
  // data.role is writable only by the private server/migration, never profile input.
  return profile?.data?.role === 'admin' || clean(ctx.config.APP_ADMIN_USER_IDS).split(',').map(clean).includes(ctx.actor.id);
}
export async function ensureProfile(ctx: AppContext): Promise<any> {
  const {tx,actor,now}=ctx;
  let [profile]=await tx`select * from app_private.profiles where user_id=${actor.id}`;
  if (!profile) {
    const data={full_name:safeCommunityDisplayName(actor.full_name || 'Operative'),display_name:safeCommunityDisplayName(actor.full_name || 'Operative'),avatar:'🕵️',language:'en',spy_card_theme:'field',spy_card_accent:'signal_red',spy_card_badge:'operative',radar_invite_policy:'ask',onboarding_completed:false,onboarding_version:0};
    await tx`insert into app_private.profiles(user_id,contact_email,data,created_at,updated_at) values(${actor.id},${actor.contactEmail},${tx.json(data)},${now},${now}) on conflict(user_id) do nothing`;
    [profile]=await tx`select * from app_private.profiles where user_id=${actor.id}`;
  }
  if(profile.state!=='active') throw new AppServiceError('account_unavailable','This account is unavailable.',410);
  if(!profile.spy_id) {
    // Serialize only allocation, including first-use races for the same actor.
    await tx`select pg_advisory_xact_lock(hashtextextended('app:spy-id-allocation',0))`;
    [profile]=await tx`select * from app_private.profiles where user_id=${actor.id}`;
    if(!profile.spy_id) {
      for(let attempt=0;attempt<256;attempt++) {
        const candidate=await stableSpyID(actor.id,attempt);
        if(isReservedManualSpyID(candidate)) continue;
        if((await tx`select 1 from app_private.profiles where spy_id=${candidate}`).length) continue;
        [profile]=await tx`update app_private.profiles set spy_id=${candidate},updated_at=${now} where user_id=${actor.id} returning *`;
        break;
      }
      if(!profile.spy_id) throw new AppServiceError('spy_id_unavailable','SPY ID allocation is unavailable.',503,true);
    }
  }
  return profile;
}
export async function activeProfile(ctx: AppContext,id: unknown): Promise<any> {
  const [row]=await ctx.tx`select * from app_private.profiles where user_id=${requireUUID(id,'user_id')} and state='active'`;
  if(!row) throw new AppServiceError('profile_not_found','Operative not found.',404);
  return row;
}
export async function signalUsers(ctx: AppContext,userIDs:string[]):Promise<void> {
  const ids=[...new Set(userIDs)].sort(); if(!ids.length) return;
  await ctx.tx`insert into public.app_user_signals(recipient_user_id,revision,updated_at) select user_id,1,${ctx.now} from app_private.profiles where user_id=any(${ids}::uuid[]) and state='active' on conflict(recipient_user_id) do update set revision=app_user_signals.revision+1,updated_at=excluded.updated_at`;
}
export async function signalProfile(ctx:AppContext,userID:string):Promise<void> {
  await ctx.tx`insert into public.app_profile_signals(recipient_user_id,profile_user_id,revision,updated_at)
    select p.user_id,${userID}::uuid,1,${ctx.now} from app_private.profiles p where p.state='active' and
    (p.user_id=${userID} or exists(select 1 from app_private.friendships f where f.status='accepted' and f.pair_low=least(p.user_id,${userID}::uuid) and f.pair_high=greatest(p.user_id,${userID}::uuid)) or exists(select 1 from app_private.profile_watchers w where w.viewer_id=p.user_id and w.profile_id=${userID} and w.last_seen_at>${new Date(ctx.now.getTime()-600000)}))
    and not exists(select 1 from app_private.friendships b where b.status='blocked' and b.pair_low=least(p.user_id,${userID}::uuid) and b.pair_high=greatest(p.user_id,${userID}::uuid))
    on conflict(recipient_user_id,profile_user_id) do update set revision=app_profile_signals.revision+1,updated_at=excluded.updated_at`;
}
export async function projectedProfiles(ctx:AppContext,profiles:any[]):Promise<any[]> {
  if(!profiles.length) return [];
  const ids=profiles.map(p=>p.user_id);
  const rows=await ctx.tx`select result from full_game_private.history where player_id=any(${ids}::uuid[])`;
  const records=rows.map((r:any)=>r.result);
  const stats=aggregateCompetitiveStats(records), roles=aggregateCompetitiveRoleStats(records);
  return profiles.map(p=>{
    const s=stats.get(p.user_id),r=roles.get(p.user_id);
    return publicProfile({...p.data,id:p.user_id,spy_id:p.spy_id,rating:s?.rating||0,games_played:s?.games||0,games_won:s?.wins||0,spy_games_played:r?.spyGames||0,spy_games_won:r?.spyWins||0,detective_games_played:r?.detectiveGames||0,detective_games_won:r?.detectiveWins||0});
  });
}
export async function ownProfile(ctx:AppContext,profile:any):Promise<any> {
  const [publicData]=await projectedProfiles(ctx,[profile]);
  const data=profile.data||{};
  return {...publicData,email:ctx.actor.email,contact_email:profile.contact_email,full_name:clean(data.full_name)||publicData.display_name,language:languages.has(data.language)?data.language:'en',role:isAppAdmin(ctx,profile)?'admin':'user',is_verified:true,onboarding_completed:data.onboarding_completed===true,onboarding_version:Number(data.onboarding_version)||0,onboarding_completed_at:data.onboarding_completed_at||null,acquisition_source:data.acquisition_source||null,radar_invite_policy:['ask','automatic','blocked'].includes(data.radar_invite_policy)?data.radar_invite_policy:'ask'};
}
async function hasMembership(ctx:AppContext):Promise<boolean> {
  const rows=await ctx.tx`select 1 from app_private.entitlements where user_id=${ctx.actor.id} and active and (expires_at is null or expires_at>${ctx.now}) union all select 1 from app_private.membership_grants where user_id=${ctx.actor.id} and active and (expires_at is null or expires_at>${ctx.now}) limit 1`;
  return rows.length>0;
}
function validatedLanguage(value:unknown):string {
  const v=clean(value); if(!languages.has(v)) throw new AppServiceError('invalid_language','Unsupported language.',422); return v;
}
function validatedAcquisition(value:unknown):string {
  const v=clean(value); if(!acquisitionSources.has(v)) throw new AppServiceError('invalid_acquisition_source','Invalid acquisition source.',422); return v;
}
export async function dispatchProfile(ctx:AppContext,body:any):Promise<any> {
  let profile=await ensureProfile(ctx);
  const action=clean(body.action);
  if(['current','get','me','current_user'].includes(action)) return await ownProfile(ctx,profile);
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'app:profile:'+ctx.actor.id},0))`;
  profile=await activeProfile(ctx,ctx.actor.id);
  const patch:any={};
  if(['update','update_profile'].includes(action)) {
    if(body.display_name!==undefined) patch.display_name=safeCommunityDisplayName(body.display_name);
    if(body.avatar!==undefined) patch.avatar=safeCommunityAvatar(body.avatar);
    if(body.spy_card_theme!==undefined) patch.spy_card_theme=['field','blacksite','dossier'].includes(clean(body.spy_card_theme))?clean(body.spy_card_theme):'field';
    if(body.spy_card_accent!==undefined) patch.spy_card_accent=['signal_red','clearance_amber','verified_green'].includes(clean(body.spy_card_accent))?clean(body.spy_card_accent):'signal_red';
    if(body.spy_card_badge!==undefined) patch.spy_card_badge=['operative','ghost','analyst','handler'].includes(clean(body.spy_card_badge))?clean(body.spy_card_badge):'operative';
    if(ctx.config.SPYCLASH_LIMITLESS_ENABLED==='true'&&requiresPremiumProfileChange(profile.data,{...profile.data,...patch})&&!await hasMembership(ctx)) throw new AppServiceError('limitless_required','This customization requires LIMITLESS.',403);
    if(body.language!==undefined) patch.language=validatedLanguage(body.language);
  } else if(['update_language','language'].includes(action)) patch.language=validatedLanguage(body.language);
  else if(['complete_onboarding','onboarding'].includes(action)) {
    patch.language=validatedLanguage(body.language);
    const version=Number(body.onboarding_version);
    if(!Number.isInteger(version)||version<1||version>100) throw new AppServiceError('invalid_onboarding_version','Invalid onboarding version.',422);
    patch.onboarding_completed=true; patch.onboarding_version=Math.max(version,Number(profile.data.onboarding_version)||0);
    patch.onboarding_completed_at=ctx.now.toISOString();
    if(body.acquisition_source!==undefined&&body.acquisition_source!==null) patch.acquisition_source=validatedAcquisition(body.acquisition_source);
  } else if(['save_acquisition_source','acquisition_source','acquisition'].includes(action)) patch.acquisition_source=validatedAcquisition(body.acquisition_source);
  else if(action==='set_radar_invite_policy') {
    const policy=clean(body.radar_invite_policy);
    if(!['ask','automatic','blocked'].includes(policy)) throw new AppServiceError('invalid_radar_invite_policy','Invalid Radar invite policy.',422);
    patch.radar_invite_policy=policy;
  } else throw new AppServiceError('unsupported_profile_action','Unsupported profile action.');
  const [updated]=await ctx.tx`update app_private.profiles set data=data||${ctx.tx.json(patch)},updated_at=${ctx.now} where user_id=${ctx.actor.id} and state='active' returning *`;
  if(!updated) throw new AppServiceError('account_unavailable','This account is unavailable.',410);
  await signalProfile(ctx,ctx.actor.id);
  return action==='set_radar_invite_policy'?{radar_invite_policy:patch.radar_invite_policy}:await ownProfile(ctx,updated);
}

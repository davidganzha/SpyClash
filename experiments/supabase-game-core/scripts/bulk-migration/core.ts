/** Operator-only migration, invoked offline or by the temporary sealed-job
 * migration worker. Never expose this core through the ordinary app APIs.
 * Exported source data establishes row ownership; it does NOT prove a person's
 * current authentication. Only legacy-session may create verified legacy_links.
 */
import { canonical, digest } from '../../supabase/functions/app-services/integration-crypto.ts';
import { safeCommunityAvatar, safeCommunityDisplayName } from '../../supabase/functions/app-services/policies/community-safety.ts';
import { stableSpyID, isReservedManualSpyID } from '../../supabase/functions/app-services/policies/community.ts';
import { aggregateCompetitiveStats, aggregateCompetitiveRoleStats, deduplicateCompetitiveHistory } from '../../supabase/functions/full-game-core/rules/competitive-stats.ts';

export type Row = Record<string, any>;
export type SourceSnapshot = {version:number;source:{origin:string;appID:string};capturedAt:string;verifiedAt?:string;entities:Record<string,Row[]>;digest:string;inventory?:Row[]};
export type CoreTarget = {profiles:Row[];links:Row[];reservations:Row[];imports:Row[];runs:Row[];packs:Row[];history:Row[];friendships:Row[];comments:Row[];authUsers:Row[];bulkRows:Row[];lifecycleJobs:Row[];mainAccountDeletions:Row[]};
export type Issue = {code:string;entity:string;source_id:string;detail?:string};
export type AccountPlan = Row & {legacy_user_id:string;user_id:string;identity_key:string;shadow_email:string;existing_link:boolean;needs_auth:boolean;reservation_new:boolean;profile_action:'insert'|'preserve'|'fill_spy_id';profile:Row};
export type CorePlan = {version:1;sourceKey:string;source:SourceSnapshot['source'];sourceDigest:string;capturedAt:string;baseline:CoreTarget;accounts:AccountPlan[];packs:Row[];history:Row[];friendships:Row[];comments:Row[];provenance:Row[];issues:Issue[];warnings:Issue[];dispositions:Row[];counts:Row;progress:Row[]};
const APP_ID='69a0e57fa939f578082f8091';
const clean=(v:any)=>String(v??'').trim();
const email=(v:any)=>clean(v).toLowerCase();
const emptyTarget=():CoreTarget=>({profiles:[],links:[],reservations:[],imports:[],runs:[],packs:[],history:[],friendships:[],comments:[],authUsers:[],bulkRows:[],lifecycleJobs:[],mainAccountDeletions:[]});
const validID=(v:any)=>typeof v==='string'&&v.trim()===v&&v.length>0&&v.length<=200;
const canonicalSort=(rows:Row[])=>rows.map(r=>canonical(r)).sort();
const same=(a:any,b:any)=>canonical(a)===canonical(b);
// Base44 emits UTC timestamps both with and without a trailing Z. A local
// operator in Europe/London must produce exactly the same times as UTC Edge.
const instant=(v:any,fallback:string)=>{
  if(typeof v!=='string')return fallback;
  const normalized=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$/.test(v)?v+'Z':v;
  return Number.isFinite(Date.parse(normalized))?new Date(normalized).toISOString():fallback;
};
const pair=(a:string,b:string)=>[a,b].sort().join(':');
const sourceIndex=(entity:string,id:string)=>entity+'\n'+id;
function fail(code:string):never {throw new Error(code);}

/** Exactly matches legacy-import.ts. Never substitute a new UUID namespace. */
export async function mappedUUID(sourceKey:string,entity:string,id:string):Promise<string> {
  const hex=await digest('spyclash-legacy-import-v1:'+sourceKey+':'+entity+':'+id);
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-5${hex.slice(13,16)}-a${hex.slice(17,20)}-${hex.slice(20,32)}`;
}
export async function legacyIdentityKey(source:SourceSnapshot['source'],legacyID:string) {
  return await digest(source.origin+'\n'+source.appID+'\n'+legacyID);
}
function profileData(identity:Row):Row {
  const data:Row={full_name:safeCommunityDisplayName(identity.full_name||identity.display_name||'Operative'),display_name:safeCommunityDisplayName(identity.display_name||identity.full_name||'Operative'),avatar:safeCommunityAvatar(identity.avatar||'🕵️')};
  for(const [key,allowed,fallback] of [
    ['language',['en','ru','uk','es'],'en'],['spy_card_theme',['field','blacksite','dossier'],'field'],
    ['spy_card_accent',['signal_red','clearance_amber','verified_green'],'signal_red'],['spy_card_badge',['operative','ghost','analyst','handler'],'operative'],
    ['radar_invite_policy',['ask','automatic','blocked'],'ask'],
  ] as Array<[string,string[],string]>)data[key]=allowed.includes(clean(identity[key]))?clean(identity[key]):fallback;
  data.onboarding_completed=identity.onboarding_completed===true;
  data.onboarding_version=Number.isInteger(identity.onboarding_version)&&identity.onboarding_version>=1?identity.onboarding_version:0;
  if(typeof identity.onboarding_completed_at==='string'&&Number.isFinite(Date.parse(identity.onboarding_completed_at)))data.onboarding_completed_at=identity.onboarding_completed_at;
  if(['chatgpt','app_store_search','web_search','social_media','friends_or_family','other'].includes(identity.acquisition_source))data.acquisition_source=identity.acquisition_source;
  return data;
}
function historyData(row:Row):Row {
  const data:Row={id:row.id};
  for(const key of ['player_user_id','match_id','result_key','created_date','room_code','match_type','role','word','category','winner','player_count','spy_count','won','ranked'])if(row[key]!==undefined)data[key]=row[key];
  return data;
}

/** Read only; caller may wrap in a repeatable-read transaction. Minimal Auth
 * projection excludes password hashes, factors, identities and credentials. */
export async function readCoreTarget(db:any):Promise<CoreTarget> {
  const result=emptyTarget();
  const tables:Record<string,string>={profiles:'app_private.profiles',links:'app_private.legacy_links',reservations:'app_private.legacy_session_accounts',imports:'app_private.legacy_import_rows',runs:'app_private.legacy_import_runs',packs:'full_game_private.word_packs',history:'full_game_private.history',friendships:'app_private.friendships',comments:'app_private.profile_comments'};
  // JSON projection preserves PostgreSQL microseconds and UTC offset exactly,
  // matching the administrative MCP snapshot instead of Date's millisecond cast.
  for(const [key,table] of Object.entries(tables))(result as any)[key]=(await db.unsafe('select to_jsonb(t) as value from '+table+' t')).map((r:Row)=>r.value);
  result.authUsers=await db`select id,email,role,raw_app_meta_data from auth.users`;
  const [exists]=await db`select to_regclass('app_private.bulk_migration_rows') is not null as present`;
  if(exists?.present)result.bulkRows=(await db`select to_jsonb(t) as value from app_private.bulk_migration_rows t`).map((r:Row)=>r.value);
  result.lifecycleJobs=(await db`select to_jsonb(t) as value from app_private.lifecycle_jobs t`).map((r:Row)=>r.value);
  const [hasDeletions]=await db`select to_regclass('app_private.main_account_deletions') is not null as present`;
  if(hasDeletions?.present)result.mainAccountDeletions=(await db`select to_jsonb(t) as value from app_private.main_account_deletions t`).map((r:Row)=>r.value);
  return JSON.parse(JSON.stringify(result));
}

/** Planning is side-effect free. Random shadow mailboxes are sealed in the plan;
 * retry the persisted plan instead of creating another candidate mailbox. */
export async function buildCorePlan(snapshot:SourceSnapshot,target:CoreTarget):Promise<CorePlan> {
  if(snapshot.version!==1||snapshot.source?.origin!=='https://spyclash.com'||snapshot.source?.appID!==APP_ID)fail('bulk_source_forbidden');
  if(!Number.isFinite(Date.parse(snapshot.capturedAt))||!snapshot.digest)fail('bulk_snapshot_invalid');
  for(const entity of ['User','WordPack','GameHistory','Friendship','ProfileComment'])if(!Array.isArray(snapshot.entities[entity]))fail('bulk_source_entity_missing:'+entity);
  target={...emptyTarget(),...target};
  const sourceKey=snapshot.source.origin+'/'+snapshot.source.appID;
  const p:CorePlan={version:1,sourceKey,source:snapshot.source,sourceDigest:snapshot.digest,capturedAt:snapshot.capturedAt,baseline:target,accounts:[],packs:[],history:[],friendships:[],comments:[],provenance:[],issues:[],warnings:[],dispositions:[],counts:{},progress:[]};
  const issue=(code:string,entity:string,source_id:string,detail?:string)=>p.issues.push({code,entity,source_id,...(detail?{detail}:{})});
  const warn=(code:string,entity:string,source_id:string,detail?:string)=>p.warnings.push({code,entity,source_id,...(detail?{detail}:{})});
  const disposition=(entity:string,source_id:string,action:string,target_id?:string,reason?:string)=>p.dispositions.push({entity,source_id,action,...(target_id?{target_id}:{}),...(reason?{reason}:{})});
  const entities:Record<string,Row[]>={};
  for(const [entity,rows] of Object.entries(snapshot.entities)) {
    entities[entity]=[];const seen=new Set<string>();
    for(const row of rows) {
      if(!row||!validID(row.id)){issue('invalid_source_id',entity,clean(row?.id));continue;}
      if(seen.has(row.id)){issue('duplicate_source_id',entity,row.id);continue;}
      seen.add(row.id);entities[entity].push(row);
    }
    entities[entity].sort((a,b)=>a.id.localeCompare(b.id));
  }
  const users=new Map(entities.User.map(r=>[r.id,r]));
  const byEmail=new Map<string,string[]>();
  for(const row of users.values())if(email(row.email))byEmail.set(email(row.email),[...(byEmail.get(email(row.email))||[]),row.id]);
  const profiles=new Map(target.profiles.map(r=>[r.user_id,r]));
  const reservations=new Map(target.reservations.map(r=>[r.legacy_user_id,r]));
  const links=new Map(target.links.map(r=>[r.legacy_user_id,r]));
  const auth=new Map(target.authUsers.map(r=>[r.id,r]));
  const imports=new Map(target.imports.filter(r=>r.source_key===sourceKey).map(r=>[sourceIndex(r.entity,r.source_id),r]));
  const ledger=new Map(target.bulkRows.filter(r=>r.source_key===sourceKey).map(r=>[sourceIndex(r.entity,r.source_id),r]));
  const spies=new Map(target.profiles.filter(r=>r.spy_id).map(r=>[r.spy_id,r.user_id]));
  // Reserve ALL source SPY IDs before generating an ID for a source lacking one.
  const sourceSpies=new Map<string,string>();
  for(const row of users.values())if(clean(row.spy_id)) {
    if(!/^[0-9]{3}-[0-9]{3}$/.test(row.spy_id)){issue('invalid_source_spy_id','User',row.id);continue;}
    if(sourceSpies.has(row.spy_id))issue('duplicate_source_spy_id','User',row.id);
    sourceSpies.set(row.spy_id,row.id);
  }
  for(const row of users.values()) {
    const link=links.get(row.id),reservation=reservations.get(row.id),identity_key=await legacyIdentityKey(snapshot.source,row.id);
    const user_id=reservation?.user_id||link?.user_id||await mappedUUID(sourceKey,'User',row.id);
    const prior=profiles.get(user_id),priorAuth=auth.get(user_id);
    const lifecycleKey='billing:'+(await digest('spyclash-billing-lifecycle:'+row.id)).slice(0,40);
    if((snapshot.entities.BillingIdentityLifecycle||[]).some(r=>r.subject_key===lifecycleKey&&r.state!=='active'))issue('source_account_deleting','User',row.id);
    if(target.lifecycleJobs.some(r=>r.user_id===user_id)||target.mainAccountDeletions.some(r=>r.user_id===user_id))issue('target_account_deleting','User',row.id);
    if(link&&(link.state!=='active'||link.source_origin!==snapshot.source.origin))issue('legacy_link_unavailable','User',row.id);
    if(reservation&&(reservation.identity_key!==identity_key||reservation.source_origin!==snapshot.source.origin||reservation.source_app_id!==snapshot.source.appID||(link&&link.user_id!==reservation.user_id)))issue('reservation_identity_conflict','User',row.id);
    if(reservation?.lease_until&&Date.parse(reservation.lease_until)>Date.parse(snapshot.capturedAt))issue('legacy_signin_in_progress','User',row.id);
    if(prior&&prior.state!=='active')issue('account_tombstone','User',row.id);
    if(!reservation&&!link&&(prior||priorAuth))issue('unrelated_target_uuid_collision','User',row.id);
    if(target.links.some(r=>r.user_id===user_id&&r.legacy_user_id!==row.id)||target.reservations.some(r=>r.user_id===user_id&&r.legacy_user_id!==row.id))issue('target_owner_conflict','User',row.id);
    if(p.accounts.some(r=>r.user_id===user_id))issue('duplicate_target_owner','User',row.id);
    const shadow_email=reservation?.shadow_email||crypto.randomUUID().replaceAll('-','')+'@accounts.spyclash.invalid';
    const existing_link=!!link;
    if(priorAuth&&(priorAuth.role!=='authenticated'||(!existing_link&&(priorAuth.email!==shadow_email||priorAuth.raw_app_meta_data?.legacy_provider!=='base44'||priorAuth.raw_app_meta_data?.legacy_identity_key!==identity_key))))issue('auth_identity_conflict','User',row.id);
    if(!priorAuth&&(existing_link||reservation?.state==='ready'))issue('auth_tombstone','User',row.id);
    let spy_id=clean(row.spy_id)||prior?.spy_id||null;
    if(prior?.spy_id&&row.spy_id&&prior.spy_id!==row.spy_id)issue('existing_spy_id_differs','User',row.id);
    if(spy_id&&spies.has(spy_id)&&spies.get(spy_id)!==user_id)issue('target_spy_id_collision','User',row.id);
    if(!spy_id)for(let attempt=0;attempt<256;attempt++) {
      const candidate=await stableSpyID(user_id,attempt);
      if(!spies.has(candidate)&&!sourceSpies.has(candidate)&&!isReservedManualSpyID(candidate)){spy_id=candidate;break;}
    }
    if(!spy_id)issue('spy_id_allocation_exhausted','User',row.id);else spies.set(spy_id,user_id);
    const profile_action=!prior?'insert':!prior.spy_id?'fill_spy_id':'preserve';
    const profile=prior?{...prior,spy_id:prior.spy_id||spy_id}:{user_id,state:'active',contact_email:clean(row.email),spy_id,data:profileData(row),created_at:instant(row.created_date,snapshot.capturedAt),updated_at:instant(row.updated_date,snapshot.capturedAt)};
    if(prior&&!same(prior.data,profileData(row)))warn('existing_profile_preserved','User',row.id);
    const account:AccountPlan={legacy_user_id:row.id,user_id,identity_key,shadow_email,existing_link,needs_auth:!priorAuth,reservation_new:!reservation,profile_action,profile,source_digest:await digest(canonical(row))};
    p.accounts.push(account);
    disposition('User',row.id,profile_action==='preserve'?'preserve_current':'import',user_id);
    const previous=imports.get(sourceIndex('User',row.id));
    if(previous&&previous.user_id!==user_id)issue('provenance_owner_conflict','User',row.id);
    p.provenance.push({entity:'User',source_id:row.id,source_digest:account.source_digest,target_id:user_id,user_id,legacy:!previous,disposition:profile_action});
  }
  const accounts=new Map(p.accounts.map(a=>[a.legacy_user_id,a]));
  function owner(row:Row,entity:string,idKey:string,emailKey:string):AccountPlan|undefined {
    const stable=clean(row[idKey]);
    if(stable) {
      const found=accounts.get(stable);
      if(!found){warn('orphaned_stable_owner_archived',entity,row.id);disposition(entity,row.id,'archive_only',undefined,'owner_not_in_source_users');}
      return found;
    }
    const candidates=byEmail.get(email(row[emailKey]))||[];
    if(candidates.length===1)return accounts.get(candidates[0]);
    if(candidates.length>1)issue('ambiguous_legacy_email_owner',entity,row.id);
    else {warn('orphaned_email_owner_archived',entity,row.id);disposition(entity,row.id,'archive_only',undefined,'owner_not_in_source_users');}
    return undefined;
  }
  async function provenance(entity:string,row:Row,target_id:string,user_id:string,legacy:boolean,action:string) {
    const hash=await digest(canonical(row));
    const previous=ledger.get(sourceIndex(entity,row.id));
    if(previous&&previous.source_digest!==hash)issue('source_changed_after_bulk_import',entity,row.id);
    p.provenance.push({entity,source_id:row.id,source_digest:hash,target_id,user_id,legacy,disposition:action});
  }
  for(const row of entities.WordPack) {
    const account=owner(row,'WordPack','owner_user_id','owner_email');if(!account)continue;
    const id=await mappedUUID(sourceKey,'WordPack',row.id),previous=imports.get(sourceIndex('WordPack',row.id));
    if(previous) {
      if(previous.user_id!==account.user_id||previous.target_id!==id)issue('provenance_owner_conflict','WordPack',row.id);
      disposition('WordPack',row.id,'preserve_current',id,'already_imported_or_deleted');await provenance('WordPack',row,id,account.user_id,false,'preserve_current');continue;
    }
    if(typeof row.name!=='string'||!row.name.trim()||row.name.length>200||typeof row.category!=='string'||row.category.length>200||!Array.isArray(row.words)||!row.words.length||row.words.length>10000||row.words.some((w:any)=>typeof w!=='string'||!w.trim()||w.length>200)){issue('invalid_word_pack','WordPack',row.id);continue;}
    if(target.packs.some(r=>r.id===id)){issue('untracked_pack_collision','WordPack',row.id);continue;}
    p.packs.push({id,owner_id:account.user_id,pack:{id,name:row.name,category:row.category,words:row.words,owner_email:account.user_id+'@example.test',is_public:false},created_at:instant(row.created_date,snapshot.capturedAt),updated_at:instant(row.updated_date,snapshot.capturedAt)});
    disposition('WordPack',row.id,'import',id);await provenance('WordPack',row,id,account.user_id,true,'import');
  }
  const ownedHistory=new Map<string,Row[]>();
  for(const row of entities.GameHistory){const account=owner(row,'GameHistory','player_user_id','player_email');if(account)ownedHistory.set(account.user_id,[...(ownedHistory.get(account.user_id)||[]),row]);}
  const existingHistory=new Map(target.history.map(r=>[r.match_id+':'+r.player_id,r]));
  const plannedHistory=new Map<string,Row>();
  for(const account of p.accounts) {
    const rows=ownedHistory.get(account.user_id)||[],selected=deduplicateCompetitiveHistory(rows.map(historyData)) as Row[];
    const selectedIDs=new Set(selected.map(r=>r.id));
    for(const row of rows)if(!selectedIDs.has(row.id))disposition('GameHistory',row.id,'archive_duplicate',undefined,'same_competitive_result');
    for(const row of selected) {
      const match_id=await mappedUUID(sourceKey,'Match',clean(row.match_id)||'history:'+row.id),previous=imports.get(sourceIndex('GameHistory',row.id));
      const stable=clean(row.player_user_id)===account.legacy_user_id;
      const result:Row={match_id,result_key:match_id+':'+account.user_id,player_user_id:stable?account.user_id:'',player_email:account.user_id+'@example.test'};
      for(const key of ['room_code','match_type','role','word','category','winner','player_count','spy_count','won','ranked'])if(row[key]!==undefined)result[key]=row[key];
      if(!stable)result.ranked=false;
      result.created_date=instant(row.created_date,snapshot.capturedAt);
      const entry={match_id,player_id:account.user_id,room_id:null,result,created_at:result.created_date},key=match_id+':'+account.user_id;
      const existing=existingHistory.get(key)||plannedHistory.get(key);
      if(previous) {
        if(previous.user_id!==account.user_id||previous.target_id!==match_id)issue('provenance_owner_conflict','GameHistory',row.id);
        if(!existing)issue('imported_history_missing','GameHistory',row.id);
        else if(!same(existing.result,result))issue('imported_history_changed','GameHistory',row.id);
        disposition('GameHistory',row.id,'preserve_current',match_id,'already_imported');await provenance('GameHistory',row,match_id,account.user_id,false,'preserve_current');continue;
      }
      if(existing) {
        if(!same(existing.result,result))issue('history_result_conflict','GameHistory',row.id);
        disposition('GameHistory',row.id,'preserve_current',match_id,'logical_match_already_present');
      } else {p.history.push(entry);plannedHistory.set(key,entry);disposition('GameHistory',row.id,'import',match_id);}
      // Existing importer hashes its reduced history projection, not provider metadata.
      await provenance('GameHistory',row,match_id,account.user_id,true,existing?'preserve_current':'import');
    }
    const stats=aggregateCompetitiveStats(selected).get(account.legacy_user_id)||{rating:0,games:0,wins:0,losses:0};
    const source=users.get(account.legacy_user_id)!;
    const mirror={rating:Number(source.rating)||0,games:Number(source.games_played)||0,wins:Number(source.games_won)||0};
    if(mirror.rating!==stats.rating||mirror.games!==stats.games||mirror.wins!==stats.wins)warn('source_stats_mirror_differs_from_history','User',account.legacy_user_id);
    const priorResults=target.history.filter(r=>r.player_id===account.user_id).map(r=>r.result);
    const combinedResults=[...priorResults,...p.history.filter(r=>r.player_id===account.user_id).map(r=>r.result)];
    p.progress.push({legacy_user_id:account.legacy_user_id,user_id:account.user_id,source_history:rows.length,canonical_history:selected.length,source_competitive:stats,source_mirror:mirror,
      source_roles:aggregateCompetitiveRoleStats(selected).get(account.legacy_user_id)||{spyGames:0,spyWins:0,detectiveGames:0,detectiveWins:0},
      existing_target:aggregateCompetitiveStats(priorResults).get(account.user_id)||{rating:0,games:0,wins:0,losses:0},
      combined_target:aggregateCompetitiveStats(combinedResults).get(account.user_id)||{rating:0,games:0,wins:0,losses:0},
      combined_roles:aggregateCompetitiveRoleStats(combinedResults).get(account.user_id)||{spyGames:0,spyWins:0,detectiveGames:0,detectiveWins:0},
      source_history_complete:!p.issues.some(i=>i.entity==='GameHistory'&&selectedIDs.has(i.source_id))});
  }
  const sourcePairs=new Set<string>();
  for(const row of entities.Friendship) {
    const a=accounts.get(row.requester_id),b=accounts.get(row.addressee_id);
    if(!a||!b){warn('orphaned_social_row_archived','Friendship',row.id);disposition('Friendship',row.id,'archive_only',undefined,'endpoint_not_in_source_users');continue;}
    if(a===b||!['pending','accepted','declined','blocked'].includes(row.status)||(row.status==='blocked'&&![row.requester_id,row.addressee_id].includes(row.blocked_by_id))||(row.status!=='blocked'&&clean(row.blocked_by_id))){issue('invalid_friendship','Friendship',row.id);continue;}
    const key=pair(a.user_id,b.user_id);if(sourcePairs.has(key)){issue('duplicate_source_friendship_pair','Friendship',row.id);continue;}sourcePairs.add(key);
    const prior=ledger.get(sourceIndex('Friendship',row.id));
    const id=prior?.target_id||await mappedUUID(sourceKey,'Friendship',row.id);
    if(prior){disposition('Friendship',row.id,'preserve_current',id,'already_imported_or_deleted');await provenance('Friendship',row,id,a.user_id,false,'preserve_current');continue;}
    const blocked_by_id=row.status==='blocked'?accounts.get(row.blocked_by_id)!.user_id:null;
    const current=target.friendships.find(r=>pair(r.requester_id,r.addressee_id)===key);
    if(current) {
      if(current.status!==row.status||current.blocked_by_id!==blocked_by_id||(row.status==='pending'&&current.requester_id!==a.user_id))issue('existing_friendship_conflict','Friendship',row.id);
      disposition('Friendship',row.id,'preserve_current',current.id);await provenance('Friendship',row,current.id,a.user_id,false,'preserve_current');continue;
    }
    if(target.friendships.some(r=>r.id===id)){issue('untracked_friendship_collision','Friendship',row.id);continue;}
    p.friendships.push({id,requester_id:a.user_id,addressee_id:b.user_id,status:row.status,blocked_by_id,request_event_id:row.request_event_id?await mappedUUID(sourceKey,'FriendRequestEvent',row.request_event_id):null,created_at:instant(row.created_at||row.created_date,snapshot.capturedAt),updated_at:instant(row.updated_at||row.updated_date,snapshot.capturedAt)});
    disposition('Friendship',row.id,'import',id);await provenance('Friendship',row,id,a.user_id,false,'import');
  }
  for(const row of entities.ProfileComment) {
    const a=accounts.get(row.target_user_id),b=accounts.get(row.author_user_id);
    if(!a||!b){warn('orphaned_social_row_archived','ProfileComment',row.id);disposition('ProfileComment',row.id,'archive_only',undefined,'endpoint_not_in_source_users');continue;}
    if(a===b||typeof row.body!=='string'||!row.body.length||[...row.body].length>280){issue('invalid_profile_comment','ProfileComment',row.id);continue;}
    const prior=ledger.get(sourceIndex('ProfileComment',row.id)),id=prior?.target_id||await mappedUUID(sourceKey,'ProfileComment',row.id);
    if(prior){disposition('ProfileComment',row.id,'preserve_current',id,'already_imported_or_deleted');await provenance('ProfileComment',row,id,b.user_id,false,'preserve_current');continue;}
    if(target.comments.some(r=>r.id===id)){issue('untracked_comment_collision','ProfileComment',row.id);continue;}
    p.comments.push({id,target_user_id:a.user_id,author_user_id:b.user_id,body:row.body,created_at:instant(row.created_at||row.created_date,snapshot.capturedAt),updated_at:instant(row.updated_at||row.updated_date,snapshot.capturedAt)});
    disposition('ProfileComment',row.id,'import',id);await provenance('ProfileComment',row,id,b.user_id,false,'import');
  }
  p.counts={source_users:users.size,accounts_to_provision:p.accounts.filter(a=>a.needs_auth).length,profiles_to_insert:p.accounts.filter(a=>a.profile_action==='insert').length,profiles_preserved:p.accounts.filter(a=>a.profile_action==='preserve').length,packs_to_insert:p.packs.length,history_to_insert:p.history.length,friendships_to_insert:p.friendships.length,comments_to_insert:p.comments.length,issues:p.issues.length,archive_only:p.dispositions.filter(d=>d.action==='archive_only').length};
  return p;
}

export function assertPlanReady(plan:CorePlan) {if(plan.issues.length)fail('bulk_plan_has_conflicts:'+plan.issues.map(i=>i.code).join(','));}

/** Verified login refreshes these audit timestamps without changing data. The
 * bulk importer never writes existing profiles.updated_at or links.verified_at,
 * so newer values survive untouched. Every identity, content and ownership field
 * remains an exact optimistic-concurrency guard. */
export function assertCoreTargetUnchanged(plan:CorePlan,current:CoreTarget) {
  for(const field of ['profiles','links','imports','runs','packs','history','friendships','comments','bulkRows','lifecycleJobs','mainAccountDeletions'] as const) {
    const comparable=(rows:Row[])=>canonicalSort(rows.map(row=>{
      const value={...row};
      if(field==='profiles')delete value.updated_at;
      if(field==='links')delete value.verified_at;
      return value;
    }));
    if(!same(comparable(plan.baseline[field]),comparable(current[field])))fail('bulk_target_changed:'+field);
  }
}

/** First transaction: persist immutable UUID/mailbox reservations BEFORE the
 * runner invokes Auth Admin createUser. A crash leaves resumable reservations. */
export async function reserveCoreAccounts(tx:any,plan:CorePlan) {
  assertPlanReady(plan);
  for(const a of [...plan.accounts].sort((x,y)=>x.user_id.localeCompare(y.user_id))) {
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+a.user_id},0))`;
    await tx`select pg_advisory_xact_lock(hashtextextended(${'legacy:'+a.legacy_user_id},0))`;
    const [profile]=await tx`select state from app_private.profiles where user_id=${a.user_id}`;
    if(profile&&profile.state!=='active')fail('bulk_account_unavailable');
    if((await tx`select 1 from app_private.lifecycle_jobs where user_id=${a.user_id}`).length)fail('bulk_account_deleting');
    const [hasDeletions]=await tx`select to_regclass('app_private.main_account_deletions') is not null as present`;
    if(hasDeletions?.present&&(await tx`select 1 from app_private.main_account_deletions where user_id=${a.user_id}`).length)fail('bulk_account_deleting');
    const [link]=await tx`select * from app_private.legacy_links where legacy_user_id=${a.legacy_user_id} for update`;
    if(!!link!==a.existing_link||(link&&(link.user_id!==a.user_id||link.state!=='active'||link.source_origin!==plan.source.origin)))fail('bulk_identity_changed');
    const [existing]=await tx`select * from app_private.legacy_session_accounts where legacy_user_id=${a.legacy_user_id} for update`;
    if(existing) {
      if(existing.user_id!==a.user_id||existing.identity_key!==a.identity_key||existing.shadow_email!==a.shadow_email||existing.source_origin!==plan.source.origin||existing.source_app_id!==plan.source.appID)fail('bulk_reservation_changed');
      if(existing.lease_until&&new Date(existing.lease_until).getTime()>Date.now())fail('bulk_legacy_signin_in_progress');
    } else {
      if(!a.reservation_new)fail('bulk_reservation_disappeared');
      await tx`insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email,existing_link) values(${a.identity_key},${a.legacy_user_id},${plan.source.origin},${plan.source.appID},${a.user_id},${a.shadow_email},${a.existing_link})`;
    }
  }
}

/** Validate an Auth response without accepting matching contact email as proof. */
export function assertProvisionedAccount(account:AccountPlan,user:Row) {
  if(user?.id!==account.user_id||user?.role!=='authenticated')fail('bulk_auth_identity_mismatch');
  if(!account.existing_link&&(user.email!==account.shadow_email||user.app_metadata?.legacy_provider!=='base44'||user.app_metadata?.legacy_identity_key!==account.identity_key))fail('bulk_auth_ownership_mismatch');
}

/** The caller owns one transaction for archive + all functional writes. */
export async function applyCorePlan(tx:any,plan:CorePlan):Promise<Row> {
  assertPlanReady(plan);
  for(const a of [...plan.accounts].sort((x,y)=>x.user_id.localeCompare(y.user_id)))await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+a.user_id},0))`;
  await tx.unsafe('lock table app_private.profiles, app_private.legacy_links, app_private.legacy_session_accounts, app_private.legacy_import_rows, app_private.legacy_import_runs, app_private.legacy_import_history_stage, app_private.lifecycle_jobs, full_game_private.word_packs, full_game_private.history, app_private.friendships, app_private.profile_comments, app_private.bulk_migration_rows in share row exclusive mode');
  const [hasDeletions]=await tx`select to_regclass('app_private.main_account_deletions') is not null as present`;
  if(hasDeletions?.present)await tx.unsafe('lock table app_private.main_account_deletions in share row exclusive mode');
  const current=await readCoreTarget(tx);
  assertCoreTargetUnchanged(plan,current);
  for(const a of plan.accounts) {
    const row=current.reservations.find(r=>r.legacy_user_id===a.legacy_user_id);
    if(!row||row.user_id!==a.user_id||row.identity_key!==a.identity_key||row.shadow_email!==a.shadow_email||row.source_origin!==plan.source.origin||row.source_app_id!==plan.source.appID)fail('bulk_reservation_missing');
    if(row.lease_until&&Date.parse(row.lease_until)>Date.now())fail('bulk_legacy_signin_in_progress');
    const user=current.authUsers.find(r=>r.id===a.user_id);assertProvisionedAccount(a,{...user,app_metadata:user?.raw_app_meta_data});
  }
  for(const a of plan.accounts) {
    const r=a.profile;
    if(a.profile_action==='insert')await tx`insert into app_private.profiles(user_id,state,contact_email,spy_id,data,created_at,updated_at) values(${r.user_id},'active',${r.contact_email},${r.spy_id},${tx.json(r.data)},${r.created_at},${r.updated_at})`;
    else if(a.profile_action==='fill_spy_id')await tx`update app_private.profiles set spy_id=${r.spy_id} where user_id=${a.user_id} and spy_id is null`;
  }
  for(const r of plan.packs)await tx`insert into full_game_private.word_packs(id,owner_id,pack,created_at,updated_at) values(${r.id},${r.owner_id},${tx.json(r.pack)},${r.created_at},${r.updated_at})`;
  for(const r of plan.history)await tx`insert into full_game_private.history(match_id,player_id,room_id,result,created_at) values(${r.match_id},${r.player_id},null,${tx.json(r.result)},${r.created_at})`;
  for(const r of plan.friendships)await tx`insert into app_private.friendships(id,requester_id,addressee_id,status,blocked_by_id,request_event_id,created_at,updated_at) values(${r.id},${r.requester_id},${r.addressee_id},${r.status},${r.blocked_by_id},${r.request_event_id},${r.created_at},${r.updated_at})`;
  for(const r of plan.comments)await tx`insert into app_private.profile_comments(id,target_user_id,author_user_id,body,created_at,updated_at) values(${r.id},${r.target_user_id},${r.author_user_id},${r.body},${r.created_at},${r.updated_at})`;
  for(const r of plan.provenance) {
    if(r.legacy)await tx`insert into app_private.legacy_import_rows(user_id,source_key,entity,source_id,source_digest,target_id) values(${r.user_id},${plan.sourceKey},${r.entity},${r.source_id},${r.source_digest},${r.target_id})`;
    await tx`insert into app_private.bulk_migration_rows(source_key,entity,source_id,source_digest,target_id,disposition) values(${plan.sourceKey},${r.entity},${r.source_id},${r.source_digest},${r.target_id},${r.disposition}) on conflict(source_key,entity,source_id) do nothing`;
  }
  for(const a of plan.accounts) {
    await tx`insert into app_private.legacy_import_runs(user_id,source_key,legacy_user_id,profile_applied,status,history_cursor,social_status) values(${a.user_id},${plan.sourceKey},${a.legacy_user_id},true,'complete','{"phase":"done","skip":0}'::jsonb,'bulk_applied') on conflict(user_id,source_key) do update set profile_applied=true,status='complete',history_cursor=excluded.history_cursor,social_status='bulk_applied',last_import_at=clock_timestamp()`;
    await tx`delete from app_private.legacy_import_history_stage where user_id=${a.user_id} and source_key=${plan.sourceKey}`;
    await tx`update app_private.legacy_session_accounts set import_completed=true,updated_at=clock_timestamp() where identity_key=${a.identity_key}`;
  }
  // Wake current clients without sending push notifications or new invitations.
  const ids=plan.accounts.map(a=>a.user_id);
  if(ids.length)await tx`insert into public.app_user_signals(recipient_user_id,revision,updated_at) select user_id,1,clock_timestamp() from app_private.profiles where user_id=any(${ids}::uuid[]) and state='active' on conflict(recipient_user_id) do update set revision=app_user_signals.revision+1,updated_at=excluded.updated_at`;
  return plan.counts;
}

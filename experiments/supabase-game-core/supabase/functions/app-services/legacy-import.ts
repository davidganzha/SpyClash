import { AppServiceError, type AppContext } from './contracts.ts';
import { canonical, digest } from './integration-crypto.ts';
import { ensureProfile, clean, isAppAdmin } from './profile.ts';
import { normalizeSpyID } from './policies/community.ts';
import { safeCommunityAvatar, safeCommunityDisplayName } from './policies/community-safety.ts';
import { deduplicateCompetitiveHistory } from '../full-game-core/rules/competitive-stats.ts';

type Row = Record<string, any>;
type Source = {origin:string,appID:string,accessToken:string,expectedLegacyID:string};
type Cursor={phase:'stable'|'email'|'done',skip:number,anchor?:string};
type Snapshot = {sourceKey:string,origin:string,legacyID:string,identity:Row,packs:Row[],history:Row[],capturedAt:number,previousCursor:Cursor,nextCursor:Cursor,alreadyComplete:boolean};
const verified = new WeakSet<object>();
const APP_ID = '69a0e57fa939f578082f8091';
const ORIGINS = new Set(['https://spyclash.com','https://base44.app']);
const MAX_HISTORY = 5000, PAGE = 100, PAGES_PER_EXCHANGE=4;
const failure = (code:string,message:string,status=422) => new AppServiceError(code,message,status,status>=500);
function record(value:any):Row {
  if(!value || Array.isArray(value) || typeof value!=='object') throw failure('legacy_import_invalid','Invalid source record.');
  return value;
}
function sourceID(value:any):string {
  if(typeof value!=='string'||!value.trim()||value.length>200) throw failure('legacy_import_invalid','A stable source record ID is required.');
  return value.trim();
}
function timestamp(value:any,fallback:Date):Date {
  const at=typeof value==='string'?Date.parse(value):NaN;
  return Number.isFinite(at)?new Date(at):fallback;
}
async function readJSON(response:Response):Promise<any> {
  if(!response.ok) throw failure('legacy_import_source_unavailable','Existing account data could not be read. Retry sign-in.',response.status===401?401:503);
  const bytes=await response.text();
  if(bytes.length>2_000_000) throw failure('legacy_import_too_large','Source response exceeds the bounded import size.');
  try{return JSON.parse(bytes);}catch{throw failure('legacy_import_invalid','Invalid source response.');}
}

/** These are existing owner-scoped read contracts. Never calls communityAction,
 * membership reconciliation, account deletion, or a source write operation. */
export async function prepareLegacyImport(source:Source,dependencies:{fetch?:typeof fetch,db?:any}={}):Promise<Snapshot> {
  if(!ORIGINS.has(source.origin)||source.appID!==APP_ID) throw failure('legacy_import_source_forbidden','Unexpected legacy source.',403);
  if(typeof source.accessToken!=='string'||source.accessToken.length<20) throw failure('legacy_session_required','Sign in to the existing account.',401);
  const fetcher=dependencies.fetch||fetch,base=source.origin+'/api/apps/'+source.appID,deadline=AbortSignal.timeout(25_000);
  const headers={Authorization:'Bearer '+source.accessToken,'X-App-Id':source.appID,'Content-Type':'application/json',Origin:source.origin};
  const get=async(url:string)=>readJSON(await fetcher(url,{headers,redirect:'error',signal:AbortSignal.any([deadline,AbortSignal.timeout(10_000)])}));
  const identity=record(await get(base+'/entities/User/me'));
  if(sourceID(identity.id)!==sourceID(source.expectedLegacyID)) throw failure('legacy_identity_changed','The verified account changed during import.',409);
  const email=clean(identity.email).toLowerCase();
  if(!email||email.length>320) throw failure('legacy_import_identity_incomplete','The source account email is missing.');
  const sourceKey=source.origin+'/'+source.appID;
  const [prior]=dependencies.db?await dependencies.db`select status,history_cursor from app_private.legacy_import_runs where source_key=${sourceKey} and legacy_user_id=${identity.id}`:[];
  const previousCursor:Cursor=prior?.history_cursor||{phase:'stable',skip:0};
  let cursor:Cursor={...previousCursor};
  const alreadyComplete=prior?.status==='complete';
  const packs=alreadyComplete?[]:await readJSON(await fetcher(base+'/functions/wordPackAction',{method:'POST',headers,redirect:'error',signal:AbortSignal.any([deadline,AbortSignal.timeout(15_000)]),body:JSON.stringify({action:'list',access_token:source.accessToken})}));
  const historyByID=new Map<string,Row>();
  async function pageAt(position:Cursor,limit=PAGE):Promise<Row[]> {
    const query=position.phase==='stable'?{player_user_id:identity.id}:{player_email:identity.email};
    const url=new URL(base+'/entities/GameHistory');
    url.search=new URLSearchParams({q:JSON.stringify(query),sort:'-created_date',limit:String(limit),skip:String(position.skip)}).toString();
    const page=await get(url.toString());
    if(!Array.isArray(page)||page.length>limit)throw failure('legacy_import_invalid','Invalid history page.');
    for(const item of page) {
      const row=record(item),owner=clean(row.player_user_id);sourceID(row.id);
      // Email is only the provider's legacy row-access contract, never an identity link.
      if(owner?owner!==identity.id:clean(row.player_email).toLowerCase()!==email)throw failure('legacy_import_owner_mismatch','Source history belongs to another account.',403);
    }
    return page;
  }
  if(!alreadyComplete) {
    if(cursor.anchor&&cursor.skip>0) {
      const anchor=await pageAt({...cursor,skip:cursor.skip-1},1);
      if(anchor[0]?.id!==cursor.anchor)throw failure('legacy_import_snapshot_changed','Source history changed during migration; a new snapshot is required.',409);
    }
    for(let pageNumber=0;pageNumber<PAGES_PER_EXCHANGE&&cursor.phase!=='done';pageNumber++) {
      if(cursor.skip>=MAX_HISTORY)throw failure('legacy_import_too_large','This account requires a larger explicit history migration.');
      const page=await pageAt(cursor);
      for(const row of page) {
        const previous=historyByID.get(row.id);
        if(previous&&canonical(previous)!==canonical(row))throw failure('legacy_import_snapshot_changed','Source history changed during import. Retry.',503);
        historyByID.set(row.id,row);
      }
      if(page.length<PAGE)cursor={phase:cursor.phase==='stable'?'email':'done',skip:0};
      else cursor={...cursor,skip:cursor.skip+PAGE,anchor:page.at(-1)!.id};
    }
  }
  // The source list contract caps each ownership query at 500 without a cursor.
  // Reaching that boundary is ambiguous and must not be called a complete import.
  if(!Array.isArray(packs)||packs.length>=500) throw failure('legacy_import_pack_limit','This account requires a batched word-pack migration; no partial import was applied.');
  const seenPacks=new Set<string>();
  for(const value of packs){const row=record(value),id=sourceID(row.id);if(seenPacks.has(id))throw failure('legacy_import_invalid','Duplicate source pack ID.');seenPacks.add(id);}
  const snapshot:Snapshot={sourceKey,origin:source.origin,legacyID:identity.id,identity,packs,history:[...historyByID.values()],capturedAt:Date.now(),previousCursor,nextCursor:cursor,alreadyComplete};
  // Only in-process source verification creates evidence; HTTP JSON cannot forge it.
  verified.add(snapshot); return snapshot;
}

async function mappedUUID(sourceKey:string,entity:string,id:string):Promise<string> {
  const hex=await digest('spyclash-legacy-import-v1:'+sourceKey+':'+entity+':'+id);
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-5${hex.slice(13,16)}-a${hex.slice(17,20)}-${hex.slice(20,32)}`;
}
function profileData(identity:Row):Row {
  const data:Row={full_name:safeCommunityDisplayName(identity.full_name||identity.display_name||'Operative'),display_name:safeCommunityDisplayName(identity.display_name||identity.full_name||'Operative'),avatar:safeCommunityAvatar(identity.avatar||'🕵️')};
  for(const [key,allowed,fallback] of [
    ['language',['en','ru','uk','es'],'en'],['spy_card_theme',['field','blacksite','dossier'],'field'],
    ['spy_card_accent',['signal_red','clearance_amber','verified_green'],'signal_red'],['spy_card_badge',['operative','ghost','analyst','handler'],'operative'],
    ['radar_invite_policy',['ask','automatic','blocked'],'ask'],
  ] as Array<[string,string[],string]>) data[key]=allowed.includes(clean(identity[key]))?clean(identity[key]):fallback;
  data.onboarding_completed=identity.onboarding_completed===true;
  data.onboarding_version=Number.isInteger(identity.onboarding_version)&&identity.onboarding_version>=1?identity.onboarding_version:0;
  if(typeof identity.onboarding_completed_at==='string'&&Number.isFinite(Date.parse(identity.onboarding_completed_at)))data.onboarding_completed_at=identity.onboarding_completed_at;
  if(['chatgpt','app_store_search','web_search','social_media','friends_or_family','other'].includes(identity.acquisition_source))data.acquisition_source=identity.acquisition_source;
  // Provider role, rating mirrors, quotas and arbitrary metadata are not imported.
  return data;
}
function normalizedPack(row:Row,id:string,email:string):Row {
  if(typeof row.name!=='string'||!row.name.trim()||row.name.length>200||typeof row.category!=='string'||row.category.length>200
      ||!Array.isArray(row.words)||!row.words.length||row.words.length>10000||row.words.some((w:any)=>typeof w!=='string'||!w.trim()||w.length>200))throw failure('legacy_import_invalid_pack','An existing pack needs review before migration.');
  return {id,name:row.name,category:row.category,words:row.words,owner_email:email,is_public:false};
}
async function reserveRow(ctx:AppContext,s:Snapshot,entity:string,row:Row,targetID:string):Promise<boolean> {
  const source=sourceID(row.id),hash=await digest(canonical(row));
  const [prior]=await ctx.tx`select user_id from app_private.legacy_import_rows where source_key=${s.sourceKey} and entity=${entity} and source_id=${source}`;
  if(prior){if(prior.user_id!==ctx.actor.id)throw failure('legacy_import_owner_mismatch','Source row already belongs to another account.',409);return false;}
  await ctx.tx`insert into app_private.legacy_import_rows(user_id,source_key,entity,source_id,source_digest,target_id) values(${ctx.actor.id},${s.sourceKey},${entity},${source},${hash},${targetID})`;
  return true;
}

/** Caller owns the outer transaction. Serialized per actor and opposed to account
 * deletion; aborting any source validation rolls back the entire import. */
export async function applyLegacyImport(ctx:AppContext,snapshot:Snapshot):Promise<Row> {
  if(!snapshot||!verified.has(snapshot)||Date.now()-snapshot.capturedAt>180_000)throw failure('legacy_import_verification_required','Fresh verified source data is required.',401);
  const s=snapshot,{tx,actor,now}=ctx;
  await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+actor.id},0))`;
  await tx`select pg_advisory_xact_lock(hashtextextended(${'legacy-import:'+actor.id},0))`;
  const [link]=await tx`select * from app_private.legacy_links where user_id=${actor.id} for share`;
  if(!link||link.state!=='active'||link.legacy_user_id!==s.legacyID||link.source_origin!==s.origin)throw failure('legacy_import_link_required','The account mapping must be verified before import.',409);
  let [profile]=await tx`select * from app_private.profiles where user_id=${actor.id} for update`;
  if(profile&&profile.state!=='active')throw failure('account_unavailable','This account is unavailable.',410);
  const [run]=await tx`select * from app_private.legacy_import_runs where user_id=${actor.id} and source_key=${s.sourceKey}`;
  if(run&&run.legacy_user_id!==s.legacyID)throw failure('legacy_import_owner_mismatch','This import belongs to another account.',409);
  if(run?.status==='complete') {
    await tx`update app_private.profiles set contact_email=${clean(s.identity.email)} where user_id=${actor.id}`;
    return {complete:true,profile_imported:false,packs_imported:0,history_imported:0,social_status:run.social_status};
  }
  if(canonical(run?.history_cursor||{phase:'stable',skip:0})!==canonical(s.previousCursor))throw failure('legacy_import_progress_changed','Another login advanced the import. Retry.',503);
  await tx`insert into app_private.legacy_import_runs(user_id,source_key,legacy_user_id,last_import_at) values(${actor.id},${s.sourceKey},${s.legacyID},${now}) on conflict(user_id,source_key) do update set last_import_at=excluded.last_import_at`;
  let profileImported=false;
  if(!run?.profile_applied) {
    // A preexisting nonempty staging profile is user data too. Never replace its
    // cosmetics or identity choices merely because an old account was linked.
    const virgin=!profile||Object.keys(profile.data||{}).length===0;
    if(virgin) {
      const spyID=normalizeSpyID(s.identity.spy_id);
      await tx`select pg_advisory_xact_lock(hashtextextended('app:spy-id-allocation',0))`;
      if(spyID&&(await tx`select 1 from app_private.profiles where spy_id=${spyID} and user_id<>${actor.id}`).length)throw failure('legacy_spy_id_conflict','The existing SPY ID needs manual conflict resolution.',409);
      const data=profileData(s.identity),created=timestamp(s.identity.created_date,now);
      [profile]=await tx`insert into app_private.profiles(user_id,contact_email,spy_id,data,created_at,updated_at) values(${actor.id},${clean(s.identity.email)},${spyID},${tx.json(data)},${created},${now}) on conflict(user_id) do update set contact_email=excluded.contact_email,spy_id=excluded.spy_id,data=excluded.data,updated_at=excluded.updated_at returning *`;
      profileImported=true;
    } else await tx`update app_private.profiles set contact_email=${clean(s.identity.email)} where user_id=${actor.id}`;
    await reserveRow(ctx,s,'User',s.identity,actor.id);
    await tx`update app_private.legacy_import_runs set profile_applied=true where user_id=${actor.id} and source_key=${s.sourceKey}`;
  }
  await ensureProfile({...ctx,actor:{...actor,contactEmail:clean(s.identity.email)}});
  let packsImported=0,historyImported=0;
  for(const row of s.packs) {
    const id=await mappedUUID(s.sourceKey,'WordPack',row.id),pack=normalizedPack(row,id,actor.email);
    if(!await reserveRow(ctx,s,'WordPack',row,id))continue;
    await tx`insert into full_game_private.word_packs(id,owner_id,pack,created_at,updated_at) values(${id},${actor.id},${tx.json(pack)},${timestamp(row.created_date,now)},${timestamp(row.updated_date,now)})`;
    packsImported++;
  }
  const staged=s.history.map(row=>{
    // Keep only original result fields, not arbitrary profile/contact metadata.
    const data:Row={id:row.id};
    for(const key of ['player_user_id','match_id','result_key','created_date','room_code','match_type','role','word','category','winner','player_count','spy_count','won','ranked'])if(row[key]!==undefined)data[key]=row[key];
    return {source_id:sourceID(row.id),data};
  });
  if(staged.length) {
    const priorRows=await tx`select source_id,data from app_private.legacy_import_history_stage where user_id=${actor.id} and source_key=${s.sourceKey} and source_id=any(${staged.map(r=>r.source_id)}::text[])`;
    const priorMap=new Map(priorRows.map((r:any)=>[r.source_id,r.data]));
    for(const row of staged)if(priorMap.has(row.source_id)&&canonical(priorMap.get(row.source_id))!==canonical(row.data))throw failure('legacy_import_snapshot_changed','A previously captured source result changed; migration requires review.',409);
    await tx`insert into app_private.legacy_import_history_stage(user_id,source_key,source_id,data)
      select ${actor.id}::uuid,${s.sourceKey},r.source_id,r.data from jsonb_to_recordset(${tx.json(staged)}::jsonb) as r(source_id text,data jsonb)
      on conflict(user_id,source_key,source_id) do nothing`;
  }
  await tx`update app_private.legacy_import_runs set history_cursor=${tx.json(s.nextCursor)} where user_id=${actor.id} and source_key=${s.sourceKey}`;
  if(s.nextCursor.phase!=='done')return {complete:false,profile_imported:profileImported,packs_imported:packsImported,history_imported:0,social_status:'deferred_verified_export_required'};
  const captured=await tx`select data from app_private.legacy_import_history_stage where user_id=${actor.id} and source_key=${s.sourceKey}`;
  // Preserve the original dedup policy across all batches before re-keying IDs.
  const entries=await Promise.all(deduplicateCompetitiveHistory(captured.map((r:any)=>r.data)).map(async row=>{
    const matchID=await mappedUUID(s.sourceKey,'Match',clean(row.match_id)||'history:'+sourceID(row.id));
    const stableOwner=clean(row.player_user_id)===s.legacyID;
    const result:Row={match_id:matchID,result_key:matchID+':'+actor.id,player_user_id:stableOwner?actor.id:'',player_email:actor.email};
    for(const key of ['room_code','match_type','role','word','category','winner','player_count','spy_count','won','ranked'])if(row[key]!==undefined)result[key]=row[key];
    // Email-only historical records remain visible without gaining ranked credit.
    if(!stableOwner)result.ranked=false;
    const created=timestamp(row.created_date,now);result.created_date=created.toISOString();
    return {source_id:sourceID(row.id),source_digest:await digest(canonical(row)),target_id:matchID,result,created_at:created.toISOString()};
  }));
  if(entries.length) {
    const priorRows=await tx`select source_id,user_id from app_private.legacy_import_rows where source_key=${s.sourceKey} and entity='GameHistory' and source_id=any(${entries.map(r=>r.source_id)}::text[])`;
    if(priorRows.some((r:any)=>r.user_id!==actor.id))throw failure('legacy_import_owner_mismatch','Source history has another mapped owner.',409);
    const priorIDs=new Set(priorRows.map((r:any)=>r.source_id)),fresh=entries.filter(r=>!priorIDs.has(r.source_id));
    if(fresh.length) {
      await tx`insert into app_private.legacy_import_rows(user_id,source_key,entity,source_id,source_digest,target_id)
        select ${actor.id}::uuid,${s.sourceKey},'GameHistory',r.source_id,r.source_digest,r.target_id
        from jsonb_to_recordset(${tx.json(fresh)}::jsonb) as r(source_id text,source_digest text,target_id uuid)`;
      const rows=await tx`insert into full_game_private.history(match_id,player_id,room_id,result,created_at)
        select r.target_id,${actor.id}::uuid,null,r.result,r.created_at from jsonb_to_recordset(${tx.json(fresh)}::jsonb) as r(target_id uuid,result jsonb,created_at timestamptz)
        on conflict(match_id,player_id) do nothing returning match_id`;
      historyImported=rows.length;
    }
  }
  await tx`delete from app_private.legacy_import_history_stage where user_id=${actor.id} and source_key=${s.sourceKey}`;
  await tx`update app_private.legacy_import_runs set status='complete' where user_id=${actor.id} and source_key=${s.sourceKey}`;
  return {complete:true,profile_imported:profileImported,packs_imported:packsImported,history_imported:historyImported,social_status:'deferred_verified_export_required'};
}

/** Private migration-only format: it never creates fake users or sends invites.
 * Supply rows from a verified administrative source export, not HTTP/client JSON.
 * Both identities still require immutable legacy mappings before later apply. */
export async function stageLegacySocialExport(ctx:AppContext,input:{sourceKey:string,legacyID:string,rows:Row[],capturedAt:Date}) {
  await ctx.tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+ctx.actor.id},0))`;
  const [profile]=await ctx.tx`select state,data from app_private.profiles where user_id=${ctx.actor.id} for share`;
  if(profile?.state!=='active'||ctx.config.LEGACY_SOCIAL_IMPORT_ENABLED!=='true'||!isAppAdmin(ctx,profile))throw failure('legacy_social_import_forbidden','Only an authorized migration operator can stage a verified source export.',403);
  if(!Array.isArray(input.rows)||input.rows.length>5000)throw failure('legacy_social_import_limit','Use a bounded social export.');
  const [link]=await ctx.tx`select legacy_user_id,state,source_origin from app_private.legacy_links where user_id=${ctx.actor.id} for share`;
  if(!link||link.state!=='active'||link.legacy_user_id!==input.legacyID||input.sourceKey!==link.source_origin+'/'+APP_ID)throw failure('legacy_import_link_required','Verified account mapping required.',409);
  let deferred=0;
  for(const value of input.rows) {
    const row=record(value),entity=clean(row.entity),id=sourceID(row.id);
    const first=clean(entity==='Friendship'?row.requester_id:row.target_user_id),second=clean(entity==='Friendship'?row.addressee_id:row.author_user_id);
    if(!['Friendship','ProfileComment'].includes(entity)||first===second||![first,second].includes(input.legacyID))throw failure('legacy_social_owner_mismatch','Social row is outside this account.',403);
    const peer=sourceID(first===input.legacyID?second:first);
    const [mapping]=await ctx.tx`select l.user_id from app_private.legacy_links l join app_private.profiles p on p.user_id=l.user_id and p.state='active' where l.legacy_user_id=${peer} and l.source_origin=${link.source_origin} and l.state='active'`;
    const data=entity==='Friendship'?{requester_id:first,addressee_id:second,status:row.status,blocked_by_id:row.blocked_by_id||null,created_at:row.created_at,updated_at:row.updated_at}:{target_user_id:first,author_user_id:second,body:row.body,created_at:row.created_at,updated_at:row.updated_at};
    if(entity==='Friendship'&&!['pending','accepted','declined','blocked'].includes(data.status))throw failure('legacy_social_invalid','Invalid friendship status.');
    if(entity==='ProfileComment'&&(typeof data.body!=='string'||!data.body||data.body.length>280))throw failure('legacy_social_invalid','Invalid profile comment.');
    await ctx.tx`insert into app_private.legacy_pending_social(owner_id,source_key,source_id,entity,peer_legacy_id,source_digest,data,state,captured_at) values(${ctx.actor.id},${input.sourceKey},${id},${entity},${peer},${await digest(canonical(data))},${ctx.tx.json(data)},${mapping?'ready_for_review':'awaiting_identity_mapping'},${input.capturedAt}) on conflict(owner_id,source_key,entity,source_id) do nothing`;
    deferred++;
  }
  return {staged:deferred,applied:0,requires_review:true};
}

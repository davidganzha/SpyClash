import {AppServiceError,type AppContext} from './contracts.ts';
import {canonical,digest} from './integration-crypto.ts';
import {isAppAdmin,signalProfile,signalUsers} from './profile.ts';
import {safeCommunityTextForDisplay} from './policies/community-safety.ts';
import {hidePersonalNotifications} from './inbox.ts';

type Row=Record<string,any>;
export const SOCIAL_SOURCE='https://spyclash.com/69a0e57fa939f578082f8091';
const fields={Friendship:['id','requester_id','addressee_id','status','blocked_by_id','created_at','updated_at','created_date','updated_date'],ProfileComment:['id','target_user_id','author_user_id','body','created_at','updated_at','created_date','updated_date']};
type Entity=keyof typeof fields;
export type SocialExport={version:1,source_key:string,captured_at:string,rows:Row[],digest:string};
type EntityReader=(entity:Entity,options:{sort:string,limit:number,skip:number,fields:string[]})=>Promise<Row[]>;
const fail=(code:string,message:string)=>new AppServiceError(code,message,422);
const text=(v:any)=>typeof v==='string'?v.trim():'';
function identifier(v:any):string {const s=text(v);if(!s||s.length>200)throw fail('social_export_invalid','Missing stable source identity.');return s;}
function date(v:any):string {if(typeof v!=='string'||!Number.isFinite(Date.parse(v)))throw fail('social_export_invalid','A source timestamp is required.');return new Date(v).toISOString();}
function normalize(entity:Entity,value:Row):Row {
  if(!value||typeof value!=='object'||Array.isArray(value))throw fail('social_export_invalid','Invalid source record.');
  const common={entity,id:identifier(value.id),created_at:date(value.created_at||value.created_date),updated_at:date(value.updated_at||value.updated_date||value.created_at||value.created_date)};
  if(entity==='Friendship') {
    const requester=identifier(value.requester_id),addressee=identifier(value.addressee_id),status=text(value.status);
    if(requester===addressee||!['pending','accepted','declined','blocked'].includes(status))throw fail('social_export_invalid','Invalid source friendship.');
    const blocked=status==='blocked'?identifier(value.blocked_by_id):null;
    if(blocked&&![requester,addressee].includes(blocked))throw fail('social_export_invalid','Invalid block owner.');
    return {...common,requester_id:requester,addressee_id:addressee,status,blocked_by_id:blocked};
  }
  const target=identifier(value.target_user_id),author=identifier(value.author_user_id);
  if(target===author||typeof value.body!=='string'||!value.body.trim()||value.body.length>280)throw fail('social_export_invalid','Invalid source comment.');
  return {...common,target_user_id:target,author_user_id:author,body:value.body};
}
const participants=(r:Row):string[]=>r.entity==='Friendship'?[r.requester_id,r.addressee_id]:[r.target_user_id,r.author_user_id];

/** Adapter supports CLI SDK list() or connector query_entities(). It calls only
 * direct entity reads: no communityAction, profile repair, analytics, or writes. */
export async function captureLegacySocialExport(read:EntityReader,{pageSize=250,maxRows=10000,now=new Date()}={}):Promise<SocialExport> {
  if(!Number.isInteger(pageSize)||pageSize<1||pageSize>500||!Number.isInteger(maxRows)||maxRows<1||maxRows>20000)throw fail('social_export_limit','Invalid export bound.');
  const rows:Row[]=[],seen=new Set<string>();
  for(const entity of ['Friendship','ProfileComment'] as Entity[]) {
    let complete=false;
    for(let skip=0;skip<=maxRows;skip+=pageSize) {
      const page=await read(entity,{sort:'id',limit:pageSize,skip,fields:fields[entity]});
      if(!Array.isArray(page)||page.length>pageSize)throw fail('social_export_invalid','Invalid source page.');
      for(const value of page) {
        const row=normalize(entity,value),key=entity+':'+row.id;
        if(seen.has(key))throw fail('social_export_changed','Source pagination changed; repeat the read-only export.');
        seen.add(key);rows.push(row);
        if(rows.length>maxRows)throw fail('social_export_limit','Export exceeds its explicit bound; no complete snapshot was produced.');
      }
      if(page.length<pageSize){complete=true;break;}
    }
    if(!complete)throw fail('social_export_limit','Export is incomplete.');
  }
  const value={version:1 as const,source_key:SOCIAL_SOURCE,captured_at:now.toISOString(),rows};
  return {...value,digest:await digest(canonical(value))};
}
async function verifyExport(value:SocialExport) {
  if(value?.version!==1||value.source_key!==SOCIAL_SOURCE||!Array.isArray(value.rows)||value.rows.length>20000)throw fail('social_export_invalid','Unexpected export provenance.');
  date(value.captured_at);
  const expected=await digest(canonical({version:value.version,source_key:value.source_key,captured_at:value.captured_at,rows:value.rows}));
  if(value.digest!==expected)throw fail('social_export_digest_mismatch','The private source export changed.');
  const rows=value.rows.map(row=>{
    if(!['Friendship','ProfileComment'].includes(row.entity))throw fail('social_export_invalid','Unsupported source entity.');
    return normalize(row.entity,row);
  });
  if(new Set(rows.map(r=>r.entity+':'+r.id)).size!==rows.length)throw fail('social_export_invalid','Duplicate source record.');
  return rows;
}
/** Read-only projection. Peer ownership is matched only by verified legacy ID. */
export async function planLegacySocialExport(value:SocialExport,mappings:Array<{legacy_user_id:string,user_id:string,state?:string,source_origin?:string}>) {
  const rows=await verifyExport(value),map=new Map<string,string>();
  for(const m of mappings) {
    if(m.state&&m.state!=='active')continue;
    if(m.source_origin&&m.source_origin!=='https://spyclash.com')continue;
    if(map.has(m.legacy_user_id)&&map.get(m.legacy_user_id)!==m.user_id)throw fail('social_mapping_conflict','A legacy identity has multiple owners.');
    map.set(identifier(m.legacy_user_id),identifier(m.user_id));
  }
  const ready:Row[]=[],deferred:Row[]=[];
  for(const row of rows) {
    const peers=participants(row),targets=peers.map(id=>map.get(id));
    const plan={entity:row.entity,source_id:row.id,target_ids:targets.filter(Boolean),unmapped_count:targets.filter(id=>!id).length};
    if(targets.every(Boolean)&&targets[0]!==targets[1])ready.push(plan);else deferred.push(plan);
  }
  return {dry_run:true,source_digest:value.digest,total:rows.length,ready_count:ready.length,deferred_count:deferred.length,ready,deferred};
}
async function operator(ctx:AppContext) {
  await ctx.tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+ctx.actor.id},0))`;
  const [profile]=await ctx.tx`select state,data from app_private.profiles where user_id=${ctx.actor.id}`;
  if(ctx.config.LEGACY_SOCIAL_IMPORT_ENABLED!=='true'||profile?.state!=='active'||!isAppAdmin(ctx,profile))throw new AppServiceError('legacy_social_import_forbidden','A server-authorized migration operator is required.',403);
}

/** Private operator command. Not routed from app-services or any client body.
 * Captured content is staged once; a different snapshot cannot overwrite it. */
export async function stageVerifiedSocialExport(ctx:AppContext,value:SocialExport) {
  await operator(ctx);const rows=await verifyExport(value);
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended('app:legacy-social-migration',0))`;
  const mappings=await ctx.tx`select l.legacy_user_id,l.user_id from app_private.legacy_links l join app_private.profiles p on p.user_id=l.user_id and p.state='active' where l.state='active' and l.source_origin='https://spyclash.com'`;
  const map=new Map<string,string>(mappings.map((r:any)=>[r.legacy_user_id,r.user_id]));
  const targetIDs=[...new Set(rows.flatMap(r=>participants(r).map(id=>map.get(id)).filter(Boolean)))].sort();
  for(const id of targetIDs)await ctx.tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+id},0))`;
  const liveRows=await ctx.tx`select user_id from app_private.profiles where user_id=any(${targetIDs}::uuid[]) and state='active' for share`;
  const live=new Set(liveRows.map((r:any)=>r.user_id));
  for(const [legacy,id] of map)if(!live.has(id))map.delete(legacy);
  let staged=0,unmapped=0;
  for(const row of rows) {
    const peers=participants(row),ownerLegacy=peers.find(id=>map.has(id));
    if(!ownerLegacy){unmapped++;continue;}
    const ownerID=map.get(ownerLegacy)!,peerLegacy=peers.find(id=>id!==ownerLegacy)!;
    const [prior]=await ctx.tx`select source_digest from app_private.legacy_pending_social where source_key=${value.source_key} and entity=${row.entity} and source_id=${row.id} limit 1`;
    const hash=await digest(canonical(row));
    if(prior&&prior.source_digest!==hash)throw fail('social_source_conflict','A different social snapshot is already staged; review it before replacing.');
    if(prior)continue;
    await ctx.tx`insert into app_private.legacy_pending_social(owner_id,source_key,entity,source_id,peer_legacy_id,source_digest,data,state,captured_at)
      values(${ownerID},${value.source_key},${row.entity},${row.id},${peerLegacy},${hash},${ctx.tx.json(row)},${map.has(peerLegacy)?'ready_for_review':'awaiting_identity_mapping'},${value.captured_at})`;
    staged++;
  }
  return {staged,unmapped,applied:0};
}
async function targetID(entity:string,id:string) {
  const hash=await digest('spyclash-social-import-v1:'+SOCIAL_SOURCE+':'+entity+':'+id);
  return `${hash.slice(0,8)}-${hash.slice(8,12)}-5${hash.slice(13,16)}-a${hash.slice(17,20)}-${hash.slice(20,32)}`;
}

/** Apply only explicitly reviewed source IDs. Existing local relationships are
 * never overwritten; existing blocks and source blocks suppress comments.
 * No push or invitation is generated for imported historical relationships. */
export async function applyDeferredSocialRows(ctx:AppContext,sourceIDs:string[]) {
  await operator(ctx);
  if(!Array.isArray(sourceIDs)||!sourceIDs.length||sourceIDs.length>500)throw fail('social_apply_limit','Review at most 500 source IDs per transaction.');
  sourceIDs=[...new Set(sourceIDs.map(identifier))];
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended('app:legacy-social-migration',0))`;
  const rows=await ctx.tx`select * from app_private.legacy_pending_social where source_key=${SOCIAL_SOURCE} and source_id=any(${sourceIDs}::text[]) order by case when entity='Friendship' then 0 else 1 end,source_id for update`;
  for(const row of rows)row.data=normalize(row.entity,{...row.data,id:row.source_id});
  const mappings=await ctx.tx`select l.legacy_user_id,l.user_id from app_private.legacy_links l join app_private.profiles p on p.user_id=l.user_id and p.state='active' where l.state='active' and l.source_origin='https://spyclash.com'`;
  const map=new Map<string,string>(mappings.map((r:any)=>[r.legacy_user_id,r.user_id]));
  const accountIDs=[...new Set(rows.flatMap((r:any)=>participants(r.data).map(id=>map.get(id)).filter(Boolean)))].sort();
  for(const id of accountIDs)await ctx.tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+id},0))`;
  const active=await ctx.tx`select user_id from app_private.profiles where user_id=any(${accountIDs}::uuid[]) and state='active' order by user_id for share`;
  const live=new Set(active.map((r:any)=>r.user_id));
  const summary={applied:0,already_applied:0,deferred:0,conflicts:0,blocked_comments:0};
  rows.sort((a:any,b:any)=>(a.entity==='Friendship'?0:2)-(b.entity==='Friendship'?0:2)||(a.data.status==='blocked'?-1:0)-(b.data.status==='blocked'?-1:0)||a.source_id.localeCompare(b.source_id));
  for(const pending of rows) {
    if(pending.state==='applied'){summary.already_applied++;continue;}
    const row=normalize(pending.entity,{...pending.data,id:pending.source_id}),[legacyA,legacyB]=participants(row),a=map.get(legacyA),b=map.get(legacyB);
    if(!a||!b||!live.has(a)||!live.has(b)){summary.deferred++;continue;}
    if(a===b)throw fail('social_mapping_conflict','A social pair maps to the same account.');
    const pair=[a,b].sort();
    await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'app:pair:'+pair.join(':')},0))`;
    const [existing]=await ctx.tx`select * from app_private.friendships where pair_low=${pair[0]} and pair_high=${pair[1]} for update`;
    const id=await targetID(row.entity,row.id);
    if(row.entity==='Friendship') {
      if(existing&&existing.id!==id){summary.conflicts++;continue;}
      if(!existing)await ctx.tx`insert into app_private.friendships(id,requester_id,addressee_id,status,blocked_by_id,created_at,updated_at)
        values(${id},${a},${b},${row.status},${row.status==='blocked'?map.get(row.blocked_by_id):null},${row.created_at},${row.updated_at})`;
      if(row.status==='blocked') {
        await ctx.tx`delete from app_private.profile_comments where (author_user_id=${a} and target_user_id=${b}) or (author_user_id=${b} and target_user_id=${a})`;
        await ctx.tx`delete from app_private.room_invites where (sender_user_id=${a} and recipient_user_id=${b}) or (sender_user_id=${b} and recipient_user_id=${a})`;
        await hidePersonalNotifications(ctx,{pair:[a,b]});
      }
    } else {
      const sourceBlocks=await ctx.tx`select 1 from app_private.legacy_pending_social where source_key=${SOCIAL_SOURCE} and entity='Friendship' and data->>'status'='blocked'
        and ((data->>'requester_id'=${legacyA} and data->>'addressee_id'=${legacyB}) or (data->>'requester_id'=${legacyB} and data->>'addressee_id'=${legacyA})) limit 1`;
      if(existing?.status==='blocked'||sourceBlocks.length||!safeCommunityTextForDisplay(row.body,''))summary.blocked_comments++;
      else await ctx.tx`insert into app_private.profile_comments(id,target_user_id,author_user_id,body,created_at,updated_at) values(${id},${a},${b},${row.body},${row.created_at},${row.updated_at}) on conflict(id) do nothing`;
    }
    await ctx.tx`update app_private.legacy_pending_social set state='applied' where source_key=${SOCIAL_SOURCE} and entity=${row.entity} and source_id=${row.id}`;
    await signalUsers(ctx,[a,b]);await signalProfile(ctx,a);await signalProfile(ctx,b);summary.applied++;
  }
  return summary;
}

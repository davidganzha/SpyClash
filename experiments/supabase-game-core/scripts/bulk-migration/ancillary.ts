/** Private offline data migration. No provider calls, pushes, sessions or jobs. */
import { mappedUUID, type CorePlan, type SourceSnapshot, type Row, type Issue } from './core.ts';
import { canonical, digest } from '../../supabase/functions/app-services/integration-crypto.ts';

export type AncillaryTarget = {announcements:Row[];events:Row[];readReceipts:Row[];reports:Row[]};
export type AncillaryPlan = AncillaryTarget & {version:1;sourceKey:string;sourceDigest:string;baseline:AncillaryTarget;provenance:Row[];issues:Issue[];warnings:Issue[];dispositions:Row[];counts:Row};
const text=(v:unknown)=>typeof v==='string'?v.trim():'';
// Base44's timezone-less ISO timestamps are UTC, independent of operator TZ.
const timestamp=(v:unknown):string|null=>{
  if(typeof v!=='string')return null;
  const normalized=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$/.test(v)?v+'Z':v;
  return Number.isFinite(Date.parse(normalized))?new Date(normalized).toISOString():null;
};
const created=(r:Row,fallback:string)=>timestamp(r.created_at)||timestamp(r.created_date)||fallback;
const updated=(r:Row,fallback:string)=>timestamp(r.updated_at)||timestamp(r.updated_date)||created(r,fallback);
const sorted=(rows:Row[])=>rows.map(canonical).sort();
const same=(a:unknown,b:unknown)=>canonical(a)===canonical(b);
const sourceKey=(entity:string,id:string)=>entity+'\n'+id;
const retained=(published:string,now:string)=>published<=now&&published>=new Date(Math.max(Date.parse('2026-07-27T00:00:00.000Z'),Date.parse(now)-90*86400000)).toISOString();
const plain=(v:unknown)=>typeof v==='string'?v:'';

export async function readAncillaryTarget(db:any):Promise<AncillaryTarget> {
  // Preserve PostgreSQL's full timestamp precision, matching reviewed SQL JSON.
  // Driver Date conversion would truncate microseconds and falsely report drift.
  const announcements=(await db`select to_jsonb(t) as value from app_private.notification_announcements t`).map((r:Row)=>r.value);
  const events=(await db`select to_jsonb(t) as value from app_private.notification_events t`).map((r:Row)=>r.value);
  const readReceipts=(await db`select to_jsonb(t) as value from app_private.notification_read_receipts t`).map((r:Row)=>r.value);
  const reports=(await db`select to_jsonb(t) as value from app_private.community_reports t`).map((r:Row)=>r.value);
  return {announcements,events,readReceipts,reports};
}

/** Uses only reviewed core account mappings. Source email never binds identity. */
export async function buildAncillaryPlan(snapshot:SourceSnapshot,core:CorePlan,target:AncillaryTarget):Promise<AncillaryPlan> {
  if(core.sourceDigest!==snapshot.digest||core.sourceKey!==snapshot.source.origin+'/'+snapshot.source.appID)throw new Error('ancillary_source_mismatch');
  const names=['NotificationAnnouncement','NotificationReadReceipt','PushNotificationEvent','CommunityReport','RoomInvite','GameRoom'];
  for(const name of names)if(!Array.isArray(snapshot.entities[name]))throw new Error('ancillary_source_entity_missing:'+name);
  const p:AncillaryPlan={version:1,sourceKey:core.sourceKey,sourceDigest:snapshot.digest,baseline:target,announcements:[],events:[],readReceipts:[],reports:[],provenance:[],issues:[],warnings:[],dispositions:[],counts:{}};
  const accounts=new Map(core.accounts.map(a=>[a.legacy_user_id,a.user_id]));
  const ledger=new Map(core.baseline.bulkRows.filter(r=>r.source_key===core.sourceKey).map(r=>[sourceKey(r.entity,r.source_id),r]));
  const mapping=new Map(core.dispositions.filter(d=>d.target_id).map(d=>[sourceKey(d.entity,d.source_id),d.target_id]));
  const issue=(code:string,entity:string,row:Row)=>p.issues.push({code,entity,source_id:row.id});
  const warn=(code:string,entity:string,row:Row)=>p.warnings.push({code,entity,source_id:row.id});
  const rows=(entity:string)=>snapshot.entities[entity];
  const seen=new Set<string>();
  for(const name of names)for(const row of rows(name)) {
    if(!row||typeof row.id!=='string'||!row.id||row.id.length>200||seen.has(sourceKey(name,row.id)))throw new Error('ancillary_invalid_source_id');
    seen.add(sourceKey(name,row.id));
  }
  async function remember(entity:string,row:Row,action:string,target_id:string|null,reason?:string) {
    p.dispositions.push({entity,source_id:row.id,action,...(target_id?{target_id}:{}),...(reason?{reason}:{})});
    p.provenance.push({entity,source_id:row.id,source_digest:await digest(canonical(row)),target_id,disposition:action});
  }
  async function prior(entity:string,row:Row):Promise<Row|undefined> {
    const old=ledger.get(sourceKey(entity,row.id));
    if(old&&old.source_digest!==await digest(canonical(row)))issue('ancillary_source_changed_after_import',entity,row);
    if(old)await remember(entity,row,'preserve_current',old.target_id||null,'already_imported_or_deleted');
    return old;
  }
  const eventIDs=new Map<string,string>();
  const announcementIDs=new Map<string,string>();
  const allFriendships=[...core.baseline.friendships,...core.friendships];

  for(const row of rows('NotificationAnnouncement')) {
    const old=await prior('NotificationAnnouncement',row);
    const id=old?.target_id||await mappedUUID(core.sourceKey,'NotificationAnnouncement',row.id);
    announcementIDs.set(row.id,id);if(old)continue;
    if(target.announcements.some(r=>r.id===id)){issue('untracked_announcement_collision','NotificationAnnouncement',row);continue;}
    if(!['draft','published','withdrawn'].includes(row.status)||!['release','service','community','developer'].includes(row.topic)||!['quiet','important'].includes(row.importance)) {issue('invalid_source_announcement','NotificationAnnouncement',row);continue;}
    const data:Row={topic:row.topic,importance:row.importance};
    for(const locale of ['en','ru','es','uk'])for(const field of ['title','body'])data[field+'_'+locale]=plain(row[field+'_'+locale]);
    if(!text(data.title_en)||!text(data.body_en)||Object.entries(data).some(([k,v])=>(k.startsWith('title_')&&v.length>80)||(k.startsWith('body_')&&v.length>800))) {issue('invalid_announcement_copy','NotificationAnnouncement',row);continue;}
    const published_at=timestamp(row.published_at);
    if(row.status==='published'&&!published_at){issue('published_announcement_missing_date','NotificationAnnouncement',row);continue;}
    data.action_deep_link=text(row.action_deep_link).startsWith('spyclash://')?text(row.action_deep_link):'spyclash://notifications';
    // Base44 treats missing expiry as indefinite. Target needs a timestamp.
    const expires_at=timestamp(row.expires_at)||'9999-12-31T23:59:59.000Z';
    data.expires_at=expires_at;
    const author_id=accounts.get(text(row.created_by_id))||await mappedUUID(core.sourceKey,'ArchiveAuthor',text(row.created_by_id)||'system');
    // Technical audit UUID is not an Auth user or an admin grant.
    if(!accounts.has(text(row.created_by_id)))data.legacy_author_unmapped=true;
    p.announcements.push({id,request_id:await mappedUUID(core.sourceKey,'AnnouncementRequest',row.id),author_id,status:row.status,revision:await mappedUUID(core.sourceKey,'AnnouncementRevision',row.id),data,published_at,expires_at,created_at:created(row,snapshot.capturedAt),updated_at:updated(row,snapshot.capturedAt)});
    await remember('NotificationAnnouncement',row,'import',id);
  }

  for(const row of rows('PushNotificationEvent')) {
    const old=await prior('PushNotificationEvent',row);
    let id=old?.target_id||await mappedUUID(core.sourceKey,'PushNotificationEvent',row.id);
    if(old){eventIDs.set(row.id,id);continue;}
    const projected=row.inbox_visible===true&&!!timestamp(row.inbox_committed_at)&&Number(row.inbox_projection_version)>=1&&!!text(row.inbox_kind)&&!!text(row.inbox_title_en)&&!!text(row.inbox_body_en)&&!!timestamp(row.inbox_published_at)&&row.state!=='cancelled';
    const sourceFriends=rows('Friendship').filter(f=>text(f.request_event_id)&&f.request_event_id===row.source_event_id&&f.addressee_id===row.recipient_user_id);
    const sourceFriend=sourceFriends.length===1?sourceFriends[0]:undefined;
    const published=timestamp(row.inbox_published_at)||created(row,snapshot.capturedAt);
    const sourceVisible=projected&&row.event_type==='friend_request'&&(!text(row.source_event_id)||sourceFriend?.status==='pending')&&retained(published,snapshot.capturedAt);
    if(row.event_type!=='friend_request') {
      eventIDs.set(row.id,id);
      await remember('PushNotificationEvent',row,'archive_only',id,row.event_type==='room_invite'?'room_invite_not_resumed':'transport_event_not_in_source_inbox');
      continue;
    }
    const actor_id=accounts.get(row.actor_user_id),recipient_id=accounts.get(row.recipient_user_id);
    const friendID=sourceFriend&&mapping.get(sourceKey('Friendship',sourceFriend.id));
    const friend=allFriendships.find(f=>f.id===friendID);
    if(!actor_id||!recipient_id||!sourceFriend||!friend||sourceFriends.length!==1) {
      if(sourceVisible)issue('visible_personal_event_unmapped','PushNotificationEvent',row);
      eventIDs.set(row.id,id);await remember('PushNotificationEvent',row,'archive_only',id,'unavailable_source_or_owner');continue;
    }
    id=await mappedUUID(core.sourceKey,'FriendRequestEvent',row.source_event_id);
    eventIDs.set(row.id,id);
    // A current target request must never be replaced by an older source event.
    const visible=sourceVisible&&friend.status==='pending'&&friend.request_event_id===id&&friend.requester_id===actor_id&&friend.addressee_id===recipient_id;
    if(sourceVisible&&!visible)warn('current_target_request_preserved','PushNotificationEvent',row);
    const collision=[...target.events,...p.events].find(e=>e.id===id||(e.event_type==='friend_request'&&e.source_id===friendID&&e.recipient_id===recipient_id));
    if(collision){issue('untracked_personal_event_collision','PushNotificationEvent',row);continue;}
    const data:Row={importance:row.inbox_importance==='quiet'?'quiet':'important',deep_link:'spyclash://community/requests',notification_event_id:id,source_id:friendID};
    for(const locale of ['en','ru','es','uk'])for(const field of ['title','body'])data[field+'_'+locale]=plain(row['inbox_'+field+'_'+locale]);
    p.events.push({id,event_type:'friend_request',source_id:friendID,actor_id,recipient_id,room_id:null,visible,data,created_at:published});
    await remember('PushNotificationEvent',row,'import',id,visible?'source_actionable_without_push':'historical_projection_hidden');
  }

  const receipts=new Map<string,Row>();
  for(const row of rows('NotificationReadReceipt')) {
    if(await prior('NotificationReadReceipt',row))continue;
    const user_id=accounts.get(row.user_id),read_at=timestamp(row.read_at);
    const key=text(row.notification_key),split=key.indexOf(':'),prefix=split<0?key:key.slice(0,split),source=split<0?'':key.slice(split+1);
    if(!user_id){await remember('NotificationReadReceipt',row,'archive_only',null,'owner_not_in_source_users');continue;}
    if(!read_at){issue('invalid_read_receipt_date','NotificationReadReceipt',row);continue;}
    let notification_key=key;
    if(!['__all__','__all__:global','__all__:personal'].includes(key)) {
      if(!source||!['global','personal'].includes(prefix)){issue('invalid_notification_key','NotificationReadReceipt',row);continue;}
      const id=prefix==='global'?(announcementIDs.get(source)||await mappedUUID(core.sourceKey,'NotificationAnnouncement',source)):(eventIDs.get(source)||await mappedUUID(core.sourceKey,'PushNotificationEvent',source));
      notification_key=prefix+':'+id;
    }
    const composite=user_id+'\n'+notification_key;
    const existing=target.readReceipts.find(r=>r.user_id===user_id&&r.notification_key===notification_key);
    const current=receipts.get(composite)||existing;
    if(!current||Date.parse(read_at)>Date.parse(current.read_at))receipts.set(composite,{user_id,notification_key,read_at});
    await remember('NotificationReadReceipt',row,existing?'merge_read_watermark':'import',await mappedUUID(core.sourceKey,'NotificationReadReceipt',row.id));
  }
  p.readReceipts=[...receipts.values()];

  for(const row of rows('CommunityReport')) {
    if(await prior('CommunityReport',row))continue;
    const id=await mappedUUID(core.sourceKey,'CommunityReport',row.id);
    if(target.reports.some(r=>r.id===id)){issue('untracked_report_collision','CommunityReport',row);continue;}
    if(!['user','comment'].includes(row.report_type)||!['harassment','hate_speech','sexual_content','violence_or_threats','spam','impersonation','other'].includes(row.reason)||!['open','reviewing','actioned','dismissed'].includes(row.status)||plain(row.details).length>500||plain(row.content_snapshot).length>500){issue('invalid_source_report','CommunityReport',row);continue;}
    const reporter_user_id=accounts.get(row.reporter_user_id)||null,reported_user_id=accounts.get(row.reported_user_id)||null;
    const comment_id=text(row.comment_id)?mapping.get(sourceKey('ProfileComment',row.comment_id))||await mappedUUID(core.sourceKey,'ProfileComment',row.comment_id):null;
    if(reporter_user_id&&reported_user_id&&['open','reviewing'].includes(row.status)&&[...target.reports,...p.reports].some(r=>r.reporter_user_id===reporter_user_id&&r.reported_user_id===reported_user_id&&r.report_type===row.report_type&&(r.comment_id||null)===comment_id&&['open','reviewing'].includes(r.status))){issue('open_report_pair_conflict','CommunityReport',row);continue;}
    const data:Row={legacy_reporter_user_id:text(row.reporter_user_id)||null,legacy_reported_user_id:text(row.reported_user_id)||null,legacy_comment_id:text(row.comment_id)||null};
    p.reports.push({id,reporter_user_id,reported_user_id,comment_id,report_type:row.report_type,reason:row.reason,details:plain(row.details),content_snapshot:plain(row.content_snapshot),status:row.status,data,created_at:created(row,snapshot.capturedAt),updated_at:updated(row,snapshot.capturedAt)});
    await remember('CommunityReport',row,'import',id,(!reporter_user_id||!reported_user_id)?'unmapped_deleted_identifiers_retained_privately':undefined);
  }

  for(const row of rows('RoomInvite')) {
    if(await prior('RoomInvite',row))continue;
    const room=rows('GameRoom').find(r=>r.id===row.room_id);
    if(['pending','accepted'].includes(row.status)&&room?.status==='waiting')issue('actionable_source_room_invite_requires_handoff','RoomInvite',row);
    await remember('RoomInvite',row,'archive_only',null,['declined','expired'].includes(row.status)?'terminal_invite':'source_room_unavailable_not_resumed');
  }
  for(const row of rows('GameRoom')) {
    if(await prior('GameRoom',row))continue;
    if(!['waiting','finished','closed'].includes(row.status))issue('active_source_room_requires_handoff','GameRoom',row);
    await remember('GameRoom',row,'archive_only',null,row.status==='finished'?'completed_room_history_imported_separately':'live_room_not_resumed');
  }
  p.counts={announcements_to_insert:p.announcements.length,events_to_insert:p.events.length,visible_events_to_insert:p.events.filter(r=>r.visible).length,read_receipts_to_merge:p.readReceipts.length,reports_to_insert:p.reports.length,archive_only:p.dispositions.filter(d=>d.action==='archive_only').length,issues:p.issues.length,warnings:p.warnings.length};
  return p;
}

export function assertAncillaryPlanReady(plan:AncillaryPlan) {
  if(plan.issues.length)throw new Error('ancillary_plan_has_conflicts:'+plan.issues.map(i=>i.code).join(','));
}

/** Must share the outer transaction with core/archive writes. No fanout APIs. */
export async function applyAncillaryPlan(tx:any,plan:AncillaryPlan):Promise<Row> {
  assertAncillaryPlanReady(plan);
  await tx.unsafe('lock table app_private.notification_announcements, app_private.notification_events, app_private.notification_read_receipts, app_private.community_reports in share row exclusive mode');
  const current=await readAncillaryTarget(tx);
  for(const key of ['announcements','events','readReceipts','reports'] as const)if(!same(sorted(current[key]),sorted(plan.baseline[key])))throw new Error('ancillary_target_changed:'+key);
  for(const r of plan.announcements)await tx`insert into app_private.notification_announcements(id,request_id,author_id,status,revision,data,published_at,expires_at,created_at,updated_at) values(${r.id},${r.request_id},${r.author_id},${r.status},${r.revision},${tx.json(r.data)},${r.published_at},${r.expires_at},${r.created_at},${r.updated_at})`;
  for(const r of plan.events)await tx`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id,room_id,visible,data,created_at) values(${r.id},${r.event_type},${r.source_id},${r.actor_id},${r.recipient_id},null,${r.visible},${tx.json(r.data)},${r.created_at})`;
  for(const r of plan.readReceipts)await tx`insert into app_private.notification_read_receipts(user_id,notification_key,read_at) values(${r.user_id},${r.notification_key},${r.read_at}) on conflict(user_id,notification_key) do update set read_at=greatest(notification_read_receipts.read_at,excluded.read_at)`;
  for(const r of plan.reports)await tx`insert into app_private.community_reports(id,reporter_user_id,reported_user_id,comment_id,report_type,reason,details,content_snapshot,status,data,created_at,updated_at) values(${r.id},${r.reporter_user_id},${r.reported_user_id},${r.comment_id},${r.report_type},${r.reason},${r.details},${r.content_snapshot},${r.status},${tx.json(r.data)},${r.created_at},${r.updated_at})`;
  for(const r of plan.provenance)await tx`insert into app_private.bulk_migration_rows(source_key,entity,source_id,source_digest,target_id,disposition) values(${plan.sourceKey},${r.entity},${r.source_id},${r.source_digest},${r.target_id},${r.disposition}) on conflict(source_key,entity,source_id) do nothing`;
  return plan.counts;
}

import { buildAncillaryPlan, applyAncillaryPlan, readAncillaryTarget, assertAncillaryPlanReady, type AncillaryTarget } from './ancillary.ts';
import { mappedUUID, type CorePlan, type SourceSnapshot, type Row } from './core.ts';
import { canonical, digest } from '../../supabase/functions/app-services/integration-crypto.ts';

function assert(v:unknown,message='assertion failed'):asserts v {if(!v)throw new Error(message);}
async function rejects(work:()=>Promise<unknown>,code:string) {
  try{await work();}catch(error){assert(error instanceof Error&&error.message.startsWith(code),'unexpected safe error');return;}
  throw new Error('expected rejection');
}
const now='2026-10-19T12:00:00.000Z';
const alice='00000000-0000-5000-a000-000000000001',bob='00000000-0000-5000-a000-000000000002';
const target=():AncillaryTarget=>({announcements:[],events:[],readReceipts:[],reports:[]});
function fixture():{snapshot:SourceSnapshot;core:CorePlan} {
  const source={origin:'https://spyclash.com',appID:'69a0e57fa939f578082f8091'};
  const snapshot:SourceSnapshot={version:1,source,capturedAt:now,digest:'test-snapshot',entities:Object.fromEntries(['NotificationAnnouncement','NotificationReadReceipt','PushNotificationEvent','CommunityReport','RoomInvite','GameRoom','Friendship'].map(e=>[e,[]]))};
  const core={version:1,sourceKey:source.origin+'/'+source.appID,source,sourceDigest:snapshot.digest,capturedAt:now,accounts:[{legacy_user_id:'alice',user_id:alice},{legacy_user_id:'bob',user_id:bob}],baseline:{bulkRows:[],friendships:[]},friendships:[],dispositions:[]} as unknown as CorePlan;
  return {snapshot,core};
}
async function friendEvent(snapshot:SourceSnapshot,core:CorePlan,change:Row={}) {
  const friend={id:'friend',requester_id:'alice',addressee_id:'bob',status:'pending',request_event_id:'request'};
  const id=await mappedUUID(core.sourceKey,'Friendship',friend.id),eventID=await mappedUUID(core.sourceKey,'FriendRequestEvent',friend.request_event_id);
  snapshot.entities.Friendship.push(friend);
  core.friendships.push({...friend,id,requester_id:alice,addressee_id:bob,request_event_id:eventID});
  core.dispositions.push({entity:'Friendship',source_id:friend.id,target_id:id,action:'import'});
  const event={id:'event',event_type:'friend_request',source_event_id:'request',actor_user_id:'alice',recipient_user_id:'bob',inbox_visible:true,inbox_committed_at:'2026-10-18T08:00:00',inbox_projection_version:1,inbox_kind:'friend_request',inbox_title_en:'Friend request',inbox_body_en:'Alice wants to connect.',inbox_title_ru:'Запрос',inbox_published_at:'2026-10-18T08:00:00',state:'no_devices',...change};
  snapshot.entities.PushNotificationEvent.push(event);
  return {friend,event,id,eventID};
}
const announcement=(change:Row={})=>({id:'notice',status:'published',topic:'developer',importance:'quiet',title_en:'Release',body_en:'Release details',created_by_id:'alice',published_at:'2026-10-18T09:00:00',...change});
const report=(change:Row={})=>({id:'report',reporter_user_id:'alice',reported_user_id:'bob',report_type:'user',reason:'harassment',status:'open',details:'Details',content_snapshot:'Original content',...change});

Deno.test('pending personal inbox item and read receipt share the authoritative request event ID',async()=>{
  const {snapshot,core}=fixture();const {eventID,id}=await friendEvent(snapshot,core);
  snapshot.entities.NotificationReadReceipt.push({id:'receipt',user_id:'bob',notification_key:'personal:event',read_at:'2026-10-18T10:00:00'});
  const plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
  assert(plan.events.length===1&&plan.events[0].id===eventID&&plan.events[0].source_id===id&&plan.events[0].visible===true);
  assert(plan.events[0].created_at==='2026-10-18T08:00:00.000Z');
  assert(plan.events[0].data.title_ru==='Запрос');
  assert(plan.readReceipts[0].notification_key==='personal:'+eventID&&plan.readReceipts[0].read_at==='2026-10-18T10:00:00.000Z');
  assert(!('state' in plan.events[0])&&!('attempt_count' in plan.events[0]));
});
Deno.test('accepted requests, cancelled delivery and uncommitted projections stay hidden',async()=>{
  for(const state of ['accepted','cancelled','uncommitted']) {
    const {snapshot,core}=fixture();const {friend,event}=await friendEvent(snapshot,core);
    if(state==='accepted'){friend.status='accepted';core.friendships[0].status='accepted';}
    if(state==='cancelled')event.state='cancelled';
    if(state==='uncommitted')delete (event as Row).inbox_committed_at;
    const plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
    assert(plan.events.length===1&&!plan.events[0].visible,state);
  }
});
Deno.test('a current target request is preserved when its request event supersedes the source',async()=>{
  const {snapshot,core}=fixture();await friendEvent(snapshot,core);core.friendships[0].request_event_id='00000000-0000-5000-a000-000000000099';
  const plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
  assert(!plan.events[0].visible&&plan.warnings.some(x=>x.code==='current_target_request_preserved'));
});
Deno.test('visible personal items that cannot be bound safely block migration; old transport is archived',async()=>{
  const {snapshot,core}=fixture();const {event}=await friendEvent(snapshot,core);event.source_event_id='';
  let plan=await buildAncillaryPlan(snapshot,core,target());assert(plan.issues.some(x=>x.code==='visible_personal_event_unmapped'));
  event.event_type='game_finished';plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
  assert(!plan.events.length&&plan.dispositions[0].action==='archive_only');
});
Deno.test('read watermarks never move backwards and absent owners remain archived',async()=>{
  const {snapshot,core}=fixture(),existing=target();
  existing.readReceipts.push({user_id:bob,notification_key:'__all__:personal',read_at:'2026-10-19T10:00:00.000Z'});
  snapshot.entities.NotificationReadReceipt.push(
    {id:'old',user_id:'bob',notification_key:'__all__:personal',read_at:'2026-10-18T10:00:00Z'},
    {id:'latest',user_id:'bob',notification_key:'__all__',read_at:'2026-10-19T11:00:00Z'},
    {id:'earlier',user_id:'bob',notification_key:'__all__',read_at:'2026-10-17T11:00:00Z'},
    {id:'deleted-owner',user_id:'gone',notification_key:'__all__',read_at:'2026-10-19T11:00:00Z'});
  const plan=await buildAncillaryPlan(snapshot,core,existing);assertAncillaryPlanReady(plan);
  assert(plan.readReceipts.length===1&&plan.readReceipts[0].notification_key==='__all__'&&plan.readReceipts[0].read_at==='2026-10-19T11:00:00.000Z');
  assert(plan.dispositions.some(d=>d.source_id==='deleted-owner'&&d.action==='archive_only'));
});
Deno.test('announcements preserve withdrawal, indefinite expiry and publication timestamps',async()=>{
  const {snapshot,core}=fixture();snapshot.entities.NotificationAnnouncement.push(announcement(),announcement({id:'withdrawn',status:'withdrawn',published_at:null,expires_at:'2026-09-02T11:00:00Z',created_by_id:'gone'}));
  const plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
  assert(plan.announcements[0].expires_at==='9999-12-31T23:59:59.000Z'&&plan.announcements[0].published_at==='2026-10-18T09:00:00.000Z');
  assert(plan.announcements[1].status==='withdrawn'&&plan.announcements[1].published_at===null&&plan.announcements[1].data.legacy_author_unmapped===true);
  assert(!core.accounts.some(a=>a.user_id===plan.announcements[1].author_id));
});
Deno.test('provenance preserves target edits and target deletion; changed source is a conflict',async()=>{
  const {snapshot,core}=fixture();const row=announcement();snapshot.entities.NotificationAnnouncement.push(row);
  const id=await mappedUUID(core.sourceKey,'NotificationAnnouncement',row.id);
  core.baseline.bulkRows.push({source_key:core.sourceKey,entity:'NotificationAnnouncement',source_id:row.id,source_digest:await digest(canonical(row)),target_id:id,disposition:'import'});
  const existing=target();existing.announcements.push({id,status:'withdrawn',data:{body_en:'New user edit'}});
  let plan=await buildAncillaryPlan(snapshot,core,existing);assertAncillaryPlanReady(plan);assert(!plan.announcements.length);
  plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);assert(!plan.announcements.length);
  row.body_en='Later source edit';plan=await buildAncillaryPlan(snapshot,core,target());
  assert(plan.issues.some(x=>x.code==='ancillary_source_changed_after_import'));
});
Deno.test('untracked collisions block instead of overwriting announcements and personal events',async()=>{
  const {snapshot,core}=fixture();const {eventID}=await friendEvent(snapshot,core);snapshot.entities.NotificationAnnouncement.push(announcement());
  const existing=target();existing.announcements.push({id:await mappedUUID(core.sourceKey,'NotificationAnnouncement','notice')});existing.events.push({id:eventID});
  const plan=await buildAncillaryPlan(snapshot,core,existing);
  assert(plan.issues.some(x=>x.code==='untracked_announcement_collision')&&plan.issues.some(x=>x.code==='untracked_personal_event_collision'));
});
Deno.test('moderation reports keep deleted principal evidence without fabricating an account',async()=>{
  const {snapshot,core}=fixture();snapshot.entities.CommunityReport.push(report({reported_user_id:'deleted-user',status:'actioned'}));
  const plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);
  assert(plan.reports[0].reporter_user_id===alice&&plan.reports[0].reported_user_id===null&&plan.reports[0].data.legacy_reported_user_id==='deleted-user');
  assert(plan.reports[0].status==='actioned'&&plan.reports[0].content_snapshot==='Original content');
});
Deno.test('duplicate open moderation cases require review instead of silent collapse',async()=>{
  const {snapshot,core}=fixture();snapshot.entities.CommunityReport.push(report(),report({id:'second'}));
  const plan=await buildAncillaryPlan(snapshot,core,target());assert(plan.issues.some(x=>x.code==='open_report_pair_conflict'));
});
Deno.test('terminal room invites are explicitly archived and actionable live handoff is blocked',async()=>{
  const {snapshot,core}=fixture();snapshot.entities.RoomInvite.push({id:'old',status:'expired',room_id:'missing'});
  let plan=await buildAncillaryPlan(snapshot,core,target());assertAncillaryPlanReady(plan);assert(plan.dispositions[0].reason==='terminal_invite');
  snapshot.entities.GameRoom.push({id:'room',status:'waiting'});snapshot.entities.RoomInvite.push({id:'pending',status:'pending',room_id:'room'});
  plan=await buildAncillaryPlan(snapshot,core,target());assert(plan.issues.some(x=>x.code==='actionable_source_room_invite_requires_handoff'));
  snapshot.entities.GameRoom[0].status='playing';plan=await buildAncillaryPlan(snapshot,core,target());assert(plan.issues.some(x=>x.code==='active_source_room_requires_handoff'));
});
Deno.test('apply rechecks all target rows before writes and never calls notification delivery',async()=>{
  const {snapshot,core}=fixture();snapshot.entities.NotificationAnnouncement.push(announcement());
  const plan=await buildAncillaryPlan(snapshot,core,target()),queries:string[]=[];
  let drift=false;
  const tx:any=async (strings:TemplateStringsArray)=>{const query=strings.join('?');queries.push(query);return drift&&query.includes('from app_private.notification_announcements')?[{value:{id:'concurrent-change'}}]:[];};
  tx.unsafe=async(query:string)=>{queries.push(query);return [];};tx.json=(value:unknown)=>value;
  drift=true;await rejects(()=>applyAncillaryPlan(tx,plan),'ancillary_target_changed:announcements');assert(!queries.some(q=>q.startsWith('insert')));
  queries.length=0;drift=false;await applyAncillaryPlan(tx,plan);
  assert(queries.some(q=>q.startsWith('insert into app_private.notification_announcements')));
  assert(queries.every(q=>!q.includes('push_outbox')&&!q.includes('push_jobs')&&!q.includes('app_signals')));
});
Deno.test('target snapshots preserve PostgreSQL timestamp precision for reviewed baseline comparison',async()=>{
  const timestamp='2026-10-19T08:00:00.123456+00:00';
  const db=async(strings:TemplateStringsArray)=>{const sql=strings.join('?');assert(sql.includes('to_jsonb(t)'));return sql.includes('notification_events')?[{value:{id:'event',created_at:timestamp}}]:[];};
  const rows=await readAncillaryTarget(db);assert(rows.events[0].created_at===timestamp);
});

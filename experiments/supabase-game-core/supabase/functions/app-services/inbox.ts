import { AppServiceError, type AppContext, requireUUID } from './contracts.ts';
import { clean, ensureProfile, isAppAdmin, signalUsers } from './profile.ts';
import { enqueueAppPush, cancelAppPush } from './push.ts';
import { safeCommunityDisplayName } from './policies/community-safety.ts';
import { announcementCopy, decodeCursor, encodeCursor, INBOX_EPOCH, INBOX_RETENTION_MS, language, localizedAnnouncement, optionalActionDeepLink, optionalExpiry, requireImportance, requireTopic, NotificationContractError } from './policies/notification-contracts.ts';

type PersonalInput={id:string,event_type:'friend_request'|'room_invite',source_id:string,actor_id:string,recipient_id:string,room_id?:string,actor_name:unknown};
function copyFor(event:PersonalInput):any {
  const actor=safeCommunityDisplayName(event.actor_name);
  const copies=event.event_type==='friend_request'?{
    en:['New friend request',`${actor} wants to connect.`],ru:['Новый запрос в друзья',`${actor} хочет добавить вас в друзья.`],es:['Nueva solicitud de amistad',`${actor} quiere conectar contigo.`],uk:['Новий запит у друзі',`${actor} хоче додати вас у друзі.`]
  }:{en:['Game invitation',`${actor} invited you to a SpyClash room.`],ru:['Приглашение в игру',`${actor} приглашает вас в комнату SpyClash.`],es:['Invitación al juego',`${actor} te invitó a una sala de SpyClash.`],uk:['Запрошення до гри',`${actor} запрошує вас до кімнати SpyClash.`]};
  return {...Object.fromEntries(Object.entries(copies).flatMap(([locale,[title,body]])=>[[`title_${locale}`,title],[`body_${locale}`,body]])),title:copies.en[0],body:copies.en[1],deep_link:event.event_type==='friend_request'?'spyclash://community/requests':'spyclash://community/invites',importance:'important',actor_name:actor,notification_event_id:event.id,source_id:event.source_id};
}
export async function enqueuePersonalNotification(ctx:AppContext,event:PersonalInput):Promise<void> {
  const data=copyFor(event);
  await ctx.tx`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id,room_id,data,created_at) values(${event.id},${event.event_type},${event.source_id},${event.actor_id},${event.recipient_id},${event.room_id||null},${ctx.tx.json(data)},${ctx.now}) on conflict(id) do nothing`;
  await enqueueAppPush(ctx,{...event,data});
}
export async function hidePersonalNotifications(ctx:AppContext,filter:{ids?:string[],pair?:string[]}):Promise<void> {
  let rows:any[]=[];
  if(filter.ids?.length) rows=await ctx.tx`update app_private.notification_events set visible=false where id=any(${filter.ids}::uuid[]) returning id,recipient_id`;
  if(filter.pair?.length===2) {
    const [a,b]=filter.pair;
    rows.push(...await ctx.tx`update app_private.notification_events set visible=false where (actor_id=${a} and recipient_id=${b}) or (actor_id=${b} and recipient_id=${a}) returning id,recipient_id`);
  }
  await cancelAppPush(ctx,rows.map(r=>r.id));
  await signalUsers(ctx,rows.map(r=>r.recipient_id));
}
function scope(value:unknown):'all'|'personal'|'global' {
  const v=clean(value)||'all';
  if(!['all','personal','global'].includes(v)) throw new AppServiceError('invalid_scope','Inbox scope is invalid.',422);
  return v as any;
}
function globalItem(row:any,locale:string):any {
  return {id:'global:'+row.id,scope:'global',kind:row.data.topic||'developer',importance:row.data.importance,...localizedAnnouncement(row.data,locale),published_at:new Date(row.published_at||row.created_at).toISOString(),read_at:null,action_deep_link:row.data.action_deep_link||'spyclash://notifications'};
}
function personalItem(row:any,locale:string):any {
  return {id:'personal:'+row.id,scope:'personal',kind:row.event_type,importance:row.data.importance||'important',title:clean(row.data['title_'+locale]||row.data.title_en).slice(0,80),body:clean(row.data['body_'+locale]||row.data.body_en).slice(0,800),published_at:new Date(row.created_at).toISOString(),read_at:null,action_deep_link:row.data.deep_link};
}
async function visibleItems(ctx:AppContext,locale:string):Promise<any[]> {
  const earliest=new Date(Math.max(Date.parse(INBOX_EPOCH),ctx.now.getTime()-INBOX_RETENTION_MS));
  const globals=await ctx.tx`select * from app_private.notification_announcements where status='published' and published_at<=${ctx.now} and published_at>=${earliest} and expires_at>${ctx.now} order by published_at desc,id limit 500`;
  // Recheck the authoritative source so a removed friend, joined/closed room,
  // deleted user or block cannot remain actionable through a stale projection.
  const personals=await ctx.tx`select e.* from app_private.notification_events e
    join app_private.profiles author on author.user_id=e.actor_id and author.state='active'
    where e.recipient_id=${ctx.actor.id} and e.visible and e.created_at>=${earliest} and e.created_at<=${ctx.now}
    and not exists(select 1 from app_private.friendships b where b.pair_low=least(e.actor_id,e.recipient_id) and b.pair_high=greatest(e.actor_id,e.recipient_id) and b.status='blocked')
    and ((e.event_type='friend_request' and exists(select 1 from app_private.friendships f where f.id=e.source_id and f.request_event_id=e.id and f.status='pending' and f.addressee_id=e.recipient_id))
      or (e.event_type='room_invite' and exists(select 1 from app_private.room_invites i
        join full_game_private.rooms r on r.id=i.room_id and not r.closed and r.state->>'status'='waiting'
        join app_private.friendships f on f.pair_low=least(i.sender_user_id,i.recipient_user_id) and f.pair_high=greatest(i.sender_user_id,i.recipient_user_id) and f.status='accepted'
        join full_game_private.members m on m.room_id=i.room_id and m.user_id=i.sender_user_id
        where i.id=e.source_id and i.notification_event_id=e.id and i.status in ('pending','accepted') and not exists(select 1 from full_game_private.members already where already.room_id=i.room_id and already.user_id=i.recipient_user_id))))
    order by e.created_at desc,e.id limit 500`;
  const items=[...globals.map((r:any)=>globalItem(r,locale)),...personals.map((r:any)=>personalItem(r,locale))];
  const keys=['__all__','__all__:global','__all__:personal',...items.map(i=>i.id)];
  const receipts=await ctx.tx`select notification_key,read_at from app_private.notification_read_receipts where user_id=${ctx.actor.id} and notification_key=any(${keys}::text[])`;
  const marks=new Map(receipts.map((r:any)=>[r.notification_key,new Date(r.read_at).toISOString()]));
  return items.map(i=>({...i,read_at:[marks.get(i.id),marks.get('__all__'),marks.get('__all__:'+i.scope)].filter((m):m is string=>typeof m==='string'&&m>=i.published_at).sort().at(-1)||null})).sort((a,b)=>b.published_at.localeCompare(a.published_at)||a.id.localeCompare(b.id));
}
function unread(items:any[]):any {
  const global=items.filter(i=>i.scope==='global'&&!i.read_at).length,personal=items.filter(i=>i.scope==='personal'&&!i.read_at).length;
  return {global,personal,total:global+personal};
}
async function publishFanout(ctx:AppContext,row:any):Promise<void> {
  if(row.data.importance!=='important') return;
  const recipients=await ctx.tx`select p.user_id from app_private.profiles p where p.state='active' and exists(select 1 from app_private.push_registrations r where r.user_id=p.user_id and r.active and r.kind='device' and r.alert_authorized)`;
  for(const recipient of recipients) {
    const data={...row.data,title:row.data.title_en,body:row.data.body_en,deep_link:row.data.action_deep_link,announcement_id:row.id,announcement_revision:row.revision};
    await enqueueAppPush(ctx,{id:row.id,event_type:'global_announcement',recipient_id:recipient.user_id,actor_id:ctx.actor.id,data});
  }
}
async function mutateAnnouncement(ctx:AppContext,body:any,locale:string):Promise<any> {
  const action=clean(body.action); let row:any;
  if(action==='create_draft'||action==='publish_global') {
    const requestID=requireUUID(body.request_id,'request_id');
    await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'app:announcement-request:'+requestID},0))`;
    [row]=await ctx.tx`select * from app_private.notification_announcements where request_id=${requestID}`;
    const data={topic:requireTopic(body.topic||'developer'),importance:requireImportance(body.importance||'quiet'),...announcementCopy({...body,title_en:body.title_en??body.title,body_en:body.body_en??body.body}),action_deep_link:optionalActionDeepLink(body.action_deep_link),expires_at:optionalExpiry(body.expires_at||(row?new Date(row.expires_at).toISOString():undefined),ctx.now)};
    if(row) {
      if(row.author_id!==ctx.actor.id||JSON.stringify(row.data)!==JSON.stringify(data)) {
        // PostgreSQL JSONB key order differs from input; compare field values.
        if(row.author_id!==ctx.actor.id||Object.keys(data).some(key=>String(row.data[key]??'')!==String((data as any)[key]??''))) throw new AppServiceError('idempotency_conflict','request_id was already used with different content.',409);
      }
    } else [row]=await ctx.tx`insert into app_private.notification_announcements(request_id,author_id,status,revision,data,expires_at,created_at,updated_at) values(${requestID},${ctx.actor.id},'draft',${crypto.randomUUID()},${ctx.tx.json(data)},${new Date(data.expires_at)},${ctx.now},${ctx.now}) returning *`;
    if(action==='create_draft') return {ok:true,announcement_id:row.id,status:row.status,revision:row.revision};
  } else {
    const id=requireUUID(body.announcement_id,'announcement_id');
    [row]=await ctx.tx`select * from app_private.notification_announcements where id=${id} for update`;
    if(!row) throw new AppServiceError('not_found','Announcement not found.',404);
    if(!clean(body.expected_revision)) throw new AppServiceError('missing_expected_revision','expected_revision is required.',428);
    if((action==='publish'&&row.status!=='published')||(action==='withdraw'&&row.status!=='withdrawn')) {
      if(clean(body.expected_revision)!==row.revision) throw new AppServiceError('cas_conflict','Announcement changed. Reload and retry.',409);
    }
  }
  if(action==='withdraw') {
    if(row.status!=='withdrawn') {
      if(row.status!=='published') throw new AppServiceError('invalid_state','Announcement cannot be withdrawn.',409);
      [row]=await ctx.tx`update app_private.notification_announcements set status='withdrawn',revision=${crypto.randomUUID()},updated_at=${ctx.now} where id=${row.id} returning *`;
    }
    await cancelAppPush(ctx,[row.id]);
    return {ok:true,announcement_id:row.id,status:row.status,revision:row.revision};
  }
  if(row.status!=='published') {
    if(row.status!=='draft') throw new AppServiceError('invalid_state','Announcement was withdrawn.',409);
    if(new Date(row.expires_at)<=ctx.now) throw new AppServiceError('announcement_expired','Announcement has expired.',409);
    [row]=await ctx.tx`update app_private.notification_announcements set status='published',published_at=${ctx.now},revision=${crypto.randomUUID()},updated_at=${ctx.now} where id=${row.id} returning *`;
    await publishFanout(ctx,row);
  }
  return {ok:true,item:globalItem(row,locale),unread:unread(await visibleItems(ctx,locale)),...(action==='publish_global'?{request_id:row.request_id}:{}),revision:row.revision};
}
export async function dispatchInbox(ctx:AppContext,body:any):Promise<any> {
  try { return await dispatchInboxAction(ctx,body); }
  catch(error) {
    if(error instanceof NotificationContractError) throw new AppServiceError(error.code,error.message,error.status);
    throw error;
  }
}
async function dispatchInboxAction(ctx:AppContext,body:any):Promise<any> {
  const profile=await ensureProfile(ctx),locale=language(body.locale||profile.data.language),action=clean(body.action);
  if(['summary','list','mark_read','mark_all_read'].includes(action)) {
    const items=await visibleItems(ctx,locale);
    if(action==='summary') return {ok:true,unread:unread(items),server_time:ctx.now.toISOString()};
    if(action==='list') {
      const selected=scope(body.scope),cursor=decodeCursor(body.cursor),limit=Math.max(1,Math.min(50,parseInt(String(body.limit))||30));
      const candidates=items.filter(i=>(selected==='all'||i.scope===selected)&&(!cursor||i.published_at<cursor[0]||(i.published_at===cursor[0]&&i.id>cursor[1]))),page=candidates.slice(0,limit);
      return {ok:true,scope:selected,items:page,unread:unread(items),next_cursor:candidates.length>limit&&page.length?encodeCursor(page.at(-1).published_at,page.at(-1).id):null};
    }
    const selected=action==='mark_all_read'?scope(body.scope):null,key=selected?(selected==='all'?'__all__':'__all__:'+selected):clean(body.item_id);
    const item=selected?null:items.find(i=>i.id===key);
    if(!selected&&!item) throw new AppServiceError('notification_not_found','Notification is unavailable.',404);
    await ctx.tx`insert into app_private.notification_read_receipts(user_id,notification_key,read_at) values(${ctx.actor.id},${key},${ctx.now}) on conflict(user_id,notification_key) do update set read_at=greatest(notification_read_receipts.read_at,excluded.read_at)`;
    await signalUsers(ctx,[ctx.actor.id]);
    return {ok:true,...(item?{item:{...item,read_at:ctx.now.toISOString()}}:{}),unread:unread(await visibleItems(ctx,locale))};
  }
  if(!['create_draft','publish_global','publish','withdraw'].includes(action)) throw new AppServiceError('unsupported_inbox_action','Unsupported notification action.');
  if(!isAppAdmin(ctx,profile)) throw new AppServiceError('forbidden','Forbidden.',403);
  return await mutateAnnouncement(ctx,body,locale);
}

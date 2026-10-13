import { AppServiceError, type AppContext, requireUUID } from './contracts.ts';
import { activeProfile, clean, dispatchProfile, ensureProfile, projectedProfiles, signalProfile, signalUsers } from './profile.ts';
import { normalizeSpyID, profileMatchesCommunityQuery, sanitizeProfileComment } from './policies/community.ts';
import { normalizeCommunityReportReason, requireSafeCommunityText, safeCommunityTextForDisplay, sanitizeCommunityReportDetails, ObjectionableCommunityContentError } from './policies/community-safety.ts';
import { friendshipDecisionDisposition, roomInviteAcceptanceDisposition } from './policies/mutation-idempotency.ts';
import { enqueuePersonalNotification, hidePersonalNotifications } from './inbox.ts';

const opposite=(row:any,id:string)=>row.requester_id===id?row.addressee_id:row.requester_id;
const summary=(row:any,id:string)=>row?{id:row.id,status:row.status,direction:row.requester_id===id?'outgoing':'incoming'}:null;
const iso=(value:any)=>new Date(value).toISOString();
async function relationship(ctx:AppContext,a:string,b:string):Promise<any> {
  const [row]=await ctx.tx`select * from app_private.friendships where pair_low=least(${a}::uuid,${b}::uuid) and pair_high=greatest(${a}::uuid,${b}::uuid)`;
  return row||null;
}
async function relationships(ctx:AppContext,id:string):Promise<any[]> {
  return await ctx.tx`select * from app_private.friendships where requester_id=${id} or addressee_id=${id} order by updated_at desc,id`;
}
async function lockPair(ctx:AppContext,a:string,b:string):Promise<void> {
  const ids=[a,b].sort();
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'app:pair:'+ids.join(':')},0))`;
  // Opposes account deletion through the row lock while inspecting both sides.
  const rows=await ctx.tx`select user_id from app_private.profiles where user_id=any(${ids}::uuid[]) and state='active' order by user_id for share`;
  if(rows.length!==new Set(ids).size) throw new AppServiceError('profile_not_found','Operative not found.',404);
}
function requireUnblocked(row:any,status=403):void {
  if(row?.status==='blocked') throw new AppServiceError('interaction_unavailable',status===404?'Operative not found.':'Interaction unavailable.',status);
}
async function profileMap(ctx:AppContext,ids:string[]):Promise<Map<string,any>> {
  const unique=[...new Set(ids)]; if(!unique.length) return new Map();
  const rows=await ctx.tx`select * from app_private.profiles where user_id=any(${unique}::uuid[]) and state='active'`;
  return new Map((await projectedProfiles(ctx,rows)).map(p=>[p.id,p]));
}
async function targetProfile(ctx:AppContext,body:any):Promise<any> {
  if(clean(body.target_user_id)) return await activeProfile(ctx,body.target_user_id);
  const spyID=normalizeSpyID(body.spy_id);
  if(!spyID) throw new AppServiceError('invalid_spy_id','Invalid SPY ID.',422);
  const [row]=await ctx.tx`select * from app_private.profiles where spy_id=${spyID} and state='active'`;
  if(!row) throw new AppServiceError('profile_not_found','Operative not found.',404);
  return row;
}
async function visibleInvites(ctx:AppContext):Promise<any[]> {
  const rows=await ctx.tx`select i.* from app_private.room_invites i
    join app_private.friendships f on f.pair_low=least(i.sender_user_id,i.recipient_user_id) and f.pair_high=greatest(i.sender_user_id,i.recipient_user_id) and f.status='accepted'
    join full_game_private.rooms r on r.id=i.room_id and not r.closed and r.state->>'status'='waiting'
    join full_game_private.members m on m.room_id=r.id and m.user_id=i.sender_user_id
    where i.recipient_user_id=${ctx.actor.id} and i.status in ('pending','accepted')
    and not exists(select 1 from full_game_private.members already where already.room_id=r.id and already.user_id=i.recipient_user_id)
    order by i.created_at desc,i.id`;
  const profiles=await profileMap(ctx,rows.map((r:any)=>r.sender_user_id));
  return rows.filter((r:any)=>profiles.has(r.sender_user_id)).map((r:any)=>({id:r.id,status:r.status,room_id:r.room_id,room_code:r.room_code,created_at:iso(r.created_at),sender:profiles.get(r.sender_user_id)}));
}
export async function communityState(ctx:AppContext):Promise<any> {
  const me=await ensureProfile(ctx),rows=await relationships(ctx,ctx.actor.id);
  const profiles=await profileMap(ctx,[ctx.actor.id,...rows.map(r=>opposite(r,ctx.actor.id))]);
  const groups:any={friends:[],incoming:[],outgoing:[],blocked:[]};
  for(const r of rows) {
    const profile=profiles.get(opposite(r,ctx.actor.id)); if(!profile) continue;
    const group=r.status==='accepted'?'friends':r.status==='pending'?(r.requester_id===ctx.actor.id?'outgoing':'incoming'):r.status==='blocked'&&r.blocked_by_id===ctx.actor.id?'blocked':null;
    if(group) groups[group].push({...summary(r,ctx.actor.id),profile});
  }
  return {me:profiles.get(me.user_id),...groups,incoming_room_invites:await visibleInvites(ctx)};
}
async function detail(ctx:AppContext,target:any):Promise<any> {
  const ownID=ctx.actor.id;
  await lockPair(ctx,ownID,target.user_id);
  const rel=target.user_id===ownID?null:await relationship(ctx,ownID,target.user_id);
  requireUnblocked(rel,404);
  await ctx.tx`insert into app_private.profile_watchers(viewer_id,profile_id,last_seen_at) values(${ownID},${target.user_id},${ctx.now}) on conflict(viewer_id,profile_id) do update set last_seen_at=excluded.last_seen_at`;
  const viewer=await relationships(ctx,ownID),targetRows=target.user_id===ownID?viewer:await relationships(ctx,target.user_id);
  const blocked=new Set([...viewer.filter(r=>r.status==='blocked').map(r=>opposite(r,ownID)),...targetRows.filter(r=>r.status==='blocked').map(r=>opposite(r,target.user_id))]);
  const friendIDs=targetRows.filter(r=>r.status==='accepted'&&!blocked.has(opposite(r,target.user_id))).slice(0,60).map(r=>opposite(r,target.user_id));
  const comments=await ctx.tx`select * from app_private.profile_comments where target_user_id=${target.user_id} order by created_at desc,id`;
  const visible=comments.filter((r:any)=>!blocked.has(r.author_user_id)&&safeCommunityTextForDisplay(r.body,'')).slice(0,40);
  const profiles=await profileMap(ctx,[target.user_id,...friendIDs,...visible.map((c:any)=>c.author_user_id)]);
  return {profile:profiles.get(target.user_id),is_self:target.user_id===ownID,relationship:summary(rel,ownID),friends:friendIDs.map(id=>profiles.get(id)).filter(Boolean),comments:visible.filter((c:any)=>profiles.has(c.author_user_id)).map((c:any)=>({id:c.id,body:safeCommunityTextForDisplay(c.body,''),created_at:iso(c.created_at),author:profiles.get(c.author_user_id),can_delete:c.author_user_id===ownID||c.target_user_id===ownID}))};
}
async function directory(ctx:AppContext,body:any):Promise<any> {
  const rows=await relationships(ctx,ctx.actor.id),blocked=new Set(rows.filter(r=>r.status==='blocked').map(r=>opposite(r,ctx.actor.id)));
  const candidates=await ctx.tx`select * from app_private.profiles where state='active' order by created_at desc,user_id`;
  const exact=normalizeSpyID(body.query),query=clean(body.query),offset=Math.min(1000000,Math.max(0,parseInt(String(body.offset))||0)),limit=Math.min(60,Math.max(1,parseInt(String(body.limit))||24));
  const filtered=candidates.filter((p:any)=>!blocked.has(p.user_id)&&(exact?p.spy_id===exact:!query||profileMatchesCommunityQuery({...p.data,spy_id:p.spy_id},query)));
  return {profiles:await projectedProfiles(ctx,exact?filtered:filtered.slice(offset,offset+limit)),next_offset:!exact&&offset+limit<filtered.length?offset+limit:null};
}
async function validateInviteRoom(ctx:AppContext,roomID:unknown,roomCode:unknown,sender:string,recipient:string):Promise<any> {
  const [room]=await ctx.tx`select * from full_game_private.rooms where id=${requireUUID(roomID,'room_id')} for share`;
  if(!room||room.closed||clean(roomCode).toUpperCase()!==room.code) throw new AppServiceError('room_not_found','Room not found.',404);
  if(room.state.status!=='waiting') throw new AppServiceError('room_unavailable','Room is no longer accepting invites.',409);
  const members=await ctx.tx`select user_id from full_game_private.members where room_id=${room.id}`;
  if(!members.some((m:any)=>m.user_id===sender)) throw new AppServiceError('not_member','Join the room before inviting operatives.',403);
  if(members.some((m:any)=>m.user_id===recipient)) throw new AppServiceError('already_member','Operative is already in this room.',409);
  return room;
}
export async function dispatchCommunity(ctx:AppContext,body:any):Promise<any> {
  try { return await dispatchCommunityAction(ctx,body); }
  catch(error) {
    if(error instanceof ObjectionableCommunityContentError) throw new AppServiceError(error.code,error.message,error.status);
    throw error;
  }
}
async function dispatchCommunityAction(ctx:AppContext,body:any):Promise<any> {
  const action=clean(body.action),id=ctx.actor.id;
  const me=await ensureProfile(ctx);
  if(action==='state') return await communityState(ctx);
  if(action==='directory') return await directory(ctx,body);
  if(action==='update_profile'||action==='set_radar_invite_policy') return await dispatchProfile(ctx,body);
  if(action==='search'||action==='profile') {
    const target=await targetProfile(ctx,body);
    if(action==='profile') return await detail(ctx,target);
    const rel=target.user_id===id?null:await relationship(ctx,id,target.user_id); requireUnblocked(rel,404);
    return {profile:(await projectedProfiles(ctx,[target]))[0],is_self:target.user_id===id,relationship:summary(rel,id)};
  }
  if(['send_request','block','add_comment','invite_to_room'].includes(action)) {
    const target=await targetProfile(ctx,body),targetID=target.user_id;
    if(targetID===id) throw new AppServiceError('self_interaction','This action requires another operative.',409);
    await lockPair(ctx,id,targetID);
    const rel=await relationship(ctx,id,targetID);
    if(action==='block') {
      if(rel?.status==='blocked'&&rel.blocked_by_id!==id) throw new AppServiceError('interaction_unavailable','Interaction unavailable.',403);
      if(rel) await ctx.tx`update app_private.friendships set status='blocked',blocked_by_id=${id},updated_at=${ctx.now} where id=${rel.id}`;
      else await ctx.tx`insert into app_private.friendships(requester_id,addressee_id,status,blocked_by_id,created_at,updated_at) values(${id},${targetID},'blocked',${id},${ctx.now},${ctx.now})`;
      await ctx.tx`delete from app_private.profile_comments where (author_user_id=${id} and target_user_id=${targetID}) or (author_user_id=${targetID} and target_user_id=${id})`;
      await ctx.tx`delete from app_private.room_invites where (sender_user_id=${id} and recipient_user_id=${targetID}) or (sender_user_id=${targetID} and recipient_user_id=${id})`;
      await hidePersonalNotifications(ctx,{pair:[id,targetID]});
      await signalUsers(ctx,[id,targetID]); await signalProfile(ctx,id); await signalProfile(ctx,targetID);
      return await communityState(ctx);
    }
    requireUnblocked(rel);
    if(action==='send_request') {
      if(rel?.status==='accepted') throw new AppServiceError('already_friends','Already friends.',409);
      if(rel?.status==='pending'&&rel.requester_id!==id) throw new AppServiceError('request_pending','Request already pending.',409);
      if(rel?.status!=='pending') {
        const eventID=crypto.randomUUID();
        let saved;
        if(rel) [saved]=await ctx.tx`update app_private.friendships set requester_id=${id},addressee_id=${targetID},status='pending',blocked_by_id=null,request_event_id=${eventID},updated_at=${ctx.now} where id=${rel.id} returning *`;
        else [saved]=await ctx.tx`insert into app_private.friendships(requester_id,addressee_id,status,request_event_id,created_at,updated_at) values(${id},${targetID},'pending',${eventID},${ctx.now},${ctx.now}) returning *`;
        await enqueuePersonalNotification(ctx,{id:eventID,event_type:'friend_request',source_id:saved.id,actor_id:id,recipient_id:targetID,actor_name:me.data.display_name||me.data.full_name});
      }
      await signalUsers(ctx,[id,targetID]); return await communityState(ctx);
    }
    if(action==='add_comment') {
      const sanitized=sanitizeProfileComment(body.comment); if(!sanitized) throw new AppServiceError('invalid_comment','Comment must contain 1-280 characters.',422);
      const comment=requireSafeCommunityText(sanitized,'Comment');
      await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${'app:comments:'+id},0))`;
      const [last]=await ctx.tx`select created_at from app_private.profile_comments where author_user_id=${id} order by created_at desc limit 1`;
      if(last&&ctx.now.getTime()-new Date(last.created_at).getTime()<5000) throw new AppServiceError('comment_cooldown','Wait before posting another comment.',429);
      await ctx.tx`insert into app_private.profile_comments(target_user_id,author_user_id,body,created_at,updated_at) values(${targetID},${id},${comment},${ctx.now},${ctx.now})`;
      await signalProfile(ctx,targetID); return await detail(ctx,target);
    }
    if(rel?.status!=='accepted') throw new AppServiceError('friends_required','Only accepted friends can be invited.',403);
    const room=await validateInviteRoom(ctx,body.room_id,body.room_code,id,targetID);
    const [existing]=await ctx.tx`select * from app_private.room_invites where sender_user_id=${id} and recipient_user_id=${targetID} and room_id=${room.id}`;
    if(!existing||existing.status!=='pending') {
      if(existing) await hidePersonalNotifications(ctx,{ids:[existing.notification_event_id]});
      const eventID=crypto.randomUUID(); let invite;
      if(existing) [invite]=await ctx.tx`update app_private.room_invites set status='pending',notification_event_id=${eventID},room_code=${room.code},created_at=${ctx.now},updated_at=${ctx.now} where id=${existing.id} returning *`;
      else [invite]=await ctx.tx`insert into app_private.room_invites(sender_user_id,recipient_user_id,room_id,room_code,status,notification_event_id,created_at,updated_at) values(${id},${targetID},${room.id},${room.code},'pending',${eventID},${ctx.now},${ctx.now}) returning *`;
      await enqueuePersonalNotification(ctx,{id:eventID,event_type:'room_invite',source_id:invite.id,actor_id:id,recipient_id:targetID,room_id:room.id,actor_name:me.data.display_name||me.data.full_name});
    }
    await signalUsers(ctx,[id,targetID]); return {ok:true};
  }
  if(action==='delete_comment') {
    const commentID=requireUUID(body.comment_id,'comment_id');
    let [comment]=await ctx.tx`select * from app_private.profile_comments where id=${commentID}`;
    if(!comment) throw new AppServiceError('comment_not_found','Comment not found.',404);
    if(comment.author_user_id!==id&&comment.target_user_id!==id) throw new AppServiceError('forbidden','Comment cannot be deleted.',403);
    await lockPair(ctx,comment.author_user_id,comment.target_user_id);
    [comment]=await ctx.tx`delete from app_private.profile_comments where id=${commentID} returning *`;
    if(!comment) throw new AppServiceError('comment_not_found','Comment not found.',404);
    await signalProfile(ctx,comment.target_user_id); return await detail(ctx,await activeProfile(ctx,comment.target_user_id));
  }
  if(action==='report') {
    const type=clean(body.report_type),reason=normalizeCommunityReportReason(body.reason);
    if(!reason||!['user','comment'].includes(type)) throw new AppServiceError('invalid_report','A valid report reason and type are required.',422);
    let comment:any=null,target:any;
    if(type==='comment') {
      [comment]=await ctx.tx`select * from app_private.profile_comments where id=${requireUUID(body.comment_id,'comment_id')}`;
      if(!comment) throw new AppServiceError('content_not_found','Reported content not found.',404);
      target=await activeProfile(ctx,comment.author_user_id);
    } else target=await targetProfile(ctx,body);
    if(target.user_id===id) throw new AppServiceError('self_report','You cannot report yourself.',409);
    await lockPair(ctx,id,target.user_id);
    if(comment) {
      const [fresh]=await ctx.tx`select * from app_private.profile_comments where id=${comment.id} for share`;
      if(!fresh||fresh.author_user_id!==target.user_id) throw new AppServiceError('content_not_found','Reported content not found.',404);
      comment=fresh;
    }
    const snapshot=sanitizeCommunityReportDetails(comment?comment.body:`${clean(target.data.display_name||target.data.full_name)} ${target.spy_id}`);
    await ctx.tx`insert into app_private.community_reports(reporter_user_id,reported_user_id,comment_id,report_type,reason,details,content_snapshot,created_at,updated_at) values(${id},${target.user_id},${comment?.id||null},${type},${reason},${sanitizeCommunityReportDetails(body.details)},${snapshot},${ctx.now},${ctx.now}) on conflict do nothing`;
    return {ok:true,message:'Report received'};
  }
  if(['accept_room_invite','decline_room_invite','consume_room_invite'].includes(action)) {
    const inviteID=requireUUID(body.invite_id,'invite_id');
    let [invite]=await ctx.tx`select * from app_private.room_invites where id=${inviteID}`;
    if(!invite) {
      if(action!=='accept_room_invite') return {state:await communityState(ctx),room_code:null};
      throw new AppServiceError('invite_not_found','Invite not found.',404);
    }
    if(invite.recipient_user_id!==id) throw new AppServiceError('invite_not_found','Invite not found.',404);
    await lockPair(ctx,id,invite.sender_user_id);
    [invite]=await ctx.tx`select * from app_private.room_invites where id=${inviteID}`;
    if(!invite) {
      if(action==='consume_room_invite') return {state:await communityState(ctx),room_code:null};
      throw new AppServiceError('invite_not_found','Invite not found.',404);
    }
    let roomCode=null;
    if(action==='accept_room_invite') {
      const rel=await relationship(ctx,id,invite.sender_user_id);
      if(rel?.status!=='accepted') throw new AppServiceError('friends_required','Only accepted friends can accept room invites.',403);
      const disposition=roomInviteAcceptanceDisposition(invite,id);
      if(!['apply','already_applied'].includes(disposition)) throw new AppServiceError('invite_unavailable','Invite cannot be accepted.',409);
      if(disposition==='apply') {
        await validateInviteRoom(ctx,invite.room_id,invite.room_code,invite.sender_user_id,id);
        await ctx.tx`update app_private.room_invites set status='accepted',updated_at=${ctx.now} where id=${invite.id}`;
      }
      roomCode=invite.room_code;
    } else {
      if(action==='consume_room_invite'&&!['accepted','expired'].includes(invite.status)) throw new AppServiceError('room_invite_not_accepted','Room invite is not accepted.',409);
      await ctx.tx`delete from app_private.room_invites where id=${invite.id}`;
    }
    if(action!=='accept_room_invite') await hidePersonalNotifications(ctx,{ids:[invite.notification_event_id]});
    await signalUsers(ctx,[id,invite.sender_user_id]); return {state:await communityState(ctx),room_code:roomCode};
  }
  if(['accept','decline','cancel_request','remove_friend','unblock'].includes(action)) {
    const friendshipID=requireUUID(body.friendship_id,'friendship_id');
    let [rel]=await ctx.tx`select * from app_private.friendships where id=${friendshipID}`;
    if(!rel||![rel.requester_id,rel.addressee_id].includes(id)) throw new AppServiceError('relationship_not_found','Relationship not found.',404);
    const counterpart=opposite(rel,id); await lockPair(ctx,id,counterpart);
    [rel]=await ctx.tx`select * from app_private.friendships where id=${friendshipID}`;
    if(!rel) throw new AppServiceError('relationship_not_found','Relationship not found.',404);
    if(action==='unblock') {
      if(rel.status!=='blocked'||rel.blocked_by_id!==id) throw new AppServiceError('forbidden','Only the operative who blocked may unblock.',403);
      await ctx.tx`delete from app_private.friendships where id=${rel.id}`;
    } else {
      requireUnblocked(rel);
      if(action==='accept'||action==='decline') {
        const disposition=friendshipDecisionDisposition(action,rel,id);
        if(!['apply','already_applied'].includes(disposition)) throw new AppServiceError('invalid_relationship_state','Request cannot be updated.',409);
        if(disposition==='apply') await ctx.tx`update app_private.friendships set status=${action==='accept'?'accepted':'declined'},updated_at=${ctx.now} where id=${rel.id}`;
      } else {
        if(action==='cancel_request'&&(rel.requester_id!==id||rel.status!=='pending')) throw new AppServiceError('invalid_relationship_state','Request cannot be cancelled.',409);
        if(action==='remove_friend'&&rel.status!=='accepted') throw new AppServiceError('invalid_relationship_state','Not friends.',409);
        await ctx.tx`delete from app_private.friendships where id=${rel.id}`;
      }
      if(rel.request_event_id) await hidePersonalNotifications(ctx,{ids:[rel.request_event_id]});
      if(action==='remove_friend') await hidePersonalNotifications(ctx,{pair:[id,counterpart]});
    }
    await signalUsers(ctx,[id,counterpart]); await signalProfile(ctx,id); await signalProfile(ctx,counterpart);
    return await communityState(ctx);
  }
  throw new AppServiceError('unsupported_community_action','Unsupported community action.');
}

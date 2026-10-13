import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test,{after} from 'node:test';
import postgres from 'postgres';
import {dispatchProfile,ensureProfile} from '../../supabase/functions/app-services/profile.ts';
import {dispatchCommunity} from '../../supabase/functions/app-services/community.ts';
import {dispatchInbox} from '../../supabase/functions/app-services/inbox.ts';
import {AppServiceError} from '../../supabase/functions/app-services/contracts.ts';

const databaseURL=process.env.DATABASE_URL;
assert.ok(databaseURL,'DATABASE_URL is required; tests never choose a cloud endpoint');
const parsed=new URL(databaseURL);
assert.equal(parsed.hostname,'127.0.0.1'); assert.equal(parsed.port,'56322');
const db=postgres(databaseURL,{max:12,onnotice:()=>{},connect_timeout:5});
const identities=[],roomIDs=[];
const now=()=>new Date();
async function actor(name='Operative') {
  const id=randomUUID(),user={id,email:id+'@example.test',contactEmail:`${id}@private.test`,full_name:name,metadata:{role:'admin'}};
  identities.push(id);
  await db`insert into auth.users(id,aud,role,email,created_at,updated_at) values(${id},'authenticated','authenticated',${user.contactEmail},now(),now())`;
  await call(user,'profile',{action:'current'}); return user;
}
async function call(user,service,body,{at=now(),config={},afterDispatch}={}) {
  return await db.begin(async tx=>{
    const ctx={tx,actor:user,now:at,config};
    const result=await ({profile:dispatchProfile,community:dispatchCommunity,notifications:dispatchInbox}[service])(ctx,body);
    if(afterDispatch) await afterDispatch(ctx,result);
    return result;
  });
}
async function pair(a,b) {
  const sent=await call(a,'community',{action:'send_request',target_user_id:b.id});
  const id=sent.outgoing.find(r=>r.profile.id===b.id).id;
  await call(b,'community',{action:'accept',friendship_id:id}); return id;
}
async function room(host) {
  const id=randomUUID(),code=randomUUID().replaceAll('-','').slice(0,6).toUpperCase(); roomIDs.push(id);
  await db`insert into full_game_private.rooms(id,code,state) values(${id},${code},${db.json({id,code,status:'waiting',players:[{user_id:host.id,email:host.email}]})})`;
  await db`insert into full_game_private.members(room_id,user_id,membership_id) values(${id},${host.id},${randomUUID()})`;
  return {id,code};
}
async function expectFailure(promise,status,code) {
  await assert.rejects(promise,error=>{assert.equal(error.status,status);if(code)assert.equal(error.code,code);return true;});
}

after(async()=>{
  if(identities.length) await db.begin(async tx=>{
    await tx`delete from app_private.push_outbox where user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.push_registrations where user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.notification_events where actor_id=any(${identities}::uuid[]) or recipient_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.notification_announcements where author_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.notification_read_receipts where user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.community_reports where reporter_user_id=any(${identities}::uuid[]) or reported_user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.profile_comments where author_user_id=any(${identities}::uuid[]) or target_user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.room_invites where sender_user_id=any(${identities}::uuid[]) or recipient_user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.friendships where requester_id=any(${identities}::uuid[]) or addressee_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.profile_watchers where viewer_id=any(${identities}::uuid[]) or profile_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.entitlements where user_id=any(${identities}::uuid[])`;
    await tx`delete from app_private.membership_grants where user_id=any(${identities}::uuid[])`;
    await tx`delete from public.app_user_signals where recipient_user_id=any(${identities}::uuid[])`;
    await tx`delete from public.app_profile_signals where recipient_user_id=any(${identities}::uuid[]) or profile_user_id=any(${identities}::uuid[])`;
    await tx`delete from full_game_private.history where player_id=any(${identities}::uuid[])`;
    if(roomIDs.length) await tx`delete from full_game_private.rooms where id=any(${roomIDs}::uuid[])`;
    await tx`delete from app_private.profiles where user_id=any(${identities}::uuid[])`;
    await tx`delete from auth.users where id=any(${identities}::uuid[])`;
  });
  await db.end();
});

test('profile DTO keeps contact private, stable SPY ID, partial update and immutable authorization',async()=>{
  const a=await actor('Profile Alpha'),b=await actor('Profile Beta');
  const first=await call(a,'profile',{action:'current'});
  assert.match(first.spy_id,/^\d{3}-\d{3}$/); assert.equal(first.role,'user');assert.equal(first.contact_email,a.contactEmail);
  const saved=await call(a,'profile',{action:'update',display_name:'New callsign',spy_card_theme:'blacksite'});
  const language=await call(a,'profile',{action:'update',language:'ru',role:'admin',spy_id:'067-067',rating:99999});
  assert.equal(language.display_name,saved.display_name);assert.equal(language.spy_card_theme,'blacksite');assert.equal(language.language,'ru');assert.equal(language.spy_id,first.spy_id);assert.equal(language.role,'user');assert.equal(language.rating,0);
  const viewed=await call(b,'community',{action:'profile',target_user_id:a.id});
  assert.equal(viewed.profile.display_name,'New callsign');assert.equal('email' in viewed.profile,false);assert.equal('contact_email' in viewed.profile,false);
  const onboarding=await call(a,'profile',{action:'onboarding',language:'en',onboarding_version:2,onboarding_completed_at:'1970-01-01',acquisition_source:'chatgpt'});
  assert.equal(onboarding.onboarding_version,2);assert.ok(Date.parse(onboarding.onboarding_completed_at)>Date.parse('2026-01-01'));
  const source=await call(a,'profile',{action:'acquisition',acquisition_source:'friends_or_family'});assert.equal(source.acquisition_source,'friends_or_family');
  await expectFailure(call(a,'profile',{action:'update',language:'xx'}),422,'invalid_language');
});

test('concurrent first profile requests allocate one persistent unique non-reserved SPY ID',async()=>{
  const id=randomUUID(),a={id,email:id+'@example.test',contactEmail:'parallel@private.test',full_name:'Parallel',metadata:{}};identities.push(id);
  await db`insert into auth.users(id,aud,role,email) values(${id},'authenticated','authenticated',${id+'@test.invalid'})`;
  const responses=await Promise.all(Array.from({length:6},()=>call(a,'profile',{action:'current'})));
  assert.equal(new Set(responses.map(r=>r.spy_id)).size,1);assert.notEqual(responses[0].spy_id,'067-067');
  assert.equal((await db`select * from app_private.profiles where user_id=${id}`).length,1);
});

test('premium profile changes require verified grants while saved expired customization survives',async()=>{
  const a=await actor('Premium');const config={SPYCLASH_LIMITLESS_ENABLED:'true'};
  await expectFailure(call(a,'profile',{action:'update',spy_card_theme:'blacksite'},{config}),403,'limitless_required');
  await db`insert into app_private.membership_grants(user_id,expires_at) values(${a.id},${new Date(Date.now()+60000)})`;
  assert.equal((await call(a,'profile',{action:'update',spy_card_theme:'blacksite'},{config})).spy_card_theme,'blacksite');
  await db`update app_private.membership_grants set active=false where user_id=${a.id}`;
  assert.equal((await call(a,'profile',{action:'update',language:'uk'},{config})).spy_card_theme,'blacksite');
  await expectFailure(call(a,'profile',{action:'update',spy_card_accent:'verified_green'},{config}),403,'limitless_required');
});

test('concurrent friend requests commit one pair and inbox item; decisions are actor-bound and replay-safe',async()=>{
  const a=await actor('Requester'),b=await actor('Recipient'),outsider=await actor('Outsider');
  const responses=await Promise.all(Array.from({length:5},()=>call(a,'community',{action:'send_request',target_user_id:b.id})));
  const friendship=responses[0].outgoing[0]; assert.ok(friendship.id);assert.equal(new Set(responses.map(r=>r.outgoing[0].id)).size,1);
  const inbox=await call(b,'notifications',{action:'list',scope:'personal'});assert.equal(inbox.items.length,1);assert.equal(inbox.unread.personal,1);
  await expectFailure(call(a,'community',{action:'accept',friendship_id:friendship.id}),409);
  await expectFailure(call(outsider,'community',{action:'accept',friendship_id:friendship.id}),404);
  await expectFailure(call(b,'community',{action:'send_request',target_user_id:a.id}),409);
  assert.equal((await call(b,'community',{action:'accept',friendship_id:friendship.id})).friends.length,1);
  assert.equal((await call(b,'community',{action:'accept',friendship_id:friendship.id})).friends.length,1);
  assert.equal((await call(b,'notifications',{action:'summary'})).unread.personal,0);
  assert.equal((await db`select * from app_private.notification_events where actor_id=${a.id} and recipient_id=${b.id}`).length,1);
});

test('comments enforce author-wide cooldown, public safety and ownership; reports deduplicate',async()=>{
  const a=await actor('Commenter'),b=await actor('Target'),c=await actor('Other'),at=now();
  const results=await Promise.allSettled([call(a,'community',{action:'add_comment',target_user_id:b.id,comment:'First message'},{at}),call(a,'community',{action:'add_comment',target_user_id:c.id,comment:'Second message'},{at})]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.equal(results.find(r=>r.status==='rejected').reason.status,429);
  const [comment]=await db`select * from app_private.profile_comments where author_user_id=${a.id}`;
  const target=comment.target_user_id===b.id?b:c,other=target===b?c:b;
  await expectFailure(call(other,'community',{action:'delete_comment',comment_id:comment.id}),403);
  await Promise.all(Array.from({length:3},()=>call(other,'community',{action:'report',report_type:'comment',comment_id:comment.id,reason:'spam'})));
  assert.equal((await db`select * from app_private.community_reports where reporter_user_id=${other.id} and comment_id=${comment.id}`).length,1);
  assert.equal((await call(target,'community',{action:'delete_comment',comment_id:comment.id})).comments.length,0);
  await expectFailure(call(a,'community',{action:'add_comment',target_user_id:a.id,comment:'self'}),409);
  await expectFailure(call(a,'community',{action:'add_comment',target_user_id:b.id,comment:'x'.repeat(281)}),422);
});

test('block atomically hides profiles and removes pair content, invites, inbox and queued pushes',async()=>{
  const a=await actor('Blocker'),b=await actor('Blocked');await pair(a,b);
  await db`insert into app_private.push_registrations(user_id,installation_id,kind,binding,bundle_id,environment,token_hash,token_ciphertext,alert_authorized) values(${b.id},${randomUUID()},'device','','com.spyclash.ios.supabasetest','sandbox',${randomUUID()},'{}',true)`;
  await call(b,'community',{action:'add_comment',target_user_id:a.id,comment:'Visible before block'});
  const lobby=await room(a);await call(a,'community',{action:'invite_to_room',target_user_id:b.id,room_id:lobby.id,room_code:lobby.code});
  assert.equal((await db`select 1 from app_private.push_outbox where user_id=${b.id} and state='pending'`).length,1);
  const state=await call(a,'community',{action:'block',target_user_id:b.id});assert.equal(state.blocked.length,1);assert.equal(state.friends.length,0);
  await expectFailure(call(b,'community',{action:'profile',target_user_id:a.id}),404);
  assert.equal((await call(b,'notifications',{action:'summary'})).unread.personal,0);
  assert.equal((await db`select * from app_private.room_invites where sender_user_id=${a.id}`).length,0);
  assert.equal((await db`select * from app_private.profile_comments where author_user_id=${b.id}`).length,0);
  assert.equal((await db`select 1 from app_private.push_outbox where user_id=${b.id} and state='cancelled'`).length,1);
  await expectFailure(call(b,'community',{action:'unblock',friendship_id:state.blocked[0].id}),403);
  assert.equal((await call(a,'community',{action:'unblock',friendship_id:state.blocked[0].id})).blocked.length,0);
  assert.equal((await call(b,'community',{action:'profile',target_user_id:a.id})).profile.id,a.id);
});

test('room invites check friendship, membership and waiting state; accept/consume recover safely',async()=>{
  const a=await actor('Host'),b=await actor('Guest'),c=await actor('Stranger'),lobby=await room(a);
  await expectFailure(call(a,'community',{action:'invite_to_room',target_user_id:b.id,room_id:lobby.id,room_code:lobby.code}),403);
  await pair(a,b);
  await call(a,'community',{action:'invite_to_room',target_user_id:b.id,room_id:lobby.id,room_code:lobby.code});
  const state=await call(b,'community',{action:'state'}),invite=state.incoming_room_invites[0];assert.equal(invite.room_code,lobby.code);
  await expectFailure(call(b,'community',{action:'consume_room_invite',invite_id:invite.id}),409,'room_invite_not_accepted');
  await expectFailure(call(c,'community',{action:'accept_room_invite',invite_id:invite.id}),404);
  assert.equal((await call(b,'community',{action:'accept_room_invite',invite_id:invite.id})).room_code,lobby.code);
  assert.equal((await call(b,'community',{action:'accept_room_invite',invite_id:invite.id})).room_code,lobby.code);
  await call(b,'community',{action:'consume_room_invite',invite_id:invite.id});await call(b,'community',{action:'consume_room_invite',invite_id:invite.id});
  await db`update full_game_private.rooms set state=state||'{"status":"playing"}'::jsonb where id=${lobby.id}`;
  await expectFailure(call(a,'community',{action:'invite_to_room',target_user_id:b.id,room_id:lobby.id,room_code:lobby.code}),409);
});

test('inbox ownership, localized copy and scoped watermark preserve later unread events',async()=>{
  const a=await actor('Inbox sender'),b=await actor('Inbox reader'),c=await actor('Foreign reader'),t=now();
  await call(b,'profile',{action:'update',language:'ru'});
  await call(a,'community',{action:'send_request',target_user_id:b.id},{at:t});
  const page=await call(b,'notifications',{action:'list',scope:'personal'},{at:t});assert.equal(page.items[0].title,'Новый запрос в друзья');
  await expectFailure(call(c,'notifications',{action:'mark_read',item_id:page.items[0].id},{at:t}),404);
  await call(b,'notifications',{action:'mark_all_read',scope:'personal'},{at:new Date(t.getTime()+10)});
  assert.equal((await call(b,'notifications',{action:'summary'},{at:new Date(t.getTime()+11)})).unread.personal,0);
  await call(c,'community',{action:'send_request',target_user_id:b.id},{at:new Date(t.getTime()+20)});
  assert.equal((await call(b,'notifications',{action:'summary'},{at:new Date(t.getTime()+21)})).unread.personal,1);
});

test('announcement authorization ignores metadata; drafts use revisions, cursor and withdrawal',async()=>{
  const admin=await actor('Configured admin'),reader=await actor('Reader'),config={APP_ADMIN_USER_IDS:admin.id},t=now();
  const request={action:'publish_global',request_id:randomUUID(),title:'Release test',body:'A new isolated release',importance:'quiet'};
  await expectFailure(call(admin,'notifications',request),403,'forbidden');
  const first=await call(admin,'notifications',request,{config,at:t});assert.ok(first.item.id.startsWith('global:'));
  const draft=await call(admin,'notifications',{action:'create_draft',request_id:randomUUID(),title_en:'Draft title',body_en:'Draft body'},{config,at:new Date(t.getTime()+1)});
  await expectFailure(call(admin,'notifications',{action:'publish',announcement_id:draft.announcement_id,expected_revision:randomUUID()},{config}),409,'cas_conflict');
  const published=await call(admin,'notifications',{action:'publish',announcement_id:draft.announcement_id,expected_revision:draft.revision},{config,at:new Date(t.getTime()+2)});
  const page=await call(reader,'notifications',{action:'list',scope:'global',limit:1},{at:new Date(t.getTime()+3)});assert.equal(page.items.length,1);assert.ok(page.next_cursor);
  const next=await call(reader,'notifications',{action:'list',scope:'global',limit:1,cursor:page.next_cursor},{at:new Date(t.getTime()+3)});assert.notEqual(next.items[0].id,page.items[0].id);
  await call(admin,'notifications',{action:'withdraw',announcement_id:draft.announcement_id,expected_revision:published.revision},{config,at:new Date(t.getTime()+4)});
  const visible=await call(reader,'notifications',{action:'list',scope:'global'},{at:new Date(t.getTime()+5)});assert.equal(visible.items.some(i=>i.id===published.item.id),false);
});

test('public profile stats derive only canonical ranked history with original role rating rules',async()=>{
  const a=await actor('Ranked'),lobby=await room(a),match=randomUUID();
  const record={match_id:match,player_user_id:a.id,player_email:a.email,role:'spy',won:true,match_type:'online',ranked:true,spy_count:1,room_code:lobby.code};
  await db`insert into full_game_private.history(match_id,player_id,room_id,result) values(${match},${a.id},${lobby.id},${db.json(record)})`;
  const second=randomUUID();await db`insert into full_game_private.history(match_id,player_id,room_id,result) values(${second},${a.id},${lobby.id},${db.json({...record,match_id:second,spy_count:2})})`;
  const user=await call(a,'profile',{action:'current'});assert.equal(user.rating,60);assert.equal(user.games_played,1);assert.equal(user.spy_games_won,1);assert.equal(user.win_rate,100);
});

test('service transaction rolls friendship and inbox back together on infrastructure failure',async()=>{
  const a=await actor('Rollback A'),b=await actor('Rollback B');
  await assert.rejects(call(a,'community',{action:'send_request',target_user_id:b.id},{afterDispatch:async()=>{throw new Error('Injected infrastructure failure');}}),/Injected/);
  assert.equal((await call(a,'community',{action:'state'})).outgoing.length,0);
  assert.equal((await call(b,'notifications',{action:'summary'})).unread.personal,0);
});

test('target deletion row lock prevents late interaction; metadata-only signals enforce recipient RLS',async()=>{
  const a=await actor('Active'),b=await actor('Deleting');
  let acquired,release;const locked=new Promise(r=>acquired=r),gate=new Promise(r=>release=r);
  const deletion=db.begin(async tx=>{await tx`update app_private.profiles set state='deleted' where user_id=${b.id}`;acquired();await gate;});
  await locked;
  const action=call(a,'community',{action:'send_request',target_user_id:b.id});release();await deletion;
  await expectFailure(action,404,'profile_not_found');
  assert.equal((await db`select * from app_private.friendships where requester_id=${a.id} or addressee_id=${a.id}`).length,0);
  await call(a,'profile',{action:'update',display_name:'Signal name'});
  await db.begin(async tx=>{
    await tx`select set_config('request.jwt.claim.sub',${a.id},true)`;await tx`set local role authenticated`;
    const rows=await tx`select * from public.app_profile_signals`;
    assert.ok(rows.length);assert.ok(rows.every(r=>r.recipient_user_id===a.id));
    assert.deepEqual(Object.keys(rows[0]).sort(),['profile_user_id','recipient_user_id','revision','updated_at']);
  });
  await assert.rejects(db.begin(async tx=>{await tx`set local role authenticated`;await tx`select * from app_private.profiles`;}),error=>error.code==='42501');
});

test('copied content and notification policy failures are definitive application errors',async()=>{
  const a=await actor('Policy tester'),b=await actor('Target');
  await assert.rejects(call(a,'community',{action:'add_comment',target_user_id:b.id,comment:'fuck you'}),error=>error instanceof AppServiceError&&error.status===422&&error.code==='objectionable_content');
  await assert.rejects(call(a,'notifications',{action:'list',scope:'global',cursor:'not-a-cursor'}),error=>error instanceof AppServiceError&&error.status===422);
  await assert.rejects(call(a,'notifications',{action:'publish_global',request_id:randomUUID(),title:'<script>',body:'unsafe'},{config:{APP_ADMIN_USER_IDS:a.id}}),error=>error instanceof AppServiceError&&error.status===422);
});

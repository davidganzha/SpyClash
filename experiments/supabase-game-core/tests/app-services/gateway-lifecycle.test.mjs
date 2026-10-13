import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import postgres from 'postgres';
import {createClient} from '@supabase/supabase-js';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {executeGame} from '../../supabase/functions/full-game-core/service.ts';
import {processAccountDeletionJobs} from '../../supabase/functions/app-services/lifecycle.ts';
import {accountGate} from '../../supabase/functions/app-services/account-gate.ts';

let db;const users=[];
const endpoint=process.env.APP_SERVICES_URL;
const sdk=()=>createClient(process.env.SUPABASE_URL,process.env.SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
async function account(){
  const client=sdk(),email=`full-app-${crypto.randomUUID()}@example.test`;
  const {data,error}=await client.auth.signUp({email,password:'Isolated-fixture-'+crypto.randomUUID(),options:{data:{full_name:'Fixture',role:'admin',premium:true}}});assert.ifError(error);assert.ok(data.session);
  const actor={id:data.user.id,email:data.user.id+'@example.test',contactEmail:email,full_name:'Fixture',metadata:{role:'admin'}};
  const user={...actor,client,token:data.session.access_token};users.push(user);return user;
}
async function call(user,body){const response=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer '+user.token,'Content-Type':'application/json'},body:JSON.stringify(body)});return {status:response.status,body:await response.json()};}
const mutation=(service,action,fields={})=>({service,action,...fields,request_id:crypto.randomUUID()});
before(()=>{assert.equal(new URL(endpoint).hostname,'127.0.0.1');assert.equal(new URL(process.env.DATABASE_URL).port,'56322');db=postgres(process.env.DATABASE_URL,{max:12,onnotice:()=>{}});});
after(async()=>{
  if(!db)return;
  for(const user of users){
    try{await executeApp(db,user,mutation('profile','delete'));}catch{}
    await db`update app_private.lifecycle_jobs set next_attempt_at=clock_timestamp() where user_id=${user.id}`;
    await processAccountDeletionJobs(db,process.env,fetch,user.id);
  }
  await db.end();
});

test('real Auth gateway ignores editable privilege claims and keeps contact address private',async()=>{
  const user=await account(),outsider=await account();
  const current=await call(user,{service:'profile',action:'current'});assert.equal(current.status,200);assert.equal(current.body.role,'user');assert.equal(current.body.email,user.email);assert.equal(current.body.contact_email,user.contactEmail);
  await call(outsider,{service:'profile',action:'current'});
  const directory=await call(outsider,{service:'community',action:'directory'});assert.equal(directory.status,200);assert.ok(!JSON.stringify(directory.body).includes(user.contactEmail));
  const forged=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer invalid-token'},body:JSON.stringify({service:'profile',action:'current'})});assert.equal(forged.status,401);
  const publish=await call(user,mutation('notifications','publish_global',{title:'Unauthorized',body:'Not admin'}));assert.equal(publish.status,403);
  const reserved=await call(user,{...mutation('profile','update',{language:'ru'}),evidence:{role:'admin'}});assert.equal(reserved.status,400);
  for(const table of ['profiles','receipts','entitlements','legacy_links','push_registrations']){
    const read=await user.client.schema('app_private').from(table).select('*').limit(1);assert.ok(read.error||!read.data?.length);
  }
  const signals=await outsider.client.from('app_user_signals').select('*').eq('recipient_user_id',user.id);assert.ifError(signals.error);assert.deepEqual(signals.data,[]);
});

test('concurrent duplicate commands have one receipt; different body cannot reuse the command ID',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  const body=mutation('profile','update',{display_name:'Immutable Operative',language:'ru'});
  const results=await Promise.all(Array.from({length:8},()=>call(user,body)));results.forEach(r=>{assert.equal(r.status,200);assert.deepEqual(r,results[0]);});
  assert.equal((await db`select 1 from app_private.receipts where actor_id=${user.id} and request_id=${body.request_id}`).length,1);
  const changed=await call(user,{...body,language:'es'});assert.equal(changed.status,409);assert.equal(changed.body.code,'request_id_reused');
  const follow=await call(user,mutation('profile','update',{language:'es'}));assert.equal(follow.body.display_name,'Immutable Operative');
  assert.deepEqual(await call(user,body),results[0],'lost acknowledgement recovers original response after a later write');
});

test('definitive rejection is durable and SQL failure rolls back without a receipt',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  const rejected=mutation('profile','update',{language:'invalid'}),one=await call(user,rejected);
  assert.equal(one.status,422);assert.deepEqual(await call(user,rejected),one);
  const constraint='test_app_'+crypto.randomUUID().replaceAll('-','');
  await db`alter table app_private.profiles add constraint ${db(constraint)} check(user_id<>${db.unsafe("'"+user.id+"'::uuid")} or data->>'language'<>'uk') not valid`;
  const body=mutation('profile','update',{language:'uk'});
  try{
    assert.equal((await call(user,body)).status,503);
    assert.equal((await db`select 1 from app_private.receipts where actor_id=${user.id} and request_id=${body.request_id}`).length,0);
    assert.equal((await call(user,{service:'profile',action:'current'})).body.language,'en');
  }finally{await db`alter table app_private.profiles drop constraint ${db(constraint)}`;}
  assert.equal((await call(user,body)).status,200);
});

test('revoked Auth session cannot write with its still-unexpired access JWT',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  assert.ifError((await user.client.auth.signOut({scope:'global'})).error);
  const result=await call(user,mutation('profile','update',{language:'ru'}));assert.equal(result.status,401);
});

test('refreshing Supabase directly cannot extend a legacy session beyond its source revalidation window',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  await db`insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email)
    values(${crypto.randomUUID().replaceAll('-','').repeat(2)},${'legacy-'+crypto.randomUUID()},'https://spyclash.com','69a0e57fa939f578082f8091',${user.id},${crypto.randomUUID()+'@accounts.spyclash.invalid'})`;
  await db`update auth.sessions set created_at=clock_timestamp()-interval '66 minutes' where user_id=${user.id}`;
  const refreshed=await user.client.auth.refreshSession();assert.ifError(refreshed.error);assert.ok(refreshed.data.session);
  user.token=refreshed.data.session.access_token;
  const response=await call(user,{service:'profile',action:'current'});
  assert.equal(response.status,401);assert.equal(response.body.code,'legacy_session_revalidation_required');
  const game=await fetch(process.env.FULL_CORE_URL,{method:'POST',headers:{Authorization:'Bearer '+user.token,'Content-Type':'application/json'},body:JSON.stringify({action:'get_history'})});
  assert.equal(game.status,401);assert.equal((await game.json()).code,'legacy_session_revalidation_required');
});

test('an older session cannot access a partial legacy import and deletion removes its staging data',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  const source='pending-'+crypto.randomUUID(),legacyID='legacy-'+crypto.randomUUID();
  await db`insert into app_private.legacy_import_runs(user_id,source_key,legacy_user_id) values(${user.id},${source},${legacyID})`;
  const pending=await call(user,{service:'profile',action:'current'});
  assert.equal(pending.status,503);assert.equal(pending.body.code,'legacy_import_pending');
  const game=await fetch(process.env.FULL_CORE_URL,{method:'POST',headers:{Authorization:'Bearer '+user.token,'Content-Type':'application/json'},body:JSON.stringify({action:'get_history'})});
  assert.equal(game.status,503);assert.equal((await game.json()).code,'legacy_import_pending');
  await db`update app_private.legacy_import_runs set status='complete' where user_id=${user.id}`;
  assert.equal((await call(user,{service:'profile',action:'current'})).status,200);
  await db`update app_private.legacy_import_runs set status='pending' where user_id=${user.id}`;
  await db`insert into app_private.legacy_import_rows(user_id,source_key,entity,source_id,source_digest) values(${user.id},${source},'User',${legacyID},${'a'.repeat(64)})`;
  await db`insert into app_private.legacy_import_history_stage(user_id,source_key,source_id,data) values(${user.id},${source},'result','{"secret":"private staged data"}')`;
  await db`insert into app_private.legacy_pending_social(owner_id,source_key,source_id,entity,peer_legacy_id,source_digest,data,captured_at) values(${user.id},${source},'relation','Friendship','unmapped-peer',${'b'.repeat(64)},'{}',clock_timestamp())`;
  assert.equal((await call(user,mutation('profile','delete'))).status,200);
  for(const table of ['legacy_import_runs','legacy_import_rows','legacy_import_history_stage'])assert.equal((await db`select 1 from ${db('app_private.'+table)} where user_id=${user.id}`).length,0);
  assert.equal((await db`select 1 from app_private.legacy_pending_social where owner_id=${user.id}`).length,0);
});

test('deletion closes rooms, fences subsequent game writes, removes content and keeps ownership tombstone',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  const created=await executeGame(db,user,{action:'create_room',request_id:crypto.randomUUID()});assert.equal(created.status,200);const roomID=created.body.room.id;
  await executeGame(db,user,{action:'create_word_pack',request_id:crypto.randomUUID(),pack:{name:'Delete me',category:'test',words:['train','moon']}});
  await db`insert into app_private.apple_accounts(user_id,app_account_token) values(${user.id},${crypto.randomUUID()})`;
  const deleted=await executeApp(db,user,mutation('profile','delete'));assert.equal(deleted.status,200);
  const [profile]=await db`select * from app_private.profiles where user_id=${user.id}`;assert.equal(profile.state,'deleted');assert.equal(profile.contact_email,'');assert.deepEqual(profile.data,{});
  assert.equal((await db`select 1 from full_game_private.word_packs where owner_id=${user.id}`).length,0);
  const [room]=await db`select state,closed from full_game_private.rooms where id=${roomID}`;assert.equal(room.closed,true);assert.deepEqual(room.state.players,[]);
  await assert.rejects(executeGame(db,user,{action:'create_room',request_id:crypto.randomUUID()}),e=>e.code==='account_unavailable');
  assert.equal((await db`select state from app_private.apple_accounts where user_id=${user.id}`)[0].state,'deleted');
  let attempts=0;
  await processAccountDeletionJobs(db,process.env,async()=>{attempts++;throw new Error('lost network');},user.id);assert.equal(attempts,1);
  assert.equal((await db`select phase from app_private.lifecycle_jobs where user_id=${user.id}`)[0].phase,'revoke_auth');
  await db`update app_private.lifecycle_jobs set next_attempt_at=clock_timestamp() where user_id=${user.id}`;
  await processAccountDeletionJobs(db,process.env,fetch,user.id);
  assert.equal((await db`select phase from app_private.lifecycle_jobs where user_id=${user.id}`)[0].phase,'complete');
  assert.equal((await db`select 1 from auth.users where id=${user.id}`).length,0);
  assert.equal((await db`select 1 from app_private.profiles where user_id=${user.id} and state='deleted'`).length,1);
});

test('deletion waits for an admitted writer and rejects every writer admitted after tombstone',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  let release,acquired;const ready=new Promise(r=>acquired=r),hold=new Promise(r=>release=r);
  const writer=db.begin(async tx=>{await accountGate(tx,user.id);acquired();await hold;await tx`update app_private.profiles set data=data||'{"display_name":"Before deletion"}'::jsonb where user_id=${user.id}`;});
  await ready;let finished=false;
  const deletion=executeApp(db,user,mutation('profile','delete')).then(r=>{finished=true;return r;});
  await new Promise(r=>setTimeout(r,75));assert.equal(finished,false);
  release();await writer;assert.equal((await deletion).status,200);
  const responses=await Promise.allSettled(Array.from({length:8},()=>executeApp(db,user,mutation('profile','update',{language:'ru'}))));
  responses.forEach(r=>{assert.equal(r.status,'rejected');assert.equal(r.reason.code,'account_unavailable');});
  assert.deepEqual((await db`select data from app_private.profiles where user_id=${user.id}`)[0].data,{});
});

test('history cursor preserves all rows beyond 200 even when timestamps collide',async()=>{
  const user=await account();await call(user,{service:'profile',action:'current'});
  const room=await executeGame(db,user,{action:'create_room',request_id:crypto.randomUUID()});
  const expected=new Set();
  await db.begin(async tx=>{
    for(let i=0;i<205;i++){
      const id=crypto.randomUUID();expected.add(id);
      await tx`insert into full_game_private.history(match_id,player_id,room_id,result,created_at) values(${id},${user.id},${room.body.room.id},${tx.json({result_key:id})},'2026-10-13T00:00:00.123456Z')`;
    }
  });
  const first=await executeGame(db,user,{action:'get_history'});assert.equal(first.body.history.length,200);assert.ok(first.body.next_cursor);
  const second=await executeGame(db,user,{action:'get_history',cursor:first.body.next_cursor});assert.equal(second.body.history.length,5);assert.equal(second.body.next_cursor,null);
  assert.deepEqual(new Set([...first.body.history,...second.body.history].map(r=>r.id)),expected);
});

import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {prepareMembershipExternal,dispatchMembership,WEEKLY_PRODUCT} from '../../supabase/functions/app-services/membership.ts';
import {dispatchPush,enqueueAppPush,allowedPushBundle} from '../../supabase/functions/app-services/push.ts';
import {drainPushOutbox,reconcileCommittedEvents} from '../../supabase/functions/app-services/worker.ts';
import {sendLegacyPush,MAIN_PUSH_BUNDLE} from '../../supabase/functions/app-services/legacy-push.ts';
import {createRelayHandler} from '../../base44-prepared/supabasePushRelay/handler.ts';

let db;const owners=[],rooms=[];
const credential='mocked-existing-base44-credential';
const billing={SUPABASE_URL:'http://127.0.0.1:56321',APP_BILLING_PROVIDER:'base44',APP_LEGACY_BILLING_ENABLED:'true',APP_LEGACY_PURCHASES_ENABLED:'true'};
const push={SUPABASE_URL:billing.SUPABASE_URL,APP_PUSH_ENABLED:'true',APP_PUSH_DELIVERY_ENABLED:'true',APP_PUSH_DELIVERY_PROVIDER:'base44',APP_LEGACY_PUSH_RELAY_ENABLED:'true',APNS_TOPIC:MAIN_PUSH_BUNDLE,BASE44_PUSH_RELAY_SECRET:'12'.repeat(32),PUSH_TOKEN_ENCRYPTION_KEY:'34'.repeat(32)};
const snapshot=active=>({active,tier:active?'limitless':'free',protocol:'limitless',status:active?'active':'inactive',providers:active?['apple']:[],expires_at:active?new Date(Date.now()+86400_000).toISOString():null,benefits:{premium_avatars:active,full_history:active,advanced_statistics:active,ai_generations_daily_limit:active?null:10,history_limit:active?null:5},apple_purchase_enabled:!active});
async function actor(){const id=crypto.randomUUID(),a={id,email:id+'@example.test',contactEmail:'fixture@example.test',full_name:'Fixture',metadata:{},legacyID:'billing-'+id};owners.push(id);await db`insert into app_private.profiles(user_id,contact_email) values(${id},${a.contactEmail})`;await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${id},${a.legacyID},'https://spyclash.com',clock_timestamp())`;return a;}
async function call(a,body,fetcher,config=billing){const evidence=await prepareMembershipExternal({actor:a,body,config},{db,fetch:fetcher});return db.begin(tx=>dispatchMembership({tx,actor:a,body,config,now:new Date(),evidence},body));}
function provider(a,handle){return async(url,options)=>{assert.ok(url.startsWith('https://spyclash.com/api/apps/69a0e57fa939f578082f8091/'));assert.equal(options.headers.Authorization,'Bearer '+credential);if(url.endsWith('/User/me'))return Response.json({id:a.legacyID});const body=JSON.parse(options.body);assert.equal(body.access_token,credential);return handle(url,body);};}
before(async()=>{const status=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});assert.equal(status.status,0);const info=JSON.parse(status.stdout),url=new URL(info.DB_URL);assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');db=postgres(info.DB_URL,{max:4,onnotice:()=>{}});for(const file of ['schemas/full_game_core.sql','functions/app-services/services-schema.sql','functions/app-services/billing-push-schema.sql'])await db.unsafe(readFileSync('supabase/'+file,'utf8'));});
after(async()=>{for(const id of owners){await db`delete from app_private.notification_events where recipient_id=${id}`;await db`delete from app_private.push_registrations where user_id=${id}`;await db`delete from app_private.legacy_operations where user_id=${id}`;await db`delete from app_private.legacy_links where user_id=${id}`;await db`delete from app_private.entitlements where user_id=${id}`;await db`delete from app_private.profiles where user_id=${id}`;}for(const id of rooms){await db`delete from full_game_private.outbox where room_id=${id}`;await db`delete from full_game_private.rooms where id=${id}`;}await db.end();});

test('existing weekly billing owns the purchase token; durable retry never allocates a new token',async()=>{
  const a=await actor(),token=crypto.randomUUID();let calls=0;
  const fetcher=provider(a,(_url,body)=>{calls++;assert.equal(body.action,'prepare');assert.equal(body.requested_product_id,WEEKLY_PRODUCT);return Response.json({product_id:WEEKLY_PRODUCT,app_account_token:token});});
  const body={action:'prepare',requested_product_id:WEEKLY_PRODUCT,request_id:crypto.randomUUID(),base44_access_token:credential};
  assert.equal((await call(a,body,fetcher)).app_account_token,token);assert.equal((await call(a,body,fetcher)).app_account_token,token);assert.equal(calls,1);
  await assert.rejects(call(a,{...body,requested_product_id:'com.spyclash.ios.limitless.monthly'},fetcher),e=>e.code==='unsupported_product');
  const [stored]=await db`select response from app_private.legacy_operations where user_id=${a.id}`;assert.ok(!JSON.stringify(stored).includes(credential));
});
test('verified linked membership is mirrored with bounded TTL and revocation; wrong owner makes no billing call',async()=>{
  const a=await actor();let active=true,calls=0;
  const fetcher=provider(a,()=>{calls++;return Response.json(snapshot(active));});
  const body={action:'check',base44_access_token:credential};assert.equal((await call(a,body,fetcher)).active,true);
  let [mirror]=await db`select * from app_private.entitlements where user_id=${a.id}`;assert.equal(mirror.active,true);assert.ok(new Date(mirror.expires_at)-Date.now()<=300_000);
  active=false;await call(a,body,fetcher);[mirror]=await db`select * from app_private.entitlements where user_id=${a.id}`;assert.equal(mirror.active,false);
  const foreign=await actor();await assert.rejects(call(foreign,body,fetcher),e=>e.code==='legacy_owner_mismatch');assert.equal(calls,2);
});
test('unverified Apple result cannot grant, and replayed old snapshot never extends entitlement freshness',async()=>{
  const a=await actor(),body={action:'sync_transaction',signed_transaction:'fake-jws-handled-only-by-provider',request_id:crypto.randomUUID(),base44_access_token:credential};
  await assert.rejects(call(a,body,provider(a,()=>Response.json({success:true,server_status_verified:false,entitlement:{product_id:WEEKLY_PRODUCT}}))),e=>e.code==='legacy_billing_response_invalid');
  const fetcher=provider(a,url=>Response.json(url.endsWith('checkSubscription')?snapshot(true):{success:true,server_status_verified:true,entitlement:{product_id:WEEKLY_PRODUCT,status:'active'}}));
  await call(a,body,fetcher);
  await db`update app_private.legacy_operations set response=jsonb_set(response,'{snapshotCheckedAt}',${db.json(Date.now()-600_000)}) where user_id=${a.id}`;
  await db`delete from app_private.entitlements where user_id=${a.id}`;
  await call(a,body,fetcher);const [mirror]=await db`select active from app_private.entitlements where user_id=${a.id}`;assert.equal(mirror.active,false);
});
test('main-topic push reaches only authenticated prepared Base44 relay and retains outbox fencing',async()=>{
  const a=await actor();const registration={action:'register_device',installation_id:crypto.randomUUID(),apns_token:'aa'.repeat(32),environment:'production',bundle_id:MAIN_PUSH_BUNDLE,alert_authorized:true};
  assert.equal(allowedPushBundle({...push,APP_LEGACY_PUSH_RELAY_ENABLED:'false'}),null);
  await db.begin(tx=>dispatchPush({tx,actor:a,config:push,now:new Date()},registration));
  const event={id:crypto.randomUUID(),event_type:'friend_request',recipient_id:a.id,data:{title:'Test',body:'Message'}};
  await db`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id) values(${event.id},'friend_request',${crypto.randomUUID()},${a.id},${a.id})`;
  await db.begin(tx=>enqueueAppPush({tx,actor:a,config:push,now:new Date()},event));
  let delivered=0;const relay=createRelayHandler({config:{SPYCLASH_SUPABASE_PUSH_RELAY_ENABLED:'true',SPYCLASH_SUPABASE_PUSH_RELAY_SECRET:push.BASE44_PUSH_RELAY_SECRET},send:async input=>{delivered++;assert.equal(input.bundleID,MAIN_PUSH_BUNDLE);return {delivered:true,retryable:false,invalidateToken:false,reason:'ok'};}});
  const result=await drainPushOutbox(db,push,{send:input=>sendLegacyPush(input,push,async(url,options)=>relay(new Request(url,options)))});
  assert.equal(result.delivered,1);assert.equal(delivered,1);
});
test('relay rejects missing signature, tampering and expired requests without APNs calls',async()=>{
  let sends=0;const relay=createRelayHandler({config:{SPYCLASH_SUPABASE_PUSH_RELAY_ENABLED:'true',SPYCLASH_SUPABASE_PUSH_RELAY_SECRET:push.BASE44_PUSH_RELAY_SECRET},send:async()=>{sends++;throw new Error('must not send');}});
  assert.equal((await relay(new Request('https://example.test',{method:'POST',body:'{}'}))).status,401);
  const input={eventID:crypto.randomUUID(),token:'aa'.repeat(32),environment:'sandbox',bundleID:MAIN_PUSH_BUNDLE,kind:'alert',payload:{aps:{alert:'Hi'}},collapseID:'ab'.repeat(32),expiresAt:new Date(Date.now()+60000)};
  let captured;await sendLegacyPush(input,push,async(url,options)=>{captured={url,options};return Response.json({delivered:true,retryable:false,invalidateToken:false,reason:'ok'});});
  assert.equal((await relay(new Request(captured.url,{...captured.options,body:captured.options.body.replace('Hi','Changed')}))).status,401);
  assert.equal((await relay(new Request(captured.url,{...captured.options,headers:{...captured.options.headers,'X-SpyClash-Relay-Timestamp':String(Math.floor(Date.now()/1000)-120)}}))).status,401);assert.equal(sends,0);
});
test('main-bundle UUID-room Live Activity keeps private words out of relay and ends after closure',async()=>{
  const a=await actor(),roomID=crypto.randomUUID(),matchID=crypto.randomUUID();rooms.push(roomID);
  const room={id:roomID,match_id:matchID,status:'playing',players:[{user_id:a.id,email:a.email,name:'Agent'}],game_mode:'associations',round_number:1,category:'Fruit',word:'SECRET',secret_word:'SECRET',spy_emails:[a.email],game_started_at:new Date().toISOString(),game_duration_seconds:900,current_asker_email:a.email,updated_date:new Date().toISOString()};
  await db`insert into full_game_private.rooms(id,code,revision,state) values(${roomID},${crypto.randomUUID().slice(0,6).toUpperCase()},1,${db.json(room)})`;
  await db.begin(tx=>dispatchPush({tx,actor:a,config:push,now:new Date()},{action:'register_live_activity_token',installation_id:crypto.randomUUID(),token_kind:'activity',activity_id:crypto.randomUUID(),room_id:roomID,match_id:matchID,live_activity_token:'ef'.repeat(32),environment:'production',bundle_id:MAIN_PUSH_BUNDLE,locale:'ru'}));
  const events=[];
  const relay=createRelayHandler({config:{SPYCLASH_SUPABASE_PUSH_RELAY_ENABLED:'true',SPYCLASH_SUPABASE_PUSH_RELAY_SECRET:push.BASE44_PUSH_RELAY_SECRET},send:async input=>{assert.equal(input.kind,'liveactivity');assert.ok(!JSON.stringify(input.payload).includes('SECRET'));events.push(input.payload.aps.event);return {delivered:true,retryable:false,invalidateToken:false,reason:'ok'};}});
  const send=input=>sendLegacyPush(input,push,async(url,options)=>relay(new Request(url,options)));
  await reconcileCommittedEvents(db,push);await drainPushOutbox(db,push,{send});
  await db`update full_game_private.rooms set closed=true where id=${roomID}`;
  await reconcileCommittedEvents(db,push);await drainPushOutbox(db,push,{send});
  assert.deepEqual(events,['update','end']);
});

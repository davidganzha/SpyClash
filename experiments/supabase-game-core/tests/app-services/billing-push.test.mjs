import assert from 'node:assert/strict';
import test, {before,after} from 'node:test';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {dispatchMembership,prepareMembershipExternal,WEEKLY_PRODUCT,cleanupBillingPush} from '../../supabase/functions/app-services/membership.ts';
import {dispatchPush,enqueueAppPush,TEST_PUSH_BUNDLE} from '../../supabase/functions/app-services/push.ts';
import {drainPushOutbox,reconcileCommittedEvents} from '../../supabase/functions/app-services/worker.ts';
import {prepareLegacyExternal,dispatchLegacy,validateLegacyImport,dryRunLegacyImport} from '../../supabase/functions/app-services/legacy.ts';
import {encryptToken,decryptToken} from '../../supabase/functions/app-services/integration-crypto.ts';
let db;
const actor=()=>{const id=crypto.randomUUID();return {id,email:id+'@example.test',contactEmail:'fixture@example.test',full_name:'Fixture',metadata:{}};};
const owners=[];
const rooms=[];
const config={APP_PUSH_ENABLED:'true',APP_PUSH_DELIVERY_ENABLED:'true',APNS_TOPIC:TEST_PUSH_BUNDLE,PUSH_TOKEN_ENCRYPTION_KEY:'01'.repeat(32)};
const billing={SPYCLASH_LIMITLESS_ENABLED:'true',SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'true',APP_IAP_ENABLED:'true',APP_IAP_BUNDLE_ID:TEST_PUSH_BUNDLE,APP_IAP_ENVIRONMENT:'Sandbox',APP_IAP_KEY_ID:'fixture',APP_IAP_ISSUER_ID:'fixture',APP_IAP_PRIVATE_KEY_P8:'fixture',APP_IAP_ROOT_CERTIFICATES_JSON:'[]'};
const legacy={APP_ENVIRONMENT:'staging',LEGACY_BRIDGE_ENABLED:'true',BASE44_STAGING_ORIGIN:'https://isolated.example.test',BASE44_STAGING_ORIGIN_ALLOWLIST:'["https://isolated.example.test"]',BASE44_STAGING_APP_ID:'a'.repeat(24)};
async function fixture(){const a=actor();owners.push(a.id);await db`insert into app_private.profiles(user_id,state,contact_email) values(${a.id},'active',${a.contactEmail})`;return a;}
async function call(fn,a,body,settings={},evidence){return db.begin(tx=>fn({tx,actor:a,now:new Date(),config:settings,evidence},body));}
before(async()=>{
  let url=process.env.DATABASE_URL;
  if(!url){const status=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});assert.equal(status.status,0,'Local Supabase must already be running');url=JSON.parse(status.stdout).DB_URL;}
  const parsed=new URL(url);assert.equal(parsed.hostname,'127.0.0.1');assert.equal(parsed.port,'56322');
  db=postgres(url,{max:4,onnotice:()=>{}});
  await db.unsafe(readFileSync('supabase/schemas/full_game_core.sql','utf8'));
  await db.unsafe(readFileSync('supabase/functions/app-services/services-schema.sql','utf8'));
  await db.unsafe(readFileSync('supabase/functions/app-services/billing-push-schema.sql','utf8'));
});
after(async()=>{
  if(!db)return;
  for(const id of owners){await db`delete from app_private.notification_events where recipient_id=${id} or actor_id=${id}`;await db`delete from app_private.push_registrations where user_id=${id}`;await db`delete from app_private.legacy_operations where user_id=${id}`;await db`delete from app_private.legacy_links where user_id=${id}`;await db`delete from app_private.entitlements where user_id=${id}`;await db`delete from app_private.apple_accounts where user_id=${id}`;await db`delete from app_private.membership_grants where user_id=${id}`;await db`delete from app_private.profiles where user_id=${id}`;}
  for(const id of rooms){await db`delete from full_game_private.outbox where room_id=${id}`;await db`delete from full_game_private.rooms where id=${id}`;}
  await db.end();
});
test('membership preserves universal and gated weekly; forged evidence cannot grant',async()=>{
  const a=await fixture();
  assert.equal((await call(dispatchMembership,a,{action:'check'})).protocol,'casada');
  assert.equal((await call(dispatchMembership,a,{action:'check'},billing)).active,false);
  await assert.rejects(call(dispatchMembership,a,{action:'prepare',requested_product_id:'com.spyclash.ios.limitless.monthly'},billing),e=>e.code==='unsupported_product');
  const contexts=await Promise.all(Array.from({length:4},()=>call(dispatchMembership,a,{action:'prepare'},billing)));
  assert.equal(new Set(contexts.map(c=>c.app_account_token)).size,1);assert.equal(contexts[0].product_id,WEEKLY_PRODUCT);
  await assert.rejects(call(dispatchMembership,a,{action:'sync_transaction',signed_transaction:'x'.repeat(30)},billing,{actor:a.id,verified:{}}),e=>e.code==='verified_transaction_required');
});
test('verified canonical transaction enforces immutable owner and older status cannot overwrite',async()=>{
  const a=await fixture(),b=await fixture();
  const purchase=await call(dispatchMembership,a,{action:'prepare'},billing);
  const body={action:'sync_transaction',signed_transaction:'fixture-jws-not-real'.repeat(2)};
  const transaction={productId:WEEKLY_PRODUCT,bundleId:TEST_PUSH_BUNDLE,environment:'Sandbox',originalTransactionId:crypto.randomUUID(),transactionId:crypto.randomUUID(),appAccountToken:purchase.app_account_token,expiresDate:Date.now()+3600_000,signedDate:Date.now()};
  const verify=async()=>({transaction,status:1,checkedAtMilliseconds:Date.now()});
  const evidence=await prepareMembershipExternal({actor:a,body,config:billing},{verify});
  const saved=await call(dispatchMembership,a,body,billing,evidence);assert.equal(saved.server_status_verified,true);
  assert.equal((await call(dispatchMembership,a,{action:'check'},billing)).active,true);
  const forgedOwner=await prepareMembershipExternal({actor:b,body,config:billing},{verify});
  await assert.rejects(call(dispatchMembership,b,body,billing,forgedOwner),e=>e.code==='purchase_owner_mismatch');
  await db`update app_private.entitlements set provider_event_at=clock_timestamp()+interval '1 hour',data=data||${db.json({status:'revoked',provider_event_at:new Date(Date.now()+3600_000).toISOString()})},active=false where user_id=${a.id}`;
  const delayed=await prepareMembershipExternal({actor:a,body,config:billing},{verify});
  assert.equal((await call(dispatchMembership,a,body,billing,delayed)).entitlement.status,'revoked');
});
test('encrypted token binds actor and topic; duplicate registration and event enqueue are idempotent',async()=>{
  const a=await fixture(),b=await fixture(),token='ab'.repeat(32),installation=crypto.randomUUID();
  const body={action:'register_device',installation_id:installation,apns_token:token,environment:'sandbox',bundle_id:TEST_PUSH_BUNDLE,alert_authorized:true,locale:'ru'};
  const first=await call(dispatchPush,a,body,config),second=await call(dispatchPush,a,body,config);assert.equal(first.registration_id,second.registration_id);
  await assert.rejects(call(dispatchPush,b,body,config),e=>e.code==='push_owner_mismatch');
  await assert.rejects(call(dispatchPush,a,{...body,bundle_id:'com.spyclash.ios'},config),e=>e.code==='push_topic_forbidden');
  const [stored]=await db`select token_ciphertext from app_private.push_registrations where id=${first.registration_id}`;assert.ok(!JSON.stringify(stored).includes(token));
  const encrypted=await encryptToken(token,config.PUSH_TOKEN_ENCRYPTION_KEY,'owner-a');await assert.rejects(decryptToken(encrypted,config.PUSH_TOKEN_ENCRYPTION_KEY,'owner-b'));
  const event={id:crypto.randomUUID(),event_type:'friend_request',recipient_id:a.id,data:{title_en:'Hello',body_en:'Request',title_ru:'Привет',body_ru:'Запрос'}};
  await db`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id) values(${event.id},'friend_request',${crypto.randomUUID()},${b.id},${a.id})`;
  await db.begin(async tx=>{const ctx={tx,actor:a,now:new Date(),config};await enqueueAppPush(ctx,event);await enqueueAppPush(ctx,event);});
  const rows=await db`select * from app_private.push_outbox where event_key=${event.id}`;assert.equal(rows.length,1);assert.equal(rows[0].payload.aps.alert.title,'Привет');
  let sends=0;const result=await drainPushOutbox(db,config,{send:async()=>{sends++;return {delivered:true,retryable:false,reason:'delivered'};}});assert.equal(result.delivered,1);assert.equal(sends,1);
});
test('hidden notification and deleted-account outbox work is cancelled before delivery',async()=>{
  const a=await fixture();const body={action:'register_device',installation_id:crypto.randomUUID(),apns_token:'cd'.repeat(32),environment:'sandbox',bundle_id:TEST_PUSH_BUNDLE,alert_authorized:true};await call(dispatchPush,a,body,config);
  const event={id:crypto.randomUUID(),event_type:'friend_request',recipient_id:a.id,data:{title:'test',body:'test'}};
  await db`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id,visible) values(${event.id},'friend_request',${crypto.randomUUID()},${a.id},${a.id},false)`;
  await db.begin(tx=>enqueueAppPush({tx,actor:a,now:new Date(),config},event));
  let sent=0;const result=await drainPushOutbox(db,config,{send:async()=>{sent++;return {delivered:true,retryable:false,reason:'delivered'};}});assert.equal(sent,0);assert.equal(result.cancelled,1);
  await call(cleanupBillingPush,a,{},config);assert.equal((await db`select * from app_private.push_registrations where user_id=${a.id}`).length,0);
});
test('legacy bridge rejects redirected canonical app and binds verified identity before durable generation',async()=>{
  const a=await fixture(),credential='legacy-fixture-credential-no-supabase';let requests=[];
  const fetcher=async(url,options)=>{requests.push({url,options});if(url.endsWith('/me'))return Response.json({id:'verified-legacy-id'});return Response.json({name:'Theme',category:'Theme',words:['One','Two'],ai_limit:10});};
  await assert.rejects(prepareLegacyExternal({actor:a,body:{action:'link',base44_access_token:credential},config:{...legacy,BASE44_STAGING_APP_ID:'69a0e57fa939f578082f8091'}},{fetch:fetcher}),e=>e.code==='legacy_destination_forbidden');assert.equal(requests.length,0);
  const linkBody={action:'link',base44_access_token:credential},link=await prepareLegacyExternal({actor:a,body:linkBody,config:legacy},{fetch:fetcher});await call(dispatchLegacy,a,linkBody,legacy,link);
  const body={action:'generate',request_id:crypto.randomUUID(),theme:'Theme',count:2,base44_access_token:credential};
  const first=await prepareLegacyExternal({actor:a,body,config:legacy},{fetch:fetcher,db});assert.equal((await call(dispatchLegacy,a,body,legacy,first)).words.length,2);
  const retry=await prepareLegacyExternal({actor:a,body,config:legacy},{fetch:fetcher,db});await call(dispatchLegacy,a,body,legacy,retry);
  assert.equal(requests.filter(r=>r.url.endsWith('generateWordPack')).length,1);
  assert.equal(requests.at(-1).options.headers.Authorization,'Bearer '+credential);
  await assert.rejects(prepareLegacyExternal({actor:a,body:{...body,theme:'Different'},config:legacy},{fetch:fetcher,db}),e=>e.code==='request_id_reused');
});
test('import dry run rejects conflicting identity ownership and source drift',()=>{
  const a=actor(),row={legacyID:'old',userID:a.id,sourceID:'row',digest:'a'.repeat(64)};
  assert.equal(validateLegacyImport([row,row]).rows,1);
  assert.throws(()=>validateLegacyImport([row,{...row,userID:crypto.randomUUID()}]),e=>e.code==='ambiguous_legacy_owner');
  assert.throws(()=>validateLegacyImport([row,{...row,digest:'b'.repeat(64)}]),e=>e.code==='conflicting_source_row');
});
test('Supabase JWT is rejected before any legacy HTTP request',async()=>{
  const a=await fixture();let calls=0;const token='fixture.'+btoa(JSON.stringify({iss:'https://test.supabase.co/auth/v1'}))+'.fixture';
  await assert.rejects(prepareLegacyExternal({actor:a,body:{action:'link',base44_access_token:token},config:legacy},{fetch:async()=>{calls++;return Response.json({});}}),e=>e.code==='wrong_credential_provider');assert.equal(calls,0);
});
test('lost generation response keeps durable request for retry and rejects changed body',async()=>{
  const a=await fixture();let generationAttempts=0;let providerInvocations=0;const seen=new Set();
  const fetcher=async(url,options)=>{
    if(url.endsWith('/me'))return Response.json({id:'lost-ack-'+a.id});
    generationAttempts++;const request=JSON.parse(options.body);if(!seen.has(request.request_id)){seen.add(request.request_id);providerInvocations++;throw new Error('simulated connection lost after upstream commit');}
    return Response.json({category:'Words',words:['Apple','Pear']});
  };
  const linkBody={action:'link',base44_access_token:'staging-legacy-test-credential'};
  await call(dispatchLegacy,a,linkBody,legacy,await prepareLegacyExternal({actor:a,body:linkBody,config:legacy},{fetch:fetcher}));
  const body={action:'generate',request_id:crypto.randomUUID(),theme:'Fruit',count:2,base44_access_token:linkBody.base44_access_token};
  await assert.rejects(prepareLegacyExternal({actor:a,body,config:legacy},{fetch:fetcher,db}));
  const [reservation]=await db`select state from app_private.legacy_operations where user_id=${a.id} and request_id=${body.request_id}`;assert.equal(reservation.state,'reserved');
  await assert.rejects(prepareLegacyExternal({actor:a,body:{...body,count:3},config:legacy},{fetch:fetcher,db}),e=>e.code==='request_id_reused');
  const evidence=await prepareLegacyExternal({actor:a,body,config:legacy},{fetch:fetcher,db});await call(dispatchLegacy,a,body,legacy,evidence);
  assert.equal(generationAttempts,2);assert.equal(providerInvocations,1);
});
test('push transport outage retries once eligible; competing workers cannot claim same lease',async()=>{
  const a=await fixture();const body={action:'register_device',installation_id:crypto.randomUUID(),apns_token:crypto.randomUUID().replaceAll('-','').repeat(2),environment:'sandbox',bundle_id:TEST_PUSH_BUNDLE,alert_authorized:true};await call(dispatchPush,a,body,config);
  const event={id:crypto.randomUUID(),event_type:'friend_request',recipient_id:a.id,data:{title:'Test',body:'Retry'}};
  await db`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id) values(${event.id},'friend_request',${crypto.randomUUID()},${a.id},${a.id})`;
  await db.begin(tx=>enqueueAppPush({tx,actor:a,now:new Date(),config},event));
  let attempts=0;const send=async()=>{attempts++;return {delivered:false,retryable:true,reason:'Unavailable'};};
  await Promise.all([drainPushOutbox(db,config,{send}),drainPushOutbox(db,config,{send})]);assert.equal(attempts,1);
  const [pending]=await db`select state,attempts from app_private.push_outbox where event_key=${event.id}`;assert.equal(pending.state,'pending');assert.equal(pending.attempts,1);
  await db`update app_private.push_outbox set available_at=clock_timestamp()-interval '1 second' where event_key=${event.id}`;
  const success=await drainPushOutbox(db,config,{send:async()=>({delivered:true,retryable:false,reason:'delivered'})});assert.equal(success.delivered,1);
});
test('committed live events preserve privacy, replay dedup, and terminal end after room advanced',async()=>{
  const a=await fixture(),roomID=crypto.randomUUID(),matchID=crypto.randomUUID(),installation=crypto.randomUUID();rooms.push(roomID);
  const room={id:roomID,match_id:matchID,status:'playing',players:[{user_id:a.id,email:a.email,name:'Agent',avatar:'🕵️'}],
    game_mode:'associations',round_number:1,category:'Fruit',word:'PRIVATE_WORD',secret_word:'PRIVATE_WORD',spy_emails:[a.email],
    game_started_at:new Date().toISOString(),game_duration_seconds:900,current_asker_email:a.email,updated_date:new Date().toISOString()};
  await db`insert into full_game_private.rooms(id,code,revision,state) values(${roomID},${crypto.randomUUID().slice(0,6).toUpperCase()},1,${db.json(room)})`;
  const registration={action:'register_live_activity_token',installation_id:installation,token_kind:'activity',activity_id:crypto.randomUUID(),room_id:roomID,match_id:matchID,live_activity_token:'ef'.repeat(32),environment:'sandbox',bundle_id:TEST_PUSH_BUNDLE,locale:'ru'};
  await call(dispatchPush,a,registration,config);
  await reconcileCommittedEvents(db,config);await reconcileCommittedEvents(db,config);
  const updates=await db`select * from app_private.push_outbox where room_id=${roomID}`;assert.equal(updates.length,1);
  const serialized=JSON.stringify(updates[0].payload);assert.ok(!serialized.includes('PRIVATE_WORD'));assert.ok(!serialized.includes(a.email));assert.equal(updates[0].payload.aps['content-state'].privateIntel,null);
  const terminalID='game-finished:'+matchID;
  await db`insert into full_game_private.outbox(id,room_id,event) values(${terminalID},${roomID},${db.json({type:'game_finished',match_id:matchID,recipient_user_ids:[a.id]})})`;
  // Replay overtakes the worker. The old match's exact activity must still end.
  await db`update full_game_private.rooms set revision=2,state=${db.json({...room,match_id:crypto.randomUUID(),updated_date:new Date(Date.now()+1000).toISOString()})} where id=${roomID}`;
  await reconcileCommittedEvents(db,config);await reconcileCommittedEvents(db,config);
  const ends=await db`select * from app_private.push_outbox where room_id=${roomID} and payload->'aps'->>'event'='end'`;assert.equal(ends.length,1);assert.equal(ends[0].match_id,matchID);
  const delivered=[];await drainPushOutbox(db,config,{send:async input=>{delivered.push(input);return {delivered:true,retryable:false,reason:'delivered'};}});
  assert.equal(delivered.length,1);assert.equal(delivered[0].payload.aps.event,'end');
  const [reg]=await db`select active from app_private.push_registrations where user_id=${a.id}`;assert.equal(reg.active,false);
});
test('import dry run reports unresolved verified mappings without writing content',async()=>{
  const a=await fixture();await db`insert into app_private.legacy_links(user_id,legacy_user_id,verified_at,source_origin) values(${a.id},${'import-'+a.id},clock_timestamp(),'https://isolated.example.test')`;
  const row={entity:'WordPack',source_id:'source-one',legacy_user_id:'import-'+a.id,digest:'a'.repeat(64)};
  const result=await dryRunLegacyImport(db,[row,row,{...row,source_id:'source-two',legacy_user_id:'unlinked'}, {...row,digest:'b'.repeat(64)}]);
  assert.equal(result.dry_run,true);assert.equal(result.ready_count,1);assert.equal(result.unresolved_count,2);
  assert.deepEqual(result.unresolved.map(r=>r.reason),['verified_identity_mapping_required','source_digest_conflict']);
  assert.equal(result.ready[0].user_id,a.id);
});
test('expired claimed tail reclaimed by another worker is never sent by stale owner',async()=>{
  const a=await fixture();await call(dispatchPush,a,{action:'register_device',installation_id:crypto.randomUUID(),apns_token:crypto.randomUUID().replaceAll('-','').repeat(2),environment:'sandbox',bundle_id:TEST_PUSH_BUNDLE,alert_authorized:true},config);
  const event={id:crypto.randomUUID(),event_type:'friend_request',recipient_id:a.id,data:{title:'Lease',body:'Race'}};
  await db`insert into app_private.notification_events(id,event_type,source_id,actor_id,recipient_id) values(${event.id},'friend_request',${crypto.randomUUID()},${a.id},${a.id})`;
  await db.begin(tx=>enqueueAppPush({tx,actor:a,now:new Date(),config},event));
  let claimedResolve,releaseResolve;
  const claimed=new Promise(resolve=>claimedResolve=resolve),release=new Promise(resolve=>releaseResolve=resolve);
  // Pause after the first worker's real database claim, without a production
  // test hook or wall-clock sleep. The second worker can then reclaim the lease.
  const pausedDB=new Proxy(db,{get(target,property){if(property==='begin')return async(...args)=>{
    const result=await target.begin(...args);
    if(Array.isArray(result)&&result.some(row=>row.event_key===event.id&&row.lease_id)){claimedResolve();await release;}
    return result;
  };return Reflect.get(target,property);}});
  let staleSends=0,newSends=0;
  const oldRun=drainPushOutbox(pausedDB,config,{send:async()=>{staleSends++;return {delivered:true,retryable:false,reason:'delivered'};}});
  await claimed;
  const [before]=await db`select lease_id from app_private.push_outbox where event_key=${event.id}`;
  await db`update app_private.push_outbox set lease_until=clock_timestamp()-interval '1 second' where event_key=${event.id}`;
  await drainPushOutbox(db,config,{send:async()=>{newSends++;return {delivered:true,retryable:false,reason:'delivered'};}});
  releaseResolve();const oldResult=await oldRun;
  const [after]=await db`select lease_id,state from app_private.push_outbox where event_key=${event.id}`;
  assert.notEqual(after.lease_id,before.lease_id);assert.equal(after.state,'delivered');assert.equal(newSends,1);assert.equal(staleSends,0);assert.equal(oldResult.skipped,1);
});

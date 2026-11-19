import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {nativeAccount} from '../../supabase/functions/app-services/native-account.ts';
import {accountGate,sessionGate} from '../../supabase/functions/app-services/account-gate.ts';
import {dispatchMembership,prepareMembershipExternal,cleanupBillingPush,WEEKLY_PRODUCT} from '../../supabase/functions/app-services/membership.ts';
import {nativeAccountConfiguration,appleVerificationTargets} from '../../supabase/functions/app-services/native-apple.ts';
import {prepareNativeAppleDeletion,assertAppleRevocationComplete} from '../../supabase/functions/app-services/native-apple-deletion.ts';
import {prepareMainAccountDeletion} from '../../supabase/functions/app-services/main-account-deletion.ts';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {prepareGenerationRewards,dispatchGenerationRewards} from '../../supabase/functions/app-services/generation-rewards.ts';
import {canonical,digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import {verifyAppleSourceErasureRequest} from '../../../../base44/functions/deleteAccount/apple-source-erasure.ts';
let db;const actors=[];
const config={SUPABASE_URL:'http://127.0.0.1:56321',APP_BILLING_PROVIDER:'base44',APP_IAP_ENABLED:'true',APP_NATIVE_APPLE_IAP_ENABLED:'true',APP_NATIVE_GAME_CENTER_IAP_ENABLED:'true',APP_IAP_BUNDLE_ID:'com.spyclash.ios',APP_IAP_APPLE_ID:'6793534085',APP_IAP_ENVIRONMENT:'SandboxAndProduction',SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'true',APP_IAP_KEY_ID:'fixture',APP_IAP_ISSUER_ID:'fixture',APP_IAP_PRIVATE_KEY_P8:'fixture',APP_IAP_ROOT_CERTIFICATES_JSON:'[]',APPLE_TEAM_ID:'AAAAAAAAAA',APPLE_KEY_ID:'BBBBBBBBBB',APPLE_PRIVATE_KEY_P8_B64:btoa('-----BEGIN PRIVATE KEY-----fixture'),APPLE_GRANT_ENCRYPTION_KEY:'33'.repeat(32),APP_DELETION_RECEIPT_SECRET:'11'.repeat(32),APP_DELETION_ARCHIVE_SECRET:'22'.repeat(32)};
before(async()=>{const s=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});assert.equal(s.status,0);const url=new URL(JSON.parse(s.stdout).DB_URL);assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');db=postgres(url.href,{max:5,onnotice:()=>{}});});
after(async()=>{if(!db)return;for(const a of actors){
 await db`delete from game_center_private.generation_reward_attempts where user_id=${a.id}`;
 await db`delete from game_center_private.generation_reward_enrollments where user_id=${a.id}`;
 await db`delete from game_center_private.generation_requests where user_id=${a.id}`;
 await db`delete from apple_private.attempts where identity_key=${a.key}`;
 await db`delete from apple_private.grants where user_id=${a.id}`;
 await db`delete from apple_private.deletions where user_id=${a.id}`;
 await db`delete from apple_private.migration_snapshots where user_id=${a.id}`;
 await db`delete from apple_private.billing_token_aliases where user_id=${a.id}`;
 await db`delete from app_private.receipts where actor_id=${a.id}`;
 await db`delete from app_private.lifecycle_jobs where user_id=${a.id}`;
 await db`delete from app_private.main_account_deletions where user_id=${a.id}`;
 await db`delete from apple_private.accounts where user_id=${a.id}`;
 await db`delete from game_center_private.accounts where user_id=${a.id}`;
 await db`delete from app_private.entitlements where user_id=${a.id}`;
 await db`delete from app_private.apple_accounts where user_id=${a.id}`;
 await db`delete from app_private.legacy_links where user_id=${a.id}`;
 await db`delete from app_private.legacy_session_accounts where user_id=${a.id}`;
 await db`delete from app_private.profiles where user_id=${a.id}`;
 await db`delete from auth.users where id=${a.id}`;
 }await db.end();});
async function fixture({ready=true,legacy=true,provider='apple'}={}){
 const id=crypto.randomUUID(),key=id.replaceAll('-','').repeat(2),a={id,key,email:id+'@example.test',contactEmail:'',full_name:'Fixture',metadata:{provider:'apple'},legacyID:legacy?'legacy-'+id:null};actors.push(a);
 await db`insert into app_private.profiles(user_id,state,data) values(${id},'active',${db.json({display_name:'Preserved',games_played:17})})`;
 if(legacy){await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${id},${a.legacyID},'https://spyclash.com',clock_timestamp())`;
 await db`insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email,state,import_completed) values(${key},${a.legacyID},'https://spyclash.com','69a0e57fa939f578082f8091',${id},${id+'@accounts.spyclash.invalid'},'ready',true)`;}
 if(provider==='apple')await db`insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,legacy_user_id,state,migration_complete,migration_version) values(${key},${'apple-subject:'+key},'com.spyclash.ios',${id},${id+'@accounts.spyclash.invalid'},${a.legacyID},${ready?'ready':'pending'},${ready},1)`;
 else if(provider==='game_center')await db`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${key},${id},${id+'@accounts.spyclash.invalid'},'ready')`;
 return a;
}
async function call(a,body,evidence){return db.begin(async tx=>{await accountGate(tx,a.id);return dispatchMembership({tx,actor:a,config,now:new Date(),evidence},body)});}
test('private completed subject migration preserves UUID/profile and permits native services with historical provenance',async()=>{
 const a=await fixture();const native=await db.begin(tx=>nativeAccount(tx,a.id));assert.equal(native.user_id,a.id);assert.equal(native.provider,'apple');
 assert.equal((await db`select data from app_private.profiles where user_id=${a.id}`)[0].data.games_played,17);
 assert.equal((await call(a,{action:'check'})).protocol,'limitless');
 await db`insert into game_center_private.generation_requests(user_id,request_id,request_hash,usage_date,state) values(${a.id},${crypto.randomUUID()},${'a'.repeat(64)},current_date,'pending')`;
 assert.equal((await call(a,{action:'check'})).ai_generations_today,1);
});
test('pending Apple is fenced from app access and metadata cannot opt legacy account into native billing',async()=>{
 const pending=await fixture({ready:false});await assert.rejects(db.begin(tx=>accountGate(tx,pending.id)),e=>e.code==='apple_account_unavailable');
 await assert.rejects(db.begin(tx=>nativeAccount(tx,pending.id)),e=>e.code==='apple_migration_pending');
 const forged=await fixture({provider:'none'});assert.equal(await db.begin(tx=>nativeAccount(tx,forged.id)),undefined);
 await assert.rejects(prepareMembershipExternal({actor:forged,body:{action:'check'},config},{db,fetch:async()=>{throw Error('must not fetch')}}),e=>e.code==='legacy_billing_unconfigured');
});
test('GC mapping remains native but conflicting legacy provenance stays rejected',async()=>{
 const good=await fixture({provider:'game_center',legacy:false});assert.equal((await db.begin(tx=>nativeAccount(tx,good.id))).provider,'game_center');
 const bad=await fixture({provider:'game_center'});await assert.rejects(db.begin(tx=>nativeAccount(tx,bad.id)),e=>e.code==='game_center_identity_conflict');
});
test('Apple verification gate is separate from GC, requires exact main bundle and explicit enable',()=>{
 const c=nativeAccountConfiguration(config,'apple');assert.equal(appleVerificationTargets(c).length,2);
 assert.deepEqual(appleVerificationTargets({...c,APP_NATIVE_APPLE_IAP_ENABLED:'false'}),[]);
 assert.deepEqual(appleVerificationTargets({...c,APP_IAP_BUNDLE_ID:'other'}),[]);
});
test('both historical tokens restore to same UUID and cannot be claimed by another account',async()=>{
 const a=await fixture(),b=await fixture(),tokens=[crypto.randomUUID(),crypto.randomUUID()];
 await db`insert into app_private.apple_accounts(user_id,app_account_token) values(${a.id},${tokens[0]})`;
 for(const token of tokens){await db`insert into apple_private.billing_token_aliases(app_account_token,user_id,source_record_id) values(${token},${a.id},${'fixture-'+token})`;
 const body={action:'sync_transaction',signed_transaction:'fixture-verified-transaction-'+token};
 const verify=async()=>({transaction:{productId:WEEKLY_PRODUCT,bundleId:'com.spyclash.ios',environment:'Sandbox',originalTransactionId:BigInt('0x'+token.replaceAll('-','')).toString(),transactionId:BigInt('0x'+crypto.randomUUID().replaceAll('-','')).toString(),appAccountToken:token,expiresDate:Date.now()+3600000,signedDate:Date.now()},status:1});
 const evidence=await prepareMembershipExternal({actor:a,body,config},{db,verify});assert.equal((await call(a,body,evidence)).success,true);
 const foreign=await prepareMembershipExternal({actor:b,body,config},{db,verify});await assert.rejects(call(b,body,foreign),e=>e.code==='purchase_owner_mismatch');}
 assert.equal((await db`select count(*)::int total from app_private.entitlements where user_id=${a.id}`)[0].total,2);
 await db.begin(tx=>cleanupBillingPush({tx,actor:a,now:new Date(),config}));assert.equal((await db`select count(*)::int total from apple_private.billing_token_aliases where user_id=${a.id} and state='deleted'`)[0].total,2);
});
test('replay nonce and authorization-code hashes are globally unique and exchanging blocks final deletion',async()=>{
 const a=await fixture(),b=await fixture();const nonce='c'.repeat(64),code='d'.repeat(64);
 await db`insert into apple_private.attempts(request_id,identity_key,nonce_hash,code_hash,state,expires_at) values(${crypto.randomUUID()},${a.key},${nonce},${code},'exchanging',clock_timestamp()+interval '5 minutes')`;
 await assert.rejects(db`insert into apple_private.attempts(request_id,identity_key,nonce_hash,code_hash,state,expires_at) values(${crypto.randomUUID()},${b.key},${nonce},${'e'.repeat(64)},'reserved',clock_timestamp()+interval '5 minutes')`,e=>e.code==='23505');
 await assert.rejects(db.begin(tx=>assertAppleRevocationComplete(tx,a.id)),e=>e.code==='apple_account_deletion_pending');
 await db`update apple_private.attempts set state='uncertain' where identity_key=${a.key}`;
 await assert.rejects(db.begin(tx=>assertAppleRevocationComplete(tx,a.id)),e=>e.code==='apple_account_deletion_pending');
});
test('missing historical erasure capability leaves Apple and profile active',async()=>{
 const a=await fixture();await assert.rejects(prepareNativeAppleDeletion({actor:a,body:{request_id:crypto.randomUUID()},config},{db,fetch:async()=>Response.json({protocol:'spyclash-deletion-receipt-v2'}),revoke:async()=>{throw Error('must not revoke')}}),e=>e.code==='apple_source_erasure_unconfigured');
 assert.equal((await db`select state from apple_private.accounts where user_id=${a.id}`)[0].state,'ready');assert.equal((await db`select state from app_private.profiles where user_id=${a.id}`)[0].state,'active');
});
test('completed Apple session outlives legacy revalidation interval; ordinary legacy still needs revalidation',async()=>{
 for(const provider of ['apple','none']){const a=await fixture({provider}),sid=crypto.randomUUID();
 await db`insert into auth.users(id,aud,role,email) values(${a.id},'authenticated','authenticated',${a.email})`;
 await db`insert into auth.sessions(id,user_id,created_at,updated_at) values(${sid},${a.id},clock_timestamp()-interval '2 hours',clock_timestamp())`;
 if(provider==='apple'){await sessionGate(db,a.id,sid);
 for(const state of ['deleting','deleted']){await db`update apple_private.accounts set state=${state} where user_id=${a.id}`;await sessionGate(db,a.id,sid);await assert.rejects(db.begin(tx=>accountGate(tx,a.id)),e=>e.code==='apple_account_unavailable');}
 }else await assert.rejects(sessionGate(db,a.id,sid),e=>e.code==='legacy_session_revalidation_required');}
});
test('Apple reward status uses native ledger without a legacy bearer or network request',async()=>{
 const a=await fixture(),body={action:'status'};assert.equal(await prepareGenerationRewards({actor:a,body,config},{db,fetch:async()=>{throw Error('unexpected Base44 request')}}),undefined);
 const status=await db.begin(async tx=>{await accountGate(tx,a.id);return dispatchGenerationRewards({tx,actor:a,config,now:new Date()},body)});
 assert.equal(typeof status.enabled,'boolean');
});
test('Apple deletion waits for revocation, signs exact source erasure, preserves intent across retry, and acknowledges only complete local wipe',async()=>{
 const a=await fixture();const input={actor:a,body:{service:'profile',action:'delete',deletion_scope:'account',request_id:crypto.randomUUID()},config};
 await db`insert into apple_private.migration_snapshots(user_id,source_sha256,data) values(${a.id},${'f'.repeat(64)},${db.json({source_user:{email:'fixture-private@example.test'},billing:[{app_account_token:'private-old-token'}]})})`;
 let sourceCalls=0,sourceRequest;
 const fetcher=async(url,options)=>{assert.equal(url,'https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/deleteAccountPublic');assert.equal(options.headers.Authorization,undefined);const body=JSON.parse(options.body);
 if(body.action==='deletion_capabilities')return Response.json({protocol:'spyclash-deletion-receipt-v2',apple_source_erasure_protocol:'spyclash-apple-source-erasure-v1'});
 const owner=await verifyAppleSourceErasureRequest(body,{secret:config.APP_DELETION_ARCHIVE_SECRET});assert.equal(owner.actorID,a.id);assert.equal(owner.legacyID,a.legacyID);sourceCalls++;sourceRequest=body.request_id;
 return Response.json({success:true,manual_apple_revocation_required:false,deletion_receipt:{complete:true,request_id:body.request_id,subject_hash:await digest('spyclash-delete-user-v1:'+a.legacyID),erasure_proof:{version:1,archive_alias_digest:await digest(canonical(body.archive_erasure_request.aliases)),apple_identity_keys:[],apple_record_ids:[]}}});};
 await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:fetcher,revokeApple:async()=>{throw Error('revocation temporarily unavailable')}}),e=>e.code==='apple_account_deletion_pending');
 assert.equal(sourceCalls,0);assert.equal((await db`select state from apple_private.accounts where user_id=${a.id}`)[0].state,'deleting');
 assert.equal((await db`select state,data from app_private.profiles where user_id=${a.id}`)[0].data.games_played,17);
 const original=input.body.request_id;input.body.request_id=crypto.randomUUID();
 const evidence=await prepareMainAccountDeletion(input,{db,fetch:fetcher,revokeApple:async()=>({revoked:0})});assert.equal(sourceRequest,original);
 const result=await executeApp(db,a,input.body,config,evidence);assert.equal(result.status,200);assert.equal(result.body.apple_account_deleted,true);assert.equal(result.body.native_account_deleted,undefined);
 assert.equal((await db`select state from apple_private.accounts where user_id=${a.id}`)[0].state,'deleted');
 assert.equal((await db`select state,data from app_private.profiles where user_id=${a.id}`)[0].state,'deleted');
 assert.equal((await db`select phase from app_private.main_account_deletions where user_id=${a.id}`)[0].phase,'complete');
 assert.equal((await db`select phase from apple_private.deletions where user_id=${a.id}`)[0].phase,'complete');
 assert.equal((await db`select 1 from apple_private.migration_snapshots where user_id=${a.id}`).length,0);
});

import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {accountGate} from '../../supabase/functions/app-services/account-gate.ts';
import {dispatchMembership,prepareMembershipExternal,refreshNativeMembership,membershipCapabilities,WEEKLY_PRODUCT,MONTHLY_PRODUCT,cleanupBillingPush} from '../../supabase/functions/app-services/membership.ts';
import {appleVerificationTargets,nativeGameCenterConfiguration,MAIN_APPLE_APP_ID,verifyApple} from '../../supabase/functions/app-services/native-apple.ts';
import {projectedProfiles} from '../../supabase/functions/app-services/profile.ts';
const config={APP_BILLING_PROVIDER:'base44',APP_IAP_ENABLED:'true',APP_NATIVE_GAME_CENTER_IAP_ENABLED:'true',APP_IAP_BUNDLE_ID:'com.spyclash.ios',APP_IAP_APPLE_ID:String(MAIN_APPLE_APP_ID),APP_IAP_ENVIRONMENT:'SandboxAndProduction',SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'true',APP_IAP_KEY_ID:'fixture',APP_IAP_ISSUER_ID:'fixture',APP_IAP_PRIVATE_KEY_P8:'fixture',APP_IAP_ROOT_CERTIFICATES_JSON:'[]'};
let db;const actors=[];
const appleID=()=>BigInt('0x'+crypto.randomUUID().replaceAll('-','')).toString();
before(async()=>{const status=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});assert.equal(status.status,0);const url=new URL(JSON.parse(status.stdout).DB_URL);assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');db=postgres(url.href,{max:4,onnotice:()=>{}});});
after(async()=>{if(!db)return;for(const a of actors){await db`delete from game_center_private.generation_requests where user_id=${a.id}`;await db`delete from app_private.entitlements where user_id=${a.id}`;await db`delete from app_private.apple_accounts where user_id=${a.id}`;await db`delete from game_center_private.accounts where user_id=${a.id}`;await db`delete from app_private.profiles where user_id=${a.id}`;}await db.end();});
async function fixture(native=true){const id=crypto.randomUUID();const a={id,email:id+'@example.test',contactEmail:'',full_name:'Test',metadata:{provider:'game_center'}};actors.push(a);await db`insert into app_private.profiles(user_id,state) values(${id},'active')`;if(native)await db`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${id.replaceAll('-','').repeat(2)},${id},${id+'@test.invalid'},'ready')`;return a;}
async function call(actor,body,evidence,settings=config){return db.begin(async tx=>{await accountGate(tx,actor.id);return dispatchMembership({tx,actor,config:settings,now:new Date(),evidence},body);});}
async function bought(actor,{environment='Sandbox',expires=Date.now()+3600000,status=1}={}){const p=await call(actor,{action:'prepare'}),body={action:'sync_transaction',signed_transaction:'fixture-untrusted-jws'.repeat(2)};const transaction={productId:WEEKLY_PRODUCT,bundleId:'com.spyclash.ios',environment,originalTransactionId:appleID(),transactionId:appleID(),appAccountToken:p.app_account_token,expiresDate:expires,signedDate:Date.now()};const verify=async()=>({transaction,status,checkedAtMilliseconds:Date.now()});const evidence=await prepareMembershipExternal({actor,body,config},{db,verify});await call(actor,body,evidence);return {transaction,body,verify};}
async function stale(a){await db`update app_private.entitlements set data=data||${db.json({last_verified_at:'2000-01-01T00:00:00Z',provider_event_at:'2000-01-01T00:00:00Z'})} where user_id=${a.id}`;}
test('native main Apple targets require exact server app identity and explicit environment gate',()=>{const native=nativeGameCenterConfiguration(config);assert.deepEqual(appleVerificationTargets(native).map(t=>t.environment),['Production','Sandbox']);for(const patch of [{APP_IAP_APPLE_ID:'123'},{APP_IAP_BUNDLE_ID:'com.spyclash.ios.gamecenter000'},{APP_NATIVE_GAME_CENTER_IAP_ENABLED:'false'},{APP_IAP_ENVIRONMENT:'anything'}])assert.deepEqual(appleVerificationTargets({...native,...patch}),[]);assert.equal(membershipCapabilities(native).apple_purchase_enabled,true);assert.deepEqual(appleVerificationTargets(config),[]);});
test('native account gets gated free access even when legacy rollout flags are absent',async()=>{const a=await fixture(),m=await call(a,{action:'check'});assert.equal(m.active,false);assert.equal(m.protocol,'limitless');assert.equal(m.benefits.ai_generations_daily_limit,10);assert.equal(m.ai_remaining,10);assert.match((await call(a,{action:'prepare'})).app_account_token,/^[a-f0-9-]{36}$/);});
test('native monthly checkout is independently gated and preserves the existing owner token and old client weekly product',async()=>{
 const a=await fixture();
 for(const flag of [undefined,'false','TRUE','1']) {
   await assert.rejects(call(a,{action:'prepare',requested_product_id:MONTHLY_PRODUCT},undefined,{...config,SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED:flag}),
     e=>e.code==='apple_monthly_purchase_unconfigured'&&e.status===503);
 }
 assert.equal((await db`select 1 from app_private.apple_accounts where user_id=${a.id}`).length,0);
 const enabled={...config,SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED:'true'};
 await assert.rejects(call(a,{action:'prepare',requested_product_id:MONTHLY_PRODUCT},undefined,{...enabled,SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'false'}),e=>e.code==='apple_purchase_unconfigured');
 for(const requested_product_id of ['',null,'unknown',{},[MONTHLY_PRODUCT]]) {
   await assert.rejects(call(a,{action:'prepare',requested_product_id},undefined,enabled),e=>e.code==='unsupported_product');
 }
 const monthly=await call(a,{action:'prepare_purchase',requested_product_id:MONTHLY_PRODUCT},undefined,enabled);
 const weekly=await call(a,{action:'prepare'},undefined,enabled);
 assert.equal(monthly.product_id,MONTHLY_PRODUCT);assert.equal(weekly.product_id,WEEKLY_PRODUCT);
 assert.equal(monthly.app_account_token,weekly.app_account_token);
});
test('native owned monthly restore and crossgrades work with checkout disabled and keep the exact submitted product',async()=>{
 const a=await fixture(),b=await fixture(),weekly=await bought(a);
 const disabled={...config,SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'false',SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED:'false'};
 for(const [submitted,canonical,status] of [[WEEKLY_PRODUCT,MONTHLY_PRODUCT,1],[MONTHLY_PRODUCT,WEEKLY_PRODUCT,1],[MONTHLY_PRODUCT,MONTHLY_PRODUCT,5]]) {
   const transaction={...weekly.transaction,transactionId:appleID(),productId:canonical,signedDate:Date.now()};
   const body={action:'sync_transaction',signed_transaction:'monthly-crossgrade-fixture-'+crypto.randomUUID()};
   const verify=async()=>({transaction,submittedProductID:submitted,status,checkedAtMilliseconds:Date.now()});
   const evidence=await prepareMembershipExternal({actor:a,body,config:disabled},{db,verify});
   const response=await call(a,body,evidence,disabled);
   assert.equal(response.server_status_verified,true);assert.equal(response.submitted_product_id,submitted);
   assert.equal(response.entitlement.product_id,canonical);
   const [row]=await db`select product_id,active,user_id from app_private.entitlements where user_id=${a.id}`;
   assert.equal(row.product_id,canonical);assert.equal(row.active,status===1);assert.equal(row.user_id,a.id);
   const foreign=await prepareMembershipExternal({actor:b,body,config:disabled},{db,verify});
   await assert.rejects(call(b,body,foreign,disabled),e=>e.code==='purchase_owner_mismatch');
 }
 assert.equal((await call(a,{action:'check'})).active,false);
});
test('editable provider metadata cannot bypass the legacy credential bridge',async()=>{const a=await fixture(false);let fetched=0;await assert.rejects(prepareMembershipExternal({actor:a,body:{action:'check'},config},{db,fetch:async()=>{fetched++;return Response.json({});}}),e=>e.code==='legacy_billing_unconfigured');assert.equal(fetched,0);});
test('native memberships count durable charged AI reservations only',async()=>{const a=await fixture();for(const charged of [true,true,false])await db`insert into game_center_private.generation_requests(user_id,request_id,request_hash,usage_date,charged,state) values(${a.id},${crypto.randomUUID()},${'a'.repeat(64)},(clock_timestamp() at time zone 'UTC')::date,${charged},'pending')`;const m=await call(a,{action:'check'});assert.equal(m.ai_generations_today,2);assert.equal(m.ai_remaining,8);});
test('verified main native purchase cannot be restored by a different Game Center account',async()=>{const a=await fixture(),b=await fixture(),purchase=await bought(a,{environment:'Production'});assert.equal((await call(a,{action:'check'})).active,true);const foreign=await prepareMembershipExternal({actor:b,body:purchase.body,config},{db,verify:purchase.verify});await assert.rejects(call(b,purchase.body,foreign),e=>e.code==='purchase_owner_mismatch');});
test('preparing a new purchase cannot claim an older foreign chain before its first server sync; its owner can recover',async()=>{
 const owner=await fixture(),other=await fixture();
 const original=await call(owner,{action:'prepare'}),prepared=await call(other,{action:'prepare_purchase'});
 assert.notEqual(original.app_account_token,prepared.app_account_token);
 assert.equal((await call(other,{action:'prepare_purchase'})).app_account_token,prepared.app_account_token);
 const body={action:'sync_transaction',signed_transaction:'verified-old-chain-fixture'.repeat(2)};
 const transaction={productId:WEEKLY_PRODUCT,bundleId:'com.spyclash.ios',environment:'Sandbox',originalTransactionId:appleID(),
   transactionId:appleID(),appAccountToken:original.app_account_token,expiresDate:Date.now()+3600000,signedDate:Date.now()};
 const verify=async()=>({transaction,status:1,checkedAtMilliseconds:Date.now()});
 // The verified Apple chain predates its first native entitlement sync.
 assert.equal((await db`select 1 from app_private.entitlements where user_id in (${owner.id},${other.id})`).length,0);
 const foreign=await prepareMembershipExternal({actor:other,body,config},{db,verify});
 await assert.rejects(call(other,body,foreign),e=>e.status===409&&e.code==='purchase_owner_mismatch');
 assert.equal((await call(other,{action:'check'})).active,false);
 assert.equal((await db`select 1 from app_private.entitlements where user_id in (${owner.id},${other.id})`).length,0);
 assert.equal((await db`select app_account_token from app_private.apple_accounts where user_id=${other.id}`)[0].app_account_token,prepared.app_account_token);
 assert.equal((await call(owner,{action:'prepare_purchase'})).app_account_token,original.app_account_token);
 const owned=await prepareMembershipExternal({actor:owner,body,config},{db,verify});
 assert.equal((await call(owner,body,owned)).server_status_verified,true);
 const restored=await prepareMembershipExternal({actor:owner,body,config},{db,verify});
 assert.equal((await call(owner,body,restored)).server_status_verified,true);
 assert.equal((await call(owner,{action:'check'})).active,true);
 assert.equal((await call(other,{action:'check'})).active,false);
 const rows=await db`select user_id from app_private.entitlements where user_id in (${owner.id},${other.id})`;
 assert.deepEqual(rows.map(row=>row.user_id),[owner.id]);
});
test('a prepared native account cannot adopt a verified historical token missing from the billing registry',async()=>{
 const actor=await fixture(),prepared=await call(actor,{action:'prepare_purchase'}),historicalToken=crypto.randomUUID();
 assert.notEqual(historicalToken,prepared.app_account_token);
 const body={action:'sync_transaction',signed_transaction:'verified-unknown-owner-fixture'.repeat(2)};
 const transaction={productId:WEEKLY_PRODUCT,bundleId:'com.spyclash.ios',environment:'Sandbox',originalTransactionId:appleID(),
   transactionId:appleID(),appAccountToken:historicalToken,expiresDate:Date.now()+3600000,signedDate:Date.now()};
 assert.equal((await db`select 1 from app_private.apple_accounts where app_account_token=${historicalToken}`).length,0);
 const evidence=await prepareMembershipExternal({actor,body,config},{db,verify:async()=>({transaction,status:1,checkedAtMilliseconds:Date.now()})});
 await assert.rejects(call(actor,body,evidence),e=>e.status===409&&e.code==='purchase_owner_mismatch');
 assert.equal((await call(actor,{action:'check'})).active,false);
 assert.equal((await db`select 1 from app_private.entitlements where user_id=${actor.id}`).length,0);
 assert.equal((await db`select 1 from app_private.apple_accounts where app_account_token=${historicalToken}`).length,0);
 assert.equal((await db`select app_account_token from app_private.apple_accounts where user_id=${actor.id}`)[0].app_account_token,prepared.app_account_token);
});
test('canonical refresh reconciles expired owned subscription renewal and refund',async()=>{const a=await fixture(),purchase=await bought(a,{expires:Date.now()-60000,status:2});await stale(a);let reads=0;const input={actor:a,body:{service:'membership',action:'check'},config};const refreshed=await refreshNativeMembership(input,{db,verify:async()=>{reads++;return {transaction:{...purchase.transaction,expiresDate:Date.now()+3600000},status:1};}});assert.equal(refreshed.SPYCLASH_LIMITLESS_ENABLED,'true');assert.equal(reads,1);assert.equal((await call(a,{action:'check'})).active,true);await stale(a);await refreshNativeMembership({...input,body:{service:'legacy',action:'generate_word_pack'}},{db,verify:async()=>({transaction:{...purchase.transaction,expiresDate:Date.now()+3600000},status:5})});assert.equal((await call(a,{action:'check'})).active,false);});
test('Apple outage fails closed without overwriting the last owned entitlement',async()=>{const a=await fixture();await bought(a);await stale(a);await assert.rejects(refreshNativeMembership({actor:a,body:{service:'profile',action:'update_profile',spy_card_theme:'blacksite'},config},{db,verify:async()=>{throw new Error('offline');}}),e=>e.code==='apple_status_unavailable'&&e.status===503&&e.retryable);assert.equal((await db`select active from app_private.entitlements where user_id=${a.id}`)[0].active,true);});
test('refresh after concurrent account deletion cannot reactivate a purchase',async()=>{const a=await fixture(),purchase=await bought(a);await stale(a);await assert.rejects(refreshNativeMembership({actor:a,body:{service:'membership',action:'check'},config},{db,verify:async()=>{await db`update app_private.profiles set state='deleted' where user_id=${a.id}`;await db`update app_private.entitlements set active=false where user_id=${a.id}`;return {transaction:purchase.transaction,status:1};}}),e=>e.code==='account_unavailable');assert.equal((await db`select active from app_private.entitlements where user_id=${a.id}`)[0].active,false);});
test('ordinary game/profile read does not require a provider round trip',async()=>{const a=await fixture();await bought(a);await stale(a);await refreshNativeMembership({actor:a,body:{service:'profile',action:'current'},config},{db,verify:async()=>{throw new Error('must not fetch');}});await refreshNativeMembership({actor:a,body:{service:'profile',action:'update',language:'ru'},config},{db,verify:async()=>{throw new Error('must not fetch language');}});});

test('temporary Apple certificate verification failure stays retryable and does not try another environment',async()=>{
 let attempts=0;const tools=async()=>({invalidEnvironment:4,retryableFailure:2,verifier:{verifyAndDecodeTransaction:async()=>{attempts++;throw {status:2};}}});
 await assert.rejects(verifyApple('signed',nativeGameCenterConfiguration(config),{tools}),e=>e.status===503&&e.retryable===true);assert.equal(attempts,1);
});
test('Apple environment mismatch alone can try the second explicitly enabled environment',async()=>{
 let attempts=0;const tools=async()=>({invalidEnvironment:4,retryableFailure:2,verifier:{verifyAndDecodeTransaction:async()=>{attempts++;throw {status:4};}}});
 await assert.rejects(verifyApple('signed',nativeGameCenterConfiguration(config),{tools}),e=>e.status===422);assert.equal(attempts,2);
 const invalid=async()=>({invalidEnvironment:4,retryableFailure:2,verifier:{verifyAndDecodeTransaction:async()=>{attempts++;throw {status:6};}}});
 attempts=0;await assert.rejects(verifyApple('signed',nativeGameCenterConfiguration(config),{tools:invalid}),e=>e.status===422);assert.equal(attempts,1);
});

test('native Loyalty persists unique verified periods, survives history outage and reconciles refunds',async()=>{
 const a=await fixture(),b=await fixture(),purchase=await bought(a,{environment:'Production'});
 let timestamp=Date.now();
 const deliver=async(actor,ids)=>{
   const loyalty=ids===undefined?undefined:{original_transaction_id:purchase.transaction.originalTransactionId,environment:'production',transaction_ids:ids,verified_at:new Date(++timestamp).toISOString()};
   const evidence=await prepareMembershipExternal({actor,body:purchase.body,config},{db,verify:async()=>({transaction:purchase.transaction,status:1,loyalty})});
   return call(actor,purchase.body,evidence);
 };
 const stored=async()=> (await db`select data from app_private.entitlements where user_id=${a.id}`)[0].data;
 const publicView=()=>db.begin(async tx=>{
   const [profile]=await tx`select * from app_private.profiles where user_id=${a.id}`;
   return (await projectedProfiles({tx,actor:b,now:new Date(),config},[profile]))[0];
 });
 const paidIDs=['2000000000000001','2000000000000002','2000000000000003'];
 await deliver(a,[...paidIDs,paidIDs[2]]);
 assert.deepEqual((await stored()).loyalty_transaction_ids,paidIDs);
 let projected=await publicView();
 assert.deepEqual(projected.achievements.find(award=>award.id==='loyalty_3'),{id:'loyalty_3',progress:3,target:3});
 for(const privateValue of [...paidIDs,purchase.transaction.originalTransactionId,purchase.transaction.appAccountToken,'loyalty_transaction_ids','loyalty_verified_at'])
   assert.equal(JSON.stringify(projected).includes(privateValue),false);
 await deliver(a,paidIDs);
 await deliver(a,undefined);
 assert.equal((await stored()).loyalty_transaction_ids.length,3);
 await assert.rejects(deliver(b,paidIDs),e=>e.code==='purchase_owner_mismatch');
 await deliver(a,[paidIDs[0],paidIDs[2]]);
 assert.deepEqual((await stored()).loyalty_transaction_ids,[paidIDs[0],paidIDs[2]]);
 projected=await publicView();
 assert.deepEqual(projected.achievements.find(award=>award.id==='loyalty_3'),{id:'loyalty_3',progress:2,target:3});
 await db.begin(tx=>cleanupBillingPush({tx,actor:a,now:new Date(),config}));
 const erased=await stored();
 assert.equal(erased.loyalty_transaction_ids,undefined);assert.equal(erased.loyalty_verified_at,undefined);
 assert.equal(erased.original_transaction_id,purchase.transaction.originalTransactionId);
});

test('canonical Apple verification adds only complete Loyalty history, without making a history outage a purchase failure',async()=>{
 const now=Date.now(),token=crypto.randomUUID(),id=appleID();
 const transaction={productId:WEEKLY_PRODUCT,bundleId:'com.spyclash.ios',environment:'Production',originalTransactionId:id,
   transactionId:'2000000000000003',appAccountToken:token,expiresDate:now+3600_000,purchaseDate:now-1000,signedDate:now,
   type:'Auto-Renewable Subscription',inAppOwnershipType:'PURCHASED',price:1990};
 let fail=false;
 const tools=async()=>({invalidEnvironment:4,retryableFailure:2,
   verifier:{verifyAndDecodeTransaction:async signed=>signed==='current'||signed==='submitted'?transaction:JSON.parse(signed)},
   client:{getAllSubscriptionStatuses:async()=>({bundleId:'com.spyclash.ios',environment:'Production',appAppleId:MAIN_APPLE_APP_ID,
     data:[{lastTransactions:[{originalTransactionId:id,status:1,signedTransactionInfo:'current'}]}]})},
   getHistory:async()=>{if(fail)throw Error('offline');return {bundleId:'com.spyclash.ios',environment:'Production',appAppleId:MAIN_APPLE_APP_ID,
     hasMore:false,signedTransactions:[JSON.stringify(transaction)]};}});
 const complete=await verifyApple('submitted',nativeGameCenterConfiguration(config),{tools});
 assert.deepEqual(complete.loyalty.transaction_ids,['2000000000000003']);assert.equal(complete.status,1);
 fail=true;const incomplete=await verifyApple('submitted',nativeGameCenterConfiguration(config),{tools});
 assert.equal(incomplete.loyalty,undefined);assert.equal(incomplete.status,1);
});

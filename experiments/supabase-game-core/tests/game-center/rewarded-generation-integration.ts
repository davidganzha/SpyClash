import assert from 'node:assert/strict';
import {generateKeyPairSync,sign} from 'node:crypto';
import postgres from 'postgres';
import {executeApp,validateCommand} from '../../supabase/functions/app-services/dispatcher.ts';
import {prepareNativeGeneration} from '../../supabase/functions/app-services/native-generation.ts';
import {createGenerationRewardSSVHandler,prepareGenerationRewards} from '../../supabase/functions/app-services/generation-rewards.ts';
import {nativeRewardStatus} from '../../supabase/functions/app-services/generation-reward-ledger.ts';
import {createNativeAIRelayHandler} from '../../supabase/functions/app-services/native-ai-relay.ts';
import {relayHeaders} from '../../supabase/functions/app-services/native-ai-relay-protocol.ts';
import {AppServiceError} from '../../supabase/functions/app-services/contracts.ts';
import {createAppRouter} from '../../supabase/functions/app-services/router.ts';

// Creates and destroys only its own isolated local database. No provider, Auth,
// AdMob or cloud endpoint is contacted: every external response is a fixture.
const raw=Deno.env.get('REWARDED_TEST_DATABASE_URL');
if(!raw)throw new Error('REWARDED_TEST_DATABASE_URL must name a local PostgreSQL server.');
const url=new URL(raw);
if(!['127.0.0.1','localhost'].includes(url.hostname))throw new Error('Local database required.');
const admin=postgres(url.href,{max:1,onnotice:()=>{}});
const name='spyclash_rewards_'+crypto.randomUUID().replaceAll('-','');
await admin.unsafe('create database '+name);
url.pathname='/'+name;
const db=postgres(url.href,{max:15,onnotice:()=>{}});
const config={SPYCLASH_REWARDED_GENERATION_ENABLED:'true',ADMOB_REWARDED_AD_UNIT_ID:'ca-app-pub-1234567890123456/1234567890',
  APP_NATIVE_GAME_CENTER_AI_ENABLED:'true',APP_NATIVE_GAME_CENTER_AI_PROVIDER:'openai',OPENAI_API_KEY:'local-fixture-only'};
let checks=0;
const check=async(name:string,run:()=>Promise<void>)=>{await run();checks++;console.log('PASS '+name);};
const actor=async()=>{
  const id=crypto.randomUUID();
  await db`insert into app_private.profiles(user_id,state,data,spy_id) values(${id},'active','{}',${id})`;
  await db`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${id.replaceAll('-','').repeat(2)},${id},${id+'@example.test'},'ready')`;
  return {id,email:id+'@example.test',contactEmail:'',full_name:'Test',metadata:{}};
};
const status=async(a:any,c=config)=>await db.begin(async(tx:any)=>await nativeRewardStatus(tx,a.id,c));
const app=async(a:any,body:any,c=config,evidence?:any)=>await executeApp(db,a,body,c,evidence);
const prepare=async(a:any,id=crypto.randomUUID())=>{
  const response=await app(a,{service:'generation_rewards',action:'prepare',request_id:id});
  assert.equal(response.status,200,JSON.stringify(response));return response.body;
};
const keys=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const googleKeys=async(input:any)=>{
  assert.equal(String(input),'https://www.gstatic.com/admob/reward/verifier-keys.json');
  return Response.json({keys:[{keyId:123,base64:keys.publicKey.export({format:'der',type:'spki'}).toString('base64')}]});
};
const ssv=createGenerationRewardSSVHandler(db,googleKeys);
function signed(attempt:any,extra:Record<string,string>={}){
  const values={ad_network:'5450213213286189855',ad_unit:attempt.ad_unit_id.split('/')[1],custom_data:attempt.custom_data,
    reward_amount:'1',reward_item:'generation',timestamp:String(Date.now()),transaction_id:crypto.randomUUID().replaceAll('-',''),user_id:attempt.ssv_user_id,...extra};
  const query=Object.entries(values).sort(([a],[b])=>a.localeCompare(b)).map(([key,value])=>key+'='+encodeURIComponent(value)).join('&');
  const signature=sign('sha256',Buffer.from(decodeURIComponent(query)),keys.privateKey).toString('base64url');
  return 'http://127.0.0.1/functions/v1/app-services/rewarded-generation/ssv?'+query+'&signature='+signature+'&key_id=123';
}
const earn=async(a:any)=>{const attempt=await prepare(a);const response=await ssv(new Request(signed(attempt)));assert.equal(response.status,200,await response.text());return attempt;};
const providerReply=()=>Response.json({status:'completed',output:[{type:'message',role:'assistant',content:[{type:'output_text',text:JSON.stringify({
  draft_words:['Apple','Pear'],accepted_indices:[0,1],replacement_words:[],accepted_replacement_indices:[],category:'Fruit',exhausted:false})}]}]});
let providerCalls=0;
const provider=async()=>{providerCalls++;return providerReply();};
async function generate(a:any,id=crypto.randomUUID(),fetcher:typeof fetch=provider,c:Record<string,string>=config,database:any=db){
  const body={service:'legacy',action:'generate',theme:'Fruit',count:2,request_id:id};
  try{
    const evidence=await prepareNativeGeneration({actor:a,body,config:c},{db:database,fetch:fetcher});
    return await app(a,body,c as typeof config,evidence);
  }catch(error){if(error instanceof AppServiceError)return {status:error.status,body:{code:error.code,retryable:error.retryable}};throw error;}
}
async function exhaust(a:any){for(let i=0;i<3;i++)assert.equal((await generate(a)).status,200);}
try{
  await db.unsafe(`create schema app_private;
    create table app_private.profiles(user_id uuid primary key,state text,data jsonb,spy_id text);
    create table app_private.legacy_links(user_id uuid,legacy_user_id text,source_origin text,state text);
    create table app_private.legacy_session_accounts(user_id uuid);
    create table app_private.main_account_deletions(user_id uuid);
    create table app_private.entitlements(user_id uuid,active boolean,expires_at timestamptz);
    create table app_private.membership_grants(user_id uuid,active boolean,expires_at timestamptz);
    create table app_private.receipts(actor_id uuid,request_id uuid,request_hash text,status int,response jsonb,primary key(actor_id,request_id));`);
  const files=['../../supabase/functions/game-center-session/schema.sql','../../supabase/migrations/20261026234309_native_game_center_ai_relay.sql',
    '../../supabase/migrations/20261101130901_native_generation_failure_recovery.sql','../../supabase/migrations/20261105224817_rewarded_generation_credits.sql'];
  for(const file of files)await db.unsafe(await Deno.readTextFile(new URL(file,import.meta.url)));
  await check('new tables are private with RLS and no client grants',async()=>{
    const [row]=await db`select relrowsecurity from pg_class where oid='game_center_private.generation_reward_attempts'::regclass`;assert.equal(row.relrowsecurity,true);
    const [priv]=await db`select has_table_privilege('authenticated','game_center_private.generation_reward_attempts','select,insert,update,delete') as allowed`;assert.equal(priv.allowed,false);
  });
  await check('feature defaults off and demo ad unit cannot mint credits',async()=>{
    const a=await actor(),off={...config,SPYCLASH_REWARDED_GENERATION_ENABLED:'false'};
    assert.equal((await status(a,off)).enabled,false);assert.equal((await app(a,{service:'generation_rewards',action:'prepare',request_id:crypto.randomUUID()},off)).status,409);
    assert.equal((await status(a,{...config,ADMOB_REWARDED_AD_UNIT_ID:'ca-app-pub-3940256099942544/1712485313'})).ad_available,false);
    const result=await generate(a,crypto.randomUUID(),provider,off);assert.equal(result.body.ai_limit,10);
  });
  await check('valid signed SSV earns exactly one bonus across concurrent duplicate callbacks',async()=>{
    const a=await actor();await exhaust(a);const attempt=await prepare(a),same=await prepare(a,attempt.attempt_id);assert.equal(attempt.custom_data,same.custom_data);
    assert.equal((await status(a)).bonus_credits,0);
    const url=signed(attempt),responses=await Promise.all(Array.from({length:8},()=>ssv(new Request(url))));
    assert.equal(responses.every(r=>r.status===200),true);assert.equal((await status(a)).bonus_credits,1);
    assert.equal((await app(a,{service:'generation_rewards',action:'claim_status',attempt_id:attempt.attempt_id})).body.state,'earned');
    assert.throws(()=>validateCommand({service:'generation_rewards',action:'claim',request_id:crypto.randomUUID(),evidence:{earned:true}}));
  });
  await check('forged signature, wrong user/unit/amount/item, reused transaction and expired event never earn',async()=>{
    const a=await actor();await exhaust(a);const attempt=await prepare(a),second=await prepare(a),other=await actor();
    const bad=[signed(attempt).replace('reward_amount=1','reward_amount=9'),signed(attempt,{user_id:other.id}),signed(attempt,{ad_unit:'9999999999'}),
      signed(attempt,{reward_amount:'2'}),signed(attempt,{reward_item:'coins'}),signed(attempt,{timestamp:String(Date.now()-172800000)})];
    for(const url of bad)assert.notEqual((await ssv(new Request(url))).status,200);
    assert.equal((await status(a)).bonus_credits,0);
    const tx='abc123',valid=signed(attempt,{transaction_id:tx});assert.equal((await ssv(new Request(valid))).status,200);
    assert.equal((await ssv(new Request(signed(second,{transaction_id:tx})))).status,409);
    assert.equal((await app(other,{service:'generation_rewards',action:'claim_status',attempt_id:attempt.attempt_id})).status,404);
  });
  await check('late delivery honors a signed event in its issued window and routes without user auth',async()=>{
    const a=await actor();await exhaust(a);const attempt=await prepare(a);
    await db`update game_center_private.generation_reward_attempts set created_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 day' where user_id=${a.id}`;
    const request=new Request(signed(attempt,{timestamp:String(Date.now()-129600000)}));
    const other=async()=>{throw new Error('SSV must not enter bearer auth');};
    const router=createAppRouter({app:other,maintenance:other,nativeAIRelay:other,generationRewardSSV:ssv});
    assert.equal((await router(request)).status,200);assert.equal((await status(a)).bonus_credits,1);
  });
  await check('legacy rewards proxy verifies account mapping and keeps Base44 as the only credit owner',async()=>{
    const a=await actor();await db`delete from game_center_private.accounts where user_id=${a.id}`;
    const legacyID='legacy-fixture-user';await db`insert into app_private.legacy_links values(${a.id},${legacyID},'https://spyclash.com','active')`;
    const c={...config,SUPABASE_URL:'http://127.0.0.1:56321'},body={service:'generation_rewards',action:'prepare',request_id:crypto.randomUUID(),base44_access_token:'fixture-legacy-credential-at-least-twenty-chars'};
    let commands=0;
    const fetcher=async(url:any,init:any)=>{
      if(String(url).endsWith('/entities/User/me'))return Response.json({id:legacyID});
      assert.ok(String(url).endsWith('/functions/generationRewardAction'));commands++;
      assert.deepEqual(JSON.parse(init.body),{action:'prepare',request_id:body.request_id});
      return Response.json({enabled:true,unlimited:false,daily_limit:3,free_remaining:0,bonus_credits:0,resets_at:new Date().toISOString(),ad_available:true,
        attempt_id:body.request_id,custom_data:'opaque-legacy-token',ad_unit_id:config.ADMOB_REWARDED_AD_UNIT_ID,user_id:legacyID,ssv_user_id:legacyID});
    };
    const evidence=await prepareGenerationRewards({actor:a,body,config:c},{db,fetch:fetcher});
    const result=await app(a,body,c,evidence);assert.equal(result.status,200);assert.equal(result.body.ssv_user_id,legacyID);assert.equal(commands,1);
    const [{count}]=await db`select count(*)::int as count from game_center_private.generation_reward_attempts where user_id=${a.id}`;assert.equal(count,0);
    await db`update app_private.legacy_links set legacy_user_id='another-account' where user_id=${a.id}`;
    await assert.rejects(prepareGenerationRewards({actor:a,body:{...body,request_id:crypto.randomUUID()},config:c},{db,fetch:fetcher}),e=>e instanceof AppServiceError&&e.code==='legacy_link_required');
    assert.equal(commands,1);
  });
  await check('concurrent generations consume 3 free then one credit and never double-charge retries',async()=>{
    const a=await actor();await exhaust(a);await earn(a);
    await db`update game_center_private.generation_requests set usage_date=usage_date-1 where user_id=${a.id}`;
    const firstID=crypto.randomUUID();
    const first=await generate(a,firstID);assert.equal(first.status,200);assert.equal(first.body.ai_free_remaining,2);assert.equal(first.body.ai_bonus_credits,1);
    const before=providerCalls;assert.deepEqual(await generate(a,firstID),first);assert.equal(providerCalls,before);
    const results=await Promise.all(Array.from({length:8},()=>generate(a)));assert.equal(results.filter(r=>r.status===200).length,3);
    assert.equal(results.filter(r=>r.status===429).length,5);const final=await status(a);assert.equal(final.free_remaining,0);assert.equal(final.bonus_credits,0);
  });
  await check('definitive bonus failure refunds once and successful replacement spends that same credit',async()=>{
    const a=await actor();for(let i=0;i<3;i++)assert.equal((await generate(a)).status,200);await earn(a);
    const id=crypto.randomUUID(),failure=async()=>Response.json({error:{message:'fixture'}},{status:400});
    assert.equal((await generate(a,id,failure)).status,422);assert.equal((await status(a)).bonus_credits,1);
    assert.equal((await generate(a,id,failure)).status,422);assert.equal((await status(a)).bonus_credits,1);
    assert.equal((await generate(a)).status,200);assert.equal((await status(a)).bonus_credits,0);
  });
  await check('LIMITLESS is server-owned and unlimited; expiry falls back to 3 free',async()=>{
    const a=await actor();a.metadata={premium:true,is_limitless:true};assert.equal((await status(a)).unlimited,false);
    await db`insert into app_private.membership_grants values(${a.id},true,clock_timestamp()+interval '1 day')`;
    for(let i=0;i<5;i++){const r=await generate(a);assert.equal(r.status,200);assert.equal(r.body.ai_unlimited,true);assert.equal(r.body.ai_free_remaining,null);}
    assert.equal((await status(a)).ad_available,false);
    await db`update app_private.membership_grants set expires_at=clock_timestamp()-interval '1 second' where user_id=${a.id}`;
    assert.equal((await status(a)).free_remaining,3);
  });
  await check('UTC daily reset restores free allowance without expiring unused bonus',async()=>{
    const a=await actor();for(let i=0;i<3;i++)await generate(a);await earn(a);
    await db`update game_center_private.generation_requests set usage_date=usage_date-1 where user_id=${a.id}`;
    const snapshot=await status(a);assert.equal(snapshot.free_remaining,3);assert.equal(snapshot.bonus_credits,1);assert.equal(new Date(snapshot.resets_at).getUTCHours(),0);
    await generate(a);assert.equal((await status(a)).bonus_credits,1);
  });
  await check('unknown direct provider result retains reservation and same request cannot repeat provider work',async()=>{
    const a=await actor(),id=crypto.randomUUID();let calls=0;
    const failure=async()=>{calls++;throw new Error('fixture lost ACK');};
    assert.equal((await generate(a,id,failure)).status,503);assert.equal((await status(a)).free_remaining,2);
    await db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${a.id} and request_id=${id}`;
    assert.equal((await generate(a,id,failure)).status,503);assert.equal(calls,1);assert.equal((await status(a)).free_remaining,2);
  });
  await check('successful direct result survives write failure and lost commit ACK without another provider call',async()=>{
    for(const mode of ['before_write','after_commit']){
      const a=await actor(),id=crypto.randomUUID();let calls=0,injected=0;
      const interruptedDB=new Proxy(db,{get(target,key,receiver){
        if(key!=='begin')return Reflect.get(target,key,receiver);
        return async(action:any)=>{
          let touched=false;
          const saved=await target.begin((tx:any)=>action(new Proxy(tx,{apply(query,thisArg,args){
            if(Array.isArray(args[0])&&args[0].join(' ').includes("update game_center_private.generation_provider_calls set state='complete'")){
              touched=true;
              if(injected===0&&mode==='before_write'){injected++;throw new Error('fixture write unavailable');}
            }
            return Reflect.apply(query,thisArg,args);
          }})));
          if(touched&&injected===0&&mode==='after_commit'){injected++;throw new Error('fixture lost commit ACK');}
          return saved;
        };
      }});
      const fetcher=async()=>{calls++;return providerReply();};
      const result=await generate(a,id,fetcher,config,interruptedDB);assert.equal(result.status,200,JSON.stringify(result));
      assert.equal(injected,1);assert.equal(calls,1);assert.equal((await status(a)).free_remaining,2);
      assert.deepEqual(await generate(a,id,fetcher),result);assert.equal(calls,1);
      const [call]=await db`select state,error_code from game_center_private.generation_provider_calls where user_id=${a.id}`;
      assert.equal(call.state,'complete');assert.equal(call.error_code,null);
    }
  });
  await check('persistent success-save outage stays unknown and never refunds or repeats the provider',async()=>{
    const a=await actor(),id=crypto.randomUUID();let calls=0,writes=0;
    const interruptedDB=new Proxy(db,{get(target,key,receiver){
      if(key!=='begin')return Reflect.get(target,key,receiver);
      return (action:any)=>target.begin((tx:any)=>action(new Proxy(tx,{apply(query,thisArg,args){
        if(Array.isArray(args[0])&&args[0].join(' ').includes("update game_center_private.generation_provider_calls set state='complete'")){
          writes++;throw new Error('fixture persistent database outage');
        }
        return Reflect.apply(query,thisArg,args);
      }})));
    }});
    const fetcher=async()=>{calls++;return providerReply();};
    assert.equal((await generate(a,id,fetcher,config,interruptedDB)).status,503);assert.equal(writes,3);assert.equal(calls,1);
    const [call]=await db`select state,error_code from game_center_private.generation_provider_calls where user_id=${a.id}`;
    assert.equal(call.state,'started');assert.equal(call.error_code,null);assert.equal((await status(a)).free_remaining,2);
    await db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${a.id} and request_id=${id}`;
    assert.equal((await generate(a,id,fetcher)).status,503);assert.equal(calls,1);assert.equal((await status(a)).free_remaining,2);
  });
  await check('HTTP 200 with interrupted response body stays unknown and cannot refund its credit',async()=>{
    const a=await actor(),id=crypto.randomUUID();let calls=0;
    const fetcher=async()=>{calls++;return new Response(new ReadableStream({start(controller){
      controller.enqueue(new TextEncoder().encode('{"status":"completed",'));controller.error(new Error('fixture broken body stream'));
    }}),{status:200,headers:{'Content-Type':'application/json'}});};
    assert.equal((await generate(a,id,fetcher)).status,503);assert.equal((await status(a)).free_remaining,2);
    const [call]=await db`select state,error_code from game_center_private.generation_provider_calls where user_id=${a.id}`;
    assert.equal(call.state,'started');assert.equal(call.error_code,null);
    await db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${a.id} and request_id=${id}`;
    assert.equal((await generate(a,id,fetcher)).status,503);assert.equal(calls,1);assert.equal((await status(a)).free_remaining,2);
  });
  await check('late signed relay completion recovers expired worker lease without another provider call',async()=>{
    const a=await actor(),id=crypto.randomUUID(),secret='a'.repeat(64);
    const c={...config,APP_NATIVE_GAME_CENTER_AI_PROVIDER:'base44-managed',SPYCLASH_NATIVE_AI_RELAY_SECRET:secret};
    const relay=createNativeAIRelayHandler(db,c);let ticket:any,claimID:string|undefined,calls=0;
    const send=async(action:'claim'|'complete'|'fail',payload:any)=>{const body=JSON.stringify(payload);return await relay(new Request('http://127.0.0.1/native-ai-relay/'+action,{method:'POST',headers:await relayHeaders(secret,action,body),body}));};
    const fetcher=async(_url:any,init:any)=>{calls++;ticket=JSON.parse(init.body);const response=await send('claim',ticket);const result=await response.json();claimID=result.claim_id;assert.ok(claimID);return Response.json({lost:true},{status:503});};
    assert.equal((await generate(a,id,fetcher,c)).status,503);
    await db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${a.id} and request_id=${id}`;
    assert.equal((await generate(a,id,fetcher,c)).status,503);assert.equal(calls,1);
    const complete=await send('complete',{ticket,claim_id:claimID,result:{category:'Fruit',words:['Apple','Pear'],exhausted:false}});assert.equal(complete.status,200,await complete.text());
    const recovered=await generate(a,id,fetcher,c);assert.equal(recovered.status,200,JSON.stringify(recovered));assert.equal(calls,1);assert.equal((await status(a)).free_remaining,2);
  });
  await check('deleted account rejects late signed reward and erased ledger cannot reappear',async()=>{
    const a=await actor();await exhaust(a);const attempt=await prepare(a);
    await db.begin(async(tx:any)=>{await tx`update app_private.profiles set state='deleted' where user_id=${a.id}`;await tx`delete from game_center_private.generation_reward_attempts where user_id=${a.id}`;await tx`update game_center_private.accounts set state='deleted' where user_id=${a.id}`;});
    assert.equal((await ssv(new Request(signed(attempt)))).status,403);
    const [{count}]=await db`select count(*)::int as count from game_center_private.generation_reward_attempts where user_id=${a.id}`;assert.equal(count,0);
  });
  await check('prepare rejects stale client offers after free reset or a late bonus credit',async()=>{
    const a=await actor(),body=()=>({service:'generation_rewards',action:'prepare',request_id:crypto.randomUUID()});
    assert.equal((await app(a,body())).body.code,'reward_not_needed');
    await exhaust(a);const attempt=await earn(a);
    assert.equal((await app(a,body())).body.code,'reward_not_needed');
    // The original immutable prepare response still recovers after its ACK was lost.
    assert.equal((await prepare(a,attempt.attempt_id)).custom_data,attempt.custom_data);
    await db`update game_center_private.generation_requests set usage_date=usage_date-1 where user_id=${a.id}`;
    assert.equal((await app(a,body())).body.code,'reward_not_needed');
  });
  console.log(`PASS ${checks} isolated rewarded-generation integration checks`);
}finally{
  await db.end();await admin.unsafe('drop database '+name);await admin.end();
}

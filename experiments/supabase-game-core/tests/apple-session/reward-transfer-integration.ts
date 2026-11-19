import {strict as assert} from 'node:assert';
import postgres from 'npm:postgres@3.4.9';
import {createGenerationRewardSSVHandler} from '../../supabase/functions/app-services/generation-rewards.ts';
import {hasImportedRewardAlias} from '../../supabase/functions/app-services/imported-reward-alias.ts';
import {createRewardedGenerationSSVGateway} from '../../supabase/functions/rewarded-generation-ssv/handler.ts';
const env=Deno.env.toObject(),connection=new URL(env.SUPABASE_DB_URL||'');
if(connection.hostname!=='127.0.0.1'||connection.port!=='56322'||connection.pathname!=='/postgres')throw new Error('Only dedicated loopback fixtures are allowed.');
const db=postgres(connection.href,{prepare:false,max:3,onnotice:()=>{}});
const user=crypto.randomUUID(),attempt=crypto.randomUUID(),legacy='legacy-reward-'+crypto.randomUUID(),key=crypto.randomUUID().replaceAll('-','').repeat(2);
const custom=attempt+'.legacy.'+'a'.repeat(64),issued=Date.parse('2026-11-07T20:02:00.000Z');
const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const b64=(b:Uint8Array)=>btoa(String.fromCharCode(...b));
const publicKey=b64(new Uint8Array(await crypto.subtle.exportKey('spki',pair.publicKey)));
function der(raw:Uint8Array){const parts=[raw.slice(0,32),raw.slice(32)].map(value=>{while(value.length>1&&!value[0])value=value.slice(1);if(value[0]&128)value=new Uint8Array([0,...value]);return new Uint8Array([2,value.length,...value]);});return new Uint8Array([48,parts[0].length+parts[1].length,...parts[0],...parts[1]]);}
async function signed({owner=legacy,transaction='provider-event-'+attempt,timestamp=issued+1000,unit='6816674766'}={}) {
  const query=new URLSearchParams({user_id:owner,ad_unit:unit,custom_data:custom,reward_item:'generation',reward_amount:'1',timestamp:String(timestamp),transaction_id:transaction}).toString();
  const raw=new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(decodeURIComponent(query))));
  return new Request('https://local.invalid/reward?'+query+'&signature='+b64(der(raw)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')+'&key_id=123');
}
let sourceCalls=0;
const fetcher:typeof fetch=async input=>{
  if(String(input)==='https://www.gstatic.com/admob/reward/verifier-keys.json')return Response.json({keys:[{keyId:123,base64:publicKey}]});
  sourceCalls++;throw new Error('A migrated callback must never grant on the source.');
};
const config={SUPABASE_URL:'http://127.0.0.1:56321',SPYCLASH_REWARDED_AD_PROVIDER:'unity'};
const native=createGenerationRewardSSVHandler(db,fetcher,config),gateway=createRewardedGenerationSSVGateway({config,fetch:fetcher,native,importedLegacy:value=>hasImportedRewardAlias(db,value)});
let passed=0;async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log('PASS '+name);}
try {
  await db`insert into app_private.profiles(user_id,data) values(${user},'{}')`;
  await db`insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,legacy_user_id,state,migration_version,migration_complete)
    values(${key},${'apple-subject:'+key},'com.spyclash.ios',${user},${user+'@fixture.invalid'},${legacy},'ready',1,true)`;
  await db`insert into game_center_private.generation_reward_attempts(user_id,attempt_id,custom_data,ad_unit_id,created_at,expires_at)
    values(${user},${attempt},${custom},'ca-app-pub-5081830513960558/6816674766',${new Date(issued)},${new Date(issued+86400000)})`;
  await db`insert into apple_private.reward_attempt_aliases(custom_data,source_record_id,legacy_user_id,user_id,attempt_id,transfer_id,source_state)
    values(${custom},${'fixture-'+attempt},${legacy},${user},${attempt},${crypto.randomUUID()},'pending')`;
  await check('delayed AdMob event credits migrated native owner using original unit and event time, even current provider Unity',async()=>{
    const response=await gateway(await signed());assert.equal(response.status,200,await response.text());
    const [row]=await db`select state,reward_at,transaction_id from game_center_private.generation_reward_attempts where user_id=${user} and attempt_id=${attempt}`;
    assert.equal(row.state,'earned');assert.equal(new Date(row.reward_at).getTime(),issued+1000);assert.equal(sourceCalls,0);
  });
  await check('same provider callback through gateway and native route produces one credit only',async()=>{
    assert.equal((await gateway(await signed())).status,200);assert.equal((await native(await signed())).status,200);
    const [row]=await db`select count(*)::int n from game_center_private.generation_reward_attempts where user_id=${user} and state='earned'`;assert.equal(row.n,1);
    assert.equal((await gateway(await signed({transaction:'different-event'}))).status,409);assert.equal(sourceCalls,0);
  });
  await check('valid provider signatures cannot change original source owner, unit, or issued window',async()=>{
    for(const change of [{owner:'foreign-owner'},{unit:'1234567890'},{timestamp:issued+86400001}])assert.equal((await gateway(await signed(change))).status,400);
  });
  await check('deleted owner cannot recreate migrated credit, and deletion cascades its capability alias',async()=>{
    await db`update app_private.profiles set state='deleted' where user_id=${user}`;
    assert.equal((await gateway(await signed())).status,403);
    await db`delete from game_center_private.generation_reward_attempts where user_id=${user}`;
    assert.equal(await hasImportedRewardAlias(db,custom),false);
    const request=await signed(),marked=new Request(request,{headers:{'X-SpyClash-Reward-Transfer':'1'}});
    assert.equal((await gateway(marked)).status,503);assert.equal(sourceCalls,0);
  });
  console.log(JSON.stringify({passed,localOnly:true,productionOperations:0}));
}finally{
  await db.begin(async(tx:any)=>{await tx`delete from game_center_private.generation_reward_attempts where user_id=${user}`;await tx`delete from apple_private.accounts where user_id=${user}`;await tx`delete from app_private.profiles where user_id=${user}`;});
  await db.end();
}

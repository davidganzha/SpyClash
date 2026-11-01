import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import {readFile} from 'node:fs/promises';
import postgres from 'postgres';
import {prepareNativeGeneration,dispatchNativeGeneration,nativeGenerationCapabilities} from '../../supabase/functions/app-services/native-generation.ts';
import {createNativeAIRelayHandler,terminalNativeAIOutcome} from '../../supabase/functions/app-services/native-ai-relay.ts';
import {createAppRouter} from '../../supabase/functions/app-services/router.ts';
import {createNativeWordPackRelay,relayGatewayTokenValid} from '../../../../base44/functions/nativeGameCenterWordPack/handler.ts';
import {RELAY_BASE44_URL,RELAY_CALLBACK_URL,RELAY_PROMPT_VERSION,relayHeaders,readRelayRequest} from '../../supabase/functions/app-services/native-ai-relay-protocol.ts';
import {WORD_PACK_PROMPT_VERSION} from '../../../../base44/functions/generateWordPack/openai-word-pack-provider.ts';

// All provider calls stay in process. Only the dedicated loopback database is real.
const secret='1'.repeat(64),gatewayToken='fixture.'+Buffer.from(JSON.stringify({role:'anon',ref:'bbkfsgnordtdiblgdzkg'})).toString('base64url')+'.fixture';
const config={APP_NATIVE_GAME_CENTER_AI_ENABLED:'true',APP_NATIVE_GAME_CENTER_AI_PROVIDER:'base44-managed',SPYCLASH_NATIVE_AI_RELAY_SECRET:secret};
let db;const actors=[];
before(async()=>{
  const status=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});
  assert.equal(status.status,0);const url=new URL(JSON.parse(status.stdout).DB_URL);assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
  db=postgres(url.href,{max:8,onnotice:()=>{}});
  await db.unsafe(await readFile(new URL('../../supabase/migrations/20261026234309_native_game_center_ai_relay.sql',import.meta.url),'utf8'));
  await db.unsafe(await readFile(new URL('../../supabase/migrations/20261101130901_native_generation_failure_recovery.sql',import.meta.url),'utf8'));
});
after(async()=>{
  if(!db)return;
  for(const actor of actors){await db`delete from game_center_private.generation_requests where user_id=${actor.id}`;await db`delete from app_private.membership_grants where user_id=${actor.id}`;await db`delete from game_center_private.accounts where user_id=${actor.id}`;await db`delete from app_private.profiles where user_id=${actor.id}`;}
  await db.end();
});
async function fixture(){const id=crypto.randomUUID(),actor={id,email:id+'@test.invalid',metadata:{premium:true,role:'admin'}};actors.push(actor);
  await db`insert into app_private.profiles(user_id,state) values(${id},'active')`;
  await db`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${id.replaceAll('-','').repeat(2)},${id},${id+'@test.invalid'},'ready')`;return actor;
}
const command=()=>({theme:'Fruit',count:2,request_id:crypto.randomUUID()});
const candidate=(words=['Apple','Pear'],exhausted=false)=>({draft_words:words,accepted_indices:words.map((_,i)=>i),replacement_words:[],accepted_replacement_indices:[],category:'Fruit',exhausted});
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
async function used(actor){return (await db`select count(*)::int as count from game_center_private.generation_requests where user_id=${actor.id} and charged`)[0].count;}
async function expire(actor,body){await db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${actor.id} and request_id=${body.request_id}`;}
async function generate(actor,body,fetcher,database=db){const evidence=await prepareNativeGeneration({actor,body,config},{db:database,fetch:fetcher});return database.begin(tx=>dispatchNativeGeneration({tx,actor,config,evidence},body));}
function network({invoke,loseInvokeACK=false,loseCompleteACK=false,loseFailureCallback=false,transientCompleteFailures=0}={}){
  const state={calls:0,tickets:[],callbacks:[],callbackPaths:[],delays:[]};
  const unexpected=async()=>{throw new Error('Signed relay callback reached an unrelated authentication route');};
  const control=createAppRouter({app:unexpected,maintenance:unexpected,nativeAIRelay:createNativeAIRelayHandler(db,config)});
  const base44=createNativeWordPackRelay({secret,gatewayToken,delay:async milliseconds=>state.delays.push(milliseconds),
    invoke:async(request,input)=>{state.calls++;assert.equal(input.model,'gpt_5_4');assert.equal(typeof input.prompt,'string');assert.equal(input.response_json_schema.type,'object');assert.equal(Object.keys(input).sort().join(','),'model,prompt,response_json_schema');return invoke?invoke(request,input,state.calls):candidate();},
    fetch:async(url,init)=>{
      assert.ok(['claim','complete','fail'].some(action=>String(url)===RELAY_CALLBACK_URL+'/'+action));
      assert.equal(init.headers.Authorization,'Bearer '+gatewayToken);assert.equal(init.headers.apikey,gatewayToken);assert.equal(init.redirect,'manual');
      state.callbacks.push(JSON.parse(init.body));state.callbackPaths.push(String(url));
      if(loseFailureCallback&&String(url).endsWith('/fail'))throw new Error('failure callback unavailable');
      if(String(url).endsWith('/complete')&&transientCompleteFailures>0){transientCompleteFailures--;return Response.json({code:'relay_unavailable'},{status:503});}
      const response=await control(new Request(url,init));
      if(loseCompleteACK&&String(url).endsWith('/complete')&&response.ok)throw new Error('lost completion acknowledgement');return response;
    }});
  state.fetch=async(url,init)=>{assert.equal(String(url),RELAY_BASE44_URL);assert.equal(init.redirect,'error');state.tickets.push(JSON.parse(init.body));const response=await base44(new Request(url,init));if(loseInvokeACK)throw new Error('lost invoke acknowledgement');return response;};
  state.control=control;state.base44=base44;return state;
}
async function signed(action,payload,{signAction=action,signSecret=secret,now=Date.now()}={}){const body=JSON.stringify(payload);return new Request(RELAY_CALLBACK_URL+'/'+action,{method:'POST',headers:await relayHeaders(signSecret,signAction,body,now),body});}

test('deployed relay protocol, fixed model prompt and quality helpers match canonical sources',async()=>{
  assert.equal(RELAY_PROMPT_VERSION,WORD_PACK_PROMPT_VERSION);
  const root=new URL('../../../../',import.meta.url);
  for(const file of ['openai-word-pack-provider.ts','word-pack-quality.ts'])assert.equal(await readFile(new URL('base44/functions/nativeGameCenterWordPack/'+file,root),'utf8'),await readFile(new URL('base44/functions/generateWordPack/'+file,root),'utf8'));
  assert.equal(await readFile(new URL('base44/functions/nativeGameCenterWordPack/relay-protocol.ts',root),'utf8'),await readFile(new URL('../../supabase/functions/app-services/native-ai-relay-protocol.ts',import.meta.url),'utf8'));
});
test('installed client preserves terminal recovery instructions instead of its legacy unknown-result override',async()=>{
  const error=terminalNativeAIOutcome();
  const source=await readFile(new URL('../../../../SpyClash/Services/Base44Client.swift',import.meta.url),'utf8');
  const interceptedCodes=[...source.matchAll(/if normalizedCode == "([^"]+)"/g)].map(match=>match[1]);
  assert.ok(interceptedCodes.includes('generation_outcome_unknown'));
  assert.equal(interceptedCodes.includes(error.code),false);
  assert.equal(error.code,'generation_attempt_closed');assert.equal(error.status,422);assert.equal(error.retryable,false);
  assert.match(error.message,/close and reopen the generator/i);
});
test('entry router preserves ordinary application and maintenance dispatch while isolating all signed relay callbacks',async()=>{
  const reached=[];
  const route=createAppRouter(Object.fromEntries(['app','maintenance','nativeAIRelay'].map(name=>[name,async request=>{
    reached.push({name,path:new URL(request.url).pathname});return Response.json({handler:name});
  }])));
  for(const [suffix,handler]of [['','app'],['/maintenance','maintenance'],...['claim','complete','fail'].map(action=>['/native-ai-relay/'+action,'nativeAIRelay'])]){
    const path='/functions/v1/app-services'+suffix;
    assert.deepEqual(await (await route(new Request('http://127.0.0.1'+path,{method:'POST'}))).json(),{handler});
    assert.deepEqual(reached.at(-1),{name:handler,path});
  }
});
test('managed provider and gateway are explicitly configured without accepting service-role credentials',()=>{
  assert.equal(nativeGenerationCapabilities(config).configured,true);
  for(const patch of [{APP_NATIVE_GAME_CENTER_AI_ENABLED:'false'},{SPYCLASH_NATIVE_AI_RELAY_SECRET:''},{APP_NATIVE_GAME_CENTER_AI_PROVIDER:'arbitrary'},{APP_NATIVE_GAME_CENTER_AI_PROVIDER:undefined,OPENAI_API_KEY:'test'}])assert.equal(nativeGenerationCapabilities({...config,...patch}).configured,false);
  assert.equal(nativeGenerationCapabilities({...config,APP_NATIVE_GAME_CENTER_AI_PROVIDER:'openai',OPENAI_API_KEY:'test'}).configured,true);
  assert.equal(relayGatewayTokenValid(gatewayToken),true);
  for(const claims of [{role:'service_role',ref:'bbkfsgnordtdiblgdzkg'},{role:'anon',ref:'another-project'}])assert.equal(relayGatewayTokenValid('x.'+Buffer.from(JSON.stringify(claims)).toString('base64url')+'.x'),false);
});
test('HMAC binds action, body and expiry; unsigned or changed requests cannot claim paid work',async()=>{
  const control=createNativeAIRelayHandler(db,config),payload={actor_id:crypto.randomUUID()};
  for(const options of [{signAction:'invoke'},{signSecret:'2'.repeat(64)},{now:Date.now()-61_000}])assert.equal((await control(await signed('claim',payload,options))).status,401);
  const valid=await signed('claim',payload);const changed=new Request(valid.url,{method:'POST',headers:valid.headers,body:JSON.stringify({...payload,request_id:crypto.randomUUID()})});assert.equal((await control(changed)).status,401);
  const plain=new Request(RELAY_CALLBACK_URL+'/claim',{method:'POST',body:'{}'});assert.equal((await control(plain)).status,401);
  const request=await signed('claim',payload);assert.deepEqual(await readRelayRequest(request,secret,'claim'),payload);
});
test('one managed invocation persists result and one quota charge; same UUID replay is free of provider calls',async()=>{
  const actor=await fixture(),body=command(),net=network();const result=await generate(actor,body,net.fetch);
  assert.deepEqual(result.words,['Apple','Pear']);assert.equal(result.ai_remaining,9);assert.deepEqual(await generate(actor,body,net.fetch),result);assert.equal(net.calls,1);assert.equal(await used(actor),1);
  await assert.rejects(generate(actor,{...body,theme:'Cars'},net.fetch),e=>e.code==='request_id_reused');assert.equal(net.calls,1);
  const [row]=await db`select * from game_center_private.generation_provider_calls where user_id=${actor.id}`;assert.equal(row.state,'complete');assert.equal('input' in row,false);assert.equal('theme' in row,false);assert.equal('alreadyUsed' in row,false);
});
test('lost invoke and completion acknowledgements recover the durable result without another paid call',async()=>{
  for(const options of [{loseInvokeACK:true},{loseCompleteACK:true}]){const actor=await fixture(),body=command(),net=network(options);assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,1);assert.equal(await used(actor),1);}
});
test('temporary completion callback outages retry only result delivery and preserve one provider call',async()=>{
  const actor=await fixture(),body=command(),net=network({transientCompleteFailures:2});
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);
  assert.equal(net.calls,1);assert.equal(await used(actor),1);
  assert.equal(net.callbackPaths.filter(path=>path.endsWith('/claim')).length,1);
  assert.equal(net.callbackPaths.filter(path=>path.endsWith('/complete')).length,3);
  assert.equal(net.callbackPaths.some(path=>path.endsWith('/fail')),false);
  assert.deepEqual(net.delays,[250,750]);
});
test('an acknowledged provider or validation failure is terminal and cannot spend a second claim',async()=>{
  for(const [invoke,failure,code]of [
    [async()=>{throw new Error('PRIVATE_PROVIDER_ERROR');},'provider_failed','generation_failed'],
    [async()=>({private:'PRIVATE_INVALID_RESULT'}),'quality_failed','generation_quality_failed'],
  ]){
    const actor=await fixture(),body=command(),net=network({invoke});
    const terminal=error=>error.status===422&&error.code===code&&error.retryable===false&&!error.message.includes('PRIVATE');
    await assert.rejects(generate(actor,body,net.fetch),terminal);
    await assert.rejects(generate(actor,body,net.fetch),terminal);
    assert.equal(net.calls,1);assert.equal(await used(actor),1);
    const [request]=await db`select state,error_code,lease_id,lease_until from game_center_private.generation_requests where user_id=${actor.id}`;
    assert.deepEqual({...request},{state:'failed',error_code:failure==='provider_failed'?'generation_provider_failed':code,lease_id:null,lease_until:null});
    const [call]=await db`select state,error_code,result from game_center_private.generation_provider_calls where user_id=${actor.id}`;
    assert.deepEqual({...call},{state:'failed',error_code:failure,result:null});
  }
});
test('failure acknowledgement survives finalization and only the signed exact claim and reason can replay',async()=>{
  const actor=await fixture(),body=command(),net=network({invoke:async()=>{throw new Error('provider stopped');}});
  await assert.rejects(generate(actor,body,net.fetch),error=>error.code==='generation_failed');
  const payload=net.callbacks.find(callback=>callback.failure);
  assert.ok(payload);assert.equal((await net.control(await signed('fail',payload))).status,200);
  for(const options of [{signAction:'complete'},{signSecret:'2'.repeat(64)},{now:Date.now()-61_000}]){
    assert.equal((await net.control(await signed('fail',payload,options))).status,401);
  }
  const unsigned=new Request(RELAY_CALLBACK_URL+'/fail',{method:'POST',body:JSON.stringify(payload)});
  assert.equal((await net.control(unsigned)).status,401);
  for(const changed of [{...payload,claim_id:crypto.randomUUID()},{...payload,failure:'quality_failed'}]){
    assert.equal((await net.control(await signed('fail',changed))).status,409);
  }
  const completed={ticket:payload.ticket,claim_id:payload.claim_id,result:{words:['Apple','Pear'],category:'Fruit',exhausted:false}};
  assert.equal((await net.control(await signed('complete',completed))).status,409);
  assert.equal((await db`select state from game_center_private.generation_provider_calls where user_id=${actor.id}`)[0].state,'failed');
  assert.equal(net.calls,1);
});
test('complete acknowledgement survives request finalization and rejects a later failure or different result',async()=>{
  const actor=await fixture(),body=command(),net=network();await generate(actor,body,net.fetch);
  const payload=net.callbacks.find(callback=>callback.result);
  assert.ok(payload);assert.equal((await net.control(await signed('complete',payload))).status,200);
  assert.equal((await net.control(await signed('complete',{...payload,result:{...payload.result,words:['Lemon','Lime']}}))).status,409);
  assert.equal((await net.control(await signed('fail',{ticket:payload.ticket,claim_id:payload.claim_id,failure:'provider_failed'}))).status,409);
  assert.equal((await db`select state from game_center_private.generation_requests where user_id=${actor.id}`)[0].state,'complete');
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,1);
});
test('a final request persistence outage replays already stored words without a quality rejection or paid rerun',async()=>{
  const actor=await fixture(),body=command(),net=network();let injected=0;
  const interruptedDB=new Proxy(db,{get(target,key,receiver){
    if(key!=='begin')return Reflect.get(target,key,receiver);
    return action=>target.begin(tx=>action(new Proxy(tx,{apply(query,thisArg,args){
      if(injected===0&&Array.isArray(args[0])&&args[0].join(' ').includes("update game_center_private.generation_requests set state='complete'")){
        injected++;throw new Error('synthetic final persistence interruption');
      }
      return Reflect.apply(query,thisArg,args);
    }})));
  }});
  await assert.rejects(generate(actor,body,net.fetch,interruptedDB),error=>error.status>=500&&error.code!=='generation_quality_failed');
  assert.equal(injected,1);assert.equal(net.calls,1);assert.equal(await used(actor),1);
  const [prior]=await db`select state,error_code,lease_until from game_center_private.generation_requests where user_id=${actor.id}`;
  assert.notEqual(prior.error_code,'generation_quality_failed');
  assert.ok(prior.lease_until===null||new Date(prior.lease_until).getTime()<=Date.now());
  assert.equal((await db`select state from game_center_private.generation_provider_calls where user_id=${actor.id}`)[0].state,'complete');
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,1);assert.equal(await used(actor),1);
});
test('a database interruption before refill reuses the first result and invokes only the missing second call',async()=>{
  const actor=await fixture(),body=command(),net=network({invoke:async(_request,_input,count)=>candidate(count===1?['Apple']:['Pear'],true)});
  let renewalCount=0,injected=0;
  const interruptedDB=new Proxy(db,{get(target,key,receiver){
    if(key!=='begin')return Reflect.get(target,key,receiver);
    return action=>target.begin(tx=>action(new Proxy(tx,{apply(query,thisArg,args){
      if(Array.isArray(args[0])&&args[0].join(' ').includes("update game_center_private.generation_requests set lease_until=clock_timestamp()+interval '120 seconds'")){
        renewalCount++;
        if(renewalCount===2){injected++;throw new Error('synthetic refill boundary interruption');}
      }
      return Reflect.apply(query,thisArg,args);
    }})));
  }});
  await assert.rejects(generate(actor,body,net.fetch,interruptedDB),error=>error.code==='generation_persistence_retry'&&error.retryable);
  assert.equal(injected,1);assert.equal(net.calls,1);
  assert.deepEqual((await db`select call_index,state from game_center_private.generation_provider_calls where user_id=${actor.id} order by call_index`).map(row=>({...row})),[{call_index:0,state:'complete'}]);
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);
  assert.equal(net.calls,2);assert.deepEqual(net.tickets.map(ticket=>ticket.call_index),[0,1]);assert.equal(await used(actor),1);
});
test('a true normalization quality rejection remains terminal despite a completed relay result',async()=>{
  // These are distinct in the provider audit but collapse after the final
  // boundary punctuation normalization, leaving fewer than two usable words.
  const actor=await fixture(),body=command(),net=network({invoke:async()=>candidate(['Apple','Apple.'])});
  const terminal=error=>error.status===422&&error.code==='generation_quality_failed'&&error.retryable===false;
  await assert.rejects(generate(actor,body,net.fetch),terminal);
  await assert.rejects(generate(actor,body,net.fetch),terminal);
  assert.equal(net.calls,1);assert.equal(await used(actor),1);
  assert.equal((await db`select state from game_center_private.generation_provider_calls where user_id=${actor.id}`)[0].state,'complete');
  const [request]=await db`select state,error_code,lease_id from game_center_private.generation_requests where user_id=${actor.id}`;
  assert.deepEqual({...request},{state:'failed',error_code:'generation_quality_failed',lease_id:null});
});
test('unsigned routing headers cannot redirect Base44 elevated integration credentials',async()=>{
  const actor=await fixture(),body=command(),net=network({invoke:async(request)=>{
    assert.equal(request.headers.get('Base44-App-Id'),'69a0e57fa939f578082f8091');
    assert.equal(request.headers.get('Base44-Api-Url'),'https://base44.app');
    assert.equal(request.headers.get('Base44-Service-Authorization'),'Bearer fixture-platform-service');
    return candidate();
  }});
  await generate(actor,body,(url,init)=>net.fetch(url,{...init,headers:{...init.headers,'Base44-App-Id':'attacker-app','Base44-Api-Url':'https://example.invalid','Base44-Service-Authorization':'Bearer fixture-platform-service'}}));
  assert.equal(net.calls,1);
});
test('parallel request and replayed signed invocation cannot get a second paid claim',async()=>{
  const actor=await fixture(),body=command(),began=deferred(),release=deferred();const net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});
  const pending=generate(actor,body,net.fetch);await began.promise;
  await assert.rejects(generate(actor,body,net.fetch),e=>e.code==='generation_in_progress');
  const ticket=net.tickets[0],raw=JSON.stringify(ticket);const duplicate=await net.base44(new Request(RELAY_BASE44_URL,{method:'POST',headers:await relayHeaders(secret,'invoke',raw),body:raw}));assert.equal(duplicate.status,503);assert.equal(net.calls,1);
  release.resolve();assert.deepEqual((await pending).words,['Apple','Pear']);assert.equal(await used(actor),1);
});
test('a timeout after durable claim stays charged and cannot automatically invoke again after lease expiry',async()=>{
  const actor=await fixture(),body=command(),net=network({invoke:async()=>{throw new Error('ambiguous upstream timeout');},loseFailureCallback:true});
  await assert.rejects(generate(actor,body,net.fetch),e=>e.code==='generation_in_progress'&&e.retryable);assert.equal(await used(actor),1);
  await assert.rejects(generate(actor,body,net.fetch),e=>e.code==='generation_in_progress');
  await expire(actor,body);await assert.rejects(generate(actor,body,net.fetch),e=>e.status===422&&e.code==='generation_attempt_closed'&&!e.retryable);
  await assert.rejects(generate(actor,body,net.fetch),e=>e.status===422&&e.code==='generation_attempt_closed'&&!e.retryable);assert.equal(net.calls,1);assert.equal(await used(actor),1);
  const [row]=await db`select state,error_code from game_center_private.generation_requests where user_id=${actor.id}`;assert.deepEqual({...row},{state:'failed',error_code:'generation_outcome_unknown'});
});
test('transport failure before claim releases quota and fences a delayed invocation before allowing retry',async()=>{
  const actor=await fixture(),body=command(),net=network();let delayed;
  await assert.rejects(generate(actor,body,async(url,init)=>{delayed=new Request(url,init);throw new Error('offline before claim');}),e=>e.code==='ai_provider_unavailable'&&e.retryable);
  assert.equal(await used(actor),0);assert.equal((await net.base44(delayed)).status,503);assert.equal(net.calls,0);
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,1);assert.equal(await used(actor),1);
});
test('late successful completion after original HTTP failure is recovered from cache after lease expiry',async()=>{
  const actor=await fixture(),body=command(),began=deferred(),release=deferred();const net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});let remote;
  await assert.rejects(generate(actor,body,async(url,init)=>{remote=net.fetch(url,init);await began.promise;throw new Error('caller disconnected');}),e=>e.code==='generation_in_progress');
  release.resolve();assert.equal((await remote).status,200);await expire(actor,body);
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,1);assert.equal(await used(actor),1);
});
test('expired or replaced lease cannot complete a late paid attempt',async()=>{
  for(const replacement of [false,true]){const actor=await fixture(),body=command(),began=deferred(),release=deferred();const net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});
    const pending=generate(actor,body,net.fetch);await began.promise;
    if(replacement)await db`update game_center_private.generation_requests set lease_id=${crypto.randomUUID()} where user_id=${actor.id}`;else await expire(actor,body);
    release.resolve();await assert.rejects(pending);assert.equal((await db`select state from game_center_private.generation_provider_calls where user_id=${actor.id}`)[0].state,'started');assert.equal(net.calls,1);
  }
});
test('account deletion cascades private relay results and blocks late completion without resurrection',async()=>{
  const actor=await fixture(),body=command(),began=deferred(),release=deferred(),net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});
  const pending=generate(actor,body,net.fetch);await began.promise;
  await db.begin(async tx=>{await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+actor.id},0))`;await tx`update app_private.profiles set state='deleted' where user_id=${actor.id}`;await tx`delete from game_center_private.generation_requests where user_id=${actor.id}`;});
  release.resolve();await assert.rejects(pending);assert.equal((await db`select * from game_center_private.generation_provider_calls where user_id=${actor.id}`).length,0);assert.equal(await used(actor),0);
  await assert.rejects(generate(actor,body,net.fetch),e=>e.code==='account_unavailable');assert.equal(net.calls,1);
});
test('completion requires the exact claim and result hash, and rejects conflicting completion',async()=>{
  const actor=await fixture(),body=command(),began=deferred(),release=deferred(),net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});
  const pending=generate(actor,body,net.fetch);await began.promise;const ticket=net.tickets[0],result={words:['Apple','Pear'],category:'Fruit',exhausted:false};
  assert.equal((await net.control(await signed('complete',{ticket,claim_id:crypto.randomUUID(),result}))).status,409);
  const [call]=await db`select claim_id from game_center_private.generation_provider_calls where user_id=${actor.id}`;
  const payload={ticket,claim_id:call.claim_id,result};assert.equal((await net.control(await signed('complete',payload))).status,200);assert.equal((await net.control(await signed('complete',payload))).status,200);
  assert.equal((await net.control(await signed('complete',{...payload,result:{...result,words:['Lemon','Lime']}}))).status,409);
  release.resolve();assert.deepEqual((await pending).words,['Apple','Pear']);assert.equal(net.calls,1);
});
test('client-shaped extra payload fields and a changed actor/hash never reach InvokeLLM',async()=>{
  const actor=await fixture(),body=command(),began=deferred(),release=deferred(),net=network({invoke:async()=>{began.resolve();await release.promise;return candidate();}});
  const pending=generate(actor,body,net.fetch);await began.promise;const ticket=net.tickets[0];
  for(const patch of [{model:'attacker'},{callback_url:'https://example.invalid'},{quota:1000},{actor_id:crypto.randomUUID()},{request_hash:'2'.repeat(64)},{input:{...ticket.input,count:99}}]){
    const forged={...ticket,...patch},raw=JSON.stringify(forged);const result=await net.base44(new Request(RELAY_BASE44_URL,{method:'POST',headers:await relayHeaders(secret,'invoke',raw),body:raw}));assert.ok(result.status>=400);
  }
  assert.equal(net.calls,1);release.resolve();await pending;
});
test('private provider table denies anonymous/authenticated access',async()=>{
  for(const role of ['anon','authenticated'])await assert.rejects(db.begin(async tx=>{await tx.unsafe('set local role '+role);return tx`select * from game_center_private.generation_provider_calls limit 1`;}),e=>e.code==='42501');
});
test('managed generation preserves ten free reservations, ignores editable premium and honors a server grant',async()=>{
  const actor=await fixture(),net=network();const results=await Promise.allSettled(Array.from({length:11},()=>generate(actor,command(),net.fetch)));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,10);assert.equal(results.filter(r=>r.status==='rejected'&&r.reason.code==='ai_limit_reached').length,1);assert.equal(net.calls,10);assert.equal(await used(actor),10);
  await db`insert into app_private.membership_grants(id,user_id,active,expires_at,data) values(${crypto.randomUUID()},${actor.id},true,clock_timestamp()+interval '1 day','{}')`;
  const paid=await generate(actor,command(),net.fetch);assert.equal(paid.ai_limit,null);assert.equal(paid.ai_remaining,null);assert.equal(await used(actor),11);
});
test('exhaustion refill claims at most two fixed provider calls under one quota charge',async()=>{
  const actor=await fixture(),body=command(),net=network({invoke:async(_request,_input,count)=>candidate(count===1?['Apple']:['Pear'],true)});
  assert.deepEqual((await generate(actor,body,net.fetch)).words,['Apple','Pear']);assert.equal(net.calls,2);assert.deepEqual(net.tickets.map(t=>t.call_index),[0,1]);assert.deepEqual(net.tickets[1].input.alreadyUsed,['Apple']);assert.equal(await used(actor),1);
  await generate(actor,body,net.fetch);assert.equal(net.calls,2);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {createNativeWordPackRelay} from '../../../../base44/functions/nativeGameCenterWordPack/handler.ts';
import {relayHeaders,relayDigest,relayCanonical,RELAY_PROMPT_VERSION,RELAY_BASE44_URL,RELAY_CALLBACK_URL} from '../../../../base44/functions/nativeGameCenterWordPack/relay-protocol.ts';

const secret='1'.repeat(64),gatewayToken='fixture.'+Buffer.from(JSON.stringify({role:'anon',ref:'bbkfsgnordtdiblgdzkg'})).toString('base64url')+'.fixture';
async function signed(){
  const input={theme:'PRIVATE_THEME',count:2,alreadyUsed:['PRIVATE_WORD']};
  const ticket={actor_id:crypto.randomUUID(),request_id:crypto.randomUUID(),request_hash:'2'.repeat(64),lease_id:crypto.randomUUID(),call_index:0,
    input_hash:await relayDigest(relayCanonical({version:RELAY_PROMPT_VERSION,...input})),input};
  const body=JSON.stringify(ticket);
  return {ticket,request:new Request(RELAY_BASE44_URL,{method:'POST',headers:await relayHeaders(secret,'invoke',body),body})};
}
test('non-2xx callback diagnostics contain only fixed stage and status before any provider call',async()=>{
  for(const status of [401,403,500]){
    const {ticket,request}=await signed();let calls=0;const events=[];
    const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:event=>events.push(event),invoke:async()=>{calls++;},
      fetch:async()=>new Response(JSON.stringify({token:secret,actor:ticket.actor_id,error:'PRIVATE_UPSTREAM_BODY'}),{status})})(request);
    assert.equal(response.status,503);assert.deepEqual(await response.json(),{ok:false,code:'relay_unavailable'});assert.equal(calls,0);
    assert.deepEqual(events,[{stage:'claim_response',callback_status:status}]);
    for(const value of [secret,gatewayToken,ticket.actor_id,ticket.request_id,ticket.lease_id,'PRIVATE_THEME','PRIVATE_WORD','PRIVATE_UPSTREAM_BODY'])assert.equal(JSON.stringify(events).includes(value),false);
  }
});
test('transport exception text is never logged and cannot invoke the provider',async()=>{
  const {request}=await signed();let calls=0;const events=[];
  const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:event=>events.push(event),invoke:async()=>{calls++;},
    fetch:async()=>{throw new Error('PRIVATE_TRANSPORT_URL?token='+secret);}})(request);
  assert.equal(response.status,503);assert.equal(calls,0);assert.deepEqual(events,[{stage:'claim_transport'}]);
});
test('configuration and authentication failures stay distinguishable without logging input',async()=>{
  for(const [options,stage,status]of [[{secret:''},'configuration',503],[{},'authenticate',401]]){
    const events=[];let calls=0;
    const response=await createNativeWordPackRelay({secret,gatewayToken,...options,diagnose:event=>events.push(event),invoke:async()=>{calls++;},fetch:async()=>{throw Error('must not fetch');}})(new Request(RELAY_BASE44_URL,{method:'POST',body:'PRIVATE_INPUT'}));
    assert.equal(response.status,status);assert.equal(calls,0);assert.deepEqual(events,[{stage}]);
  }
});
test('a failing diagnostic sink cannot change the external response',async()=>{
  const {request}=await signed();let calls=0;
  const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:()=>{throw Error('PRIVATE_LOGGER_FAILURE');},invoke:async()=>{calls++;},fetch:async()=>new Response('PRIVATE_BODY',{status:403})})(request);
  assert.equal(response.status,503);assert.deepEqual(await response.json(),{ok:false,code:'relay_unavailable'});assert.equal(calls,0);
});
test('provider failure clears previous callback status and never retries the provider',async()=>{
  const {request}=await signed();let calls=0,callbacks=0;const events=[];
  const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:event=>events.push(event),
    invoke:async()=>{calls++;throw Error('PRIVATE_PROVIDER_ERROR '+secret);},
    fetch:async()=>{callbacks++;return Response.json({state:'started',claim_id:crypto.randomUUID()});}})(request);
  assert.equal(response.status,503);assert.equal(calls,1);assert.equal(callbacks,1);assert.deepEqual(events,[{stage:'provider'}]);
});
test('completion failure logs only its own status without retrying a completed provider call',async()=>{
  const {request}=await signed();let calls=0,callbacks=0;const events=[];
  const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:event=>events.push(event),
    invoke:async()=>{calls++;return {draft_words:['Apple','Pear'],accepted_indices:[0,1],replacement_words:[],accepted_replacement_indices:[],category:'Fruit',exhausted:false};},
    fetch:async()=>{callbacks++;return callbacks===1?Response.json({state:'started',claim_id:crypto.randomUUID()}):new Response('PRIVATE_COMPLETION_BODY',{status:500});}})(request);
  assert.equal(response.status,503);assert.equal(calls,1);assert.equal(callbacks,2);assert.deepEqual(events,[{stage:'complete_response',callback_status:500}]);
});
for(const status of [301,302,303,307,308])test(`redirect ${status} cannot forward callback credentials or retry a provider call`,async()=>{
  for(const phase of ['claim','complete']){
    const {request}=await signed();let calls=0;const events=[],urls=[];
    const response=await createNativeWordPackRelay({secret,gatewayToken,diagnose:event=>events.push(event),
      invoke:async()=>{calls++;return {draft_words:['Apple','Pear'],accepted_indices:[0,1],replacement_words:[],accepted_replacement_indices:[],category:'Fruit',exhausted:false};},
      fetch:async(url,options)=>{
        assert.equal(options.redirect,'manual');assert.ok(options.signal instanceof AbortSignal);urls.push(url);
        if(phase==='complete'&&urls.length===1)return Response.json({state:'started',claim_id:crypto.randomUUID()});
        return new Response('PRIVATE_REDIRECT_BODY',{status,headers:{Location:'https://forbidden.example/?secret='+secret}});
      }})(request);
    assert.equal(response.status,503);assert.deepEqual(await response.json(),{ok:false,code:'relay_unavailable'});
    assert.equal(calls,phase==='claim'?0:1);assert.deepEqual(urls,phase==='claim'?[RELAY_CALLBACK_URL+'/claim']:[RELAY_CALLBACK_URL+'/claim',RELAY_CALLBACK_URL+'/complete']);
    assert.deepEqual(events,[{stage:phase+'_response',callback_status:status}]);
  }
});

import {strict as assert} from 'node:assert';
import {transferReward,fingerprint,RewardTransferError} from './transfer.ts';
import {createRewardTransferHandler} from './handler.ts';
import {grantVerifiedGenerationReward,availableRewardCredits,reserveGenerationReward} from '../generationRewardAction/generation-rewards.ts';
import {forwardTransferredReward} from '../generationRewardAction/reward-transfer-forward.ts';
const attempt='11111111-1111-4111-8111-111111111111',native='22222222-2222-4222-8222-222222222222',transfer='33333333-3333-4333-8333-333333333333';
const issued='2026-11-07T20:02:00.000Z',now=new Date('2026-11-19T12:00:00.000Z');
const guard={boundary:async<T>(operation:()=>Promise<T>)=>await operation()};
async function fixture(state='pending') {
  let row:any={id:'source-record',user_id:'legacy-owner',attempt_id:attempt,custom_data:attempt+'.legacy.'+'a'.repeat(64),ad_unit_id:'ca-app-pub-5081830513960558/6816674766',issued_at:issued,state};
  if(state!=='pending')Object.assign(row,{transaction_id:'original-transaction',earned_at:issued});
  if(state==='spent'||state==='reserved')row.generation_request_id='44444444-4444-4444-8444-444444444444';
  let updates=0;
  const store={filter:async(query:any)=>Object.entries(query).every(([k,v])=>row[k]===v)?[structuredClone(row)]:[],
    updateMany:async(query:any,change:any)=>{if(Object.entries(query).every(([k,v])=>row[k]===v)){row={...row,...change.$set};updates++;return {updated:1};}return {updated:0};},create:async()=>{throw new Error('No new source reward is allowed.');}};
  const target={source_record_id:row.id,legacy_user_id:row.user_id,native_user_id:native,transfer_id:transfer,fingerprint:await fingerprint(row)};
  return {store,target,get row(){return row;},get updates(){return updates;}};
}
Deno.test('fixed source fence retains original pending obligation, is idempotent and defeats old pending callback CAS',async()=>{
  const f=await fixture();const first=await transferReward(f.store,guard,f.target,now);
  assert.equal(first.state,'transferred');assert.equal(first.transfer_state,'pending');assert.equal(first.issued_at,issued);
  assert.deepEqual(await transferReward(f.store,guard,f.target,now),first);assert.equal(f.updates,1);
  const callback={transactionID:'delayed-signed-event',customData:f.row.custom_data,userID:'legacy-owner',adUnit:f.row.ad_unit_id,rewardAmount:1,rewardItem:'generation',timestamp:Date.parse(issued)+1000};
  await assert.rejects(grantVerifiedGenerationReward({store:f.store,guard,callback,now}),{code:'reward_storage_unavailable'});
  assert.equal(f.row.state,'transferred');assert.equal(f.row.transaction_id,undefined);
});
Deno.test('earned and spent outcomes before coordinator fence are preserved without another source spend',async()=>{
  for(const state of ['earned','spent']){
    const f=await fixture(state),snapshot=await transferReward(f.store,guard,f.target,now);
    assert.equal(snapshot.transfer_state,state);assert.equal(snapshot.transaction_id,'original-transaction');assert.equal(snapshot.earned_at,issued);
    if(state==='spent')assert.equal(snapshot.generation_request_id,'44444444-4444-4444-8444-444444444444');
    assert.equal(await availableRewardCredits(f.store,'legacy-owner'),0);
    assert.equal(await reserveGenerationReward({store:f.store,guard,userID:'legacy-owner',requestID:crypto.randomUUID()}),null);
  }
});
Deno.test('reserved, foreign-owner and mutated original attempts cannot transfer',async()=>{
  const reserved=await fixture('reserved');await assert.rejects(transferReward(reserved.store,guard,reserved.target),{code:'reward_transfer_busy'});assert.equal(reserved.updates,0);
  const f=await fixture();await assert.rejects(transferReward(f.store,guard,{...f.target,legacy_user_id:'another-owner'}),RewardTransferError);
  await assert.rejects(transferReward(f.store,guard,{...f.target,fingerprint:'b'.repeat(64)}),RewardTransferError);assert.equal(f.updates,0);
});
Deno.test('unauthorized and caller-selected transfer requests never acquire service entities',async()=>{
  const f=await fixture();let entities=0;
  const input=(body:any)=>new Request('https://attacker.invalid',{method:'POST',headers:{Authorization:'Bearer synthetic','Base44-App-Id':'other','Base44-Api-Url':'https://attacker.invalid','Base44-Service-Authorization':'Bearer injected',Cookie:'private=value'},body:JSON.stringify(body)});
  const options={targets:[f.target],expiresAt:now.getTime()+10000,now:()=>now.getTime(),entities:()=>{entities++;return {};},withLease:async()=>{throw new Error('not reached');}};
  for(const auth of [async()=>{throw new Error('bad token');},async()=>({id:'member',role:'user'})]){
    const response=await createRewardTransferHandler({...options,authenticate:auth})(input({action:'transfer'}));assert.ok([401,403].includes(response.status));
  }
  const authenticate=async(request:Request)=>{
    assert.equal(request.headers.get('Base44-App-Id'),'69a0e57fa939f578082f8091');assert.equal(request.headers.get('Base44-Api-Url'),'https://base44.app');
    assert.equal(request.headers.get('Base44-Service-Authorization'),null);assert.equal(request.headers.get('Cookie'),null);return {id:'admin',role:'admin'};
  };
  assert.equal((await createRewardTransferHandler({...options,authenticate})(input({action:'transfer',user_id:'chosen'}))).status,400);
  assert.equal((await createRewardTransferHandler({...options,authenticate,targets:[]})(input({action:'transfer'}))).status,410);assert.equal(entities,0);
});
Deno.test('authorized fixed operation acquires exact owner coordinator and returns durable receipt',async()=>{
  const f=await fixture();let leases=0;
  const handler=createRewardTransferHandler({targets:[f.target],expiresAt:now.getTime()+10000,now:()=>now.getTime(),authenticate:async()=>({id:'admin',role:'admin'}),
    entities:()=>({GenerationReward:f.store,BillingIdentityLifecycle:{}}),withLease:async input=>{assert.equal(input.userID,'legacy-owner');leases++;return await input.action(guard);}});
  const response=await handler(new Request('https://spyclash.com',{method:'POST',body:'{"action":"transfer"}'}));
  assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');
  const receipt=await response.json();assert.equal(receipt.version,1);assert.equal(receipt.records[0].state,'transferred');assert.equal(leases,1);
});
Deno.test('transferred callback forwards only raw signed query to fixed target with no caller secrets or redirect follow',async()=>{
  const f=await fixture(),row=await transferReward(f.store,guard,f.target,now);
  const query='?a=one+two&custom_data=x%2ey&signature=synthetic%2Bsignature';
  const request=new Request('https://spyclash.com/callback'+query,{headers:{Authorization:'Bearer private','Base44-Service-Authorization':'Bearer server'}});
  let calls=0;const fetcher:typeof fetch=async(url,init)=>{
    calls++;assert.equal(url,'https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv'+query);assert.equal(init?.redirect,'manual');
    const headers=new Headers(init?.headers);assert.equal(headers.get('authorization'),null);assert.equal(headers.get('Base44-Service-Authorization'),null);assert.equal(headers.get('X-SpyClash-Reward-Transfer'),'1');return Response.json({received:true});
  };
  assert.deepEqual(await forwardTransferredReward(request,row,false,fetcher),{success:true});assert.equal(calls,1);
  for(const response of [new Response(null,{status:302}),new Response('x'.repeat(4097)),Response.json({success:true})])await assert.rejects(forwardTransferredReward(request,row,false,async()=>response));
});

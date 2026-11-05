import assert from 'node:assert/strict';
import test from 'node:test';
import {readAppleLoyaltyHistory,mergeAppleLoyaltySnapshot} from '../../supabase/functions/app-services/billing-rules/apple-loyalty.ts';

const now=Date.parse('2026-11-05T12:00:00Z');
const token='a7b156a1-4cf1-4479-ab42-c0f0fe0606a9';
const weekly='com.spyclash.ios.limitless.weekly';
const transaction=(id,extra={})=>({transactionId:id,originalTransactionId:'chain-1',appAccountToken:token,
  productId:weekly,bundleId:'com.spyclash.ios',environment:'Production',type:'Auto-Renewable Subscription',
  inAppOwnershipType:'PURCHASED',price:1990,purchaseDate:now-86_400_000,signedDate:now-1000,...extra});
const page=(transactions,extra={})=>({bundleId:'com.spyclash.ios',environment:'Production',appAppleId:6793534085,
  signedTransactions:transactions.map(t=>JSON.stringify(t)),hasMore:false,revision:'done',...extra});
const input=(pages,extra={})=>({transactionID:pages[0]?.signedTransactions?.length?JSON.parse(pages[0].signedTransactions[0]).transactionId:'latest',originalTransactionID:'chain-1',appAccountToken:token,
  expectedProducts:[weekly],expectedBundleID:'com.spyclash.ios',expectedEnvironment:'Production',expectedAppAppleID:6793534085,
  getHistory:async(_id,revision)=>pages[revision?1:0],verifyTransaction:async signed=>JSON.parse(signed),now:()=>now,...extra});

test('paid purchases and renewals backfill across pages and restores/duplicates count once',async()=>{
  const seen=[];
  const pages=[page([transaction('purchase',{transactionReason:'PURCHASE'}),transaction('renewal-1',{transactionReason:'RENEWAL'})],{hasMore:true,revision:'next'}),
    page([transaction('renewal-1'),transaction('renewal-2',{appAccountToken:undefined})])];
  const result=await readAppleLoyaltyHistory(input(pages,{getHistory:async(id,revision)=>{seen.push([id,revision]);return pages[revision?1:0];}}));
  assert.deepEqual(seen,[['purchase',null],['purchase','next']]);
  assert.deepEqual(result,{original_transaction_id:'chain-1',environment:'production',transaction_ids:['purchase','renewal-1','renewal-2'],verified_at:new Date(now).toISOString()});
  assert.deepEqual(await readAppleLoyaltyHistory(input(pages)),result);
});
test('free trials, zero or absent prices, family sharing and all refund representations are ineligible',async()=>{
  const changes=[{price:0},{price:undefined},{price:'1990'},{price:NaN},{price:-1},{offerDiscountType:'FREE_TRIAL'},
    {inAppOwnershipType:'FAMILY_SHARED'},{inAppOwnershipType:undefined},{revocationDate:now-10},
    {revocationReason:0},{revocationType:'REFUND_FULL'},{revocationPercentage:100000},
    {purchaseDate:now+1},{type:'Non-Consumable'},{productId:'another.product'}];
  const result=await readAppleLoyaltyHistory(input([page(changes.map((v,i)=>transaction('invalid-'+i,v)))]));
  assert.deepEqual(result.transaction_ids,[]);
});
test('sandbox never contributes paid achievements',async()=>{
  const result=await readAppleLoyaltyHistory(input([page([transaction('sandbox',{environment:'Sandbox'})],{environment:'Sandbox'})],{expectedEnvironment:'Sandbox'}));
  assert.equal(result.environment,'sandbox');assert.deepEqual(result.transaction_ids,[]);
});
test('unrelated chains are excluded, but a matching chain with a different account token rejects the snapshot',async()=>{
  await assert.rejects(readAppleLoyaltyHistory(input([page([transaction('foreign',{originalTransactionId:'chain-2',appAccountToken:'other'})])])),/omitted the verified transaction/);
  await assert.rejects(readAppleLoyaltyHistory(input([page([transaction('foreign',{appAccountToken:'other'})])])),/binding mismatch/);
});
test('signature failure and mismatched response or transaction app identity cannot become awards',async()=>{
  await assert.rejects(readAppleLoyaltyHistory(input([page([transaction('one')])],{verifyTransaction:async()=>{throw Error('signature');}})),/signature/);
  for(const changes of [{bundleId:'wrong'},{environment:'Sandbox'},{appAppleId:1}])
    await assert.rejects(readAppleLoyaltyHistory(input([page([],changes)])),/history response/);
  for(const changes of [{bundleId:'wrong'},{environment:'Sandbox'}])
    await assert.rejects(readAppleLoyaltyHistory(input([page([transaction('one',changes)])])),/identity mismatch/);
});
test('pagination must complete and advance before a snapshot is usable',async()=>{
  await assert.rejects(readAppleLoyaltyHistory(input([page([])])),/omitted the verified transaction/);
  for(const extra of [{hasMore:true,revision:''},{hasMore:undefined}])
    await assert.rejects(readAppleLoyaltyHistory(input([page([],extra)])));
  await assert.rejects(readAppleLoyaltyHistory(input([], {getHistory:async()=>page([],{hasMore:true,revision:'repeat'})})),/Incomplete/);
  let calls=0;
  await assert.rejects(readAppleLoyaltyHistory(input([], {getHistory:async()=>page([],{hasMore:true,revision:String(++calls)})})),/bounded page limit/);
  assert.equal(calls,100);
});
test('elapsed history deadline stops work after the in-flight page, without verifying or requesting more',async()=>{
  let pages=0,verifications=0;
  await assert.rejects(readAppleLoyaltyHistory(input([],{
    deadlineMilliseconds:Date.now()+20,
    getHistory:async()=>{pages++;await new Promise(resolve=>setTimeout(resolve,30));return page([transaction('latest')],{hasMore:true,revision:'next'});},
    verifyTransaction:async signed=>{verifications++;return JSON.parse(signed);},
  })),/timed out/);
  assert.equal(pages,1);assert.equal(verifications,0);
});
test('updated/refunded duplicate state wins by signed date, independent of delivery order',async()=>{
  const older=transaction('one'),revoked=transaction('one',{signedDate:now,revocationDate:now-1});
  for(const rows of [[older,revoked],[revoked,older],[older,{...revoked,signedDate:older.signedDate}]]) {
    const result=await readAppleLoyaltyHistory(input([page(rows)]));assert.deepEqual(result.transaction_ids,[]);
  }
  const reversed=transaction('one',{signedDate:now+1});
  assert.deepEqual((await readAppleLoyaltyHistory(input([page([revoked,reversed])]))).transaction_ids,['one']);
});
test('complete newer snapshot replaces prior counts; stale, missing and mismatched snapshots preserve known history',()=>{
  const current={original_transaction_id:'chain-1',environment:'production',status:'active'};
  const prior={...current,loyalty_transaction_ids:['one','two'],loyalty_verified_at:new Date(now).toISOString()};
  const next={original_transaction_id:'chain-1',environment:'production',transaction_ids:['one'],verified_at:new Date(now+1).toISOString()};
  assert.deepEqual(mergeAppleLoyaltySnapshot(current,prior,next).loyalty_transaction_ids,['one']);
  for(const snapshot of [undefined,{...next,verified_at:new Date(now-1).toISOString()},{...next,original_transaction_id:'other'},{...next,environment:'sandbox'}])
    assert.deepEqual(mergeAppleLoyaltySnapshot(current,prior,snapshot).loyalty_transaction_ids,['one','two']);
  assert.equal(mergeAppleLoyaltySnapshot({...current,original_transaction_id:'other'},prior).loyalty_transaction_ids,undefined);
});

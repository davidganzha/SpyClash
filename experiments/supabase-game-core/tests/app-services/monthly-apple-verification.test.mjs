import assert from 'node:assert/strict';
import test from 'node:test';
import {verifyApple,nativeGameCenterConfiguration,MAIN_APPLE_APP_ID} from '../../supabase/functions/app-services/native-apple.ts';
import {WEEKLY_PRODUCT,MONTHLY_PRODUCT} from '../../supabase/functions/app-services/billing-rules/apple-products.ts';

const config=nativeGameCenterConfiguration({APP_IAP_ENABLED:'true',APP_NATIVE_GAME_CENTER_IAP_ENABLED:'true',
  APP_IAP_BUNDLE_ID:'com.spyclash.ios',APP_IAP_APPLE_ID:String(MAIN_APPLE_APP_ID),APP_IAP_ENVIRONMENT:'Sandbox',
  APP_IAP_KEY_ID:'fixture',APP_IAP_ISSUER_ID:'fixture',APP_IAP_PRIVATE_KEY_P8:'fixture',APP_IAP_ROOT_CERTIFICATES_JSON:'[]',
  SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED:'false',SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED:'false'});

// These tests start at the verified SDK boundary. The real certificate/JWS/OCSP
// regression suite separately checks that no unsigned payload reaches it.
function fixture({submittedProduct=MONTHLY_PRODUCT,currentProduct=submittedProduct,submittedPatch={},currentPatch={},renewalPatch={},responsePatch={}}={}) {
  const original='2000000000000001',token='11111111-1111-4111-8111-111111111111';
  const submitted={productId:submittedProduct,bundleId:'com.spyclash.ios',environment:'Sandbox',
    transactionId:'2000000000000002',originalTransactionId:original,appAccountToken:token,...submittedPatch};
  const current={...submitted,transactionId:'2000000000000003',productId:currentProduct,
    expiresDate:Date.now()+3600000,...currentPatch};
  const renewal={originalTransactionId:original,productId:currentProduct,environment:'Sandbox',appAccountToken:token,...renewalPatch};
  let statusReads=0;
  const tools=async()=>({invalidEnvironment:4,retryableFailure:2,
    verifier:{verifyAndDecodeTransaction:async jws=>jws==='submitted'?submitted:current,verifyAndDecodeRenewalInfo:async()=>renewal},
    client:{getAllSubscriptionStatuses:async()=>{statusReads++;return {bundleId:'com.spyclash.ios',environment:'Sandbox',
      data:[{lastTransactions:[{originalTransactionId:original,status:1,signedTransactionInfo:'current',signedRenewalInfo:'renewal'}]}],...responsePatch};}},
    getHistory:async()=>{throw new Error('Optional history fixture unavailable');}});
  return {run:()=>verifyApple('submitted',config,{tools}),statusReads:()=>statusReads,submitted,current};
}

test('verified weekly/monthly renewals and same-chain crossgrades restore with both new-purchase gates disabled',async()=>{
  for(const submittedProduct of [WEEKLY_PRODUCT,MONTHLY_PRODUCT]) for(const currentProduct of [WEEKLY_PRODUCT,MONTHLY_PRODUCT]) {
    const f=fixture({submittedProduct,currentProduct});
    const result=await f.run();
    assert.equal(result.submittedProductID,submittedProduct);
    assert.equal(result.transaction.productId,currentProduct);
    assert.equal(result.transaction.originalTransactionId,f.submitted.originalTransactionId);
    assert.equal(result.transaction.appAccountToken,f.submitted.appAccountToken);
    assert.equal(result.status,1);assert.equal(f.statusReads(),1);
  }
});

test('monthly support never admits an unlisted submitted product, app, or environment',async()=>{
  for(const submittedPatch of [{productId:'unknown.monthly'},{productId:''},{bundleId:'com.other.app'},{environment:'Production'}]) {
    const f=fixture({submittedPatch});
    await assert.rejects(f.run(),error=>error.code==='transaction_identity_mismatch'&&error.status===422);
    assert.equal(f.statusReads(),0);
  }
});

test('monthly canonical status cannot substitute another product, chain, owner, renewal, or app',async()=>{
  const cases=[
    {currentPatch:{productId:'unknown.product'}},
    {currentPatch:{originalTransactionId:'2000000000000099'}},
    {currentPatch:{appAccountToken:'22222222-2222-4222-8222-222222222222'}},
    {currentPatch:{bundleId:'com.other.app'}},
    {currentPatch:{environment:'Production'}},
    {renewalPatch:{originalTransactionId:'2000000000000099'}},
    {renewalPatch:{productId:WEEKLY_PRODUCT}},
    {renewalPatch:{environment:'Production'}},
    {renewalPatch:{appAccountToken:'22222222-2222-4222-8222-222222222222'}},
    {submittedPatch:{appAccountToken:undefined}},
  ];
  for(const options of cases) await assert.rejects(fixture(options).run(),error=>error.status===409);
  for(const responsePatch of [{bundleId:'com.other.app'},{environment:'Production'}])
    await assert.rejects(fixture({responsePatch}).run(),error=>error.status===503);
});

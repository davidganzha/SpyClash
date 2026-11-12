import assert from 'node:assert/strict';
import {VerificationException,VerificationStatus} from 'npm:@apple/app-store-server-library@3.1.0';
import {verifyApple,nativeGameCenterConfiguration,MAIN_APPLE_APP_ID} from '../../supabase/functions/app-services/native-apple.ts';
import {parseAppleOCSPDate,ensureAppleOCSPDateParsing} from '../../supabase/functions/app-services/billing-rules/apple-ocsp-date.ts';

const config=nativeGameCenterConfiguration({APP_IAP_ENABLED:'true',APP_NATIVE_GAME_CENTER_IAP_ENABLED:'true',
  APP_IAP_BUNDLE_ID:'com.spyclash.ios',APP_IAP_APPLE_ID:String(MAIN_APPLE_APP_ID),APP_IAP_ENVIRONMENT:'SandboxAndProduction',
  APP_IAP_KEY_ID:'fixture',APP_IAP_ISSUER_ID:'fixture',APP_IAP_PRIVATE_KEY_P8:'fixture',APP_IAP_ROOT_CERTIFICATES_JSON:'[]'});

Deno.test('native Apple path distinguishes runtime outage from invalid signed evidence',async()=>{
  const warnings:unknown[][]=[];
  const original=console.warn;
  console.warn=(...values:unknown[])=>{warnings.push(values);};
  try {
    const runtimeCause=Object.assign(new Error('Not implemented: crypto.X509Certificate.prototype.toString private-signed-evidence'),{code:'ERR_NOT_IMPLEMENTED'});
    for(const [error,status,retryable] of [
      [new VerificationException(VerificationStatus.VERIFICATION_FAILURE,runtimeCause),503,true],
      [new VerificationException(VerificationStatus.VERIFICATION_FAILURE,new Error('invalid signature private-signed-evidence')),422,false],
      [new VerificationException(VerificationStatus.INVALID_CERTIFICATE),422,false],
      [new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE),503,true],
    ] as const) {
      let attempts=0;
      const tools=async()=>({invalidEnvironment:VerificationStatus.INVALID_ENVIRONMENT,retryableFailure:VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
        verifier:{verifyAndDecodeTransaction:async()=>{attempts++;throw error;}}});
      await assert.rejects(verifyApple('private-signed-evidence',config,{tools:tools as any}),error=>{
        const outcome=error as {status:number;retryable:boolean;code:string};
        assert.equal(outcome.status,status);assert.equal(outcome.retryable,retryable);
        assert.equal(outcome.code,retryable?'apple_verification_unavailable':'invalid_apple_transaction');return true;
      });
      assert.equal(attempts,1);
    }
    assert.equal(warnings.length,4);
    assert.equal(JSON.stringify(warnings).includes('private-signed-evidence'),false);
    assert.equal(JSON.stringify(warnings).includes('SERVER_CRYPTO_UNAVAILABLE'),true);
  } finally {console.warn=original;}
});

Deno.test('OCSP parser validates UTC calendar fields and rejects invalid timestamps',()=>{
  assert.equal(parseAppleOCSPDate('20261111230540Z').toISOString(),'2026-11-11T23:05:40.000Z');
  assert.equal(parseAppleOCSPDate('20261111230540').toISOString(),'2026-11-11T23:05:40.000Z');
  assert.equal(parseAppleOCSPDate('20280229000000Z').toISOString(),'2028-02-29T00:00:00.000Z');
  for(const value of ['','20260229000000Z','20261301000000Z','20260001000000Z','20261131230000Z',
    '20261111240540Z','20261111236040Z','20261111230560Z','20261111230540+0100','20261111230540Zjunk','19691231235959Z']) {
    assert.throws(()=>parseAppleOCSPDate(value),RangeError);
  }
  const verifier={parseX509Date:()=>new Date(NaN)};
  ensureAppleOCSPDateParsing(verifier);ensureAppleOCSPDateParsing(verifier);
  assert.equal(verifier.parseX509Date,parseAppleOCSPDate);
  assert.throws(()=>ensureAppleOCSPDateParsing({}),/Unsupported Apple verifier/);
});

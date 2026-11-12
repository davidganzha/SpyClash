import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import {createAppleVerifierFixtures} from './apple-verifier-fixtures.ts';
import {appleVerificationFailure} from '../../supabase/functions/app-services/billing-rules/apple-verification-failure.ts';
import {ensureAppleOCSPDateParsing} from '../../supabase/functions/app-services/billing-rules/apple-ocsp-date.ts';

/** Shared by Deno tests and the real Supabase Edge runtime probe. The caller
 * serves fixtures.respond over loopback; every online check uses real DER.
 */
export async function runAppleVerifierRegressionCases(fixtures: ReturnType<typeof createAppleVerifierFixtures>) {
  const {SignedDataVerifier,Environment,VerificationStatus,VerificationException,AppStoreServerAPIClient} = await import('npm:@apple/app-store-server-library@3.1.0');
  const results: string[] = [];
  const verifier = (environment = Environment.SANDBOX, root:Buffer|Buffer[] = fixtures.rootDER) => {
    const value=new SignedDataVerifier(Array.isArray(root)?root:[root],true,environment,'com.spyclash.ios',6793534085);
    ensureAppleOCSPDateParsing(value);
    return value;
  };
  async function run(name:string,fn:()=>Promise<void>|void) {
    fixtures.setMode('good');
    try { await fn(); } catch (error) { throw new Error(name, {cause:error}); }
    results.push(name);
  }
  const rejected = (status?:number) => (error:unknown) => {
    assert.ok(error instanceof VerificationException);
    if (status !== undefined) assert.equal(error.status,status);
    assert.equal(appleVerificationFailure(error).runtimeFailure,false);
    return true;
  };
  await run('valid Sandbox P-256 transaction with live OCSP',async()=>{
    const value=await verifier().verifyAndDecodeTransaction(fixtures.signed());
    assert.equal(value.environment,'Sandbox');
    assert.equal(value.transactionId,'2000000000000001');
    assert.equal(fixtures.calls,2);
  });
  await run('valid Production P-256 transaction with live OCSP',async()=>{
    const value=await verifier(Environment.PRODUCTION).verifyAndDecodeTransaction(fixtures.signed({environment:'Production'}));
    assert.equal(value.environment,'Production');assert.equal(fixtures.calls,2);
  });
  await run('mixed RSA roots before trusted EC root allow a valid signed transaction',async()=>{
    for(const roots of [[...fixtures.rsaRootDERs,fixtures.rootDER],[fixtures.rootDER,...fixtures.rsaRootDERs]]) {
      fixtures.setMode('good');
      const value=await verifier(Environment.SANDBOX,roots).verifyAndDecodeTransaction(fixtures.signed());
      assert.equal(value.transactionId,'2000000000000001');assert.equal(fixtures.calls,2);
    }
  });
  await run('mixed RSA and EC roots without the issuing root reject the chain',async()=>{
    await assert.rejects(verifier(Environment.SANDBOX,[...fixtures.rsaRootDERs,fixtures.foreignRootDER]).verifyAndDecodeTransaction(fixtures.signed()),rejected());
    assert.equal(fixtures.calls,0);
  });
  await run('mixed trust roots still reject a forged JWS signature',async()=>{
    const pieces=fixtures.signed().split('.');
    const signature=Buffer.from(pieces[2],'base64url');signature[signature.length-1]^=1;pieces[2]=signature.toString('base64url');
    await assert.rejects(verifier(Environment.SANDBOX,[...fixtures.rsaRootDERs,fixtures.rootDER]).verifyAndDecodeTransaction(pieces.join('.')),rejected());
    assert.equal(fixtures.calls,2);
  });
  await run('Sandbox keeps environment mismatch signal for Production-first selection',async()=>{
    await assert.rejects(verifier(Environment.PRODUCTION).verifyAndDecodeTransaction(fixtures.signed()),rejected(VerificationStatus.INVALID_ENVIRONMENT));
  });
  await run('wrong bundle rejected after full verification',async()=>{
    await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.signed({bundleId:'com.other.app'})),rejected(VerificationStatus.INVALID_APP_IDENTIFIER));
  });
  await run('tampered signed payload rejected',async()=>{
    const pieces=fixtures.signed().split('.');
    const payload=JSON.parse(Buffer.from(pieces[1],'base64url').toString());
    pieces[1]=Buffer.from(JSON.stringify({...payload,transactionId:'forged'})).toString('base64url');
    await assert.rejects(verifier().verifyAndDecodeTransaction(pieces.join('.')),rejected());
  });
  await run('untrusted root rejected',async()=>{
    await assert.rejects(verifier(Environment.SANDBOX,fixtures.foreignRootDER).verifyAndDecodeTransaction(fixtures.signed()),rejected());
    assert.equal(fixtures.calls,0);
  });
  await run('expired signing certificate rejected',async()=>{
    await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.signed({}, {expired:true})),rejected(VerificationStatus.INVALID_CERTIFICATE));
    assert.equal(fixtures.calls,0);
  });
  await run('missing Apple signing OID rejected',async()=>{
    await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.signed({}, {missingOID:true})),rejected());
    assert.equal(fixtures.calls,0);
  });
  await run('ES256 cannot accept a P-384 signing key',async()=>{
    // The leaf has a valid Apple-purpose certificate. Curve normalization must
    // preserve P-384 and prevent it being treated as an ES256 P-256 key.
    await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.wrongCurveSigned()),error=>{
      rejected()(error);
      assert.match((error as InstanceType<typeof VerificationException>).cause?.message||'',/requires curve "prime256v1"/);
      return true;
    });
  });
  for (const algorithm of ['none','HS256'] as const) {
    await run(`JWS algorithm ${algorithm} rejected`,async()=>{
      await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.invalidAlgorithmSigned(algorithm)),rejected());
    });
  }
  for (const mode of ['revoked','unknown','stale','invalid-time','wrong-signer','tampered'] as const) {
    await run(`OCSP ${mode} rejected`,async()=>{
      fixtures.setMode(mode);
      await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.signed()),rejected());
      assert.ok(fixtures.calls>=1);
    });
  }
  await run('OCSP outage remains retryable',async()=>{
    fixtures.setMode('unavailable');
    await assert.rejects(verifier().verifyAndDecodeTransaction(fixtures.signed()),rejected(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE));
  });
  await run('diagnostics classify runtime failure without exposing the payload',()=>{
    const cause=Object.assign(new Error('Not implemented: crypto.X509Certificate.prototype.toString secret-jws-value'),{code:'ERR_NOT_IMPLEMENTED'});
    const details=appleVerificationFailure(new VerificationException(VerificationStatus.VERIFICATION_FAILURE,cause));
    assert.deepEqual(details,{status:'VERIFICATION_FAILURE',reason:'SERVER_CRYPTO_UNAVAILABLE',runtimeFailure:true});
    assert.equal(JSON.stringify(details).includes('secret-jws-value'),false);
  });
  await run('App Store API client signs an ES256 authorization JWT',()=>{
    const client = new AppStoreServerAPIClient(fixtures.privateSigningKeyPEM,'FIXTUREKEY','fixture-issuer','com.spyclash.ios',Environment.SANDBOX);
    const token = (client as unknown as {createBearerToken():string}).createBearerToken();
    assert.equal(fixtures.verifyClientJWT(token),true);
    const payload=JSON.parse(Buffer.from(token.split('.')[1],'base64url').toString());
    assert.equal(payload.aud,'appstoreconnect-v1');assert.equal(payload.bid,'com.spyclash.ios');
  });
  return results;
}

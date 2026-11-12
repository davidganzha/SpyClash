import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {createRequire} from 'node:module';
import {createAppleVerifierFixtures} from './apple-verifier-fixtures.ts';
import {runAppleVerifierRegressionCases} from './apple-verifier-regression.ts';
import {ensureAppleX509Compatibility} from '../../supabase/functions/app-services/billing-rules/apple-x509-compatibility.ts';

Deno.test('Apple SDK validates signed transactions and OCSP with runtime compatibility',async()=>{
  let fixtures: ReturnType<typeof createAppleVerifierFixtures>;
  const server=Deno.serve({hostname:'127.0.0.1',port:0,onListen:()=>{}},request=>fixtures.respond(request));
  try {
    fixtures=createAppleVerifierFixtures(`http://127.0.0.1:${server.addr.port}`);
    const nodeCrypto=createRequire(import.meta.url)('crypto') as typeof import('node:crypto');
    const emulate=Deno.env.get('APPLE_EMULATE_EDGE_RUNTIME')==='1';
    if(emulate) {
      const NativeCertificate=nodeCrypto.X509Certificate;
      const missing=(method:string):never=>{throw Object.assign(new Error(`Not implemented: crypto.X509Certificate.prototype.${method}`),{code:'ERR_NOT_IMPLEMENTED'});};
      class UnsupportedCertificate extends NativeCertificate {
        override toString():string{return missing('toString');}
        override verify():boolean{return missing('verify');}
      }
      Object.defineProperties(UnsupportedCertificate.prototype,{
        raw:{get(){return missing('raw');},configurable:true},
        infoAccess:{get(){return missing('infoAccess');},configurable:true},
      });
      nodeCrypto.X509Certificate=UnsupportedCertificate;
      const publicFactory=nodeCrypto.createPublicKey,privateFactory=nodeCrypto.createPrivateKey;
      const alias=<T extends import('node:crypto').KeyObject>(key:T):T=>{
        const details=key.asymmetricKeyDetails;
        const curve=({'prime256v1':'p256','secp384r1':'p384','secp521r1':'p521'} as Record<string,string>)[details?.namedCurve||''];
        if(curve)Object.defineProperty(key,'asymmetricKeyDetails',{value:{...details,namedCurve:curve},configurable:true});
        return key;
      };
      nodeCrypto.createPublicKey=((...args:Parameters<typeof publicFactory>)=>alias(publicFactory(...args))) as typeof publicFactory;
      nodeCrypto.createPrivateKey=((...args:Parameters<typeof privateFactory>)=>alias(privateFactory(...args))) as typeof privateFactory;
      assert.throws(()=>new nodeCrypto.X509Certificate(fixtures.rootDER).toString(),/Not implemented/);
    }
    const previous=nodeCrypto.X509Certificate;
    ensureAppleX509Compatibility(fixtures.rootDER);
    const installed=nodeCrypto.X509Certificate;
    ensureAppleX509Compatibility(fixtures.rootDER);
    assert.equal(nodeCrypto.X509Certificate,installed);
    if(emulate)assert.notEqual(installed,previous);
    const pem=new installed(fixtures.rootDER).toString();
    for(const input of [fixtures.rootDER,pem,Buffer.from(pem),Uint8Array.from(fixtures.rootDER)]) {
      const certificate=new installed(input);
      assert.deepEqual(certificate.raw,fixtures.rootDER);
      assert.equal(certificate.toString(),pem);
    }
    const results=await runAppleVerifierRegressionCases(fixtures);
    console.log(JSON.stringify({emulatedEdgeRuntime:emulate,passed:results.length,cases:results}));
  } finally { await server.shutdown(); }
});

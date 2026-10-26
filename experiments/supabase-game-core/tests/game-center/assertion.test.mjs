import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {createFixtureCertificates} from './fixtures.mjs';
import {createAssertionVerifier,createCertificateLoader,validateCertificateChain,validateCertificateURL,parseAssertion,readJSON} from '../../supabase/functions/game-center-session/backend/assertion.mjs';
import {gameCenterConfiguration} from '../../supabase/functions/game-center-session/backend/configuration.mjs';
let fixture;
before(()=>{fixture=createFixtureCertificates();});
after(()=>fixture.cleanup());
const verifier=()=>createAssertionVerifier({loadCertificate:async()=>validateCertificateChain(fixture.leaf.raw,Date.now(),fixture.trust)});

test('valid RSA SHA256 payload uses signed team identity, bundle, UInt64 milliseconds, salt',async()=>{
  const body=fixture.assertion(); const result=await verifier()(body);
  assert.equal(result.payload.subarray(0,body.team_player_id.length).toString(),body.team_player_id);
  assert.equal(result.payload.readBigUInt64BE(body.team_player_id.length+body.bundle_id.length),BigInt(body.timestamp));
  assert.equal(result.displayName,'Local test player');
});
test('changed player, salt, timestamp and signature all fail cryptographic verification',async()=>{
  const body=fixture.assertion();
  for(const altered of [{...body,team_player_id:'T:_victim'},{...body,timestamp:body.timestamp+1},
    {...body,salt:Buffer.alloc(32).toString('base64')},{...body,signature:Buffer.alloc(256).toString('base64')}]) {
    await assert.rejects(verifier()(altered),{code:'invalid_game_center_assertion'});
  }
});
test('nickname cannot change identity or replay key; it is sanitized cosmetic data',async()=>{
  const body=fixture.assertion(); const a=await verifier()(body),b=await verifier()({...body,display_name:'Admin\u0000\u202e'});
  assert.equal(a.identityKey,b.identityKey);assert.equal(a.replayKey,b.replayKey);assert.equal(b.displayName,'Admin');
});
test('wrong bundle, stale/future/unsafe timestamps, noncanonical base64 and unknown fields rejected before network',async()=>{
  let calls=0;const verify=createAssertionVerifier({loadCertificate:async()=>{calls++;return fixture.leaf;}});
  const body=fixture.assertion();
  for(const altered of [{...body,bundle_id:'com.spyclash.ios.gamecenter000'},{...body,timestamp:Date.now()-301000},{...body,timestamp:Date.now()+31000},
    {...body,timestamp:Number.MAX_SAFE_INTEGER+1},{...body,timestamp:'1'},{...body,salt:''},{...body,signature:body.signature+'\n'},
    {...body,legacy_user_id:'victim'},{...body,team_player_id:''}]) await assert.rejects(verify(altered));
  assert.equal(calls,0);
});
test('URL allowlist rejects SSRF, deceptive Apple hosts, credentials, query and path normalization',()=>{
  for(const value of ['http://static.gc.apple.com/public-key/gc-prod-1.cer','https://static.gc.apple.com.evil.test/public-key/gc-prod-1.cer',
    'https://127.0.0.1/public-key/gc-prod-1.cer','https://evil@static.gc.apple.com/public-key/gc-prod-1.cer',
    'https://static.gc.apple.com:444/public-key/gc-prod-1.cer','https://static.gc.apple.com/public-key/../public-key/gc-prod-1.cer',
    'https://static.gc.apple.com/public-key/gc-prod-1.cer?q=1','https://static.gc.apple.com/public-key/gc-prod-1.cer#x',
    'https://static.gc.apple.com/public-key/gc-%70rod-1.cer']) assert.throws(()=>validateCertificateURL(value));
});
test('certificate trust and validity are required independently of valid RSA signature',async()=>{
  await assert.rejects(validateCertificateChain(fixture.leaf.raw));
  await assert.rejects(validateCertificateChain(fixture.leaf.raw,Date.now()+3*86400000,fixture.trust));
  await assert.rejects(validateCertificateChain(Buffer.from('not a cert'),Date.now(),fixture.trust));
});
test('certificate loader disables redirects and honors HTTP cache expiry',async()=>{
  let calls=0,time=Date.now();
  const loader=createCertificateLoader({now:()=>time,trust:fixture.trust,fetcher:async(url,options)=>{
    calls++;assert.equal(options.redirect,'error');return new Response(fixture.leaf.raw,{headers:{'cache-control':'max-age=10'}});
  }});
  const url='https://static.gc.apple.com/public-key/gc-prod-99.cer';
  await loader(url);await loader(url);assert.equal(calls,1);time+=11000;await loader(url);assert.equal(calls,2);
});
test('certificate redirect and oversized content fail closed',async()=>{
  const url='https://static.gc.apple.com/public-key/gc-prod-99.cer';
  await assert.rejects(createCertificateLoader({fetcher:async()=>new Response(null,{status:302,headers:{location:'https://evil.test'}})})(url));
  await assert.rejects(createCertificateLoader({fetcher:async()=>new Response(new Uint8Array(17000))})(url));
});
test('HTTP JSON limits streamed bodies without relying on Content-Length',async()=>{
  await assert.rejects(readJSON(new Request('http://localhost',{method:'POST',headers:{'content-type':'application/json'},body:'x'.repeat(8193)})),{status:413});
  await assert.rejects(readJSON(new Request('http://localhost',{method:'POST',body:'{}'})),{status:415});
});

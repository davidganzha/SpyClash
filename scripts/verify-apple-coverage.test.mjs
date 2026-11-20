import assert from 'node:assert/strict';
import test from 'node:test';
import {createCoverageVerifier} from './verify-apple-coverage.mjs';

const target={source_record_id:'source-1',source_revision:'revision-1',identity_key:'email-hmac-1',subject_key:'subject-hmac-1',legacy_user_id:'legacy-1',user_id:'preserved-uuid-1'};
function fixture(patch={}){
  const row={id:target.source_record_id,revision:target.source_revision,identity_key:target.identity_key,subject_key:target.subject_key,client_id:'com.spyclash.ios',credential_kind:'token',state:'pending',user_id:null,manual_revocation_required:false,refresh_token_ciphertext:'must-never-return',refresh_token_iv:'private-iv'};
  const user={id:target.legacy_user_id,email:'owned@example.test',is_verified:true};
  let reads=0,decrypts=0;
  const deps={authenticate:async()=>({role:'admin'}),targets:[target],expiresAt:'2026-11-22T00:00:00Z',now:()=>new Date('2026-11-20T00:00:00Z'),readCredential:async()=>{reads++;return row;},readUser:async()=>user,identityKey:async()=>target.identity_key,verifyEncryptedBinding:async()=>{decrypts++;return true;},...patch};
  return {row,user,deps,handler:createCoverageVerifier(deps),counts:()=>({reads,decrypts})};
}
const request=(body='{}')=>new Request('https://fixture.invalid/coverage',{method:'POST',body});
test('returns only complete fixed-cohort provenance and never grant material',async()=>{
  const f=fixture(),r=await f.handler(request()),body=await r.json();assert.equal(r.status,200);assert.equal(r.headers.get('Cache-Control'),'no-store');assert.equal(body.verified_count,1);assert.equal(body.records[0].user_id,target.user_id);assert.equal(body.records[0].encrypted_binding_verified,true);
  assert.ok(!JSON.stringify(body).includes('must-never-return'));assert.ok(!JSON.stringify(body).includes('private-iv'));assert.ok(!JSON.stringify(body).includes('owned@example.test'));assert.deepEqual(f.counts(),{reads:1,decrypts:1});
});
test('requires administrator before any record or grant is read',async()=>{const f=fixture({authenticate:async()=>({role:'user'})});assert.equal((await f.handler(request())).status,403);assert.deepEqual(f.counts(),{reads:0,decrypts:0});});
test('expired plan fails before reading historical credentials',async()=>{const f=fixture({expiresAt:'2026-11-19T00:00:00Z'});assert.equal((await f.handler(request())).status,410);assert.equal(f.counts().reads,0);});
test('caller cannot select, extend or replace the fixed cohort',async()=>{const f=fixture();assert.equal((await f.handler(request('{"targets":[]}'))).status,409);assert.equal(f.counts().reads,0);});
test('any revision, subject, owner, state or client drift rejects the cohort',async()=>{
  for(const change of [{revision:'changed'},{subject_key:'different'},{identity_key:'different'},{client_id:'web-client'},{user_id:'some-owner'},{state:'revoked'},{manual_revocation_required:true},{credential_kind:'other'}]){
    const f=fixture();Object.assign(f.row,change);const r=await f.handler(request());assert.equal(r.status,409);assert.equal((await r.json()).code,'source_credential_changed');assert.equal(f.counts().decrypts,0);
  }
});
test('wrong, disabled or unverified source user cannot establish a migration owner',async()=>{
  for(const change of [{id:'foreign-user'},{disabled:true},{is_verified:false},{is_service:true}]){const f=fixture();Object.assign(f.user,change);assert.equal((await f.handler(request())).status,409);assert.equal(f.counts().decrypts,0);}
  const f=fixture({identityKey:async()=> 'foreign-email-hmac'});assert.equal((await f.handler(request())).status,409);assert.equal(f.counts().decrypts,0);
});
test('authenticated decryption must succeed and dependency errors remain private',async()=>{
  const no=fixture({verifyEncryptedBinding:async()=>false});assert.equal((await (await no.handler(request())).json()).code,'grant_binding_unverified');
  const broken=fixture({verifyEncryptedBinding:async()=>{throw Error('private-key-or-token');}}),r=await broken.handler(request());assert.equal(r.status,409);assert.ok(!(await r.text()).includes('private-key-or-token'));
});
test('ambiguous target plans and partial verification never produce a receipt',async()=>{
  const f=fixture();assert.throws(()=>createCoverageVerifier({...f.deps,targets:[target,{...target}]}),/ambiguous/);
  const second=Object.fromEntries(Object.entries(target).map(([k,v])=>[k,v+'-2']));const h=createCoverageVerifier({...f.deps,targets:[target,second]});const r=await h(request());assert.equal(r.status,409);const body=await r.json();assert.equal(body.records,undefined);assert.equal(body.verified_count,undefined);
});

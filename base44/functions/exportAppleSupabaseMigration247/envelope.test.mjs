import test from 'node:test';
import assert from 'node:assert/strict';
import {createMigrationExportHandler,canonicalAdministratorRequest} from './envelope.mjs';

const pair = await crypto.subtle.generateKey({name:'RSA-OAEP',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['encrypt','decrypt']);
const recipientSPKI=Buffer.from(await crypto.subtle.exportKey('spki',pair.publicKey)).toString('base64');
const request=body=>new Request('https://spyclash.com/functions/exportAppleSupabaseMigration247',{method:'POST',body:JSON.stringify(body)});
const options={authenticate:async()=>({id:'owned-admin',role:'admin'}),readSecret:name=>'synthetic-'+name,recipientSPKI,expiresAt:2000,now:()=>1000};

test('hostile SDK routing and service-role headers cannot select an administrator source',async()=>{
  const hostile=new Request('https://attacker.invalid/export',{method:'POST',headers:{Authorization:'Bearer synthetic-owned', 'Base44-App-Id':'foreign','Base44-Api-Url':'https://attacker.invalid','Base44-Service-Role':'true','Base44-Service-Authorization':'Bearer synthetic-privileged',Cookie:'private=hidden'},body:JSON.stringify({action:'export'})});
  const canonical=canonicalAdministratorRequest(hostile);
  assert.equal(canonical.headers.get('Base44-App-Id'),'69a0e57fa939f578082f8091');
  assert.equal(canonical.headers.get('Base44-Api-Url'),'https://base44.app');
  assert.equal(canonical.headers.get('Authorization'),'Bearer synthetic-owned');
  assert.equal(canonical.headers.get('Base44-Service-Authorization'),null);
  assert.equal(canonical.headers.get('Base44-Service-Role'),null);assert.equal(canonical.headers.get('Cookie'),null);
  let checked=false;
  const response=await createMigrationExportHandler({...options,authenticate:async req=>{assert.equal(req.headers.get('Base44-Api-Url'),'https://base44.app');checked=true;return {id:'real-member',role:'user'};}})(hostile);
  assert.equal(response.status,403);assert.equal(checked,true);
});

test('only an authenticated app administrator can read source configuration',async()=>{
  let reads=0;
  for(const authenticate of [async()=>{throw Error('hidden');},async()=>({id:'member',role:'user'})]){
    const response=await createMigrationExportHandler({...options,authenticate,readSecret:()=>{reads++;return 'secret';}})(request({action:'export'}));
    assert.ok([401,403].includes(response.status));
    assert.doesNotMatch(await response.text(),/secret|hidden/);
  }
  assert.equal(reads,0);
});
test('expiry and caller-selected secrets or destination are rejected before reads',async()=>{
  let reads=0;const readSecret=()=>{reads++;return 'secret';};
  assert.equal((await createMigrationExportHandler({...options,readSecret,now:()=>2000})(request({action:'export'}))).status,410);
  for(const body of [{action:'export',recipient:'attacker'},{action:'export',names:['OTHER']},{action:'read'}]){
    assert.equal((await createMigrationExportHandler({...options,readSecret})(request(body))).status,400);
  }
  assert.equal(reads,0);
});
test('only the fixed recipient decrypts the exact allowlisted configuration',async()=>{
  const response=await createMigrationExportHandler(options)(request({action:'export'}));assert.equal(response.status,200);
  const raw=await response.text();assert.doesNotMatch(raw,/synthetic-|SPYCLASH_PSEUDONYM_KEY/);
  const envelope=JSON.parse(raw);const key=await crypto.subtle.decrypt({name:'RSA-OAEP'},pair.privateKey,Buffer.from(envelope.wrapped_key,'base64'));
  const aes=await crypto.subtle.importKey('raw',key,'AES-GCM',false,['decrypt']);
  const opened=await crypto.subtle.decrypt({name:'AES-GCM',iv:Buffer.from(envelope.iv,'base64'),additionalData:new TextEncoder().encode(envelope.context)},aes,Buffer.from(envelope.ciphertext,'base64'));
  const data=JSON.parse(new TextDecoder().decode(opened));assert.equal(data.app_id,'69a0e57fa939f578082f8091');
  assert.deepEqual(Object.keys(data.secrets),['SPYCLASH_PSEUDONYM_KEY','APPLE_KEY_ID','APPLE_TEAM_ID','APPLE_PRIVATE_KEY_P8_B64']);
  await assert.rejects(()=>crypto.subtle.decrypt({name:'AES-GCM',iv:Buffer.from(envelope.iv,'base64'),additionalData:new TextEncoder().encode('wrong-app')},aes,Buffer.from(envelope.ciphertext,'base64')));
});
test('missing source key returns no partial configuration',async()=>{
  const response=await createMigrationExportHandler({...options,readSecret:name=>name==='APPLE_KEY_ID'?undefined:'do-not-display'})(request({action:'export'}));
  assert.equal(response.status,503);assert.doesNotMatch(await response.text(),/do-not-display|APPLE_KEY_ID/);
});

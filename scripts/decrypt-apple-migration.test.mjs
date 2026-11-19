import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {mkdtempSync,readFileSync,rmSync,statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createMigrationExportHandler} from '../base44/functions/exportAppleSupabaseMigration247/envelope.mjs';
import {decryptMigrationEnvelope,savePrivateConfiguration} from './decrypt-apple-migration.mjs';

const rsa=generateKeyPairSync('rsa',{modulusLength:2048});
const apple=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const now=Date.now();
const secrets={SPYCLASH_PSEUDONYM_KEY:'synthetic-only-pseudonym',APPLE_KEY_ID:'SYNTHETIC1',APPLE_TEAM_ID:'3Z64QKNL54',APPLE_PRIVATE_KEY_P8_B64:Buffer.from(apple.privateKey.export({type:'pkcs8',format:'pem'})).toString('base64')};
async function envelope(overrides={}) {
  const handler=createMigrationExportHandler({authenticate:async()=>({id:'synthetic-admin',role:'admin'}),readSecret:name=>({...secrets,...overrides})[name],recipientSPKI:rsa.publicKey.export({type:'spki',format:'der'}).toString('base64'),expiresAt:now+1000,now:()=>now});
  const response=await handler(new Request('https://example.invalid/export',{method:'POST',body:JSON.stringify({action:'export'})}));
  assert.equal(response.status,200);
  return response.json();
}
test('decrypts fixed exporter and saves once with private permissions and stable grant key',async()=>{
  const result=decryptMigrationEnvelope(await envelope(),rsa.privateKey,now);
  assert.deepEqual(result,secrets);
  const directory=mkdtempSync(join(tmpdir(),'spyclash-apple-envelope-test-'));
  try {
    assert.equal(savePrivateConfiguration(result,directory).created,true);
    const path=join(directory,'supabase-apple-configuration.json');
    const saved=readFileSync(path,'utf8');
    assert.match(JSON.parse(saved).APPLE_GRANT_ENCRYPTION_KEY,/^[a-f0-9]{64}$/);
    assert.equal(statSync(path).mode&0o777,0o600);
    assert.equal(statSync(directory).mode&0o777,0o700);
    assert.equal(savePrivateConfiguration(result,directory).created,false);
    assert.equal(readFileSync(path,'utf8'),saved);
    assert.throws(()=>savePrivateConfiguration({...result,APPLE_KEY_ID:'DIFFERENT1'},directory));
    assert.equal(readFileSync(path,'utf8'),saved);
  } finally { rmSync(directory,{recursive:true,force:true}); }
});
test('wrong recipient, context, ciphertext and stale export fail closed',async()=>{
  const item=await envelope();
  const other=generateKeyPairSync('rsa',{modulusLength:2048});
  assert.throws(()=>decryptMigrationEnvelope(item,other.privateKey,now));
  assert.throws(()=>decryptMigrationEnvelope({...item,context:'foreign-app'},rsa.privateKey,now));
  const damaged=Buffer.from(item.ciphertext,'base64');damaged[0]^=1;
  assert.throws(()=>decryptMigrationEnvelope({...item,ciphertext:damaged.toString('base64')},rsa.privateKey,now));
  assert.throws(()=>decryptMigrationEnvelope(item,rsa.privateKey,now+86400001));
  assert.throws(()=>decryptMigrationEnvelope(item,rsa.privateKey,now-300001));
});
test('wrong Apple team or signing-key type is rejected before saving',async()=>{
  assert.throws(()=>decryptMigrationEnvelope({},rsa.privateKey,now));
  const foreign=await envelope({APPLE_TEAM_ID:'FOREIGN123'});
  assert.throws(()=>decryptMigrationEnvelope(foreign,rsa.privateKey,now));
  const wrongKey=await envelope({APPLE_PRIVATE_KEY_P8_B64:Buffer.from(rsa.privateKey.export({type:'pkcs8',format:'pem'})).toString('base64')});
  assert.throws(()=>decryptMigrationEnvelope(wrongKey,rsa.privateKey,now));
});

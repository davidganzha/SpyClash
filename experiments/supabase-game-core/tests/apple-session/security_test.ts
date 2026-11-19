import {strict as assert} from 'node:assert';
import {generateKeyPair, SignJWT, exportPKCS8, jwtVerify} from 'npm:jose@5.10.0';
import {AppleSessionError, type AppleConfig, clientID, issuer, parseRequest} from '../../supabase/functions/apple-session/contracts.ts';
import {createAppleAPI,createAppleVerifier,AppleExchangeError} from '../../supabase/functions/apple-session/apple.ts';
import {decryptGrant,digest,encryptGrant,grantBinding,subjectIdentity} from '../../supabase/functions/apple-session/crypto.ts';
import {createAppleHandler,exchangeApple} from '../../supabase/functions/apple-session/service.ts';
const rsa=await generateKeyPair('RS256');
const nonce='a'.repeat(64), subject='synthetic-apple-subject';
const now=Math.floor(Date.now()/1000);
const config:AppleConfig={origin:'http://127.0.0.1:56321',databaseURL:'postgresql://postgres:test@127.0.0.1:56322/postgres',local:true,
  anonKey:'test-anon',serviceRoleKey:'test-service',pseudonymKey:'synthetic-pseudonym-key-never-production',encryptionKey:'ab'.repeat(32),
  teamID:'SYNTHETIC1',keyID:'SYNTHETIC2',privateKeyPEM:'unused',newAccountsEnabled:false,migrationCoverageVerified:false};
const requestID='11111111-1111-4111-8111-111111111111';
const userID='22222222-2222-4222-8222-222222222222';
async function token(extra:Record<string,unknown>={}, key=rsa.privateKey) {
  return await new SignJWT({iss:issuer,aud:clientID,sub:subject,nonce:await digest(nonce),iat:now,exp:now+300,...extra}).setProtectedHeader({alg:'RS256',kid:'fixture'}).sign(key);
}
const validBody=async()=>({identity_token:await token(),authorization_code:'synthetic-authorization-code',raw_nonce:nonce,request_id:requestID});
Deno.test('Apple assertion verifies signature, exact audience/issuer, fresh iat and mandatory hashed nonce',async()=>{
  const verify=createAppleVerifier(config,rsa.publicKey,()=>new Date(now*1000));
  const body=await validBody();const valid=await verify.presented(body);
  assert.equal(valid.subject,subject);assert.equal(valid.nonceHash,await digest(nonce));
  for(const change of [{aud:'com.attacker.app'},{aud:[clientID,'another']},{iss:'https://attacker.invalid'},{exp:now-20},{iat:now-600},{nonce:'raw-nonce'},{sub:''}]) {
    await assert.rejects(verify.presented({...body,identity_token:await token(change)}),AppleSessionError);
  }
  const other=await generateKeyPair('RS256');
  await assert.rejects(verify.presented({...body,identity_token:await token({},other.privateKey)}),AppleSessionError);
  await assert.rejects(verify.redeemed(await token({sub:'another-owner'}),valid),{code:'apple_identity_mismatch'});
  await assert.rejects(verify.redeemed(await token({nonce:'b'.repeat(64)}),valid),{code:'apple_identity_mismatch'});
});
Deno.test('legacy HMAC namespace is exact; no email or client supplied owner participates',async()=>{
  const identity=await subjectIdentity(subject,config.pseudonymKey);
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(config.pseudonymKey),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const signature=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('spyclash-apple-refresh-token-v1:subject:'+subject));
  const expected=[...new Uint8Array(signature)].map(v=>v.toString(16).padStart(2,'0')).join('');
  assert.equal(identity.subjectKey,'apple-subject:'+expected);
  assert.deepEqual(await subjectIdentity(' \t'+subject+'\n',' \t'+config.pseudonymKey+'\n'),identity);
  await assert.rejects(subjectIdentity(' \t\n',config.pseudonymKey));
  const body=await validBody();
  for(const extra of [{email:'victim@example.test'},{user_id:userID},{apple_user_id:subject},{client_id:'other'}]) assert.throws(()=>parseRequest({...body,...extra}),AppleSessionError);
  assert.throws(()=>parseRequest({...body,raw_nonce:'short'}),AppleSessionError);
});
Deno.test('grant ciphertext authenticates exact grant/user/client binding and wrong keys fail',async()=>{
  const id=crypto.randomUUID();const binding=grantBinding(id,userID,clientID);
  const encoded=await encryptGrant('synthetic-refresh',binding,config.encryptionKey);
  const grant={...encoded,id,user_id:userID,client_id:clientID};
  assert.equal(await decryptGrant(grant,config.encryptionKey),'synthetic-refresh');
  assert.notEqual(encoded.ciphertext,'synthetic-refresh');
  await assert.rejects(decryptGrant({...grant,user_id:crypto.randomUUID()},config.encryptionKey));
  await assert.rejects(decryptGrant(grant,'cd'.repeat(32)));
  await assert.rejects(decryptGrant({...grant,client_id:'web.client'},config.encryptionKey));
});
Deno.test('Apple code exchange pins token endpoint, client and client-secret audience; tracks observed grant first',async()=>{
  const ec=await generateKeyPair('ES256',{extractable:true});const pem=await exportPKCS8(ec.privateKey);let tracked=false;
  const api=createAppleAPI({...config,privateKeyPEM:pem},async(input,init)=>{
    assert.equal(input,issuer+'/auth/token');assert.equal(init?.redirect,'error');
    const form=init!.body as URLSearchParams;assert.equal(form.get('client_id'),clientID);assert.equal(form.get('code'),'one-time-code');
    const verified=await jwtVerify(form.get('client_secret')!,ec.publicKey,{algorithms:['ES256'],issuer:config.teamID,audience:issuer});
    assert.equal(verified.payload.sub,clientID);assert.equal(form.has('redirect_uri'),false);
    return Response.json({refresh_token:'test-refresh',id_token:'invalid-token'});
  });
  const result=await api.exchange(await api.prepareExchange('one-time-code'),async value=>{assert.equal(value,'test-refresh');tracked=true;});
  assert.equal(tracked,true);assert.equal(result.identityToken,'invalid-token');
});
function harness() {
  const calls:string[]=[];let candidateRevocations=0,grantRevocations=0;let failure:unknown;let stopped=false;
  const account={identity_key:'c'.repeat(64),subject_key:'apple-subject:'+'d'.repeat(64),user_id:userID,shadow_email:'opaque@accounts.spyclash.invalid',legacy_user_id:'legacy-owner',state:'ready',migration_complete:true,lease_id:crypto.randomUUID()};
  const assertion={identityKey:account.identity_key,subjectKey:account.subject_key,subject,nonceHash:'a'.repeat(64),codeHash:'b'.repeat(64),requestID,displayName:'Operative'};
  const user={id:userID,email:account.shadow_email,role:'authenticated'};
  const claims={sub:userID,role:'authenticated',session_id:'33333333-3333-4333-8333-333333333333',exp:now+3600};
  const access='test.'+btoa(JSON.stringify(claims))+'.signature';
  const repository={reserve:async()=>{calls.push('reserve');return account;},renew:async()=>{if(stopped)throw new AppleSessionError('apple_account_unavailable',410);},
    beginExchange:async()=>{calls.push('exchanging');},trackGrant:async()=>{calls.push('tracked');},revoked:async()=>{calls.push('grant-revoked');},
    settleFailure:async(_a:unknown,value:unknown)=>{failure=value;},provisionProfile:async()=>{calls.push('profile');},complete:async()=>{calls.push('complete');},release:async()=>{calls.push('release');}};
  const apple={prepareExchange:async()=>new URLSearchParams(),exchange:async(_body:unknown,onGrant:(token:string)=>Promise<void>)=>{calls.push('apple-exchange');await onGrant('fixture-refresh');return {identityToken:'redeemed'};},revoke:async()=>{grantRevocations++;}};
  const verifier={presented:async()=>assertion,redeemed:async()=>{calls.push('verified-redeemed');}};
  const auth={request:async(path:string,_method?:string,body?:any):Promise<any>=>{
    calls.push(path);
    if(path.startsWith('/admin/users/'))return user;
    if(path==='/admin/generate_link'){assert.deepEqual(body,{type:'magiclink',email:account.shadow_email});return {id:userID,hashed_token:'synthetic-hash'};}
    if(path==='/verify')return {user,access_token:access,refresh_token:'supabase-refresh',token_type:'bearer',expires_in:3600};
    if(path==='/user')return user;
    if(path==='/logout?scope=local'){candidateRevocations++;return {};}
    throw new Error('unexpected Auth endpoint');
  }};
  return {dependencies:{config,repository,apple,verifier,auth},calls,account,user,get failure(){return failure;},get candidateRevocations(){return candidateRevocations;},get grantRevocations(){return grantRevocations;},stop:()=>{stopped=true;}};
}
Deno.test('existing UUID session uses only supported Auth API and immutable mapped email, retaining grant before mint',async()=>{
  const h=harness();const result=await exchangeApple(await validBody(),h.dependencies);
  assert.equal(result.user.id,userID);assert.equal(result.provider,'apple');assert.equal(result.migration_version,1);
  assert.ok(h.calls.indexOf('tracked')<h.calls.indexOf('/admin/generate_link'));
  assert.ok(h.calls.indexOf('/user')<h.calls.indexOf('complete'));
  assert.equal(h.calls.includes('/admin/users'),false);assert.equal(h.grantRevocations,0);
});
Deno.test('mismatched Auth UUID rejects candidate and revokes only unreturned session and new Apple grant',async()=>{
  const h=harness(), request=h.dependencies.auth.request;
  h.dependencies.auth.request=async(path,...args)=>{const response=await request(path,...args);return path==='/verify'?{...response,user:{id:crypto.randomUUID()}}:response;};
  await assert.rejects(exchangeApple(await validBody(),h.dependencies),{code:'apple_identity_mismatch'});
  assert.equal(h.candidateRevocations,1);assert.equal(h.grantRevocations,1);assert.equal(h.failure,false);assert.equal(h.calls.includes('complete'),false);
});
Deno.test('unknown Apple network result retains unresolved issuance; explicit invalid grant does not',async()=>{
  for(const outcome of ['uncertain','not_issued'] as const){const h=harness();h.dependencies.apple.exchange=async()=>{throw new AppleExchangeError(outcome);};
    await assert.rejects(exchangeApple(await validBody(),h.dependencies));assert.equal(h.failure,outcome==='uncertain');assert.equal(h.calls.includes('/admin/generate_link'),false);}
});
Deno.test('untracked refresh grant is compensated and failed compensation keeps durable uncertainty',async()=>{
  for(const revokeFails of [false,true]){const h=harness();h.dependencies.repository.trackGrant=async()=>{throw new Error('database unavailable');};
    if(revokeFails)h.dependencies.apple.revoke=async()=>{throw new Error('revocation unavailable');};
    await assert.rejects(exchangeApple(await validBody(),h.dependencies));assert.equal(h.failure,revokeFails);assert.equal(h.calls.includes('/admin/generate_link'),false);}
});
Deno.test('cancelled candidate and account deletion gate cannot return a session',async()=>{
  const h=harness(),controller=new AbortController();h.dependencies.repository.complete=async()=>{controller.abort();};
  await assert.rejects(exchangeApple(await validBody(),h.dependencies,controller.signal),{code:'apple_request_cancelled'});
  assert.equal(h.candidateRevocations,1);assert.equal(h.grantRevocations,1);
  const deleted=harness();deleted.stop();await assert.rejects(exchangeApple(await validBody(),deleted.dependencies),{code:'apple_account_unavailable'});
  assert.equal(deleted.calls.includes('/admin/generate_link'),false);
});
Deno.test('handler rejects identity injection and oversized bodies without auth calls or secret echo',async()=>{
  const h=harness(),handler=createAppleHandler(h.dependencies);
  const response=await handler(new Request('https://test.invalid',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...await validBody(),user_id:userID})}));
  assert.equal(response.status,400);assert.equal(h.calls.length,0);assert.equal(response.headers.get('cache-control'),'no-store');
  assert.equal((await response.text()).includes(userID),false);
  const oversized=await handler(new Request('https://test.invalid',{method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(33_000)}));
  assert.equal(oversized.status,413);assert.equal(h.calls.length,0);
});

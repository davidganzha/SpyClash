import {strict as assert} from 'node:assert';
import postgres from 'npm:postgres@3.4.9';
import {generateKeyPair, SignJWT} from 'npm:jose@5.10.0';
import type {AppleConfig} from '../../supabase/functions/apple-session/contracts.ts';

// This suite creates disposable users only in the dedicated loopback stack.
// The optional source directory lets release checks exercise downloaded code.
const env=Deno.env.toObject(),database=new URL(env.SUPABASE_DB_URL||'');
if(env.SUPABASE_URL!=='http://127.0.0.1:56321'||database.hostname!=='127.0.0.1'||database.port!=='56322'||database.pathname!=='/postgres'||!['postgres:','postgresql:'].includes(database.protocol)||!env.SUPABASE_ANON_KEY||!env.SUPABASE_SERVICE_ROLE_KEY)throw Error('Dedicated loopback Auth/DB required; cloud targets are forbidden.');
const source=env.APPLE_LOCAL_TEST_SOURCE_ROOT?new URL(env.APPLE_LOCAL_TEST_SOURCE_ROOT):new URL('../../supabase/functions/',import.meta.url);
if(source.protocol!=='file:')throw Error('Only local source files may be tested.');
const {clientID,issuer}=await import(new URL('apple-session/contracts.ts',source).href);
const {createAppleVerifier,AppleExchangeError}=await import(new URL('apple-session/apple.ts',source).href);
const {digest,subjectIdentity}=await import(new URL('apple-session/crypto.ts',source).href);
const {createAppleRepository}=await import(new URL('apple-session/repository.ts',source).href);
const {createAuthAPI,exchangeApple}=await import(new URL('apple-session/service.ts',source).href);
const {ensureProfile}=await import(new URL('app-services/profile.ts',source).href);
const config:AppleConfig={origin:env.SUPABASE_URL,databaseURL:database.href,local:true,anonKey:env.SUPABASE_ANON_KEY,serviceRoleKey:env.SUPABASE_SERVICE_ROLE_KEY,pseudonymKey:'local-new-apple-fixture-never-production',encryptionKey:'bc'.repeat(32),teamID:'FIXTURE001',keyID:'FIXTURE002',privateKeyPEM:'unused',newAccountsEnabled:false,migrationCoverageVerified:false};
const db=postgres(config.databaseURL,{prepare:false,max:5,onnotice:()=>{}}),auth=createAuthAPI(config);
const rsa=await generateKeyPair('RS256'),tokens=new Map<string,string>(),identities=new Map<string,any>();
let exchangeCalls=0,denyExchangeOnce=false,failProfileOnce=false,passed=0;
const repository=createAppleRepository(db,config,async(ctx:any)=>{if(failProfileOnce){failProfileOnce=false;throw Error('synthetic profile outage');}return await ensureProfile(ctx);});
const apple={prepareExchange:async(code:string)=>new URLSearchParams({code}),exchange:async(form:URLSearchParams,onGrant:(token:string)=>Promise<void>)=>{
  exchangeCalls++;if(denyExchangeOnce){denyExchangeOnce=false;throw new AppleExchangeError('not_issued');}
  await onGrant('synthetic-grant-'+crypto.randomUUID());return {identityToken:tokens.get(form.get('code')!)!};
},revoke:async()=>{}};
const dependencies={config,repository,auth,apple,verifier:createAppleVerifier(config,rsa.publicKey)};
async function body(subject:string,rawNonce=crypto.randomUUID()+crypto.randomUUID()){
  identities.set(subject,await subjectIdentity(subject,config.pseudonymKey));
  const now=Math.floor(Date.now()/1000),code='synthetic-code-'+crypto.randomUUID();
  const token=await new SignJWT({iss:issuer,aud:clientID,sub:subject,nonce:await digest(rawNonce),iat:now,exp:now+300}).setProtectedHeader({alg:'RS256'}).sign(rsa.privateKey);
  tokens.set(code,token);return {identity_token:token,authorization_code:code,raw_nonce:rawNonce,request_id:crypto.randomUUID(),given_name:'First',family_name:'Operative'};
}
async function account(subject:string){const key=identities.get(subject).identityKey;return (await db`select * from apple_private.accounts where identity_key=${key}`)[0];}
async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log('PASS '+name);}
const subject='new-apple-'+crypto.randomUUID();let first:any,owner='';
try{
  await check('both approval flags are required; disabled combinations create no account or Apple exchange',async()=>{
    const [before]=await db`select count(*)::int n from auth.users`;
    for(const [enabled,coverage]of [[false,false],[true,false],[false,true]]){
      config.newAccountsEnabled=enabled;config.migrationCoverageVerified=coverage;
      await assert.rejects(exchangeApple(await body(subject),dependencies),{code:'apple_migration_pending'});
      assert.equal(await account(subject),undefined);
    }
    const [after]=await db`select count(*)::int n from auth.users`;assert.equal(after.n,before.n);assert.equal(exchangeCalls,0);
    config.newAccountsEnabled=true;config.migrationCoverageVerified=true;
  });
  await check('first registration creates one real Auth user, ready Apple registry and onboarding profile',async()=>{
    first=await exchangeApple(await body(subject),dependencies);owner=first.user.id;
    assert.equal((await auth.request('/user','GET',undefined,first.access_token)).id,owner);
    const a=await account(subject);assert.equal(a.user_id,owner);assert.equal(a.state,'ready');assert.equal(a.legacy_user_id,null);assert.equal(a.migration_complete,true);assert.equal(a.migration_version,1);
    const user=await auth.request('/admin/users/'+owner);assert.equal(user.app_metadata.apple_identity_key,a.identity_key);assert.equal(user.email,a.shadow_email);
    const [p]=await db`select * from app_private.profiles where user_id=${owner}`;assert.equal(p.state,'active');assert.ok(p.spy_id);assert.equal(p.data.display_name,'First Operative');assert.equal(p.data.onboarding_completed,false);
    const [native]=await db`select provider,state from app_private.native_accounts where user_id=${owner}`;assert.deepEqual({...native},{provider:'apple',state:'ready'});
    const [count]=await db`select count(*)::int n from auth.users where id=${owner} or email=${a.shadow_email}`;assert.equal(count.n,1);
  });
  await check('fresh authorization preserves the same UUID and completed onboarding',async()=>{
    await db`update app_private.profiles set data=data||${db.json({display_name:'Saved operative',onboarding_completed:true})}::jsonb where user_id=${owner}`;
    const again=await exchangeApple(await body(subject),dependencies);assert.equal(again.user.id,owner);
    const [p]=await db`select data from app_private.profiles where user_id=${owner}`;assert.equal(p.data.display_name,'Saved operative');assert.equal(p.data.onboarding_completed,true);
  });
  await check('refresh restores the same account without another Apple exchange',async()=>{
    const calls=exchangeCalls;const r=await auth.request('/token?grant_type=refresh_token','POST',{refresh_token:first.refresh_token});assert.equal(r.user.id,owner);assert.equal(exchangeCalls,calls);
  });
  await check('parallel first authorizations cannot create duplicate identities or users',async()=>{
    const s='parallel-apple-'+crypto.randomUUID(),a=await body(s),b=await body(s);
    const results=await Promise.allSettled([exchangeApple(a,dependencies),exchangeApple(b,dependencies)]);
    assert.ok(results.some(r=>r.status==='fulfilled'));const row=await account(s);
    for(const r of results)if(r.status==='fulfilled')assert.equal(r.value.user.id,row.user_id);else assert.equal(r.reason.code,'apple_session_busy');
    const [count]=await db`select count(*)::int n from auth.users where id=${row.user_id} or email=${row.shadow_email}`;assert.equal(count.n,1);
  });
  await check('replayed nonce on a different new subject rolls back its reservation before Auth creation',async()=>{
    const original=await body(subject);await exchangeApple(original,dependencies);
    const s='replay-apple-'+crypto.randomUUID();await assert.rejects(exchangeApple(await body(s,original.raw_nonce),dependencies),{code:'apple_assertion_replayed'});assert.equal(await account(s),undefined);
  });
  await check('explicit Apple rejection retains one pending UUID and a fresh proof can finish registration',async()=>{
    const s='retry-apple-'+crypto.randomUUID();denyExchangeOnce=true;
    await assert.rejects(exchangeApple(await body(s),dependencies),{code:'apple_code_exchange_failed'});const pending=await account(s);assert.equal(pending.state,'pending');assert.equal(await auth.request('/admin/users/'+pending.user_id),undefined);
    const recovered=await exchangeApple(await body(s),dependencies);assert.equal(recovered.user.id,pending.user_id);assert.equal((await account(s)).state,'ready');
  });
  await check('profile provisioning outage reuses the already created Auth UUID on the next fresh authorization',async()=>{
    const s='profile-retry-apple-'+crypto.randomUUID();failProfileOnce=true;
    await assert.rejects(exchangeApple(await body(s),dependencies));const pending=await account(s);assert.ok(await auth.request('/admin/users/'+pending.user_id));
    const recovered=await exchangeApple(await body(s),dependencies);assert.equal(recovered.user.id,pending.user_id);assert.equal((await account(s)).state,'ready');
  });
  console.log(JSON.stringify({passed,localOnly:true,productionOperations:0,source:source.href}));
}finally{
  for(const identity of identities.values()){
    const [a]=await db`select user_id from apple_private.accounts where identity_key=${identity.identityKey}`;if(!a)continue;
    await auth.request('/admin/users/'+a.user_id,'DELETE').catch(()=>{});
    await db.begin(async(tx:any)=>{await tx`delete from apple_private.grants where user_id=${a.user_id}`;await tx`delete from apple_private.attempts where identity_key=${identity.identityKey}`;await tx`delete from apple_private.accounts where user_id=${a.user_id}`;await tx`delete from app_private.profiles where user_id=${a.user_id}`;});
  }
  await db.end();
}

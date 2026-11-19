import {strict as assert} from 'node:assert';
import postgres from 'npm:postgres@3.4.9';
import {generateKeyPair,SignJWT} from 'npm:jose@5.10.0';
import {AppleExchangeError,createAppleVerifier} from '../../supabase/functions/apple-session/apple.ts';
import {type AppleConfig,clientID,issuer} from '../../supabase/functions/apple-session/contracts.ts';
import {digest,subjectIdentity,encryptGrant,grantBinding} from '../../supabase/functions/apple-session/crypto.ts';
import {assertAppleRevocationComplete} from '../../supabase/functions/app-services/native-apple-deletion.ts';
import {createAppleRepository} from '../../supabase/functions/apple-session/repository.ts';
import {createAuthAPI,exchangeApple} from '../../supabase/functions/apple-session/service.ts';
const env=Deno.env.toObject();
const database=new URL(env.SUPABASE_DB_URL||'');
if(env.SUPABASE_URL!=='http://127.0.0.1:56321' || !['postgres:','postgresql:'].includes(database.protocol) || database.hostname!=='127.0.0.1' || database.port!=='56322' || database.pathname!=='/postgres' || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('Apple integration tests require the dedicated existing loopback stack; cloud is forbidden.');
const config:AppleConfig={origin:env.SUPABASE_URL,databaseURL:database.href,local:true,anonKey:env.SUPABASE_ANON_KEY,serviceRoleKey:env.SUPABASE_SERVICE_ROLE_KEY,
  pseudonymKey:'integration-fixture-never-production-key',encryptionKey:'ab'.repeat(32),teamID:'FIXTURE001',keyID:'FIXTURE002',privateKeyPEM:'unused',newAccountsEnabled:false,migrationCoverageVerified:false};
const db=postgres(config.databaseURL,{prepare:false,max:3,onnotice:()=>{}});
const auth=createAuthAPI(config);const rsa=await generateKeyPair('RS256');
const userID=crypto.randomUUID(),subject='apple-integration-'+crypto.randomUUID(),email=crypto.randomUUID().replaceAll('-','')+'@accounts.spyclash.invalid';
const identity=await subjectIdentity(subject,config.pseudonymKey),tokens=new Map<string,string>();
const repository=createAppleRepository(db,config,async()=>{throw new Error('An imported profile must never be reprovisioned.');});
const apple={prepareExchange:async(code:string)=>new URLSearchParams({code}),exchange:async(form:URLSearchParams,onGrant:(token:string)=>Promise<void>)=>{
  await onGrant('synthetic-grant-'+crypto.randomUUID());return {identityToken:tokens.get(form.get('code')!)!};
},revoke:async()=>{}};
const dependencies={config,repository,auth,apple,verifier:createAppleVerifier(config,rsa.publicKey)};
async function body(owner=subject) {
  const rawNonce=crypto.randomUUID()+crypto.randomUUID(),code='synthetic-code-'+crypto.randomUUID(),now=Math.floor(Date.now()/1000);
  const token=await new SignJWT({iss:issuer,aud:clientID,sub:owner,nonce:await digest(rawNonce),iat:now,exp:now+300}).setProtectedHeader({alg:'RS256'}).sign(rsa.privateKey);
  tokens.set(code,token);return {identity_token:token,authorization_code:code,raw_nonce:rawNonce,request_id:crypto.randomUUID()};
}
let passed=0;
async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log('PASS '+name);}
try {
  await auth.request('/admin/users','POST',{id:userID,email,email_confirm:true,app_metadata:{legacy_provider:'base44',integration_fixture:true}});
  await db`insert into app_private.profiles(user_id,data) values(${userID},${db.json({display_name:'Imported operative',onboarding_completed:true,onboarding_version:2})})`;
  await db`insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,legacy_user_id,state,migration_version,migration_complete)
    values(${identity.identityKey},${identity.subjectKey},${clientID},${userID},${email},${'apple-integration-'+crypto.randomUUID()},'ready',1,true)`;
  let first:any;const proof=await body();
  await check('real Auth session retains imported UUID, profile and one existing Auth user',async()=>{
    first=await exchangeApple(proof,dependencies);assert.equal(first.user.id,userID);assert.equal(first.migration_version,1);
    assert.equal((await auth.request('/user','GET',undefined,first.access_token)).id,userID);
    const [profile]=await db`select data from app_private.profiles where user_id=${userID}`;assert.equal(profile.data.display_name,'Imported operative');assert.equal(profile.data.onboarding_completed,true);
    const [count]=await db`select count(*)::int as n from auth.users where id=${userID} or email=${email}`;assert.equal(count.n,1);
    const [registry]=await db`select provider,state,migration_complete from app_private.native_accounts where user_id=${userID}`;assert.deepEqual({...registry},{provider:'apple',state:'ready',migration_complete:true});
  });
  await check('real refresh and fresh Apple proof restore the same UUID',async()=>{
    const refreshed=await auth.request('/token?grant_type=refresh_token','POST',{refresh_token:first.refresh_token});assert.equal(refreshed.user.id,userID);
    assert.equal((await exchangeApple(await body(),dependencies)).user.id,userID);
  });
  await check('database replay keys reject reused request, nonce and code',async()=>{
    await assert.rejects(exchangeApple(proof,dependencies),{code:'apple_assertion_replayed'});
    await assert.rejects(exchangeApple({...proof,request_id:crypto.randomUUID()},dependencies),{code:'apple_assertion_replayed'});
    const fresh=await body();await assert.rejects(exchangeApple({...fresh,authorization_code:proof.authorization_code},dependencies),{code:'apple_assertion_replayed'});
  });
  await check('unmapped subject fails closed without creating Auth user',async()=>{
    const [before]=await db`select count(*)::int as n from auth.users`;
    await assert.rejects(exchangeApple(await body('unknown-'+crypto.randomUUID()),dependencies),{code:'apple_migration_pending'});
    const [after]=await db`select count(*)::int as n from auth.users`;assert.equal(after.n,before.n);
  });
  await check('parallel sign-ins serialize lease without duplicating imported account',async()=>{
    const a=await body(),b=await body();const results=await Promise.allSettled([exchangeApple(a,dependencies),exchangeApple(b,dependencies)]);
    assert.ok(results.some(value=>value.status==='fulfilled'));
    for(const value of results)if(value.status==='fulfilled')assert.equal(value.value.user.id,userID);else assert.ok(['apple_session_busy','apple_issuance_unresolved'].includes(value.reason.code));
    const [count]=await db`select count(*)::int as n from apple_private.accounts where user_id=${userID}`;assert.equal(count.n,1);
  });
  await check('deletion at completion revokes the unreturned real Auth candidate',async()=>{
    const [before]=await db`select count(*)::int as n from auth.sessions where user_id=${userID}`;
    const racing={...repository,complete:async(account:any,sessionID:string)=>{
      await db`update app_private.profiles set state='deleted' where user_id=${userID}`;return await repository.complete(account,sessionID);
    }};
    try {await assert.rejects(exchangeApple(await body(),{...dependencies,repository:racing}),{code:'apple_account_unavailable'});
      const [after]=await db`select count(*)::int as n from auth.sessions where user_id=${userID}`;assert.equal(after.n,before.n);
    } finally {await db`update app_private.profiles set state='active' where user_id=${userID}`;}
  });
  await check('unknown exchange retains deletion obligation while a fresh verified login recovers the same UUID',async()=>{
    const uncertain={...apple,exchange:async()=>{throw new AppleExchangeError('uncertain');}};
    await assert.rejects(exchangeApple(await body(),{...dependencies,apple:uncertain}));
    const rows=await db`select request_id from apple_private.attempts where identity_key=${identity.identityKey} and state='uncertain'`;assert.equal(rows.length,1);
    assert.equal((await exchangeApple(await body(),dependencies)).user.id,userID);
    const stillUnresolved=await db`select request_id from apple_private.attempts where identity_key=${identity.identityKey} and state='uncertain'`;assert.equal(stillUnresolved.length,1);
    // Settle all synthetic known grants so only the unknown issuance, rather
    // than an ordinary active token, is responsible for the deletion refusal.
    for(const grant of await db`select id from apple_private.grants where user_id=${userID}`)await repository.revoked(grant.id);
    await assert.rejects(db.begin(tx=>assertAppleRevocationComplete(tx,userID)),{code:'apple_account_deletion_pending'});
  });
  await check('live lease blocks overlap, stale issuer cannot publish but its late grant remains durable',async()=>{
    const oldProof=await body(),assertion=await dependencies.verifier.presented(oldProof),old=await repository.reserve(assertion);
    await repository.beginExchange(old);
    await assert.rejects(exchangeApple(await body(),dependencies),{code:'apple_session_busy'});
    await db`update apple_private.accounts set lease_until=clock_timestamp()-interval '1 second' where user_id=${userID} and lease_id=${old.lease_id}`;
    const fresh=await exchangeApple(await body(),dependencies);assert.equal(fresh.user.id,userID);
    await assert.rejects(repository.renew(old),{code:'apple_session_busy'});
    const sessionID=JSON.parse(atob(fresh.access_token.split('.')[1].replaceAll('-','+').replaceAll('_','/'))).session_id;
    await assert.rejects(repository.complete(old,sessionID),{code:'apple_session_busy'});
    const id=crypto.randomUUID(),grant={id,...await encryptGrant('late-synthetic-grant',grantBinding(id,userID,clientID),config.encryptionKey)};
    await repository.trackGrant(old,grant);
    const [saved]=await db`select state from apple_private.attempts where request_id=${old.request_id}`;assert.equal(saved.state,'grant_stored');
    assert.equal((await db`select id from apple_private.grants where id=${id}`).length,1);
    await assert.rejects(repository.complete(old,sessionID),{code:'apple_session_busy'});
  });
  console.log(JSON.stringify({passed,localOnly:true,productionOperations:0}));
} finally {
  // Only the randomly named records created by this run are removed.
  await auth.request('/admin/users/'+userID,'DELETE').catch(()=>{});
  await db.begin(async(tx:any)=>{
    await tx`delete from apple_private.grants where user_id=${userID}`;
    await tx`delete from apple_private.attempts where identity_key=${identity.identityKey}`;
    await tx`delete from apple_private.accounts where user_id=${userID}`;
    await tx`delete from app_private.profiles where user_id=${userID}`;
  }).catch(()=>{});
  await db.end();
}

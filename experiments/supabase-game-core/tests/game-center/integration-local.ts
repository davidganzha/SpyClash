import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createGameCenterRuntime} from '../../supabase/functions/game-center-session/backend/runtime.mjs';
import {createAssertionVerifier,validateCertificateChain} from '../../supabase/functions/game-center-session/backend/assertion.mjs';
import {exchangeGameCenter,createGameCenterHandler} from '../../supabase/functions/game-center-session/backend/service.mjs';
import {ensureProfile} from '../../supabase/functions/app-services/profile.ts';
import {createAppHandler} from '../../supabase/functions/app-services/handler.ts';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {prepareMainAccountDeletion} from '../../supabase/functions/app-services/main-account-deletion.ts';
import {AppServiceError} from '../../supabase/functions/app-services/contracts.ts';
import {createActorAuthenticator} from '../../supabase/functions/game-center-session/backend/service.mjs';
import {createFixtureCertificates} from './fixtures.mjs';
import {runNativeGenerationChecks} from './native-generation-integration.ts';
import {runNativeHistoryChecks} from './native-history-integration.ts';
const runtime=createGameCenterRuntime(Deno.env.toObject(),ensureProfile);
if(!runtime.config.local)throw new Error('Integration tests refuse cloud projects.');
const fixture=createFixtureCertificates();
const verify=createAssertionVerifier({loadCertificate:async()=>validateCertificateChain(fixture.leaf.raw,Date.now(),fixture.trust)});
const dependencies={verify,repository:runtime.repository,auth:runtime.auth};
const sessions:any[]=[];const identities=new Set<string>();
let passed=0;
async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log(`PASS ${name}`);}
async function exchange(body:any){identities.add((await verify(body)).identityKey);const result=await exchangeGameCenter(body,dependencies);sessions.push(result);return result;}
const app=createAppHandler({db:runtime.db,
  authenticate:createActorAuthenticator(runtime.auth,()=>new AppServiceError('unauthorized','Sign in again.',401)),
  config:{SUPABASE_URL:runtime.config.origin,SUPABASE_SERVICE_ROLE_KEY:runtime.config.serviceRoleKey}});
const request=async(session:any,body:any)=>{
  const response=await app(new Request('http://127.0.0.1/functions/v1/app-services',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+session.access_token},body:JSON.stringify(body)}));
  const json=await response.json();assert.equal(response.status,200,JSON.stringify(json));return json;
};
try{
  let first:any;let firstBody:any;
  await check('valid synthetic assertion provisions genuine Auth session and unfinished profile',async()=>{
    firstBody=fixture.assertion();first=await exchange(firstBody);
    assert.equal(first.provider,'game_center');
    const user=await runtime.auth.request('/user','GET',undefined,first.access_token);assert.equal(user.id,first.user.id);
    const profile=await request(first,{service:'profile',action:'current'});
    assert.equal(profile.id,first.user.id);assert.equal(profile.onboarding_completed,false);assert.equal(profile.onboarding_version,0);
  });
  await check('same signed assertion is rejected as replay',async()=>{
    await assert.rejects(exchangeGameCenter(firstBody,dependencies),{code:'game_center_assertion_replayed'});
  });
  await check('fresh proof of same Game Center identity restores same account',async()=>{
    const restored=await exchange(fixture.assertion({team_player_id:firstBody.team_player_id,display_name:'Changed cosmetic nickname'}));
    assert.equal(restored.user.id,first.user.id);
  });
  await check('different signed identity with same nickname gets a separate account',async()=>{
    const second=await exchange(fixture.assertion({display_name:firstBody.display_name}));assert.notEqual(second.user.id,first.user.id);
  });
  await check('parallel first sign-ins serialize identity creation; no duplicate user',async()=>{
    const team='T:_race_'+randomUUID().replaceAll('-','');
    const a=fixture.assertion({team_player_id:team}),b=fixture.assertion({team_player_id:team});
    identities.add((await verify(a)).identityKey);
    const values=await Promise.allSettled([exchange(a),exchange(b)]);
    assert.ok(values.some(value=>value.status==='fulfilled'));
    for(const value of values)if(value.status==='rejected')assert.equal(value.reason.code,'game_center_busy');
    const [{count}]=await runtime.db`select count(*)::int as count from game_center_private.accounts where identity_key=${(await verify(a)).identityKey}`;
    assert.equal(count,1);
    const again=await exchange(fixture.assertion({team_player_id:team}));
    for(const value of values)if(value.status==='fulfilled')assert.equal(value.value.user.id,again.user.id);
  });
  await check('lost Auth create acknowledgement recovers the reserved UUID without creating a second account',async()=>{
    const body=fixture.assertion();identities.add((await verify(body)).identityKey);let lost=false;
    const auth={request:async(...args:any[])=>{const value=await runtime.auth.request(...args);if(!lost&&args[0]==='/admin/users'&&args[1]==='POST'){lost=true;throw new Error('lost acknowledgement');}return value;}};
    const session=await exchangeGameCenter(body,{...dependencies,auth});sessions.push(session);assert.equal(lost,true);
    const [account]=await runtime.db`select user_id from game_center_private.accounts where identity_key=${(await verify(body)).identityKey}`;
    assert.equal(account.user_id,session.user.id);
  });
  await check('reserved Auth UUID with different server metadata is rejected rather than adopted',async()=>{
    const body=fixture.assertion(),assertion=await verify(body);identities.add(assertion.identityKey);
    const reserved=await runtime.repository.reserve(assertion);
    await runtime.auth.request('/admin/users','POST',{id:reserved.user_id,email:reserved.shadow_email,email_confirm:true,app_metadata:{game_center_identity_key:'different-owner',game_center_environment:'main'}});
    await runtime.repository.release(reserved);
    await assert.rejects(exchangeGameCenter(fixture.assertion({team_player_id:body.team_player_id}),dependencies),{code:'game_center_identity_mismatch'});
    const user=await runtime.auth.request('/admin/users/'+reserved.user_id);assert.equal(user.app_metadata.game_center_identity_key,'different-owner');
  });
  await check('deletion during Auth OTP verification revokes the unreturned candidate session',async()=>{
    const body=fixture.assertion();identities.add((await verify(body)).identityKey);let revokedID:string|undefined;
    const repository={...runtime.repository,complete:async(account:any,sessionID:any)=>{
      revokedID=account.user_id;await runtime.db`update app_private.profiles set state='deleted' where user_id=${account.user_id}`;
      return await runtime.repository.complete(account,sessionID);
    }};
    await assert.rejects(exchangeGameCenter(body,{...dependencies,repository}),{code:'game_center_account_unavailable'});
    const [{count}]=await runtime.db`select count(*)::int as count from auth.sessions where user_id=${revokedID!}`;assert.equal(count,0);
  });
  await check('standard Supabase refresh returns same user without Base44 credentials',async()=>{
    const refreshed=await runtime.auth.request('/token?grant_type=refresh_token','POST',{refresh_token:first.refresh_token});
    sessions.push(refreshed);assert.equal(refreshed.user.id,first.user.id);first=refreshed;
  });
  await check('onboarding save and authenticated readback persist on real profile',async()=>{
    const profile=await request(first,{service:'profile',action:'onboarding',onboarding_version:2,display_name:'Game Center Tester',language:'en',acquisition_source:'other',request_id:randomUUID()});
    assert.equal(profile.onboarding_completed,true);
    const readback=await request(first,{service:'profile',action:'current'});assert.equal(readback.onboarding_completed,true);
  });
  await check('repeat Game Center login keeps completed onboarding and original profile',async()=>{
    const restored=await exchange(fixture.assertion({team_player_id:firstBody.team_player_id,display_name:'Do not overwrite me'}));
    const profile=await request(restored,{service:'profile',action:'current'});
    assert.equal(profile.onboarding_completed,true);assert.equal(profile.onboarding_version,2);
    assert.equal(profile.full_name,'Local test player');
  });
  await check('native deletion requires nonserializable server proof and explicit full scope',async()=>{
    const actor={id:first.user.id,email:first.user.id+'@example.test',contactEmail:'',full_name:'',metadata:{game_center:true}};
    const command={service:'profile',action:'delete',deletion_scope:'account',request_id:randomUUID()};
    const result=await executeApp(runtime.db,actor,command,{}, {actor:actor.id,requestID:command.request_id});
    assert.equal(result.status,409);assert.equal(result.body.code,'native_account_deletion_proof_required');
    const scoped=await executeApp(runtime.db,actor,{service:'profile',action:'delete',request_id:randomUUID()});
    assert.equal(scoped.status,409);
    const [{state}]=await runtime.db`select state from app_private.profiles where user_id=${actor.id}`;assert.equal(state,'active');
  });
  await check('native deletion cannot bypass an existing legacy ownership or deletion intent',async()=>{
    const body=fixture.assertion(),session=await exchange(body);
    const actor={id:session.user.id,email:session.user.id+'@example.test',contactEmail:'',full_name:'',metadata:{}};
    const command={service:'profile',action:'delete',deletion_scope:'account',request_id:randomUUID()};
    const evidence=await prepareMainAccountDeletion({actor,body:command,config:{}},{db:runtime.db,fetch:()=>{throw new Error('Native deletion must not contact Base44');}});
    await runtime.db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${actor.id},${'gc-test-'+randomUUID()},'https://example.test',clock_timestamp())`;
    const conflict=await executeApp(runtime.db,actor,command,{},evidence);
    assert.equal(conflict.status,409);assert.equal(conflict.body.code,'game_center_identity_conflict');
    await assert.rejects(prepareMainAccountDeletion({actor,body:command,config:{}},{db:runtime.db}),{code:'game_center_identity_conflict'});
    await runtime.db`delete from app_private.legacy_links where user_id=${actor.id}`;
    await runtime.db`insert into app_private.main_account_deletions(user_id,request_id,legacy_user_id,source_origin,source_app_id)
      values(${actor.id},${randomUUID()},'legacy-owned','https://example.test','test-app')`;
    await assert.rejects(prepareMainAccountDeletion({actor,body:command,config:{}},{db:runtime.db}),{code:'game_center_identity_conflict'});
    await runtime.db`delete from app_private.main_account_deletions where user_id=${actor.id}`;
  });
  await check('native full deletion tombstones identity, revokes Auth, and cannot restore the deleted user',async()=>{
    const body=fixture.assertion(),session=await exchange(body);
    const result=await request(session,{service:'profile',action:'delete',deletion_scope:'account',request_id:randomUUID()});
    assert.equal(result.native_account_deleted,true);assert.equal(result.original_account_deleted,undefined);
    const [account]=await runtime.db`select state from game_center_private.accounts where user_id=${session.user.id}`;
    assert.equal(account.state,'deleted');
    const [{count}]=await runtime.db`select count(*)::int as count from auth.sessions where user_id=${session.user.id}`;assert.equal(count,0);
    assert.equal(await runtime.auth.request('/admin/users/'+session.user.id),undefined);
    await assert.rejects(exchangeGameCenter(fixture.assertion({team_player_id:body.team_player_id}),dependencies),{code:'game_center_account_unavailable'});
    const stale=await app(new Request('http://127.0.0.1/functions/v1/app-services',{method:'POST',headers:{Authorization:'Bearer '+session.access_token},body:JSON.stringify({service:'profile',action:'current'})}));
    assert.equal(stale.status,401);
  });
  await check('tampered proof reaches neither Auth nor database creation',async()=>{
    const bad=fixture.assertion();bad.team_player_id='T:_attacker';
    const [{count:before}]=await runtime.db`select count(*)::int as count from game_center_private.accounts`;
    await assert.rejects(exchangeGameCenter(bad,dependencies),{code:'invalid_game_center_assertion'});
    const [{count:after}]=await runtime.db`select count(*)::int as count from game_center_private.accounts`;assert.equal(after,before);
  });
  await check('untrusted certificate rejected by production verifier even for valid synthetic signature',async()=>{
    const handler=createGameCenterHandler({repository:runtime.repository,auth:runtime.auth,
      verify:createAssertionVerifier({loadCertificate:async()=>validateCertificateChain(fixture.leaf.raw)})});
    const result=await handler(new Request('http://localhost',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(fixture.assertion())}));
    assert.equal(result.status,401);
  });
  await check('deleted account tombstone cannot be revived by Game Center',async()=>{
    await runtime.db`update app_private.profiles set state='deleted' where user_id=${first.user.id}`;
    await assert.rejects(exchangeGameCenter(fixture.assertion({team_player_id:firstBody.team_player_id}),dependencies),{code:'game_center_account_unavailable'});
  });
  await check('private identity and replay tables deny public client access and have RLS',async()=>{
    const rows=await runtime.db`select c.relname,c.relrowsecurity,
      has_table_privilege('anon',c.oid,'SELECT') as anon_read,has_table_privilege('authenticated',c.oid,'SELECT') as user_read
      from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='game_center_private' and c.relkind='r'`;
    assert.equal(rows.length,3);for(const row of rows){assert.equal(row.relrowsecurity,true);assert.equal(row.anon_read,false);assert.equal(row.user_read,false);}
  });
  await runNativeGenerationChecks({runtime,exchange,fixture,check});
  await runNativeHistoryChecks({runtime,exchange,fixture,check});
  console.log(`${passed} local integration checks passed. Synthetic cryptographic fixtures; no Apple device sign-in was performed.`);
}finally{
  // Remove only identities created by this test invocation; never reset the stack.
  for(const session of sessions)try{await runtime.auth.request('/logout?scope=local','POST',{},session.access_token);}catch{}
  for(const key of identities){
    const [account]=await runtime.db`select * from game_center_private.accounts where identity_key=${key}`;
    if(account){try{await runtime.auth.request('/admin/users/'+account.user_id,'DELETE');}catch{}
      await runtime.db.begin(async(tx:any)=>{
        await tx`delete from public.app_profile_signals where recipient_user_id=${account.user_id} or profile_user_id=${account.user_id}`;
        await tx`delete from public.app_user_signals where recipient_user_id=${account.user_id}`;
        await tx`delete from app_private.receipts where actor_id=${account.user_id}`;
        await tx`delete from app_private.lifecycle_jobs where user_id=${account.user_id}`;
        await tx`delete from app_private.main_account_deletions where user_id=${account.user_id}`;
        await tx`delete from app_private.legacy_links where user_id=${account.user_id}`;
        await tx`delete from app_private.profiles where user_id=${account.user_id}`;
        await tx`delete from game_center_private.generation_requests where user_id=${account.user_id}`;
        await tx`delete from game_center_private.accounts where identity_key=${key}`;
      });
    }
  }
  await runtime.db.end();fixture.cleanup();
}

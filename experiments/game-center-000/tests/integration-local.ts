import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createExperimentalRuntime} from '../backend/runtime.mjs';
import {createAssertionVerifier,validateCertificateChain} from '../backend/assertion.mjs';
import {exchangeGameCenter,createGameCenterHandler} from '../backend/service.mjs';
import {ensureProfile} from '../../supabase-game-core/supabase/functions/app-services/profile.ts';
import {createAppHandler} from '../../supabase-game-core/supabase/functions/app-services/handler.ts';
import {createFixtureCertificates} from './fixtures.mjs';
const runtime=createExperimentalRuntime(Deno.env.toObject(),ensureProfile);
if(!runtime.config.local)throw new Error('Integration tests refuse cloud projects.');
const fixture=createFixtureCertificates();
const verify=createAssertionVerifier({loadCertificate:async()=>validateCertificateChain(fixture.leaf.raw,Date.now(),fixture.trust)});
const dependencies={verify,repository:runtime.repository,auth:runtime.auth};
const sessions:any[]=[];const identities=new Set<string>();
let passed=0;
async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log(`PASS ${name}`);}
async function exchange(body:any){identities.add((await verify(body)).identityKey);const result=await exchangeGameCenter(body,dependencies);sessions.push(result);return result;}
const app=createAppHandler({db:runtime.db,authenticate:token=>runtime.auth.request('/user','GET',undefined,token),config:{}});
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
    const [{count}]=await runtime.db`select count(*)::int as count from gc000_private.accounts where identity_key=${(await verify(a)).identityKey}`;
    assert.equal(count,1);
    const again=await exchange(fixture.assertion({team_player_id:team}));
    for(const value of values)if(value.status==='fulfilled')assert.equal(value.value.user.id,again.user.id);
  });
  await check('standard Supabase refresh returns same user without Base44 credentials',async()=>{
    const refreshed=await runtime.auth.request('/token?grant_type=refresh_token','POST',{refresh_token:first.refresh_token});
    sessions.push(refreshed);assert.equal(refreshed.user.id,first.user.id);first=refreshed;
  });
  await check('onboarding save and authenticated readback persist on real profile',async()=>{
    const profile=await request(first,{service:'profile',action:'onboarding',onboarding_version:1,display_name:'Game Center Tester',language:'en',acquisition_source:'other',request_id:randomUUID()});
    assert.equal(profile.onboarding_completed,true);
    const readback=await request(first,{service:'profile',action:'current'});assert.equal(readback.onboarding_completed,true);
  });
  await check('tampered proof reaches neither Auth nor database creation',async()=>{
    const bad=fixture.assertion();bad.team_player_id='T:_attacker';
    const [{count:before}]=await runtime.db`select count(*)::int as count from gc000_private.accounts`;
    await assert.rejects(exchangeGameCenter(bad,dependencies),{code:'invalid_game_center_assertion'});
    const [{count:after}]=await runtime.db`select count(*)::int as count from gc000_private.accounts`;assert.equal(after,before);
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
      from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='gc000_private' and c.relkind='r'`;
    assert.equal(rows.length,2);for(const row of rows){assert.equal(row.relrowsecurity,true);assert.equal(row.anon_read,false);assert.equal(row.user_read,false);}
  });
  console.log(`${passed} local integration checks passed. Synthetic cryptographic fixtures; no Apple device sign-in was performed.`);
}finally{
  // Remove only identities created by this test invocation; never reset the stack.
  for(const session of sessions)try{await runtime.auth.request('/logout?scope=local','POST',{},session.access_token);}catch{}
  for(const key of identities){
    const [account]=await runtime.db`select * from gc000_private.accounts where identity_key=${key}`;
    if(account){try{await runtime.auth.request('/admin/users/'+account.user_id,'DELETE');}catch{}
      await runtime.db.begin(async(tx:any)=>{
        await tx`delete from public.app_profile_signals where recipient_user_id=${account.user_id} or profile_user_id=${account.user_id}`;
        await tx`delete from public.app_user_signals where recipient_user_id=${account.user_id}`;
        await tx`delete from app_private.receipts where actor_id=${account.user_id}`;
        await tx`delete from app_private.profiles where user_id=${account.user_id}`;
        await tx`delete from gc000_private.accounts where identity_key=${key}`;
      });
    }
  }
  await runtime.db.end();fixture.cleanup();
}

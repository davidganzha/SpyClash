import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {createClient} from '@supabase/supabase-js';
import {cloudTestConfig,requireAllowedTestTarget} from '../client/game-client.mjs';
import {loadTestFixture,testEnvironment} from './test-fixtures.mjs';

const env=testEnvironment({SUPABASE_TEST_CONFIG_FILE:'.local/cloud-env.json',...process.env});
const config=cloudTestConfig(env),fixture=loadTestFixture(config,'.local/cloud-actors.json');
assert.equal(config.projectRef,'bbkfsgnordtdiblgdzkg');
const endpoint=config.url+'/functions/v1/app-services';requireAllowedTestTarget(endpoint,config);
const users=[],checks=[];let stage='sign_in';
const write=(service,action,fields={})=>({service,action,...fields,request_id:randomUUID()});
try {
  for(const id of ['js1','js2']){
    const credential=fixture.actors.find(a=>a.id===id);assert.ok(credential);
    const sdk=createClient(config.url,config.anonKey,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
    const {data,error}=await sdk.auth.signInWithPassword({email:credential.email,password:credential.password});assert.ifError(error);assert.ok(data.session.expires_in<=3600);
    users.push({id:data.user.id,token:data.session.access_token,sdk});
  }
  async function call(user,body,route='app-services'){
    const response=await fetch(config.url+'/functions/v1/'+route,{method:'POST',redirect:'error',signal:AbortSignal.timeout(30000),headers:{apikey:config.anonKey,Authorization:'Bearer '+user.token,'Content-Type':'application/json'},body:JSON.stringify(body)});
    const payload=await response.json();
    if(response.status!==200)throw new Error('cloud_'+response.status+'_'+String(payload.code||''));return payload;
  }
  stage='profiles';const profiles=await Promise.all(users.map(u=>call(u,{service:'profile',action:'current'})));
  profiles.forEach((p,i)=>{assert.equal(p.id,users[i].id);assert.equal(p.email,users[i].id+'@example.test');assert.match(p.spy_id,/^\d{3}-\d{3}$/);assert.equal(p.role,'user');});checks.push('verified_self_profiles');
  stage='receipt_concurrency';const body=write('profile','update',{language:profiles[0].language});
  const repeated=await Promise.all(Array.from({length:4},()=>call(users[0],body)));repeated.forEach(p=>assert.deepEqual(p,repeated[0]));checks.push('concurrent_exact_receipt_replay');
  stage='community_inbox';
  const directory=await call(users[0],{service:'community',action:'directory'});assert.ok(!JSON.stringify(directory).includes(profiles[1].contact_email));
  const state=await call(users[1],{service:'community',action:'state'});assert.ok(state);
  const inbox=await call(users[1],{service:'notifications',action:'list',scope:'all',locale:'en'});assert.ok(Array.isArray(inbox.items));checks.push('community_inbox_and_private_contact');
  stage='capabilities';const membership=await call(users[0],{service:'membership',action:'check'});assert.equal(typeof membership.active,'boolean');
  const legacy=await call(users[0],{service:'legacy',action:'status'});assert.equal(legacy.generator_provider,'base44');assert.equal(legacy.configured,true);assert.equal(legacy.linked,false);checks.push('membership_and_honest_legacy_capabilities');
  stage='game_read';const history=await call(users[0],{action:'get_history',limit:200},'full-game-core');assert.ok(Array.isArray(history.history));checks.push('shared_game_identity_history');
  stage='rls';const privateRead=await users[0].sdk.schema('app_private').from('profiles').select('*').limit(1);assert.ok(privateRead.error||!privateRead.data?.length);
  const signals=await users[1].sdk.from('app_user_signals').select('*').eq('recipient_user_id',users[0].id);assert.ifError(signals.error);assert.deepEqual(signals.data,[]);checks.push('private_schema_and_recipient_rls');
  const anonymous=await fetch(endpoint,{method:'POST',headers:{apikey:config.anonKey,'Content-Type':'application/json'},body:JSON.stringify({service:'profile',action:'current'})});assert.equal(anonymous.status,401);checks.push('anonymous_gateway_denied');
  stage='hybrid_auth_boundary';
  const bridge=config.url+'/functions/v1/legacy-session';
  for(const token of [null,users[0].token]) {
    const headers={apikey:config.anonKey,'Content-Type':'application/json'};
    if(token)headers.Authorization='Bearer '+token;
    const response=await fetch(bridge,{method:'POST',redirect:'error',signal:AbortSignal.timeout(15000),headers,body:JSON.stringify({action:'exchange'})});
    assert.equal(response.status,401);
  }
  const invalidMethod=await fetch(bridge,{redirect:'error',signal:AbortSignal.timeout(15000),headers:{apikey:config.anonKey}});assert.equal(invalidMethod.status,405);
  checks.push('hybrid_bridge_denies_missing_and_supabase_credentials');
  const report={project_ref:config.projectRef,checked_at:new Date().toISOString(),passed:true,checks,synthetic_clients:2,production_mutations:false};
  writeFileSync('.local/app-services-cloud-verification.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report,null,2));
} catch(error) {
  console.error(JSON.stringify({passed:false,stage,error:String(error.message).slice(0,160)}));process.exitCode=1;
} finally {for(const user of users)await user.sdk.auth.signOut({scope:'local'});}

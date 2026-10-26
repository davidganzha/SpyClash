import test from 'node:test';
import assert from 'node:assert/strict';
import {createAuthAPI,createActorAuthenticator} from '../../supabase/functions/game-center-session/backend/service.mjs';
const config={origin:'https://ovowoixuyabccgkxcexp.supabase.co',anonKey:'public-test-key',serviceRoleKey:'test-only-server-key'};
class Unauthorized extends Error {constructor(){super('Sign in to continue.');this.code='unauthorized';this.status=401;this.retryable=false;}}
const json=(value,status=200)=>Response.json(value,{status});

test('only Auth 401/403 bearer rejections become terminal app 401',async()=>{
 for(const status of [401,403]){
  const auth=createAuthAPI(config,async()=>json({error_code:'user_not_found'},status));
  await assert.rejects(auth.request('/user','GET',undefined,'synthetic-bearer'),{code:'auth_session_invalid',status:401,retryable:false});
  const authenticate=createActorAuthenticator(auth,()=>new Unauthorized());
  await assert.rejects(authenticate('synthetic-bearer'),{code:'unauthorized',status:401,retryable:false});
 }
});
test('Auth 5xx and rate limits remain retryable 503 and cannot sign the app out',async()=>{
 for(const status of [429,500,502,503,504]){
  const auth=createAuthAPI(config,async()=>json({error_code:'unexpected_failure'},status));
  const authenticate=createActorAuthenticator(auth,()=>{throw new Error('must not invalidate session');});
  await assert.rejects(authenticate('synthetic-bearer'),{code:'game_center_unavailable',status:503,retryable:true});
 }
});
test('network timeout and malformed Auth success remain retryable 503',async()=>{
 for(const fetcher of [async()=>{throw new TypeError('fetch failed');},async()=>new Response('not json')]){
  const authenticate=createActorAuthenticator(createAuthAPI(config,fetcher),()=>{throw new Error('must not invalidate session');});
  await assert.rejects(authenticate('synthetic-bearer'),{status:503,retryable:true});
 }
});
test('a rejected administrative credential is a server outage, not a rejected player',async()=>{
 const auth=createAuthAPI(config,async()=>json({},401));
 await assert.rejects(auth.request('/admin/users','POST',{}),{code:'game_center_unavailable',status:503,retryable:true});
});
test('verified Auth identity is returned without an extra exchange',async()=>{
 let calls=0;const user={id:'11111111-1111-4111-8111-111111111111'};
 const auth=createAuthAPI(config,async(_url,init)=>{calls++;assert.equal(init.headers.Authorization,'Bearer synthetic-bearer');return json(user);});
 assert.deepEqual(await createActorAuthenticator(auth,()=>new Unauthorized())('synthetic-bearer'),user);
 assert.equal(calls,1);
});

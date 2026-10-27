import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createAppHandler} from '../../supabase/functions/app-services/handler.ts';
import {AppServiceError} from '../../supabase/functions/app-services/contracts.ts';
import {createActorAuthenticator} from '../../supabase/functions/game-center-session/backend/service.mjs';

const reply=(words=['Apple','Pear'])=>Response.json({status:'completed',output:[{type:'message',role:'assistant',content:[{type:'output_text',text:JSON.stringify({
  draft_words:words,accepted_indices:words.map((_,i)=>i),replacement_words:[],accepted_replacement_indices:[],category:'Fruit',exhausted:false})}]}]});
function heldProvider(){
  let release!:()=>void,started!:()=>void;
  const waiting=new Promise<void>(resolve=>release=resolve),began=new Promise<void>(resolve=>started=resolve);
  return {began,release:()=>release(),fetch:async()=>{started();await waiting;return reply();}};
}
export async function runNativeGenerationChecks({runtime,exchange,fixture,check}:any){
  const config={APP_NATIVE_GAME_CENTER_AI_ENABLED:'true',APP_NATIVE_GAME_CENTER_AI_PROVIDER:'openai',OPENAI_API_KEY:'local-fixture-not-a-provider-secret',
    SUPABASE_URL:runtime.config.origin,SUPABASE_SERVICE_ROLE_KEY:runtime.config.serviceRoleKey};
  const handler=(fetcher:typeof fetch,options=config)=>createAppHandler({db:runtime.db,config:options,fetch:fetcher,
    authenticate:createActorAuthenticator(runtime.auth,()=>new AppServiceError('unauthorized','Sign in again.',401))});
  const call=async(app:any,session:any,body:any)=>{
    const response=await app(new Request('http://127.0.0.1/functions/v1/app-services',{method:'POST',headers:{Authorization:'Bearer '+session.access_token},body:JSON.stringify(body)}));
    return {status:response.status,body:await response.json()};
  };
  const command=(id=randomUUID())=>({service:'legacy',action:'generate',theme:'Fruit',count:2,request_id:id});
  const used=async(userID:string)=>{const [row]=await runtime.db`select count(*)::int as used from game_center_private.generation_requests where user_id=${userID} and charged`;return row.used;};
  let calls=0;
  const provider=async(url:any,options:any)=>{
    assert.equal(String(url),'https://api.openai.com/v1/responses');
    assert.equal(options.method,'POST');calls++;return reply();
  };
  const app=handler(provider),session=await exchange(fixture.assertion());
  await check('native generation capabilities require explicit rollout and provider configuration',async()=>{
    const disabled=handler(provider,{...config,OPENAI_API_KEY:''});
    const status=await call(disabled,session,{service:'legacy',action:'status'});
    assert.equal(status.status,200);assert.equal(status.body.requires_legacy_session,false);assert.equal(status.body.configured,false);
    const before=calls,result=await call(disabled,session,command());
    assert.equal(result.status,503);assert.equal(result.body.code,'native_generation_unconfigured');assert.equal(calls,before);assert.equal(await used(session.user.id),0);
  });
  await check('native AI executes existing provider/quality gate, persists one quota charge and replays without provider',async()=>{
    const request=command(),before=calls;
    const a=await call(app,session,request),b=await call(app,session,request);
    assert.equal(a.status,200,JSON.stringify(a.body));assert.deepEqual(a.body.words,['Apple','Pear']);assert.deepEqual(b,a);
    assert.equal(a.body.ai_limit,10);assert.equal(a.body.ai_remaining,9);assert.equal(calls,before+1);assert.equal(await used(session.user.id),1);
    const conflict=await call(app,session,{...request,theme:'Cars'});assert.equal(conflict.status,409);assert.equal(calls,before+1);
  });
  await check('native account cannot adopt a Base44 identity or send forged generator evidence',async()=>{
    const before=calls;
    const link=await call(app,session,{service:'legacy',action:'link',base44_access_token:'forged',request_id:randomUUID()});
    assert.equal(link.status,409);assert.equal(link.body.code,'game_center_legacy_link_unsupported');
    const forged=await call(app,session,{...command(),evidence:{result:{words:['forged']}}});assert.equal(forged.status,400);assert.equal(calls,before);
  });
  await check('failed provider does not spend quota; same immutable request can recover',async()=>{
    const request=command(),before=await used(session.user.id);
    const failure=await call(handler(async()=>Response.json({error:{message:'private upstream'}},{status:503})),session,request);
    assert.equal(failure.status,503);assert.equal(failure.body.code,'ai_provider_unavailable');assert.equal(JSON.stringify(failure).includes('private upstream'),false);
    assert.equal(await used(session.user.id),before);
    const result=await call(app,session,request);assert.equal(result.status,200);assert.equal(await used(session.user.id),before+1);
  });
  await check('parallel same request shares a lease and cannot duplicate its quota',async()=>{
    const held=heldProvider(),request=command(),before=await used(session.user.id);
    const pending=call(handler(held.fetch),session,request);await held.began;
    const busy=await call(app,session,request);assert.equal(busy.status,503);assert.equal(busy.body.code,'generation_in_progress');
    held.release();assert.equal((await pending).status,200);assert.equal(await used(session.user.id),before+1);
  });
  await check('expired lease recovery fences a stale provider completion and keeps one charge',async()=>{
    const held=heldProvider(),request=command(),before=await used(session.user.id);
    const pending=call(handler(held.fetch),session,request);await held.began;
    await runtime.db`update game_center_private.generation_requests set lease_until=clock_timestamp()-interval '1 second' where user_id=${session.user.id} and request_id=${request.request_id}`;
    const recovered=await call(app,session,request);assert.equal(recovered.status,200);
    held.release();assert.equal((await pending).status,503);assert.equal(await used(session.user.id),before+1);
    assert.deepEqual(await call(app,session,request),recovered);
  });
  await check('daily free quota stays bounded during parallel requests and ignores editable premium metadata',async()=>{
    const free=await exchange(fixture.assertion());
    await runtime.auth.request('/user','PUT',{data:{premium:true,role:'admin',is_limitless:true}},free.access_token);
    const results=await Promise.all(Array.from({length:11},()=>call(app,free,command())));
    assert.equal(results.filter(r=>r.status===200).length,10,JSON.stringify(results));
    assert.equal(results.filter(r=>r.status===429&&r.body.code==='ai_limit_reached').length,1);assert.equal(await used(free.user.id),10);
  });
  await check('active server grant permits native generation beyond the free quota',async()=>{
    const paid=await exchange(fixture.assertion());
    await runtime.db`insert into app_private.membership_grants(id,user_id,active,expires_at,data) values(${randomUUID()},${paid.user.id},true,clock_timestamp()+interval '1 day','{}')`;
    try{
      for(let index=0;index<11;index++){const result=await call(app,paid,command());assert.equal(result.status,200,JSON.stringify(result));assert.equal(result.body.ai_limit,null);}
      assert.equal(await used(paid.user.id),11);
    }finally{await runtime.db`delete from app_private.membership_grants where user_id=${paid.user.id}`;}
  });
  await check('account deletion during native provider work removes results and blocks late writes',async()=>{
    const deleted=await exchange(fixture.assertion()),held=heldProvider(),request=command();
    const pending=call(handler(held.fetch),deleted,request);await held.began;
    const removal=await call(app,deleted,{service:'profile',action:'delete',deletion_scope:'account',request_id:randomUUID()});
    assert.equal(removal.status,200);assert.equal(removal.body.native_account_deleted,true);
    held.release();assert.equal((await pending).status,403);
    const [{count}]=await runtime.db`select count(*)::int as count from game_center_private.generation_requests where user_id=${deleted.user.id}`;assert.equal(count,0);
  });
}

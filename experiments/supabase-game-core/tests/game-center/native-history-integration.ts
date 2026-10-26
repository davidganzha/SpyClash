import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createHandler} from '../../supabase/functions/full-game-core/handler.ts';
import {AppServiceError} from '../../supabase/functions/app-services/contracts.ts';
import {createActorAuthenticator} from '../../supabase/functions/game-center-session/backend/service.mjs';

export async function runNativeHistoryChecks({runtime,exchange,fixture,check}:any){
  const session=await exchange(fixture.assertion()),roomID=randomUUID(),grantID=randomUUID();
  const app=createHandler({db:runtime.db,authenticate:createActorAuthenticator(runtime.auth,()=>new AppServiceError('unauthorized','Sign in again.',401))});
  const call=async(body:any)=>{
    const response=await app(new Request('http://127.0.0.1/functions/v1/full-game-core',{method:'POST',headers:{Authorization:'Bearer '+session.access_token},body:JSON.stringify(body)}));
    return {status:response.status,body:await response.json()};
  };
  try{
    await runtime.db`insert into full_game_private.rooms(id,code,state,closed) values(${roomID},${roomID.slice(0,6).toUpperCase()},'{}',true)`;
    for(let index=0;index<8;index++)await runtime.db`insert into full_game_private.history(match_id,player_id,room_id,result,created_at)
      values(${randomUUID()},${session.user.id},${roomID},${runtime.db.json({result_key:randomUUID(),order:index})},clock_timestamp()-${index}*interval '1 day')`;
    let oldPaidCursor:string;
    await check('native free history exposes only newest five even with arbitrary high limit and pagination',async()=>{
      const full=await call({action:'get_history',limit:200});assert.equal(full.status,200);assert.equal(full.body.history.length,5);assert.equal(full.body.next_cursor,null);
      let cursor:undefined|string;const all=[];
      do{const page=await call({action:'get_history',limit:2,...(cursor?{cursor}:{})});assert.equal(page.status,200);all.push(...page.body.history);cursor=page.body.next_cursor;}while(cursor);
      assert.equal(all.length,5);assert.deepEqual(all.map(row=>row.order),[0,1,2,3,4]);
      const forged=btoa(JSON.stringify({at:'2000-01-01T00:00:00.000000Z',id:randomUUID()}));
      assert.equal((await call({action:'get_history',cursor:forged})).body.history.length,0);
    });
    await check('server membership grant unlocks all native history without changing stored records',async()=>{
      await runtime.db`insert into app_private.membership_grants(id,user_id,active,expires_at,data) values(${grantID},${session.user.id},true,clock_timestamp()+interval '1 day','{}')`;
      const full=await call({action:'get_history'});assert.equal(full.status,200);assert.equal(full.body.history.length,8);
      const page=await call({action:'get_history',limit:6});oldPaidCursor=page.body.next_cursor;assert.ok(oldPaidCursor);
    });
    await check('expired membership cannot reuse a paid history cursor to bypass free boundary',async()=>{
      await runtime.db`update app_private.membership_grants set expires_at=clock_timestamp()-interval '1 minute' where id=${grantID}`;
      const page=await call({action:'get_history',cursor:oldPaidCursor});assert.equal(page.status,200);assert.equal(page.body.history.length,0);
      const full=await call({action:'get_history'});assert.equal(full.body.history.length,5);
    });
    await check('stale native Apple entitlement cannot expose paid history without canonical verification',async()=>{
      const key='native-history-fixture:'+randomUUID();
      await runtime.db`insert into app_private.entitlements(source_key,user_id,active,expires_at,provider,data)
        values(${key},${session.user.id},true,clock_timestamp()+interval '1 day','apple',${runtime.db.json({last_verified_at:'2000-01-01T00:00:00Z'})})`;
      try{
        const result=await call({action:'get_history'});assert.equal(result.status,503);assert.equal(result.body.history,undefined);
        const ordinary=await call({action:'word_packs'});assert.equal(ordinary.status,200);
      }finally{await runtime.db`delete from app_private.entitlements where source_key=${key}`;}
    });
  }finally{
    await runtime.db`delete from app_private.membership_grants where user_id=${session.user.id}`;
    await runtime.db`delete from full_game_private.history where room_id=${roomID}`;
    await runtime.db`delete from full_game_private.rooms where id=${roomID}`;
  }
}

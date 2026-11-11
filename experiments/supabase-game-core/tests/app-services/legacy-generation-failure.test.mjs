import assert from 'node:assert/strict';
import test from 'node:test';
import {legacyGenerationFailure} from '../../supabase/functions/app-services/legacy.ts';

const proof={retryable:true,retry_phase:'before_effects',effects_started:false};
const failure=(body,status=503)=>legacyGenerationFailure(Response.json(body,{status}));

test('legacy generation preserves proven pre-effect shared-library failures for installed-client retry',async()=>{
  for(const code of ['shared_library_busy','shared_library_unavailable']){
    const error=await failure({code,...proof,error:'PRIVATE_UPSTREAM_MESSAGE'});
    assert.equal(error.code,code);
    assert.equal(error.status,503);
    assert.equal(error.retryable,true);
    assert.ok(!error.message.includes('PRIVATE'));
  }
});

test('legacy generation never upgrades partial, contradictory or unrelated errors into safe library retries',async()=>{
  for(const code of ['shared_library_busy','shared_library_unavailable']){
    for(const patch of [
      {retryable:false},{retryable:'true'},{retryable:undefined},
      {retry_phase:'effects_may_have_started'},{retry_phase:undefined},
      {effects_started:true},{effects_started:'false'},{effects_started:undefined},
    ]){
      const error=await failure({code,...proof,...patch});
      assert.equal(error.code,'legacy_generation_unavailable');
      assert.equal(error.status,503);
    }
  }
  for(const code of ['generation_outcome_unknown','generation_journal_unavailable','ai_provider_unavailable','shared_generation_in_progress','shared_library_unconfigured','unrecognized']){
    assert.equal((await failure({code,...proof})).code,'legacy_generation_unavailable');
  }
});

test('legacy generation requires exact retry status and preserves non-server rejection status',async()=>{
  for(const status of [400,401,409,422,429,500,502,504]){
    const error=await failure({code:'shared_library_busy',...proof},status);
    assert.equal(error.code,'legacy_generation_unavailable');
    assert.equal(error.status,status>=500?503:status);
    assert.equal(error.retryable,status>=500);
  }
});

test('legacy generation preserves only definite daily allowance rejections and sanitizes their message',async()=>{
  for(const fields of [{},{retryable:false}]){
    const error=await failure({code:'daily_ai_limit_reached',...fields,error:'PRIVATE_QUOTA_MESSAGE'},429);
    assert.equal(error.code,'daily_ai_limit_reached');
    assert.equal(error.status,429);
    assert.equal(error.retryable,false);
    assert.equal(error.message,'Daily AI generation limit reached. Try again tomorrow.');
  }
  for(const retryable of [true,'false','true',null,0,{},[]]){
    assert.equal((await failure({code:'daily_ai_limit_reached',retryable},429)).code,'legacy_generation_unavailable');
  }
  for(const code of ['ai_limit_reached','rate_limited','daily_ai_limit_reached ',null]){
    assert.equal((await failure({code,retryable:false},429)).code,'legacy_generation_unavailable');
  }
  for(const status of [400,409,422,500,503]){
    assert.equal((await failure({code:'daily_ai_limit_reached',retryable:false},status)).code,'legacy_generation_unavailable');
  }
});

test('legacy generation safely falls back on malformed, oversized or interrupted error responses',async()=>{
  for(const response of [
    new Response('PRIVATE_NOT_JSON',{status:503}),
    Response.json(null,{status:503}),
    Response.json(['shared_library_busy'],{status:503}),
    Response.json({code:'shared_library_busy',...proof,error:'x'.repeat(256_000)},{status:503}),
    new Response(new ReadableStream({start(controller){controller.error(new Error('PRIVATE_TRANSPORT'));}}),{status:503}),
  ]){
    const error=await legacyGenerationFailure(response);
    assert.equal(error.code,'legacy_generation_unavailable');
    assert.equal(error.status,503);
    assert.ok(!error.message.includes('PRIVATE'));
  }
});

import assert from 'node:assert/strict';
import postgres from 'postgres';
import {buildSharedWordPackVariant,prepareSharedWordPackRequest} from '../../supabase/functions/app-services/word-generation/shared-word-pack-library.ts';

// Local PostgreSQL only. This script creates and drops its own database and
// never touches the running local app's database or a hosted service.
const raw=Deno.env.get('SHARED_LIBRARY_TEST_DATABASE_URL');
if(!raw)throw new Error('SHARED_LIBRARY_TEST_DATABASE_URL must name local PostgreSQL.');
const url=new URL(raw);
if(!['127.0.0.1','localhost'].includes(url.hostname))throw new Error('Local database required.');
const admin=postgres(url.href,{max:1,onnotice:()=>{}});
const name='spyclash_shared_'+crypto.randomUUID().replaceAll('-','');
await admin.unsafe('create database '+name);
url.pathname='/'+name;
const db=postgres(url.href,{max:16,onnotice:()=>{}});
let checks=0;
const check=async(name:string,run:()=>Promise<void>)=>{await run();checks++;console.log('PASS '+name);};
const request=await prepareSharedWordPackRequest({theme:'Fruit',language:'und',promptVersion:'test-v1',requestedCount:2});
const pack=await buildSharedWordPackVariant({request,result:{words:['Apple','Pear'],exhausted:false}});
try{
  await db.unsafe(await Deno.readTextFile(new URL('../../supabase/migrations/20261111185732_shared_word_pack_library.sql',import.meta.url)));
  await check('shared stock has RLS and no anonymous or signed-in client grants',async()=>{
    const rows=await db`select relrowsecurity from pg_class where oid in ('public.word_pack_library_variants'::regclass,'public.word_pack_library_leases'::regclass)`;
    assert.equal(rows.length,2);assert.ok(rows.every(row=>row.relrowsecurity));
    for(const role of ['anon','authenticated']){
      const [priv]=await db`select has_table_privilege(${role},'public.word_pack_library_variants','select,insert,update,delete') as table_allowed,
        has_function_privilege(${role},'public.word_pack_library_read(text)','execute') as read_allowed,
        has_function_privilege(${role},'public.word_pack_library_claim(text,uuid)','execute') as claim_allowed,
        has_function_privilege(${role},'public.word_pack_library_publish(jsonb,uuid)','execute') as publish_allowed`;
      assert.equal(priv.table_allowed,false);assert.equal(priv.read_allowed,false);assert.equal(priv.claim_allowed,false);assert.equal(priv.publish_allowed,false);
    }
    const functions=await db`select prosecdef,proconfig from pg_proc where oid in ('public.word_pack_library_read(text)'::regprocedure,'public.word_pack_library_claim(text,uuid)'::regprocedure,'public.word_pack_library_publish(jsonb,uuid)'::regprocedure,'public.word_pack_library_release(text,uuid)'::regprocedure)`;
    assert.equal(functions.length,4);assert.ok(functions.every(row=>!row.prosecdef));
  });
  await check('one concurrent claimant owns the shared topic generation lease',async()=>{
    const tokens=Array.from({length:12},()=>crypto.randomUUID());
    const results=await Promise.all(tokens.map(async token=>{
      const [row]=await db`select public.word_pack_library_claim(${request.cacheKey},${token}::uuid) as claimed`;
      return {token,claimed:row.claimed};
    }));
    assert.equal(results.filter(row=>row.claimed).length,1);
    const winner=results.find(row=>row.claimed)!;
    const [lease]=await db`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
    assert.equal(lease.token,winner.token);
  });
  await check('stale tokens cannot publish or release another worker lease',async()=>{
    const [lease]=await db`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
    const stale=crypto.randomUUID();
    const [denied]=await db`select public.word_pack_library_publish(${db.json(pack)},${stale}::uuid) as published`;
    assert.equal(denied.published,false);
    await db`select public.word_pack_library_release(${request.cacheKey},${stale}::uuid)`;
    const [still]=await db`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
    assert.equal(still.token,lease.token);
    const [accepted]=await db`select public.word_pack_library_publish(${db.json(pack)},${lease.token}::uuid) as published`;
    assert.equal(accepted.published,true);
    const [row]=await db`select public.word_pack_library_read(${request.cacheKey}) as records`;
    assert.equal(row.records.length,1);assert.deepEqual(row.records[0].words,['Apple','Pear']);
  });
  await check('the backend service role can read and publish through invoker RPCs',async()=>{
    await db.begin(async(tx:any)=>{
      await tx`set local role service_role`;
      const [row]=await tx`select public.word_pack_library_read(${request.cacheKey}) as records`;
      assert.equal(row.records.length,1);
      const [lease]=await tx`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
      const [result]=await tx`select public.word_pack_library_publish(${tx.json(pack)},${lease.token}::uuid) as published`;
      assert.equal(result.published,true);
    });
  });
  await check('expired leases can be replaced and old workers lose publication rights',async()=>{
    const [prior]=await db`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
    await db`update public.word_pack_library_leases set expires_at=clock_timestamp()-interval '1 second' where cache_key=${request.cacheKey}`;
    const next=crypto.randomUUID();
    const [claimed]=await db`select public.word_pack_library_claim(${request.cacheKey},${next}::uuid) as value`;
    assert.equal(claimed.value,true);
    const [old]=await db`select public.word_pack_library_publish(${db.json(pack)},${prior.token}::uuid) as value`;
    assert.equal(old.value,false);
    await db`select public.word_pack_library_release(${request.cacheKey},${prior.token}::uuid)`;
    const [remaining]=await db`select token from public.word_pack_library_leases where cache_key=${request.cacheKey}`;
    assert.equal(remaining.token,next);
  });
  await check('lookup returns all live variants and excludes expired stock',async()=>{
    // More than the usual API row cap: RPC returns one aggregated JSON value.
    await db`insert into public.word_pack_library_variants(variant_key,cache_key,language_key,prompt_version,exclusion_key,words,exhausted,word_count,generated_at,expires_at)
      select 'swv1_'||lpad(i::text,43,'0'),${pack.cache_key},${pack.language_key},${pack.prompt_version},${pack.exclusion_key},'["Apple","Pear"]'::jsonb,false,2,clock_timestamp(),clock_timestamp()+interval '1 day'
      from generate_series(1,1001) i`;
    const [all]=await db`select public.word_pack_library_read(${request.cacheKey}) as records`;
    assert.equal(all.records.length,1002);
    await db`update public.word_pack_library_variants set generated_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 day' where variant_key=${pack.variant_key}`;
    const [active]=await db`select public.word_pack_library_read(${request.cacheKey}) as records`;
    assert.equal(active.records.length,1001);
  });
  console.log(`PASS ${checks} shared-library PostgreSQL checks`);
}finally{
  await db.end();
  await admin.unsafe('drop database '+name+' with (force)');
  await admin.end();
}

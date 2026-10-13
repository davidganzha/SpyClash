import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test,{after} from 'node:test';
import postgres from 'postgres';
import {captureLegacySocialExport,planLegacySocialExport,stageVerifiedSocialExport,applyDeferredSocialRows} from '../../supabase/functions/app-services/legacy-social.ts';
const url=new URL(process.env.DATABASE_URL||'');assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
const db=postgres(url.toString(),{max:8,onnotice:()=>{}}),ids=[];
const at='2025-01-01T00:00:00.000Z';
async function actor({mapped=true}={}) {
  const id=randomUUID(),legacy='source-'+randomUUID();ids.push(id);
  await db`insert into app_private.profiles(user_id,contact_email,data) values(${id},'',${db.json({display_name:'Test operator'})})`;
  if(mapped)await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${id},${legacy},'https://spyclash.com',now())`;
  return {id,legacy,email:id+'@example.test',contactEmail:'',full_name:'Test operator',metadata:{}};
}
const ctx=(tx,a)=>({tx,actor:a,now:new Date(),config:{APP_ADMIN_USER_IDS:a.id,LEGACY_SOCIAL_IMPORT_ENABLED:'true'}});
const friend=(a,b,status='accepted')=>({id:'friend-'+randomUUID(),requester_id:a.legacy,addressee_id:b.legacy,status,blocked_by_id:status==='blocked'?a.legacy:null,created_at:at,updated_at:at});
const comment=(a,b)=>({id:'comment-'+randomUUID(),target_user_id:a.legacy,author_user_id:b.legacy,body:'Good game',created_at:at,updated_at:at});
async function snapshot(friendships=[],comments=[],extra={}) {
  return captureLegacySocialExport(async(entity,options)=>{
    assert.equal(options.sort,'id');assert.ok(options.fields.includes('id'));assert.ok(!options.fields.includes('email'));
    const rows=entity==='Friendship'?friendships:comments;return rows.slice(options.skip,options.skip+options.limit);
  },{pageSize:2,...extra});
}
const stage=(a,s)=>db.begin(tx=>stageVerifiedSocialExport(ctx(tx,a),s));
const apply=(a,sourceIDs)=>db.begin(tx=>applyDeferredSocialRows(ctx(tx,a),sourceIDs));
after(async()=>{
  if(ids.length)await db.begin(async tx=>{
    await tx`delete from app_private.profile_comments where target_user_id=any(${ids}::uuid[]) or author_user_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.friendships where requester_id=any(${ids}::uuid[]) or addressee_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.legacy_pending_social where owner_id=any(${ids}::uuid[])`;
    await tx`delete from public.app_profile_signals where recipient_user_id=any(${ids}::uuid[]) or profile_user_id=any(${ids}::uuid[])`;
    await tx`delete from public.app_user_signals where recipient_user_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.legacy_links where user_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.profiles where user_id=any(${ids}::uuid[])`;
  });await db.end();
});

test('direct-read export is bounded and dry-run reports mappings without creating users or touching data',async()=>{
  const a=await actor(),b=await actor(),f=friend(a,b),c=comment(a,b);
  const s=await snapshot([f],[c]);assert.equal(s.rows.length,2);
  const plan=await planLegacySocialExport(s,[{legacy_user_id:a.legacy,user_id:a.id,state:'active'}]);
  assert.equal(plan.ready_count,0);assert.equal(plan.deferred_count,2);
  assert.equal((await db`select 1 from app_private.friendships where requester_id=${a.id}`).length,0);
  await assert.rejects(snapshot([f],[c],{maxRows:1}),e=>e.code==='social_export_limit');
  await assert.rejects(planLegacySocialExport({...s,digest:'0'.repeat(64)},[]),e=>e.code==='social_export_digest_mismatch');
});

test('unmapped peer remains deferred and applies once a verified identity exists; replay does not resurrect deletion',async()=>{
  const op=await actor(),a=await actor(),b=await actor({mapped:false}),f=friend(a,b),c=comment(a,b),s=await snapshot([f],[c]);
  await stage(op,s);
  assert.equal((await apply(op,[f.id,c.id])).deferred,2);
  await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${b.id},${b.legacy},'https://spyclash.com',now())`;
  const result=await apply(op,[f.id,c.id]);assert.equal(result.applied,2);
  assert.equal((await db`select 1 from app_private.friendships where requester_id=${a.id} and addressee_id=${b.id}`).length,1);
  assert.equal((await db`select 1 from app_private.profile_comments where target_user_id=${a.id} and author_user_id=${b.id}`).length,1);
  assert.equal((await db`select 1 from app_private.notification_events where actor_id=${a.id} or recipient_id=${a.id}`).length,0);
  assert.equal((await db`select 1 from app_private.push_outbox where user_id=${a.id} or user_id=${b.id}`).length,0);
  await db`delete from app_private.friendships where requester_id=${a.id} and addressee_id=${b.id}`;
  await db`delete from app_private.profile_comments where target_user_id=${a.id} and author_user_id=${b.id}`;
  await stage(op,s);assert.equal((await apply(op,[f.id,c.id])).already_applied,2);
  assert.equal((await db`select 1 from app_private.friendships where requester_id=${a.id}`).length,0);
});

test('source blocks precede acceptance and suppress comments; existing local block is never overwritten',async()=>{
  const op=await actor(),a=await actor(),b=await actor(),blocked=friend(a,b,'blocked'),accepted=friend(a,b),c=comment(a,b);
  await stage(op,await snapshot([accepted,blocked],[c]));
  const result=await apply(op,[accepted.id,c.id,blocked.id]);
  assert.equal(result.applied,2);assert.equal(result.conflicts,1);assert.equal(result.blocked_comments,1);
  const [relation]=await db`select status,blocked_by_id from app_private.friendships where requester_id=${a.id}`;
  assert.equal(relation.status,'blocked');assert.equal(relation.blocked_by_id,a.id);
  assert.equal((await db`select 1 from app_private.profile_comments where target_user_id=${a.id}`).length,0);
  assert.equal((await apply(op,[accepted.id])).conflicts,1);
});

test('application is transactional, admin-gated, idempotent under races, and cannot target deleted profiles',async()=>{
  const op=await actor(),a=await actor(),b=await actor(),f=friend(a,b),s=await snapshot([f]);
  await assert.rejects(db.begin(tx=>stageVerifiedSocialExport({...ctx(tx,op),config:{}},s)),e=>e.code==='legacy_social_import_forbidden');
  await stage(op,s);
  await assert.rejects(db.begin(async tx=>{await applyDeferredSocialRows(ctx(tx,op),[f.id]);throw new Error('abort transaction');}),/abort transaction/);
  assert.equal((await db`select 1 from app_private.friendships where requester_id=${a.id}`).length,0);
  const results=await Promise.all([apply(op,[f.id]),apply(op,[f.id])]);
  assert.equal(results.reduce((n,r)=>n+r.applied,0),1);assert.equal(results.reduce((n,r)=>n+r.already_applied,0),1);
  const d=await actor(),g=friend(a,d);await stage(op,await snapshot([g]));
  await db`update app_private.profiles set state='deleted',data='{}' where user_id=${d.id}`;
  assert.equal((await apply(op,[g.id])).deferred,1);
});

test('changed source snapshot and invalid block ownership are explicit conflicts, never overwrites',async()=>{
  const op=await actor(),a=await actor(),b=await actor(),f=friend(a,b);await stage(op,await snapshot([f]));
  await assert.rejects(stage(op,await snapshot([{...f,status:'declined'}])),e=>e.code==='social_source_conflict');
  await assert.rejects(snapshot([{...f,status:'blocked',blocked_by_id:'stranger'}]),e=>e.code==='social_export_invalid');
});

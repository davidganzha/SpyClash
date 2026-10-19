import test from 'node:test';
import assert from 'node:assert/strict';
import { buildCorePlan, mappedUUID, legacyIdentityKey, assertPlanReady, assertProvisionedAccount, assertCoreTargetUnchanged } from './core.ts';
import { digest } from '../../supabase/functions/app-services/integration-crypto.ts';

const source={origin:'https://spyclash.com',appID:'69a0e57fa939f578082f8091'};
const sourceKey=source.origin+'/'+source.appID;
const date='2026-10-19T12:00:00.000Z';
const user=(id,spy)=>({id,email:id+'@example.invalid',full_name:'Old '+id,display_name:'Agent '+id,avatar:'🦊',language:'ru',spy_id:spy,role:'admin',rating:0,games_played:0,games_won:0});
const snapshot=(entities={})=>({version:1,source,capturedAt:date,verifiedAt:date,digest:'synthetic-fixed-source-digest',entities:{User:[user('a','101-001'),user('b','101-002')],WordPack:[],GameHistory:[],Friendship:[],ProfileComment:[],...entities}});
const target=(patch={})=>({profiles:[],links:[],reservations:[],imports:[],runs:[],packs:[],history:[],friendships:[],comments:[],authUsers:[],bulkRows:[],lifecycleJobs:[],mainAccountDeletions:[],...patch});
const history=(id,patch={})=>({id,player_user_id:'a',player_email:'a@example.invalid',match_id:'match-'+id,room_code:'ABC123',match_type:'online',role:'spy',winner:'spy',won:true,ranked:true,spy_count:1,created_date:'2024-07-10T12:00:00.123',...patch});
const pack=(id,patch={})=>({id,owner_user_id:'a',owner_email:'a@example.invalid',name:'Places',category:'Places',words:['Port','Station'],...patch});
const friendship=(patch={})=>({id:'friend-a-b',requester_id:'a',addressee_id:'b',status:'accepted',created_at:date,updated_at:date,...patch});
async function linkedTarget(patch={}) {
  const id='10000000-0000-4000-8000-000000000001';
  return target({profiles:[{user_id:id,state:'active',spy_id:'101-001',contact_email:'a@example.invalid',data:{display_name:'Current choice',avatar:'🦉',language:'es'},created_at:date,updated_at:date}],links:[{user_id:id,legacy_user_id:'a',source_origin:source.origin,state:'active'}],authUsers:[{id,role:'authenticated',email:'unrelated-shadow@example.invalid',raw_app_meta_data:{}}],...patch});
}

test('cold import preserves source SPY IDs, profile choices and full social endpoints without granting roles or identity verification',async()=>{
  const p=await buildCorePlan(snapshot({WordPack:[pack('pack-1')],GameHistory:[history('h1')],Friendship:[friendship()],ProfileComment:[{id:'comment-1',target_user_id:'a',author_user_id:'b',body:'Nice game!',created_at:date,updated_at:date}]}),target());
  assertPlanReady(p);assert.equal(p.accounts.length,2);assert.equal(p.accounts[0].profile.spy_id,'101-001');assert.equal(p.accounts[0].profile.data.language,'ru');assert.equal(p.accounts[0].profile.data.role,undefined);
  assert.equal(p.accounts[0].existing_link,false);assert.equal(p.accounts[0].needs_auth,true);assert.equal(p.accounts[0].identity_key,await legacyIdentityKey(source,'a'));
  assert.equal(p.friendships[0].requester_id,p.accounts[0].user_id);assert.equal(p.comments[0].author_user_id,p.accounts[1].user_id);
  assert.equal(p.history[0].result.created_date,'2024-07-10T12:00:00.123Z');assert.equal(p.history[0].room_id,null);
});

test('UUIDs reuse the owner importer namespace while shadow mailboxes remain unpredictable',async()=>{
  const first=await buildCorePlan(snapshot(),target()),second=await buildCorePlan(snapshot(),target());
  assert.equal(first.accounts[0].user_id,second.accounts[0].user_id);assert.equal(first.accounts[0].user_id,await mappedUUID(sourceKey,'User','a'));
  assert.notEqual(first.accounts[0].shadow_email,second.accounts[0].shadow_email);
  assert.match(first.accounts[0].shadow_email,/^[a-f0-9]{32}@accounts\.spyclash\.invalid$/);
});

test('a matching contact email never attaches a source account to unrelated Auth identity',async()=>{
  const unrelated='10000000-0000-4000-8000-000000000009';
  const p=await buildCorePlan(snapshot(),target({authUsers:[{id:unrelated,email:'a@example.invalid',role:'authenticated',raw_app_meta_data:{}}],profiles:[{user_id:unrelated,state:'active',spy_id:'999-001',contact_email:'a@example.invalid',data:{}}]}));
  assertPlanReady(p);assert.notEqual(p.accounts[0].user_id,unrelated);assert.equal(p.accounts[0].needs_auth,true);assert.equal(p.accounts[0].existing_link,false);
});

test('verified existing UUID wins and current cosmetics/contact/progress survive unchanged',async()=>{
  const t=await linkedTarget();const p=await buildCorePlan(snapshot(),t);
  assertPlanReady(p);assert.equal(p.accounts[0].user_id,t.profiles[0].user_id);assert.equal(p.accounts[0].profile_action,'preserve');assert.deepEqual(p.accounts[0].profile,t.profiles[0]);assert.equal(p.accounts[0].needs_auth,false);
});

test('SPY ID conflicts fail closed instead of silently reassigning a public identity',async()=>{
  const t=await linkedTarget();t.profiles[0].spy_id='999-999';
  let p=await buildCorePlan(snapshot(),t);assert.ok(p.issues.some(i=>i.code==='existing_spy_id_differs'));assert.throws(()=>assertPlanReady(p));
  p=await buildCorePlan(snapshot({User:[user('a','101-001'),user('b','101-001')]}),target());assert.ok(p.issues.some(i=>i.code==='duplicate_source_spy_id'));
  p=await buildCorePlan(snapshot(),target({profiles:[{user_id:'10000000-0000-4000-8000-000000000009',state:'active',spy_id:'101-001',data:{}}]}));assert.ok(p.issues.some(i=>i.code==='target_spy_id_collision'));
});

test('generated SPY IDs cannot occupy any still-unprocessed source SPY ID',async()=>{
  const initial=await buildCorePlan(snapshot({User:[user('a',undefined)]}),target());const candidate=initial.accounts[0].profile.spy_id;
  const p=await buildCorePlan(snapshot({User:[user('a',undefined),user('b',candidate)]}),target());assertPlanReady(p);assert.notEqual(p.accounts[0].profile.spy_id,candidate);assert.equal(p.accounts[1].profile.spy_id,candidate);
});

test('source deletion fences and local lifecycle tombstones prevent account resurrection',async()=>{
  const subject_key='billing:'+(await digest('spyclash-billing-lifecycle:a')).slice(0,40);
  let p=await buildCorePlan(snapshot({BillingIdentityLifecycle:[{id:'lifecycle-1',subject_key,state:'deleting'}]}),target());assert.ok(p.issues.some(i=>i.code==='source_account_deleting'));
  const t=await linkedTarget();t.lifecycleJobs=[{user_id:t.profiles[0].user_id,phase:'complete'}];p=await buildCorePlan(snapshot(),t);assert.ok(p.issues.some(i=>i.code==='target_account_deleting'));
  t.lifecycleJobs=[];t.profiles[0].state='deleted';p=await buildCorePlan(snapshot(),t);assert.ok(p.issues.some(i=>i.code==='account_tombstone'));
});

test('dedup preserves local, multi-spy and email-only history without awarding unearned ranked credit',async()=>{
  const rows=[history('first',{match_id:'same-match'}),history('duplicate',{match_id:'same-match',created_date:'2024-07-11T12:00:00'}),history('local',{match_type:'local'}),history('multi',{spy_count:2}),history('email',{player_user_id:undefined})];
  const p=await buildCorePlan(snapshot({GameHistory:rows}),target());assertPlanReady(p);assert.equal(p.history.length,4);assert.equal(p.dispositions.filter(d=>d.action==='archive_duplicate').length,1);
  assert.equal(p.history.filter(r=>r.result.player_user_id==='').length,1);assert.equal(p.history.find(r=>r.result.player_user_id==='').result.ranked,false);assert.equal(p.progress[0].source_competitive.games,1);assert.equal(p.progress[0].combined_target.games,1);
});

test('nonempty deleted stable owner never falls back to email; orphan rows are explicitly archived',async()=>{
  const p=await buildCorePlan(snapshot({WordPack:[pack('orphan',{owner_user_id:'deleted-owner'})],GameHistory:[history('orphan',{player_user_id:'deleted-owner'})]}),target());
  assertPlanReady(p);assert.equal(p.packs.length,0);assert.equal(p.history.length,0);assert.equal(p.counts.archive_only,2);
});

test('ambiguous legacy row email blocks data assignment instead of guessing',async()=>{
  const a=user('a','101-001'),b=user('b','101-002');b.email=a.email;
  const p=await buildCorePlan(snapshot({User:[a,b],GameHistory:[history('email',{player_user_id:undefined})]}),target());assert.ok(p.issues.some(i=>i.code==='ambiguous_legacy_email_owner'));
});

test('existing history provenance prevents double count and detects lost or modified imported results',async()=>{
  const s=snapshot({GameHistory:[history('h1')]});const first=await buildCorePlan(s,target()),a=first.accounts[0];
  const t=target({history:first.history,imports:[{source_key:sourceKey,entity:'GameHistory',source_id:'h1',user_id:a.user_id,target_id:first.history[0].match_id}]});
  let p=await buildCorePlan(s,t);assertPlanReady(p);assert.equal(p.history.length,0);assert.equal(p.progress[0].combined_target.games,1);
  t.history=[];p=await buildCorePlan(s,t);assert.ok(p.issues.some(i=>i.code==='imported_history_missing'));
  t.history=[{...first.history[0],result:{...first.history[0].result,won:false}}];p=await buildCorePlan(s,t);assert.ok(p.issues.some(i=>i.code==='imported_history_changed'));
});

test('new target progress stays additive and source counter mirrors cannot inflate it',async()=>{
  const s=snapshot({GameHistory:[history('h1')]});s.entities.User[0].rating=99999;s.entities.User[0].games_played=999;
  const a=await mappedUUID(sourceKey,'User','a');
  const t=target({history:[{match_id:'new-target-match',player_id:a,result:{match_id:'new-target-match',player_user_id:a,match_type:'online',role:'detective',won:false,ranked:true,spy_count:1}}]});
  const p=await buildCorePlan(s,t);assertPlanReady(p);assert.equal(p.progress[0].source_competitive.rating,60);assert.equal(p.progress[0].combined_target.rating,40);assert.equal(p.progress[0].combined_target.games,2);assert.ok(p.warnings.some(i=>i.code==='source_stats_mirror_differs_from_history'));
});

test('deleted or edited imported packs are preserved through immutable provenance',async()=>{
  const id=await mappedUUID(sourceKey,'WordPack','p1'),uid=await mappedUUID(sourceKey,'User','a');
  const p=await buildCorePlan(snapshot({WordPack:[pack('p1')]}),target({imports:[{source_key:sourceKey,entity:'WordPack',source_id:'p1',user_id:uid,target_id:id}]}));assertPlanReady(p);assert.equal(p.packs.length,0);assert.equal(p.dispositions.find(d=>d.entity==='WordPack').reason,'already_imported_or_deleted');
});

test('current social decisions are never overwritten and source blocks require a valid blocker',async()=>{
  const a=await mappedUUID(sourceKey,'User','a'),b=await mappedUUID(sourceKey,'User','b');
  let p=await buildCorePlan(snapshot({Friendship:[friendship()]}),target({friendships:[{id:'10000000-0000-4000-8000-000000000002',requester_id:a,addressee_id:b,status:'blocked',blocked_by_id:b}]}));assert.ok(p.issues.some(i=>i.code==='existing_friendship_conflict'));
  p=await buildCorePlan(snapshot({Friendship:[friendship({status:'blocked',blocked_by_id:'someone-else'})]}),target());assert.ok(p.issues.some(i=>i.code==='invalid_friendship'));
});

test('social tombstone ledger prevents deleted comments and friendships from reappearing',async()=>{
  const s=snapshot({Friendship:[friendship()],ProfileComment:[{id:'c1',target_user_id:'a',author_user_id:'b',body:'Good game'}]});
  const first=await buildCorePlan(s,target());const bulkRows=first.provenance.filter(r=>['Friendship','ProfileComment'].includes(r.entity)).map(r=>({...r,source_key:sourceKey}));
  const p=await buildCorePlan(s,target({bulkRows}));assertPlanReady(p);assert.equal(p.friendships.length,0);assert.equal(p.comments.length,0);
});

test('malformed rows and duplicate IDs appear as blocking conflicts',async()=>{
  const p=await buildCorePlan(snapshot({WordPack:[pack('p1',{words:[]}),pack('p1')],ProfileComment:[{id:'c1',target_user_id:'a',author_user_id:'a',body:'self'}]}),target());
  assert.ok(p.issues.some(i=>i.code==='duplicate_source_id'));assert.ok(p.issues.some(i=>i.code==='invalid_word_pack'));assert.ok(p.issues.some(i=>i.code==='invalid_profile_comment'));
});

test('Auth provision validation requires UUID, shadow mailbox and server metadata together',async()=>{
  const p=await buildCorePlan(snapshot(),target()),a=p.accounts[0];
  const valid={id:a.user_id,role:'authenticated',email:a.shadow_email,app_metadata:{legacy_provider:'base44',legacy_identity_key:a.identity_key}};
  assert.doesNotThrow(()=>assertProvisionedAccount(a,valid));assert.throws(()=>assertProvisionedAccount(a,{...valid,email:'a@example.invalid'}));assert.throws(()=>assertProvisionedAccount(a,{...valid,app_metadata:{}}));assert.throws(()=>assertProvisionedAccount(a,{...valid,id:crypto.randomUUID()}));
});

test('login-only audit timestamps may advance but every profile and identity field stays guarded',async()=>{
  const baseline=await linkedTarget(),p=await buildCorePlan(snapshot(),baseline),current=structuredClone(baseline);
  current.profiles[0].updated_at='2026-10-19T13:00:00.000Z';current.links[0].verified_at='2026-10-19T13:00:00.000Z';
  assert.doesNotThrow(()=>assertCoreTargetUnchanged(p,current));
  for(const [field,value] of [['state','deleted'],['contact_email','new@example.invalid'],['spy_id','999-999'],['data',{display_name:'New choice'}],['created_at','2026-10-19T13:00:00.000Z']]) {
    const changed=structuredClone(current);changed.profiles[0][field]=value;
    assert.throws(()=>assertCoreTargetUnchanged(p,changed),/bulk_target_changed:profiles/);
  }
  for(const [field,value] of [['state','deleted'],['legacy_user_id','another-owner'],['source_origin','https://base44.app']]) {
    const changed=structuredClone(current);changed.links[0][field]=value;
    assert.throws(()=>assertCoreTargetUnchanged(p,changed),/bulk_target_changed:links/);
  }
});

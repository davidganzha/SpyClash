import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test,{after} from 'node:test';
import postgres from 'postgres';
import {prepareLegacyImport,applyLegacyImport,stageLegacySocialExport} from '../../supabase/functions/app-services/legacy-import.ts';
import {dispatchProfile} from '../../supabase/functions/app-services/profile.ts';
import {aggregateCompetitiveStats} from '../../supabase/functions/full-game-core/rules/competitive-stats.ts';

const url=new URL(process.env.DATABASE_URL||'');
assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
const db=postgres(url.toString(),{max:8,onnotice:()=>{}}),ids=[];
const origin='https://spyclash.com',appID='69a0e57fa939f578082f8091';
const token='synthetic-mocked-provider-token-not-a-real-credential';
const sourceKey=origin+'/'+appID;
async function actor(){
  const id=randomUUID(),legacyID='legacy-'+randomUUID();ids.push(id);
  await db`insert into auth.users(id,aud,role,email,created_at,updated_at) values(${id},'authenticated','authenticated',${id+'@accounts.invalid'},now(),now())`;
  await db`insert into app_private.legacy_links(user_id,legacy_user_id,verified_at,source_origin) values(${id},${legacyID},now(),${origin})`;
  return {id,email:id+'@example.test',contactEmail:id+'@private.test',full_name:'Provider name',metadata:{role:'admin'},legacyID};
}
const context=(tx,a)=>({tx,actor:a,now:new Date(),config:{}});
const apply=(a,s)=>db.begin(tx=>applyLegacyImport(context(tx,a),s));
function fixture(a,{packs,history,spyID,identity={}}={}){
  const user={id:a.legacyID,email:a.contactEmail,full_name:'Old full name',display_name:'Old operative',avatar:'🦊',language:'uk',spy_card_theme:'dossier',spy_card_badge:'ghost',spy_card_accent:'clearance_amber',spy_id:spyID,onboarding_completed:true,onboarding_version:2,role:'admin',rating:99999,...identity};
  const packRows=packs??[{id:'pack-'+randomUUID(),name:'Old pack',category:'Places',words:['Harbor','Station'],owner_email:a.contactEmail,created_date:'2024-01-01T00:00:00Z'}];
  const historyRows=history??[{id:'result-'+randomUUID(),player_user_id:a.legacyID,player_email:a.contactEmail,match_id:'old-match-'+randomUUID(),room_code:'ABC123',match_type:'online',role:'spy',winner:'spy',won:true,ranked:true,spy_count:1,created_date:'2024-01-01T00:00:00Z'}];
  const calls=[];
  const fetcher=async(raw,options)=>{
    const u=new URL(raw);calls.push({path:u.pathname,method:options.method||'GET'});
    assert.equal(u.origin,origin);assert.equal(options.redirect,'error');assert.equal(options.headers.Authorization,'Bearer '+token);
    if(u.pathname.endsWith('/entities/User/me'))return Response.json(user);
    if(u.pathname.endsWith('/functions/wordPackAction')){assert.deepEqual(JSON.parse(options.body),{action:'list',access_token:token});return Response.json(packRows);}
    assert.ok(u.pathname.endsWith('/entities/GameHistory'));
    const query=JSON.parse(u.searchParams.get('q')),skip=Number(u.searchParams.get('skip')),limit=Number(u.searchParams.get('limit'));
    const rows=historyRows.filter(r=>Object.entries(query).every(([k,v])=>r[k]===v));
    return Response.json(rows.slice(skip,skip+limit));
  };
  return {user,packs:packRows,history:historyRows,calls,fetcher};
}
const prepare=(a,f)=>prepareLegacyImport({origin,appID,accessToken:token,expectedLegacyID:a.legacyID},{fetch:f.fetcher,db});

after(async()=>{
  if(ids.length)await db.begin(async tx=>{
    for(const table of ['legacy_pending_social','legacy_import_history_stage','legacy_import_rows','legacy_import_runs'])await tx.unsafe(`delete from app_private.${table} where ${table==='legacy_pending_social'?'owner_id':'user_id'}=any($1::uuid[])`,[ids]);
    await tx`delete from public.app_profile_signals where recipient_user_id=any(${ids}::uuid[]) or profile_user_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.legacy_links where user_id=any(${ids}::uuid[])`;
    await tx`delete from app_private.profiles where user_id=any(${ids}::uuid[])`;
    await tx`delete from auth.users where id=any(${ids}::uuid[])`;
  });
  await db.end();
});

test('verified bootstrap preserves profile, SPY ID, owned packs and ranked history without copying admin privilege',async()=>{
  const a=await actor(),spyID='9'+String(Math.floor(Math.random()*100)).padStart(2,'0')+'-'+String(Math.floor(Math.random()*1000)).padStart(3,'0');
  const f=fixture(a,{spyID}),result=await apply(a,await prepare(a,f));
  assert.equal(result.complete,true);assert.equal(result.packs_imported,1);assert.equal(result.history_imported,1);
  const profile=await db.begin(tx=>dispatchProfile(context(tx,a),{action:'current'}));
  assert.equal(profile.spy_id,spyID);assert.equal(profile.display_name,'Old operative');assert.equal(profile.contact_email,a.contactEmail);
  assert.equal(profile.role,'user');assert.equal(profile.rating,60);assert.equal(profile.language,'uk');assert.equal(profile.onboarding_version,2);
  const [row]=await db`select * from full_game_private.history where player_id=${a.id}`;
  assert.equal(row.room_id,null);assert.equal(row.result.player_user_id,a.id);assert.equal(row.result.player_email,a.email);
  assert.match(row.match_id,/^[a-f0-9-]{36}$/);assert.notEqual(row.match_id,f.history[0].match_id);
  const [pack]=await db`select pack from full_game_private.word_packs where owner_id=${a.id}`;
  assert.deepEqual(pack.pack.words,['Harbor','Station']);assert.equal(pack.pack.owner_email,a.email);
  assert.ok(f.calls.every(c=>c.method==='GET'||c.path.endsWith('/functions/wordPackAction')));
});

test('relogin neither overwrites Supabase edits nor resurrects deleted imported packs; verified contact still refreshes',async()=>{
  const a=await actor(),f=fixture(a);await apply(a,await prepare(a,f));
  await db.begin(tx=>dispatchProfile(context(tx,a),{action:'update',display_name:'New chosen name',language:'es'}));
  await db`delete from full_game_private.word_packs where owner_id=${a.id}`;
  f.user.email='changed-'+a.contactEmail;f.user.display_name='Provider changed name';f.packs[0].words=['Changed old source'];
  const replay=await apply(a,await prepare(a,f));assert.equal(replay.complete,true);assert.equal(replay.packs_imported,0);
  assert.equal((await db`select 1 from full_game_private.word_packs where owner_id=${a.id}`).length,0);
  const [p]=await db`select data,contact_email from app_private.profiles where user_id=${a.id}`;
  assert.equal(p.data.display_name,'New chosen name');assert.equal(p.data.language,'es');assert.equal(p.contact_email,f.user.email);
  assert.equal(f.calls.filter(c=>c.path.endsWith('/functions/wordPackAction')).length,1);
});

test('large histories resume bounded pages, remain private until complete, and deduplicate across batches',async()=>{
  const a=await actor();
  const histories=Array.from({length:450},(_,i)=>({id:'history-'+i,player_user_id:a.legacyID,player_email:a.contactEmail,match_id:'match-'+i,room_code:'ABC123',match_type:'online',role:'detective',won:true,winner:'detectives',created_date:new Date(Date.UTC(2024,0,1,0,0,i)).toISOString()}));
  histories.push({...histories[0],id:'duplicate-result',created_date:'2025-01-01T00:00:00Z'});
  const f=fixture(a,{history:histories});
  const first=await apply(a,await prepare(a,f));assert.equal(first.complete,false);
  assert.equal((await db`select 1 from full_game_private.history where player_id=${a.id}`).length,0);
  assert.equal((await db`select 1 from app_private.legacy_import_history_stage where user_id=${a.id}`).length,400);
  let complete=false;
  for(let i=0;i<3&&!complete;i++)complete=(await apply(a,await prepare(a,f))).complete;
  assert.equal(complete,true);
  const rows=await db`select result from full_game_private.history where player_id=${a.id}`;
  assert.equal(rows.length,450);assert.equal(aggregateCompetitiveStats(rows.map(r=>r.result)).get(a.id).games,450);
  assert.equal((await db`select 1 from app_private.legacy_import_history_stage where user_id=${a.id}`).length,0);
});

test('email-only history remains visible but never gains ranked identity or rating',async()=>{
  const a=await actor(),f=fixture(a,{history:[{id:'email-only-'+randomUUID(),player_email:a.contactEmail,room_code:'ABC123',role:'spy',won:true,winner:'spy',ranked:true}]});
  await apply(a,await prepare(a,f));
  const [row]=await db`select result from full_game_private.history where player_id=${a.id}`;
  assert.equal(row.result.player_user_id,'');assert.equal(row.result.ranked,false);
  assert.equal(aggregateCompetitiveStats([row.result]).size,0);
});

test('forged, wrong-owner, conflicting-SPY and invalid-source imports fail without partial writes',async()=>{
  const a=await actor(),f=fixture(a);
  await assert.rejects(apply(a,JSON.parse(JSON.stringify(await prepare(a,f)))),e=>e.code==='legacy_import_verification_required');
  const b=await actor();await assert.rejects(apply(b,await prepare(a,f)),e=>e.code==='legacy_import_link_required');
  const malformed=fixture(a,{packs:[{id:'bad',name:'Bad',category:'X',words:[]}]});
  await assert.rejects(apply(a,await prepare(a,malformed)),e=>e.code==='legacy_import_invalid_pack');
  assert.equal((await db`select 1 from app_private.profiles where user_id=${a.id}`).length,0);
  const changed=fixture(a,{identity:{id:'different-account'}});
  await assert.rejects(prepare(a,changed),e=>e.code==='legacy_identity_changed');
  const conflict='8'+String(Math.floor(Math.random()*100)).padStart(2,'0')+'-'+String(Math.floor(Math.random()*1000)).padStart(3,'0');
  await apply(b,await prepare(b,fixture(b,{spyID:conflict})));
  await assert.rejects(apply(a,await prepare(a,fixture(a,{spyID:conflict}))),e=>e.code==='legacy_spy_id_conflict');
  assert.equal((await db`select 1 from app_private.legacy_import_runs where user_id=${a.id}`).length,0);
});

test('source access failure never reports empty account success and a retry uses the same mapping',async()=>{
  const a=await actor(),f=fixture(a);
  await assert.rejects(prepareLegacyImport({origin,appID,accessToken:token,expectedLegacyID:a.legacyID},{db,fetch:async(u,o)=>u.endsWith('/entities/User/me')?f.fetcher(u,o):new Response('',{status:503})}),e=>e.code==='legacy_import_source_unavailable'&&e.retryable);
  assert.equal((await db`select 1 from app_private.legacy_import_runs where user_id=${a.id}`).length,0);
  assert.equal((await apply(a,await prepare(a,f))).complete,true);
});

test('deleted account tombstone blocks import while deferred social export creates no invitations or peers',async()=>{
  const a=await actor(),f=fixture(a);await apply(a,await prepare(a,f));
  const exported={sourceKey,legacyID:a.legacyID,capturedAt:new Date(),rows:[{entity:'Friendship',id:'friend-'+randomUUID(),requester_id:a.legacyID,addressee_id:'unmigrated-peer',status:'accepted'}]};
  await assert.rejects(db.begin(tx=>stageLegacySocialExport(context(tx,a),exported)),e=>e.code==='legacy_social_import_forbidden');
  const staged=await db.begin(tx=>stageLegacySocialExport({...context(tx,a),config:{APP_ADMIN_USER_IDS:a.id,LEGACY_SOCIAL_IMPORT_ENABLED:'true'}},exported));
  assert.equal(staged.applied,0);assert.equal(staged.requires_review,true);
  const [pending]=await db`select state from app_private.legacy_pending_social where owner_id=${a.id}`;
  assert.equal(pending.state,'awaiting_identity_mapping');
  assert.equal((await db`select 1 from app_private.friendships where requester_id=${a.id} or addressee_id=${a.id}`).length,0);
  await db`update app_private.profiles set state='deleted',data='{}',contact_email='' where user_id=${a.id}`;
  await assert.rejects(apply(a,await prepare(a,f)),e=>e.code==='account_unavailable');
});

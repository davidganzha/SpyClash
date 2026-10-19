/** Local PostgreSQL rehearsal. Creates and removes its own database; never
 * touches the shared QA database or makes a provider/network Auth request. */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import postgres from 'postgres';
import {canonical,digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import {buildCorePlan,readCoreTarget,assertPlanReady} from './core.ts';
import {buildAncillaryPlan,readAncillaryTarget,assertAncillaryPlanReady} from './ancillary.ts';
import {createMigrationHandler} from './coordinator.ts';
import {rollbackJournal,readJournalState,buildDispositionManifest} from './archive.ts';
import {exchangeLegacySession} from '../../supabase/functions/legacy-session/service.ts';
import {ensureProfile} from '../../supabase/functions/app-services/profile.ts';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const privateMode=process.argv.includes('--private');
const evidence=resolve(root,'.local/bulk-migration');mkdirSync(evidence,{recursive:true,mode:0o700});
const status=spawnSync(resolve(root,'node_modules/.bin/supabase'),['status','-o','json'],{cwd:root,encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});
assert.equal(status.status,0,'Local Supabase must already be running');
const info=JSON.parse(status.stdout),url=new URL(info.DB_URL);
assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
const admin=postgres(url.href,{max:1,onnotice:()=>{}});
const database='spyclash_migration_191_'+crypto.randomUUID().replaceAll('-','').slice(0,12);
assert.match(database,/^spyclash_migration_191_[a-f0-9]{12}$/);
let db;const checks=[];let authCreates=0,networkCalls=0;
const pass=name=>checks.push(name);
const sort=rows=>rows.map(canonical).sort();

function syntheticSnapshot() {
  const entities={User:[{id:'rehearsal-a',email:'a@example.invalid',display_name:'A',spy_id:'101-101'},{id:'rehearsal-b',email:'b@example.invalid',display_name:'B',spy_id:'101-102'}],WordPack:[{id:'pack-1',owner_user_id:'rehearsal-a',owner_email:'a@example.invalid',name:'Places',category:'Places',words:['Port','Station']}],GameHistory:[{id:'history-1',player_user_id:'rehearsal-a',player_email:'a@example.invalid',match_id:'source-match-1',match_type:'online',role:'spy',winner:'spy',won:true,spy_count:1,ranked:true,created_date:'2026-10-18T12:00:00'}],Friendship:[{id:'friend-1',requester_id:'rehearsal-a',addressee_id:'rehearsal-b',status:'accepted'}],ProfileComment:[{id:'comment-1',target_user_id:'rehearsal-a',author_user_id:'rehearsal-b',body:'Good game!'}],NotificationAnnouncement:[],NotificationReadReceipt:[],PushNotificationEvent:[],CommunityReport:[],RoomInvite:[],GameRoom:[],BillingIdentityLifecycle:[]};
  return {version:1,source:{origin:'https://spyclash.com',appID:'69a0e57fa939f578082f8091'},capturedAt:new Date().toISOString(),verifiedAt:new Date().toISOString(),entities};
}
async function insertRows(table,rows) {
  if(!rows.length)return;
  const columns=(await db`select column_name from information_schema.columns where table_schema=${table.split('.')[0]} and table_name=${table.split('.')[1]} and is_generated='NEVER' order by ordinal_position`).map(r=>r.column_name);
  // Missing baseline columns must use their defaults, not jsonb_recordset NULLs.
  for(const row of rows) {
    const keys=columns.filter(k=>Object.hasOwn(row,k));
    await db.unsafe('insert into '+table+' ('+keys.map(k=>'"'+k+'"').join(',')+') select '+keys.map(k=>'r."'+k+'"').join(',')+' from jsonb_populate_record(null::'+table+',$1::jsonb) r',[row]);
  }
}

try {
  await admin.unsafe('create database '+database);
  url.pathname='/'+database;db=postgres(url.href,{max:3,onnotice:()=>{}});
  await db.unsafe("create schema auth; create table auth.users(id uuid primary key,email text,role text,raw_app_meta_data jsonb); create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz); create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;");
  for(const file of ['supabase/schemas/full_game_core.sql',...['foundation','services','billing-push','legacy-session','legacy-import'].map(n=>'supabase/functions/app-services/'+n+'-schema.sql'),'supabase/migrations/20261019102945_bulk_legacy_archive.sql'])await db.unsafe(readFileSync(resolve(root,file),'utf8'));
  pass('actual migration/application schemas applied to a new isolated database');

  let snapshot,baseline;
  if(privateMode) {
    snapshot=JSON.parse(readFileSync(resolve(evidence,'source-snapshot.json'),'utf8'));
    baseline=JSON.parse(readFileSync(resolve(evidence,'target-baseline.json'),'utf8'));
  } else {
    snapshot=syntheticSnapshot();snapshot.digest=await digest(canonical(snapshot));
    baseline={};
  }
  const {digest:sourceHash,...sourceValue}=snapshot;assert.equal(await digest(canonical(sourceValue)),sourceHash);
  await insertRows('auth.users',baseline.authUsers||[]);
  const rooms=[...new Set((baseline.history||[]).map(r=>r.room_id).filter(Boolean))];
  for(let i=0;i<rooms.length;i++)await db`insert into full_game_private.rooms(id,code,state) values(${rooms[i]},${'Q'+String(i).padStart(5,'0')},'{}')`;
  const baselineTables={profiles:'app_private.profiles',links:'app_private.legacy_links',reservations:'app_private.legacy_session_accounts',imports:'app_private.legacy_import_rows',runs:'app_private.legacy_import_runs',packs:'full_game_private.word_packs',history:'full_game_private.history',friendships:'app_private.friendships',comments:'app_private.profile_comments',announcements:'app_private.notification_announcements',events:'app_private.notification_events',readReceipts:'app_private.notification_read_receipts',reports:'app_private.community_reports',bulkRows:'app_private.bulk_migration_rows',lifecycleJobs:'app_private.lifecycle_jobs'};
  for(const [key,table] of Object.entries(baselineTables))await insertRows(table,baseline[key]||[]);
  const initialCore=await readCoreTarget(db),initialAncillary=await readAncillaryTarget(db);
  // Exercise real MCP JSON timestamps, including microseconds, without converting
  // them to operator-local Date strings before plan creation.
  for(const key of Object.keys(initialCore))if(Array.isArray(baseline[key]))assert.deepEqual(sort(initialCore[key]),sort(baseline[key]),'MCP baseline matches PostgreSQL JSON for '+key);
  pass('private live baseline cloned with exact JSON timestamps and retained target data');
  let core=await buildCorePlan(snapshot,initialCore),ancillary=await buildAncillaryPlan(snapshot,core,initialAncillary);
  assertPlanReady(core);assertAncillaryPlanReady(ancillary);
  const plannedCoreCounts=structuredClone(core.counts);
  const originalCounts={profiles:initialCore.profiles.length,auth:initialCore.authUsers.length,links:initialCore.links.length,history:initialCore.history.length};
  const rowsInSource=Object.values(snapshot.entities).reduce((n,rows)=>n+rows.length,0);
  let failAuth=false,loseAck=false,createdLostAck=false;
  const mockAuth=async(raw,options)=>{
    networkCalls++;
    const u=new URL(raw);assert.equal(u.origin,'http://127.0.0.1:56321');
    assert.ok(u.pathname.startsWith('/auth/v1/admin/users'),'No email or session endpoint used while provisioning');
    if(options.method==='GET') {
      const id=u.pathname.split('/').at(-1),[user]=await db`select id,email,role,raw_app_meta_data as app_metadata from auth.users where id=${id}`;
      return user?Response.json(user):Response.json({error:'not_found'},{status:404});
    }
    assert.equal(options.method,'POST');assert.equal(u.pathname,'/auth/v1/admin/users');
    if(failAuth)return Response.json({error:'synthetic_auth_failure'},{status:503});
    const body=JSON.parse(options.body);assert.equal(body.email_confirm,true);assert.equal(body.password,undefined);assert.equal(body.phone,undefined);assert.match(body.email,/@accounts\.spyclash\.invalid$/);
    await db`insert into auth.users(id,email,role,raw_app_meta_data) values(${body.id},${body.email},'authenticated',${db.json(body.app_metadata)})`;authCreates++;
    if(loseAck&&!createdLostAck){createdLostAck=true;throw new Error('synthetic_lost_auth_ack');}
    return Response.json({id:body.id,email:body.email,role:'authenticated',app_metadata:body.app_metadata});
  };
  const handler=createMigrationHandler({db,origin:'http://127.0.0.1:56321',serviceKey:'local-mocked-server-key',fetch:mockAuth,now:()=>new Date(Date.parse(snapshot.verifiedAt)+1000)});
  let jobID,token;
  async function createJob() {
    jobID=crypto.randomUUID();token=crypto.randomUUID().replaceAll('-','')+crypto.randomUUID().replaceAll('-','');
    const payload={snapshot,core,ancillary,manifest:buildDispositionManifest(snapshot,core,ancillary)};
    await db`insert into app_private.bulk_migration_jobs(id,source_key,source_digest,source_content_digest,plan_digest,token_digest,token_expires_at,payload) values(${jobID},${core.sourceKey},${snapshot.digest},${await digest(canonical({source:snapshot.source,entities:snapshot.entities,schemas:snapshot.sourceSchemas}))},${await digest(canonical(payload))},${await digest(token)},clock_timestamp()+interval '1 hour','{}'::jsonb)`;
    const upload=(body,capability=token)=>handler(new Request('http://127.0.0.1/operator/upload',{method:'POST',headers:{'x-migration-token':capability,'x-migration-job':jobID,'content-type':'application/json'},body}));
    const payloadBytes=JSON.stringify(payload);
    assert.equal((await upload(payloadBytes,'0'.repeat(64))).status,401);
    assert.equal((await upload('{}')).status,409);
    assert.equal((await db`select payload from app_private.bulk_migration_jobs where id=${jobID}`)[0].payload.constructor,Object);
    assert.deepEqual((await db`select payload from app_private.bulk_migration_jobs where id=${jobID}`)[0].payload,{});
    const uploaded=await upload(payloadBytes);assert.equal(uploaded.status,200);assert.equal((await uploaded.json()).status,'uploaded');
    assert.equal((await upload(payloadBytes)).status,401,'sealed payload cannot be replaced');
  }
  const attest=async(age=0)=>db`update app_private.bulk_migration_jobs set source_attested_digest=source_content_digest,source_attested_at=${new Date(Date.parse(snapshot.verifiedAt)+1000-age)} where id=${jobID}`;
  const call=async(suppliedToken=token)=>{const r=await handler(new Request('http://127.0.0.1/operator',{method:'POST',headers:{'x-migration-token':suppliedToken,'content-type':'application/json'},body:JSON.stringify({job_id:jobID})}));return {status:r.status,body:await r.json()};};
  await createJob();pass('sealed HTTP upload rejects wrong token, wrong digest and replacement of a committed payload');
  const oversized=await handler(new Request('http://127.0.0.1/operator',{method:'POST',headers:{'x-migration-token':token,'content-type':'application/json'},body:'x'.repeat(300)}));assert.equal(oversized.status,400);
  assert.equal((await call('0'.repeat(64))).status,401);assert.equal(networkCalls,0);assert.equal((await readCoreTarget(db)).profiles.length,originalCounts.profiles);pass('incorrect operator capability and oversized requests perform no Auth or data action');
  const reserved=await call();assert.equal(reserved.body.status,'reserved',JSON.stringify(reserved));
  let current=await readCoreTarget(db);assert.equal(current.reservations.length,core.accounts.length);assert.equal(current.authUsers.length,originalCounts.auth);assert.equal(current.links.length,originalCounts.links);pass('reservations persist first without creating verified ownership or sessions');
  if(core.accounts.some(a=>a.needs_auth)) {
    failAuth=true;assert.equal((await call()).status,409);failAuth=false;
    assert.equal((await readCoreTarget(db)).authUsers.length,originalCounts.auth);pass('Auth failure leaves functional data unchanged and reservations resumable');
  }
  loseAck=true;
  for(let step=0;step<100;step++) {
    const users=(await readCoreTarget(db)).authUsers;if(core.accounts.every(a=>users.some(u=>u.id===a.user_id)))break;
    const r=await call();assert.equal(r.status,200);assert.equal(r.body.status,'provisioning');
  }
  assert.equal(authCreates,core.accounts.filter(a=>a.needs_auth).length);assert.equal((await db`select count(*)::int as n from auth.sessions`)[0].n,0);pass('bounded Auth provisioning recovers a lost create acknowledgement with one immutable UUID');
  assert.equal((await call()).body.status,'source_verification_required');await attest(61000);assert.equal((await call()).body.status,'source_verification_required');await attest();pass('missing or stale independent source attestation prevents functional apply');
  if(initialCore.profiles.length) {
    const before=initialCore.profiles[0];await db`update app_private.profiles set data=data||'{"display_name":"Synthetic newer edit"}'::jsonb where user_id=${before.user_id}`;
    const rejected=await call();assert.equal(rejected.status,409);assert.equal(rejected.body.error,'bulk_target_changed:profiles');
    assert.equal((await readCoreTarget(db)).history.length,originalCounts.history);
    await db`update app_private.profiles set data=${db.json(before.data)} where user_id=${before.user_id}`;pass('reviewed target drift rejects all functional writes');
  }
  // Fail at the LAST operation to prove core, ancillary and archive are atomic.
  await db.unsafe("create function app_private.rehearsal_archive_fail() returns trigger language plpgsql as $$ begin raise exception 'synthetic_archive_failure'; end $$; create trigger rehearsal_archive_fail before insert on app_private.bulk_migration_archive for each row execute function app_private.rehearsal_archive_fail();");
  assert.equal((await call()).status,409);current=await readCoreTarget(db);assert.equal(current.profiles.length,originalCounts.profiles);assert.equal(current.history.length,originalCounts.history);assert.equal((await db`select count(*)::int as n from app_private.bulk_migration_archive`)[0].n,0);
  await db.unsafe('drop trigger rehearsal_archive_fail on app_private.bulk_migration_archive; drop function app_private.rehearsal_archive_fail()');pass('archive failure rolls back the complete functional transaction');
  const applied=await call();assert.equal(applied.status,200);assert.equal(applied.body.status,'applied');assert.equal(applied.body.summary.archived_rows,rowsInSource);
  current=await readCoreTarget(db);assert.equal(current.profiles.length,originalCounts.profiles+core.counts.profiles_to_insert);assert.equal(current.history.length,originalCounts.history+core.history.length);assert.equal(current.links.length,originalCounts.links);
  for(const a of core.accounts){const r=current.reservations.find(x=>x.user_id===a.user_id);assert.equal(r.import_completed,true);if(a.needs_auth){assert.equal(r.state,'reserved');assert.equal(r.last_verified_at,null);}assert.equal(current.profiles.find(x=>x.user_id===a.user_id).spy_id,a.profile.spy_id);}
  for(const row of initialCore.history)assert.deepEqual(current.history.find(r=>r.match_id===row.match_id&&r.player_id===row.player_id),row);
  for(const row of initialCore.profiles)assert.deepEqual(current.profiles.find(r=>r.user_id===row.user_id),row);
  const archived=await db`select entity,source_id,source_digest,payload from app_private.bulk_migration_archive where job_id=${jobID}`;
  for(const row of archived){const source=snapshot.entities[row.entity].find(r=>r.id===row.source_id);assert.deepEqual(row.payload,source);assert.equal(row.source_digest,await digest(canonical(source)));}
  pass('all source records archived byte-semantically and all planned data/IDs applied with current data preserved');
  const afterJournal=await readJournalState(db),callsBeforeReplay=networkCalls;
  assert.equal((await call()).body.status,'applied');assert.equal(networkCalls,callsBeforeReplay);assert.deepEqual(await readJournalState(db),afterJournal);pass('applied job replay is idempotent and makes no Auth call');
  const replayCore=await buildCorePlan(snapshot,current),replayAncillary=await buildAncillaryPlan(snapshot,replayCore,await readAncillaryTarget(db));assertPlanReady(replayCore);assertAncillaryPlanReady(replayAncillary);
  assert.equal(replayCore.history.length+replayCore.packs.length+replayCore.friendships.length+replayCore.comments.length,0);assert.equal(replayAncillary.events.length+replayAncillary.announcements.length+replayAncillary.reports.length,0);pass('fresh planning respects provenance and cannot duplicate or resurrect imported content');
  const [job]=await db`select rollback_journal from app_private.bulk_migration_jobs where id=${jobID}`;
  const changedComment=core.comments[0];
  if(changedComment) {
    await db`update app_private.profile_comments set body='Synthetic newer edit' where id=${changedComment.id}`;
    await assert.rejects(db.begin(tx=>rollbackJournal(tx,job.rollback_journal.changes)),/rollback_newer_activity/);
    assert.equal((await readCoreTarget(db)).profiles.length,current.profiles.length);
    await db`update app_private.profile_comments set body=${changedComment.body} where id=${changedComment.id}`;pass('rollback refuses newer user activity atomically');
  }
  await db.begin(tx=>rollbackJournal(tx,job.rollback_journal.changes));
  await db`update app_private.bulk_migration_jobs set status='rolled_back' where id=${jobID}`;
  const rolled=await readCoreTarget(db);assert.deepEqual(sort(rolled.profiles),sort(initialCore.profiles));assert.deepEqual(sort(rolled.history),sort(initialCore.history));assert.equal(rolled.authUsers.length,current.authUsers.length);assert.equal(rolled.reservations.length,current.reservations.length);assert.equal((await call()).status,409);pass('rollback restores original data while retaining immutable Auth/reservation identity');

  // Reapply after rollback and exercise the real bridge code with a mocked
  // verified provider and mocked session transport. This tests identity adoption,
  // not a live human sign-in or real remote provider acceptance.
  core=await buildCorePlan(snapshot,rolled);ancillary=await buildAncillaryPlan(snapshot,core,await readAncillaryTarget(db));assertPlanReady(core);assertAncillaryPlanReady(ancillary);await createJob();assert.equal((await call()).body.status,'reserved');await attest();assert.equal((await call()).body.status,'applied');
  const dormant=core.accounts.find(a=>!a.existing_link);
  if(dormant) {
    const who=snapshot.entities.User.find(r=>r.id===dormant.legacy_user_id),sessionID=crypto.randomUUID(),credential='synthetic-verified-base44-session';let prepareCalls=0,providerCalls=0,sessionCalls=0;
    const deps={db,config:{SUPABASE_URL:'http://127.0.0.1:56321',SUPABASE_SERVICE_ROLE_KEY:'mock-service',SUPABASE_ANON_KEY:'mock-anon'},ensureProfile,prepareImport:async()=>{prepareCalls++;throw new Error('must not reimport complete bulk data');},fetch:async(raw,options)=>{
      const u=new URL(raw);
      if(u.origin==='https://spyclash.com'){providerCalls++;assert.ok(u.pathname.endsWith('/User/me'));assert.equal(options.headers.Authorization,'Bearer '+credential);return Response.json(who);}
      assert.equal(u.origin,'http://127.0.0.1:56321');
      const [user]=await db`select id,email,role,raw_app_meta_data as app_metadata from auth.users where id=${dormant.user_id}`;
      if(u.pathname==='/auth/v1/admin/users/'+dormant.user_id)return Response.json(user);
      if(u.pathname==='/auth/v1/admin/generate_link'){sessionCalls++;return Response.json({id:dormant.user_id,hashed_token:'synthetic-session-token-hash'});}
      if(u.pathname==='/auth/v1/verify'){
        await db`insert into auth.sessions(id,user_id) values(${sessionID},${dormant.user_id})`;
        const claims={sub:dormant.user_id,role:'authenticated',session_id:sessionID,exp:Math.floor(Date.now()/1000)+3600};
        return Response.json({user,access_token:'synthetic.'+btoa(JSON.stringify(claims))+'.signature',refresh_token:'synthetic-refresh',token_type:'bearer',expires_in:3600});
      }
      throw new Error('Unexpected bridge transport endpoint');
    }};
    const beforeHistory=(await readCoreTarget(db)).history.length;
    const session=await exchangeLegacySession(credential,deps);assert.equal(session.user.id,dormant.user_id);assert.equal(providerCalls,1);assert.equal(prepareCalls,0);assert.equal(sessionCalls,1);assert.equal((await readCoreTarget(db)).history.length,beforeHistory);
    const [linked]=await db`select user_id from app_private.legacy_links where legacy_user_id=${dormant.legacy_user_id}`;assert.equal(linked.user_id,dormant.user_id);pass('verified bridge adopts the reserved UUID and complete progress without reimporting');
  }
  const summary={mode:privateMode?'private-full-snapshot':'synthetic',passed:checks.length,checks,source_rows:rowsInSource,source_users:snapshot.entities.User.length,core_counts:plannedCoreCounts,ancillary_counts:ancillary.counts,result_profiles:originalCounts.profiles+plannedCoreCounts.profiles_to_insert,result_history:originalCounts.history+plannedCoreCounts.history_to_insert,auth_provisions:authCreates,remote_network_calls:0,production_mutations:0,isolated_database_removed:true};
  writeFileSync(resolve(evidence,privateMode?'rehearsal-private-summary.json':'rehearsal-synthetic-summary.json'),JSON.stringify(summary,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify(summary,null,2));
} catch(error) {
  const report={name:error?.name,code:error?.code,message:error?.message,stack:error?.stack,passed:checks.length,checks};
  writeFileSync(resolve(evidence,'rehearsal-failure.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
  console.error('Rehearsal failed; inspect private .local/bulk-migration/rehearsal-failure.json ('+(error?.code||error?.name||'unknown')+').');
  process.exitCode=1;
} finally {
  if(db)await db.end();
  await admin.unsafe('drop database if exists '+database+' with (force)');await admin.end();
}

import assert from 'node:assert/strict';
import test, {before, after} from 'node:test';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {prepareMainAccountDeletion, processMainAccountDeletionJobs} from '../../supabase/functions/app-services/main-account-deletion.ts';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {accountGate} from '../../supabase/functions/app-services/account-gate.ts';
import {createAppHandler} from '../../supabase/functions/app-services/handler.ts';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import {prepareDeletionReceipt,markDeletionReceiptReady,deletionReceiptStatus} from '../../../../base44/functions/deleteAccount/deletion-receipt.ts';

let db;
let authConfiguration;
const actors=[];
const token='fixture-only-legacy-credential-not-for-network';
const config={SUPABASE_URL:'http://127.0.0.1:56321',APP_MAIN_ACCOUNT_DELETION_ENABLED:'true',APP_DELETION_RECEIPT_SECRET:'09'.repeat(32)};
before(async()=>{
  const result=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});
  assert.equal(result.status,0);
  const info=JSON.parse(result.stdout),{DB_URL}=info,url=new URL(DB_URL);
  authConfiguration={SUPABASE_URL:info.API_URL,SUPABASE_ANON_KEY:info.ANON_KEY,SUPABASE_SERVICE_ROLE_KEY:info.SERVICE_ROLE_KEY};
  assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
  db=postgres(DB_URL,{max:5,onnotice:()=>{}});
  await db.unsafe(readFileSync('supabase/functions/app-services/foundation-schema.sql','utf8'));
});
after(async()=>{
  if(!db)return;
  for(const a of actors){
    await db`delete from app_private.main_account_deletions where user_id=${a.id}`;
    await executeApp(db,a,{service:'profile',action:'delete',request_id:crypto.randomUUID()});
    await db`delete from app_private.receipts where actor_id=${a.id}`;
    await db`delete from app_private.lifecycle_jobs where user_id=${a.id}`;
    await db`delete from app_private.legacy_links where user_id=${a.id}`;
    await db`delete from app_private.profiles where user_id=${a.id}`;
    await db`delete from auth.users where id=${a.id}`;
  }
  await db.end();
});
async function fixture(){
  const id=crypto.randomUUID(),a={id,email:id+'@example.test',contactEmail:'fixture@example.test',full_name:'Fixture',metadata:{}};
  actors.push(a);
  await db`insert into auth.users(id,aud,role,email) values(${id},'authenticated','authenticated',${id+'@example.test'})`;
  await executeApp(db,a,{service:'profile',action:'current'});
  await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${id},${'legacy-'+id},'https://spyclash.com',clock_timestamp())`;
  return {actor:a,body:{service:'profile',action:'delete',deletion_scope:'account',request_id:crypto.randomUUID(),base44_access_token:token},config};
}
function provider(input,remove=async()=>Response.json({success:true,manual_apple_revocation_required:true}),who={}){
  return async(url,options)=>{
    const body=options.body?JSON.parse(options.body):{};
    if(body.action==='deletion_capabilities')return Response.json({protocol:'spyclash-deletion-receipt-v1'});
    if(body.action==='deletion_status')return Response.json({complete:false,request_id:body.request_id,subject_hash:await (async()=>{const {digest}=await import('../../supabase/functions/app-services/integration-crypto.ts');return digest('spyclash-delete-user-v1:legacy-'+input.actor.id);})()});
    assert.equal(options.headers.Authorization,'Bearer '+token);
    assert.equal(options.redirect,'error');
    if(url.endsWith('/entities/User/me'))return Response.json({id:'legacy-'+input.actor.id,role:'user',...who});
    assert.equal(url,'https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/deleteAccount');
    assert.equal(body.request_id,input.body.request_id);assert.match(body.recovery_token,/^[a-f0-9]{64}$/);
    const response=await remove();
    if(!response.ok)return response;
    const value=await response.json();
    return Response.json({...value,deletion_receipt:{complete:true,request_id:body.request_id,subject_hash:await digest('spyclash-delete-user-v1:legacy-'+input.actor.id)}});
  };
}

test('main deletion is explicitly disabled and validates identity before fencing',async()=>{
  const input=await fixture();let calls=0;
  await assert.rejects(prepareMainAccountDeletion({...input,config:{}},{db,fetch:async()=>{calls++;throw Error();}}),e=>e.code==='account_deletion_unconfigured');
  assert.equal(calls,0);
  for(const secret of [undefined,'wrong','0'.repeat(63)]) {
    await assert.rejects(prepareMainAccountDeletion({...input,config:{...config,APP_DELETION_RECEIPT_SECRET:secret}},{db,fetch:async()=>{calls++;throw Error();}}),e=>e.code==='deletion_recovery_unconfigured');
  }
  assert.equal(calls,0);
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:provider(input,undefined,{id:'somebody-else'})}),e=>e.code==='legacy_owner_mismatch');
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:provider(input,undefined,{role:'admin'})}),e=>e.code==='account_deletion_admin_transfer_required');
  assert.equal((await db`select state from app_private.profiles where user_id=${input.actor.id}`)[0].state,'active');
  assert.equal((await db`select * from app_private.main_account_deletions where user_id=${input.actor.id}`).length,0);
});

test('old Base44 capability preflight carries no user authentication and never falls back to deletion',async()=>{
  const input=await fixture();let calls=0;
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:async(url,options)=>{
    calls++;
    assert.equal(options.headers.Authorization,undefined);assert.equal(options.headers.Cookie,undefined);
    assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');
    assert.deepEqual(JSON.parse(options.body),{action:'deletion_capabilities'});
    return Response.json({error:'unauthorized'},{status:401});
  }}),e=>e.code==='deletion_recovery_unconfigured');
  assert.equal(calls,1);
  assert.equal((await db`select state from app_private.profiles where user_id=${input.actor.id}`)[0].state,'active');
  assert.equal((await db`select * from app_private.main_account_deletions where user_id=${input.actor.id}`).length,0);
});

test('confirmed Base44 response gates Supabase purge and survives lost native acknowledgement',async()=>{
  const input=await fixture();let removed=0;
  const evidence=await prepareMainAccountDeletion(input,{db,fetch:provider(input,async()=>{removed++;return Response.json({success:true,manual_apple_revocation_required:true});})});
  await assert.rejects(db.begin(tx=>accountGate(tx,input.actor.id)),e=>e.code==='account_unavailable');
  const result=await executeApp(db,input.actor,input.body,input.config,evidence);
  assert.equal(result.status,200);assert.equal(result.body.original_account_deleted,true);assert.equal(result.body.manual_apple_revocation_required,true);
  const replayEvidence=await prepareMainAccountDeletion(input,{db,fetch:async()=>{throw Error('Must not reauthenticate deleted Base44 user');}});
  const replay=await executeApp(db,input.actor,{...input.body,base44_access_token:'rotated-not-persisted'},input.config,replayEvidence);
  assert.deepEqual(replay,result);assert.equal(removed,1);
  const [intent]=await db`select * from app_private.main_account_deletions where user_id=${input.actor.id}`;
  assert.equal(intent.phase,'complete');assert.equal(JSON.stringify(intent).includes(token),false);
});

test('lost provider acknowledgement remains pending; revoked token is never proof of erasure',async()=>{
  const input=await fixture();
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:provider(input,async()=>{throw Error('Lost final ACK');})}),e=>e.code==='account_deletion_pending'&&e.retryable);
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:async(_url,options)=>JSON.parse(options.body||'{}').action==='deletion_capabilities'?Response.json({protocol:'spyclash-deletion-receipt-v1'}):Response.json({error:'unauthorized'},{status:401})}),e=>e.code==='account_deletion_pending');
  await assert.rejects(db.begin(tx=>accountGate(tx,input.actor.id)),e=>e.code==='account_unavailable');
  await assert.rejects(executeApp(db,input.actor,{service:'profile',action:'delete',request_id:crypto.randomUUID()}),e=>e.code==='account_deletion_pending');
  const [intent]=await db`select * from app_private.main_account_deletions where user_id=${input.actor.id}`;
  assert.equal(intent.phase,'pending');assert.equal(intent.lease_id,null);
  assert.equal((await db`select * from app_private.lifecycle_jobs where user_id=${input.actor.id}`).length,0);
});

test('concurrent same-command deletion issues one provider write and forged evidence cannot purge',async()=>{
  const input=await fixture();let release,entered,removed=0;
  const wait=new Promise(r=>{release=r;}),started=new Promise(r=>{entered=r;});
  const first=prepareMainAccountDeletion(input,{db,fetch:provider(input,async()=>{removed++;entered();await wait;return Response.json({success:true});})});
  await started;
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:provider(input)}),e=>e.code==='account_deletion_pending');
  await assert.rejects(executeApp(db,input.actor,input.body,input.config,{actor:input.actor.id,requestID:input.body.request_id}),e=>e.code==='account_deletion_pending');
  release();const evidence=await first;
  assert.equal((await executeApp(db,input.actor,input.body,input.config,evidence)).status,200);assert.equal(removed,1);
});

test('real Auth HTTP handler retries a deleting profile and rejects unrelated access',async()=>{
  const input=await fixture();
  // Issue a real local Auth session for the exact fixture identity.
  const auth=async(path,body)=>fetch(authConfiguration.SUPABASE_URL+'/auth/v1'+path,{method:'POST',headers:{apikey:authConfiguration.SUPABASE_SERVICE_ROLE_KEY,Authorization:'Bearer '+authConfiguration.SUPABASE_SERVICE_ROLE_KEY,'Content-Type':'application/json'},body:JSON.stringify(body)});
  await db`delete from auth.users where id=${input.actor.id}`;
  const created=await auth('/admin/users',{id:input.actor.id,email:input.actor.id+'@example.test',email_confirm:true});
  assert.equal(created.status,200);
  const link=await (await auth('/admin/generate_link',{type:'magiclink',email:input.actor.id+'@example.test'})).json();
  const session=await (await auth('/verify',{type:'email',token_hash:link.hashed_token})).json();
  assert.ok(session.access_token);
  let writes=0;
  const handler=createAppHandler({db,config:{...config,...authConfiguration},authenticate:async(token)=>{
    const response=await fetch(authConfiguration.SUPABASE_URL+'/auth/v1/user',{headers:{apikey:authConfiguration.SUPABASE_ANON_KEY,Authorization:'Bearer '+token}});
    assert.equal(response.status,200);return response.json();
  },fetch:async(url,options)=>{
    if(new URL(url).origin===authConfiguration.SUPABASE_URL)return fetch(url,options);
    return provider(input,async()=>{writes++;return writes===1?Response.json({error:'retry'},{status:503}):Response.json({success:true});})(url,options);
  }});
  const server=createServer(async(req,res)=>{
    const chunks=[];for await(const chunk of req)chunks.push(chunk);
    const response=await handler(new Request('http://127.0.0.1/app-services',{method:req.method,headers:req.headers,body:Buffer.concat(chunks)}));
    res.writeHead(response.status,Object.fromEntries(response.headers));res.end(await response.text());
  });
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const invoke=async(body)=>{
    const response=await fetch('http://127.0.0.1:'+server.address().port,{method:'POST',headers:{Authorization:'Bearer '+session.access_token,'Content-Type':'application/json'},body:JSON.stringify(body)});
    return {status:response.status,body:await response.json()};
  };
  try{
    assert.equal((await invoke(input.body)).body.code,'account_deletion_pending');
    const blocked=await invoke({service:'profile',action:'current'});
    assert.equal(blocked.status,403);assert.equal(blocked.body.code,'account_unavailable');
    const retry=await invoke(input.body);
    assert.equal(retry.status,200);assert.equal(retry.body.original_account_deleted,true);assert.equal(writes,2);
  }finally{server.close();await once(server,'close');}
});

class ReceiptStore {
  rows=[];
  async filter(query){return this.rows.filter(row=>Object.entries(query).every(([key,value])=>row[key]===value)).map(row=>({...row}));}
  async create(value){const row={...value,id:crypto.randomUUID(),created_date:new Date().toISOString()};this.rows.push(row);return {...row};}
  async updateMany(query,update){let updated=0;for(const row of this.rows)if(Object.entries(query).every(([key,value])=>row[key]===value)){Object.assign(row,update.$set);updated++;}return {updated};}
}
function lostAckProvider(input){
  const receipts=new ReceiptStore(),users=new ReceiptStore();users.rows=[{id:'legacy-'+input.actor.id}];
  let writes=0;
  return {receipts,get writes(){return writes;},fetch:async(url,options)=>{
    assert.ok(url.startsWith('https://spyclash.com/api/apps/69a0e57fa939f578082f8091/'));
    const body=options.body?JSON.parse(options.body):{};
    if(body.action==='deletion_capabilities')return Response.json({protocol:'spyclash-deletion-receipt-v1'});
    if(body.action==='deletion_status'){
      assert.equal(options.headers.Authorization,undefined,'Recovery cannot depend on a revoked user token');
      return Response.json(await deletionReceiptStatus(receipts,users,body));
    }
    if(url.endsWith('/entities/User/me'))return users.rows.length?Response.json({...users.rows[0],role:'user'}):Response.json({error:'unauthorized'},{status:401});
    writes++;
    const receipt=await prepareDeletionReceipt(receipts,users.rows[0].id,body);
    await markDeletionReceiptReady(receipts,receipt,true);users.rows=[];
    throw Error('Provider completed deletion; final HTTP response lost');
  }};
}
test('native retry after lost Base44 ACK consumes exact receipt without a live legacy token',async()=>{
  const input=await fixture(),remote=lostAckProvider(input);
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:remote.fetch}),e=>e.code==='account_deletion_pending');
  const evidence=await prepareMainAccountDeletion({...input,body:{...input.body,base44_access_token:''}},{db,fetch:remote.fetch});
  const result=await executeApp(db,input.actor,input.body,input.config,evidence);
  assert.equal(result.body.original_account_deleted,true);assert.equal(remote.writes,1);
  assert.ok(remote.receipts.rows.every(row=>row.user_id===''));
});
test('maintenance completes lost-ACK deletion without any native session or user bearer',async()=>{
  const input=await fixture(),remote=lostAckProvider(input);
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:remote.fetch}),e=>e.code==='account_deletion_pending');
  const result=await processMainAccountDeletionJobs(db,input.config,remote.fetch);
  assert.equal(result.completed,1);
  assert.equal((await db`select state from app_private.profiles where user_id=${input.actor.id}`)[0].state,'deleted');
  assert.equal((await db`select phase from app_private.main_account_deletions where user_id=${input.actor.id}`)[0].phase,'complete');
  assert.equal(remote.writes,1);
});

test('rotating the recovery secret cannot falsely confirm a pending account deletion',async()=>{
  const input=await fixture(),remote=lostAckProvider(input);
  await assert.rejects(prepareMainAccountDeletion(input,{db,fetch:remote.fetch}),e=>e.code==='account_deletion_pending');
  const wrong=await processMainAccountDeletionJobs(db,{...input.config,APP_DELETION_RECEIPT_SECRET:'11'.repeat(32)},remote.fetch);
  assert.equal(wrong.completed,0);
  assert.equal((await db`select state from app_private.profiles where user_id=${input.actor.id}`)[0].state,'deleting');
  await db`update app_private.main_account_deletions set next_attempt_at=clock_timestamp() where user_id=${input.actor.id}`;
  assert.equal((await processMainAccountDeletionJobs(db,input.config,remote.fetch)).completed,1);
});

import assert from 'node:assert/strict';
import test,{before,after} from 'node:test';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {redactArchiveValue,redactRollbackJournal,verifiedArchiveAliases} from '../../supabase/functions/app-services/deletion-archive.ts';
import {signedArchiveErasureRequest,verifiedArchiveErasureProof} from '../../supabase/functions/app-services/deletion-archive-proof.ts';
import {verifyArchiveErasureRequest,archiveProofMessage} from '../../../../base44/functions/deleteAccount/deletion-archive-proof.ts';
import {prepareDeletionReceipt,recordDeletionArchiveProof,markDeletionReceiptReady,deletionReceiptStatus} from '../../../../base44/functions/deleteAccount/deletion-receipt.ts';
import {deleteHistoricalOwnedContent} from '../../../../base44/functions/deleteAccount/historical-content-cleanup.ts';
import {prepareMainAccountDeletion} from '../../supabase/functions/app-services/main-account-deletion.ts';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {digest,canonical} from '../../supabase/functions/app-services/integration-crypto.ts';

const source='https://spyclash.com/69a0e57fa939f578082f8091';
const config={SUPABASE_URL:'http://127.0.0.1:56321',APP_MAIN_ACCOUNT_DELETION_ENABLED:'true',APP_DELETION_RECEIPT_SECRET:'21'.repeat(32),APP_DELETION_ARCHIVE_SECRET:'22'.repeat(32)};
const subject={userID:'subject-native',legacyID:'subject-legacy',aliases:new Set(['old@example.test']),appleKeys:new Set(['apple-email:'+'a'.repeat(64)]),appleRecordIDs:new Set(['owned-token']),lifecycleKeys:new Set()};
test('shared room preserves other participants and removes own nested fields/maps',()=>{
  const row={id:'room',players:[{user_id:'subject-legacy',email:'old@example.test',display_name:'Remove me'},{user_id:'other',email:'keep@example.test',display_name:'Keep me'}],host_email:'old@example.test',cards_read:{'old@example.test':true,'keep@example.test':false},participant_user_ids:['subject-legacy','other']};
  const result=redactArchiveValue(row,subject,'GameRoom');
  assert.deepEqual(result,{id:'room',players:[row.players[1]],cards_read:{'keep@example.test':false},participant_user_ids:['other']});
});
test('foreign Apple binding outranks matching selector in snapshot and rollback copies',()=>{
  const foreign={id:'foreign-token',user_id:'other',identity_key:[...subject.appleKeys][0],refresh_token_ciphertext:'keep-foreign-ciphertext'};
  assert.deepEqual(redactArchiveValue(foreign,subject,'AppleSignInCredential'),foreign);
  const journal={changes:[{table:'archive',keys:['id'],before:foreign,after:foreign}]};
  assert.deepEqual(redactRollbackJournal(journal,subject),journal);
  assert.equal(redactArchiveValue({...foreign,user_id:''},subject,'AppleSignInCredential'),undefined);
});
test('archive aliases require immutable User ID and reject a reused email',()=>{
  assert.deepEqual(verifiedArchiveAliases([{id:'own',email:'OLD@example.test'},{id:'own',email:'new@example.test'},{id:'other',email:'keep@example.test'}],'own'),['new@example.test','old@example.test']);
  assert.throws(()=>verifiedArchiveAliases([{id:'own',email:'old@example.test'},{id:'other',email:'OLD@example.test'}],'own'),e=>e.code==='archive_alias_owner_conflict');
});
test('rollback entries that contain subject data are removed; unrelated entries remain exact',()=>{
  const own={table:'app_private.profiles',keys:['user_id'],before:{user_id:subject.userID,data:{secret:'old'}},after:{user_id:subject.userID,data:{secret:'new'}}};
  const other={table:'app_private.profiles',keys:['user_id'],before:null,after:{user_id:'other',data:{display_name:'Keep'}}};
  assert.deepEqual(redactRollbackJournal({changes:[own,other]},subject),{changes:[other]});
});
async function signedBody(aliases=['old@example.test']) {
  const request_id=crypto.randomUUID(),subject_hash=await digest('spyclash-delete-user-v1:legacy'),timestamp=Date.now();
  const key=await crypto.subtle.importKey('raw',Buffer.from(config.APP_DELETION_ARCHIVE_SECRET,'hex'),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const signature=Buffer.from(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(archiveProofMessage(request_id,subject_hash,aliases,timestamp)))).toString('hex');
  return {request_id,recovery_token:'23'.repeat(32),archive_erasure_request:{aliases,subject_hash,timestamp,signature}};
}
const deriveKey=async(alias)=>'apple-email:'+await digest('test-historical-key:'+alias);
test('archive selector proof requires independent server signature, exact subject/request and freshness',async()=>{
  const body=await signedBody(),hash=body.archive_erasure_request.subject_hash;
  const options={secret:config.APP_DELETION_ARCHIVE_SECRET,deriveKey};
  assert.deepEqual((await verifyArchiveErasureRequest(body,hash,options)).apple_identity_keys,[await deriveKey('old@example.test')]);
  for(const changed of [
    {...body,request_id:crypto.randomUUID()},
    {...body,archive_erasure_request:{...body.archive_erasure_request,aliases:['foreign@example.test']}},
    {...body,archive_erasure_request:{...body.archive_erasure_request,timestamp:Date.now()-600_000}},
    {...body,archive_erasure_request:{...body.archive_erasure_request,subject_hash:'a'.repeat(64)}},
  ])await assert.rejects(verifyArchiveErasureRequest(changed,hash,options),e=>e.code==='deletion_archive_request_invalid');
  await assert.rejects(verifyArchiveErasureRequest(body,hash,{...options,secret:'24'.repeat(32)}),e=>e.code==='deletion_archive_request_invalid');
});
test('a historical email reassigned to another current Base44 User cannot authorize selectors',async()=>{
  const body=await signedBody();let derived=0;
  await assert.rejects(verifyArchiveErasureRequest(body,body.archive_erasure_request.subject_hash,{secret:config.APP_DELETION_ARCHIVE_SECRET,deriveKey:async()=>{derived++;return 'unused';},users:{filter:async()=>[{id:'other-user'}]}}),e=>e.code==='deletion_archive_alias_reassigned');
  assert.equal(derived,0);
});
test('completed proof survives lost ACK followed by email reassignment without deriving new selectors',async()=>{
  const body=await signedBody(),hash=body.archive_erasure_request.subject_hash;
  const proof=await verifyArchiveErasureRequest(body,hash,{secret:config.APP_DELETION_ARCHIVE_SECRET,deriveKey});
  const recovered=await verifyArchiveErasureRequest(body,hash,{secret:config.APP_DELETION_ARCHIVE_SECRET,completedProof:proof,
    deriveKey:async()=>{throw Error('must use already verified historical proof');},users:{filter:async()=>{throw Error('must not infer new ownership');}}});
  assert.deepEqual(recovered,proof);
});
test('historical email-only content is erased, foreign stable owners with same email survive',async()=>{
  for(const [ownerField,emailField] of [['player_user_id','player_email'],['owner_user_id','owner_email']]) {
    const records=[{id:'old-unbound',[emailField]:'old@example.test'},{id:'own-id',[ownerField]:'own',[emailField]:'unknown@example.test'},
      {id:'foreign',[ownerField]:'other',[emailField]:'old@example.test'},{id:'unrelated',[emailField]:'keep@example.test'}];
    const store={rows:records,filter:async function(query,_sort,limit,skip){return this.rows.filter(r=>Object.entries(query).every(([k,v])=>r[k]===v)).slice(skip,skip+limit);},delete:async function(id){this.rows=this.rows.filter(r=>r.id!==id);}};
    await deleteHistoricalOwnedContent(store,'own',ownerField,emailField,['old@example.test','new@example.test']);
    assert.deepEqual(store.rows,records.slice(2));
    await deleteHistoricalOwnedContent(store,'own',ownerField,emailField,['old@example.test','new@example.test']);
    assert.deepEqual(store.rows,records.slice(2));
  }
});
class Store {
  rows=[];loseUpdate=false;
  async filter(query){return this.rows.filter(row=>Object.entries(query).every(([k,v])=>row[k]===v)).map(row=>({...row}));}
  async create(value){const row={...value,id:crypto.randomUUID(),created_date:new Date().toISOString()};this.rows.push(row);return {...row};}
  async updateMany(query,update){let updated=0;for(const row of this.rows)if(Object.entries(query).every(([k,v])=>row[k]===v)){Object.assign(row,update.$set);updated++;}if(this.loseUpdate)throw Error('lost');return {updated};}
}
test('receipt preserves selectors through lost write ACK and completed User deletion',async()=>{
  const body=await signedBody(),store=new Store(),users=new Store(),receipt=await prepareDeletionReceipt(store,'legacy',body);
  const proof=await verifyArchiveErasureRequest(body,body.archive_erasure_request.subject_hash,{secret:config.APP_DELETION_ARCHIVE_SECRET,deriveKey});
  store.loseUpdate=true;await recordDeletionArchiveProof(store,body,{...proof,apple_record_ids:['old-record']});
  await markDeletionReceiptReady(store,receipt,false);
  const result=await deletionReceiptStatus(store,users,body);assert.equal(result.complete,true);
  assert.deepEqual(result.erasure_proof.apple_record_ids,['old-record']);assert.equal(store.rows[0].user_id,'');
  assert.ok(!JSON.stringify(store.rows).includes('old@example.test'),'receipt must not recreate deleted raw contact data');
  await assert.rejects(recordDeletionArchiveProof(store,{...body,recovery_token:'24'.repeat(32)},proof),e=>e.code==='deletion_receipt_unavailable');
});

let db;const fixtures=[];
before(async()=>{
  const result=spawnSync('node_modules/.bin/supabase',['status','-o','json'],{encoding:'utf8',env:{...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});
  assert.equal(result.status,0);const url=new URL(JSON.parse(result.stdout).DB_URL);assert.equal(url.hostname,'127.0.0.1');assert.equal(url.port,'56322');
  db=postgres(url.href,{max:5,onnotice:()=>{}});await db.unsafe(readFileSync('supabase/functions/app-services/foundation-schema.sql','utf8'));
});
after(async()=>{
  if(!db)return;
  try{for(const f of fixtures){
    await db`delete from app_private.bulk_migration_archive where job_id=${f.job}`;
    for(const row of f.rows)await db`delete from app_private.bulk_migration_rows where source_key=${source} and entity=${row.entity} and source_id=${row.payload.id}`;
    await db`delete from app_private.bulk_migration_jobs where id=${f.job}`;
    await db`delete from app_private.main_account_deletions where user_id=${f.actor.id}`;
    await db`delete from app_private.legacy_links where user_id=${f.actor.id}`;
    await executeApp(db,f.actor,{service:'profile',action:'delete',request_id:crypto.randomUUID()});
    await db`delete from app_private.receipts where actor_id=${f.actor.id}`;await db`delete from app_private.lifecycle_jobs where user_id=${f.actor.id}`;
    await db`delete from app_private.profiles where user_id=${f.actor.id}`;await db`delete from auth.users where id=${f.actor.id}`;
  }}finally{await db.end();}
});
async function fixture(){
  const id=crypto.randomUUID(),legacy='archive-legacy-'+id,job=crypto.randomUUID(),other='archive-other-'+id;
  const old=id+'-old@example.test',current=id+'-new@example.test',keep=id+'-other@example.test';
  const actor={id,email:id+'@example.test',contactEmail:current,full_name:'Fixture',metadata:{}};
  const f={actor,legacy,job,other,old,current,keep,rows:[]};fixtures.push(f);
  await db`insert into auth.users(id,aud,role,email) values(${id},'authenticated','authenticated',${actor.email})`;
  await executeApp(db,actor,{service:'profile',action:'current'});
  await db`insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values(${id},${legacy},'https://spyclash.com',clock_timestamp())`;
  f.rows=[
    {entity:'User',payload:{id:legacy,email:old,full_name:'Erase name'}},
    {entity:'User',payload:{id:other,email:keep,full_name:'Keep name',friends:[old,keep]}},
    {entity:'AppleSignInCredential',payload:{id:'apple-own-'+id,user_id:'',identity_key:await deriveKey(old),refresh_token_ciphertext:'erase-token-'+id}},
    {entity:'AppleSignInCredential',payload:{id:'apple-other-'+id,user_id:other,identity_key:await deriveKey(old),refresh_token_ciphertext:'keep-token-'+id}},
    {entity:'GameHistory',payload:{id:'history-own-'+id,player_email:old,word:'private-word'}},
    {entity:'GameHistory',payload:{id:'history-other-'+id,player_user_id:other,player_email:keep,word:'keep-word'}},
    {entity:'GameRoom',payload:{id:'room-'+id,players:[{user_id:legacy,email:old,display_name:'Erase name'},{user_id:other,email:keep,display_name:'Keep name'}],host_email:old}},
  ];
  const entities={};for(const row of f.rows)(entities[row.entity]??=[]).push(row.payload);
  const foreignJournal={table:'app_private.profiles',keys:['user_id'],before:null,after:{user_id:other,data:{email:keep,name:'Keep'}}};
  f.foreignJournal=foreignJournal;
  const payload={snapshot:{source:{origin:'https://spyclash.com',appID:'69a0e57fa939f578082f8091'},entities},core:{accounts:[{legacy_user_id:legacy,user_id:id,profile:{email:old}},{legacy_user_id:other,user_id:other,profile:{email:keep}}],baseline:{authUsers:[{id,email:actor.email},{id:other,email:keep}]}},manifest:f.rows.map(r=>({entity:r.entity,source_id:r.payload.id}))};
  const journal={changes:[{table:'app_private.profiles',keys:['user_id'],before:null,after:{user_id:id,data:{name:'Erase name',email:old}}},foreignJournal]};
  await db`insert into app_private.bulk_migration_jobs(id,source_key,source_digest,source_content_digest,plan_digest,token_digest,token_expires_at,payload,status,rollback_journal) values(${job},${source},${'a'.repeat(64)},${'b'.repeat(64)},${'c'.repeat(64)},${'d'.repeat(64)},clock_timestamp()+interval '1 hour',${db.json(payload)},'applied',${db.json(journal)})`;
  for(const row of f.rows){
    await db`insert into app_private.bulk_migration_archive(job_id,source_key,entity,source_id,source_digest,payload,disposition,reason) values(${job},${source},${row.entity},${row.payload.id},${'a'.repeat(64)},${db.json(row.payload)},'archive_only','fixture')`;
    await db`insert into app_private.bulk_migration_rows(source_key,entity,source_id,source_digest,disposition) values(${source},${row.entity},${row.payload.id},${'a'.repeat(64)},'archive_only')`;
  }
  return f;
}
function provider(f){return async(url,options)=>{
  const body=options.body?JSON.parse(options.body):{};
  if(body.action==='deletion_capabilities')return Response.json({protocol:'spyclash-deletion-receipt-v2'});
  if(url.endsWith('/entities/User/me'))return Response.json({id:f.legacy,role:'user',email:f.current});
  const proof=await verifyArchiveErasureRequest(body,await digest('spyclash-delete-user-v1:'+f.legacy),{secret:config.APP_DELETION_ARCHIVE_SECRET,deriveKey,users:{filter:async({email})=>email===f.current?[{id:f.legacy,email}]:[]}});
  return Response.json({success:true,deletion_receipt:{complete:true,request_id:body.request_id,subject_hash:await digest('spyclash-delete-user-v1:'+f.legacy),erasure_proof:proof}});
};}
test('real SQL deletion erases historical email/unbound Apple copies and preserves mixed archive + rollback peer',async()=>{
  const f=await fixture(),body={service:'profile',action:'delete',deletion_scope:'account',request_id:crypto.randomUUID(),base44_access_token:'archive-fixture-credential-not-network'};
  const input={actor:f.actor,body,config},evidence=await prepareMainAccountDeletion(input,{db,fetch:provider(f)});
  assert.equal((await executeApp(db,f.actor,body,config,evidence)).body.original_account_deleted,true);
  const remaining=await db`select entity,payload from app_private.bulk_migration_archive where job_id=${f.job}`;
  assert.equal(remaining.length,4);
  assert.ok(remaining.some(r=>r.payload.refresh_token_ciphertext==='keep-token-'+f.actor.id));
  assert.ok(!JSON.stringify(remaining).includes('erase-token-'+f.actor.id));assert.ok(!JSON.stringify(remaining).includes(f.old));
  const [job]=await db`select * from app_private.bulk_migration_jobs where id=${f.job}`;
  assert.deepEqual(job.rollback_journal,{changes:[f.foreignJournal]});
  assert.ok(!JSON.stringify(job.payload).includes(f.old));assert.ok(JSON.stringify(job.payload).includes('Keep name'));
  assert.equal((await db`select token_expires_at<=clock_timestamp() as expired from app_private.bulk_migration_jobs where id=${f.job}`)[0].expired,true);assert.equal(job.source_attested_at,null);
  assert.deepEqual((await db`select erasure_proof from app_private.main_account_deletions where user_id=${f.actor.id}`)[0].erasure_proof,{});
  const restored={...body,request_id:crypto.randomUUID()};
  const retryEvidence=await prepareMainAccountDeletion({...input,body:restored},{db,fetch:async()=>{throw Error('must not call provider');}});
  assert.equal((await executeApp(db,f.actor,restored,config,retryEvidence)).body.original_account_deleted,true);
});
test('missing/forged provider selectors cannot commit full deletion',async()=>{
  const f=await fixture(),body={service:'profile',action:'delete',deletion_scope:'account',request_id:crypto.randomUUID(),base44_access_token:'archive-fixture-credential-not-network'};
  await assert.rejects(prepareMainAccountDeletion({actor:f.actor,body,config},{db,fetch:async(url,options)=>{
    const response=await provider(f)(url,options),value=await response.json();if(value.deletion_receipt)delete value.deletion_receipt.erasure_proof;return Response.json(value);
  }}),e=>e.code==='account_deletion_pending');
  assert.equal((await db`select count(*)::int as count from app_private.bulk_migration_archive where job_id=${f.job}`)[0].count,f.rows.length);
  assert.equal((await db`select phase from app_private.main_account_deletions where user_id=${f.actor.id}`)[0].phase,'pending');
  await assert.rejects(verifiedArchiveErasureProof({version:1,archive_alias_digest:await digest(JSON.stringify(['foreign@example.test'])),apple_identity_keys:[],apple_record_ids:[]},[f.old]),e=>e.code==='deletion_archive_proof_unavailable');
});
test('active archive migration blocks deletion before fencing or sending provider delete',async()=>{
  const f=await fixture();await db`update app_private.bulk_migration_jobs set status='reserved' where id=${f.job}`;
  const body={service:'profile',action:'delete',deletion_scope:'account',request_id:crypto.randomUUID(),base44_access_token:'archive-fixture-credential-not-network'};
  let deletes=0;
  await assert.rejects(prepareMainAccountDeletion({actor:f.actor,body,config},{db,fetch:async(url,options)=>{
    const request=options.body?JSON.parse(options.body):{};
    if(!request.action&&!url.endsWith('/entities/User/me'))deletes++;
    return provider(f)(url,options);
  }}),e=>e.code==='archive_migration_busy');
  assert.equal(deletes,0);assert.equal((await db`select state from app_private.profiles where user_id=${f.actor.id}`)[0].state,'active');
  assert.equal((await db`select 1 from app_private.main_account_deletions where user_id=${f.actor.id}`).length,0);
});

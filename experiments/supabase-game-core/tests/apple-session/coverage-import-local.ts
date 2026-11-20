import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.9';
import {createAuthAPI} from '../../supabase/functions/apple-session/service.ts';
import {digest} from '../../supabase/functions/apple-session/crypto.ts';

const env=Deno.env.toObject(),url=new URL(env.SUPABASE_DB_URL||'');
if(env.SUPABASE_URL!=='http://127.0.0.1:56321'||url.hostname!=='127.0.0.1'||url.port!=='56322'||url.pathname!=='/postgres'||!['postgres:','postgresql:'].includes(url.protocol)||!env.SUPABASE_ANON_KEY||!env.SUPABASE_SERVICE_ROLE_KEY)throw Error('Dedicated loopback Auth/DB required; cloud targets are forbidden.');
const db=postgres(url.href,{max:1,prepare:false,onnotice:()=>{}});
const auth=createAuthAPI({origin:env.SUPABASE_URL,anonKey:env.SUPABASE_ANON_KEY,serviceRoleKey:env.SUPABASE_SERVICE_ROLE_KEY});
const root=new URL('../../../../',import.meta.url).pathname;
const temp=await Deno.makeTempDir({dir:root+'.local/apple-new-users-251',prefix:'coverage-sql-'});
const targets:any[]=[],owners:any[]=[],users:any[]=[],records:any[]=[];
const rights=Object.fromEntries(['AppStoreAccount','MembershipGrant','Entitlement','AiGenerationUsage','GenerationReward','GenerationRewardEnrollment'].map(x=>[x,[]]));
let passed=0;
async function compile(receipt:boolean,out:string){
 const args=[root+'scripts/prepare-apple-coverage-import.py','--input',temp+'/input.json','--output-dir',temp+'/'+out];
 if(receipt)args.push('--receipt',temp+'/receipt.json');
 const result=await new Deno.Command('python3',{args,stdout:'piped',stderr:'piped'}).output();
 if(!result.success)throw Error(new TextDecoder().decode(result.stderr));
 return await Deno.readTextFile(temp+'/'+out+'/import.private.sql');
}
async function fails(sql:string,pattern:RegExp){
 try{await assert.rejects(db.unsafe(sql),pattern);}finally{await db.unsafe('rollback');}
}
async function count(){return (await db`select count(*)::int n from apple_private.accounts where user_id=any(${targets.map(t=>t.user_id)}::uuid[])`)[0].n;}
async function check(name:string,run:()=>Promise<void>){await run();passed++;console.log('PASS '+name);}
try{
 for(let i=0;i<22;i++){
  const id=crypto.randomUUID(),legacy=crypto.randomUUID().replaceAll('-','').slice(0,24),email=crypto.randomUUID().replaceAll('-','')+'@accounts.spyclash.invalid';
  const t={source_record_id:crypto.randomUUID().replaceAll('-','').slice(0,24),source_revision:crypto.randomUUID(),identity_key:'apple-email:'+await digest('email-'+id),subject_key:'apple-subject:'+await digest('subject-'+id),legacy_user_id:legacy,user_id:id};targets.push(t);
  await auth.request('/admin/users','POST',{id,email,email_confirm:true,app_metadata:{legacy_provider:'base44'}});
  await db`insert into app_private.profiles(user_id,data) values(${id},${db.json({display_name:'Preserved '+i,onboarding_completed:true,fixture_marker:id})})`;
  await db`insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email,state,import_completed)
   values(${await digest('https://spyclash.com\n69a0e57fa939f578082f8091\n'+legacy)},${legacy},'https://spyclash.com','69a0e57fa939f578082f8091',${id},${email},'reserved',true)`;
  await db`insert into app_private.legacy_import_runs(user_id,source_key,legacy_user_id,status,profile_applied) values(${id},${'local-coverage-'+id},${legacy},'complete',true)`;
  owners.push({legacy_user_id:legacy,user_id:id,shadow_email:email,auth_exists:true,auth_mail_matches:true,auth_deleted:false,auth_banned:false,deletion_fenced:false,profile_state:'active',reservation_imported:true,native_provider:null,reservation_state:'reserved',link_state:null});
  users.push({id:legacy,email:'synthetic-'+i+'@example.test',is_verified:true});
  records.push({...t,client_id:'com.spyclash.ios',source_state:'pending',encrypted_binding_verified:true,source_user_verified:true});
 }
 await Deno.writeTextFile(temp+'/input.json',JSON.stringify({targets,owners,source_users:users,rights}));
 await Deno.writeTextFile(temp+'/receipt.json',JSON.stringify({version:1,captured_at:new Date().toISOString(),verified_count:22,records}));
 const draft=await compile(false,'draft'),sql=await compile(true,'ready');
 await check('provisional coverage SQL cannot write without the source verifier receipt',async()=>{await fails(draft,/actual fixed-cohort source verification receipt required/);assert.equal(await count(),0);});
 await check('a last-account ownership conflict rolls back every preceding promotion',async()=>{
  const last=owners.at(-1);await db`update app_private.legacy_session_accounts set shadow_email='mismatch@accounts.spyclash.invalid' where user_id=${last.user_id}`;
  await fails(sql,/canonical reservation changed/);assert.equal(await count(),0);
  const [links]=await db`select count(*)::int n from app_private.legacy_links where user_id=any(${targets.map(t=>t.user_id)}::uuid[])`;assert.equal(links.n,0);
  await db`update app_private.legacy_session_accounts set shadow_email=${last.shadow_email} where user_id=${last.user_id}`;
 });
 await check('verified cohort retains all 22 Auth UUIDs and profiles while completing both registries',async()=>{
  await db.unsafe(sql);assert.equal(await count(),22);
  const rows=await db`select a.user_id,a.state,a.migration_complete,a.migration_version,p.data,n.provider,n.state native_state,u.email,a.shadow_email
   from apple_private.accounts a join app_private.profiles p using(user_id) join app_private.native_accounts n using(user_id) join auth.users u on u.id=a.user_id where a.user_id=any(${targets.map(t=>t.user_id)}::uuid[])`;
  assert.equal(rows.length,22);for(const r of rows){assert.equal(r.state,'ready');assert.equal(r.migration_complete,true);assert.equal(r.migration_version,1);assert.equal(r.provider,'apple');assert.equal(r.native_state,'ready');assert.equal(r.data.fixture_marker,r.user_id);assert.equal(r.data.onboarding_completed,true);assert.equal(r.email,r.shadow_email);}
 });
 await check('replaying the same verified plan does not duplicate identities or overwrite profiles',async()=>{
  await db.unsafe(sql);assert.equal(await count(),22);
  const [snapshots]=await db`select count(*)::int n from apple_private.migration_snapshots where user_id=any(${targets.map(t=>t.user_id)}::uuid[])`;assert.equal(snapshots.n,22);
 });
 console.log(JSON.stringify({passed,localOnly:true,productionOperations:0}));
}finally{
 await db.unsafe('rollback').catch(()=>{});
 for(const t of targets){
  await db`delete from apple_private.migration_snapshots where user_id=${t.user_id}`;
  await db`delete from apple_private.accounts where user_id=${t.user_id}`;
  await db`delete from app_private.legacy_links where user_id=${t.user_id}`;
  await db`delete from app_private.legacy_import_runs where user_id=${t.user_id}`;
  await db`delete from app_private.legacy_session_accounts where user_id=${t.user_id}`;
  await db`delete from app_private.profiles where user_id=${t.user_id}`;
  await auth.request('/admin/users/'+t.user_id,'DELETE').catch(()=>{});
 }
 await db.end();
}

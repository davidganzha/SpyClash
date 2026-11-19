import {verifyAppleSourceErasureRequest,resolveAppleSourceErasureUser} from './apple-source-erasure.ts';
import {prepareDeletionReceipt,markDeletionReceiptReady,completeDeletionReceipt,deletionSubjectHash} from './deletion-receipt.ts';
import {signedAppleSourceErasureRequest} from '../../../experiments/supabase-game-core/supabase/functions/app-services/apple-source-erasure.ts';

type Row=Record<string,any>;
const assert=(value:unknown,message='assertion failed')=>{if(!value)throw Error(message);};
async function rejects(task:Promise<unknown>,code:string){try{await task;throw Error('expected rejection');}catch(error){assert((error as any).code===code,'unexpected rejection: '+(error as any).code);}}
const secret='a1'.repeat(32),actor=crypto.randomUUID(),legacy='a123456789012345678901234';
const subject='apple-subject:'+'23'.repeat(32);
class Store {
  rows:Row[]=[];reads=0;
  async filter(query:Row){this.reads++;return this.rows.filter(row=>Object.entries(query).every(([key,value])=>row[key]===value)).map(row=>({...row}));}
  async create(value:Row){const row={...value,id:crypto.randomUUID(),created_date:new Date().toISOString()};this.rows.push(row);return {...row};}
  async updateMany(query:Row,update:Row){let updated=0;for(const row of this.rows)if(Object.entries(query).every(([key,value])=>row[key]===value)){Object.assign(row,update.$set);updated++;}return {updated};}
}
async function fixture(changes:Row={}) {
  const request=crypto.randomUUID(),recovery='07'.repeat(32),archive={signature:'08'.repeat(32),subject_hash:await deletionSubjectHash(legacy)};
  const account={subject_key:subject,legacy_user_id:legacy,state:'deleting',migration_complete:true,...changes};
  const ownership={accounts:[account],links:[{legacy_user_id:legacy}],
    intents:[{request_id:request,legacy_user_id:legacy,source_origin:'https://spyclash.com',source_app_id:'69a0e57fa939f578082f8091'}]};
  const tx=async(parts:TemplateStringsArray)=>{
    const sql=parts.join('?');
    if(sql.includes('apple_private.accounts'))return ownership.accounts;
    if(sql.includes('main_account_deletions'))return ownership.intents;
    if(sql.includes('legacy_links'))return ownership.links;
    return [];
  };
  const db={begin:async(fn:(tx:any)=>Promise<any>)=>await fn(tx)};
  const config={SUPABASE_URL:'http://127.0.0.1:56321',APP_DELETION_ARCHIVE_SECRET:secret};
  const sign=()=>signedAppleSourceErasureRequest(db,config,actor,legacy,request,recovery,archive);
  return {sign,body:{action:'apple_source_erasure',request_id:request,recovery_token:recovery,archive_erasure_request:archive},account,ownership};
}
async function signedFixture() {
  const f=await fixture();const body={...f.body,apple_source_erasure_request:await f.sign()};
  const stores={receipts:new Store(),users:new Store(),credentials:new Store()};
  stores.users.rows=[{id:legacy,role:'user',email:'owner@example.test'}];
  stores.credentials.rows=[{subject_key:subject,user_id:legacy,state:'bound'}];
  return {body,stores};
}

Deno.test('signed migrated Apple erasure binds the preserved owner without a legacy bearer',async()=>{
  const {body,stores}=await signedFixture();
  const result=await resolveAppleSourceErasureUser(body,stores,{secret});
  assert(result.owner.actorID===actor&&result.user?.id===legacy&&result.owner.subjectKey===subject);
  assert(stores.receipts.rows.length===0,'preflight must not create deletion intent');
});
Deno.test('forged identity, nonce, capability, archive signature and expiry fail before source reads',async()=>{
  const {body,stores}=await signedFixture();
  const copies=[
    {...body,request_id:crypto.randomUUID()},
    {...body,recovery_token:'09'.repeat(32)},
    {...body,archive_erasure_request:{...body.archive_erasure_request,signature:'11'.repeat(32)}},
    {...body,apple_source_erasure_request:{...body.apple_source_erasure_request,actor_id:crypto.randomUUID()}},
    {...body,apple_source_erasure_request:{...body.apple_source_erasure_request,legacy_user_id:'foreign-user'}},
    {...body,apple_source_erasure_request:{...body.apple_source_erasure_request,subject_key:'apple-subject:'+'11'.repeat(32)}},
    {...body,apple_source_erasure_request:{...body.apple_source_erasure_request,expires_at:Date.now()-1}},
    {...body,action:'deletion_status'},
  ];
  for(const value of copies)await rejects(resolveAppleSourceErasureUser(value,stores,{secret}),'apple_source_erasure_invalid');
  assert(stores.users.reads+stores.credentials.reads+stores.receipts.reads===0);
  await rejects(verifyAppleSourceErasureRequest(body,{secret:'22'.repeat(32)}),'apple_source_erasure_invalid');
});
Deno.test('unresolved, incomplete or active migration cannot authorize source erasure',async()=>{
  for(const changes of [{migration_complete:false},{state:'ready'},{state:'deleted'},{legacy_user_id:'other'},{subject_key:'apple-subject:invalid'}]) {
    const f=await fixture(changes);await rejects(f.sign(),'apple_source_erasure_identity_conflict');
  }
});
Deno.test('sender requires exact durable request, historical link and canonical source',async()=>{
  const mutations=[
    (o:any)=>o.accounts=[],(o:any)=>o.links=[],(o:any)=>o.links.push({legacy_user_id:'foreign'}),
    (o:any)=>o.intents=[],(o:any)=>o.intents[0].request_id=crypto.randomUUID(),
    (o:any)=>o.intents[0].legacy_user_id='foreign',(o:any)=>o.intents[0].source_origin='https://attacker.example',
    (o:any)=>o.intents[0].source_app_id='000000000000000000000000',
  ];
  for(const mutate of mutations) {const f=await fixture();mutate(f.ownership);await rejects(f.sign(),'apple_source_erasure_identity_conflict');}
});
Deno.test('initial source authorization requires bound matching Apple subject and rejects foreign owner',async()=>{
  for(const rows of [[],[{subject_key:subject,user_id:'',state:'pending'}],[{subject_key:subject,user_id:'different',state:'bound'}]]) {
    const {body,stores}=await signedFixture();stores.credentials.rows=rows;
    await rejects(resolveAppleSourceErasureUser(body,stores,{secret}),'apple_source_erasure_invalid');
  }
});
Deno.test('durable pending receipt permits retry after credentials were erased but never proves absent-user completion',async()=>{
  const {body,stores}=await signedFixture();await prepareDeletionReceipt(stores.receipts,legacy,body);
  stores.credentials.rows=[];
  assert((await resolveAppleSourceErasureUser(body,stores,{secret})).user?.id===legacy);
  stores.users.rows=[];
  await rejects(resolveAppleSourceErasureUser(body,stores,{secret}),'apple_source_erasure_user_unavailable');
});
Deno.test('completed exact receipt handles lost response without reviving a deleted source account',async()=>{
  const {body,stores}=await signedFixture();const receipt=await prepareDeletionReceipt(stores.receipts,legacy,body);
  await markDeletionReceiptReady(stores.receipts,receipt,false);await completeDeletionReceipt(stores.receipts,receipt,false);
  stores.credentials.rows=[];stores.users.rows=[];
  const result=await resolveAppleSourceErasureUser(body,stores,{secret});
  assert(result.receipt?.complete===true&&result.user===undefined);
  assert(stores.credentials.reads===0&&stores.receipts.rows.every(row=>row.user_id===''));
});
Deno.test('route shares protected-account checks and existing archive and revocation cleanup',async()=>{
  const source=await Deno.readTextFile(new URL('./main.ts',import.meta.url));
  const route=source.indexOf('const sourceErasure ='),protection=source.indexOf('protectedAccountDeletionResponse(user)',route);
  assert(route>0&&protection>route&&protection<source.indexOf('prepareDeletionReceipt(receiptStore,user.id',route));
  assert(source.includes('const user = sourceErasure ? sourceErasure.user : await base44.auth.me();'));
});

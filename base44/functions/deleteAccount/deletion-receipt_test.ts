import {prepareDeletionReceipt,markDeletionReceiptReady,completeDeletionReceipt,deletionReceiptStatus,deletionSubjectHash} from './deletion-receipt.ts';
const assert=(value:unknown,message='Assertion failed')=>{if(!value)throw new Error(message);};
class MemoryStore {
  rows:Record<string,any>[]=[];
  loseCreate=false;loseUpdate=false;
  async filter(query:Record<string,any>){return this.rows.filter(row=>Object.entries(query).every(([key,value])=>row[key]===value)).map(row=>({...row}));}
  async create(value:Record<string,any>){const row={...value,id:crypto.randomUUID(),created_date:new Date().toISOString()};this.rows.push(row);if(this.loseCreate)throw Error('lost create');return {...row};}
  async updateMany(query:Record<string,any>,update:Record<string,any>){let updated=0;for(const row of this.rows)if(Object.entries(query).every(([key,value])=>row[key]===value)){Object.assign(row,update.$set);updated++;}if(this.loseUpdate)throw Error('lost update');return {updated};}
}
const input=()=>({request_id:crypto.randomUUID(),recovery_token:'07'.repeat(32)});
async function rejects(task:Promise<unknown>,code:string){try{await task;throw Error('Expected rejection');}catch(error){assert((error as {code?:string}).code===code,'Wrong rejection');}}

Deno.test('deletion receipt is optional and stores no raw recovery token',async()=>{
  const store=new MemoryStore(),body=input();
  assert(await prepareDeletionReceipt(store,'user',{})===undefined);
  const row=await prepareDeletionReceipt(store,'user',body);
  assert(row?.phase==='pending');assert(!JSON.stringify(store.rows).includes(body.recovery_token));
  await rejects(prepareDeletionReceipt(store,'user',{...body,recovery_token:'08'.repeat(32)}),'deletion_receipt_conflict');
});
Deno.test('missing user cannot complete deletion before cleanup-ready marker',async()=>{
  const store=new MemoryStore(),users=new MemoryStore(),body=input();
  await prepareDeletionReceipt(store,'user',body);
  const status=await deletionReceiptStatus(store,users,body);
  assert(status.complete===false);assert(status.subject_hash===await deletionSubjectHash('user'));
});
Deno.test('lost User.delete ACK reconciles exact absence after ready and scrubs identity',async()=>{
  const store=new MemoryStore(),users=new MemoryStore(),body=input();
  users.rows=[{id:'user'}];
  const receipt=await prepareDeletionReceipt(store,'user',body);
  await markDeletionReceiptReady(store,receipt,true);
  assert(!(await deletionReceiptStatus(store,users,body)).complete);
  users.rows=[];
  const result=await deletionReceiptStatus(store,users,body);
  assert(result.complete&&result.manual_apple_revocation_required);
  assert(store.rows.every(row=>row.user_id===''));
  assert((await deletionReceiptStatus(store,users,body)).complete);
});
Deno.test('receipt recovers lost writes and redacts equivalent create duplicates',async()=>{
  const store=new MemoryStore(),body=input();store.loseCreate=true;
  const receipt=await prepareDeletionReceipt(store,'user',body);
  store.rows.push({...store.rows[0],id:crypto.randomUUID()});
  store.loseUpdate=true;
  await markDeletionReceiptReady(store,receipt,false);
  await completeDeletionReceipt(store,receipt,false);
  assert(store.rows.every(row=>row.phase==='complete'&&row.user_id===''));
});
Deno.test('wrong capability and expired receipt cannot discover or confirm account deletion',async()=>{
  const store=new MemoryStore(),body=input();
  await prepareDeletionReceipt(store,'user',body);
  await rejects(deletionReceiptStatus(store,new MemoryStore(),{...body,recovery_token:'09'.repeat(32)}),'deletion_receipt_unavailable');
  await rejects(deletionReceiptStatus(store,new MemoryStore(),body,new Date(Date.now()+31*86400_000)),'deletion_receipt_expired');
});
Deno.test('status repairs a partially redacted duplicate even when another row is complete',async()=>{
  const store=new MemoryStore(),users=new MemoryStore(),body=input();
  const row=await prepareDeletionReceipt(store,'user',body);
  await markDeletionReceiptReady(store,row,true);
  await completeDeletionReceipt(store,row,true);
  store.rows.push({...store.rows[0],id:crypto.randomUUID(),created_date:'2000-01-01',phase:'pending',user_id:'user'});
  const status=await deletionReceiptStatus(store,users,body);
  assert(status.complete);assert(store.rows.every(value=>value.phase==='complete'&&value.user_id===''));
});

import {deleteHistoricalOwnedContent,historicalRoomSubject} from './historical-content-cleanup.ts';
const assert=(value:unknown)=>{if(!value)throw Error('assertion failed');};
Deno.test('historical content removes own stable and email-only rows but preserves foreign binding',async()=>{
  const rows=[{id:'one',player_email:'old@example.test'},{id:'two',player_user_id:'own',player_email:'changed@example.test'},{id:'foreign',player_user_id:'other',player_email:'old@example.test'}];
  const store={rows,filter:async function(query:Record<string,any>,_sort:string,limit:number,skip:number){return this.rows.filter(row=>Object.entries(query).every(([k,v])=>(row as any)[k]===v)).slice(skip,skip+limit);},delete:async function(id:string){this.rows=this.rows.filter(r=>r.id!==id);}};
  await deleteHistoricalOwnedContent(store,'own','player_user_id','player_email',['old@example.test']);
  assert(store.rows.length===1&&store.rows[0].id==='foreign');
});
Deno.test('historical room alias cannot override a foreign stable participant',()=>{
  const result=historicalRoomSubject({players:[{user_id:'other',email:'old@example.test'}],host_email:'old@example.test'},'own',['old@example.test']);
  assert(!result.ownedByID&&result.aliases.length===0);
});
Deno.test('own stable room membership survives changed email while legacy email-only remains eligible',()=>{
  assert(historicalRoomSubject({players:[{user_id:'own',email:'different@example.test'}]},'own',['old@example.test']).ownedByID);
  assert(historicalRoomSubject({players:[{email:'old@example.test'}]},'own',['old@example.test']).aliases.includes('old@example.test'));
});

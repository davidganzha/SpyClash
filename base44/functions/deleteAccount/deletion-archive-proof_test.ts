import {archiveErasureCapabilities,verifyArchiveErasureRequest,archiveProofMessage} from './deletion-archive-proof.ts';
const assert=(value:unknown)=>{if(!value)throw Error('assertion failed');};
async function rejects(task:Promise<unknown>,code:string){try{await task;throw Error('expected rejection');}catch(error){assert((error as any).code===code);}}
Deno.test('capability v2 requires explicit historical key verification and configured server key',async()=>{
  const names=['APP_DELETION_ARCHIVE_SECRET','APP_DELETION_ARCHIVE_KEY_VERIFIED','SPYCLASH_PSEUDONYM_KEY'];
  const old=names.map(name=>Deno.env.get(name));
  try {
    Deno.env.set(names[0],'31'.repeat(32));Deno.env.set(names[1],'false');Deno.env.set(names[2],'local-test-pseudonym-secret-only-32-bytes');
    await rejects(archiveErasureCapabilities(),'deletion_archive_unconfigured');
    Deno.env.set(names[1],'true');assert((await archiveErasureCapabilities()).protocol==='spyclash-deletion-receipt-v2');
    Deno.env.delete(names[0]);await rejects(archiveErasureCapabilities(),'deletion_archive_unconfigured');
  } finally {names.forEach((name,i)=>old[i]===undefined?Deno.env.delete(name):Deno.env.set(name,old[i]!));}
});
Deno.test('read-only probe verification rejects absent signature, invalid UUID and forged subject before lookup',async()=>{
  let reads=0;const options={secret:'31'.repeat(32),users:{filter:async()=>{reads++;return [];}}};
  for(const body of [{request_id:'bad',archive_erasure_request:{}},{request_id:crypto.randomUUID(),archive_erasure_request:{aliases:[],timestamp:Date.now(),subject_hash:'a'.repeat(64),signature:'b'.repeat(64)}}])
    await rejects(verifyArchiveErasureRequest(body,'a'.repeat(64),options),'deletion_archive_request_invalid');
  assert(reads===0);
});
Deno.test('probe entry remains read-only and precedes the authenticated deletion branch',async()=>{
  for(const url of [new URL('./main.ts',import.meta.url),new URL('../../../experiments/supabase-game-core/base44-prepared/deleteAccount/entry.ts',import.meta.url)]) {
    const source=await Deno.readTextFile(url),start=source.indexOf('if (body.action === "deletion_archive_probe")'),end=source.indexOf('if (body.action === "deletion_status")',start);
    assert(start>=0&&end>start);const probe=source.slice(start,end);
    assert(probe.includes('verifyArchiveErasureRequest')&&!probe.includes('prepareDeletionReceipt')&&!probe.includes('recordDeletionArchiveProof')&&!probe.includes('.delete('));
  }
});

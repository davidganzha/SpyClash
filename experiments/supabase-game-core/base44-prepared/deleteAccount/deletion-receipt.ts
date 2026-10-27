type Row = Record<string, any>;
type Store = {filter: (query: Row, sort?: string, limit?: number, skip?: number) => Promise<Row[]>; create: (value: Row) => Promise<Row>; updateMany: (query: Row, update: Row) => Promise<{updated?: number}>};
export class DeletionReceiptError extends Error {
  constructor(public code: string, public status = 503) { super(code); }
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hex = /^[a-f0-9]{64}$/;
const equalHash = (left: string, right: string) => {let difference=left.length^right.length;for(let i=0;i<64;i++)difference|=(left.charCodeAt(i)||0)^(right.charCodeAt(i)||0);return difference===0;};
const hash = async(value: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(v=>v.toString(16).padStart(2,'0')).join('');
export const deletionSubjectHash = (id: string) => hash('spyclash-delete-user-v1:'+id);
function input(body: Row) {
  if (!uuid.test(body?.request_id || '') || !hex.test(body?.recovery_token || '')) throw new DeletionReceiptError('deletion_receipt_invalid',400);
  return {requestID:body.request_id.toLowerCase(),token:body.recovery_token};
}
function canonical(rows: Row[], now: Date): Row {
  if (!rows.length || rows.length > 8) throw new DeletionReceiptError('deletion_receipt_unavailable',404);
  const phase:Record<string,number>={pending:0,user_delete_ready:1,complete:2};
  const sorted=[...rows].sort((a,b)=>(phase[b.phase]??-1)-(phase[a.phase]??-1)||String(a.created_date||'').localeCompare(String(b.created_date||''))||String(a.id).localeCompare(String(b.id)));
  const row=sorted[0];
  if (!row.id || !Number.isFinite(Date.parse(row.expires_at)) || Date.parse(row.expires_at)<now.getTime()) throw new DeletionReceiptError('deletion_receipt_expired',410);
  if (sorted.some(r=>r.request_key!==row.request_key||r.request_id!==row.request_id||!equalHash(String(r.token_hash),String(row.token_hash))||r.subject_hash!==row.subject_hash)) throw new DeletionReceiptError('deletion_receipt_conflict',409);
  return row;
}
async function exact(store: Store, row: Row, now = new Date()) {
  return canonical(await store.filter({request_key:row.request_key},'created_date',9,0),now);
}

/** Optional for existing clients. A verified ordinary user owns the binding;
 * neither a supplied subject nor a contact address can create recovery proof. */
export async function prepareDeletionReceipt(store: Store, userID: string, body: Row, now = new Date()) {
  if (body?.recovery_token === undefined && body?.request_id === undefined) return undefined;
  const {requestID,token}=input(body);
  if (!userID) throw new DeletionReceiptError('deletion_receipt_identity_required',401);
  const subjectHash=await deletionSubjectHash(userID),tokenHash=await hash(token),requestKey=await hash(subjectHash+':'+requestID);
  let rows=await store.filter({request_key:requestKey},'created_date',9,0);
  if (!rows.length) {
    try {
      await store.create({request_key:requestKey,request_id:requestID,subject_hash:subjectHash,user_id:userID,token_hash:tokenHash,phase:'pending',manual_apple_revocation_required:false,expires_at:new Date(now.getTime()+30*86400_000).toISOString()});
    } catch { /* Re-read an ambiguous create ACK by its immutable request key. */ }
    rows=await store.filter({request_key:requestKey},'created_date',9,0);
  }
  const row=canonical(rows,now);
  if (row.subject_hash!==subjectHash||row.request_id!==requestID||!equalHash(String(row.token_hash),tokenHash)||(row.user_id && row.user_id!==userID)) throw new DeletionReceiptError('deletion_receipt_conflict',409);
  if(row.phase==='complete')await transition(store,row,'complete',row.manual_apple_revocation_required===true);
  return row;
}
async function transition(store: Store, receipt: Row, target: 'user_delete_ready'|'complete', manual: boolean) {
  const row=await exact(store,receipt);
  if(row.phase==='complete'&&target!=='complete')return row;
  if(target==='complete'&&!['user_delete_ready','complete'].includes(row.phase))throw new DeletionReceiptError('deletion_receipt_not_ready');
  // Same-key duplicate creates may race on Base44. Once cleanup is confirmed,
  // scrub every equivalent receipt, not just its canonical row.
  const query=target==='complete'?{request_key:row.request_key,token_hash:row.token_hash}:{id:row.id,phase:row.phase,token_hash:row.token_hash};
  try { await store.updateMany(query,{ $set:{phase:target,manual_apple_revocation_required:manual || row.manual_apple_revocation_required === true,...(target==='complete'?{user_id:''}:{})} }); }
  catch { /* Lost update ACK must be verified by a fresh exact read. */ }
  const updated=await exact(store,row);
  if(updated.phase!==target&&updated.phase!=='complete')throw new DeletionReceiptError('deletion_receipt_update_pending');
  if(target==='complete') {
    const all=await store.filter({request_key:row.request_key},'created_date',9,0);
    canonical(all,new Date());
    if(all.some(item=>item.phase!=='complete'||item.user_id!==''))throw new DeletionReceiptError('deletion_receipt_redaction_pending');
  }
  return updated;
}
export async function markDeletionReceiptReady(store: Store, receipt: Row|undefined, manual: boolean) {
  if(receipt)await transition(store,receipt,'user_delete_ready',manual);
}
export async function completeDeletionReceipt(store: Store, receipt: Row|undefined, manual: boolean) {
  if(receipt)await transition(store,receipt,'complete',manual);
}

/** Capability proves only this deletion. It grants no account/session access.
 * User absence is authoritative only after all content cleanup reached ready. */
export async function deletionReceiptStatus(store: Store, users: Pick<Store,'filter'>, body: Row, now = new Date()) {
  const {requestID,token}=input(body),tokenHash=await hash(token);
  let row=canonical(await store.filter({token_hash:tokenHash,request_id:requestID},'created_date',9,0),now);
  if(row.phase==='user_delete_ready') {
    if(!row.user_id)throw new DeletionReceiptError('deletion_receipt_identity_missing');
    const matches=await users.filter({id:row.user_id},'created_date',2,0);
    if(!Array.isArray(matches))throw new DeletionReceiptError('deletion_receipt_lookup_pending');
    if(!matches.some(value=>value.id===row.user_id))row=await transition(store,row,'complete',row.manual_apple_revocation_required===true);
  }
  if(row.phase==='complete')row=await transition(store,row,'complete',row.manual_apple_revocation_required===true);
  return {request_id:requestID,subject_hash:row.subject_hash,complete:row.phase==='complete',manual_apple_revocation_required:row.manual_apple_revocation_required===true,...(row.erasure_proof?{erasure_proof:row.erasure_proof}:{})};
}

/** Called only with server-derived proof after the signed archive request was
 * verified. The capability and immutable subject bind each persisted update. */
export async function recordDeletionArchiveProof(store: Store, body: Row, proof: Row) {
  const {requestID,token}=input(body),tokenHash=await hash(token);
  const row=canonical(await store.filter({token_hash:tokenHash,request_id:requestID},'created_date',9,0),new Date());
  const prior=row.erasure_proof;
  const merged={version:1,archive_alias_digest:proof.archive_alias_digest,
    apple_identity_keys:[...new Set([...(prior?.apple_identity_keys||[]),...proof.apple_identity_keys])].sort(),
    apple_record_ids:[...new Set([...(prior?.apple_record_ids||[]),...proof.apple_record_ids])].sort()};
  if(merged.apple_identity_keys.length>256||merged.apple_record_ids.length>4096)throw new DeletionReceiptError('deletion_archive_proof_too_large');
  try {await store.updateMany({request_key:row.request_key,token_hash:tokenHash},{$set:{erasure_proof:merged}});}
  catch { /* Re-read a lost acknowledgement before deleting credentials. */ }
  const rows=await store.filter({request_key:row.request_key},'created_date',9,0);canonical(rows,new Date());
  if(rows.some(value=>JSON.stringify(value.erasure_proof)!==JSON.stringify(merged)))throw new DeletionReceiptError('deletion_archive_proof_pending');
  return merged;
}

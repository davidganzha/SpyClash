type Row=Record<string,any>;
export type Target={source_record_id:string;legacy_user_id:string;native_user_id:string;transfer_id:string;fingerprint:string};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const fingerprint=async(row:Row)=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify([
  row.id,row.user_id,row.attempt_id,row.custom_data,row.ad_unit_id,row.issued_at,
]))))].map(v=>v.toString(16).padStart(2,'0')).join('');
export class RewardTransferError extends Error {constructor(public code:string){super(code);}}
/** Caller is the fixed-app administrator and holds the existing per-user
 * generation coordinator. Source callbacks/spending use this same lease. */
export async function transferReward(store:any,guard:any,target:Target,now=new Date()) {
  const invalid=()=>new RewardTransferError('reward_transfer_conflict');
  if(!uuid.test(target.native_user_id)||!uuid.test(target.transfer_id))throw invalid();
  const read=async()=>{
    const rows=await store.filter({id:target.source_record_id},'created_date',2,0);
    if(!Array.isArray(rows)||rows.length!==1||rows[0].user_id!==target.legacy_user_id||await fingerprint(rows[0])!==target.fingerprint)throw invalid();
    return rows[0];
  };
  let row=await read();
  if(row.state==='transferred') {
    if(row.transfer_user_id!==target.native_user_id||row.transfer_id!==target.transfer_id||!['pending','earned','spent'].includes(row.transfer_state))throw invalid();
    return row;
  }
  if(!['pending','earned','spent'].includes(row.state))throw new RewardTransferError('reward_transfer_busy');
  if(row.state==='pending'&&(row.transaction_id||row.earned_at||row.generation_request_id))throw invalid();
  if(row.state!=='pending'&&(!row.transaction_id||!Number.isFinite(Date.parse(row.earned_at))))throw invalid();
  if(row.state==='spent'&&!uuid.test(row.generation_request_id||''))throw invalid();
  const originalState=row.state;
  try {
    await guard.boundary(()=>store.updateMany({id:row.id,user_id:row.user_id,state:originalState,custom_data:row.custom_data},{$set:{
      state:'transferred',transfer_state:originalState,transfer_user_id:target.native_user_id,transfer_id:target.transfer_id,transferred_at:now.toISOString(),
    }}));
  } catch {/* A lost ACK is reconciled against the exact immutable transfer. */}
  row=await read();
  if(row.state!=='transferred'||row.transfer_state!==originalState||row.transfer_user_id!==target.native_user_id||row.transfer_id!==target.transfer_id)throw invalid();
  return row;
}
export function canonicalAdministratorRequest(request:Request) {
  const headers=new Headers({'Base44-App-Id':'69a0e57fa939f578082f8091','Base44-Api-Url':'https://base44.app'});
  const bearer=request.headers.get('Authorization');if(bearer)headers.set('Authorization',bearer);
  return new Request('https://base44.app',{method:'POST',headers});
}

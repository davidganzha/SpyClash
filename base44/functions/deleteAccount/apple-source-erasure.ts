import {DeletionReceiptError, deletionReceiptStatus, deletionSubjectHash} from './deletion-receipt.ts';

type Row = Record<string, any>;
type Store = {filter:(query:Row,sort?:string,limit?:number,skip?:number)=>Promise<Row[]>};
const APP_ID='69a0e57fa939f578082f8091';
const hex=/^[a-f0-9]{64}$/;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const encoder=new TextEncoder();
const hash=async(value:string)=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(value)))].map(v=>v.toString(16).padStart(2,'0')).join('');
const invalid=()=>new DeletionReceiptError('apple_source_erasure_invalid',403);

export function appleSourceErasureMessage(proof:Row,requestID:string,recoveryHash:string,archiveSignature:string) {
  return JSON.stringify(['spyclash-apple-source-erasure-v1',APP_ID,proof.actor_id,proof.legacy_user_id,
    proof.subject_key,requestID,recoveryHash,archiveSignature,proof.issued_at,proof.expires_at]);
}

/** Only the trusted Supabase migration registry can authorize this route. A
 * client bearer, email address or caller-supplied provider flag grants nothing.
 * The immutable deletion request UUID is also the idempotency nonce. */
export async function verifyAppleSourceErasureRequest(body:Row,options:{secret?:string;now?:number}={}) {
  const proof=body?.apple_source_erasure_request, now=options.now??Date.now();
  if(body?.action!=='apple_source_erasure'||proof?.version!==1||!uuid.test(proof.actor_id||'')
    ||typeof proof.legacy_user_id!=='string'||!/^[A-Za-z0-9_-]{1,200}$/.test(proof.legacy_user_id)
    ||!/^apple-subject:[a-f0-9]{64}$/.test(proof.subject_key||'')||!uuid.test(body.request_id||'')
    ||!hex.test(body.recovery_token||'')||!hex.test(body.archive_erasure_request?.signature||'')
    ||!Number.isSafeInteger(proof.issued_at)||!Number.isSafeInteger(proof.expires_at)
    ||proof.issued_at>now+30_000||proof.expires_at<=now||proof.expires_at<=proof.issued_at
    ||proof.expires_at-proof.issued_at>300_000||!hex.test(proof.signature||''))throw invalid();
  const secret:string=options.secret??(globalThis as any).Deno?.env?.get('APP_DELETION_ARCHIVE_SECRET')??'';
  if(!/^[a-f0-9]{64}$/i.test(secret))throw new DeletionReceiptError('deletion_archive_unconfigured');
  const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  const signature=Uint8Array.from(proof.signature.match(/.{2}/g)!, (v:string)=>parseInt(v,16));
  if(!await crypto.subtle.verify('HMAC',key,signature,encoder.encode(appleSourceErasureMessage(proof,body.request_id,
    await hash(body.recovery_token),body.archive_erasure_request.signature))))throw invalid();
  if(body.archive_erasure_request.subject_hash!==await deletionSubjectHash(proof.legacy_user_id))throw invalid();
  return {actorID:proof.actor_id as string,legacyID:proof.legacy_user_id as string,subjectKey:proof.subject_key as string};
}

/** A receipt authorizes continuation only after its exact subject/capability
 * has been checked. User absence alone is never evidence of content erasure. */
export async function resolveAppleSourceErasureUser(body:Row,stores:{receipts:any;users:Store;credentials:Store},options:{secret?:string;now?:number}={}) {
  const owner=await verifyAppleSourceErasureRequest(body,options);
  let receipt:Row|undefined;
  try {receipt=await deletionReceiptStatus(stores.receipts,stores.users,body);}
  catch(error) {
    if(!(error instanceof DeletionReceiptError)||error.code!=='deletion_receipt_unavailable')throw error;
  }
  if(receipt&&receipt.subject_hash!==await deletionSubjectHash(owner.legacyID))throw invalid();
  if(receipt?.complete)return {owner,receipt};
  const users=await stores.users.filter({id:owner.legacyID},'created_date',2,0);
  if(!Array.isArray(users)||users.length!==1||users[0].id!==owner.legacyID)throw new DeletionReceiptError('apple_source_erasure_user_unavailable');
  const credentials=await stores.credentials.filter({subject_key:owner.subjectKey},'created_date',100,0);
  if(!Array.isArray(credentials)||credentials.length>=100
    ||credentials.some(row=>row.user_id&&row.user_id!==owner.legacyID)
    ||(!receipt&&!credentials.some(row=>row.user_id===owner.legacyID&&row.state==='bound')))throw invalid();
  return {owner,user:users[0],receipt};
}

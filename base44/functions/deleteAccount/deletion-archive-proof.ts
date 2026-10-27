import {appleCredentialIdentityKey} from './apple-sign-in-credential.ts';
import {DeletionReceiptError} from './deletion-receipt.ts';

type Row = Record<string,any>;
const hex=/^[a-f0-9]{64}$/i;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const encoder=new TextEncoder();
const env=(key:string)=>(globalThis as any).Deno?.env?.get(key);
export function archiveProofMessage(requestID:string,subjectHash:string,aliases:string[],timestamp:number) {
  return JSON.stringify(['spyclash-deletion-archive-v1',requestID,subjectHash,aliases,timestamp]);
}
export async function archiveErasureCapabilities() {
  if(!hex.test(env('APP_DELETION_ARCHIVE_SECRET')||'') || env('APP_DELETION_ARCHIVE_KEY_VERIFIED')!=='true')throw new DeletionReceiptError('deletion_archive_unconfigured');
  await appleCredentialIdentityKey('configuration-check@spyclash.invalid');
  return {protocol:'spyclash-deletion-receipt-v2'};
}
/** This key is a separate server-to-server authorization key. The historical
 * Apple pseudonym key never leaves Base44. No user bearer can authorize an
 * arbitrary email-selector lookup. The recovery capability is checked too. */
export async function verifyArchiveErasureRequest(body:Row,subjectHash:string,options:{secret?:string;now?:number;deriveKey?:(alias:string)=>Promise<string>;completedProof?:Row;users?:{filter:(query:Row,sort?:string,limit?:number,skip?:number)=>Promise<Row[]>}}={}) {
  const request=body?.archive_erasure_request;
  if(request===undefined)return undefined;
  const aliases=request?.aliases;
  if(!uuid.test(body.request_id||'')||!hex.test(subjectHash)||!Array.isArray(aliases)||aliases.length>64||aliases.some(value=>typeof value!=='string'||value.length>512||value!==value.trim().toLowerCase()||!value.includes('@'))
    ||JSON.stringify([...new Set(aliases)].sort())!==JSON.stringify(aliases)||request.subject_hash!==subjectHash
    ||!Number.isSafeInteger(request.timestamp)||Math.abs((options.now??Date.now())-request.timestamp)>300_000||!hex.test(request.signature||''))throw new DeletionReceiptError('deletion_archive_request_invalid',403);
  const secret:string=options.secret??env('APP_DELETION_ARCHIVE_SECRET')??'';
  if(!hex.test(secret||''))throw new DeletionReceiptError('deletion_archive_unconfigured');
  const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  const signature=Uint8Array.from(request.signature.match(/.{2}/g)!, (v:string)=>parseInt(v,16));
  if(!await crypto.subtle.verify('HMAC',key,signature,encoder.encode(archiveProofMessage(body.request_id,subjectHash,aliases,request.timestamp))))throw new DeletionReceiptError('deletion_archive_request_invalid',403);
  const aliasBytes=await crypto.subtle.digest('SHA-256',encoder.encode(JSON.stringify(aliases)));
  const archive_alias_digest=[...new Uint8Array(aliasBytes)].map(v=>v.toString(16).padStart(2,'0')).join('');
  // A completed private receipt already proved ownership before deletion. Its
  // exact historical proof remains valid if the email is reassigned later.
  if(options.completedProof?.version===1 && options.completedProof.archive_alias_digest===archive_alias_digest)return options.completedProof;
  // A historical email may now belong to another immutable Base44 identity.
  // Reassignment must fail closed even when the old archive was unambiguous.
  if(options.users)for(const alias of aliases) {
    const owners=await options.users.filter({email:alias},'created_date',100,0);
    if(!Array.isArray(owners)||owners.length>=100)throw new DeletionReceiptError('deletion_archive_owner_unavailable');
    for(const owner of owners) {
      const value=await crypto.subtle.digest('SHA-256',encoder.encode('spyclash-delete-user-v1:'+owner.id));
      const ownerHash=[...new Uint8Array(value)].map(v=>v.toString(16).padStart(2,'0')).join('');
      if(!owner.id||ownerHash!==subjectHash)throw new DeletionReceiptError('deletion_archive_alias_reassigned',409);
    }
  }
  const derive=options.deriveKey??((alias:string)=>appleCredentialIdentityKey(alias));
  const keys=await Promise.all(aliases.map(derive));
  return {version:1,archive_alias_digest,apple_identity_keys:[...new Set(keys)].sort(),apple_record_ids:[]};
}

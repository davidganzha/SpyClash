import {AppServiceError} from './contracts.ts';
import {canonical,digest} from './integration-crypto.ts';
import {loadArchiveAliases} from './deletion-archive.ts';

type Row=Record<string,any>;
export async function signedArchiveErasureRequest(db:any,config:Record<string,string|undefined>,userID:string,legacyID:string,requestID:string) {
  const secret=config.APP_DELETION_ARCHIVE_SECRET;
  if(!secret||!/^[a-f0-9]{64}$/i.test(secret))throw new AppServiceError('deletion_archive_unconfigured','Account archive erasure is not configured.',503,true);
  const aliases=await loadArchiveAliases(db,userID,legacyID),subject_hash=await digest('spyclash-delete-user-v1:'+legacyID),timestamp=Date.now();
  const message=JSON.stringify(['spyclash-deletion-archive-v1',requestID,subject_hash,aliases,timestamp]);
  const key=await crypto.subtle.importKey('raw',Uint8Array.from(secret.match(/.{2}/g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const bytes=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(message));
  return {aliases,subject_hash,timestamp,signature:[...new Uint8Array(bytes)].map(v=>v.toString(16).padStart(2,'0')).join('')};
}
export async function verifiedArchiveErasureProof(value:unknown,aliases:string[]) {
  const proof=value as Row;
  if(!proof||proof.version!==1||proof.archive_alias_digest!==await digest(canonical(aliases))
    ||!Array.isArray(proof.apple_identity_keys)||proof.apple_identity_keys.length>256||proof.apple_identity_keys.some((v:any)=>typeof v!=='string'||!/^apple-email:[a-f0-9]{64}$/.test(v))
    ||!Array.isArray(proof.apple_record_ids)||proof.apple_record_ids.length>4096||proof.apple_record_ids.some((v:any)=>typeof v!=='string'||!v||v.length>200)) {
    throw new AppServiceError('deletion_archive_proof_unavailable','Account archive ownership has not been confirmed.',503,true);
  }
  return {version:1,archive_alias_digest:proof.archive_alias_digest,apple_identity_keys:[...new Set(proof.apple_identity_keys)].sort(),apple_record_ids:[...new Set(proof.apple_record_ids)].sort()};
}

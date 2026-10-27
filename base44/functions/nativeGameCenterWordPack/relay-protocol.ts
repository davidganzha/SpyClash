// Mirrored in app-services. The parity test protects this server-to-server wire contract.
export const RELAY_BASE44_URL = 'https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/nativeGameCenterWordPack';
export const RELAY_CALLBACK_URL = 'https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/app-services/native-ai-relay';
export const RELAY_PROMPT_VERSION = 'word-pack-2026-08-29-v5';
export type RelayAction = 'invoke' | 'claim' | 'complete';
export type RelayInput = {theme:string,count:number,alreadyUsed:string[]};
export type RelayTicket = {actor_id:string,request_id:string,request_hash:string,lease_id:string,call_index:number,input_hash:string,input:RelayInput};
export type RelayResult = {words:string[],category:string,exhausted:boolean};
const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = /^[0-9a-f]{64}$/;
export class RelayProtocolError extends Error {
  constructor(readonly code='invalid_relay_request', readonly status=401){super(code);}
}
export function relaySecretConfigured(secret:string|undefined): secret is string {return /^[0-9a-f]{64}$/.test(secret||'');}
export function relayCanonical(value:any):string {
  if(Array.isArray(value))return '['+value.map(relayCanonical).join(',')+']';
  if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+relayCanonical(value[k])).join(',')+'}';
  return JSON.stringify(value);
}
export async function relayDigest(value:string) {return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(value))),x=>x.toString(16).padStart(2,'0')).join('');}
function exact(value:any,keys:string[]) {if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).sort().join(',')!==keys.sort().join(','))throw new RelayProtocolError('invalid_relay_payload',400);}
export async function validateRelayTicket(value:any):Promise<RelayTicket> {
  exact(value,['actor_id','request_id','request_hash','lease_id','call_index','input_hash','input']);
  for(const name of ['actor_id','request_id','lease_id'])if(typeof value[name]!=='string'||!uuid.test(value[name]))throw new RelayProtocolError('invalid_relay_payload',400);
  if(!hash.test(value.request_hash)||!hash.test(value.input_hash)||![0,1].includes(value.call_index))throw new RelayProtocolError('invalid_relay_payload',400);
  const input=value.input;exact(input,['theme','count','alreadyUsed']);
  if(typeof input.theme!=='string'||!input.theme.trim()||input.theme.length>80||!Number.isInteger(input.count)||input.count<2||input.count>100||!Array.isArray(input.alreadyUsed)||input.alreadyUsed.length>300||input.alreadyUsed.some((w:any)=>typeof w!=='string'||w.length>120))throw new RelayProtocolError('invalid_relay_payload',400);
  if(await relayDigest(relayCanonical({version:RELAY_PROMPT_VERSION,...input}))!==value.input_hash)throw new RelayProtocolError('invalid_relay_payload',400);
  return value;
}
export function validateRelayResult(value:any):RelayResult {
  exact(value,['words','category','exhausted']);
  if(!Array.isArray(value.words)||value.words.length>100||value.words.some((w:any)=>typeof w!=='string'||!w.trim()||w.length>120)||typeof value.category!=='string'||value.category.length>120||typeof value.exhausted!=='boolean')throw new RelayProtocolError('invalid_relay_result',422);
  return value;
}
async function key(secret:string){if(!relaySecretConfigured(secret))throw new RelayProtocolError('relay_unconfigured',503);return await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);}
async function message(action:RelayAction,timestamp:string,body:string){return encoder.encode(`spyclash-native-ai-relay-v1\n${action}\nPOST\n/native-ai-relay/${action}\n${timestamp}\n${await relayDigest(body)}`);}
export async function relayHeaders(secret:string,action:RelayAction,body:string,now=Date.now()) {
  const timestamp=String(Math.floor(now/1000));
  const signature=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',await key(secret),await message(action,timestamp,body))),x=>x.toString(16).padStart(2,'0')).join('');
  return {'Content-Type':'application/json','X-SpyClash-Relay-Time':timestamp,'X-SpyClash-Relay-Signature':signature};
}
export async function readRelayRequest(request:Request,secret:string,action:RelayAction,now=Date.now()) {
  if(request.method!=='POST')throw new RelayProtocolError('method_not_allowed',405);
  const timestamp=request.headers.get('X-SpyClash-Relay-Time')||'',signature=request.headers.get('X-SpyClash-Relay-Signature')||'';
  if(!/^\d{10}$/.test(timestamp)||Math.abs(Math.floor(now/1000)-Number(timestamp))>60||!hash.test(signature))throw new RelayProtocolError();
  const reader=request.body?.getReader();if(!reader)throw new RelayProtocolError();
  const chunks:Uint8Array[]=[];let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>65536){await reader.cancel();throw new RelayProtocolError('relay_payload_too_large',413);}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  const body=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
  const signatureBytes=new Uint8Array(signature.match(/../g)!.map(x=>parseInt(x,16)));
  if(!await crypto.subtle.verify('HMAC',await key(secret),signatureBytes,await message(action,timestamp,body)))throw new RelayProtocolError();
  try{return JSON.parse(body);}catch{throw new RelayProtocolError('invalid_relay_payload',400);}
}

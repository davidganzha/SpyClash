import {AppServiceError} from './contracts.ts';
import {assertIsolatedSupabase, CANONICAL_BASE44_APP_ID, CANONICAL_BASE44_ORIGIN} from './legacy-provider.ts';
type Config = Record<string,string|undefined>;
export const MAIN_PUSH_BUNDLE = 'com.spyclash.ios';
export function legacyPushConfigured(config:Config) {
  if (config.APP_PUSH_DELIVERY_PROVIDER !== 'base44' || config.APP_LEGACY_PUSH_RELAY_ENABLED !== 'true'
    || config.APNS_TOPIC !== MAIN_PUSH_BUNDLE || !/^[a-f0-9]{64}$/i.test(config.BASE44_PUSH_RELAY_SECRET || '')) return false;
  try { assertIsolatedSupabase(config); return true; } catch { return false; }
}
export async function sendLegacyPush(input:any,config:Config,fetcher:typeof fetch=fetch) {
  if (!legacyPushConfigured(config) || input.bundleID !== MAIN_PUSH_BUNDLE) throw new AppServiceError('legacy_push_unconfigured','The existing APNs relay has not been enabled.',503);
  const timestamp = String(Math.floor(Date.now()/1000));
  const body = JSON.stringify({version:1,source_project:'bbkfsgnordtdiblgdzkg',event_id:input.eventID,token:input.token,
    environment:input.environment,bundle_id:input.bundleID,kind:input.kind,payload:input.payload,collapse_id:input.collapseID,
    expires_at:Math.floor(input.expiresAt.getTime()/1000)});
  const key = await crypto.subtle.importKey('raw',Uint8Array.from(config.BASE44_PUSH_RELAY_SECRET!.match(/../g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const signature = [...new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(timestamp+'\n'+body)))].map(v=>v.toString(16).padStart(2,'0')).join('');
  const response = await fetcher(CANONICAL_BASE44_ORIGIN+'/api/apps/'+CANONICAL_BASE44_APP_ID+'/functions/supabasePushRelay',{
    method:'POST',redirect:'error',signal:AbortSignal.timeout(15_000),headers:{'Content-Type':'application/json','X-App-Id':CANONICAL_BASE44_APP_ID,
      Origin:CANONICAL_BASE44_ORIGIN,'X-SpyClash-Relay-Timestamp':timestamp,'X-SpyClash-Relay-Signature':signature},body});
  if (!response.ok) return {delivered:false,retryable:response.status>=500||[401,403,404,429].includes(response.status),invalidateToken:false,reason:'relay_http_'+response.status};
  const result = await response.json();
  if (typeof result?.delivered !== 'boolean' || typeof result.retryable !== 'boolean' || typeof result.invalidateToken !== 'boolean'
    || typeof result.reason !== 'string' || !/^[a-zA-Z0-9_]{1,80}$/.test(result.reason)) throw new AppServiceError('legacy_push_response_invalid','The APNs relay response is invalid.',502,true);
  return result;
}

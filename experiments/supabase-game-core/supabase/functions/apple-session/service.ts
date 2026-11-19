import {AppleExchangeError} from './apple.ts';
import {AppleSessionError, type AppleConfig, type AppleRequest, boundedText, clientID, mismatch, parseRequest, unavailable, uuid} from './contracts.ts';
import {encryptGrant, grantBinding} from './crypto.ts';
export function createAuthAPI(config: Pick<AppleConfig,'origin'|'serviceRoleKey'|'anonKey'>, fetcher: typeof fetch = fetch) {
  return {async request(path:string, method='GET', body?:unknown, bearer?:string) {
    const key=path.startsWith('/admin/')?config.serviceRoleKey:config.anonKey;
    let response:Response;
    try {response=await fetcher(config.origin+'/auth/v1'+path,{method,redirect:'error',signal:AbortSignal.timeout(8000),
      headers:{apikey:key,Authorization:'Bearer '+(bearer||key),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});} catch {throw unavailable();}
    if (response.status===404 && method==='GET') return undefined;
    if (!response.ok) throw unavailable();
    try {const text=await boundedText(response,128_000);return text?JSON.parse(text):{};} catch {throw unavailable();}
  }};
}
type Dependencies = {config:AppleConfig; verifier:any; apple:any; repository:any; auth:ReturnType<typeof createAuthAPI>};
export async function exchangeApple(body:AppleRequest, dependencies:Dependencies, signal?:AbortSignal) {
  const {config,verifier,apple,repository,auth}=dependencies;
  const cancelled=()=>{if(signal?.aborted) throw new AppleSessionError('apple_request_cancelled',499);};
  cancelled();
  const assertion=await verifier.presented(body);
  // Prepare all local cryptography before recording an irreversible code request.
  const exchangeBody=await apple.prepareExchange(body.authorization_code);
  await encryptGrant('configuration-check',grantBinding(crypto.randomUUID(),crypto.randomUUID(),clientID),config.encryptionKey);
  const account=await repository.reserve(assertion);
  let candidate:any, refreshToken:string|undefined, grant:any, grantTracked=false, exchangeStarted=false, exchangeConfirmed=false;
  const request=async(...args:Parameters<typeof auth.request>)=>{cancelled();await repository.renew(account);return await auth.request(...args);};
  try {
    cancelled(); await repository.beginExchange(account); cancelled(); exchangeStarted=true;
    const redeemed=await apple.exchange(exchangeBody,async(token:string)=>{
      refreshToken=token;
      const id=crypto.randomUUID();
      grant={id,...await encryptGrant(token,grantBinding(id,account.user_id,clientID),config.encryptionKey)};
      await repository.trackGrant(account,grant); grantTracked=true;
    });
    exchangeConfirmed=true;
    await verifier.redeemed(redeemed.identityToken,assertion);
    cancelled();
    let user=await request('/admin/users/'+account.user_id);
    if (!user) {
      // Never resurrect a migrated/deleted user or guess an owner by Apple email.
      if (account.legacy_user_id || account.state!=='pending' || !config.newAccountsEnabled || !config.migrationCoverageVerified) throw new AppleSessionError('apple_account_unavailable',410);
      try {user=await request('/admin/users','POST',{id:account.user_id,email:account.shadow_email,email_confirm:true,
        app_metadata:{apple_identity_key:account.identity_key,apple_environment:'main'},user_metadata:{full_name:assertion.displayName}});}
      catch(error) {user=await request('/admin/users/'+account.user_id);if(!user)throw error;}
    }
    const existingLegacy=!!account.legacy_user_id;
    if (user.id!==account.user_id || user.email!==account.shadow_email || user.role!=='authenticated' || user.deleted_at ||
      (user.banned_until && Date.parse(user.banned_until)>Date.now()) || (!existingLegacy && user.app_metadata?.apple_identity_key!==account.identity_key)) throw mismatch();
    await repository.provisionProfile(account,assertion.displayName);
    // The private imported mailbox is a trusted Auth delivery handle selected
    // AFTER subject→UUID resolution. It is never compared to Apple's email.
    const link=await request('/admin/generate_link','POST',{type:'magiclink',email:account.shadow_email});
    if (link?.id!==account.user_id || typeof link.hashed_token!=='string' || !link.hashed_token) throw mismatch();
    candidate=await request('/verify','POST',{type:'email',token_hash:link.hashed_token});
    if (candidate?.user?.id!==account.user_id || candidate.token_type!=='bearer' || typeof candidate.access_token!=='string' || !candidate.access_token ||
      typeof candidate.refresh_token!=='string' || !candidate.refresh_token || !Number.isInteger(candidate.expires_in) || candidate.expires_in<1 || candidate.expires_in>3600) throw mismatch();
    let claims:any;
    try {claims=JSON.parse(atob(candidate.access_token.split('.')[1].replaceAll('-','+').replaceAll('_','/')));} catch {throw mismatch();}
    if (claims.sub!==account.user_id || claims.role!=='authenticated' || !uuid(claims.session_id) || !Number.isInteger(claims.exp)) throw mismatch();
    const verifiedUser=await request('/user','GET',undefined,candidate.access_token);
    if (verifiedUser?.id!==account.user_id) throw mismatch();
    cancelled(); await repository.complete(account,claims.session_id); cancelled();
    return {provider:'apple',access_token:candidate.access_token,refresh_token:candidate.refresh_token,token_type:'bearer',
      expires_in:candidate.expires_in,expires_at:claims.exp,user:{id:account.user_id},migration_version:1};
  } catch(error) {
    if (candidate?.access_token) {try {await auth.request('/logout?scope=local','POST',{},candidate.access_token);} catch {/* Never return an unverified candidate. */}}
    let uncertain=exchangeStarted && !exchangeConfirmed && !grantTracked && !(error instanceof AppleExchangeError && error.outcome==='not_issued');
    if (refreshToken) {
      try {await apple.revoke(refreshToken);if(grantTracked)await repository.revoked(grant.id);uncertain=false;}
      catch {uncertain=!grantTracked; /* A durable encrypted active grant remains revocable by deletion. */}
    }
    try {await repository.settleFailure(account,uncertain);} catch {/* Existing exchanging marker stays fail-closed. */}
    throw error;
  } finally {await repository.release(account).catch(()=>{});}
}
export function createAppleHandler(dependencies:Dependencies) {
  return async(request:Request)=>{
    const headers={'Content-Type':'application/json','Cache-Control':'no-store','Pragma':'no-cache'};
    if(request.method!=='POST')return Response.json({code:'method_not_allowed',retryable:false},{status:405,headers:{...headers,Allow:'POST'}});
    try {
      if(!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type')||''))throw new AppleSessionError('invalid_request',415);
      let body:AppleRequest;
      try {body=parseRequest(JSON.parse(await boundedText(request,32_768,new AppleSessionError('invalid_request',413))));} catch(error) {if(error instanceof AppleSessionError)throw error;throw new AppleSessionError('invalid_request',400);}
      const result=await exchangeApple(body,dependencies,request.signal);
      return Response.json(result,{headers});
    } catch(error) {
      const failure=error instanceof AppleSessionError?error:unavailable();
      return Response.json({code:failure.code,message:failure.retryable?'Apple sign-in could not be completed. Please try again.':'Apple sign-in could not be verified.',retryable:failure.retryable},{status:failure.status,headers});
    }
  };
}

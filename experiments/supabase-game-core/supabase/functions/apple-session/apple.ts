import {createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT, type JWTVerifyGetKey, type KeyLike} from 'npm:jose@5.10.0';
import {AppleSessionError, type AppleConfig, type AppleRequest, type Assertion, boundedText, clientID, issuer, mismatch, unavailable} from './contracts.ts';
import {digest, same, subjectIdentity} from './crypto.ts';
const remoteKeys = createRemoteJWKSet(new URL(issuer + '/auth/keys'), {timeoutDuration:8000,cooldownDuration:30_000,cacheMaxAge:600_000});
export function createAppleVerifier(config: Pick<AppleConfig,'pseudonymKey'>, keys: JWTVerifyGetKey | KeyLike = remoteKeys, now = () => new Date()) {
  async function token(token: string, nonceHash: string) {
    try {
      if (!token || token.length > 20_000) throw mismatch();
      const options = {algorithms:['RS256'],issuer,audience:clientID,requiredClaims:['sub','nonce','iat','exp'],clockTolerance:5,maxTokenAge:300,currentDate:now()};
      // Both overloads perform identical validation; no token-controlled JWKS URL.
      const {payload} = typeof keys === 'function' ? await jwtVerify(token,keys,options) : await jwtVerify(token,keys,options);
      if (payload.aud !== clientID || typeof payload.sub !== 'string' || !payload.sub || payload.sub.length>512 || typeof payload.nonce !== 'string' || !same(payload.nonce,nonceHash)) throw mismatch();
      return payload.sub;
    } catch (error) {
      if (error instanceof AppleSessionError) throw error;
      // Network/key rotation failures are recoverable, malformed signed assertions are not.
      if (error instanceof TypeError || (error as {code?:string})?.code === 'ERR_JWKS_TIMEOUT') throw unavailable();
      throw new AppleSessionError('invalid_apple_assertion',401);
    }
  }
  return {
    async presented(body: AppleRequest): Promise<Assertion> {
      const nonceHash = await digest(body.raw_nonce);
      const subject = await token(body.identity_token,nonceHash);
      const identity = await subjectIdentity(subject,config.pseudonymKey);
      const displayName = [body.given_name,body.family_name].filter(Boolean).join(' ').replace(/[\u0000-\u001f\u007f]/g,' ').replace(/\s+/g,' ').trim().slice(0,100) || 'Operative';
      return {...identity,subject,nonceHash,codeHash:await digest(body.authorization_code),requestID:body.request_id,displayName};
    },
    async redeemed(identityToken: string, assertion: Assertion) {
      const subject = await token(identityToken,assertion.nonceHash);
      if (!same(subject,assertion.subject)) throw mismatch();
    },
  };
}
export class AppleExchangeError extends AppleSessionError {
  constructor(public outcome: 'not_issued'|'uncertain') {super('apple_code_exchange_failed',502,true);}
}
export function createAppleAPI(config: Pick<AppleConfig,'teamID'|'keyID'|'privateKeyPEM'>, fetcher: typeof fetch = fetch) {
  let privateKey: Promise<KeyLike> | undefined;
  const clientSecret = async (audience=clientID) => {
    privateKey ||= importPKCS8(config.privateKeyPEM,'ES256');
    return await new SignJWT({}).setProtectedHeader({alg:'ES256',kid:config.keyID,typ:'JWT'}).setIssuer(config.teamID)
      .setSubject(audience).setAudience(issuer).setIssuedAt().setExpirationTime('5m').sign(await privateKey);
  };
  return {
    // Prepare signing before acquiring the irreversible issuance boundary.
    async prepareExchange(code: string) {
      return new URLSearchParams({grant_type:'authorization_code',code,client_id:clientID,client_secret:await clientSecret()});
    },
    async exchange(body: URLSearchParams, onGrant: (token:string)=>Promise<void>) {
      let response: Response;
      try {response=await fetcher(issuer+'/auth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded',Accept:'application/json'},body,redirect:'error',signal:AbortSignal.timeout(12_000)});} catch {throw new AppleExchangeError('uncertain');}
      let data: Record<string,unknown>;
      try {data=JSON.parse(await boundedText(response,64_000));} catch {throw new AppleExchangeError('uncertain');}
      const refreshToken = typeof data.refresh_token==='string' && data.refresh_token.length<=20_000 ? data.refresh_token : '';
      // Persist every observed grant before validating other fields. A malformed
      // Apple reply must not strand a new refresh token outside deletion tracking.
      if (refreshToken) await onGrant(refreshToken);
      if (!response.ok || !refreshToken || typeof data.id_token!=='string' || data.id_token.length>20_000) {
        const denied = !refreshToken && response.status===400 && ['invalid_grant','invalid_client','invalid_request','unauthorized_client','unsupported_grant_type'].includes(String(data.error));
        throw new AppleExchangeError(denied?'not_issued':'uncertain');
      }
      return {identityToken:data.id_token};
    },
    async revoke(token: string, audience=clientID) {
      // Imported web grants use their original client ID, never the native ID.
      if (!audience || audience.length>255 || !token || token.length>20_000) throw unavailable();
      const body=new URLSearchParams({client_id:audience,client_secret:await clientSecret(audience),token,token_type_hint:'refresh_token'});
      let response: Response;
      try {response=await fetcher(issuer+'/auth/revoke',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body,redirect:'error',signal:AbortSignal.timeout(12_000)});} catch {throw unavailable();}
      // Apple returns 200 for an already invalid/revoked token. Other statuses
      // do not prove revocation and retain the encrypted grant for retry.
      if (!response.ok) throw unavailable();
    },
  };
}

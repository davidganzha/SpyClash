import { AppServiceError } from './contracts.ts';

export type LegacyConfig = Record<string, string | undefined>;
export const ISOLATED_SUPABASE_ORIGIN = 'https://bbkfsgnordtdiblgdzkg.supabase.co';
export const CANONICAL_BASE44_ORIGIN = 'https://spyclash.com';
export const CANONICAL_BASE44_APP_ID = '69a0e57fa939f578082f8091';

export function assertIsolatedSupabase(config: LegacyConfig): string {
  let url: URL;
  try { url = new URL(config.SUPABASE_URL || ''); }
  catch { throw new AppServiceError('legacy_bridge_unconfigured', 'The isolated authentication bridge is not configured.', 503); }
  const local = ['127.0.0.1', 'localhost', 'kong'].includes(url.hostname) && url.protocol === 'http:';
  if ((!local && url.origin !== ISOLATED_SUPABASE_ORIGIN) || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new AppServiceError('legacy_destination_forbidden', 'Only the isolated Supabase project is allowed.', 503);
  }
  return url.origin;
}

/** Defaults are public destinations, never credentials. Existing Base44 auth and
 * generation may be consumed only by the isolated Supabase application. */
export function canonicalBase44Configuration(config: LegacyConfig) {
  if (config.LEGACY_BRIDGE_ENABLED === 'false') throw new AppServiceError('legacy_bridge_unconfigured', 'The Base44 bridge is disabled.', 503);
  if (!config.BASE44_STAGING_ORIGIN && !config.BASE44_STAGING_APP_ID) {
    assertIsolatedSupabase(config);
    return { origin: CANONICAL_BASE44_ORIGIN, appID: CANONICAL_BASE44_APP_ID };
  }
  let url: URL, allowlist: unknown;
  try { url = new URL(config.BASE44_STAGING_ORIGIN || ''); allowlist = JSON.parse(config.BASE44_STAGING_ORIGIN_ALLOWLIST || '[]'); }
  catch { throw new AppServiceError('legacy_bridge_unconfigured', 'The Base44 bridge is not configured.', 503); }
  const appID = config.BASE44_STAGING_APP_ID || '';
  if (url.origin === CANONICAL_BASE44_ORIGIN && appID === CANONICAL_BASE44_APP_ID) {
    assertIsolatedSupabase(config);
  } else if (config.LEGACY_BRIDGE_ENABLED !== 'true' || config.APP_ENVIRONMENT !== 'staging'
    || !Array.isArray(allowlist) || !allowlist.includes(url.origin) || appID === CANONICAL_BASE44_APP_ID) {
    throw new AppServiceError('legacy_destination_forbidden', 'The Base44 destination is not allowed.', 503);
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash || !/^[a-f0-9]{24}$/.test(appID)) {
    throw new AppServiceError('legacy_destination_forbidden', 'The Base44 destination is not allowed.', 503);
  }
  return { origin: url.origin, appID };
}

export function legacyCredential(value: unknown): string {
  if (typeof value !== 'string' || value.length < 20 || value.length > 20_000 || /[\r\n]/.test(value)) {
    throw new AppServiceError('legacy_session_required', 'Sign in to your Base44 account again.', 401);
  }
  if (value.startsWith('sb_')) throw new AppServiceError('wrong_credential_provider', 'A Supabase credential cannot authorize Base44.', 401);
  // Decoding is only a rejection filter; User/me is the identity authority.
  let claims: any;
  try { claims = JSON.parse(atob(value.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch { /* opaque legacy credential */ }
  if (typeof claims?.iss === 'string' && (/supabase/i.test(claims.iss) || claims.iss.endsWith('/auth/v1'))) {
    throw new AppServiceError('wrong_credential_provider', 'A Supabase credential cannot authorize Base44.', 401);
  }
  return value;
}

export async function boundedLegacyJSON(response: Response): Promise<any> {
  const raw = await response.text();
  if (raw.length > 256_000) throw new AppServiceError('legacy_response_invalid', 'The provider returned an invalid response.', 502);
  try { return JSON.parse(raw); } catch { throw new AppServiceError('legacy_response_invalid', 'The provider returned an invalid response.', 502); }
}

export async function verifyLegacyCredential(config: LegacyConfig, value: unknown, fetcher: typeof fetch = fetch) {
  const destination = canonicalBase44Configuration(config);
  const credential = legacyCredential(value);
  let response: Response;
  try {
    response = await fetcher(destination.origin + '/api/apps/' + destination.appID + '/entities/User/me', {
      headers: { Authorization: 'Bearer ' + credential, 'X-App-Id': destination.appID, Origin: destination.origin },
      redirect: 'error', signal: AbortSignal.timeout(10_000),
    });
  } catch { throw new AppServiceError('legacy_verification_unavailable', 'Base44 authentication is temporarily unavailable.', 503, true); }
  if (!response.ok) throw new AppServiceError(response.status >= 500 ? 'legacy_verification_unavailable' : 'legacy_session_invalid',
    response.status >= 500 ? 'Base44 authentication is temporarily unavailable.' : 'The Base44 session has expired.', response.status >= 500 ? 503 : 401, response.status >= 500);
  const identity = await boundedLegacyJSON(response);
  if (!identity || typeof identity.id !== 'string' || !identity.id.trim() || identity.id.length > 200) {
    throw new AppServiceError('legacy_identity_invalid', 'The Base44 identity could not be verified.', 422);
  }
  return { ...destination, credential, identity };
}

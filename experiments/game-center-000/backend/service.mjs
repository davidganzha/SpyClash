import { Buffer } from 'node:buffer';
import { GameCenterError, unavailable, createAssertionVerifier, readJSON } from './assertion.mjs';
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const mismatch = () => new GameCenterError('game_center_identity_mismatch', 'The account identity could not be verified.', 409);

export function createAuthAPI(config, fetcher = fetch) {
  return {
    async request(path, method = 'GET', body, accessToken) {
      const key = path.startsWith('/admin/') ? config.serviceRoleKey : config.anonKey;
      let response;
      try {
        response = await fetcher(config.origin + '/auth/v1' + path, {method, redirect: 'error', signal: AbortSignal.timeout(8000),
          headers: {apikey: key, Authorization: 'Bearer ' + (accessToken || key), 'Content-Type': 'application/json'},
          ...(body === undefined ? {} : {body: JSON.stringify(body)})});
      } catch { throw unavailable(); }
      if (response.status === 404 && method === 'GET') return undefined;
      if (!response.ok) throw unavailable();
      const raw = await response.text(); if (raw.length > 128_000) throw unavailable();
      try { return raw ? JSON.parse(raw) : {}; } catch { throw unavailable(); }
    },
  };
}
export async function exchangeGameCenter(body, {verify = createAssertionVerifier(), repository, auth}) {
  const assertion = await verify(body);
  const account = await repository.reserve(assertion);
  let candidate;
  const request = async (...args) => { await repository.renew(account); return await auth.request(...args); };
  try {
    let user = await request('/admin/users/' + account.user_id);
    if (!user) {
      // A ready identity whose Auth user was deleted must never be silently revived.
      if (account.state !== 'pending') throw new GameCenterError('game_center_account_unavailable', 'This account is unavailable.', 410);
      try {
        user = await request('/admin/users', 'POST', {id: account.user_id, email: account.shadow_email, email_confirm: true,
          app_metadata: {game_center_identity_key: account.identity_key, game_center_environment: 'experimental-000'},
          user_metadata: {full_name: assertion.displayName}});
      } catch (error) {
        // A lost create ACK is recovered by the reserved UUID; never nickname/email.
        user = await request('/admin/users/' + account.user_id); if (!user) throw error;
      }
    }
    if (user.id !== account.user_id || user.email !== account.shadow_email || user.role !== 'authenticated' ||
        user.app_metadata?.game_center_identity_key !== account.identity_key || user.app_metadata?.game_center_environment !== 'experimental-000' ||
        user.deleted_at || (user.banned_until && Date.parse(user.banned_until) > Date.now())) throw mismatch();
    await repository.provisionProfile(account, assertion.displayName);
    // Admin generate_link does not send an email. The server alone consumes the
    // single-use token and returns a standard, revocable Supabase session.
    const link = await request('/admin/generate_link', 'POST', {type: 'magiclink', email: account.shadow_email});
    if (link.id !== account.user_id || typeof link.hashed_token !== 'string' || !link.hashed_token) throw mismatch();
    candidate = await request('/verify', 'POST', {type: 'email', token_hash: link.hashed_token});
    if (candidate.user?.id !== account.user_id || candidate.token_type !== 'bearer' || typeof candidate.access_token !== 'string' ||
        typeof candidate.refresh_token !== 'string' || !candidate.refresh_token || !Number.isInteger(candidate.expires_in) || candidate.expires_in < 1 || candidate.expires_in > 3600) throw mismatch();
    let claims;
    try { claims = JSON.parse(Buffer.from(candidate.access_token.split('.')[1], 'base64url').toString('utf8')); } catch { throw mismatch(); }
    if (claims.sub !== account.user_id || claims.role !== 'authenticated' || !uuid(claims.session_id)) throw mismatch();
    // Readback with the issued bearer proves Auth recognizes the same user.
    const verifiedUser = await request('/user', 'GET', undefined, candidate.access_token);
    if (verifiedUser.id !== account.user_id || verifiedUser.app_metadata?.game_center_identity_key !== account.identity_key) throw mismatch();
    await repository.complete(account, claims.session_id);
    return {provider: 'game_center', access_token: candidate.access_token, refresh_token: candidate.refresh_token,
      token_type: 'bearer', expires_in: candidate.expires_in, expires_at: candidate.expires_at || claims.exp, user: {id: account.user_id}};
  } catch (error) {
    if (candidate?.access_token) {
      try { await auth.request('/logout?scope=local', 'POST', {}, candidate.access_token); } catch { /* Candidate was never returned. */ }
    }
    throw error;
  } finally { await repository.release(account); }
}
export function createGameCenterHandler(dependencies) {
  return async request => {
    const headers = {'Content-Type': 'application/json', 'Cache-Control': 'no-store'};
    if (request.method !== 'POST') return Response.json({code: 'method_not_allowed', message: 'POST required.'}, {status: 405, headers: {...headers, Allow: 'POST'}});
    try {
      const body = await readJSON(request);
      const result = await exchangeGameCenter(body, dependencies);
      return Response.json(result, {headers});
    } catch (error) {
      const failure = error instanceof GameCenterError ? error : unavailable();
      return Response.json({code: failure.code, message: failure.message, retryable: failure.retryable}, {status: failure.status, headers});
    }
  };
}

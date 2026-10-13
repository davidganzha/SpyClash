import { AppServiceError, requireUUID, type AppContext } from '../app-services/contracts.ts';
import { digest } from '../app-services/integration-crypto.ts';
import { assertIsolatedSupabase, verifyLegacyCredential, type LegacyConfig } from '../app-services/legacy-provider.ts';

type Dependencies = {
  db: any;
  config: LegacyConfig;
  fetch?: typeof fetch;
  prepareImport?: (input: {origin: string; appID: string; accessToken: string; expectedLegacyID: string}, dependencies: {fetch: typeof fetch; db: any}) => Promise<unknown>;
  applyImport?: (ctx: AppContext, snapshot: any) => Promise<{complete: boolean}>;
  ensureProfile: (ctx: AppContext) => Promise<unknown>;
};
const unavailable = () => new AppServiceError('legacy_session_unavailable', 'The game session could not be prepared. Please retry.', 503, true);
const busy = () => new AppServiceError('legacy_session_busy', 'Another sign-in is being completed. Please retry.', 409, true);
const ownership = () => new AppServiceError('legacy_owner_mismatch', 'The existing account cannot be linked to a different identity.', 409);

async function accountAvailable(tx: any, userID: string) {
  await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:' + userID},0))`;
  // The shared advisory gate excludes deletion. A profile row SHARE lock here
  // would deadlock a concurrent reservation with the importer's profile UPDATE.
  const [profile] = await tx`select state from app_private.profiles where user_id=${userID}`;
  if (profile && profile.state !== 'active') throw new AppServiceError('account_unavailable', 'This staging account has been deleted.', 410);
}

async function reserve(db: any, identityKey: string, legacyID: string, origin: string, appID: string) {
  return db.begin(async (tx: any) => {
    // Discover the candidate without locks, then use the same account -> legacy
    // lock order as app-services deletion/link. A racing first reservation retries.
    const [initialLink] = await tx`select user_id from app_private.legacy_links where legacy_user_id=${legacyID}`;
    const [initialRow] = await tx`select user_id from app_private.legacy_session_accounts where legacy_user_id=${legacyID}`;
    const candidateID = initialRow?.user_id || initialLink?.user_id || crypto.randomUUID();
    await accountAvailable(tx, candidateID);
    await tx`select pg_advisory_xact_lock(hashtextextended(${'legacy:' + legacyID},0))`;
    const [link] = await tx`select * from app_private.legacy_links where legacy_user_id=${legacyID} for update`;
    if (link && (link.state !== 'active' || link.source_origin !== origin)) throw ownership();
    let [row] = await tx`select * from app_private.legacy_session_accounts where legacy_user_id=${legacyID} for update`;
    if (row && (row.identity_key !== identityKey || row.source_origin !== origin || row.source_app_id !== appID || (link && row.user_id !== link.user_id))) throw ownership();
    if ((row && row.user_id !== candidateID) || (link && link.user_id !== candidateID)) throw busy();
    if (!row) {
      const userID = candidateID;
      // Private unpredictable mailbox prevents ordinary sign-up squatting.
      const shadowEmail = crypto.randomUUID().replaceAll('-', '') + '@accounts.spyclash.invalid';
      [row] = await tx`insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email,existing_link)
        values(${identityKey},${legacyID},${origin},${appID},${userID},${shadowEmail},${!!link}) returning *`;
    }
    const leaseID = crypto.randomUUID();
    const [leased] = await tx`update app_private.legacy_session_accounts set lease_id=${leaseID},lease_until=clock_timestamp()+interval '120 seconds',updated_at=clock_timestamp()
      where identity_key=${identityKey} and (lease_until is null or lease_until<=clock_timestamp()) returning *`;
    if (!leased) throw busy();
    return leased;
  });
}

async function renew(db: any, account: any) {
  await db.begin(async (tx: any) => {
    await accountAvailable(tx, account.user_id);
    const [link] = await tx`select state,user_id,source_origin from app_private.legacy_links where legacy_user_id=${account.legacy_user_id}`;
    if (link && (link.state !== 'active' || link.user_id !== account.user_id || link.source_origin !== account.source_origin)) throw ownership();
    const rows = await tx`update app_private.legacy_session_accounts set lease_until=clock_timestamp()+interval '120 seconds',updated_at=clock_timestamp()
      where identity_key=${account.identity_key} and lease_id=${account.lease_id} and lease_until>clock_timestamp() returning identity_key`;
    if (!rows.length) throw busy();
  });
}

/** Auth's documented Admin createUser / generateLink and verifyOtp APIs. No
 * password, email delivery or custom JWT minting is used by this bridge. */
export async function exchangeLegacySession(credential: string, dependencies: Dependencies) {
  const {db, config} = dependencies;
  const authOrigin = assertIsolatedSupabase(config);
  if (!config.SUPABASE_SERVICE_ROLE_KEY || !config.SUPABASE_ANON_KEY) throw unavailable();
  const fetcher = dependencies.fetch || fetch;
  const verified = await verifyLegacyCredential(config, credential, fetcher);
  const identityKey = await digest(verified.origin + '\n' + verified.appID + '\n' + verified.identity.id);
  const account = await reserve(db, identityKey, verified.identity.id, verified.origin, verified.appID);
  let candidate: any;
  const guardedFetch: typeof fetch = async (input, init) => { await renew(db, account); return fetcher(input, init); };
  const authRequest = async (path: string, method = 'GET', body?: any, accessToken?: string) => {
    const administrative = path.startsWith('/admin/');
    const key = administrative ? config.SUPABASE_SERVICE_ROLE_KEY! : config.SUPABASE_ANON_KEY!;
    let response: Response;
    try {
      response = await guardedFetch(authOrigin + '/auth/v1' + path, {
        method, headers: { apikey: key, Authorization: 'Bearer ' + (accessToken || key), 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : {body: JSON.stringify(body)}), redirect: 'error', signal: AbortSignal.timeout(10_000),
      });
    } catch (error) { if (error instanceof AppServiceError) throw error; throw unavailable(); }
    if (response.status === 404 && method === 'GET') return undefined;
    if (!response.ok) throw unavailable();
    const raw = await response.text();
    if (raw.length > 256_000) throw unavailable();
    try { return JSON.parse(raw); } catch { throw unavailable(); }
  };
  try {
    let user = await authRequest('/admin/users/' + account.user_id);
    if (!user) {
      if (account.existing_link || account.state === 'ready') throw new AppServiceError('account_unavailable', 'This staging account is no longer available.', 410);
      try {
        user = await authRequest('/admin/users', 'POST', {
          id: account.user_id, email: account.shadow_email, email_confirm: true,
          app_metadata: {legacy_provider: 'base44', legacy_identity_key: identityKey},
          user_metadata: {full_name: String(verified.identity.full_name || verified.identity.display_name || 'Operative').slice(0,100)},
        });
      } catch (error) {
        // Lost create ACK is recovered by the reserved UUID, never contact email.
        user = await authRequest('/admin/users/' + account.user_id);
        if (!user) throw error;
      }
    }
    if (user.id !== account.user_id || user.role !== 'authenticated' || typeof user.email !== 'string' || !user.email) throw ownership();
    if (!account.existing_link && (user.email !== account.shadow_email || user.app_metadata?.legacy_provider !== 'base44' || user.app_metadata?.legacy_identity_key !== identityKey)) throw ownership();

    const actor = {id: account.user_id, email: account.user_id + '@example.test',
      contactEmail: typeof verified.identity.email === 'string' ? verified.identity.email.slice(0,320) : '',
      full_name: String(verified.identity.full_name || verified.identity.display_name || 'Operative').slice(0,100), metadata: {}};
    let snapshot: unknown;
    if (!account.import_completed && dependencies.prepareImport) {
      snapshot = await dependencies.prepareImport({origin: verified.origin, appID: verified.appID, accessToken: verified.credential, expectedLegacyID: verified.identity.id}, {fetch: guardedFetch, db});
    }
    const importComplete = await db.begin(async (tx: any) => {
      await accountAvailable(tx, account.user_id);
      await tx`select pg_advisory_xact_lock(hashtextextended(${'legacy:' + account.legacy_user_id},0))`;
      const [owned] = await tx`select identity_key from app_private.legacy_session_accounts where identity_key=${identityKey} and lease_id=${account.lease_id} and lease_until>clock_timestamp() for update`;
      if (!owned) throw busy();
      const links = await tx`select * from app_private.legacy_links where user_id=${account.user_id} or legacy_user_id=${account.legacy_user_id} for update`;
      if (links.some((row: any) => row.state !== 'active' || row.user_id !== account.user_id || row.legacy_user_id !== account.legacy_user_id || row.source_origin !== verified.origin)) throw ownership();
      await tx`insert into app_private.legacy_links(user_id,legacy_user_id,verified_at,source_origin)
        values(${account.user_id},${account.legacy_user_id},clock_timestamp(),${verified.origin})
        on conflict(user_id) do update set verified_at=excluded.verified_at`;
      const ctx = {tx, actor, now: new Date(), config};
      const result = snapshot && dependencies.applyImport ? await dependencies.applyImport(ctx, snapshot) : {complete: true};
      if (result.complete) {
        await dependencies.ensureProfile(ctx);
        await tx`update app_private.profiles set contact_email=${actor.contactEmail},updated_at=clock_timestamp() where user_id=${account.user_id} and state='active'`;
      }
      await tx`update app_private.legacy_session_accounts set import_completed=${result.complete},last_verified_at=clock_timestamp(),updated_at=clock_timestamp()
        where identity_key=${identityKey} and lease_id=${account.lease_id}`;
      return result.complete;
    });
    if (!importComplete) throw new AppServiceError('legacy_import_pending', 'Your existing game data is still being transferred. Please retry.', 503, true);
    const link = await authRequest('/admin/generate_link', 'POST', {type: 'magiclink', email: user.email});
    if (link?.id !== account.user_id || typeof link.hashed_token !== 'string' || !link.hashed_token) throw ownership();
    candidate = await authRequest('/verify', 'POST', {token_hash: link.hashed_token, type: 'email'});
    if (candidate?.user?.id !== account.user_id || typeof candidate.access_token !== 'string' || typeof candidate.refresh_token !== 'string'
      || candidate.token_type !== 'bearer' || !Number.isFinite(candidate.expires_in)) throw ownership();
    let claims: any;
    try { claims = JSON.parse(atob(candidate.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch { throw unavailable(); }
    if (claims.sub !== account.user_id || claims.role !== 'authenticated') throw ownership();
    const sessionID = requireUUID(claims.session_id, 'session_id');
    await db.begin(async (tx: any) => {
      await accountAvailable(tx, account.user_id);
      await tx`select pg_advisory_xact_lock(hashtextextended(${'legacy:' + account.legacy_user_id},0))`;
      const [owned] = await tx`select * from app_private.legacy_session_accounts where identity_key=${identityKey} and lease_id=${account.lease_id} and lease_until>clock_timestamp() for update`;
      if (!owned) throw busy();
      const links = await tx`select * from app_private.legacy_links where user_id=${account.user_id} or legacy_user_id=${account.legacy_user_id} for update`;
      if (links.some((row: any) => row.state !== 'active' || row.user_id !== account.user_id || row.legacy_user_id !== account.legacy_user_id || row.source_origin !== verified.origin)) throw ownership();
      const sessions = await tx`select id from auth.sessions where id=${sessionID} and user_id=${account.user_id} and (not_after is null or not_after>clock_timestamp())`;
      if (!sessions.length) throw new AppServiceError('unauthorized', 'The new session is no longer active.', 401);
      if (links.length !== 1) throw ownership();
      await tx`update app_private.legacy_session_accounts set state='ready',last_verified_at=clock_timestamp(),lease_id=null,lease_until=null,updated_at=clock_timestamp()
        where identity_key=${identityKey} and lease_id=${account.lease_id}`;
    });
    return {access_token: candidate.access_token, refresh_token: candidate.refresh_token, token_type: 'bearer',
      expires_in: candidate.expires_in, expires_at: Number.isFinite(candidate.expires_at) ? candidate.expires_at : claims.exp,
      user: candidate.user, legacy_user_id: account.legacy_user_id};
  } catch (error) {
    // Revoke only this unreturned candidate; never sign out a concurrent winner.
    if (candidate?.access_token) {
      try { await fetcher(authOrigin + '/auth/v1/logout?scope=local', {method: 'POST', headers: {apikey: config.SUPABASE_ANON_KEY!, Authorization: 'Bearer ' + candidate.access_token}, redirect: 'error', signal: AbortSignal.timeout(8_000)}); } catch { /* account gate still denies deleted identities */ }
    }
    throw error;
  } finally {
    await db`update app_private.legacy_session_accounts set lease_id=null,lease_until=null,updated_at=clock_timestamp()
      where identity_key=${identityKey} and lease_id=${account.lease_id}`;
  }
}

export function createLegacySessionHandler(dependencies: Dependencies) {
  return async (request: Request): Promise<Response> => {
    const headers = {'Content-Type': 'application/json', 'Cache-Control': 'no-store'};
    if (request.method !== 'POST') return new Response(JSON.stringify({error: 'method_not_allowed'}), {status: 405, headers: {...headers, Allow: 'POST'}});
    try {
      if (!request.headers.get('content-type')?.includes('application/json')) throw new AppServiceError('invalid_request', 'A JSON request is required.', 415);
      if (Number(request.headers.get('content-length')) > 1024) throw new AppServiceError('invalid_request', 'The request is too large.', 413);
      const raw = await request.text();
      if (raw.length > 1024) throw new AppServiceError('invalid_request', 'The request is too large.', 413);
      let body: any;
      try { body = JSON.parse(raw); } catch { throw new AppServiceError('invalid_request', 'Invalid JSON.'); }
      if (!body || body.action !== 'exchange' || Object.keys(body).some(key => key !== 'action')) throw new AppServiceError('invalid_request', 'Use the exchange action.');
      const authorization = request.headers.get('authorization') || '';
      if (!authorization.startsWith('Bearer ')) throw new AppServiceError('legacy_session_required', 'A Base44 session is required.', 401);
      const session = await exchangeLegacySession(authorization.slice(7), dependencies);
      return new Response(JSON.stringify(session), {status: 200, headers});
    } catch (error) {
      const failure = error instanceof AppServiceError ? error : unavailable();
      return new Response(JSON.stringify({error: failure.code, message: failure.message, retryable: failure.retryable,
        ...(failure.retryable ? {retry_after_ms: 1000} : {})}), {status: failure.status, headers});
    }
  };
}

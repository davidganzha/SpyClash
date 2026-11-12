import postgres from 'npm:postgres@3.4.9';
import { Buffer } from 'node:buffer';

const deadlineMilliseconds = 20_000;
const defaultHandler = new URL('../../experiments/supabase-game-core/supabase/functions/app-services/handler.ts', import.meta.url);
const configuration = {
  APP_BILLING_PROVIDER: 'base44', APP_IAP_ENABLED: 'true',
  APP_NATIVE_GAME_CENTER_IAP_ENABLED: 'true', APP_IAP_BUNDLE_ID: 'com.spyclash.ios',
  APP_IAP_APPLE_ID: '6793534085', APP_IAP_ENVIRONMENT: 'SandboxAndProduction',
  SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED: 'true', APP_IAP_KEY_ID: 'fixture',
  APP_IAP_ISSUER_ID: 'fixture', APP_IAP_PRIVATE_KEY_P8: 'fixture',
  APP_IAP_ROOT_CERTIFICATES_JSON: '[]',
};

async function bounded<T>(operation: Promise<T>, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Local probe deadline: ${label}`)), deadlineMilliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

function localDatabaseURL(): URL {
  const url = new URL(Deno.env.get('SPYCLASH_TEST_DATABASE_URL') || '');
  const allowed = url.hostname === '127.0.0.1' && url.port === '56322'
    || url.hostname === 'supabase_db_spyclash-game-core-test' && url.port === '5432';
  if (!allowed || url.pathname !== '/postgres') throw new Error('Only the designated local fixture database is allowed');
  return url;
}

export async function runMembershipConcurrency(mode: string, idleSeconds = 16, injectedHandler?: { createAppHandler: any; sourceSHA256: string }) {
  if (!['direct', 'transaction', 'session'].includes(mode)) throw new Error('Unknown local probe mode');
  const poolMax = Number(Deno.env.get('SPYCLASH_TEST_POOL_MAX') || '3');
  if (![1, 3].includes(poolMax)) throw new Error('Probe supports only pool max 1 or 3');
  const controlURL = localDatabaseURL();
  const serviceURL = new URL(controlURL);
  if (mode !== 'direct') {
    const inDocker = controlURL.hostname !== '127.0.0.1';
    serviceURL.hostname = inDocker ? 'spyclash-repair235-pooler-probe' : '127.0.0.1';
    serviceURL.port = inDocker ? mode === 'session' ? '5432' : '6543' : mode === 'session' ? '59015' : '59016';
    serviceURL.username += '.repair235';
  }
  // Edge's DNS shim does not resolve names on this isolated Docker bridge.
  // Overrides are restricted to the bridge used by the local Supabase stack.
  for (const [url, key] of [[controlURL, 'SPYCLASH_TEST_DATABASE_IP'], [serviceURL, mode === 'direct' ? 'SPYCLASH_TEST_DATABASE_IP' : 'SPYCLASH_TEST_POOLER_IP']] as const) {
    const ip = Deno.env.get(key);
    if (!ip) continue;
    if (controlURL.hostname === '127.0.0.1' || !/^172\.18\.0\.[1-9]\d{0,2}$/.test(ip)) throw new Error('Invalid local Docker bridge IP');
    url.hostname = ip;
  }
  const handlerURL = new URL(Deno.env.get('SPYCLASH_TEST_HANDLER_URL') || defaultHandler.href);
  if (handlerURL.protocol !== 'file:') throw new Error('Handler must be a local source file');
  const { createAppHandler } = injectedHandler || await import(handlerURL.href);
  const handlerSHA256 = injectedHandler?.sourceSHA256 || Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', await Deno.readFile(handlerURL))))
    .map(value => value.toString(16).padStart(2, '0')).join('');
  const scenarios = [];
  for (const concurrency of [3, 12, 30]) {
    // A new database client, handler, account and session for every first wave.
    const control = postgres(controlURL.href, { prepare: false, max: 1, connect_timeout: 8, onnotice() {} });
    const queryTrace: Array<{ connection: number; query: string }> = [];
    let queries = 0;
    const db = postgres(serviceURL.href, {
      prepare: false, max: poolMax, idle_timeout: 15, connect_timeout: 8, onnotice() {},
      debug(connection, query) {
        queries++;
        queryTrace.push({ connection, query: query.replace(/\s+/g, ' ').slice(0, 180) });
        if (queryTrace.length > 8) queryTrace.shift();
      },
    });
    const userID = crypto.randomUUID(), sessionID = crypto.randomUUID();
    const token = `fixture.${Buffer.from(JSON.stringify({ session_id: sessionID })).toString('base64url')}.fixture`;
    const user = { id: userID, email: `${userID}@example.test`, user_metadata: { full_name: 'Local Membership Probe' } };
    let externalCalls = 0;
    const handler = createAppHandler({
      db, config: configuration, authenticate: async () => user,
      fetch: async () => { externalCalls++; throw new Error('Unexpected external call for zero-entitlement fixture'); },
    });
    async function call(index: number) {
      const [service, action] = index % 3 === 0 ? ['membership', 'check'] : index % 3 === 1 ? ['profile', 'current'] : ['notifications', 'summary'];
      const body = JSON.stringify({ service, action });
      const started = performance.now();
      const response = await handler(new Request('http://127.0.0.1/app-services', {
        method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body,
      }));
      const result = await response.json();
      return {
        service, action, requestBytes: new TextEncoder().encode(body).length, status: response.status,
        milliseconds: Math.round(performance.now() - started),
        ...(result.code ? { code: result.code } : {}),
        ...(service === 'membership' ? { active: result.active, remaining: result.ai_remaining } : {}),
      };
    }
    async function wave(label: string) {
      const results = await bounded(Promise.all(Array.from({ length: concurrency }, (_, index) => call(index))), label);
      if (results.some(result => result.status !== 200)) throw new Error(`Unexpected response in ${label}`);
      if (results.some(result => result.service === 'membership' && (result.active !== false || result.remaining !== 10))) {
        throw new Error(`Unexpected membership result in ${label}`);
      }
      return { label, results };
    }
    try {
      await bounded((async () => {
        await control`insert into auth.users(id,aud,role,email,created_at,updated_at) values(${userID},'authenticated','authenticated',${user.email},now(),now())`;
        await control`insert into auth.sessions(id,user_id,created_at,updated_at) values(${sessionID},${userID},now(),now())`;
        // Intentionally omit spy_id to exercise real first-use profile allocation.
        await control`insert into app_private.profiles(user_id,state) values(${userID},'active')`;
        await control`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${userID.replaceAll('-', '').repeat(2)},${userID},${`${userID}@test.invalid`},'ready')`;
      })(), 'seed local fixture');
      const waves = [await wave('cold-membership-first'), await wave('repeat')];
      if (concurrency === 3 && idleSeconds > 0) {
        await new Promise(resolve => setTimeout(resolve, idleSeconds * 1000));
        waves.push(await wave('after-idle-timeout'));
      }
      if (externalCalls !== 0) throw new Error('Fixture unexpectedly contacted an external provider');
      scenarios.push({ concurrency, waves, queries, externalCalls });
    } catch (error) {
      console.error(JSON.stringify({ mode, concurrency, lastQueries: queryTrace }));
      throw error;
    } finally {
      await bounded(db.end({ timeout: 2 }), 'close handler database');
      try {
        await bounded((async () => {
          await control`delete from game_center_private.accounts where user_id=${userID}`;
          await control`delete from app_private.profiles where user_id=${userID}`;
          await control`delete from auth.users where id=${userID}`;
        })(), 'clean local fixture');
      } finally { await control.end({ timeout: 2 }); }
    }
  }
  const identityAndRollback = await verifyIdentityAndRollback(controlURL, serviceURL, createAppHandler, poolMax);
  return { mode, runtime: Deno.version, postgresJS: '3.4.9', poolMax, handlerSHA256, deadlineMilliseconds, idleSeconds, scenarios, identityAndRollback };
}

async function verifyIdentityAndRollback(controlURL: URL, serviceURL: URL, createAppHandler: any, poolMax: number) {
  const control = postgres(controlURL.href, { prepare: false, max: 1, connect_timeout: 8, onnotice() {} });
  const db = postgres(serviceURL.href, { prepare: false, max: poolMax, idle_timeout: 15, connect_timeout: 8, onnotice() {} });
  const actors = [false, true].map(active => {
    const id = crypto.randomUUID(), session = crypto.randomUUID();
    return { id, session, active, marker: active ? 'Probe Bravo' : 'Probe Alpha', email: `${id}@example.test`,
      token: `fixture.${Buffer.from(JSON.stringify({ session_id: session })).toString('base64url')}.fixture` };
  });
  const handler = createAppHandler({ db, config: configuration,
    authenticate: async (token: string) => actors.find(actor => actor.token === token),
    fetch: async () => { throw new Error('Unexpected external call during identity probe'); },
  });
  try {
    await bounded((async () => {
      for (const actor of actors) {
        await control`insert into auth.users(id,aud,role,email,created_at,updated_at) values(${actor.id},'authenticated','authenticated',${actor.email},now(),now())`;
        await control`insert into auth.sessions(id,user_id,created_at,updated_at) values(${actor.session},${actor.id},now(),now())`;
        await control`insert into app_private.profiles(user_id,state,data) values(${actor.id},'active',${control.json({ display_name: actor.marker, full_name: actor.marker })})`;
        await control`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state) values(${actor.id.replaceAll('-', '').repeat(2)},${actor.id},${`${actor.id}@test.invalid`},'ready')`;
        if (actor.active) await control`insert into app_private.membership_grants(user_id,active) values(${actor.id},true)`;
      }
    })(), 'seed two accounts');
    const results = await bounded(Promise.all(Array.from({ length: 24 }, async (_, index) => {
      const actor = actors[index % 2], profile = Math.floor(index / 2) % 2 === 0;
      const response = await handler(new Request('http://127.0.0.1/app-services', {
        method: 'POST', headers: { authorization: `Bearer ${actor.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(profile ? { service: 'profile', action: 'current' } : { service: 'membership', action: 'check' }),
      }));
      const body = await response.json();
      if (response.status !== 200) throw new Error('Unexpected identity probe response');
      if (profile && (body.id !== actor.id || body.display_name !== actor.marker)) throw new Error('Cross-account profile mismatch');
      if (!profile && (body.active !== actor.active || body.ai_remaining !== (actor.active ? null : 10))) throw new Error('Cross-account membership mismatch');
      return { account: actor.active ? 'bravo' : 'alpha', service: profile ? 'profile' : 'membership', identityMatched: true };
    })), 'concurrent account isolation');
    const rollback = new Error('intentional local rollback');
    try {
      await bounded(db.begin(async tx => {
        await tx`update app_private.profiles set data=data || '{"probeRollback":true}'::jsonb where user_id=${actors[0].id}`;
        throw rollback;
      }), 'intentional transaction rollback');
      throw new Error('Transaction unexpectedly committed');
    } catch (error) { if (error !== rollback) throw error; }
    const [row] = await bounded(control`select data ? 'probeRollback' as persisted from app_private.profiles where user_id=${actors[0].id}`, 'verify rollback');
    if (row.persisted !== false) throw new Error('Transaction rollback marker persisted');
    return { results, rollbackVerified: true };
  } finally {
    await db.end({ timeout: 2 });
    try {
      for (const actor of actors) {
        await control`delete from app_private.membership_grants where user_id=${actor.id}`;
        await control`delete from game_center_private.accounts where user_id=${actor.id}`;
        await control`delete from app_private.profiles where user_id=${actor.id}`;
        await control`delete from auth.users where id=${actor.id}`;
      }
    } finally { await control.end({ timeout: 2 }); }
  }
}

if (import.meta.main) console.log(JSON.stringify(await runMembershipConcurrency(Deno.args[0] || 'direct'), null, 2));

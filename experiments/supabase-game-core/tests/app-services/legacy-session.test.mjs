import assert from 'node:assert/strict';
import test, {before, after} from 'node:test';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {exchangeLegacySession, createLegacySessionHandler} from '../../supabase/functions/legacy-session/service.ts';
import {canonicalBase44Configuration, CANONICAL_BASE44_ORIGIN, CANONICAL_BASE44_APP_ID} from '../../supabase/functions/app-services/legacy-provider.ts';
import {prepareLegacyImport, applyLegacyImport} from '../../supabase/functions/app-services/legacy-import.ts';

let db, config;
const legacyIDs = [];
const credential = 'local-only-mocked-Base44-credential';
function identity(email = 'same-contact@example.test') {
  const result = {id: 'bridge-fixture-' + crypto.randomUUID(), email, full_name: 'Bridge fixture'};
  legacyIDs.push(result.id);
  return result;
}
async function ensureProfile({tx, actor}) {
  await tx`insert into app_private.profiles(user_id,contact_email,data) values(${actor.id},${actor.contactEmail},${tx.json({full_name: actor.full_name})}) on conflict(user_id) do nothing`;
}
function dependencies(who, interceptor) {
  return {db, config, ensureProfile, fetch: async (url, options) => {
    if (String(url).startsWith(CANONICAL_BASE44_ORIGIN)) {
      assert.equal(String(url), CANONICAL_BASE44_ORIGIN + '/api/apps/' + CANONICAL_BASE44_APP_ID + '/entities/User/me');
      assert.equal(options.headers.Authorization, 'Bearer ' + credential);
      return Response.json(who);
    }
    assert.equal(new URL(url).origin, config.SUPABASE_URL, 'No remote Auth requests');
    assert.ok(!/\/(otp|signup|invite)$/.test(new URL(url).pathname), 'No email-sending Auth endpoint');
    return interceptor ? interceptor(url, options) : fetch(url, options);
  }};
}
async function admin(path, method = 'GET', body) {
  return fetch(config.SUPABASE_URL + '/auth/v1' + path, {method,
    headers: {apikey: config.SUPABASE_SERVICE_ROLE_KEY, Authorization: 'Bearer ' + config.SUPABASE_SERVICE_ROLE_KEY, 'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)})});
}
before(async () => {
  const status = spawnSync('node_modules/.bin/supabase', ['status', '-o', 'json'], {encoding:'utf8', env:{...process.env, DOCKER_HOST:process.env.DOCKER_HOST || `unix://${homedir()}/.colima/spyclash-supabase/docker.sock`}});
  assert.equal(status.status, 0, 'Local Supabase must already be running');
  const info = JSON.parse(status.stdout);
  const database = new URL(info.DB_URL);
  assert.equal(database.hostname, '127.0.0.1'); assert.equal(database.port, '56322');
  config = {SUPABASE_URL: info.API_URL, SUPABASE_ANON_KEY: info.ANON_KEY, SUPABASE_SERVICE_ROLE_KEY: info.SERVICE_ROLE_KEY};
  assert.equal(config.SUPABASE_URL, 'http://127.0.0.1:56321');
  db = postgres(info.DB_URL, {max: 4, onnotice: () => {}});
  for (const file of ['schemas/full_game_core.sql','functions/app-services/services-schema.sql','functions/app-services/billing-push-schema.sql','functions/app-services/legacy-session-schema.sql','functions/app-services/legacy-import-schema.sql']) await db.unsafe(readFileSync('supabase/' + file, 'utf8'));
});
after(async () => {
  if (!db) return;
  const accounts = await db`select user_id from app_private.legacy_session_accounts where legacy_user_id=any(${legacyIDs}::text[])`;
  for (const {user_id: id} of accounts) {
    await admin('/admin/users/' + id, 'DELETE');
    for (const table of ['legacy_import_runs','legacy_import_rows','legacy_import_history_stage']) await db.unsafe(`delete from app_private.${table} where user_id=$1::uuid`, [id]);
    await db`delete from app_private.legacy_links where user_id=${id}`;
    await db`delete from app_private.profiles where user_id=${id}`;
  }
  await db`delete from app_private.legacy_session_accounts where legacy_user_id=any(${legacyIDs}::text[])`;
  await db.end();
});

test('real Auth sessions preserve immutable identity and never match by contact email', async () => {
  const a = identity(), b = identity();
  const first = await exchangeLegacySession(credential, dependencies(a));
  const second = await exchangeLegacySession(credential, dependencies(a));
  const distinct = await exchangeLegacySession(credential, dependencies(b));
  assert.equal(first.user.id, second.user.id);
  assert.notEqual(first.user.id, distinct.user.id);
  assert.equal(first.legacy_user_id, a.id);
  assert.match(first.user.email, /^[a-f0-9]{32}@accounts\.spyclash\.invalid$/);
  assert.notEqual(first.user.email, a.email);
  const current = await fetch(config.SUPABASE_URL + '/auth/v1/user', {headers:{apikey:config.SUPABASE_ANON_KEY, Authorization:'Bearer '+first.access_token}});
  assert.equal(current.status, 200); assert.equal((await current.json()).id, first.user.id);
  const refreshed = await fetch(config.SUPABASE_URL + '/auth/v1/token?grant_type=refresh_token', {method:'POST', headers:{apikey:config.SUPABASE_ANON_KEY,'Content-Type':'application/json'}, body:JSON.stringify({refresh_token:first.refresh_token})});
  assert.equal(refreshed.status, 200); assert.equal((await refreshed.json()).user.id, first.user.id);
  const [profile] = await db`select contact_email from app_private.profiles where user_id=${first.user.id}`;
  assert.equal(profile.contact_email, a.email);
});

test('concurrent exchanges serialize link generation through a durable lease', async () => {
  const who = identity(); let release, reached; let links = 0;
  const paused = new Promise(resolve => {release = resolve;});
  const entered = new Promise(resolve => {reached = resolve;});
  const first = exchangeLegacySession(credential, dependencies(who, async (url, options) => {
    if (url.endsWith('/admin/generate_link')) {links++; reached(); await paused;}
    return fetch(url, options);
  }));
  await entered;
  try { await assert.rejects(exchangeLegacySession(credential, dependencies(who)), error => error.code === 'legacy_session_busy' && error.retryable); }
  finally { release(); }
  const session = await first;
  const replay = await exchangeLegacySession(credential, dependencies(who));
  assert.equal(replay.user.id, session.user.id); assert.equal(links, 1);
});

test('lost create-user acknowledgement resumes reserved UUID without a duplicate identity', async () => {
  const who = identity(); let creates = 0;
  const session = await exchangeLegacySession(credential, dependencies(who, async (url, options) => {
    const response = await fetch(url, options);
    if (url.endsWith('/admin/users') && options.method === 'POST') { creates++; assert.equal(response.status, 200); throw new Error('simulated lost create ACK'); }
    return response;
  }));
  assert.equal(creates, 1);
  const rows = await db`select user_id from app_private.legacy_session_accounts where legacy_user_id=${who.id}`;
  assert.equal(rows.length, 1); assert.equal(rows[0].user_id, session.user.id);
});

test('client identity fields and Supabase tokens cannot authorize the bridge', async () => {
  const who = identity(); let calls = 0;
  const handler = createLegacySessionHandler({...dependencies(who), fetch:async () => {calls++; throw new Error('unexpected network');}});
  const result = await handler(new Request('http://localhost/legacy-session', {method:'POST', headers:{Authorization:'Bearer '+credential,'Content-Type':'application/json'}, body:JSON.stringify({action:'exchange',user_id:crypto.randomUUID(),legacy_user_id:who.id})}));
  assert.equal(result.status, 400); assert.equal(calls, 0);
  const forged = 'fake.' + btoa(JSON.stringify({iss:config.SUPABASE_URL+'/auth/v1',sub:crypto.randomUUID()})) + '.fake';
  await assert.rejects(exchangeLegacySession(forged, dependencies(who)), error => error.code === 'wrong_credential_provider');
});

test('deleted mapping and tombstone deny rebootstrap even while Base44 remains valid', async () => {
  const who = identity(); const session = await exchangeLegacySession(credential, dependencies(who));
  await db.begin(async tx => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${'spyclash-account:'+session.user.id},0))`;
    await tx`update app_private.profiles set state='deleted',contact_email='',data='{}' where user_id=${session.user.id}`;
    await tx`update app_private.legacy_links set state='deleted' where user_id=${session.user.id}`;
    await tx`delete from auth.sessions where user_id=${session.user.id}`;
  });
  await assert.rejects(exchangeLegacySession(credential, dependencies(who)), error => ['legacy_owner_mismatch','account_unavailable'].includes(error.code));
  assert.equal((await db`select 1 from auth.sessions where user_id=${session.user.id}`).length, 0);
});

test('deletion racing OTP verification rejects and revokes the unreturned candidate session', async () => {
  const who = identity(); let candidateID;
  await assert.rejects(exchangeLegacySession(credential, dependencies(who, async (url, options) => {
    const response = await fetch(url, options);
    if (url.endsWith('/verify')) {
      const result = await response.clone().json(); candidateID = result.user.id;
      await db`update app_private.profiles set state='deleted' where user_id=${candidateID}`;
    }
    return response;
  })), error => error.code === 'account_unavailable');
  assert.ok(candidateID);
  assert.equal((await db`select 1 from auth.sessions where user_id=${candidateID}`).length, 0);
});

test('incomplete import commits progress without issuing a session and resumes on next exchange', async () => {
  const who = identity(); let batches = 0, linkCalls = 0;
  const deps = {...dependencies(who, async (url, options) => {if (url.endsWith('/admin/generate_link')) linkCalls++; return fetch(url,options);}),
    prepareImport: async () => ({}), applyImport: async () => ({complete:++batches > 1})};
  await assert.rejects(exchangeLegacySession(credential, deps), error => error.code === 'legacy_import_pending' && error.retryable);
  assert.equal(linkCalls, 0);
  const [reserved] = await db`select user_id,import_completed from app_private.legacy_session_accounts where legacy_user_id=${who.id}`;
  assert.equal(reserved.import_completed, false);
  assert.equal((await db`select 1 from app_private.legacy_links where user_id=${reserved.user_id}`).length, 1);
  const session = await exchangeLegacySession(credential, deps);
  assert.equal(session.user.id, reserved.user_id); assert.equal(linkCalls, 1); assert.equal(batches, 2);
});

test('shadow user metadata mismatch is refused instead of taking over an existing Auth account', async () => {
  const who = identity();
  await assert.rejects(exchangeLegacySession(credential, {...dependencies(who), prepareImport: async () => {throw new Error('stop after Auth creation');}}));
  const [reserved] = await db`select user_id from app_private.legacy_session_accounts where legacy_user_id=${who.id}`;
  const changed = await admin('/admin/users/' + reserved.user_id, 'PUT', {app_metadata:{legacy_identity_key:'different-owner'}});
  assert.equal(changed.status, 200);
  await assert.rejects(exchangeLegacySession(credential, dependencies(who)), error => error.code === 'legacy_owner_mismatch');
  assert.equal((await db`select 1 from auth.sessions where user_id=${reserved.user_id}`).length, 0);
});

test('canonical existing Base44 is permitted only for the isolated Supabase project', () => {
  assert.deepEqual(canonicalBase44Configuration(config), {origin:CANONICAL_BASE44_ORIGIN,appID:CANONICAL_BASE44_APP_ID});
  assert.throws(() => canonicalBase44Configuration({...config,SUPABASE_URL:'https://another.supabase.co'}), error => error.code === 'legacy_destination_forbidden');
  assert.throws(() => canonicalBase44Configuration({...config,BASE44_STAGING_ORIGIN:'https://evil.example',BASE44_STAGING_APP_ID:CANONICAL_BASE44_APP_ID,APP_ENVIRONMENT:'staging',LEGACY_BRIDGE_ENABLED:'true',BASE44_STAGING_ORIGIN_ALLOWLIST:'["https://evil.example"]'}), error => error.code === 'legacy_destination_forbidden');
});

test('expired lease reclaimed during import cannot mint a session or release the new owner', async () => {
  const who = identity(), replacement = crypto.randomUUID(); let links = 0;
  const deps = {...dependencies(who, async (url, options) => {if (url.endsWith('/admin/generate_link')) links++; return fetch(url,options);}),
    prepareImport: async () => {
      await db`update app_private.legacy_session_accounts set lease_id=${replacement},lease_until=clock_timestamp()+interval '120 seconds' where legacy_user_id=${who.id}`;
      return {};
    }, applyImport: async () => ({complete:true})};
  await assert.rejects(exchangeLegacySession(credential, deps), error => error.code === 'legacy_session_busy');
  const [row] = await db`select lease_id,user_id from app_private.legacy_session_accounts where legacy_user_id=${who.id}`;
  assert.equal(row.lease_id, replacement); assert.equal(links, 0);
  assert.equal((await db`select 1 from auth.sessions where user_id=${row.user_id}`).length, 0);
  await db`update app_private.legacy_session_accounts set lease_until=clock_timestamp()-interval '1 second' where legacy_user_id=${who.id}`;
  assert.equal((await exchangeLegacySession(credential, dependencies(who))).user.id, row.user_id);
});

test('revoked Base44 credential is denied before any privileged Auth request', async () => {
  const who = identity(); let authCalls = 0;
  const deps = {...dependencies(who), fetch:async url => {
    if (String(url).startsWith(CANONICAL_BASE44_ORIGIN)) return Response.json({error:'expired'}, {status:401});
    authCalls++; throw new Error('must not call Auth');
  }};
  await assert.rejects(exchangeLegacySession(credential, deps), error => error.code === 'legacy_session_invalid');
  assert.equal(authCalls, 0);
  assert.equal((await db`select 1 from app_private.legacy_session_accounts where legacy_user_id=${who.id}`).length, 0);
});

test('revalidation updates private contact email without overwriting Supabase profile choices', async () => {
  const who = identity(); const first = await exchangeLegacySession(credential, dependencies(who));
  await db`update app_private.profiles set data=data||${db.json({display_name:'User edited name'})} where user_id=${first.user.id}`;
  who.email = 'changed-contact@example.test';
  const restored = await exchangeLegacySession(credential, dependencies(who));
  assert.equal(restored.user.id, first.user.id);
  const [profile] = await db`select contact_email,data from app_private.profiles where user_id=${first.user.id}`;
  assert.equal(profile.contact_email, who.email); assert.equal(profile.data.display_name, 'User edited name');
});

test('real import hooks commit original profile, own pack and history before issuing a real Auth session', async () => {
  const who = {...identity(),display_name:'Original operative',avatar:'🦊',language:'ru',onboarding_completed:true,onboarding_version:2};
  const pack = {id:'pack-'+crypto.randomUUID(),name:'Original pack',category:'Places',words:['Harbor','Station'],owner_email:who.email};
  const history = {id:'history-'+crypto.randomUUID(),player_user_id:who.id,player_email:who.email,match_id:'match-'+crypto.randomUUID(),match_type:'online',role:'spy',winner:'spy',won:true,ranked:true,spy_count:1,created_date:'2024-01-01T00:00:00Z'};
  let sourceLists = 0;
  const deps = {db,config,ensureProfile,prepareImport:prepareLegacyImport,applyImport:applyLegacyImport,
    fetch:async (raw,options) => {
      const url = new URL(raw);
      if (url.origin === CANONICAL_BASE44_ORIGIN) {
        if (url.pathname.endsWith('/User/me')) return Response.json(who);
        if (url.pathname.endsWith('/wordPackAction')) {sourceLists++;return Response.json([pack]);}
        assert.ok(url.pathname.endsWith('/GameHistory'));
        const query = JSON.parse(url.searchParams.get('q'));
        return Response.json(Object.entries(query).every(([key,value])=>history[key]===value) ? [history] : []);
      }
      assert.equal(url.origin,config.SUPABASE_URL);
      if (url.pathname.endsWith('/admin/generate_link')) {
        const [mapping] = await db`select user_id from app_private.legacy_links where legacy_user_id=${who.id}`;
        assert.ok(mapping);
        const [run] = await db`select status from app_private.legacy_import_runs where user_id=${mapping.user_id}`;
        assert.equal(run.status,'complete');
        assert.equal((await db`select 1 from full_game_private.word_packs where owner_id=${mapping.user_id}`).length,1);
        assert.equal((await db`select 1 from full_game_private.history where player_id=${mapping.user_id}`).length,1);
      }
      return fetch(raw,options);
    }};
  const session = await exchangeLegacySession(credential,deps);
  const [profile] = await db`select data from app_private.profiles where user_id=${session.user.id}`;
  assert.equal(profile.data.display_name,who.display_name);assert.equal(profile.data.language,'ru');
  assert.equal((await exchangeLegacySession(credential,deps)).user.id,session.user.id);
  assert.equal(sourceLists,1);
});

test('a concurrent reservation does not deadlock an import updating the existing profile', async () => {
  const who = identity(); const original = await exchangeLegacySession(credential,dependencies(who));
  await db`update app_private.legacy_session_accounts set import_completed=false where legacy_user_id=${who.id}`;
  let reached, competing;
  const waiting = new Promise(resolve => {reached = resolve;});
  const concurrentDB = new Proxy(db,{get(target,key) {
    if (key === 'begin') return fn => target.begin(tx => fn(new Proxy(tx,{apply(fn,thisArg,args) {
      if (args[0].join('').includes('select pg_advisory_xact_lock(hashtextextended(') && args[1] === 'legacy:'+who.id) reached();
      return Reflect.apply(fn,thisArg,args);
    }})));
    return Reflect.get(target,key);
  }});
  const deps = {...dependencies(who),prepareImport:async () => ({}),applyImport:async ({tx}) => {
    competing = exchangeLegacySession(credential,{...dependencies(who),db:concurrentDB}).then(()=>'unexpected success',error=>error.code);
    await waiting;
    await tx`update app_private.profiles set data=data||${tx.json({display_name:'Imported safely'})} where user_id=${original.user.id}`;
    return {complete:true};
  }};
  const result = await exchangeLegacySession(credential,deps);
  assert.equal(result.user.id,original.user.id);assert.equal(await competing,'legacy_session_busy');
});

import assert from 'node:assert/strict';
import postgres from 'postgres';
import { AppServiceError } from '../../supabase/functions/app-services/contracts.ts';
import { prepareNativeGeneration } from '../../supabase/functions/app-services/native-generation.ts';
import { nativeRewardStatus } from '../../supabase/functions/app-services/generation-reward-ledger.ts';

// Every mutation is confined to a newly created, disposable local database.
// The provider is a fixture; no cloud, ad callback or paid model is contacted.
const raw = Deno.env.get('REWARDED_TEST_DATABASE_URL');
if (!raw) throw new Error('REWARDED_TEST_DATABASE_URL must name local PostgreSQL.');
const url = new URL(raw);
if (!['127.0.0.1', 'localhost'].includes(url.hostname)) throw new Error('Local database required.');
const admin = postgres(url.href, { max: 1, onnotice: () => {} });
const databaseName = 'spyclash_shared_' + crypto.randomUUID().replaceAll('-', '');
await admin.unsafe('create database ' + databaseName);
url.pathname = '/' + databaseName;
const db = postgres(url.href, { max: 15, onnotice: () => {} });
const config: Record<string, string> = {
  SPYCLASH_SHARED_WORD_PACKS_ENABLED: 'true',
  SPYCLASH_REWARDED_GENERATION_ENABLED: 'true',
  APP_NATIVE_GAME_CENTER_AI_ENABLED: 'true',
  APP_NATIVE_GAME_CENTER_AI_PROVIDER: 'openai',
  OPENAI_API_KEY: 'local-fixture-only',
};
let checks = 0;
const check = async (name: string, run: () => Promise<void>) => {
  await run(); checks++; console.log('PASS ' + name);
};
const actor = async (enrolled = true) => {
  const id = crypto.randomUUID();
  await db`insert into app_private.profiles(user_id,state,data,spy_id) values(${id},'active','{}',${id})`;
  await db`insert into game_center_private.accounts(identity_key,user_id,shadow_email,state)
    values(${id.replaceAll('-', '').repeat(2)},${id},${id + '@example.test'},'ready')`;
  if (enrolled) await db`insert into game_center_private.generation_reward_enrollments(user_id,provider,client_build) values(${id},'unity',228)`;
  return { id, email: id + '@example.test', contactEmail: '', full_name: 'Test', metadata: {} };
};
const command = (overrides: Record<string, unknown> = {}) => ({
  service: 'legacy', action: 'generate', theme: 'Fruit', count: 2,
  request_id: crypto.randomUUID(), ...overrides,
});
const reply = (words: string[]) => Response.json({
  status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{
    type: 'output_text', text: JSON.stringify({
      draft_words: words, accepted_indices: words.map((_, index) => index),
      replacement_words: [], accepted_replacement_indices: [], category: 'Words', exhausted: false,
    }),
  }] }],
});
let providerCalls = 0;
const provider = (words = ['Apple', 'Pear']): typeof fetch => async () => { providerCalls++; return reply(words); };
const forbiddenProvider: typeof fetch = () => { throw new Error('Cache hit invoked the provider.'); };
const generate = async (a: any, body = command(), fetcher = provider(), options = config, database: any = db) => {
  try {
    const evidence = await prepareNativeGeneration({ actor: a, body, config: options }, { db: database, fetch: fetcher });
    return { status: 200, body: evidence.result };
  } catch (error) {
    if (error instanceof AppServiceError) return { status: error.status, body: { code: error.code, retryable: error.retryable } };
    throw error;
  }
};
const used = async (a: any) => {
  const [row] = await db`select count(*)::int as used from game_center_private.generation_requests where user_id=${a.id} and charged`;
  return row.used;
};
const status = async (a: any) => await db.begin((tx: any) => nativeRewardStatus(tx, a.id, config));
const earnFixtureCredit = async (a: any) => {
  const id = crypto.randomUUID();
  await db`insert into game_center_private.generation_reward_attempts(user_id,attempt_id,custom_data,ad_unit_id,state,transaction_id,reward_at)
    values(${a.id},${id},${id},'fixture-ad-unit','earned',${id},clock_timestamp())`;
  return id;
};
function failSQL(database: any, needle: string, failure: () => boolean): any {
  return new Proxy(database, {
    apply(target, thisArg, args) {
      const text = Array.isArray(args[0]) ? args[0].join(' ') : '';
      if (text.includes(needle) && failure()) throw new Error('Injected local database failure.');
      return Reflect.apply(target, thisArg, args);
    },
    get(target, property, receiver) {
      if (property === 'begin') return (operation: (tx: any) => unknown) => target.begin((tx: any) => operation(failSQL(tx, needle, failure)));
      return Reflect.get(target, property, receiver);
    },
  });
}
try {
  await db.unsafe(`create schema app_private;
    create table app_private.profiles(user_id uuid primary key,state text,data jsonb,spy_id text);
    create table app_private.legacy_links(user_id uuid,legacy_user_id text,source_origin text,state text);
    create table app_private.legacy_session_accounts(user_id uuid);
    create table app_private.main_account_deletions(user_id uuid);
    create table app_private.entitlements(user_id uuid,active boolean,expires_at timestamptz);
    create table app_private.membership_grants(user_id uuid,active boolean,expires_at timestamptz);`);
  for (const file of [
    '../../supabase/functions/game-center-session/schema.sql',
    '../../supabase/migrations/20261026234309_native_game_center_ai_relay.sql',
    '../../supabase/migrations/20261101130901_native_generation_failure_recovery.sql',
    '../../supabase/migrations/20261105224817_rewarded_generation_credits.sql',
    '../../supabase/migrations/20261111184822_rewarded_generation_enrollment.sql',
    '../../supabase/migrations/20261111185732_shared_word_pack_library.sql',
  ]) await db.unsafe(await Deno.readTextFile(new URL(file, import.meta.url)));

  await check('another account receives a successful charged pack without AI, including prefer_fresh', async () => {
    const first = await actor(), second = await actor(), before = providerCalls;
    const created = await generate(first, command({ count: 3 }), provider(['Apple', 'Pear', 'Plum']));
    assert.equal(created.status, 200, JSON.stringify(created));
    assert.equal(created.body.cache_hit, false);
    const request = command({ theme: ' FRUIT ', prefer_fresh: true });
    const hit = await generate(second, request, forbiddenProvider);
    assert.equal(hit.status, 200, JSON.stringify(hit)); assert.equal(hit.body.cache_hit, true);
    assert.equal(hit.body.words.length, 2); assert.equal(providerCalls, before + 1);
    assert.equal(await used(first), 1); assert.equal(await used(second), 1);
    assert.equal(hit.body.ai_remaining, 2);
    const replay = await generate(second, request, forbiddenProvider);
    assert.deepEqual(replay, hit); assert.equal(await used(second), 1);
  });

  await check('shared cache preserves legacy quota for an unenrolled account and LIMITLESS for an enrolled account', async () => {
    const old = await actor(false);
    for (let index = 0; index < 4; index++) {
      const hit = await generate(old, command(), forbiddenProvider);
      assert.equal(hit.status, 200); assert.equal(hit.body.cache_hit, true); assert.equal(hit.body.ai_limit, 10);
    }
    assert.equal((await status(old)).enabled, false);
    const limitless = await actor();
    await db`insert into app_private.membership_grants values(${limitless.id},true,clock_timestamp()+interval '1 day')`;
    for (let index = 0; index < 4; index++) {
      const hit = await generate(limitless, command(), forbiddenProvider);
      assert.equal(hit.status, 200); assert.equal(hit.body.cache_hit, true); assert.equal(hit.body.ai_limit, null);
    }
    const paidStatus = await status(limitless);
    assert.equal(paidStatus.unlimited, true); assert.equal(paidStatus.ad_available, false);
  });

  await check('cache hits consume daily points then one earned bonus exactly once', async () => {
    const a = await actor();
    for (let index = 0; index < 3; index++) assert.equal((await generate(a, command(), forbiddenProvider)).status, 200);
    const denied = await generate(a, command(), forbiddenProvider);
    assert.equal(denied.status, 429); assert.equal(await used(a), 3);
    const bonus = await earnFixtureCredit(a), request = command();
    const hit = await generate(a, request, forbiddenProvider);
    assert.equal(hit.status, 200); assert.equal(hit.body.cache_hit, true); assert.equal(hit.body.ai_bonus_credits, 0);
    assert.deepEqual(await generate(a, request, forbiddenProvider), hit);
    const [credit] = await db`select consumed_request_id from game_center_private.generation_reward_attempts where user_id=${a.id} and attempt_id=${bonus}`;
    assert.equal(credit.consumed_request_id, request.request_id); assert.equal(await used(a), 4);
  });

  await check('exclusions cause AI only when stock is insufficient, then pooled stock serves another account', async () => {
    const a = await actor(), before = providerCalls;
    const missing = await generate(a, command({ exclude_words: ['APPLE', 'Pear'] }), provider(['Banana', 'Orange']));
    assert.equal(missing.status, 200, JSON.stringify(missing)); assert.equal(missing.body.cache_hit, false);
    assert.deepEqual(missing.body.words, ['Banana', 'Orange']); assert.equal(providerCalls, before + 1);
    const hit = await generate(await actor(), command({ exclude_words: ['Apple', 'Banana', 'Orange'] }), forbiddenProvider);
    assert.equal(hit.status, 200, JSON.stringify(hit)); assert.equal(hit.body.cache_hit, true);
    assert.deepEqual(new Set(hit.body.words), new Set(['Pear', 'Plum']));
  });

  await check('database lookup failure never starts AI and refunds a reserved bonus', async () => {
    const a = await actor();
    for (let index = 0; index < 3; index++) await generate(a, command(), forbiddenProvider);
    await earnFixtureCredit(a);
    const broken = failSQL(db, 'word_pack_library_read', () => true), request = command();
    const failed = await generate(a, request, forbiddenProvider, config, broken);
    assert.equal(failed.status, 503); assert.equal(failed.body.code, 'shared_library_unavailable');
    assert.equal(await used(a), 3); assert.equal((await status(a)).bonus_credits, 1);
    const recovered = await generate(a, request, forbiddenProvider);
    assert.equal(recovered.status, 200); assert.equal(await used(a), 4); assert.equal((await status(a)).bonus_credits, 0);
  });

  await check('concurrent first requests for a topic start one provider and the waiting request later consumes one point', async () => {
    const a = await actor(), b = await actor();
    let started!: () => void, release!: () => void;
    const began = new Promise<void>((resolve) => started = resolve), held = new Promise<void>((resolve) => release = resolve);
    const fetcher: typeof fetch = async () => { providerCalls++; started(); await held; return reply(['Carrot', 'Broccoli']); };
    const before = providerCalls, first = command({ theme: 'Vegetables' }), waiting = command({ theme: 'Vegetables' });
    const pending = generate(a, first, fetcher); await began;
    const busy = await generate(b, waiting, forbiddenProvider);
    assert.equal(busy.status, 503); assert.equal(busy.body.code, 'shared_generation_in_progress'); assert.equal(await used(b), 0);
    release(); assert.equal((await pending).status, 200);
    const hit = await generate(b, waiting, forbiddenProvider);
    assert.equal(hit.status, 200); assert.equal(hit.body.cache_hit, true);
    assert.equal(providerCalls, before + 1); assert.equal(await used(a), 1); assert.equal(await used(b), 1);
  });

  await check('existing stock is available without provider configuration and misses refund their point', async () => {
    const a = await actor(), noProvider = { ...config, OPENAI_API_KEY: '' };
    const hit = await generate(a, command(), forbiddenProvider, noProvider);
    assert.equal(hit.status, 200); assert.equal(hit.body.cache_hit, true);
    const missing = await generate(a, command({ theme: 'Aircraft' }), forbiddenProvider, noProvider);
    assert.equal(missing.status, 503); assert.equal(missing.body.code, 'native_generation_unconfigured'); assert.equal(await used(a), 1);
  });

  await check('publication failure preserves paid output and charge; exact retry publishes without another AI call', async () => {
    const a = await actor(), request = command({ theme: 'Musical instruments' }), before = providerCalls;
    let failures = 1;
    const broken = failSQL(db, 'word_pack_library_publish', () => failures-- > 0);
    const failed = await generate(a, request, provider(['Piano', 'Violin']), config, broken);
    assert.equal(failed.status, 503); assert.equal(failed.body.code, 'generation_persistence_retry'); assert.equal(await used(a), 1);
    const recovered = await generate(a, request, forbiddenProvider);
    assert.equal(recovered.status, 200, JSON.stringify(recovered)); assert.equal(await used(a), 1); assert.equal(providerCalls, before + 1);
    const next = await generate(await actor(), command({ theme: 'Musical instruments' }), forbiddenProvider);
    assert.equal(next.status, 200); assert.equal(next.body.cache_hit, true);
  });

  await check('legacy quotas remain ten and a definitive provider failure refunds only the failed request', async () => {
    const a = await actor(), legacy = { ...config, SPYCLASH_REWARDED_GENERATION_ENABLED: 'false' };
    const hit = await generate(a, command(), forbiddenProvider, legacy);
    assert.equal(hit.status, 200); assert.equal(hit.body.ai_limit, 10); assert.equal(hit.body.ai_remaining, 9);
    const failed = await generate(a, command({ theme: 'Ocean animals' }), async () => Response.json({ error: { message: 'fixture' } }, { status: 400 }), legacy);
    assert.equal(failed.status, 422); assert.equal(await used(a), 1);
    const rows = await db`select distinct charge_source from game_center_private.generation_requests where user_id=${a.id}`;
    assert.deepEqual(rows.map((row) => row.charge_source), ['legacy']);
  });

  await check('an unknown legacy provider outcome retains its reservation and topic lease across accounts', async () => {
    const a = await actor(), request = command({ theme: 'Reptiles' });
    const legacy = { ...config, SPYCLASH_REWARDED_GENERATION_ENABLED: 'false' };
    let attempts = 0;
    const unknown: typeof fetch = async () => { attempts++; throw new TypeError('Lost provider response.'); };
    const failure = await generate(a, request, unknown, legacy);
    assert.equal(failure.status, 503); assert.equal(await used(a), 1);
    const replay = await generate(a, request, forbiddenProvider, legacy);
    assert.equal(replay.status, 503); assert.equal(replay.body.code, 'generation_in_progress'); assert.equal(await used(a), 1);
    const other = await actor();
    const competing = await generate(other, command({ theme: 'Reptiles' }), forbiddenProvider, legacy);
    assert.equal(competing.status, 503); assert.equal(competing.body.code, 'shared_generation_in_progress');
    assert.equal(await used(other), 0); assert.equal(attempts, 1);
  });

  await check('disabled rollout ignores shared stock and preserves the original generation path', async () => {
    const a = await actor(), before = providerCalls;
    const off = { ...config, SPYCLASH_SHARED_WORD_PACKS_ENABLED: 'false' };
    const result = await generate(a, command(), provider(), off);
    assert.equal(result.status, 200); assert.equal(providerCalls, before + 1); assert.equal('cache_hit' in result.body, false);
  });
  console.log(`PASS ${checks} shared native generation checks`);
} finally {
  await db.end({ timeout: 5 });
  await admin.unsafe('drop database ' + databaseName + ' with (force)');
  await admin.end({ timeout: 5 });
}

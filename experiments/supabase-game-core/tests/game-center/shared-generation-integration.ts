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
const reply = (words: string[], exhausted = false) => Response.json({
  status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{
    type: 'output_text', text: JSON.stringify({
      draft_words: words, accepted_indices: words.map((_, index) => index),
      replacement_words: [], accepted_replacement_indices: [], category: 'Words', exhausted,
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
    '../../supabase/migrations/20261111213606_generation_shared_seed.sql',
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
    assert.deepEqual(missing.body.words, ['Plum', 'Banana']); assert.equal(providerCalls, before + 1);
    const hit = await generate(await actor(), command({ exclude_words: ['Apple', 'Banana', 'Orange'] }), forbiddenProvider);
    assert.equal(hit.status, 200, JSON.stringify(hit)); assert.equal(hit.body.cache_hit, true);
    assert.deepEqual(new Set(hit.body.words), new Set(['Pear', 'Plum']));
  });

  await check('larger requests preserve the first 30 names and request the minimum two additions for one missing slot', async () => {
    const first = await actor(), second = await actor(), theme = 'Constellations';
    const names = Array.from({ length: 30 }, (_, index) => `Constellation ${index}`);
    assert.equal((await generate(first, command({ theme, count: 30 }), provider(names))).status, 200);
    let prompt = '', requested = 0;
    const topUp: typeof fetch = async (_url, init) => {
      providerCalls++;
      const input = JSON.parse(String(init?.body));
      prompt = input.input[0].content;
      requested = input.text.format.schema.properties.draft_words.maxItems;
      return reply(['Constellation 30', 'Constellation 31']);
    };
    const body = command({ theme, count: 31 }), before = providerCalls;
    const larger = await generate(second, body, topUp);
    assert.equal(larger.status, 200, JSON.stringify(larger));
    assert.deepEqual(larger.body.words, [...names, 'Constellation 30']);
    assert.equal(requested, 2); assert.ok(prompt.includes(JSON.stringify(names)));
    assert.equal(larger.body.cache_hit, false); assert.equal(await used(second), 1);
    assert.deepEqual(await generate(second, body, forbiddenProvider), larger);
    assert.equal(providerCalls, before + 1); assert.equal(await used(second), 1);
  });

  await check('partial top-up retains five names and honors 200 original exclusions', async () => {
    const theme = 'Garden flowers', names = ['Rose', 'Lily', 'Daisy', 'Tulip', 'Poppy'];
    assert.equal((await generate(await actor(), command({ theme, count: 5 }), provider(names))).status, 200);
    const exclusions = Array.from({ length: 200 }, (_, index) => `Used ${index}`);
    const response = await generate(await actor(), command({ theme, count: 7, exclude_words: exclusions }), async (_url, init) => {
      const input = JSON.parse(String(init?.body));
      assert.equal(input.text.format.schema.properties.draft_words.maxItems, 2);
      assert.ok(input.input[0].content.includes(JSON.stringify([...exclusions, ...names])));
      return reply(['Violet', 'Iris']);
    });
    assert.equal(response.status, 200, JSON.stringify(response));
    assert.deepEqual(response.body.words, [...names, 'Violet', 'Iris']);
  });

  await check('paid top-up recovery uses frozen seed after shared stock expires without a second provider call', async () => {
    const theme = 'Tree species', names = ['Oak', 'Ash', 'Pine', 'Birch', 'Maple'];
    assert.equal((await generate(await actor(), command({ theme, count: 5 }), provider(names))).status, 200);
    const a = await actor(), body = command({ theme, count: 7 }), before = providerCalls;
    let failures = 1;
    const broken = failSQL(db, 'word_pack_library_publish', () => failures-- > 0);
    const failed = await generate(a, body, provider(['Willow', 'Cedar']), config, broken);
    assert.equal(failed.status, 503); assert.equal(failed.body.code, 'generation_persistence_retry');
    const [pending] = await db`select state,result,seed_words from game_center_private.generation_requests where user_id=${a.id} and request_id=${body.request_id}`;
    assert.equal(pending.result, null); assert.deepEqual(pending.seed_words, names);
    await db`update public.word_pack_library_variants set generated_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 day' where words @> '["Oak"]'::jsonb`;
    const recovered = await generate(a, body, forbiddenProvider);
    assert.equal(recovered.status, 200, JSON.stringify(recovered));
    assert.deepEqual(recovered.body.words, [...names, 'Willow', 'Cedar']);
    assert.equal(providerCalls, before + 1); assert.equal(await used(a), 1);
    assert.equal('seed_words' in recovered.body, false);
  });

  await check('a legacy paid top-up still replays its frozen inputs when the shared rollout is disabled', async () => {
    const theme = 'Mountain ranges', names = ['Alps', 'Andes'];
    const legacy = { ...config, SPYCLASH_REWARDED_GENERATION_ENABLED: 'false' };
    assert.equal((await generate(await actor(false), command({ theme }), provider(names), legacy)).status, 200);
    const a = await actor(false), body = command({ theme, count: 4 }), before = providerCalls;
    let failures = 1;
    const broken = failSQL(db, 'word_pack_library_publish', () => failures-- > 0);
    const failed = await generate(a, body, provider(['Himalayas', 'Rockies']), legacy, broken);
    assert.equal(failed.status, 503); assert.equal(failed.body.code, 'generation_persistence_retry');
    const disabled = { ...legacy, SPYCLASH_SHARED_WORD_PACKS_ENABLED: 'false' };
    const recovered = await generate(a, body, forbiddenProvider, disabled);
    assert.equal(recovered.status, 200, JSON.stringify(recovered));
    assert.deepEqual(recovered.body.words, [...names, 'Himalayas', 'Rockies']);
    assert.equal(providerCalls, before + 1); assert.equal(await used(a), 1);
  });

  await check('prior-version paid requests replay original full-count inputs without republishing obsolete quality', async () => {
    const theme = 'Historic ships', a = await actor(), body = command({ theme }), before = providerCalls;
    let failures = 1;
    const broken = failSQL(db, 'word_pack_library_publish', () => failures-- > 0);
    const failed = await generate(a, body, provider(['Victory', 'Cutty Sark']), config, broken);
    assert.equal(failed.status, 503);
    // A pre-upgrade provider journal has no seed column value. Its input was
    // the original full-count request, and its result may use older quality.
    await db`update game_center_private.generation_requests set seed_words=null where user_id=${a.id} and request_id=${body.request_id}`;
    let completionFailures = 1;
    const brokenCompletion = failSQL(db, "set state='complete',result", () => completionFailures-- > 0);
    const deferred = await generate(a, body, forbiddenProvider, config, brokenCompletion);
    assert.equal(deferred.status, 503);
    const [pending] = await db`select seed_words from game_center_private.generation_requests where user_id=${a.id} and request_id=${body.request_id}`;
    assert.equal(pending.seed_words, null);
    const recovered = await generate(a, body, forbiddenProvider);
    assert.equal(recovered.status, 200, JSON.stringify(recovered));
    assert.deepEqual(recovered.body.words, ['Victory', 'Cutty Sark']);
    assert.equal(providerCalls, before + 1); assert.equal(await used(a), 1);
    const [published] = await db`select count(*)::int as count from public.word_pack_library_variants where words @> '["Cutty Sark"]'::jsonb`;
    assert.equal(published.count, 0);
  });

  await check('exhausted top-ups keep existing names and verify only the remaining unseen items', async () => {
    const theme = 'Primary additive colors', names = ['Red', 'Green'];
    assert.equal((await generate(await actor(), command({ theme }), provider(names))).status, 200);
    let calls = 0;
    const expanded = await generate(await actor(), command({ theme, count: 5 }), async (_url, init) => {
      const input = JSON.parse(String(init?.body));
      const prompt = input.input[0].content;
      calls++;
      assert.ok(prompt.includes(JSON.stringify(calls === 1 ? names : [...names, 'Blue'])));
      return reply(calls === 1 ? ['Blue'] : [], true);
    });
    assert.equal(expanded.status, 200, JSON.stringify(expanded));
    assert.deepEqual(expanded.body.words, [...names, 'Blue']);
    assert.equal(expanded.body.exhausted, true); assert.equal(calls, 2);
    const hit = await generate(await actor(), command({ theme, count: 5 }), forbiddenProvider);
    assert.equal(hit.status, 200); assert.deepEqual(hit.body.words, [...names, 'Blue']);
    assert.equal(hit.body.exhausted, true); assert.equal(hit.body.cache_hit, true);
  });

  await check('unspent partial requests may recover from newly completed stock without provider configuration', async () => {
    const theme = 'Gemstones', names = ['Ruby', 'Emerald'];
    assert.equal((await generate(await actor(), command({ theme }), provider(names))).status, 200);
    const a = await actor(), body = command({ theme, count: 4 }), noProvider = { ...config, OPENAI_API_KEY: '' };
    const failed = await generate(a, body, forbiddenProvider, noProvider);
    assert.equal(failed.status, 503); assert.equal(failed.body.code, 'native_generation_unconfigured');
    assert.equal(await used(a), 0);
    const filled = await generate(await actor(), command({ theme, count: 4 }), provider(['Sapphire', 'Diamond']));
    assert.equal(filled.status, 200, JSON.stringify(filled));
    const recovered = await generate(a, body, forbiddenProvider, noProvider);
    assert.equal(recovered.status, 200, JSON.stringify(recovered));
    assert.deepEqual(recovered.body.words, [...names, 'Sapphire', 'Diamond']);
    assert.equal(recovered.body.cache_hit, true); assert.equal(await used(a), 1);
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

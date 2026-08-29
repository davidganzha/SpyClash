import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  buildWordPackCacheVariantRecord,
  lookupWordPackCache,
  persistWordPackCacheVariant,
  prepareWordPackCacheRequest,
  pruneExpiredWordPackCacheVariants,
  wordPackTelemetryDimensions,
} from "./generation-cache.ts";
import {
  BASE44_WORD_PACK_MODEL,
  WORD_PACK_CACHE_VERSION,
  WORD_PACK_PROMPT_VERSION,
} from "./openai-word-pack-provider.ts";

const NOW = new Date("2026-07-24T12:00:00.000Z");

class MockStore {
  records: Record<string, unknown>[] = [];

  async filter(
    filter: Record<string, unknown>,
    _sort = "created_date",
    limit = 50,
    skip = 0,
  ) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).slice(skip, skip + limit).map((record) => structuredClone(record));
  }

  async create(value: Record<string, unknown>) {
    const created = {
      ...structuredClone(value),
      id: `cache-${this.records.length + 1}`,
      created_date: NOW.toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }
}

async function request(
  overrides: Partial<Parameters<typeof prepareWordPackCacheRequest>[0]> = {},
) {
  return await prepareWordPackCacheRequest({
    userID: "user-1",
    theme: " Café   Racers ",
    language: "pt_BR",
    promptVersion: " Prompt-V3 ",
    requestedCount: 5,
    exclusions: [],
    ...overrides,
  });
}

Deno.test("cache keys exactly normalize user, theme, language, and prompt version", async () => {
  const first = await request();
  const equivalent = await request({
    userID: " user-1 ",
    theme: "ＣＡＦÉ RACERS",
    language: "pt-br",
    promptVersion: "prompt-v3",
    requestedCount: 20,
    exclusions: ["one"],
  });
  assertEquals(first.cacheKey, equivalent.cacheKey);
  assertEquals(first.themeKey, equivalent.themeKey);
  assertNotEquals(first.exclusionKey, equivalent.exclusionKey);
  assertEquals(
    first.cacheKey,
    "awc1_KUr6GQU3-wCjsXuyN2GBKZ64Z6ZudybAlv0vZwL63rg",
    "versioned exact-key contract drifted",
  );
  assertEquals(first.languageKey, "pt-br");
  assertEquals(first.promptVersion, "prompt-v3");

  assertNotEquals(
    first.cacheKey,
    (await request({ userID: "user-2" })).cacheKey,
  );
  assertNotEquals(first.cacheKey, (await request({ language: "es" })).cacheKey);
  assertNotEquals(first.cacheKey, (await request({ language: "uk" })).cacheKey);
  assertNotEquals(
    first.cacheKey,
    (await request({ promptVersion: "prompt-v4" })).cacheKey,
  );
  assertNotEquals(
    first.cacheKey,
    (await request({ theme: "Café Bikes" })).cacheKey,
  );
});

Deno.test("current exact-theme prompt bypasses cached v3 variants", async () => {
  const legacy = await request({
    promptVersion: "word-pack-2026-08-16-v3",
  });
  const current = await request({ promptVersion: WORD_PACK_CACHE_VERSION });

  assertEquals(WORD_PACK_PROMPT_VERSION, "word-pack-2026-08-29-v4");
  assertEquals(BASE44_WORD_PACK_MODEL, "gpt_5_4");
  assertEquals(
    WORD_PACK_CACHE_VERSION,
    "word-pack-2026-08-29-v4-gpt_5_4",
  );
  assertNotEquals(current.cacheKey, legacy.cacheKey);
});

Deno.test("legacy theme-auto cache cannot collide with an explicit English locale", async () => {
  const legacyThemeAuto = await request({
    theme: "Personajes de anime",
    language: "und",
  });
  const explicitEnglish = await request({
    theme: "Personajes de anime",
    language: "en",
  });

  assertNotEquals(legacyThemeAuto.cacheKey, explicitEnglish.cacheKey);
});

Deno.test("telemetry dimensions expose only a per-user theme hash", async () => {
  const prepared = await request({ theme: "Very Private Birthday Theme" });
  const dimensions = wordPackTelemetryDimensions(prepared);
  const serialized = JSON.stringify(dimensions).toLowerCase();

  assertEquals(Object.keys(dimensions).sort(), [
    "excluded_count",
    "language_key",
    "prompt_version",
    "requested_count",
    "theme_key",
  ]);
  assert(!serialized.includes("very private birthday theme"));
  assert(!serialized.includes("normalizedtheme"));
  assert(String(dimensions.theme_key).startsWith("awt1_"));
});

Deno.test("cache retains multiple variants and applies TTL and exclusions on read", async () => {
  const store = new MockStore();
  const prepared = await request({ exclusions: [" ALPHA "] });

  await persistWordPackCacheVariant({
    store,
    request: prepared,
    now: NOW,
    ttlMilliseconds: 60_000,
    result: {
      category: "Racers",
      words: ["Alpha", "Bravo", "Charlie", "Delta", "Echo"],
      exhausted: false,
    },
  });
  await persistWordPackCacheVariant({
    store,
    request: prepared,
    now: NOW,
    ttlMilliseconds: 60_000,
    result: {
      category: "Racers",
      words: ["Foxtrot", "Golf", "Hotel", "India", "Juliet"],
      exhausted: true,
    },
  });
  assertEquals(store.records.length, 2);

  const hit = await lookupWordPackCache({
    store,
    request: prepared,
    now: NOW,
    selectionSeed: "request-1",
  });
  assertEquals(hit?.words, ["Foxtrot", "Golf", "Hotel", "India", "Juliet"]);
  assertEquals(hit?.exhausted, true);

  const expired = await lookupWordPackCache({
    store,
    request: prepared,
    now: new Date(NOW.getTime() + 60_000),
  });
  assertEquals(expired, null, "TTL boundary must be exclusive");
});

Deno.test("identical cache content is deduplicated without replacing other variants", async () => {
  const store = new MockStore();
  const prepared = await request();
  const input = {
    store,
    request: prepared,
    now: NOW,
    result: {
      category: "Racers",
      words: ["One", "Two", "Three", "Four", "Five"],
      exhausted: false,
    },
  };
  const first = await persistWordPackCacheVariant(input);
  const replay = await persistWordPackCacheVariant(input);
  assertEquals(first.id, replay.id);
  assertEquals(store.records.length, 1);

  const secondVariant = await buildWordPackCacheVariantRecord({
    request: prepared,
    now: NOW,
    result: {
      category: "Racers",
      words: ["Six", "Seven", "Eight", "Nine", "Ten"],
      exhausted: true,
    },
  });
  assertNotEquals(first.variant_key, secondVariant.variant_key);
  assertEquals(first.user_id, "user-1");
});

Deno.test("an exhausted playable partial is a hit and prevents a futile refill", async () => {
  const prepared = await request({ requestedCount: 5, exclusions: ["Used"] });
  const record = await buildWordPackCacheVariantRecord({
    request: prepared,
    now: NOW,
    result: {
      category: "Tiny Theme",
      words: ["Used", "One", "Two", "Three"],
      exhausted: true,
    },
  });
  const store = new MockStore();
  store.records.push(record);

  const hit = await lookupWordPackCache({ store, request: prepared, now: NOW });
  assertEquals(hit?.words, ["One", "Two", "Three"]);
  assertEquals(hit?.exhausted, true);

  const differentExclusions = await request({
    requestedCount: 5,
    exclusions: [],
  });
  assertEquals(
    await lookupWordPackCache({
      store,
      request: differentExclusions,
      now: NOW,
    }),
    null,
    "an exhausted partial cannot narrow a different exclusion search space",
  );
});

Deno.test("cache drops oversized generated words before persistence", async () => {
  const record = await buildWordPackCacheVariantRecord({
    request: await request(),
    now: NOW,
    result: {
      category: "Racers",
      words: ["A".repeat(121), "Bravo", "Charlie"],
      exhausted: true,
    },
  });
  assertEquals(record.words, ["Bravo", "Charlie"]);
  assertEquals(record.word_count, 2);
});

Deno.test("cache prune physically removes only expired rows for the user", async () => {
  const store = new MockStore();
  store.records = [{
    id: "expired-target",
    user_id: "user-1",
    expires_at: new Date(NOW.getTime() - 1).toISOString(),
  }, {
    id: "active-target",
    user_id: "user-1",
    expires_at: new Date(NOW.getTime() + 1).toISOString(),
  }, {
    id: "expired-other",
    user_id: "user-2",
    expires_at: new Date(NOW.getTime() - 1).toISOString(),
  }];

  assertEquals(
    await pruneExpiredWordPackCacheVariants({
      store,
      userID: "user-1",
      now: NOW,
    }),
    1,
  );
  assertEquals(store.records.map((record) => record.id).sort(), [
    "active-target",
    "expired-other",
  ]);
});

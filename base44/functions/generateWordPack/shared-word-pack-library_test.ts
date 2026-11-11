import {
  assert,
  assertEquals,
  assertNotEquals,
  assertRejects,
} from "jsr:@std/assert@1";
import {
  buildSharedWordPackVariant,
  prepareSharedWordPackRequest,
  selectSharedWordPackHit,
  SHARED_WORD_PACK_TTL_MILLISECONDS,
  sharedWordPackLibraryEnabled,
  type SharedWordPackRequest,
} from "./shared-word-pack-library.ts";

const NOW = new Date("2026-11-11T12:00:00.000Z");
const WORDS = ["Apple", "Pear", "Banana", "Mango", "Cherry"];
const request = (
  overrides: Partial<Parameters<typeof prepareSharedWordPackRequest>[0]> = {},
) =>
  prepareSharedWordPackRequest({
    theme: "Fruit",
    language: "und",
    promptVersion: "quality-v1",
    requestedCount: 5,
    exclusions: [],
    ...overrides,
  });
const variant = (r: SharedWordPackRequest, words = WORDS, exhausted = false) =>
  buildSharedWordPackVariant({
    request: r,
    result: { words, exhausted },
    now: NOW,
  });

Deno.test("shared library is explicit opt-in and keys have no account scope", async () => {
  assertEquals(sharedWordPackLibraryEnabled({}), false);
  assertEquals(
    sharedWordPackLibraryEnabled({
      SPYCLASH_SHARED_WORD_PACKS_ENABLED: "TRUE",
    }),
    false,
  );
  assertEquals(
    sharedWordPackLibraryEnabled({
      SPYCLASH_SHARED_WORD_PACKS_ENABLED: "true",
    }),
    true,
  );
  const first = await request(),
    second = await request({
      theme: "  ＦＲＵＩＴ. ",
      requestedCount: 100,
      exclusions: ["Apple"],
    });
  assertEquals(first.cacheKey, second.cacheKey);
  assertNotEquals(first.exclusionKey, second.exclusionKey);
  assert(!("userID" in first));
  for (
    const changes of [{ theme: "Tropical fruit" }, { language: "ru" }, {
      promptVersion: "quality-v2",
    }]
  ) {
    assertNotEquals(first.cacheKey, (await request(changes)).cacheKey);
  }
});

Deno.test("shared records retain only reusable words and keyed dimensions", async () => {
  const record = await variant(await request());
  assertEquals(
    Object.keys(record).sort(),
    [
      "cache_key",
      "variant_key",
      "language_key",
      "prompt_version",
      "exclusion_key",
      "words",
      "exhausted",
      "word_count",
      "generated_at",
      "expires_at",
    ].sort(),
  );
  assertEquals(
    Date.parse(record.expires_at) - Date.parse(record.generated_at),
    SHARED_WORD_PACK_TTL_MILLISECONDS,
  );
  assert(!JSON.stringify(record).includes("fruit"));
});

Deno.test("a second request reuses existing words without an owner requirement", async () => {
  const record = await variant(await request());
  const hit = await selectSharedWordPackHit({
    request: await request({ theme: "FRUIT" }),
    records: [record],
    now: NOW,
  });
  assertEquals(hit?.words, WORDS);
  assertEquals(hit?.exhausted, false);
});

Deno.test("selection combines partial usable stock and removes duplicate and excluded words", async () => {
  const r = await request({ requestedCount: 3 });
  const a = await variant(r, ["Apple", "Pear", "Banana"]);
  const b = await variant(r, ["PEAR", "Mango", "Cherry"]);
  const lookup = await request({ requestedCount: 4, exclusions: ["Apple"] });
  const hit = await selectSharedWordPackHit({
    request: lookup,
    records: [a, b],
    now: NOW,
  });
  assertEquals(hit?.words.length, 4);
  assertEquals(
    new Set(hit?.words.map((w) => w.toLowerCase())),
    new Set(["pear", "banana", "mango", "cherry"]),
  );
  assertEquals(hit?.exhausted, false);
});

Deno.test("one surviving word per variant can combine into a complete native pack", async () => {
  const r = await request({ requestedCount: 2 });
  const a = await variant(r, ["Apple", "Pear"]),
    b = await variant(r, ["Apple", "Mango"]);
  const hit = await selectSharedWordPackHit({
    request: await request({ requestedCount: 2, exclusions: ["Apple"] }),
    records: [a, b],
    now: NOW,
  });
  assertEquals(new Set(hit?.words), new Set(["Pear", "Mango"]));
});

Deno.test("insufficient stock is a miss unless exact exclusions have verified exhaustion", async () => {
  const r = await request({ requestedCount: 2 });
  const short = await variant(r, ["Apple", "Pear"]);
  const larger = await request({ requestedCount: 5 });
  assertEquals(
    await selectSharedWordPackHit({
      request: larger,
      records: [short],
      now: NOW,
    }),
    null,
  );
  const exhausted = await variant(larger, ["Apple", "Pear"], true);
  const hit = await selectSharedWordPackHit({
    request: larger,
    records: [exhausted],
    now: NOW,
  });
  assertEquals(hit?.words, ["Apple", "Pear"]);
  assertEquals(hit?.exhausted, true);
  assertEquals(
    await selectSharedWordPackHit({
      request: await request({ exclusions: ["Orange"] }),
      records: [exhausted],
      now: NOW,
    }),
    null,
  );
});

Deno.test("expired, future, malformed and wrong-version records cannot supply hits", async () => {
  const r = await request(), record = await variant(r);
  for (
    const invalid of [
      { ...record, expires_at: NOW.toISOString() },
      {
        ...record,
        generated_at: new Date(NOW.getTime() + 60_001).toISOString(),
      },
      { ...record, prompt_version: "old" },
      { ...record, language_key: "ru" },
      { ...record, variant_key: "malformed" },
      { ...record, words: ["Apple", {}] },
      {
        ...record,
        expires_at: new Date(
          NOW.getTime() + SHARED_WORD_PACK_TTL_MILLISECONDS + 1,
        ).toISOString(),
      },
    ]
  ) {
    assertEquals(
      await selectSharedWordPackHit({
        request: r,
        records: [invalid],
        now: NOW,
      }),
      null,
    );
  }
});

Deno.test("bounded backend clock skew does not hide a newly published pack", async () => {
  const r = await request();
  const record = await buildSharedWordPackVariant({
    request: r,
    result: { words: WORDS, exhausted: false },
    now: new Date(NOW.getTime() + 30_000),
  });
  const hit = await selectSharedWordPackHit({
    request: r,
    records: [record],
    now: NOW,
  });
  assertEquals(hit?.words, WORDS);
});

Deno.test("unsafe and known drifting words do not become reusable content", async () => {
  const r = await request(), record = await variant(r);
  assertEquals(
    await selectSharedWordPackHit({
      request: r,
      records: [{ ...record, words: ["Apple", "fuck"] }],
      now: NOW,
    }),
    null,
  );
  const anime = await request({ theme: "Anime characters", requestedCount: 2 });
  const valid = await variant(anime, ["Naruto", "Luffy"]);
  assertEquals(
    await selectSharedWordPackHit({
      request: anime,
      records: [{ ...valid, words: ["Naruto", "shonen"] }],
      now: NOW,
    }),
    null,
  );
});

Deno.test("publication rejects incomplete generated packs and accepts native two-word requests", async () => {
  const r = await request();
  await assertRejects(() => variant(r, ["Apple", "Pear"]));
  const native = await request({ requestedCount: 2 });
  assertEquals((await variant(native, ["Apple", "Pear"])).word_count, 2);
  await assertRejects(() => request({ requestedCount: 1 }));
  await assertRejects(() => request({ requestedCount: 101 }));
});

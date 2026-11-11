import { assert, assertEquals } from "jsr:@std/assert@1";
// This is the axios version resolved by the pinned Base44 SDK used by main.ts.
import axios, {
  AxiosError,
  type InternalAxiosRequestConfig,
} from "npm:axios@1.18.1";
import {
  billingIdentitySubjectKey,
  isBillingIdentityLeaseActive,
} from "./billing-identity-lifecycle.ts";
import {
  buildSharedWordPackVariant,
  prepareSharedWordPackRequest,
} from "./shared-word-pack-library.ts";
import { WORD_PACK_CACHE_VERSION } from "./openai-word-pack-provider.ts";
import { quotaKey, utcUsageDate } from "./quota.ts";
import { prepareWordPackCacheRequest } from "./generation-cache.ts";
import {
  buildWordPackRequestResultRecord,
  prepareWordPackIdempotency,
} from "./generation-idempotency.ts";

type Row = Record<string, any>;
const APP_ID = "69a0e57fa939f578082f8091";
const ACCOUNT_SUBJECT = await billingIdentitySubjectKey("journal-user");
const WORDS = [
  "Piano",
  "Guitar",
  "Violin",
  "Cello",
  "Flute",
  "Trumpet",
  "Trombone",
  "Clarinet",
  "Oboe",
  "Bassoon",
  "Harp",
  "Accordion",
  "Saxophone",
  "Tuba",
  "Ukulele",
  "Mandolin",
  "Banjo",
  "Organ",
  "Recorder",
  "Harmonica",
  "Drums",
  "Xylophone",
  "Marimba",
  "Triangle",
];

function matches(row: Row, query: Row): boolean {
  return Object.entries(query).every(([key, expected]) => {
    if (key === "$or") {
      return (expected as Row[]).some((part) => matches(row, part));
    }
    if (key === "$and") {
      return (expected as Row[]).every((part) => matches(row, part));
    }
    if (expected && typeof expected === "object" && !Array.isArray(expected)) {
      return Object.entries(expected).every(([operator, value]) => {
        switch (operator) {
          case "$exists":
            return (row[key] !== undefined) === value;
          case "$lt":
            return row[key] < value!;
          case "$lte":
            return row[key] <= value!;
          case "$gt":
            return row[key] > value!;
          case "$gte":
            return row[key] >= value!;
          case "$ne":
            return row[key] !== value;
          case "$in":
            return (value as unknown[]).includes(row[key]);
          default:
            throw new Error(`Unsupported test filter operator ${operator}`);
        }
      });
    }
    return row[key] === expected;
  });
}

/** In-memory HTTP adapter; the real SDK still serializes and unwraps requests. */
class GenerationHTTPStore {
  userID = "journal-user";
  tables = new Map<string, Row[]>();
  providerCalls = 0;
  providerRequests: Row[] = [];
  providerWords = WORDS;
  quotaReservations = 0;
  journalStateAtProvider: string[] = [];
  legacyReadUnavailable = false;
  journalReadUnavailable = false;
  journalCompletionUnavailable = false;
  failRunningConfirmationOnce = false;
  loseCompletionResponseOnce = false;
  journalReadsToFail = 0;
  legacyWriteUnavailable = false;
  loseLegacyCreateResponseOnce = false;
  failLegacyConfirmationOnce = false;
  legacyReadsToFail = 0;
  loseProviderResponse = false;
  deleteAccountAfterProvider = false;
  nextID = 0;
  unexpected: string[] = [];

  constructor() {
    // Rewarded tests represent accounts already enrolled by a supported status
    // request. New/legacy account coverage explicitly removes these records.
    this.tables.set("GenerationRewardEnrollment", ["journal-user", "second-player"].map((userID) => ({
      id: `enrollment-${userID}`, user_id: userID, provider: "unity",
      client_build: 228, enrolled_at: new Date().toISOString(),
    })));
  }

  rows(name: string): Row[] {
    if (!this.tables.has(name)) this.tables.set(name, []);
    return this.tables.get(name)!;
  }

  private failure(config: InternalAxiosRequestConfig, message: string): never {
    throw new AxiosError(message, "ERR_BAD_RESPONSE", config, undefined, {
      status: 503,
      statusText: "Unavailable",
      data: { message },
      headers: {},
      config,
    });
  }

  handle = async (config: InternalAxiosRequestConfig) => {
    const response = (data: unknown) => ({
      data: structuredClone(data),
      status: 200,
      statusText: "OK",
      headers: {},
      config,
    });
    const path = new URL(config.url!, config.baseURL).pathname;
    const method = config.method?.toUpperCase();
    const body: Row = typeof config.data === "string"
      ? JSON.parse(config.data)
      : config.data || {};
    if (path === `/apps/${APP_ID}/entities/User/me` && method === "GET") {
      assertEquals(
        config.headers.get("Authorization"),
        "Bearer test-user-token",
      );
      return response({
        id: this.userID,
        email: "journal@example.test",
        ai_generations_today: 0,
      });
    }
    if (
      path === `/apps/${APP_ID}/integration-endpoints/Core/InvokeLLM` &&
      method === "POST"
    ) {
      this.providerCalls += 1;
      this.providerRequests.push(structuredClone(body));
      this.journalStateAtProvider.push(
        this.rows("AiWordPackOperation")[0]?.state || "missing",
      );
      const account = this.rows("BillingIdentityLifecycle").find((row) =>
        row.subject_key === ACCOUNT_SUBJECT
      );
      assert(account);
      assertEquals(
        isBillingIdentityLeaseActive(account.lease_until),
        false,
        "provider latency must not hold the global account lease",
      );
      if (this.loseProviderResponse) {
        this.failure(
          config,
          "simulated response loss after provider execution",
        );
      }
      const count = body.response_json_schema.properties.draft_words.maxItems;
      const words = this.providerWords.slice(0, count);
      if (this.deleteAccountAfterProvider) {
        this.tables.set("AiWordPackOperation", []);
        for (const lifecycle of this.rows("BillingIdentityLifecycle")) {
          // Both account and generation rows are protected here. No later
          // journal/result create may pass the real persistence boundary.
          lifecycle.state = "deleting";
          lifecycle.lease_token = "deleting:test-account-deletion";
          lifecycle.revision = `deleting-${lifecycle.id}`;
          lifecycle.lease_until = new Date(Date.now() + 600_000).toISOString();
        }
      }
      return response({
        draft_words: words,
        accepted_indices: words.map((_word, index) => index),
        replacement_words: [],
        accepted_replacement_indices: [],
        category: "Musical instruments",
        exhausted: false,
      });
    }
    const match = path.match(
      new RegExp(`^/apps/${APP_ID}/entities/([^/]+)(?:/([^/]+))?$`),
    );
    if (!match) {
      this.unexpected.push(`${method} ${path}`);
      throw new Error("Unexpected local test HTTP route");
    }
    const [, entity, suffix] = match;
    const rows = this.rows(entity);
    if (method === "GET" && !suffix) {
      if (entity === "AiWordPackRequestResult" && this.legacyReadUnavailable) {
        this.failure(config, "legacy replay read unavailable");
      }
      if (entity === "AiWordPackRequestResult" && this.legacyReadsToFail > 0) {
        this.legacyReadsToFail -= 1;
        this.failure(config, "legacy replay confirmation unavailable");
      }
      if (entity === "AiWordPackOperation" && this.journalReadUnavailable) {
        this.failure(config, "journal read unavailable");
      }
      if (entity === "AiWordPackOperation" && this.journalReadsToFail > 0) {
        this.journalReadsToFail -= 1;
        this.failure(config, "journal running confirmation unavailable");
      }
      const query = JSON.parse(config.params?.q || "{}");
      const skip = Number(config.params?.skip || 0);
      const limit = Number(config.params?.limit || 100);
      return response(
        rows.filter((row) => matches(row, query)).slice(skip, skip + limit),
      );
    }
    if (method === "POST" && !suffix) {
      if (entity === "AiWordPackRequestResult" && this.legacyWriteUnavailable) {
        this.failure(config, "legacy replay persistence unavailable");
      }
      const record = {
        ...body,
        id: `record-${++this.nextID}`,
        created_date: new Date().toISOString(),
      };
      rows.push(structuredClone(record));
      if (entity === "AiWordPackRequestResult") {
        if (this.failLegacyConfirmationOnce) {
          this.failLegacyConfirmationOnce = false;
          this.legacyReadsToFail = 1;
        }
        if (this.loseLegacyCreateResponseOnce) {
          this.loseLegacyCreateResponseOnce = false;
          this.failure(
            config,
            "legacy replay create response lost after commit",
          );
        }
      }
      return response(record);
    }
    if (method === "PATCH" && suffix === "update-many") {
      if (
        entity === "AiWordPackOperation" &&
        body.data.$set?.state === "completed" &&
        this.journalCompletionUnavailable
      ) {
        this.failure(config, "journal completion persistence unavailable");
      }
      if (
        entity === "AiGenerationUsage" && body.data.$inc?.generations_used === 1
      ) {
        assertEquals(
          this.rows("AiWordPackOperation").some((row) =>
            row.state === "running" && row.user_id === this.userID
          ),
          true,
          "durable admission must precede quota effects",
        );
        this.quotaReservations += 1;
      }
      let updated = 0;
      for (const row of rows) {
        if (!matches(row, body.query)) continue;
        Object.assign(row, body.data.$set || {});
        for (const [key, increment] of Object.entries(body.data.$inc || {})) {
          row[key] = Number(row[key] || 0) + Number(increment);
        }
        updated += 1;
      }
      if (entity === "AiWordPackOperation" && updated === 1) {
        if (
          body.data.$set?.state === "running" &&
          this.failRunningConfirmationOnce
        ) {
          this.failRunningConfirmationOnce = false;
          this.journalReadsToFail = 1;
        }
        if (
          body.data.$set?.state === "completed" &&
          this.loseCompletionResponseOnce
        ) {
          this.loseCompletionResponseOnce = false;
          this.failure(config, "journal completion response lost after commit");
        }
      }
      return response({ updated });
    }
    if (method === "PUT" && suffix) {
      const row = rows.find((row) => row.id === suffix);
      if (row) Object.assign(row, body);
      return response(row || { id: suffix, ...body });
    }
    if (method === "DELETE" && suffix) {
      this.tables.set(entity, rows.filter((row) => row.id !== suffix));
      return response({ deleted: 1 });
    }
    this.unexpected.push(`${method} ${path}`);
    throw new Error("Unsupported local test entity request");
  };
}

/** The real REST adapter talks only to this in-memory Supabase RPC fixture. */
class LibraryHTTPStore {
  records: Row[] = [];
  readCalls = 0;
  publishCalls = 0;
  releaseCalls = 0;
  claimCalls = 0;
  readUnavailable = false;
  publicationUnavailable = false;
  claimBusy = false;
  token: string | null = null;
  leaseCacheKey: string | null = null;
  leaseUntil = 0;
  handle = async (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = new URL(String(input));
    assertEquals(url.origin, "https://library.example.test");
    assertEquals(init?.method, "POST");
    const headers = new Headers(init?.headers);
    assertEquals(headers.get("apikey"), "sb_secret_local_library_fixture");
    assertEquals(headers.get("authorization"), null);
    const body = JSON.parse(String(init?.body));
    switch (url.pathname) {
      case "/rest/v1/rpc/word_pack_library_read":
        this.readCalls++;
        if (this.readUnavailable) return new Response(null, { status: 503 });
        assertEquals(Object.keys(body), ["p_cache_key"]);
        return Response.json(
          this.records.filter((row) => row.cache_key === body.p_cache_key),
        );
      case "/rest/v1/rpc/word_pack_library_claim":
        this.claimCalls++;
        if (
          this.claimBusy ||
          (this.leaseCacheKey === body.p_cache_key &&
            this.leaseUntil > Date.now() &&
            this.token !== body.p_token)
        ) return Response.json(false);
        this.token = body.p_token;
        this.leaseCacheKey = body.p_cache_key;
        this.leaseUntil = Date.now() + 5 * 60_000;
        return Response.json(true);
      case "/rest/v1/rpc/word_pack_library_publish":
        this.publishCalls++;
        if (this.publicationUnavailable) {
          return new Response(null, { status: 503 });
        }
        if (
          body.p_token !== this.token ||
          body.p_record.cache_key !== this.leaseCacheKey ||
          this.leaseUntil <= Date.now()
        ) return Response.json(false);
        assert(!("user_id" in body.p_record));
        assert(!("theme" in body.p_record));
        this.records.push(structuredClone(body.p_record));
        return Response.json(true);
      case "/rest/v1/rpc/word_pack_library_release":
        this.releaseCalls++;
        if (
          body.p_token === this.token && body.p_cache_key === this.leaseCacheKey
        ) {
          this.token = null;
          this.leaseCacheKey = null;
          this.leaseUntil = 0;
        }
        return new Response(null, { status: 204 });
      default:
        throw new Error("Unexpected library RPC");
    }
  };
}

Deno.test("actual generation handler preserves durable operation recovery across SDK HTTP boundaries", async (test) => {
  const originalServe = Deno.serve;
  const originalEnvGet = Deno.env.get;
  const originalAdapter = axios.defaults.adapter;
  const originalFetch = globalThis.fetch;
  const originalLogs = {
    error: console.error,
    warn: console.warn,
    info: console.info,
  };
  let handler: ((req: Request) => Promise<Response>) | undefined;
  let unexpectedNetworkCalls = 0;
  let db = new GenerationHTTPStore();
  let library = new LibraryHTTPStore();
  let sharedEnabled = false;
  const metrics: Row[] = [];
  const seedLibrary = async () => {
    const request = await prepareSharedWordPackRequest({
      theme: "Musical instruments",
      language: "und",
      promptVersion: WORD_PACK_CACHE_VERSION,
      requestedCount: 12,
      exclusions: [],
    });
    library.records.push(
      await buildSharedWordPackVariant({
        request,
        result: { words: WORDS.slice(0, 12), exhausted: false },
      }),
    );
  };
  const invoke = async (
    requestID = "actual-handler-request",
    count = 12,
    extra: Row = {},
  ) => {
    assert(handler);
    return await handler(
      new Request("https://example.test/functions/generateWordPack", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-user-token",
          "Base44-Service-Authorization": "Bearer test-service-token",
          "Base44-App-Id": APP_ID,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          request_id: requestID,
          theme: "Musical instruments",
          count,
          prefer_fresh: true,
          ...extra,
        }),
      }),
    );
  };
  const expectNoNewEffects = (calls: number, quota: number) => {
    assertEquals(db.providerCalls, calls);
    assertEquals(db.quotaReservations, quota);
    assertEquals(db.unexpected, []);
  };
  try {
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as typeof Deno.serve;
    // Exercise real quota reservation while using only local fake credentials.
    // No real environment secret is read, and the direct provider is disabled.
    Deno.env.get = (name) => {
      if (name === "SPYCLASH_SHARED_WORD_PACKS_ENABLED") {
        return sharedEnabled ? "true" : "false";
      }
      if (name === "SPYCLASH_WORD_LIBRARY_SUPABASE_URL") {
        return "https://library.example.test";
      }
      if (name === "SPYCLASH_WORD_LIBRARY_SUPABASE_SECRET") {
        return "sb_secret_local_library_fixture";
      }
      return name === "SPYCLASH_LIMITLESS_ENABLED" ||
          name === "SPYCLASH_REWARDED_GENERATION_ENABLED"
        ? "true"
        : undefined;
    };
    axios.defaults.adapter = (config) => db.handle(config);
    globalThis.fetch = ((input, init) => {
      if (
        String(input).startsWith("https://library.example.test/rest/v1/rpc/")
      ) return library.handle(input, init);
      unexpectedNetworkCalls += 1;
      return Promise.reject(
        new Error("External network is forbidden in this test"),
      );
    }) as typeof fetch;
    console.error = console.warn = () => {};
    console.info = (...args) => {
      if (args[0] === "generateWordPack metrics:") {
        metrics.push(JSON.parse(String(args[1])));
      }
    };
    await import("./main.ts");

    await test.step("successful generation journals before quota/provider and replay adds no effects", async () => {
      db = new GenerationHTTPStore();
      const first = await invoke();
      assertEquals(first.status, 200);
      const payload = await first.json();
      assertEquals(payload.words, WORDS.slice(0, 12));
      assertEquals(db.journalStateAtProvider, ["running"]);
      assertEquals(db.rows("AiWordPackOperation")[0].state, "completed");
      assertEquals(db.quotaReservations, 1);
      const replay = await invoke();
      assertEquals(replay.status, 200);
      assertEquals((await replay.json()).words, payload.words);
      expectNoNewEffects(1, 1);
    });

    for (const state of ["legacy-completed", "completed", "running", "prepared"] as const) {
      await test.step(`historical whole-items-v2 ${state} request survives cache version migration`, async () => {
        db = new GenerationHTTPStore();
        const requestID = `historical-${state}`;
        const identity = await prepareWordPackIdempotency({
          userID: db.userID, requestID,
          request: await prepareWordPackCacheRequest({
            userID: db.userID, theme: "Musical instruments", language: "und",
            promptVersion: "word-pack-2026-08-29-v5-gpt_5_4-whole-items-v2",
            requestedCount: 12, exclusions: [],
          }),
        });
        const now = new Date().toISOString();
        if (state === "legacy-completed") {
          db.rows("AiWordPackRequestResult").push({
            id: "historical-result",
            ...await buildWordPackRequestResultRecord({
              identity,
              result: { category: "AI GENERATED", words: WORDS.slice(0, 12), exhausted: false },
            }),
          });
        } else {
          db.rows("AiWordPackOperation").push({
            id: "historical-operation", request_key: identity.requestKey,
            user_id: identity.userID, request_id: identity.requestID,
            request_fingerprint: identity.requestFingerprint,
            operation_token: "historical-operation-token", state,
            updated_at: now, created_date: now,
            ...(state === "completed" ? {
              result_category: "AI GENERATED", result_words: WORDS.slice(0, 12),
              exhausted: false, completed_at: now,
            } : {}),
          });
        }
        const response = await invoke(requestID);
        const payload = await response.json();
        if (state === "running") {
          assertEquals(response.status, 503);
          assertEquals(payload.code, "generation_outcome_unknown");
          expectNoNewEffects(0, 0);
        } else {
          assertEquals(response.status, 200);
          assertEquals(payload.words, WORDS.slice(0, 12));
          const resumed = state === "prepared" ? 1 : 0;
          expectNoNewEffects(resumed, resumed);
          const replay = await invoke(requestID);
          assertEquals(replay.status, 200);
          assertEquals((await replay.json()).words, payload.words);
          expectNoNewEffects(resumed, resumed);
        }
        assertEquals((await invoke(requestID, 13)).status, 409);
        assertEquals((await invoke(requestID, 12, {exclude_words: ["Piano"]})).status, 409);
      });
    }

    await test.step("generation and durable replay preserve commas and semicolons within each AI entry", async () => {
      db = new GenerationHTTPStore();
      db.providerWords = [
        "Piano, grand",
        "Drums; electronic",
        ...WORDS.slice(2),
      ];
      const first = await invoke();
      assertEquals(first.status, 200);
      const expected = db.providerWords.slice(0, 12);
      assertEquals((await first.json()).words, expected);
      const replay = await invoke();
      assertEquals(replay.status, 200);
      assertEquals((await replay.json()).words, expected);
      expectNoNewEffects(1, 1);
    });

    await test.step("shared hit is a successful charged generation even with prefer_fresh, and replay is free", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        await seedLibrary();
        const first = await invoke();
        assertEquals(first.status, 200);
        const payload = await first.json();
        assertEquals(payload.words, WORDS.slice(0, 12));
        assertEquals(payload.cache_hit, true);
        assertEquals(payload.ai_generations_today, 1);
        assertEquals(metrics.at(-1)?.source, "shared_library");
        assertEquals(db.rows("AiWordPackOperation")[0].state, "completed");
        assertEquals(library.readCalls, 1);
        assertEquals(library.claimCalls, 0);
        const replay = await invoke();
        assertEquals(replay.status, 200);
        assertEquals((await replay.json()).request_replayed, true);
        assertEquals(
          library.readCalls,
          1,
          "exact durable replay does not depend on the library",
        );
        expectNoNewEffects(0, 1);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("each independent shared hit consumes a point and cached words do not bypass an exhausted balance", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        await seedLibrary();
        for (let i = 1; i <= 3; i++) {
          const response = await invoke(`shared-success-${i}`);
          assertEquals(response.status, 200);
          assertEquals((await response.json()).ai_generations_today, i);
        }
        assertEquals((await invoke("no-points-left")).status, 429);
        assertEquals(library.readCalls, 3);
        expectNoNewEffects(0, 3);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("shared hit spends an earned bonus once after daily points are exhausted", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        await seedLibrary();
        db.rows("AiGenerationUsage").push({
          id: "spent-daily-quota",
          quota_key: quotaKey(db.userID),
          user_id: db.userID,
          usage_date: utcUsageDate(),
          generations_used: 3,
        });
        db.rows("GenerationReward").push({
          id: "earned-bonus",
          user_id: db.userID,
          attempt_id: crypto.randomUUID(),
          state: "earned",
        });
        const response = await invoke("shared-bonus-request");
        assertEquals(response.status, 200);
        assertEquals((await response.json()).cache_hit, true);
        assertEquals(db.rows("GenerationReward")[0].state, "spent");
        assertEquals(
          db.rows("GenerationReward")[0].generation_request_id,
          "shared-bonus-request",
        );
        assertEquals((await invoke("shared-bonus-request")).status, 200);
        assertEquals(db.rows("GenerationReward")[0].state, "spent");
        assertEquals((await invoke("needs-another-point")).status, 429);
        expectNoNewEffects(0, 0);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("a generated pack is reused by another account with a separate successful charge", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        const generated = await invoke("first-author");
        assertEquals(generated.status, 200);
        assertEquals((await generated.json()).cache_hit, false);
        assertEquals(library.records.length, 1);
        assertEquals(library.publishCalls, 1);
        assertEquals(library.releaseCalls, 1);
        db.userID = "second-player";
        const reused = await invoke("second-player-request");
        assertEquals(reused.status, 200);
        const payload = await reused.json();
        assertEquals(payload.cache_hit, true);
        assertEquals(payload.ai_generations_today, 1);
        assertEquals(payload.words, WORDS.slice(0, 12));
        assertEquals(
          db.rows("AiGenerationUsage").map((
            row,
          ) => [row.user_id, row.generations_used]),
          [["journal-user", 1], ["second-player", 1]],
        );
        expectNoNewEffects(1, 2);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("larger requests retain every existing name and generate only the missing words", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        const first = await invoke("small-source", 5);
        assertEquals(first.status, 200);
        const original = (await first.json()).words;
        db.providerWords = WORDS.slice(5);
        db.userID = "second-player";
        const larger = await invoke("larger-target", 7);
        assertEquals(larger.status, 200);
        const payload = await larger.json();
        assertEquals(payload.words, WORDS.slice(0, 7));
        assertEquals(payload.words.slice(0, 5), original);
        assertEquals(payload.cache_hit, false);
        assertEquals(db.providerRequests.at(-1)?.response_json_schema.properties.draft_words.maxItems, 2);
        assert(db.providerRequests.at(-1)?.prompt.includes(JSON.stringify(original)));
        assertEquals(db.providerCalls, 2);
        assertEquals(db.quotaReservations, 2);
        const replay = await invoke("larger-target", 7);
        assertEquals((await replay.json()).words, payload.words);
        assertEquals(db.providerCalls, 2);
        assertEquals(db.quotaReservations, 2);
      } finally { sharedEnabled = false; }
    });

    await test.step("top-up removes excluded stock and supports the full public exclusion allowance", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        assertEquals((await invoke("source-before-exclusions", 5)).status, 200);
        db.providerWords = WORDS.slice(5);
        const exclusions = [WORDS[0], ...Array.from({ length: 199 }, (_, i) => `Used ${i}`)];
        const response = await invoke("expanded-exclusions", 6, { exclude_words: exclusions });
        assertEquals(response.status, 200);
        assertEquals((await response.json()).words, WORDS.slice(1, 7));
        assertEquals(db.providerRequests.at(-1)?.response_json_schema.properties.draft_words.maxItems, 2);
        const prompt = db.providerRequests.at(-1)?.prompt;
        assert(prompt.includes(JSON.stringify([...exclusions, ...WORDS.slice(1, 5)])));
        assertEquals(db.providerCalls, 2);
      } finally { sharedEnabled = false; }
    });

    await test.step("library outage stops before journal, point reservation and model, then the same request recovers", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        library.readUnavailable = true;
        const failed = await invoke();
        assertEquals(failed.status, 503);
        const unavailable = await failed.json();
        assertEquals(unavailable.retryable, true);
        assertEquals(unavailable.retry_phase, "before_effects");
        assertEquals(unavailable.effects_started, false);
        assertEquals(db.rows("AiWordPackOperation").length, 0);
        expectNoNewEffects(0, 0);
        library.readUnavailable = false;
        await seedLibrary();
        assertEquals((await invoke()).status, 200);
        expectNoNewEffects(0, 1);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("another topic producer causes a retryable response without a point charge", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        library.claimBusy = true;
        const failed = await invoke();
        assertEquals(failed.status, 503);
        const payload = await failed.json();
        assertEquals(payload.code, "shared_library_busy");
        assertEquals(payload.retryable, true);
        assertEquals(payload.retry_phase, "before_effects");
        assertEquals(payload.effects_started, false);
        assertEquals(db.rows("AiWordPackOperation").length, 0);
        assertEquals(library.releaseCalls, 0);
        expectNoNewEffects(0, 0);
        await seedLibrary();
        assertEquals((await invoke()).status, 200);
        expectNoNewEffects(0, 1);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("library publication failure preserves a charged durable success and replay does not regenerate", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        library.publicationUnavailable = true;
        assertEquals((await invoke()).status, 200);
        assertEquals(library.publishCalls, 1);
        assertEquals(library.releaseCalls, 1);
        assertEquals(db.rows("AiWordPackOperation")[0].state, "completed");
        assertEquals((await invoke()).status, 200);
        expectNoNewEffects(1, 1);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("unknown provider outcome keeps its topic lease so another account cannot duplicate paid work", async () => {
      db = new GenerationHTTPStore();
      library = new LibraryHTTPStore();
      sharedEnabled = true;
      try {
        db.loseProviderResponse = true;
        const first = await invoke("unknown-shared-outcome");
        assertEquals(first.status, 503);
        assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
        assertEquals(library.releaseCalls, 0);
        assert(library.token);
        assert(library.leaseUntil > Date.now());
        const ownerToken = library.token;
        expectNoNewEffects(1, 1);

        db.userID = "second-player";
        db.loseProviderResponse = false;
        const second = await invoke("second-player-same-topic");
        assertEquals(second.status, 503);
        const busy = await second.json();
        assertEquals(busy.code, "shared_library_busy");
        assertEquals(busy.retryable, true);
        assertEquals(busy.retry_phase, "before_effects");
        assertEquals(busy.effects_started, false);
        assertEquals(library.token, ownerToken);
        assertEquals(library.releaseCalls, 0);
        assertEquals(db.rows("AiWordPackOperation").length, 1);
        assertEquals(db.rows("AiGenerationUsage").map((row) => row.user_id), [
          "journal-user",
        ]);
        expectNoNewEffects(1, 1);

        db.userID = "journal-user";
        const retry = await invoke("unknown-shared-outcome");
        assertEquals(retry.status, 503);
        // The original journal remains unresolved; a library lease expiry must
        // never make that original paid request executable a second time.
        assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
        assertEquals(library.token, ownerToken);
        assertEquals(library.releaseCalls, 0);
        expectNoNewEffects(1, 1);

        library.leaseUntil = Date.now() - 1;
        const afterExpiry = await invoke("unknown-shared-outcome");
        assertEquals(afterExpiry.status, 503);
        assertEquals(
          (await afterExpiry.json()).code,
          "generation_outcome_unknown",
        );
        assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
        assertEquals(library.token, null);
        assertEquals(library.releaseCalls, 1);
        expectNoNewEffects(1, 1);
      } finally {
        sharedEnabled = false;
      }
    });

    await test.step("disabled reward rollout preserves live unlimited access with the global LIMITLESS flag enabled", async () => {
      db = new GenerationHTTPStore();
      const enabledEnvironment = Deno.env.get;
      Deno.env.get = (name) =>
        name === "SPYCLASH_LIMITLESS_ENABLED" ? "true" : undefined;
      try {
        const first = await invoke();
        assertEquals(first.status, 200);
        const payload = await first.json();
        assertEquals(payload.protocol, "casada");
        assertEquals(payload.ai_limit, null);
        assertEquals(payload.active, true);
        expectNoNewEffects(1, 0);
      } finally {
        Deno.env.get = enabledEnvironment;
      }
    });

    await test.step("lost provider result leaves running and retry cannot call provider or reserve quota again", async () => {
      db = new GenerationHTTPStore();
      db.loseProviderResponse = true;
      assertEquals((await invoke()).status, 503);
      assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
      db.loseProviderResponse = false;
      const retry = await invoke();
      assertEquals(retry.status, 503);
      const payload = await retry.json();
      assertEquals(payload.code, "generation_outcome_unknown");
      assertEquals(payload.retryable, false);
      expectNoNewEffects(1, 1);
    });

    await test.step("lost running confirmation stops before quota/provider and later retry remains blocked", async () => {
      db = new GenerationHTTPStore();
      db.failRunningConfirmationOnce = true;
      assertEquals((await invoke()).status, 503);
      assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
      const retry = await invoke();
      assertEquals(retry.status, 503);
      assertEquals((await retry.json()).code, "generation_outcome_unknown");
      expectNoNewEffects(0, 0);
    });

    await test.step("lost completion response reconciles the exact committed result", async () => {
      db = new GenerationHTTPStore();
      db.loseCompletionResponseOnce = true;
      const first = await invoke();
      assertEquals(first.status, 200);
      assertEquals((await first.json()).words, WORDS.slice(0, 12));
      assertEquals(db.rows("AiWordPackOperation")[0].state, "completed");
      assertEquals((await invoke()).status, 200);
      expectNoNewEffects(1, 1);
    });

    await test.step("completed journal serves exact words during old replay-store outage or expiry", async () => {
      db = new GenerationHTTPStore();
      assertEquals((await invoke()).status, 200);
      db.legacyReadUnavailable = true;
      const replay = await invoke();
      assertEquals(replay.status, 200);
      assertEquals((await replay.json()).words, WORDS.slice(0, 12));
      db.legacyReadUnavailable = false;
      db.tables.set("AiWordPackRequestResult", []);
      assertEquals((await invoke()).status, 200);
      expectNoNewEffects(1, 1);
    });

    await test.step("old durable result remains replayable if journal lookup is unavailable", async () => {
      db = new GenerationHTTPStore();
      assertEquals((await invoke()).status, 200);
      db.tables.set("AiWordPackOperation", []);
      db.journalReadUnavailable = true;
      const replay = await invoke();
      assertEquals(replay.status, 200);
      assertEquals((await replay.json()).words, WORDS.slice(0, 12));
      expectNoNewEffects(1, 1);
    });

    await test.step("unavailable recovery stores fail before quota or provider", async () => {
      db = new GenerationHTTPStore();
      db.journalReadUnavailable = true;
      db.legacyReadUnavailable = true;
      assertEquals((await invoke()).status, 503);
      expectNoNewEffects(0, 0);
    });

    await test.step("completion outage preserves confirmed legacy result without repeating generation", async () => {
      db = new GenerationHTTPStore();
      db.journalCompletionUnavailable = true;
      const first = await invoke();
      assertEquals(first.status, 200);
      assertEquals((await first.json()).words, WORDS.slice(0, 12));
      assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
      assertEquals(db.rows("AiWordPackRequestResult").length, 1);
      const replay = await invoke();
      assertEquals(replay.status, 200);
      expectNoNewEffects(1, 1);
    });

    await test.step("failed result persistence after provider cannot authorize a second execution", async () => {
      db = new GenerationHTTPStore();
      db.legacyWriteUnavailable = true;
      assertEquals((await invoke()).status, 503);
      db.legacyWriteUnavailable = false;
      const retry = await invoke();
      assertEquals(retry.status, 503);
      assertEquals((await retry.json()).code, "generation_outcome_unknown");
      expectNoNewEffects(1, 1);
    });

    for (
      const fault of [
        "loseLegacyCreateResponseOnce",
        "failLegacyConfirmationOnce",
      ] as const
    ) {
      await test.step(`${fault} does not claim confirmed success but later replays the saved result`, async () => {
        db = new GenerationHTTPStore();
        db[fault] = true;
        // A persisted row alone does not make executeGeneration successful:
        // its required create response and canonical reread must both finish.
        assertEquals((await invoke()).status, 503);
        assertEquals(db.rows("AiWordPackOperation")[0].state, "running");
        assertEquals(db.rows("AiWordPackRequestResult").length, 1);
        const replay = await invoke();
        assertEquals(replay.status, 200);
        assertEquals((await replay.json()).words, WORDS.slice(0, 12));
        expectNoNewEffects(1, 1);
      });
    }

    await test.step("reused identity with a changed count remains a conflict", async () => {
      db = new GenerationHTTPStore();
      assertEquals((await invoke()).status, 200);
      const conflict = await invoke("actual-handler-request", 24);
      assertEquals(conflict.status, 409);
      expectNoNewEffects(1, 1);
    });

    await test.step("deletion during provider latency prevents late journal or replay-result recreation", async () => {
      db = new GenerationHTTPStore();
      db.deleteAccountAfterProvider = true;
      const response = await invoke();
      assert(response.status >= 400);
      assertEquals(db.rows("AiWordPackOperation").length, 0);
      assertEquals(db.rows("AiWordPackRequestResult").length, 0);
      assertEquals(db.rows("AiWordPackCacheVariant").length, 0);
      expectNoNewEffects(1, 1);
    });
    assertEquals(unexpectedNetworkCalls, 0);
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalEnvGet;
    axios.defaults.adapter = originalAdapter;
    globalThis.fetch = originalFetch;
    Object.assign(console, originalLogs);
  }
});

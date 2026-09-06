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
  tables = new Map<string, Row[]>();
  providerCalls = 0;
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
        id: "journal-user",
        email: "journal@example.test",
        ai_generations_today: 0,
      });
    }
    if (
      path === `/apps/${APP_ID}/integration-endpoints/Core/InvokeLLM` &&
      method === "POST"
    ) {
      this.providerCalls += 1;
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
      const words = WORDS.slice(0, count);
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
          this.rows("AiWordPackOperation")[0]?.state,
          "running",
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
  const invoke = async (requestID = "actual-handler-request", count = 12) => {
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
    Deno.env.get = (name) =>
      name === "SPYCLASH_LIMITLESS_ENABLED" ? "true" : undefined;
    axios.defaults.adapter = (config) => db.handle(config);
    globalThis.fetch = (() => {
      unexpectedNetworkCalls += 1;
      return Promise.reject(
        new Error("External network is forbidden in this test"),
      );
    }) as typeof fetch;
    console.error = console.warn = console.info = () => {};
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

import {
  assertEquals,
  assertNotEquals,
  assertRejects,
} from "jsr:@std/assert@1";
import { prepareWordPackCacheRequest } from "./generation-cache.ts";
import {
  lookupIdempotentWordPackResult,
  persistIdempotentWordPackResult,
  prepareWordPackIdempotency,
  pruneExpiredWordPackRequestResults,
  selectIdempotentWordPackResult,
  WordPackIdempotencyConflictError,
  WordPackIdempotencyUnavailableError,
} from "./generation-idempotency.ts";

const NOW = new Date("2026-07-24T12:00:00.000Z");

Deno.test("idempotency outage error is sanitized and retryable", () => {
  const error = new WordPackIdempotencyUnavailableError();
  assertEquals(error.status, 503);
  assertEquals(error.code, "word_pack_idempotency_unavailable");
  assertEquals(error.retryable, true);
});

class MockStore {
  records: Record<string, unknown>[] = [];

  async filter(
    filter: Record<string, unknown>,
    sort = "created_date",
    limit = 20,
    skip = 0,
  ) {
    const descending = sort.startsWith("-");
    const field = descending ? sort.slice(1) : sort;
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).sort((left, right) => {
      const order = String(left[field] ?? "").localeCompare(
        String(right[field] ?? ""),
      );
      return descending ? -order : order;
    }).slice(skip, skip + limit).map((record) => structuredClone(record));
  }

  async create(value: Record<string, unknown>) {
    const created = {
      ...structuredClone(value),
      id: `request-${this.records.length + 1}`,
      created_date: new Date(NOW.getTime() + this.records.length).toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }
}

async function preparedRequest(exclusions: unknown[] = []) {
  return await prepareWordPackCacheRequest({
    userID: "user-1",
    theme: "Classic Cinema",
    language: "en",
    promptVersion: "word-pack-v4",
    requestedCount: 5,
    exclusions,
  });
}

Deno.test("idempotency key is user plus opaque request_id and fingerprint binds inputs", async () => {
  const request = await preparedRequest();
  const first = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "Request-A",
    request,
  });
  const same = await prepareWordPackIdempotency({
    userID: " user-1 ",
    requestID: " Request-A ",
    request,
  });
  assertEquals(first, same);

  const otherUserRequest = await prepareWordPackCacheRequest({
    userID: "user-2",
    theme: "Classic Cinema",
    language: "en",
    promptVersion: "word-pack-v4",
    requestedCount: 5,
  });
  const otherUser = await prepareWordPackIdempotency({
    userID: "user-2",
    requestID: "Request-A",
    request: otherUserRequest,
  });
  assertNotEquals(first.requestKey, otherUser.requestKey);

  const changedInput = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "Request-A",
    request: await preparedRequest(["Moon"]),
  });
  assertEquals(first.requestKey, changedInput.requestKey);
  assertNotEquals(first.requestFingerprint, changedInput.requestFingerprint);
});

Deno.test("successful result replays exactly, including exhausted, without a second row", async () => {
  const store = new MockStore();
  const identity = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-1",
    request: await preparedRequest(),
  });
  const input = {
    store,
    identity,
    now: NOW,
    result: {
      category: "Cinema",
      words: ["Arrival", "Moon", "Jaws", "Alien", "Heat"],
      exhausted: true,
    },
  };
  const first = await persistIdempotentWordPackResult(input);
  const replay = await persistIdempotentWordPackResult({
    ...input,
    result: {
      category: "Ignored concurrent response",
      words: ["A", "B", "C", "D", "E"],
      exhausted: false,
    },
  });
  assertEquals(replay, first);
  assertEquals(replay.exhausted, true);
  assertEquals(store.records.length, 1);
});

Deno.test("unexpired request_id reuse with different inputs fails closed", async () => {
  const store = new MockStore();
  const original = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-2",
    request: await preparedRequest(),
  });
  await persistIdempotentWordPackResult({
    store,
    identity: original,
    now: NOW,
    result: {
      category: "Cinema",
      words: ["Arrival", "Moon", "Jaws", "Alien", "Heat"],
      exhausted: false,
    },
  });
  const conflicting = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-2",
    request: await preparedRequest(["Moon"]),
  });
  await assertRejects(
    () =>
      lookupIdempotentWordPackResult({
        store,
        identity: conflicting,
        now: NOW,
      }),
    WordPackIdempotencyConflictError,
  );
});

Deno.test("expired idempotency rows no longer replay or conflict", async () => {
  const original = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-3",
    request: await preparedRequest(),
  });
  const changed = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-3",
    request: await preparedRequest(["Moon"]),
  });
  const result = selectIdempotentWordPackResult({
    identity: changed,
    now: NOW,
    records: [{
      request_key: original.requestKey,
      user_id: original.userID,
      request_id: original.requestID,
      request_fingerprint: original.requestFingerprint,
      result_category: "Cinema",
      result_words: ["Arrival", "Moon"],
      exhausted: false,
      completed_at: "2026-07-23T10:00:00.000Z",
      expires_at: NOW.toISOString(),
    }],
  });
  assertEquals(result, null);
});

Deno.test("duplicate equivalent rows converge on the oldest completed result", async () => {
  const identity = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-4",
    request: await preparedRequest(),
  });
  const base = {
    request_key: identity.requestKey,
    user_id: identity.userID,
    request_id: identity.requestID,
    request_fingerprint: identity.requestFingerprint,
    exhausted: false,
    expires_at: "2026-07-25T12:00:00.000Z",
  };
  const selected = selectIdempotentWordPackResult({
    identity,
    now: NOW,
    records: [{
      ...base,
      id: "later",
      result_category: "Later",
      result_words: ["Six", "Seven"],
      completed_at: "2026-07-24T12:00:01.000Z",
    }, {
      ...base,
      id: "first",
      result_category: "First",
      result_words: ["One", "Two"],
      completed_at: "2026-07-24T12:00:00.000Z",
    }],
  });
  assertEquals(selected?.category, "First");
  assertEquals(selected?.recordID, "first");
});

Deno.test("lookup cannot hide a new active replay behind expired history", async () => {
  const identity = await prepareWordPackIdempotency({
    userID: "user-1",
    requestID: "request-reused-over-time",
    request: await preparedRequest(),
  });
  const store = new MockStore();
  store.records = Array.from({ length: 20 }, (_, index) => ({
    id: `expired-${index}`,
    request_key: identity.requestKey,
    user_id: identity.userID,
    request_id: identity.requestID,
    request_fingerprint: identity.requestFingerprint,
    result_category: "Expired",
    result_words: ["Old One", "Old Two"],
    exhausted: false,
    completed_at: new Date(
      NOW.getTime() - (index + 2) * 60_000,
    ).toISOString(),
    expires_at: new Date(NOW.getTime() - 60_000).toISOString(),
    created_date: new Date(
      NOW.getTime() - (index + 2) * 60_000,
    ).toISOString(),
  }));
  store.records.push({
    id: "active-newest",
    request_key: identity.requestKey,
    user_id: identity.userID,
    request_id: identity.requestID,
    request_fingerprint: identity.requestFingerprint,
    result_category: "Current",
    result_words: ["New One", "New Two"],
    exhausted: true,
    completed_at: NOW.toISOString(),
    expires_at: new Date(NOW.getTime() + 60_000).toISOString(),
    created_date: NOW.toISOString(),
  });

  const replay = await lookupIdempotentWordPackResult({
    store,
    identity,
    now: NOW,
  });
  assertEquals(replay?.recordID, "active-newest");
  assertEquals(replay?.words, ["New One", "New Two"]);
});

Deno.test("idempotency prune physically removes only expired rows for the user", async () => {
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
    await pruneExpiredWordPackRequestResults({
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

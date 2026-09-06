import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  lookupCompletedWordPackOperation,
  runWordPackOperation,
  WordPackOperationError,
  type WordPackOperationRecord,
  type WordPackOperationStore,
} from "./generation-operation.ts";
import { WordPackIdempotencyConflictError } from "./generation-idempotency.ts";

const identity = {
  userID: "user-a",
  requestID: "request-a",
  requestKey: "key-a",
  requestFingerprint: "fingerprint-a",
};
const words = {
  category: "AI GENERATED",
  words: ["One", "Two", "Three"],
  exhausted: false,
};
const guard = {
  boundary: <T>(operation: () => Promise<T>) => operation(),
  assertAvailable: () => Promise.resolve(),
};
const now = () => new Date("2026-09-06T17:00:00Z");

class Store implements WordPackOperationStore {
  rows: WordPackOperationRecord[] = [];
  reads = 0;
  writes = 0;
  creates = 0;
  failReadAt = new Set<number>();
  createLosesResponse = false;
  updateLosesResponse = new Set<number>();
  updateFailsBeforeCommit = new Set<number>();
  beforeUpdate?: (query: Record<string, unknown>) => void;

  filter(_query: Record<string, unknown>, _sort: string, limit: number) {
    this.reads += 1;
    if (this.failReadAt.has(this.reads)) {
      return Promise.reject(new Error("read unavailable"));
    }
    return Promise.resolve(structuredClone(this.rows.slice(0, limit)));
  }
  create(record: WordPackOperationRecord) {
    this.creates += 1;
    const saved = { ...structuredClone(record), id: `row-${this.creates}` };
    this.rows.push(saved);
    return this.createLosesResponse
      ? Promise.reject(new Error("lost create response"))
      : Promise.resolve(saved);
  }
  updateMany(
    query: Record<string, unknown>,
    update: Record<string, Record<string, unknown>>,
  ) {
    this.writes += 1;
    this.beforeUpdate?.(query);
    if (this.updateFailsBeforeCommit.has(this.writes)) {
      return Promise.reject(new Error("not committed"));
    }
    const matching = this.rows.filter((row) =>
      Object.entries(query).every(([key, value]) =>
        (row as unknown as Record<string, unknown>)[key] === value
      )
    );
    for (const row of matching) {
      Object.assign(row, structuredClone(update.$set));
    }
    if (this.updateLosesResponse.has(this.writes)) {
      return Promise.reject(new Error("lost write response"));
    }
    return Promise.resolve({ updated: matching.length });
  }
}

function saved(
  state: WordPackOperationRecord["state"],
): WordPackOperationRecord {
  return {
    id: "row-old",
    request_key: identity.requestKey,
    user_id: identity.userID,
    request_id: identity.requestID,
    request_fingerprint: identity.requestFingerprint,
    operation_token: "old-token",
    state,
    updated_at: now().toISOString(),
    ...(state === "completed"
      ? {
        result_category: words.category,
        result_words: words.words,
        exhausted: false,
      }
      : {}),
  };
}

Deno.test("durable generation commits running before effects and replays the exact completed result", async () => {
  const store = new Store();
  let calls = 0;
  const execute = () => {
    calls += 1;
    assertEquals(store.rows[0].state, "running");
    return Promise.resolve({ value: "response", result: words });
  };
  assertEquals(
    await runWordPackOperation({ store, identity, guard, execute, now }),
    { replayed: false, value: "response" },
  );
  assertEquals(
    await runWordPackOperation({ store, identity, guard, execute, now }),
    { replayed: true, result: words },
  );
  assertEquals(calls, 1);
  assertEquals(store.creates, 1);
});

Deno.test("a killed invocation cannot rerun effects after the account lease and old result TTL expire", async () => {
  const store = new Store();
  let calls = 0;
  const execute = () => {
    calls += 1;
    return Promise.reject(new Error("process killed after provider accepted"));
  };
  await assertRejects(() =>
    runWordPackOperation({ store, identity, guard, execute, now })
  );
  assertEquals(store.rows[0].state, "running");
  await assertRejects(
    () =>
      runWordPackOperation({
        store,
        identity,
        guard,
        execute,
        now: () => new Date("2027-09-06"),
      }),
    WordPackOperationError,
    "not be repeated",
  );
  assertEquals(calls, 1);
});

Deno.test("crash before running marker permits one exact-token takeover without effects from old owner", async () => {
  const store = new Store();
  store.rows = [saved("prepared")];
  let calls = 0;
  await runWordPackOperation({
    store,
    identity,
    guard,
    now,
    randomUUID: () => "replacement",
    execute: () => {
      calls += 1;
      assertEquals(store.rows[0].operation_token, "replacement");
      return Promise.resolve({ value: 1, result: words });
    },
  });
  assertEquals(calls, 1);
  assertEquals(
    await store.updateMany({
      id: "row-old",
      state: "prepared",
      operation_token: "old-token",
    }, { $set: { state: "running" } }),
    { updated: 0 },
  );
});

Deno.test("lost create and running-CAS responses reconcile without creating or executing twice", async () => {
  const store = new Store();
  store.createLosesResponse = true;
  store.updateLosesResponse.add(1);
  let calls = 0;
  await runWordPackOperation({
    store,
    identity,
    guard,
    now,
    execute: () => {
      calls++;
      return Promise.resolve({ value: 1, result: words });
    },
  });
  assertEquals(store.creates, 1);
  assertEquals(calls, 1);
  assertEquals(store.rows[0].state, "completed");
});

Deno.test("failed running confirmation prevents effects and leaves a durable unknown outcome", async () => {
  const store = new Store();
  store.failReadAt.add(3);
  let calls = 0;
  const execute = () => {
    calls++;
    return Promise.resolve({ value: 1, result: words });
  };
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  assertEquals(calls, 0);
  assertEquals(store.rows[0].state, "running");
});

Deno.test("failed running CAS before commit allows a later prepared takeover", async () => {
  const store = new Store();
  store.updateFailsBeforeCommit.add(1);
  let calls = 0;
  const execute = () => {
    calls++;
    return Promise.resolve({ value: 1, result: words });
  };
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  assertEquals(calls, 0);
  assertEquals(store.rows[0].state, "prepared");
  await runWordPackOperation({ store, identity, guard, now, execute });
  assertEquals(calls, 1);
});

Deno.test("lost completion acknowledgement and transient reconciliation read never repeat execution", async () => {
  const store = new Store();
  store.updateLosesResponse.add(2);
  store.failReadAt.add(4);
  let calls = 0;
  const execute = () => {
    calls++;
    return Promise.resolve({ value: 1, result: words });
  };
  await runWordPackOperation({ store, identity, guard, now, execute });
  const replay = await runWordPackOperation({
    store,
    identity,
    guard,
    now,
    execute,
  });
  assertEquals(replay.replayed, true);
  assertEquals(calls, 1);
});

Deno.test("exhausted completion writes fail closed and never rerun effects", async () => {
  const store = new Store();
  store.updateFailsBeforeCommit = new Set([2, 3, 4]);
  let calls = 0;
  const execute = () => {
    calls++;
    return Promise.resolve({ value: 1, result: words });
  };
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  assertEquals(calls, 1);
  assertEquals(store.writes, 4);
});

Deno.test("non-successful generation response is terminal for this request identity", async () => {
  const store = new Store();
  let calls = 0;
  const execute = () => {
    calls++;
    return Promise.resolve({ value: "quota denied", result: null });
  };
  assertEquals(
    await runWordPackOperation({ store, identity, guard, now, execute }),
    { replayed: false, value: "quota denied" },
  );
  await assertRejects(
    () => runWordPackOperation({ store, identity, guard, now, execute }),
    WordPackOperationError,
  );
  assertEquals(calls, 1);
  assertEquals(store.rows[0].state, "failed");
});

Deno.test("duplicate rows, conflicting input, malformed success and wrong owners block provider work", async () => {
  for (
    const rows of [
      [saved("prepared"), { ...saved("prepared"), id: "duplicate" }],
      [{ ...saved("prepared"), request_fingerprint: "other" }],
      [{ ...saved("completed"), result_words: [] }],
      [{ ...saved("prepared"), user_id: "other-user" }],
    ]
  ) {
    const store = new Store();
    store.rows = rows;
    let calls = 0;
    await assertRejects(() =>
      runWordPackOperation({
        store,
        identity,
        guard,
        now,
        execute: () => {
          calls++;
          return Promise.resolve({ value: 1, result: words });
        },
      })
    );
    assertEquals(calls, 0);
  }
});

Deno.test("the same request id with changed count or exclusions is rejected", async () => {
  const store = new Store();
  store.rows = [saved("completed")];
  await assertRejects(
    () =>
      runWordPackOperation({
        store,
        identity: { ...identity, requestFingerprint: "different-input" },
        guard,
        now,
        execute: () => Promise.resolve({ value: 1, result: words }),
      }),
    WordPackIdempotencyConflictError,
  );
});

Deno.test("replacement owner winning the running CAS prevents the losing caller from executing", async () => {
  const store = new Store();
  store.rows = [saved("prepared")];
  let calls = 0;
  store.beforeUpdate = () => {
    store.rows[0].operation_token = "winner";
    store.rows[0].state = "running";
  };
  await assertRejects(
    () =>
      runWordPackOperation({
        store,
        identity,
        guard,
        now,
        execute: () => {
          calls++;
          return Promise.resolve({ value: 1, result: words });
        },
      }),
    WordPackOperationError,
  );
  assertEquals(calls, 0);
  assertEquals(store.rows[0].operation_token, "winner");
});

Deno.test("account deletion boundary failure prevents journal creation and provider work", async () => {
  const store = new Store();
  let calls = 0;
  const deletingGuard = {
    ...guard,
    boundary: <T>(_operation: () => Promise<T>): Promise<T> =>
      Promise.reject(new Error("account deleting")),
  };
  await assertRejects(
    () =>
      runWordPackOperation({
        store,
        identity,
        guard: deletingGuard,
        now,
        execute: () => {
          calls++;
          return Promise.resolve({ value: 1, result: words });
        },
      }),
    WordPackOperationError,
  );
  assertEquals(calls, 0);
  assertEquals(store.creates, 0);
});

Deno.test("confirmed legacy replay preserves valid words when journal completion storage is unavailable", async () => {
  const store = new Store();
  store.updateFailsBeforeCommit = new Set([2, 3, 4]);
  let calls = 0;
  const response = await runWordPackOperation({
    store,
    identity,
    guard,
    now,
    execute: () => {
      calls += 1;
      return Promise.resolve({
        value: "confirmed words",
        result: words,
        replayCommitted: true,
      });
    },
  });
  assertEquals(response, { replayed: false, value: "confirmed words" });
  assertEquals(calls, 1);
  assertEquals(store.rows[0].state, "running");
  await assertRejects(() =>
    runWordPackOperation({
      store,
      identity,
      guard,
      now,
      execute: () => {
        calls++;
        return Promise.resolve({ value: 2, result: words });
      },
    }), WordPackOperationError);
  assertEquals(calls, 1);
});

Deno.test("journal result replay does not depend on legacy result retention or another store", async () => {
  const store = new Store();
  store.rows = [saved("completed")];
  assertEquals(
    await lookupCompletedWordPackOperation({ store, identity }),
    words,
  );
  assertEquals(store.writes, 0);
  store.rows[0].state = "running";
  assertEquals(
    await lookupCompletedWordPackOperation({ store, identity }),
    null,
  );
});

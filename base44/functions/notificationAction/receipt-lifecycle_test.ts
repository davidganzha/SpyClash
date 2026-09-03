import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { NotificationContractError } from "./contracts.ts";
import { withNotificationWriteLease } from "./receipt-lifecycle.ts";

type Row = Record<string, any>;
class Store {
  records: Row[] = [];
  async filter(filter: Row) {
    return this.records.filter((row) =>
      Object.entries(filter).every(([key, value]) => row[key] === value)
    ).map((row) => structuredClone(row));
  }
  async create(row: Row) {
    const saved = { id: `row-${this.records.length + 1}`, ...row };
    this.records.push(saved);
    return structuredClone(saved);
  }
  async updateMany(filter: Row, update: Row) {
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!Object.entries(filter).every(([key, value]) => row[key] === value)) {
        return row;
      }
      updated += 1;
      return { ...row, ...(update.$set || {}) };
    });
    return { updated };
  }
}

function lease(attempt = 1) {
  return {
    recordID: "row-1",
    subjectKey: "billing:user-1",
    leaseToken: `notification:lease-${attempt}`,
    leaseUntil: "2099-01-01T00:00:00.000Z",
    revision: `revision-${attempt}`,
  };
}

Deno.test("receipt writes hold the account deletion opposing lease", async () => {
  const store = new Store();
  const values = Array.from({ length: 20 }, (_, index) => `uuid-${index}`);
  let persisted = false;
  await withNotificationWriteLease({
    lifecycleStore: store,
    userID: "user-1",
    action: async (persist) => {
      await persist(async () => {
        persisted = true;
      });
    },
    nowFactory: () => new Date("2026-07-27T12:00:00.000Z"),
    randomUUID: () => values.shift() || "uuid-fallback",
  });
  assertEquals(persisted, true);
  assertEquals(store.records[0].state, "active");
  store.records[0].state = "deleting";
  await assertRejects(() =>
    withNotificationWriteLease({
      lifecycleStore: store,
      userID: "user-1",
      action: async () => undefined,
      nowFactory: () => new Date("2026-07-27T12:00:01.000Z"),
    })
  );
});

Deno.test("notification lease acquisition retries before invoking the action once", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];
  const released: string[] = [];

  const result = await withNotificationWriteLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => {
      acquireCalls += 1;
      if (acquireCalls <= 2) {
        throw new NotificationContractError(
          "brief contention",
          409,
          acquireCalls === 1 ? "active_lease" : "cas_contention",
        );
      }
      return Promise.resolve(lease(acquireCalls));
    },
    release: (_store, acquiredLease) => {
      released.push(acquiredLease.leaseToken);
      return Promise.resolve();
    },
    assert: () => Promise.resolve(),
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    action: () => {
      actionCalls += 1;
      return Promise.resolve("committed");
    },
  });

  assertEquals(result, "committed");
  assertEquals(acquireCalls, 3);
  assertEquals(actionCalls, 1);
  assertEquals(delays, [50, 100]);
  assertEquals(released, ["notification:lease-3"]);
});

Deno.test("exhausted notification lease contention remains a typed 409 source", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withNotificationWriteLease({
        lifecycleStore: {},
        userID: "user-1",
        acquire: () => {
          acquireCalls += 1;
          throw new NotificationContractError(
            "still busy",
            409,
            "active_lease",
          );
        },
        release: () => Promise.resolve(),
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    NotificationContractError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(error.status, 409);
  assertEquals(acquireCalls, 7);
  assertEquals(actionCalls, 0);
  assertEquals(delays, [50, 100, 200, 400, 600, 800]);
});

Deno.test("notification action errors are never replayed", async () => {
  let actionCalls = 0;
  let acquireCalls = 0;
  const actionError = new NotificationContractError(
    "persistence changed",
    409,
    "cas_contention",
  );

  const error = await assertRejects(
    () =>
      withNotificationWriteLease({
        lifecycleStore: {},
        userID: "user-1",
        acquire: () => {
          acquireCalls += 1;
          return Promise.resolve(lease());
        },
        release: () => Promise.resolve(),
        assert: () => Promise.resolve(),
        delay: () => Promise.resolve(),
        action: () => {
          actionCalls += 1;
          return Promise.reject(actionError);
        },
      }),
    NotificationContractError,
  );

  assertEquals(error, actionError);
  assertEquals(acquireCalls, 1);
  assertEquals(actionCalls, 1);
});

Deno.test("notification lease release retries without replacing committed success", async () => {
  let releaseCalls = 0;
  const delays: number[] = [];
  const releaseErrors: unknown[] = [];

  const result = await withNotificationWriteLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => Promise.resolve(lease()),
    release: () => {
      releaseCalls += 1;
      if (releaseCalls < 3) throw new Error("release unavailable");
      return Promise.resolve();
    },
    assert: () => Promise.resolve(),
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    onReleaseError: (error) => releaseErrors.push(error),
    action: () => Promise.resolve("committed"),
  });

  assertEquals(result, "committed");
  assertEquals(releaseCalls, 3);
  assertEquals(delays, [50, 100]);
  assertEquals(releaseErrors, []);
});

Deno.test("failed notification cleanup cannot turn a committed receipt into an error", async () => {
  let writes = 0;
  let releaseCalls = 0;
  const releaseErrors: unknown[] = [];

  const result = await withNotificationWriteLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => Promise.resolve(lease()),
    release: () => {
      releaseCalls += 1;
      return Promise.reject(new Error("release unavailable"));
    },
    assert: () => Promise.resolve(),
    delay: () => Promise.resolve(),
    onReleaseError: (error) => releaseErrors.push(error),
    action: async (persist) => {
      await persist(async () => {
        writes += 1;
      });
      return "committed";
    },
  });

  assertEquals(result, "committed");
  assertEquals(writes, 1);
  assertEquals(releaseCalls, 3);
  assertEquals(releaseErrors.length, 1);
});

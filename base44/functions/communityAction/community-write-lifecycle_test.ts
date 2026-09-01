import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  acquireBillingDeletionMarker,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";

type RecordValue = Record<string, any>;
const NOW = new Date("2026-07-14T12:00:00.000Z");

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
}

function lease(userID: string, attempt = 1): BillingIdentityLease {
  return {
    recordID: `${userID}-record`,
    subjectKey: `${userID}-subject`,
    state: "active",
    leaseToken: `${userID}-lease-${attempt}`,
    leaseUntil: "2099-01-01T00:00:00.000Z",
    revision: `${userID}-revision-${attempt}`,
  };
}

class MockLifecycleStore {
  records: RecordValue[] = [];
  nextID = 1;

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `lifecycle-${this.nextID++}`,
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        updated += 1;
      }
    }
    return { updated };
  }
}

Deno.test("social create is rejected when either participant is deleting", async () => {
  const store = new MockLifecycleStore();
  await acquireBillingDeletionMarker(
    store,
    "user-b",
    () => NOW,
    sequence("delete"),
  );
  let actionCalls = 0;
  const error = await assertRejects(
    () =>
      withCommunityWriteLeases({
        lifecycleStore: store,
        userIDs: ["user-a", "user-b"],
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
        nowFactory: () => NOW,
        randomUUID: sequence("social"),
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "deletion_in_progress");
  assertEquals(actionCalls, 0);
});

Deno.test("guarded social persistence occurs entirely before deletion", async () => {
  const store = new MockLifecycleStore();
  let deletionErrorCode = "";
  let created = false;
  await withCommunityWriteLeases({
    lifecycleStore: store,
    userIDs: ["user-b", "user-a"],
    action: async ({ persist }) => {
      const error = await assertRejects(
        () =>
          acquireBillingDeletionMarker(
            store,
            "user-b",
            () => NOW,
            sequence("delete"),
          ),
        BillingIdentityLifecycleError,
      );
      deletionErrorCode = error.code;
      await persist(async () => {
        created = true;
      });
    },
    nowFactory: () => NOW,
    randomUUID: sequence("social"),
  });
  assertEquals(created, true);
  assertEquals(deletionErrorCode, "active_lease");

  const deletion = await acquireBillingDeletionMarker(
    store,
    "user-b",
    () => NOW,
    sequence("delete-after"),
  );
  assertEquals(deletion.state, "deleting");
});

Deno.test("suspended social action reasserts lease before persistence", async () => {
  const store = new MockLifecycleStore();
  let now = NOW;
  let wrote = false;
  let rejectionCode = "";
  await withCommunityWriteLeases({
    lifecycleStore: store,
    userIDs: ["user-a"],
    action: async ({ persist }) => {
      now = new Date(NOW.getTime() + 11 * 60 * 1_000);
      const error = await assertRejects(
        () =>
          persist(async () => {
            wrote = true;
          }),
        BillingIdentityLifecycleError,
      );
      rejectionCode = error.code;
    },
    nowFactory: () => now,
    randomUUID: sequence("suspended"),
  });
  assertEquals(rejectionCode, "active_lease");
  assertEquals(wrote, false);
});

Deno.test("community lease acquisition retries contention before invoking the action once", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];
  const released: string[] = [];

  const result = await withCommunityWriteLeases({
    lifecycleStore: {},
    userIDs: ["user-a"],
    acquire: (_store, userID) => {
      acquireCalls += 1;
      if (acquireCalls <= 2) {
        throw new BillingIdentityLifecycleError(
          acquireCalls === 1 ? "active_lease" : "cas_contention",
          "brief contention",
        );
      }
      return Promise.resolve(lease(userID, acquireCalls));
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
  assertEquals(released, ["user-a-lease-3"]);
});

Deno.test("partial community leases are released before acquisition retry", async () => {
  const events: string[] = [];
  let attempt = 1;

  await withCommunityWriteLeases({
    lifecycleStore: {},
    userIDs: ["user-b", "user-a"],
    acquire: (_store, userID) => {
      events.push(`acquire-${attempt}-${userID}`);
      if (attempt === 1 && userID === "user-b") {
        throw new BillingIdentityLifecycleError(
          "active_lease",
          "brief contention",
        );
      }
      return Promise.resolve(lease(userID, attempt));
    },
    release: (_store, acquiredLease) => {
      events.push(`release-${acquiredLease.leaseToken}`);
      return Promise.resolve();
    },
    assert: () => Promise.resolve(),
    delay: (milliseconds) => {
      events.push(`delay-${milliseconds}`);
      attempt += 1;
      return Promise.resolve();
    },
    action: () => {
      events.push("action");
      return Promise.resolve();
    },
  });

  assertEquals(events, [
    "acquire-1-user-a",
    "acquire-1-user-b",
    "release-user-a-lease-1",
    "delay-50",
    "acquire-2-user-a",
    "acquire-2-user-b",
    "action",
    "release-user-b-lease-2",
    "release-user-a-lease-2",
  ]);
});

Deno.test("community action contention is never replayed", async () => {
  let actionCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withCommunityWriteLeases({
        lifecycleStore: {},
        userIDs: ["user-a"],
        acquire: (_store, userID) => Promise.resolve(lease(userID)),
        release: () => Promise.resolve(),
        assert: () => Promise.resolve(),
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          throw new BillingIdentityLifecycleError(
            "cas_contention",
            "persistence boundary changed",
          );
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "cas_contention");
  assertEquals(actionCalls, 1);
  assertEquals(delays, []);
});

Deno.test("exhausted community lease contention remains a typed 409 source", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withCommunityWriteLeases({
        lifecycleStore: {},
        userIDs: ["user-a"],
        acquire: () => {
          acquireCalls += 1;
          throw new BillingIdentityLifecycleError(
            "active_lease",
            "still busy",
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
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(acquireCalls, 7);
  assertEquals(actionCalls, 0);
  assertEquals(delays, [50, 100, 200, 400, 600, 800]);
});

Deno.test("lease release failure cannot turn a committed social write into a retry", async () => {
  const store = new MockLifecycleStore();
  const updateMany = store.updateMany.bind(store);
  store.updateMany = async (filter: RecordValue, update: RecordValue) => {
    const leaseToken = String(update.$set?.lease_token || "");
    if (leaseToken.startsWith("released:")) {
      throw new Error("release response unavailable");
    }
    return await updateMany(filter, update);
  };
  let writes = 0;
  let loggedFailures = 0;
  const cyclicReleaseError: Record<string, unknown> = {
    message: "release response unavailable",
    status: 503,
    code: "lease_release_failed",
  };
  cyclicReleaseError.self = cyclicReleaseError;
  const originalConsoleError = console.error;
  console.error = (...values: unknown[]) => {
    JSON.stringify(values);
    loggedFailures += 1;
  };

  let result = "";
  try {
    result = await withCommunityWriteLeases({
      lifecycleStore: store,
      userIDs: ["user-a"],
      action: async ({ persist }) => {
        await persist(async () => {
          writes += 1;
        });
        return "committed";
      },
      nowFactory: () => NOW,
      randomUUID: sequence("release-failure"),
      release: () => Promise.reject(cyclicReleaseError),
      delay: () => Promise.resolve(),
    });
  } finally {
    console.error = originalConsoleError;
  }

  assertEquals(result, "committed");
  assertEquals(writes, 1);
  assertEquals(loggedFailures, 1);
});

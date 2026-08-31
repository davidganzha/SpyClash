import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  acquireBillingDeletionMarker,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";

type RecordValue = Record<string, any>;
const NOW = new Date("2026-07-14T12:00:00.000Z");

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
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
  const releaseErrors: unknown[] = [];

  const result = await withCommunityWriteLeases({
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
    onReleaseError: (error) => releaseErrors.push(error),
  });

  assertEquals(result, "committed");
  assertEquals(writes, 1);
  assertEquals(releaseErrors.length, 1);
});

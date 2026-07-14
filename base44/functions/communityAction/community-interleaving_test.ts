import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";

type Entity = Record<string, unknown>;

const NOW = new Date("2026-07-14T12:00:00.000Z");

class MockLifecycleStore {
  records: Entity[] = [];
  private nextID = 0;

  async filter(filter: Entity, _sort: string, limit: number, skip: number) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async create(value: Entity) {
    const record = {
      id: `lifecycle-${++this.nextID}`,
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
      ...structuredClone(value),
    };
    this.records.push(record);
    return structuredClone(record);
  }

  async updateMany(filter: Entity, update: { $set?: Entity }) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, structuredClone(update.$set || {}));
        updated += 1;
      }
    }
    return { updated };
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }
}

function sequence(prefix: string) {
  let counter = 0;
  return () => `${prefix}-${++counter}`;
}

Deno.test("block cannot overlap stale accept, comment, or invite persistence", async () => {
  for (const staleMutation of ["accept", "comment", "invite"]) {
    const lifecycleStore = new MockLifecycleStore();
    let blockWrites = 0;
    let staleWrites = 0;

    await withCommunityWriteLeases({
      lifecycleStore,
      userIDs: ["user-a", "user-b"],
      nowFactory: () => NOW,
      randomUUID: sequence(`block-${staleMutation}`),
      action: async ({ persist }) => {
        await persist(() => {
          blockWrites += 1;
          return Promise.resolve();
        });

        const error = await assertRejects(
          () =>
            withCommunityWriteLeases({
              lifecycleStore,
              userIDs: ["user-b", "user-a"],
              nowFactory: () => NOW,
              randomUUID: sequence(`stale-${staleMutation}`),
              action: async ({ persist: persistStale }) => {
                await persistStale(() => {
                  staleWrites += 1;
                  return Promise.resolve();
                });
              },
            }),
          BillingIdentityLifecycleError,
        );
        assertEquals(error.code, "active_lease", staleMutation);
      },
    });

    assertEquals(blockWrites, 1, staleMutation);
    assertEquals(staleWrites, 0, staleMutation);
  }
});

Deno.test("expired lease is reasserted immediately before every persistence", async () => {
  const lifecycleStore = new MockLifecycleStore();
  let now = NOW;
  let writes = 0;

  const error = await assertRejects(
    () =>
      withCommunityWriteLeases({
        lifecycleStore,
        userIDs: ["user-a", "user-b"],
        nowFactory: () => now,
        randomUUID: sequence("expiry"),
        action: async ({ persist }) => {
          now = new Date("2026-07-14T12:11:00.000Z");
          await persist(() => {
            writes += 1;
            return Promise.resolve();
          });
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(writes, 0);
});

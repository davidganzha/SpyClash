import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { withGenerationWriterLease } from "./generation-write-lifecycle.ts";

type RecordValue = Record<string, any>;
const START = new Date("2026-07-14T12:00:00.000Z");

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
      created_date: START.toISOString(),
      updated_date: START.toISOString(),
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
        record.updated_date = START.toISOString();
        updated += 1;
      }
    }
    return { updated };
  }
}

Deno.test("generation side effect is rejected after its writer lease expires", async () => {
  const store = new MockLifecycleStore();
  let now = START;
  let providerCalls = 0;

  const error = await assertRejects(
    () =>
      withGenerationWriterLease({
        lifecycleStore: store,
        userID: "user-1",
        nowFactory: () => now,
        randomUUID: sequence("generation"),
        action: async (guard) => {
          now = new Date(START.getTime() + 11 * 60 * 1_000);
          await guard.boundary(async () => {
            providerCalls += 1;
          });
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(providerCalls, 0);
});

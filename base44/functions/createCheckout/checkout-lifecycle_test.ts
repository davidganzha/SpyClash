import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { withCheckoutBillingLease } from "./checkout-lifecycle.ts";

type RecordValue = Record<string, any>;
const NOW = new Date("2026-07-14T12:00:00.000Z");
const AFTER_EXPIRY = new Date("2026-07-14T12:11:00.000Z");

class MockStore {
  records: RecordValue[] = [];

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
    const record = {
      ...structuredClone(value),
      id: "lifecycle-1",
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
    };
    this.records.push(record);
    return structuredClone(record);
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

Deno.test("suspended checkout cannot create a Stripe session after lease expiry", async () => {
  const store = new MockStore();
  let clockReads = 0;
  let sessionCreates = 0;
  let uuids = 0;
  const error = await assertRejects(
    () =>
      withCheckoutBillingLease({
        lifecycleStore: store,
        userID: "user-1",
        createSession: async () => {
          sessionCreates += 1;
          return { id: "cs_1" };
        },
        nowFactory: () => ++clockReads <= 3 ? NOW : AFTER_EXPIRY,
        randomUUID: () => `uuid-${++uuids}`,
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "active_lease");
  assertEquals(sessionCreates, 0);
});

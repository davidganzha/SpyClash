import { assertEquals, assertRejects } from "jsr:@std/assert@1";
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

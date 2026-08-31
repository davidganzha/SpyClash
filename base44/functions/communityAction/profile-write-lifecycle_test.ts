import { assertEquals } from "jsr:@std/assert@1";
import { withCurrentProfileWriteLease } from "./profile-write-lifecycle.ts";

type Entity = Record<string, unknown>;
const NOW = new Date("2026-07-14T12:00:00.000Z");

class Store {
  records: Entity[] = [];
  private nextID = 0;

  async filter(filter: Entity, _sort: string, limit: number, skip: number) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).slice(skip, skip + limit).map((record) => structuredClone(record));
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

Deno.test("profile initialization and mutation share one lifecycle lease", async () => {
  const store = new Store();
  let profileWrites = 0;
  let actionWrites = 0;
  let installed: Entity | null = null;

  await withCurrentProfileWriteLease({
    lifecycleStore: store,
    userIDs: ["user-a"],
    currentUserID: "user-a",
    loadCurrent: () => Promise.resolve({ id: "user-a" }),
    ensureCurrent: async (current, persist) => {
      await persist(async () => {
        profileWrites += 1;
      });
      return { ...current, spy_id: "123-456" };
    },
    installCurrent: (current) => {
      installed = current;
    },
    action: async ({ persist }) => {
      await persist(async () => {
        actionWrites += 1;
      });
    },
  });

  assertEquals(profileWrites, 1);
  assertEquals(actionWrites, 1);
  assertEquals((installed as Entity | null)?.spy_id, "123-456");
  assertEquals(store.records.length, 1);
});

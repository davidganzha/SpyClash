import { assertEquals } from "jsr:@std/assert@1";
import { withSerializedAdminMutation } from "./admin-publish-lifecycle.ts";
import { publishGlobal } from "./inbox.ts";

type Row = Record<string, any>;

class Store {
  constructor(public records: Row[] = []) {}
  async filter(filter: Row, _sort = "created_date", limit = 100, skip = 0) {
    return this.records.filter((row) =>
      Object.entries(filter).every(([key, value]) => row[key] === value)
    ).slice(skip, skip + limit).map((row) => structuredClone(row));
  }
  async create(row: Row) {
    const saved = {
      id: `row-${crypto.randomUUID()}`,
      created_date: new Date().toISOString(),
      ...structuredClone(row),
    };
    this.records.push(saved);
    await Promise.resolve();
    return structuredClone(saved);
  }
  async updateMany(filter: Row, update: Row) {
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!Object.entries(filter).every(([key, value]) => row[key] === value)) {
        return row;
      }
      updated += 1;
      return { ...row, ...structuredClone(update.$set || {}) };
    });
    await Promise.resolve();
    return { updated };
  }
  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
  }
}

Deno.test("parallel admins converge one published announcement per request id", async () => {
  const lifecycleStore = new Store();
  const announcementStore = new Store();
  const requestID = "123e4567-e89b-42d3-a456-426614174077";
  const publish = (adminUserID: string) =>
    withSerializedAdminMutation({
      lifecycleStore,
      adminUserID,
      operationKey: `request:${requestID}`,
      action: async (persist) =>
        await publishGlobal({
          store: announcementStore,
          body: {
            request_id: requestID,
            title_en: "Build 29",
            body_en: "Ready",
            importance: "important",
          },
          persist,
        }),
    });
  const [left, right] = await Promise.all([
    publish("admin-left"),
    publish("admin-right"),
  ]);
  assertEquals(left.id, right.id);
  assertEquals(left.status, "published");
  assertEquals(
    announcementStore.records.filter((row) =>
      row.dedupe_key === `notification:${requestID}`
    ).length,
    1,
  );
});

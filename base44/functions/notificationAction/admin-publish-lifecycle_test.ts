import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { withSerializedAdminMutation } from "./admin-publish-lifecycle.ts";
import { NotificationContractError } from "./contracts.ts";
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

async function lifecycleSubjectKey(userID: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-billing-lifecycle:${userID}`),
  );
  const hex = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `billing:${hex.slice(0, 40)}`;
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

Deno.test("admin mutation callback is not replayed after it starts", async () => {
  const lifecycleStore = new Store();
  let actionCalls = 0;

  const error = await assertRejects(
    () =>
      withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: "admin-1",
        operationKey: "request:one",
        action: () => {
          actionCalls += 1;
          throw new NotificationContractError(
            "persistence changed",
            409,
            "cas_contention",
          );
        },
      }),
    NotificationContractError,
  );

  assertEquals(error.code, "cas_contention");
  assertEquals(actionCalls, 1);
});

Deno.test("failed operation lease acquisition releases the already-held admin lease", async () => {
  const operationKey = "request:blocked";
  const operationSubjectKey = await lifecycleSubjectKey(
    `notification-admin:${operationKey}`,
  );
  const lifecycleStore = new Store([{
    id: "blocked-operation",
    subject_key: operationSubjectKey,
    state: "deleting",
    lease_token: "deleting:blocked",
    lease_until: "2099-01-01T00:00:00.000Z",
    revision: "blocked-revision",
    created_date: "2026-07-27T00:00:00.000Z",
  }]);
  let actionCalls = 0;

  const error = await assertRejects(
    () =>
      withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: "admin-partial",
        operationKey,
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    NotificationContractError,
  );

  const adminSubjectKey = await lifecycleSubjectKey("admin-partial");
  const adminRow = lifecycleStore.records.find((row) =>
    row.subject_key === adminSubjectKey
  );
  assertEquals(error.code, "deletion_in_progress");
  assertEquals(actionCalls, 0);
  assertEquals(
    String(adminRow?.lease_token || "").startsWith("released:"),
    true,
  );
});

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  blockedCounterpartIDs,
  deleteBlockedPairContent,
} from "./community-moderation.ts";
import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";
import {
  acquireBillingDeletionMarker,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";

type Entity = Record<string, unknown>;
const NOW = new Date("2026-07-14T12:00:00.000Z");

class MockEntityStore {
  constructor(public records: Entity[]) {
    this.records = structuredClone(records);
  }

  async filter(filter: Entity, _sort: string, limit: number, skip: number) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }

  async updateMany(filter: Entity, update: { $set?: Entity }) {
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

class MockLifecycleStore extends MockEntityStore {
  nextID = 1;

  async create(value: Entity) {
    const record = {
      ...structuredClone(value),
      id: `lifecycle-${this.nextID++}`,
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
    };
    this.records.push(record);
    return structuredClone(record);
  }

  override async updateMany(filter: Entity, update: { $set?: Entity }) {
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

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
}

Deno.test("blocking deletes comments and room invites in both directions only", async () => {
  const comments = new MockEntityStore([
    { id: "comment-forward", author_user_id: "a", target_user_id: "b" },
    { id: "comment-reverse", author_user_id: "b", target_user_id: "a" },
    { id: "comment-safe", author_user_id: "a", target_user_id: "c" },
  ]);
  const invites = new MockEntityStore([
    { id: "invite-forward", sender_user_id: "a", recipient_user_id: "b" },
    { id: "invite-reverse", sender_user_id: "b", recipient_user_id: "a" },
    { id: "invite-safe", sender_user_id: "c", recipient_user_id: "a" },
  ]);
  const pushEvents = new MockEntityStore([
    {
      id: "event-forward",
      actor_user_id: "a",
      recipient_user_id: "b",
      event_type: "friend_request",
      state: "delivered",
      lease_token: "",
      revision: "r1",
    },
    {
      id: "event-reverse",
      actor_user_id: "b",
      recipient_user_id: "a",
      event_type: "room_invite",
      state: "pending",
      lease_token: "",
      revision: "r2",
    },
    {
      id: "event-safe",
      actor_user_id: "c",
      recipient_user_id: "a",
      event_type: "room_invite",
      state: "delivered",
      lease_token: "",
      revision: "r3",
    },
  ]);
  let guardedDeletes = 0;

  const deleted = await deleteBlockedPairContent({
    profileCommentStore: comments,
    roomInviteStore: invites,
    pushEventStore: pushEvents,
    firstUserID: "a",
    secondUserID: "b",
    persist: async (writer) => {
      guardedDeletes += 1;
      return await writer();
    },
  });

  assertEquals(deleted, {
    profileComments: 2,
    roomInvites: 2,
    pushEvents: 2,
  });
  assertEquals(guardedDeletes, 6);
  assertEquals(comments.records.map((record) => record.id), ["comment-safe"]);
  assertEquals(invites.records.map((record) => record.id), ["invite-safe"]);
  assertEquals(pushEvents.records.map((record) => record.state), [
    "cancelled",
    "cancelled",
    "delivered",
  ]);
});

Deno.test("blocked counterpart set is bidirectional", () => {
  const relationships = [
    { requester_id: "a", addressee_id: "b", status: "blocked" },
    { requester_id: "c", addressee_id: "a", status: "blocked" },
    { requester_id: "a", addressee_id: "d", status: "accepted" },
  ];
  assertEquals([...blockedCounterpartIDs(relationships, "a")].sort(), [
    "b",
    "c",
  ]);
});

Deno.test("every social mutation class refuses a deletion-marked participant before writing", async () => {
  const mutationClasses = [
    "friendship_create",
    "friendship_update",
    "friendship_delete",
    "comment_create",
    "comment_delete",
    "invite_create",
    "invite_update",
    "invite_delete",
    "report_create",
    "block",
    "unblock",
  ];

  for (const mutationClass of mutationClasses) {
    const store = new MockLifecycleStore([]);
    await acquireBillingDeletionMarker(
      store,
      "user-deleting",
      () => NOW,
      sequence(`delete-${mutationClass}`),
    );
    let writes = 0;
    const error = await assertRejects(
      () =>
        withCommunityWriteLeases({
          lifecycleStore: store,
          userIDs: ["user-deleting"],
          action: async ({ persist }) => {
            await persist(async () => {
              writes += 1;
            });
          },
          nowFactory: () => NOW,
          randomUUID: sequence(`social-${mutationClass}`),
        }),
      BillingIdentityLifecycleError,
    );
    assertEquals(error.code, "deletion_in_progress", mutationClass);
    assertEquals(writes, 0, mutationClass);
  }
});

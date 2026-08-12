import { assertEquals } from "jsr:@std/assert@1";
import {
  cancelCommunityPushEvent,
  commitCommunityPushEvent,
  enqueueCommunityPushEvent,
  reusablePendingInviteEventID,
} from "./push-events.ts";

class Store {
  records: Record<string, any>[] = [];
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }
  async create(record: Record<string, any>) {
    const saved = { id: `row-${this.records.length + 1}`, ...record };
    this.records.push(saved);
    return saved;
  }
  async updateMany(
    filter: Record<string, any>,
    update: Record<string, any>,
  ) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        return record;
      }
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    return { updated };
  }
}

Deno.test("source failure stays hidden and lost-response retry commits idempotently", async () => {
  const store = new Store();
  const input = {
    store,
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    eventType: "friend_request" as const,
    sourceEventID: "source-1",
    actorUserID: "actor",
    actorDisplayName: "Red Raven",
    recipientUserID: "recipient",
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => "revision-1",
  };
  const first = await enqueueCommunityPushEvent(input);
  const second = await enqueueCommunityPushEvent(input);
  assertEquals(first.id, second.id);
  assertEquals(store.records.length, 1);
  assertEquals("actor_name" in store.records[0], false);
  assertEquals(store.records[0].inbox_body_en, "Red Raven wants to connect.");
  assertEquals(
    store.records[0].inbox_body_uk,
    "Red Raven хоче додати вас у друзі.",
  );
  assertEquals(store.records[0].inbox_projection_version, 1);
  assertEquals(store.records[0].inbox_visible, false);

  assertEquals(
    await commitCommunityPushEvent({
      store,
      persist: async <T>(writer: () => Promise<T>) => await writer(),
      eventType: "friend_request",
      sourceEventID: "source-1",
      actorDisplayName: "Red Raven",
      now: new Date("2026-07-15T12:00:01.000Z"),
      randomUUID: () => "revision-committed",
    }),
    true,
  );
  assertEquals(store.records[0].inbox_visible, true);
  assertEquals(store.records[0].inbox_body_en, "Red Raven wants to connect.");

  assertEquals(
    await cancelCommunityPushEvent({
      store,
      persist: async <T>(writer: () => Promise<T>) => await writer(),
      eventType: "friend_request",
      sourceEventID: "source-1",
      reason: "friend_request_cancelled",
      now: new Date("2026-07-15T12:01:00.000Z"),
      randomUUID: () => "revision-2",
    }),
    1,
  );
  assertEquals(store.records[0].state, "cancelled");
  assertEquals(store.records[0].inbox_visible, false);
});

Deno.test("a pending room invite reuses its event instead of spamming APNs", () => {
  assertEquals(
    reusablePendingInviteEventID({
      status: "pending",
      notification_event_id: "existing-event",
    }),
    "existing-event",
  );
  assertEquals(
    reusablePendingInviteEventID({
      status: "declined",
      notification_event_id: "old-event",
    }),
    "",
  );
});

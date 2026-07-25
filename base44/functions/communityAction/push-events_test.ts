import { assertEquals } from "jsr:@std/assert@1";
import {
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
}

Deno.test("community push enqueue is idempotent and stores no profile snapshot", async () => {
  const store = new Store();
  const input = {
    store,
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    eventType: "friend_request" as const,
    sourceEventID: "source-1",
    actorUserID: "actor",
    recipientUserID: "recipient",
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => "revision-1",
  };
  const first = await enqueueCommunityPushEvent(input);
  const second = await enqueueCommunityPushEvent(input);
  assertEquals(first.id, second.id);
  assertEquals(store.records.length, 1);
  assertEquals("actor_name" in store.records[0], false);
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

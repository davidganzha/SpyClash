import { assertEquals } from "jsr:@std/assert@1";
import {
  claimLiveDelivery,
  completeLiveDelivery,
  liveDeliveryDue,
  queueLiveRetry,
} from "./live-delivery.ts";

class Store {
  constructor(public records: Record<string, any>[]) {}
  async filter(filter: Record<string, any>) {
    return this.records.filter((row) =>
      Object.entries(filter).every(([key, value]) => row[key] === value)
    ).map((row) => structuredClone(row));
  }
  async updateMany(filter: Record<string, any>, update: Record<string, any>) {
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

function registration() {
  return {
    id: "live-1",
    token_hash: "token",
    status: "active",
    delivery_state: "idle",
    delivery_revision: "r1",
    delivery_lease_until: "2026-07-15T11:00:00.000Z",
    delivery_attempt_count: 0,
    pending_room_revision: 0,
  };
}

Deno.test("Live Activity delivery claim is exact CAS", async () => {
  const store = new Store([registration()]);
  const claimed = await claimLiveDelivery({
    store,
    registration: structuredClone(store.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => "claim",
  });
  assertEquals(claimed?.delivery_revision, "claim");
  assertEquals(
    await claimLiveDelivery({
      store,
      registration: registration(),
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
    }),
    null,
  );
});

Deno.test("a newer room state queued during send survives completion", async () => {
  const store = new Store([registration()]);
  const claimed = await claimLiveDelivery({
    store,
    registration: store.records[0],
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => "claim",
  });
  assertEquals(
    await queueLiveRetry({
      store,
      registrationID: "live-1",
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 200,
      now: new Date("2026-07-15T12:00:01.000Z"),
    }),
    true,
  );
  assertEquals(
    await completeLiveDelivery({
      store,
      claimed: claimed!,
      state: "idle",
      randomUUID: () => "complete",
    }),
    true,
  );
  assertEquals(store.records[0].retry_requested, true);
  assertEquals(store.records[0].delivery_state, "retry");
  assertEquals(store.records[0].pending_room_revision, 200);
  assertEquals(liveDeliveryDue(store.records[0]), true);
});

Deno.test("forced remote end remains durable across a retry claim", async () => {
  const store = new Store([registration()]);
  assertEquals(
    await queueLiveRetry({
      store,
      registrationID: "live-1",
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
      forceEnd: true,
      now: new Date("2026-07-15T12:00:00.000Z"),
    }),
    true,
  );
  assertEquals(store.records[0].pending_force_end, true);
  const claimed = await claimLiveDelivery({
    store,
    registration: structuredClone(store.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:01.000Z"),
    randomUUID: () => "forced-end-claim",
  });
  assertEquals(claimed?.pending_force_end, true);
  assertEquals(
    await completeLiveDelivery({
      store,
      claimed: claimed!,
      state: "retry",
      nextAttemptAt: "2026-07-15T12:01:00.000Z",
      randomUUID: () => "retry",
    }),
    true,
  );
  assertEquals(store.records[0].pending_force_end, true);
  assertEquals(store.records[0].delivery_state, "retry");
});

import { assertEquals } from "jsr:@std/assert@1";
import {
  claimLiveDelivery,
  completeLiveDelivery,
  forcedLiveEndFailurePatch,
  liveDeliveryDue,
  MAX_LIVE_DELIVERY_ATTEMPTS,
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
      state: "retry",
      nextAttemptAt: "2026-07-15T12:00:02.000Z",
      patch: {
        last_revision: 100,
        last_apns_timestamp: 1_752_580_800,
        provider_match_id: "match-1",
        started_match_ids: ["match-1"],
        last_started_match_id: "match-1",
        status: "ended",
        ended_at: "2026-07-15T12:00:02.000Z",
        pending_force_end: false,
      },
      randomUUID: () => "complete",
    }),
    true,
  );
  assertEquals(store.records[0].retry_requested, true);
  assertEquals(store.records[0].delivery_state, "retry");
  assertEquals(store.records[0].pending_room_revision, 200);
  assertEquals(store.records[0].last_revision, 100);
  assertEquals(store.records[0].last_apns_timestamp, 1_752_580_800);
  assertEquals(store.records[0].provider_match_id, "match-1");
  assertEquals(store.records[0].started_match_ids, ["match-1"]);
  assertEquals(store.records[0].last_started_match_id, "match-1");
  assertEquals(store.records[0].status, "active");
  assertEquals(store.records[0].ended_at, undefined);
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

Deno.test("first forced end gets a fresh budget but duplicate enqueue preserves it", async () => {
  const store = new Store([{
    ...registration(),
    delivery_state: "retry",
    delivery_attempt_count: MAX_LIVE_DELIVERY_ATTEMPTS - 1,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 90,
  }]);

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
  assertEquals(store.records[0].delivery_attempt_count, 0);

  const claimed = await claimLiveDelivery({
    store,
    registration: structuredClone(store.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:01.000Z"),
    randomUUID: () => "forced-attempt-1",
  });
  assertEquals(claimed?.delivery_attempt_count, 1);
  await completeLiveDelivery({
    store,
    claimed: claimed!,
    state: "retry",
    nextAttemptAt: "2026-07-15T12:01:00.000Z",
    now: new Date("2026-07-15T12:00:02.000Z"),
    randomUUID: () => "forced-retry",
  });

  assertEquals(
    await queueLiveRetry({
      store,
      registrationID: "live-1",
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
      forceEnd: true,
      now: new Date("2026-07-15T12:00:03.000Z"),
    }),
    true,
  );
  assertEquals(
    store.records[0].delivery_attempt_count,
    1,
    "duplicate forced-end enqueue must not create an infinite retry budget",
  );
});

Deno.test("committed finish upgrades a prepared end and cannot be downgraded", async () => {
  const store = new Store([registration()]);
  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
  });
  const preparedRevision = store.records[0].delivery_revision;
  assertEquals(store.records[0].pending_force_end_commit_id, undefined);

  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    terminalCommitID: "game-finished:match-1",
  });
  assertEquals(
    store.records[0].pending_force_end_commit_id,
    "game-finished:match-1",
  );
  assertEquals(store.records[0].delivery_revision === preparedRevision, false);

  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
  });
  assertEquals(
    store.records[0].pending_force_end_commit_id,
    "game-finished:match-1",
  );
});

Deno.test("a new match never inherits an older terminal receipt", async () => {
  const store = new Store([{
    ...registration(),
    pending_force_end: true,
    pending_force_end_commit_id: "game-finished:match-old",
    pending_room_id: "room-1",
    pending_match_id: "match-old",
    pending_room_revision: 100,
  }]);
  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-new",
    roomRevision: 1,
    forceEnd: true,
  });
  assertEquals(store.records[0].pending_match_id, "match-new");
  assertEquals(store.records[0].pending_force_end_commit_id, null);
});

Deno.test("forced end retry backoff is not due until its scheduled time", () => {
  const retry = {
    ...registration(),
    pending_force_end: true,
    retry_requested: false,
    delivery_state: "retry",
    next_attempt_at: "2026-07-15T12:01:00.000Z",
  };
  assertEquals(
    liveDeliveryDue(retry, new Date("2026-07-15T12:00:59.999Z")),
    false,
  );
  assertEquals(
    liveDeliveryDue(retry, new Date("2026-07-15T12:01:00.000Z")),
    true,
  );
});

Deno.test("terminal forced-end failure clears the durable unregister blocker", async () => {
  const store = new Store([registration()]);
  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:00.000Z"),
  });
  const claimed = await claimLiveDelivery({
    store,
    registration: structuredClone(store.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:01.000Z"),
    randomUUID: () => "terminal-claim",
  });
  assertEquals(
    await completeLiveDelivery({
      store,
      claimed: claimed!,
      state: "failed",
      errorCode: "nonretryable",
      patch: forcedLiveEndFailurePatch(
        false,
        new Date("2026-07-15T12:00:02.000Z"),
      ),
      now: new Date("2026-07-15T12:00:02.000Z"),
      randomUUID: () => "terminal-failure",
    }),
    true,
  );
  assertEquals(store.records[0].delivery_state, "failed");
  assertEquals(store.records[0].status, "ended");
  assertEquals(store.records[0].ended_at, "2026-07-15T12:00:02.000Z");
  assertEquals(store.records[0].pending_force_end, false);
  assertEquals(store.records[0].pending_force_end_commit_id, null);
  assertEquals(store.records[0].pending_room_id, null);
  assertEquals(store.records[0].pending_match_id, null);
  assertEquals(store.records[0].pending_room_revision, 0);
});

Deno.test("newer forced-end queue survives an older terminal failure", async () => {
  const store = new Store([{
    ...registration(),
    delivery_state: "retry",
    delivery_attempt_count: MAX_LIVE_DELIVERY_ATTEMPTS - 1,
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 100,
  }]);
  await queueLiveRetry({
    store,
    registrationID: "live-1",
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:00.000Z"),
  });
  const claimed = await claimLiveDelivery({
    store,
    registration: structuredClone(store.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-07-15T12:00:01.000Z"),
    randomUUID: () => "terminal-claim",
  });
  assertEquals(claimed?.delivery_attempt_count, MAX_LIVE_DELIVERY_ATTEMPTS);

  // A duplicate close reaches the enqueue-only action while APNs is in flight.
  assertEquals(
    await queueLiveRetry({
      store,
      registrationID: "live-1",
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
      forceEnd: true,
      now: new Date("2026-07-15T12:00:02.000Z"),
    }),
    true,
  );
  assertEquals(
    await completeLiveDelivery({
      store,
      claimed: claimed!,
      state: "failed",
      errorCode: "nonretryable",
      patch: forcedLiveEndFailurePatch(
        false,
        new Date("2026-07-15T12:00:03.000Z"),
      ),
      now: new Date("2026-07-15T12:00:03.000Z"),
      randomUUID: () => "retry-after-race",
    }),
    true,
  );

  assertEquals(store.records[0].status, "active");
  assertEquals(store.records[0].delivery_state, "retry");
  assertEquals(store.records[0].delivery_revision, "retry-after-race");
  assertEquals(store.records[0].retry_requested, true);
  assertEquals(store.records[0].pending_force_end, true);
  assertEquals(store.records[0].pending_room_id, "room-1");
  assertEquals(store.records[0].pending_match_id, "match-1");
  assertEquals(store.records[0].ended_at, undefined);
});

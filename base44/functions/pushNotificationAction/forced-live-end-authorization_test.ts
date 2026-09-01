import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { authorizeForcedLiveActivityEnd } from "./forced-live-end-authorization.ts";

class Store {
  constructor(public records: Record<string, any>[]) {}

  async filter(
    filter: Record<string, any>,
    _sort = "created_date",
    limit = 100,
    skip = 0,
  ) {
    return this.records.filter((row) =>
      Object.entries(filter).every(([key, value]) => row[key] === value)
    ).slice(skip, skip + limit).map((row) => structuredClone(row));
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

function pendingRegistration() {
  return {
    id: "live-1",
    user_id: "user-1",
    token_hash: "token-1",
    status: "active",
    token_kind: "activity",
    delivery_state: "retry",
    delivery_revision: "delivery-1",
    delivery_lease_until: "2026-09-01T12:00:00.000Z",
    delivery_attempt_count: 4,
    retry_requested: true,
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 21,
  };
}

Deno.test("newer active room alone cannot clear a prepared forced end", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  const outcome = await authorizeForcedLiveActivityEnd({
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "playing",
      updated_date: "2026-09-01T12:00:00.000Z",
    }]),
    signalStore: new Store([]),
    liveStore,
    registration,
    roomID: "room-1",
    matchID: "match-1",
    now: new Date("2026-09-01T12:00:01.000Z"),
  });

  assertEquals(outcome, "deferred");
  assertEquals(liveStore.records[0], registration);
});

Deno.test("ambiguous stale active room and empty signal read preserve the prepared end", async () => {
  const registration = {
    ...pendingRegistration(),
    pending_room_revision: Date.parse("2026-09-01T12:00:00.000Z"),
  };
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        updated_date: "2026-09-01T12:00:00.000Z",
      }]),
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "deferred",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("durable close intent authorizes terminal delivery before deletion", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        close_intent: {
          id: "close-1",
          room_id: "room-1",
          match_id: "match-1",
        },
      }]),
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "committed",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("unproved room absence defers instead of ending an active session", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([]),
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "deferred",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("closed signal receipt authorizes delivery after physical deletion", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([]),
      signalStore: new Store([{
        id: "signal-1",
        room_id: "room-1",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "match-1",
      }]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "committed",
  );
});

Deno.test("closed receipt dominates a stale pre-intent active room replica", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
      }]),
      signalStore: new Store([{
        id: "signal-1",
        room_id: "room-1",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "match-1",
      }]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "committed",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("committed finish receipt dominates a stale active room replica", async () => {
  const registration = {
    ...pendingRegistration(),
    pending_force_end_commit_id: "game-finished:match-1",
  };
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
      }]),
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "committed",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("committed close receipt dominates stale room and signal replicas", async () => {
  const registration = {
    ...pendingRegistration(),
    pending_force_end_commit_id: "room-close:match-1:close-1",
  };
  const liveStore = new Store([registration]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
      }]),
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    }),
    "committed",
  );
  assertEquals(liveStore.records[0], registration);
});

Deno.test("stale authorization leaves a concurrent finish upgrade untouched", async () => {
  const stale = pendingRegistration();
  const upgraded = {
    ...stale,
    delivery_revision: "finish-upgrade",
    pending_force_end_commit_id: "game-finished:match-1",
  };
  const liveStore = new Store([upgraded]);
  assertEquals(
    await authorizeForcedLiveActivityEnd({
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
      }]),
      signalStore: new Store([]),
      liveStore,
      registration: stale,
      roomID: "room-1",
      matchID: "match-1",
      randomUUID: () => "stale-clear",
    }),
    "deferred",
  );
  assertEquals(liveStore.records[0], upgraded);
});

Deno.test("authorization read failure leaves the durable end untouched", async () => {
  const registration = pendingRegistration();
  const liveStore = new Store([registration]);
  await assertRejects(() =>
    authorizeForcedLiveActivityEnd({
      roomStore: {
        filter: () => Promise.reject(new Error("unavailable")),
      },
      signalStore: new Store([]),
      liveStore,
      registration,
      roomID: "room-1",
      matchID: "match-1",
    })
  );
  assertEquals(liveStore.records[0], registration);
});

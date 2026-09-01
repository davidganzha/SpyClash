import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  committedRoomPushEvents,
  repairCommittedRoomPushEvents,
  runCommittedRoomPushRepairIfFresh,
} from "./room-reconciliation.ts";

class Store {
  records: Record<string, any>[] = [];
  throwAfterNextUpdate = false;
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }
  async create(record: Record<string, any>) {
    this.records.push({ id: `event-${this.records.length + 1}`, ...record });
  }
  async updateMany(
    filter: Record<string, any>,
    update: Record<string, any>,
  ) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) return record;
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    if (this.throwAfterNextUpdate && updated > 0) {
      this.throwAfterNextUpdate = false;
      throw new Error("lost update response");
    }
    return { updated };
  }
}

function unfinishedEvent(recipientUserID: string, overrides = {}) {
  return {
    id: `event-${recipientUserID}`,
    dedupe_key: `game_finished:finish-1:${recipientUserID}`,
    source_event_id: "finish-1",
    event_type: "game_finished",
    source_type: "game_room",
    recipient_user_id: recipientUserID,
    room_id: "room-1",
    match_id: "match-1",
    inbox_visible: false,
    inbox_committed_at: null,
    state: "pending",
    lease_token: "",
    revision: `revision-${recipientUserID}`,
    ...overrides,
  };
}

Deno.test("persisted game start identity repairs a missing outbox idempotently", async () => {
  const store = new Store();
  let persistenceBoundaries = 0;
  const room = {
    id: "room-1",
    status: "playing",
    match_id: "match-1",
    game_started_event_id: "start-1",
    participant_user_ids: ["user-b", "user-a", "user-a"],
    players: [{ user_id: "user-c" }],
    intro_started_at: "2026-07-26T12:00:00.000Z",
    game_duration_seconds: 900,
  };
  const input = {
    eventStore: store,
    room,
    persist: async <T>(writer: () => Promise<T>) => {
      persistenceBoundaries += 1;
      return await writer();
    },
    now: new Date("2026-07-26T12:00:01.000Z"),
    randomUUID: () => "revision",
  };
  assertEquals(await repairCommittedRoomPushEvents(input), 3);
  assertEquals(await repairCommittedRoomPushEvents(input), 0);
  assertEquals(persistenceBoundaries, 1);
  assertEquals(store.records.map((row) => row.recipient_user_id), [
    "user-a",
    "user-b",
    "user-c",
  ]);
  assertEquals(store.records.every((row) => row.state === "pending"), true);
  assertEquals(
    store.records.every((row) =>
      row.inbox_projection_version === 1 &&
      row.inbox_title_en === "Mission started" &&
      row.inbox_title_uk === "Гра почалася" &&
      row.inbox_action_deep_link === "spyclash://game?room_id=room-1" &&
      row.inbox_visible === false && Boolean(row.inbox_committed_at)
    ),
    true,
  );
});

Deno.test("finished rooms repair only the terminal event", async () => {
  assertEquals(
    committedRoomPushEvents({
      status: "finished",
      match_id: "match-1",
      game_started_event_id: "start-1",
      game_finished_event_id: "finish-1",
    }),
    [{
      eventType: "game_finished",
      sourceEventID: "finish-1",
      matchID: "match-1",
    }],
  );
});

Deno.test("finished-room repair revives a committed event cancelled from a stale read", async () => {
  const store = new Store();
  store.records = [unfinishedEvent("user-a", {
    inbox_committed_at: "2026-07-26T11:59:59.000Z",
    state: "cancelled",
    last_error_code: "game_finish_stale",
  })];
  const repaired = await repairCommittedRoomPushEvents({
    eventStore: store,
    room: {
      id: "room-1",
      status: "finished",
      match_id: "match-1",
      game_finished_event_id: "finish-1",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T11:59:59.000Z",
    },
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-26T12:00:00.000Z"),
    randomUUID: () => "recovered-revision",
  });
  assertEquals(repaired, 1);
  assertEquals(store.records[0].state, "retry");
  assertEquals(store.records[0].revision, "recovered-revision");
  assertEquals(store.records[0].last_error_code, "committed_finish_recovered");
});

Deno.test("finished-room repair commits and revives an exhausted pre-commit event", async () => {
  const store = new Store();
  store.records = [unfinishedEvent("user-a", {
    inbox_committed_at: null,
    state: "cancelled",
    attempt_count: 8,
    last_error_code: "game_finish_stale",
  })];
  const repaired = await repairCommittedRoomPushEvents({
    eventStore: store,
    room: {
      id: "room-1",
      status: "finished",
      match_id: "match-1",
      game_finished_event_id: "finish-1",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T11:59:59.000Z",
    },
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-26T12:00:00.000Z"),
    randomUUID: () => "recovered-uncommitted-revision",
  });
  assertEquals(repaired, 1);
  assertEquals(store.records[0].state, "retry");
  assertEquals(store.records[0].attempt_count, 0);
  assertEquals(Boolean(store.records[0].inbox_committed_at), true);
  assertEquals(
    store.records[0].last_error_code,
    "committed_finish_recovered",
  );
});

Deno.test("partial lost batched commit is fully recoverable from the finished room", async () => {
  const store = new Store();
  store.records = [
    unfinishedEvent("user-a"),
    unfinishedEvent("user-b"),
    unfinishedEvent("user-c"),
  ];
  const input = {
    eventStore: store,
    room: {
      id: "room-1",
      status: "finished",
      match_id: "match-1",
      game_finished_event_id: "finish-1",
      participant_user_ids: ["user-a", "user-b", "user-c"],
      updated_date: "2026-07-26T11:59:30.000Z",
    },
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-26T12:00:00.000Z"),
    randomUUID: () => crypto.randomUUID(),
  };
  store.throwAfterNextUpdate = true;
  await assertRejects(
    () => repairCommittedRoomPushEvents(input),
    Error,
    "lost update response",
  );
  assertEquals(
    store.records.filter((row) => Boolean(row.inbox_committed_at)).length,
    1,
  );

  assertEquals(await repairCommittedRoomPushEvents(input), 2);
  assertEquals(
    store.records.every((row) => Boolean(row.inbox_committed_at)),
    true,
  );
  assertEquals(
    store.records.map((row) => row.recipient_user_id),
    ["user-a", "user-b", "user-c"],
  );
});

Deno.test("inbox repair does not invalidate an active delivery worker CAS", async () => {
  const store = new Store();
  store.records = [unfinishedEvent("user-a", {
    state: "processing",
    lease_token: "push-worker",
    lease_until: "2026-07-26T12:02:00.000Z",
    revision: "worker-revision",
  })];
  const repaired = await repairCommittedRoomPushEvents({
    eventStore: store,
    room: {
      id: "room-1",
      status: "finished",
      match_id: "match-1",
      game_finished_event_id: "finish-1",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T11:59:30.000Z",
    },
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-26T12:00:00.000Z"),
    randomUUID: () => "must-not-replace-worker-revision",
  });
  assertEquals(repaired, 1);
  assertEquals(store.records[0].revision, "worker-revision");
  const completion = await store.updateMany({
    id: "event-user-a",
    state: "processing",
    lease_token: "push-worker",
    revision: "worker-revision",
  }, {
    $set: {
      state: "delivered",
      lease_token: "",
      revision: "delivered-revision",
    },
  });
  assertEquals(completion.updated, 1);
  assertEquals(Boolean(store.records[0].inbox_committed_at), true);
});

Deno.test("process_event reconciles partial room outboxes before delivery", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const processEvents = source.slice(
    source.indexOf("async function processEvents"),
    source.indexOf("async function drain(base44"),
  );
  const existingLookup = processEvents.indexOf("const existingRoomEvent");
  const repair = processEvents.indexOf(
    "await repairRoomPushOutbox(base44, room)",
  );
  const delivery = processEvents.indexOf("await syncLiveActivities(base44");
  assertEquals(existingLookup >= 0, true);
  assertEquals(repair > existingLookup, true);
  assertEquals(delivery > repair, true);
});

Deno.test("scheduled drain reconciles terminal outboxes before community profile work", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const drain = source.slice(
    source.indexOf("async function drain(base44"),
    source.indexOf("\nDeno.serve"),
  );
  const outboxRepair = drain.indexOf("await reconcileRecentRoomOutboxes(");
  const profileRepair = drain.indexOf(
    "await drainDurableCommunityProfileRepairs(",
  );
  assertEquals(outboxRepair >= 0, true);
  assertEquals(profileRepair > outboxRepair, true);

  const profileDrain = source.slice(
    source.indexOf("async function drainDurableCommunityProfileRepairs"),
    source.indexOf("async function roomForSourceEvent"),
  );
  assertEquals(profileDrain.includes("await runWithinDeadline({"), true);
  assertEquals(profileDrain.includes('reason: "deadline_exceeded"'), true);

  const scheduledReconciliation = source.slice(
    source.indexOf("async function reconcileRecentRoomOutboxes"),
    source.indexOf("function internalRequest"),
  );
  assertEquals(
    scheduledReconciliation.includes(
      "await repairFinishedRoomCommunityProfiles(base44, room)",
    ),
    false,
  );
  assertEquals(
    scheduledReconciliation.includes(
      "ensureRoomReconciliationCheckpoint({",
    ),
    true,
  );
  assertEquals(
    scheduledReconciliation.includes("loadRoomReconciliationPage({"),
    true,
  );
  assertEquals(
    scheduledReconciliation.includes(
      "advanceRoomReconciliationCheckpoint({",
    ),
    true,
  );
});

Deno.test("old terminal identities are not resurrected as fresh alerts", async () => {
  const store = new Store();
  assertEquals(
    await repairCommittedRoomPushEvents({
      eventStore: store,
      room: {
        id: "room-old",
        status: "finished",
        match_id: "match-old",
        game_finished_event_id: "finish-old",
        participant_user_ids: ["user-a"],
        updated_date: "2026-07-26T09:00:00.000Z",
      },
      persist: async <T>(writer: () => Promise<T>) => await writer(),
      now: new Date("2026-07-26T12:00:00.000Z"),
    }),
    0,
  );
  assertEquals(store.records, []);
});

Deno.test("old terminal room skips the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old",
      status: "finished",
      match_id: "match-old",
      game_finished_event_id: "finish-old",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T09:00:00.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("expired game start skips the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old",
      status: "playing",
      match_id: "match-old",
      game_started_event_id: "start-old",
      participant_user_ids: ["user-a"],
      game_started_at: "2026-07-26T09:00:00.000Z",
      game_duration_seconds: 900,
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("old game start without a duration also skips repair", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old-legacy",
      status: "playing",
      match_id: "match-old-legacy",
      game_started_event_id: "start-old-legacy",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T09:00:00.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("fresh room reaches the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-current",
      status: "finished",
      match_id: "match-current",
      game_finished_event_id: "finish-current",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T11:59:30.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 2;
    },
  });
  assertEquals(repaired, 2);
  assertEquals(repairCalls, 1);
});

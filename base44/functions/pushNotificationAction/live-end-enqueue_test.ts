import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import { PushContractError } from "./contracts.ts";
import {
  closeCompletionAuthorizesLiveEndQueue,
  enqueueRoomLiveActivityEnd,
} from "./live-end-enqueue.ts";

class Store {
  deliveryPathEntered = false;
  updateCount = 0;

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

  async updateMany(
    filter: Record<string, any>,
    update: Record<string, any>,
  ) {
    const patch = update.$set || {};
    if (
      patch.delivery_state === "processing" || patch.status === "ended" ||
      Object.hasOwn(patch, "ended_at")
    ) {
      this.deliveryPathEntered = true;
    }
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!Object.entries(filter).every(([key, value]) => row[key] === value)) {
        return row;
      }
      updated += 1;
      this.updateCount += 1;
      return { ...row, ...patch };
    });
    return { updated };
  }
}

function registration(overrides: Record<string, any> = {}) {
  return {
    id: "live-1",
    user_id: "current-player",
    token_hash: "token-1",
    status: "active",
    token_kind: "activity",
    room_id: "room-1",
    match_id: "match-1",
    provider_match_id: "match-1",
    delivery_state: "idle",
    delivery_revision: "delivery-1",
    delivery_lease_until: "2026-09-01T12:30:00.000Z",
    delivery_attempt_count: 3,
    pending_room_revision: 0,
    ...overrides,
  };
}

function closeCompletion() {
  return {
    intent_id: "close-1",
    room_id: "room-1",
    match_id: "match-1",
    host_user_id: "host-user",
    participant_user_ids: ["host-user", "guest-user"],
    participant_count: 2,
    completed_at: "2026-09-01T12:00:00.000Z",
  };
}

function closeSignals() {
  const completion = closeCompletion();
  return completion.participant_user_ids.map((userID) => ({
    id: `signal-${userID}`,
    user_id: userID,
    room_id: completion.room_id,
    room_revision: 8,
    room_updated_at: "2026-09-01T12:00:00.000Z",
    state: "closed",
    close_intent_id: completion.intent_id,
    close_match_id: completion.match_id,
    close_completion: completion,
  }));
}

Deno.test("enqueue-only room end owns leases for current and departed users without delivery", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    updated_date: "2026-09-01T12:00:00.000Z",
    participant_user_ids: ["current-player"],
  }]);
  const liveStore = new Store([
    registration(),
    registration({
      id: "live-processing",
      token_hash: "token-2",
      delivery_state: "processing",
      delivery_revision: "delivery-2",
    }),
    registration({
      id: "live-departed",
      user_id: "departed-player",
      token_hash: "token-3",
      delivery_revision: "delivery-3",
    }),
    registration({ id: "wrong-match", match_id: "match-old" }),
    registration({ id: "wrong-provider", provider_match_id: "match-old" }),
    registration({ id: "ended", status: "ended" }),
    registration({ id: "alert", token_kind: "alert" }),
  ]);
  const leasedUserIDs: string[] = [];

  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    leaseRunner: async ({ userIDs, action }) => {
      leasedUserIDs.push(...userIDs.map(String));
      return await action(async (writer) => await writer());
    },
    now: new Date("2026-09-01T12:00:01.000Z"),
  });

  assertEquals(result.registrations.map((row) => row.id), [
    "live-1",
    "live-processing",
    "live-departed",
  ]);
  assertEquals(result.queued, 3);
  assertEquals(result.skipped, 0);
  assertEquals(result.alreadyQueued, false);
  assertEquals(result.receipt, "queued");
  assertEquals(liveStore.updateCount, 3);
  assertEquals(liveStore.deliveryPathEntered, false);
  assertEquals(leasedUserIDs, ["current-player", "departed-player"]);

  const idle = liveStore.records.find((row) => row.id === "live-1")!;
  assertEquals(idle.status, "active");
  assertEquals(idle.delivery_state, "retry");
  assertEquals(idle.delivery_attempt_count, 0);
  assertEquals(idle.pending_force_end, true);
  assertEquals(idle.pending_room_id, "room-1");
  assertEquals(idle.pending_match_id, "match-1");
  assertEquals(idle.pending_room_revision, 1_788_264_000_000);
  assertEquals(Object.hasOwn(idle, "ended_at"), false);

  const processing = liveStore.records.find((row) =>
    row.id === "live-processing"
  )!;
  assertEquals(processing.delivery_state, "processing");
  assertEquals(processing.retry_requested, true);
  assertEquals(processing.pending_force_end, true);
  assertEquals(processing.delivery_attempt_count, 0);

  const departed = liveStore.records.find((row) => row.id === "live-departed")!;
  assertEquals(departed.delivery_state, "retry");
  assertEquals(departed.pending_force_end, true);

  for (const id of ["wrong-match", "wrong-provider", "ended", "alert"]) {
    const untouched = liveStore.records.find((row) => row.id === id)!;
    assertEquals(untouched.pending_force_end, undefined);
  }

  // Model a caller timing out after the nested function committed. Its retry
  // receives a durable receipt without reacquiring leases or rewriting rows.
  const updateCountAfterFirstCall = liveStore.updateCount;
  const leasesAfterFirstCall = [...leasedUserIDs];
  const retry = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    leaseRunner: async ({ userIDs, action }) => {
      leasedUserIDs.push(...userIDs.map(String));
      return await action(async (writer) => await writer());
    },
    now: new Date("2026-09-01T12:00:02.000Z"),
  });
  assertEquals(retry.alreadyQueued, true);
  assertEquals(retry.receipt, "already_queued");
  assertEquals(retry.queued, 0);
  assertEquals(liveStore.updateCount, updateCountAfterFirstCall);
  assertEquals(leasedUserIDs, leasesAfterFirstCall);
});

Deno.test("enqueue-only room end returns immediately when no exact activity exists", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    updated_date: "2026-09-01T12:00:00.000Z",
  }]);
  const liveStore = new Store([
    registration({ id: "wrong-match", match_id: "match-old" }),
  ]);
  let leaseCount = 0;

  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    leaseRunner: async ({ action }) => {
      leaseCount += 1;
      return await action(async (writer) => await writer());
    },
  });

  assertEquals(result.registrations, []);
  assertEquals(result.alreadyQueued, true);
  assertEquals(result.receipt, "no_active_registrations");
  assertEquals(result.queued, 0);
  assertEquals(leaseCount, 0);
  assertEquals(liveStore.updateCount, 0);
});

Deno.test("legacy failed or idle pending end is requeued instead of accepted as a receipt", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    updated_date: "2026-09-01T12:00:00.000Z",
  }]);
  const liveStore = new Store([
    registration({
      id: "legacy-failed-no-request",
      token_hash: "legacy-token-1",
      delivery_revision: "legacy-delivery-1",
      delivery_state: "failed",
      retry_requested: false,
      pending_force_end: true,
      pending_room_id: "room-1",
      pending_match_id: "match-1",
      pending_room_revision: 1_788_264_000_000,
    }),
    registration({
      id: "legacy-failed-requested",
      token_hash: "legacy-token-2",
      delivery_revision: "legacy-delivery-2",
      delivery_state: "failed",
      retry_requested: true,
      pending_force_end: true,
      pending_room_id: "room-1",
      pending_match_id: "match-1",
      pending_room_revision: 1_788_264_000_000,
    }),
    registration({
      id: "legacy-idle-requested",
      token_hash: "legacy-token-3",
      delivery_revision: "legacy-delivery-3",
      delivery_state: "idle",
      retry_requested: true,
      pending_force_end: true,
      pending_room_id: "room-1",
      pending_match_id: "match-1",
      pending_room_revision: 1_788_264_000_000,
    }),
  ]);
  let leaseCount = 0;

  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    leaseRunner: async ({ action }) => {
      leaseCount += 1;
      return await action(async (writer) => await writer());
    },
    now: new Date("2026-09-01T12:00:01.000Z"),
  });

  assertEquals(result.alreadyQueued, false);
  assertEquals(result.receipt, "queued");
  assertEquals(result.queued, 3);
  assertEquals(leaseCount, 1);
  for (const record of liveStore.records) {
    assertEquals(record.delivery_state, "retry");
    assertEquals(record.retry_requested, true);
    assertEquals(record.pending_force_end, true);
  }
});

Deno.test("enqueue revalidates exact binding after acquiring its user lease", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    updated_date: "2026-09-01T12:00:00.000Z",
  }]);
  const liveStore = new Store([registration()]);

  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    leaseRunner: async ({ action }) => {
      liveStore.records[0] = {
        ...liveStore.records[0],
        match_id: "match-new",
        provider_match_id: "match-new",
      };
      return await action(async (writer) => await writer());
    },
    now: new Date("2026-09-01T12:00:01.000Z"),
  });

  assertEquals(result.queued, 0);
  assertEquals(result.skipped, 1);
  assertEquals(liveStore.updateCount, 0);
  assertEquals(liveStore.records[0].pending_force_end, undefined);
});

Deno.test("enqueue-only room end rejects a stale match before touching registrations", async () => {
  const roomStore = new Store([{ id: "room-1", match_id: "match-new" }]);
  const liveStore = new Store([registration()]);

  await assertRejects(
    () =>
      enqueueRoomLiveActivityEnd({
        roomStore,
        liveStore,
        lifecycleStore: {},
        roomID: "room-1",
        matchID: "match-1",
      }),
    PushContractError,
    "The room end source is stale.",
  );
  assertEquals(liveStore.updateCount, 0);
  assertEquals(liveStore.deliveryPathEntered, false);
});

Deno.test("terminal enqueue persists the exact committed finish receipt", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    status: "finished",
    game_finished_event_id: "game-finished:match-1",
    updated_date: "2026-09-01T12:00:00.000Z",
  }]);
  const liveStore = new Store([registration({
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 1_788_264_000_000,
    delivery_state: "retry",
  })]);
  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    terminalCommitID: "game-finished:match-1",
    leaseRunner: async ({ action }) =>
      await action(async (writer) => await writer()),
  });
  assertEquals(result.alreadyQueued, false);
  assertEquals(
    liveStore.records[0].pending_force_end_commit_id,
    "game-finished:match-1",
  );

  const retry = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    terminalCommitID: "game-finished:match-1",
  });
  assertEquals(retry.alreadyQueued, true);
});

Deno.test("close enqueue upgrades a prepared row with the exact close receipt", async () => {
  const roomStore = new Store([{
    id: "room-1",
    match_id: "match-1",
    status: "playing",
    updated_date: "2026-09-01T12:00:00.000Z",
    close_intent: {
      id: "close-1",
      room_id: "room-1",
      match_id: "match-1",
    },
  }]);
  const liveStore = new Store([registration({
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 1_788_264_000_000,
    delivery_state: "retry",
  })]);

  const result = await enqueueRoomLiveActivityEnd({
    roomStore,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    terminalCommitID: "room-close:match-1:close-1",
    leaseRunner: async ({ action }) =>
      await action(async (writer) => await writer()),
  });

  assertEquals(result.alreadyQueued, false);
  assertEquals(
    liveStore.records[0].pending_force_end_commit_id,
    "room-close:match-1:close-1",
  );
});

Deno.test("validated close snapshot dominates a less-fresh second room read", async () => {
  const validatedRoomSnapshot = {
    id: "room-1",
    match_id: "match-1",
    status: "playing",
    updated_date: "2026-09-01T12:00:01.000Z",
    close_intent: {
      id: "close-1",
      room_id: "room-1",
      match_id: "match-1",
    },
  };
  const liveStore = new Store([registration()]);
  const result = await enqueueRoomLiveActivityEnd({
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "playing",
      updated_date: "2026-09-01T12:00:00.000Z",
    }]),
    validatedRoomSnapshot,
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    terminalCommitID: "room-close:match-1:close-1",
    leaseRunner: async ({ action }) =>
      await action(async (writer) => await writer()),
  });
  assertEquals(result.queued, 1);
  assertEquals(
    liveStore.records[0].pending_force_end_commit_id,
    "room-close:match-1:close-1",
  );
});

Deno.test("full close completion authorizes enqueue while GameRoom reads missing", async () => {
  const completion = closeCompletion();
  const signals = closeSignals();
  assertEquals(
    closeCompletionAuthorizesLiveEndQueue({
      signals,
      completion,
      roomID: "room-1",
      matchID: "match-1",
      terminalCommitID: "room-close:match-1:close-1",
    }),
    true,
  );
  const liveStore = new Store([registration()]);
  const result = await enqueueRoomLiveActivityEnd({
    roomStore: new Store([]),
    signalStore: new Store(signals),
    liveStore,
    lifecycleStore: {},
    roomID: "room-1",
    matchID: "match-1",
    terminalCommitID: "room-close:match-1:close-1",
    closeCompletion: completion,
    leaseRunner: async ({ action }) =>
      await action(async (writer) => await writer()),
  });
  assertEquals(result.queued, 1);
  assertEquals(
    liveStore.records[0].pending_force_end_commit_id,
    "room-close:match-1:close-1",
  );
});

Deno.test("partial close completion cannot authorize missing-room enqueue", async () => {
  await assertRejects(
    () =>
      enqueueRoomLiveActivityEnd({
        roomStore: new Store([]),
        signalStore: new Store(closeSignals().slice(0, 1)),
        liveStore: new Store([registration()]),
        lifecycleStore: {},
        roomID: "room-1",
        matchID: "match-1",
        terminalCommitID: "room-close:match-1:close-1",
        closeCompletion: closeCompletion(),
      }),
    PushContractError,
    "The room close completion is invalid.",
  );
});

Deno.test("terminal enqueue rejects a receipt from another match", async () => {
  await assertRejects(
    () =>
      enqueueRoomLiveActivityEnd({
        roomStore: new Store([{ id: "room-1", match_id: "match-1" }]),
        liveStore: new Store([registration()]),
        lifecycleStore: {},
        roomID: "room-1",
        matchID: "match-1",
        terminalCommitID: "game-finished:match-old",
      }),
    PushContractError,
    "The terminal commit receipt is invalid.",
  );
});

Deno.test("trusted enqueue action returns before compatibility delivery branch", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const actionList = source.indexOf('"enqueue_room_live_activity_end"');
  const internalGate = source.indexOf("if (!internalRequest(body))");
  const branchStart = source.indexOf(
    'if (action === "enqueue_room_live_activity_end")',
  );
  const branchEnd = source.indexOf(
    'if (action === "end_room_live_activities")',
    branchStart,
  );

  assertEquals(actionList >= 0, true);
  assertEquals(internalGate > actionList, true);
  assertEquals(branchStart > internalGate, true);
  assertEquals(branchEnd > branchStart, true);
  const branch = source.slice(branchStart, branchEnd);
  assertStringIncludes(branch, "enqueueRoomLiveActivityEndOnly");
  assertEquals(branch.includes("deliverForcedLiveActivityEnd"), false);
  assertEquals(branch.includes("sendLiveActivityTermination"), false);
  assertEquals(source.includes("callerHoldsLifecycleLeases"), false);

  const syncStart = source.indexOf("async function syncLiveActivities");
  const syncEnd = source.indexOf(
    "async function deliverForcedLiveActivityEnd",
    syncStart,
  );
  const syncSource = source.slice(syncStart, syncEnd);
  const pendingRoute = syncSource.indexOf(
    "current.pending_force_end === true",
  );
  const ordinaryClaim = syncSource.indexOf("claimLiveDelivery({");
  assertEquals(pendingRoute >= 0, true);
  assertEquals(ordinaryClaim > pendingRoute, true);
  assertStringIncludes(syncSource, 'outcome === "force_end_pending"');

  const drainStart = source.indexOf("async function drainLiveActivityRetries");
  const drainEnd = source.indexOf(
    "async function reconcileIdleLiveActivityDrift",
    drainStart,
  );
  const drainSource = source.slice(drainStart, drainEnd);
  assertStringIncludes(drainSource, "retry_requested: true");
});

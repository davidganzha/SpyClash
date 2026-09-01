import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  deliverQueuedRoomLiveActivityEnd,
  type QueuedLiveEndDelivery,
} from "./queued-live-end-delivery.ts";

class Store {
  queries: Record<string, unknown>[] = [];

  constructor(public records: Record<string, any>[]) {}

  async filter(
    filter: Record<string, unknown>,
    _sort = "created_date",
    limit = 100,
    skip = 0,
  ) {
    this.queries.push(structuredClone(filter));
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).slice(skip, skip + limit).map((record) => structuredClone(record));
  }
}

function registration(overrides: Record<string, any> = {}) {
  return {
    id: "live-1",
    user_id: "player-1",
    status: "active",
    token_kind: "activity",
    room_id: "deleted-room",
    match_id: "match-1",
    provider_match_id: "match-1",
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 101,
    delivery_state: "retry",
    delivery_revision: "delivery-1",
    ...overrides,
  };
}

Deno.test("queued delivery scans only exact pending activities without a GameRoom", async () => {
  const store = new Store([
    registration(),
    registration({ id: "ended", status: "ended" }),
    registration({ id: "push-start", token_kind: "push_to_start" }),
    registration({ id: "not-pending", pending_force_end: false }),
    registration({ id: "wrong-room", pending_room_id: "room-old" }),
    registration({ id: "wrong-match", pending_match_id: "match-old" }),
  ]);
  const deliveredIDs: string[] = [];

  const result = await deliverQueuedRoomLiveActivityEnd({
    liveStore: store,
    roomID: "room-1",
    matchID: "match-1",
    deadlineEpochMs: 100,
    nowEpochMs: () => 0,
    deliver: async ({ registration }) => {
      deliveredIDs.push(registration.id);
      return "delivered";
    },
  });

  assertEquals(store.queries[0], {
    status: "active",
    token_kind: "activity",
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
  });
  assertEquals(result.registrations.map((row) => row.id), ["live-1"]);
  assertEquals(deliveredIDs, ["live-1"]);
  assertEquals(result.delivered, 1);
  assertEquals(result.failed, 0);
  assertEquals(result.skipped, 0);
  assertEquals(result.deferredRegistrations, []);
});

Deno.test("queued delivery uses only each row pending revision", async () => {
  const store = new Store([registration({
    pending_room_revision: 321,
    last_revision: 999,
  })]);
  const revisions: number[] = [];

  const request = {
    liveStore: store,
    roomID: "room-1",
    matchID: "match-1",
    deadlineEpochMs: 100,
    nowEpochMs: () => 0,
    deliver: async ({ roomRevision }: QueuedLiveEndDelivery) => {
      revisions.push(roomRevision);
      return "skipped" as const;
    },
    // A caller revision is deliberately not part of this action contract.
    roomRevision: 7_777,
  };
  await deliverQueuedRoomLiveActivityEnd(request);

  assertEquals(revisions, [321]);
});

Deno.test("deadline leaves unfinished user groups and rows durably pending", async () => {
  const store = new Store([
    registration({ id: "user-1-a", user_id: "user-1" }),
    registration({
      id: "user-1-b",
      user_id: "user-1",
      delivery_revision: "delivery-2",
    }),
    registration({
      id: "user-2-a",
      user_id: "user-2",
      delivery_revision: "delivery-3",
    }),
  ]);
  let epoch = 0;
  const started: string[] = [];

  const result = await deliverQueuedRoomLiveActivityEnd({
    liveStore: store,
    roomID: "room-1",
    matchID: "match-1",
    deadlineEpochMs: 50,
    concurrency: 1,
    nowEpochMs: () => epoch,
    deliver: async ({ registration }) => {
      started.push(registration.id);
      epoch = 50;
      return "delivered";
    },
  });

  assertEquals(started, ["user-1-a"]);
  assertEquals(
    result.deferredRegistrations.map((row) => row.id),
    ["user-1-b", "user-2-a"],
  );
  assertEquals(result.delivered, 1);
  for (const id of ["user-1-b", "user-2-a"]) {
    const pending = store.records.find((row) => row.id === id)!;
    assertEquals(pending.status, "active");
    assertEquals(pending.pending_force_end, true);
    assertEquals(pending.delivery_state, "retry");
  }
});

Deno.test("trusted queued delivery route clamps its deadline and uses forced delivery", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const actionList = source.indexOf(
    '"deliver_queued_room_live_activity_end"',
  );
  const internalGate = source.indexOf("if (!internalRequest(body))");
  const branchStart = source.indexOf(
    'if (action === "deliver_queued_room_live_activity_end")',
  );
  const branchEnd = source.indexOf(
    'if (action === "end_room_live_activities")',
    branchStart,
  );

  assertEquals(actionList >= 0, true);
  assertEquals(internalGate > actionList, true);
  assertEquals(branchStart > internalGate, true);
  assertEquals(branchEnd > branchStart, true);
  assertStringIncludes(
    source.slice(branchStart, branchEnd),
    "deliverQueuedRoomLiveActivityEndOnly",
  );

  const wrapperStart = source.indexOf(
    "async function deliverQueuedRoomLiveActivityEndOnly",
  );
  const wrapperEnd = source.indexOf(
    "async function endRoomLiveActivities",
    wrapperStart,
  );
  const wrapper = source.slice(wrapperStart, wrapperEnd);
  assertStringIncludes(wrapper, "body.deadline_epoch_ms");
  assertStringIncludes(wrapper, "clampDeadline(");
  assertStringIncludes(wrapper, "runWithinDeadline({");
  assertStringIncludes(wrapper, "if (bounded.timedOut)");
  assertStringIncludes(wrapper, "timed_out: true");
  assertStringIncludes(wrapper, "deliverForcedLiveActivityEnd({");
  assertStringIncludes(wrapper, "queuedPendingOnly: true");
  assertStringIncludes(wrapper, "withBillingLifecycleContentionRetry({");
  assertStringIncludes(wrapper, "deadlineEpochMs,");
  assertEquals(wrapper.includes("GameRoom"), false);
  assertEquals(wrapper.includes("body.room_revision"), false);
  assertEquals(wrapper.includes("sendLiveActivityTermination"), false);

  const forcedStart = source.indexOf(
    "async function deliverForcedLiveActivityEnd",
  );
  const forcedEnd = source.indexOf(
    "async function queueRoomLiveActivityEnd",
    forcedStart,
  );
  const forcedSource = source.slice(forcedStart, forcedEnd);
  assertStringIncludes(forcedSource, "input.queuedPendingOnly");
  assertStringIncludes(forcedSource, "current.pending_room_revision");
  const exactPending = forcedSource.indexOf("const exactPendingEnd");
  const dueCheck = forcedSource.indexOf("!liveDeliveryDue(current)");
  const authorization = forcedSource.indexOf(
    "authorizeForcedLiveActivityEnd({",
  );
  const claim = forcedSource.indexOf("claimLiveDelivery({");
  assertEquals(
    exactPending >= 0 && exactPending < dueCheck && dueCheck < authorization &&
      authorization < claim,
    true,
    "forced delivery must re-read, respect backoff, and prove terminal commit before claiming",
  );
  assertStringIncludes(
    forcedSource,
    "clean(current.user_id) !== clean(input.registration.user_id)",
  );
  assertStringIncludes(forcedSource, "claimLiveDelivery({");
  assertStringIncludes(forcedSource, "sendLiveActivityTermination({");

  const helperSource = await Deno.readTextFile(
    new URL("./queued-live-end-delivery.ts", import.meta.url),
  );
  assertStringIncludes(helperSource, "registration.pending_room_revision");
  assertEquals(helperSource.includes("entities.GameRoom"), false);
  assertEquals(helperSource.includes("roomStore"), false);
  assertEquals(helperSource.includes("sendLiveActivityTermination"), false);

  const syncStart = source.indexOf("async function syncLiveActivities");
  const syncEnd = source.indexOf(
    "async function deliverForcedLiveActivityEnd",
    syncStart,
  );
  const syncSource = source.slice(syncStart, syncEnd);
  const initialCloseGuard = syncSource.indexOf("if (room.close_intent)");
  const registrationScan = syncSource.indexOf(
    "const activityRegistrations",
  );
  const markerRecheck = syncSource.indexOf(
    "committedGameFinishReceipt({",
    registrationScan,
  );
  const ordinarySend = syncSource.indexOf("sendLiveActivityUpdate({");
  assertEquals(
    initialCloseGuard >= 0 && initialCloseGuard < registrationScan &&
      markerRecheck > registrationScan && markerRecheck < ordinarySend,
    true,
    "logical close must block initial and raced ordinary ActivityKit projections",
  );
  assertStringIncludes(syncSource, 'errorCode: "terminal_marker_committed"');
  assertStringIncludes(syncSource, '"terminal_source_unconfirmed"');
  assertEquals(
    syncSource.includes('status: "ended"'),
    false,
    "an unproved missing/mismatched room must never terminalize ActivityKit",
  );
});

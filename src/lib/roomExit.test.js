import assert from "node:assert/strict";
import test from "node:test";

import {
  clearPendingRoomExit,
  completePendingRoomExit,
  exitRoomImmediately,
  markRoomExitPending,
  pendingRoomExitAction,
  pendingRoomExitId,
  pendingRoomExitMarker,
  pendingRoomExitMembershipID,
  pendingRoomExitRevision,
  PENDING_ROOM_CLOSE_RETRY_DELAYS_MILLISECONDS,
  roomExitIsPending,
} from "./roomExit.js";
import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
} from "./gameRoomExit.js";

function memoryStorage(initial = {}) {
  const values = new Map(Object.entries(initial));
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test("room exit clears the active room and records pending server cleanup", () => {
  const storage = memoryStorage({ spy_active_room_id: "room-1" });

  assert.equal(markRoomExitPending(" room-1 ", storage), "room-1");
  assert.equal(storage.getItem("spy_active_room_id"), null);
  assert.equal(pendingRoomExitId(storage), "room-1");
  assert.equal(pendingRoomExitAction(storage), GAME_ROOM_LEAVE_ACTION);
  assert.equal(pendingRoomExitRevision(storage), null);
  assert.equal(pendingRoomExitMembershipID(storage), null);
  assert.equal(storage.getItem("spy_pending_room_exit_revision"), null);
  assert.equal(roomExitIsPending("room-1", storage), true);
  assert.equal(roomExitIsPending("room-2", storage), false);
});

test("pending cleanup preserves a host close_room action", () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host" });

  assert.equal(
    markRoomExitPending("room-host", storage, GAME_ROOM_CLOSE_ACTION),
    "room-host",
  );
  assert.equal(pendingRoomExitId(storage), "room-host");
  assert.equal(pendingRoomExitAction(storage), GAME_ROOM_CLOSE_ACTION);

  clearPendingRoomExit("room-host", storage, { force: true });
  assert.equal(pendingRoomExitId(storage), null);
  assert.equal(pendingRoomExitAction(storage), null);
});

test("ordinary cleanup requires the complete marker identity", () => {
  const storage = memoryStorage({ spy_active_room_id: "room-exact" });
  markRoomExitPending(
    "room-exact",
    storage,
    GAME_ROOM_CLOSE_ACTION,
    7,
    "membership-exact",
  );

  assert.equal(clearPendingRoomExit("room-exact", storage), false);
  assert.equal(clearPendingRoomExit("room-exact", storage, {
    action: GAME_ROOM_CLOSE_ACTION,
    expectedRevision: 7,
    expectedMembershipID: "membership-other",
  }), false);
  assert.equal(pendingRoomExitId(storage), "room-exact");
  assert.equal(clearPendingRoomExit("room-exact", storage, {
    action: GAME_ROOM_CLOSE_ACTION,
    expectedRevision: 7,
    expectedMembershipID: "membership-exact",
  }), true);
  assert.equal(pendingRoomExitId(storage), null);
});

test("legacy pending exits without a revision stay unversioned", async () => {
  for (const storedRevision of [undefined, "", "   "]) {
    const initial = {
      spy_pending_room_exit_id: "room-legacy",
      spy_pending_room_exit_action: GAME_ROOM_LEAVE_ACTION,
    };
    if (storedRevision !== undefined) {
      initial.spy_pending_room_exit_revision = storedRevision;
    }
    const storage = memoryStorage(initial);
    const receivedRevisions = [];

    assert.equal(pendingRoomExitRevision(storage), null);
    const completed = await completePendingRoomExit({
      roomId: "room-legacy",
      action: GAME_ROOM_LEAVE_ACTION,
      expectedRevision: storedRevision,
      storage,
      performExit: async (_roomId, expectedRevision) => {
        receivedRevisions.push(expectedRevision);
      },
    });

    assert.equal(completed, true);
    assert.deepEqual(receivedRevisions, [null]);
    assert.equal(storage.getItem("spy_pending_room_exit_revision"), null);
  }
});

test("pending room revision survives storage and every close retry", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-versioned" });
  markRoomExitPending(
    "room-versioned",
    storage,
    GAME_ROOM_CLOSE_ACTION,
    42,
  );
  const receivedRevisions = [];
  let attempts = 0;

  assert.equal(storage.getItem("spy_pending_room_exit_revision"), "42");
  assert.equal(pendingRoomExitRevision(storage), 42);
  const completed = await completePendingRoomExit({
    roomId: "room-versioned",
    action: GAME_ROOM_CLOSE_ACTION,
    expectedRevision: null,
    storage,
    performExit: async (_roomId, expectedRevision) => {
      attempts += 1;
      receivedRevisions.push(expectedRevision);
      if (attempts < 3) throw new Error("timeout");
    },
    sleep: async () => {},
  });

  assert.equal(completed, true);
  assert.deepEqual(receivedRevisions, [42, 42, 42]);
  assert.equal(pendingRoomExitRevision(storage), null);
  assert.equal(storage.getItem("spy_pending_room_exit_revision"), null);
});

test("pending membership generation survives storage and every exit attempt", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-generation" });
  markRoomExitPending(
    "room-generation",
    storage,
    GAME_ROOM_CLOSE_ACTION,
    42,
    "membership-generation-a",
  );
  const received = [];

  const completed = await completePendingRoomExit({
    roomId: "room-generation",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async (roomId, expectedRevision, expectedMembershipID) => {
      received.push({ roomId, expectedRevision, expectedMembershipID });
    },
  });

  assert.equal(completed, true);
  assert.deepEqual(received, [{
    roomId: "room-generation",
    expectedRevision: 42,
    expectedMembershipID: "membership-generation-a",
  }]);
  assert.equal(pendingRoomExitMarker(storage), null);
});

test("an old exit completion cannot erase a newer membership marker", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-race" });
  markRoomExitPending(
    "room-race",
    storage,
    GAME_ROOM_LEAVE_ACTION,
    10,
    "membership-a",
  );
  let releaseOldExit;
  let announceOldExit;
  const oldExitGate = new Promise((resolve) => { releaseOldExit = resolve; });
  const oldExitStarted = new Promise((resolve) => { announceOldExit = resolve; });

  const oldCompletion = completePendingRoomExit({
    roomId: "room-race",
    action: GAME_ROOM_LEAVE_ACTION,
    expectedRevision: 10,
    expectedMembershipID: "membership-a",
    storage,
    performExit: async () => {
      announceOldExit();
      await oldExitGate;
    },
  });
  await oldExitStarted;

  // A successful rejoin intentionally retires A, then a later exit creates B.
  assert.equal(clearPendingRoomExit("room-race", storage, { force: true }), true);
  markRoomExitPending(
    "room-race",
    storage,
    GAME_ROOM_CLOSE_ACTION,
    12,
    "membership-b",
  );
  releaseOldExit();

  assert.equal(await oldCompletion, true);
  assert.deepEqual(pendingRoomExitMarker(storage), {
    roomId: "room-race",
    action: GAME_ROOM_CLOSE_ACTION,
    expectedRevision: 12,
    expectedMembershipID: "membership-b",
  });
});

test("an old forbidden close cannot replace a newer marker with its fallback", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-close-race" });
  markRoomExitPending(
    "room-close-race",
    storage,
    GAME_ROOM_CLOSE_ACTION,
    20,
    "membership-a",
  );
  let rejectOldClose;
  let announceOldClose;
  const oldCloseGate = new Promise((resolve, reject) => { rejectOldClose = reject; });
  const oldCloseStarted = new Promise((resolve) => { announceOldClose = resolve; });
  let fallbackAttempts = 0;

  const oldCompletion = completePendingRoomExit({
    roomId: "room-close-race",
    action: GAME_ROOM_CLOSE_ACTION,
    expectedRevision: 20,
    expectedMembershipID: "membership-a",
    storage,
    performExit: async () => {
      announceOldClose();
      await oldCloseGate;
    },
    performLeaveFallback: async () => { fallbackAttempts += 1; },
  });
  await oldCloseStarted;
  markRoomExitPending(
    "room-close-race",
    storage,
    GAME_ROOM_LEAVE_ACTION,
    21,
    "membership-b",
  );
  rejectOldClose(Object.assign(new Error("host changed"), { status: 403 }));

  assert.equal(await oldCompletion, true);
  assert.equal(fallbackAttempts, 0);
  assert.deepEqual(pendingRoomExitMarker(storage), {
    roomId: "room-close-race",
    action: GAME_ROOM_LEAVE_ACTION,
    expectedRevision: 21,
    expectedMembershipID: "membership-b",
  });
});

test("navigation happens before the server leave resolves", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-1" });
  const events = [];
  let resolveLeave;
  const leave = new Promise((resolve) => { resolveLeave = resolve; });

  const completion = exitRoomImmediately({
    roomId: "room-1",
    storage,
    navigateHome: () => events.push("navigate"),
    performExit: () => {
      events.push("leave");
      return leave;
    },
  });

  assert.deepEqual(events, ["navigate"]);
  assert.equal(pendingRoomExitId(storage), "room-1");
  await Promise.resolve();
  assert.deepEqual(events, ["navigate", "leave"]);

  resolveLeave();
  assert.equal(await completion, true);
  assert.equal(pendingRoomExitId(storage), null);
});

test("failed server cleanup keeps the room suppressed for a later retry", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-1" });

  const completed = await exitRoomImmediately({
    roomId: "room-1",
    storage,
    navigateHome: () => {},
    performExit: async () => { throw new Error("offline"); },
  });

  assert.equal(completed, false);
  assert.equal(pendingRoomExitId(storage), "room-1");
  clearPendingRoomExit("different-room", storage, { force: true });
  assert.equal(pendingRoomExitId(storage), "room-1");
  clearPendingRoomExit("room-1", storage, { force: true });
  assert.equal(pendingRoomExitId(storage), null);
});

test("authoritative room absence completes pending local cleanup", async () => {
  for (const status of [403, 404]) {
    const storage = memoryStorage({ spy_active_room_id: "room-1" });
    const completed = await exitRoomImmediately({
      roomId: "room-1",
      storage,
      navigateHome: () => {},
      performExit: async () => {
        throw Object.assign(new Error("already gone"), { status });
      },
    });

    assert.equal(completed, true);
    assert.equal(pendingRoomExitId(storage), null);
  }
});

test("a pending local-first exit can retry the same authoritative cleanup", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-1" });
  let leaveAttempts = 0;

  const firstAttempt = await exitRoomImmediately({
    roomId: "room-1",
    storage,
    navigateHome: () => {},
    performExit: async () => {
      leaveAttempts += 1;
      throw new Error("offline");
    },
  });
  assert.equal(firstAttempt, false);
  assert.equal(pendingRoomExitId(storage), "room-1");
  assert.equal(pendingRoomExitAction(storage), GAME_ROOM_LEAVE_ACTION);

  const retry = await exitRoomImmediately({
    roomId: "room-1",
    action: pendingRoomExitAction(storage),
    storage,
    navigateHome: () => {},
    performExit: async () => {
      leaveAttempts += 1;
    },
  });
  assert.equal(retry, true);
  assert.equal(leaveAttempts, 2);
  assert.equal(pendingRoomExitId(storage), null);
});

test("pending idempotent close retries at a capped cadence until success", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host" });
  markRoomExitPending("room-host", storage, GAME_ROOM_CLOSE_ACTION);
  const sleeps = [];
  let attempts = 0;

  const completed = await completePendingRoomExit({
    roomId: "room-host",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      attempts += 1;
      if (attempts < 7) throw new Error("timeout");
    },
    sleep: async (milliseconds) => sleeps.push(milliseconds),
  });

  assert.equal(completed, true);
  assert.equal(attempts, 7);
  assert.deepEqual(sleeps, [1_000, 2_000, 4_000, 8_000, 8_000, 8_000]);
  assert.equal(
    Math.max(...sleeps),
    PENDING_ROOM_CLOSE_RETRY_DELAYS_MILLISECONDS.at(-1),
  );
  assert.equal(pendingRoomExitId(storage), null);
  assert.equal(pendingRoomExitAction(storage), null);
});

test("pending close stops its active worker on permanent client failures", async () => {
  for (const error of [
    Object.assign(new Error("invalid"), { status: 400 }),
    Object.assign(new Error("auth"), { status: 401 }),
    Object.assign(new Error("conflict"), { status: 409 }),
    Object.assign(new Error("wrong conflict"), {
      status: 409,
      code: "room_revision_conflict",
      retryable: true,
    }),
  ]) {
    const storage = memoryStorage({ spy_active_room_id: "room-host" });
    markRoomExitPending("room-host", storage, GAME_ROOM_CLOSE_ACTION);
    let attempts = 0;
    const sleeps = [];

    const completed = await completePendingRoomExit({
      roomId: "room-host",
      action: GAME_ROOM_CLOSE_ACTION,
      storage,
      performExit: async () => {
        attempts += 1;
        throw error;
      },
      sleep: async (milliseconds) => sleeps.push(milliseconds),
    });

    assert.equal(completed, false);
    assert.equal(attempts, 1);
    assert.deepEqual(sleeps, []);
    assert.equal(pendingRoomExitId(storage), "room-host");
  }
});

test("pending close retries only a typed retryable lease conflict", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host" });
  markRoomExitPending("room-host", storage, GAME_ROOM_CLOSE_ACTION);
  let attempts = 0;
  const sleeps = [];

  const completed = await completePendingRoomExit({
    roomId: "room-host",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      attempts += 1;
      if (attempts === 1) {
        throw Object.assign(new Error("busy"), {
          status: 409,
          code: "active_lease",
          retryable: true,
        });
      }
    },
    sleep: async (milliseconds) => sleeps.push(milliseconds),
  });

  assert.equal(completed, true);
  assert.equal(attempts, 2);
  assert.deepEqual(sleeps, [1_000]);
  assert.equal(pendingRoomExitId(storage), null);
});

test("a forbidden host close persists leave before one successful fallback", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host-forbidden" });
  markRoomExitPending("room-host-forbidden", storage, GAME_ROOM_CLOSE_ACTION);
  const events = [];

  const completed = await completePendingRoomExit({
    roomId: "room-host-forbidden",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      events.push("close");
      throw Object.assign(new Error("host access lost"), { status: 403 });
    },
    performLeaveFallback: async () => {
      events.push("leave");
      assert.equal(pendingRoomExitAction(storage), GAME_ROOM_LEAVE_ACTION);
    },
  });

  assert.equal(completed, true);
  assert.deepEqual(events, ["close", "leave"]);
  assert.equal(pendingRoomExitId(storage), null);
  assert.equal(pendingRoomExitAction(storage), null);
});

test("a timed-out forbidden-close fallback remains a durable bounded leave", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host-timeout" });
  markRoomExitPending("room-host-timeout", storage, GAME_ROOM_CLOSE_ACTION);
  let closeAttempts = 0;
  let leaveAttempts = 0;

  const first = await completePendingRoomExit({
    roomId: "room-host-timeout",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      closeAttempts += 1;
      throw Object.assign(new Error("host access lost"), { status: 403 });
    },
    performLeaveFallback: async () => {
      leaveAttempts += 1;
      throw Object.assign(new Error("leave timed out"), { status: 408 });
    },
  });

  assert.equal(first, false);
  assert.equal(closeAttempts, 1);
  assert.equal(leaveAttempts, 1);
  assert.equal(pendingRoomExitId(storage), "room-host-timeout");
  assert.equal(pendingRoomExitAction(storage), GAME_ROOM_LEAVE_ACTION);

  const recovered = await completePendingRoomExit({
    roomId: "room-host-timeout",
    action: pendingRoomExitAction(storage),
    storage,
    performExit: async () => { leaveAttempts += 1; },
  });

  assert.equal(recovered, true);
  assert.equal(closeAttempts, 1);
  assert.equal(leaveAttempts, 2);
  assert.equal(pendingRoomExitId(storage), null);
});

test("Home remount shares the forbidden-close leave fallback worker", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host-remount" });
  markRoomExitPending("room-host-remount", storage, GAME_ROOM_CLOSE_ACTION);
  let closeAttempts = 0;
  let firstFallbackAttempts = 0;
  let duplicateCloseAttempts = 0;
  let duplicateFallbackAttempts = 0;
  let releaseFallback;
  let announceFallbackStarted;
  const fallbackGate = new Promise((resolve) => { releaseFallback = resolve; });
  const fallbackStarted = new Promise((resolve) => { announceFallbackStarted = resolve; });

  const firstCompletion = completePendingRoomExit({
    roomId: "room-host-remount",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      closeAttempts += 1;
      throw Object.assign(new Error("host access lost"), { status: 403 });
    },
    performLeaveFallback: async () => {
      firstFallbackAttempts += 1;
      announceFallbackStarted();
      await fallbackGate;
    },
  });
  await fallbackStarted;

  const remountedCompletion = completePendingRoomExit({
    roomId: "room-host-remount",
    action: pendingRoomExitAction(storage),
    storage,
    performExit: async () => {
      duplicateCloseAttempts += 1;
    },
    performLeaveFallback: async () => {
      duplicateFallbackAttempts += 1;
    },
  });

  assert.equal(remountedCompletion, firstCompletion);
  assert.equal(closeAttempts, 1);
  assert.equal(firstFallbackAttempts, 1);
  assert.equal(duplicateCloseAttempts, 0);
  assert.equal(duplicateFallbackAttempts, 0);
  releaseFallback();
  assert.equal(await firstCompletion, true);
  assert.equal(await remountedCompletion, true);
  assert.equal(closeAttempts, 1);
  assert.equal(firstFallbackAttempts, 1);
  assert.equal(duplicateCloseAttempts, 0);
  assert.equal(duplicateFallbackAttempts, 0);
  assert.equal(pendingRoomExitId(storage), null);
});

test("concurrent close recovery callers share one room-action worker", async () => {
  const storage = memoryStorage({ spy_active_room_id: "room-host" });
  markRoomExitPending("room-host", storage, GAME_ROOM_CLOSE_ACTION);
  let releaseAttempt;
  const attemptGate = new Promise((resolve) => { releaseAttempt = resolve; });
  let firstWorkerAttempts = 0;
  let duplicateWorkerAttempts = 0;

  const firstCompletion = completePendingRoomExit({
    roomId: "room-host",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      firstWorkerAttempts += 1;
      await attemptGate;
    },
  });
  const remountedCompletion = completePendingRoomExit({
    roomId: "room-host",
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    performExit: async () => {
      duplicateWorkerAttempts += 1;
    },
  });

  assert.equal(remountedCompletion, firstCompletion);
  assert.equal(firstWorkerAttempts, 1);
  assert.equal(duplicateWorkerAttempts, 0);
  releaseAttempt();
  assert.equal(await firstCompletion, true);
  assert.equal(await remountedCompletion, true);
  assert.equal(firstWorkerAttempts, 1);
  assert.equal(duplicateWorkerAttempts, 0);
  assert.equal(pendingRoomExitId(storage), null);
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  clearPendingRoomExit,
  exitRoomImmediately,
  markRoomExitPending,
  pendingRoomExitAction,
  pendingRoomExitId,
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

  clearPendingRoomExit("room-host", storage);
  assert.equal(pendingRoomExitId(storage), null);
  assert.equal(pendingRoomExitAction(storage), null);
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
    leaveRoom: () => {
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
    leaveRoom: async () => { throw new Error("offline"); },
  });

  assert.equal(completed, false);
  assert.equal(pendingRoomExitId(storage), "room-1");
  clearPendingRoomExit("different-room", storage);
  assert.equal(pendingRoomExitId(storage), "room-1");
  clearPendingRoomExit("room-1", storage);
  assert.equal(pendingRoomExitId(storage), null);
});

test("authoritative room absence completes pending local cleanup", async () => {
  for (const status of [403, 404]) {
    const storage = memoryStorage({ spy_active_room_id: "room-1" });
    const completed = await exitRoomImmediately({
      roomId: "room-1",
      storage,
      navigateHome: () => {},
      leaveRoom: async () => {
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
    action: GAME_ROOM_CLOSE_ACTION,
    storage,
    navigateHome: () => {},
    leaveRoom: async () => {
      leaveAttempts += 1;
      throw new Error("offline");
    },
  });
  assert.equal(firstAttempt, false);
  assert.equal(pendingRoomExitId(storage), "room-1");
  assert.equal(pendingRoomExitAction(storage), GAME_ROOM_CLOSE_ACTION);

  const retry = await exitRoomImmediately({
    roomId: "room-1",
    action: pendingRoomExitAction(storage),
    storage,
    navigateHome: () => {},
    leaveRoom: async () => {
      leaveAttempts += 1;
    },
  });
  assert.equal(retry, true);
  assert.equal(leaveAttempts, 2);
  assert.equal(pendingRoomExitId(storage), null);
});

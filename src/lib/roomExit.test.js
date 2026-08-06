import assert from "node:assert/strict";
import test from "node:test";

import {
  clearPendingRoomExit,
  exitRoomImmediately,
  markRoomExitPending,
  pendingRoomExitId,
  roomExitIsPending,
} from "./roomExit.js";

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
  assert.equal(roomExitIsPending("room-1", storage), true);
  assert.equal(roomExitIsPending("room-2", storage), false);
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

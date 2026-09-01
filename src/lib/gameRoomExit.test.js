import assert from "node:assert/strict";
import test from "node:test";

import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
  gameRoomExitAction,
  gameRoomExitPayload,
} from "./gameRoomExit.js";

test("a host receives close_room only when the UI explicitly promises close", () => {
  const host = {
    hostEmail: " Host@Example.com ",
    userEmail: "host@example.com",
  };

  assert.equal(gameRoomExitAction({ ...host, closeForHost: true }), GAME_ROOM_CLOSE_ACTION);
  assert.equal(gameRoomExitAction({ ...host, closeForHost: false }), GAME_ROOM_LEAVE_ACTION);
  assert.equal(gameRoomExitAction({
    hostEmail: host.hostEmail,
    userEmail: "player@example.com",
    closeForHost: true,
  }), GAME_ROOM_LEAVE_ACTION);
  assert.equal(gameRoomExitAction({
    hostEmail: "",
    userEmail: "",
    closeForHost: true,
  }), GAME_ROOM_LEAVE_ACTION);
});

test("room exit payloads preserve the exact selected action and room", () => {
  assert.deepEqual(gameRoomExitPayload({
    action: GAME_ROOM_CLOSE_ACTION,
    roomId: " room-1 ",
  }), {
    action: "close_room",
    room_id: "room-1",
  });
  assert.deepEqual(gameRoomExitPayload({
    action: GAME_ROOM_LEAVE_ACTION,
    roomId: "room-2",
  }), {
    action: "leave_room",
    room_id: "room-2",
  });
  assert.deepEqual(gameRoomExitPayload({
    action: "unexpected_action",
    roomId: "room-3",
  }), {
    action: "leave_room",
    room_id: "room-3",
  });
  assert.throws(
    () => gameRoomExitPayload({ action: GAME_ROOM_CLOSE_ACTION, roomId: " " }),
    /Room ID is required/,
  );
});

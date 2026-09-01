import assert from "node:assert/strict";
import test from "node:test";

import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
  gameRoomExitAction,
  gameRoomExitExpectedMembershipID,
  gameRoomExitExpectedRevision,
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
  assert.deepEqual(gameRoomExitPayload({
    action: GAME_ROOM_CLOSE_ACTION,
    roomId: "room-4",
    expectedRevision: " 17 ",
  }), {
    action: "close_room",
    room_id: "room-4",
    expected_revision: 17,
  });
  assert.deepEqual(gameRoomExitPayload({
    action: GAME_ROOM_LEAVE_ACTION,
    roomId: "room-5",
    expectedRevision: 0,
    expectedMembershipID: " membership-5 ",
  }), {
    action: "leave_room",
    room_id: "room-5",
    expected_revision: 0,
    expected_membership_id: "membership-5",
  });
  assert.throws(
    () => gameRoomExitPayload({ action: GAME_ROOM_CLOSE_ACTION, roomId: " " }),
    /Room ID is required/,
  );
});

test("absent payload revisions never become an expected_revision of zero", () => {
  for (const expectedRevision of [null, undefined, "", "   "]) {
    assert.deepEqual(gameRoomExitPayload({
      action: GAME_ROOM_LEAVE_ACTION,
      roomId: "room-legacy",
      expectedRevision,
    }), {
      action: "leave_room",
      room_id: "room-legacy",
    });
  }
});

test("legacy rooms use room revision zero and never substitute lobby revision", () => {
  const legacyRoom = { id: "room-legacy", lobby_revision: 20 };
  const expectedRevision = gameRoomExitExpectedRevision(legacyRoom);

  assert.equal(expectedRevision, 0);
  assert.deepEqual(gameRoomExitPayload({
    action: GAME_ROOM_LEAVE_ACTION,
    roomId: legacyRoom.id,
    expectedRevision,
  }), {
    action: "leave_room",
    room_id: "room-legacy",
    expected_revision: 0,
  });
});

test("room exits use only the viewer's projected membership generation", () => {
  assert.equal(gameRoomExitExpectedMembershipID({
    viewer_membership_id: " generation-current ",
    players: [{ membership_id: "private-player-generation" }],
  }), "generation-current");
  assert.equal(gameRoomExitExpectedMembershipID({
    players: [{ membership_id: "private-player-generation" }],
  }), null);
});

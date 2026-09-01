import assert from "node:assert/strict";
import test from "node:test";

import {
  createGameRoomJoinMembershipID,
  gameRoomJoinPayload,
} from "./gameRoomJoin.js";

test("one join payload uses one stable generated membership generation", () => {
  let generations = 0;
  const payload = gameRoomJoinPayload({
    roomId: "room-1",
    player: { name: "Player" },
    randomUUID: () => {
      generations += 1;
      return "join-generation-1";
    },
  });

  assert.equal(generations, 1);
  assert.equal(payload.join_membership_id, "join-generation-1");
  assert.equal(payload.expected_membership_id, undefined);
});

test("rejoin payload preserves the observed membership CAS generation", () => {
  const payload = gameRoomJoinPayload({
    roomCode: "ABC123",
    player: { name: "Player" },
    joinMembershipID: "join-generation-2",
    expectedMembershipID: " membership-before-rejoin ",
  });

  assert.equal(payload.join_membership_id, "join-generation-2");
  assert.equal(payload.expected_membership_id, "membership-before-rejoin");
});

test("generated join membership IDs reject an empty generator result", () => {
  assert.throws(
    () => createGameRoomJoinMembershipID(() => " "),
    /Join membership ID is required/,
  );
});

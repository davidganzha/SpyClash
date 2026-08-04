import assert from "node:assert/strict";
import test from "node:test";

import {
  communityAttentionCount,
  createCommunityRequest,
  isExactSpyIDQuery,
  joinCommunityRoomInvite,
  relationshipForProfile,
} from "./communityProtocol.js";

test("communityAction request carries the app ID header and body token without Authorization", () => {
  const request = createCommunityRequest({
    appId: "app-123",
    accessToken: "token-456",
    functionsVersion: "v9",
  }, { action: "accept", friendship_id: "friend-1" });

  assert.equal(request.url, "/api/apps/app-123/functions/communityAction");
  assert.equal(request.init.credentials, "omit");
  assert.equal(request.init.headers["Base44-App-Id"], "app-123");
  assert.equal(request.init.headers["X-App-Id"], "app-123");
  assert.equal(request.init.headers["Base44-Functions-Version"], "v9");
  assert.equal("Authorization" in request.init.headers, false);
  assert.deepEqual(JSON.parse(request.init.body), {
    action: "accept",
    friendship_id: "friend-1",
    access_token: "token-456",
  });
});

test("community selectors count actionable items and resolve profile relationships", () => {
  const state = {
    friends: [{ id: "friend-1", profile: { id: "user-a" } }],
    incoming: [{ id: "request-1", status: "pending", profile: { id: "user-b" } }],
    outgoing: [],
    blocked: [],
    incoming_room_invites: [
      { id: "invite-1", status: "pending" },
      { id: "invite-2", status: "accepted" },
      { id: "invite-3", status: "expired" },
    ],
  };

  assert.equal(communityAttentionCount(state), 3);
  assert.equal(relationshipForProfile(state, "user-a")?.id, "friend-1");
  assert.equal(relationshipForProfile(state, "missing"), null);
  assert.equal(isExactSpyIDQuery("844-010"), true);
  assert.equal(isExactSpyIDQuery("RED RAVEN"), false);
});

test("room invitation is accepted, joined, and consumed in order", async () => {
  const calls = [];
  const result = await joinCommunityRoomInvite({
    invite: { id: "invite-1", status: "pending", room_code: "OLD111" },
    player: { name: "RAVEN", avatar: "🕵️" },
    acceptInvite: async (id) => {
      calls.push(["accept", id]);
      return { state: { incoming: [] }, room_code: "NEW222" };
    },
    joinRoom: async (input) => {
      calls.push(["join", input]);
      return { id: "room-1", code: input.roomCode };
    },
    rememberCleanup: async (id) => calls.push(["remember", id]),
    consumeInvite: async (id) => calls.push(["consume", id]),
    clearCleanup: async (id) => calls.push(["clear", id]),
  });

  assert.deepEqual(calls.map(([action]) => action), [
    "accept",
    "join",
    "remember",
    "consume",
    "clear",
  ]);
  assert.equal(calls[1][1].roomCode, "NEW222");
  assert.equal(result.room.id, "room-1");
  assert.deepEqual(result.acceptedState, { incoming: [] });
  assert.equal(result.cleanupPending, false);
});

test("failed join never consumes an accepted invitation", async () => {
  const calls = [];
  await assert.rejects(
    joinCommunityRoomInvite({
      invite: { id: "invite-1", status: "accepted", room_code: "ABC123" },
      player: { name: "RAVEN", avatar: "🕵️" },
      acceptInvite: async () => calls.push("accept"),
      joinRoom: async () => {
        calls.push("join");
        throw new Error("room unavailable");
      },
      rememberCleanup: async () => calls.push("remember"),
      consumeInvite: async () => calls.push("consume"),
      clearCleanup: async () => calls.push("clear"),
    }),
    /room unavailable/,
  );
  assert.deepEqual(calls, ["join"]);
});

test("transient consume failure preserves cleanup while allowing joined room", async () => {
  const calls = [];
  const result = await joinCommunityRoomInvite({
    invite: { id: "invite-1", status: "accepted", room_code: "ABC123" },
    player: { name: "RAVEN", avatar: "🕵️" },
    acceptInvite: async () => calls.push("accept"),
    joinRoom: async () => ({ id: "room-1" }),
    rememberCleanup: async () => calls.push("remember"),
    consumeInvite: async () => {
      calls.push("consume");
      throw Object.assign(new Error("offline"), { status: 503 });
    },
    clearCleanup: async () => calls.push("clear"),
  });

  assert.equal(result.room.id, "room-1");
  assert.equal(result.cleanupPending, true);
  assert.deepEqual(calls, ["remember", "consume"]);
});

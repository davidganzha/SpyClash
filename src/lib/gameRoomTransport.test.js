import assert from "node:assert/strict";
import test from "node:test";

import {
  dispatchGameRoomAction,
  GAME_ROOM_READ_DEADLINE_MILLISECONDS,
  gameRoomActionDeadlineMilliseconds,
  isRetryableRoomActionConflict,
} from "./gameRoomTransport.js";

test("only get_room receives the default three-second read deadline", () => {
  assert.equal(GAME_ROOM_READ_DEADLINE_MILLISECONDS, 3_000);
  assert.equal(
    gameRoomActionDeadlineMilliseconds({ action: "get_room" }),
    GAME_ROOM_READ_DEADLINE_MILLISECONDS,
  );
  assert.equal(gameRoomActionDeadlineMilliseconds({ action: "leave_room" }), null);
  assert.equal(gameRoomActionDeadlineMilliseconds({ action: "get_room" }, 25), 25);
});

test("cookie or SDK sessions invoke gameRoomAction when no storage token exists", async () => {
  const calls = [];
  const room = { id: "room-cookie", code: "COOKIE" };

  const result = await dispatchGameRoomAction({
    body: { action: "create_room" },
    accessToken: null,
    endpoint: "/unused",
    headers: {},
    invoke: async (body) => {
      calls.push(body);
      return { data: room };
    },
    request: async () => {
      throw new Error("body-token request must not run");
    },
  });

  assert.equal(result, room);
  assert.deepEqual(calls, [{ action: "create_room" }]);
});

test("stored tokens keep the provisioning-safe body-token transport", async () => {
  let requestBody = null;

  const result = await dispatchGameRoomAction({
    body: { action: "join_room", room_code: "ABC123" },
    accessToken: "token-123",
    endpoint: "/functions/gameRoomAction",
    headers: { "X-App-Id": "app-1" },
    invoke: async () => {
      throw new Error("SDK fallback must not run");
    },
    request: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({ id: "room-token" }),
      };
    },
  });

  assert.equal(result.id, "room-token");
  assert.deepEqual(requestBody, {
    action: "join_room",
    room_code: "ABC123",
    access_token: "token-123",
  });
});

test("SDK room failures preserve status and server code", async () => {
  await assert.rejects(
    dispatchGameRoomAction({
      body: { action: "create_room" },
      accessToken: null,
      endpoint: "/unused",
      headers: {},
      invoke: async () => {
        throw {
          message: "Authentication required",
          status: 401,
          data: { code: "auth_required" },
        };
      },
      request: async () => null,
    }),
    (error) => error.status === 401
      && error.code === "auth_required"
      && error.message === "Authentication required",
  );
});

test("only typed pre-action lease conflicts are retryable", () => {
  assert.equal(isRetryableRoomActionConflict({
    status: 409,
    code: "active_lease",
    retryable: true,
  }), true);
  assert.equal(isRetryableRoomActionConflict({
    status: 409,
    code: "active_lease",
    retryable: false,
  }), false);
  assert.equal(isRetryableRoomActionConflict({
    status: 409,
    code: "lobby_revision_conflict",
    retryable: true,
  }), false);
});

test("body-token failures preserve retryability metadata", async () => {
  await assert.rejects(
    dispatchGameRoomAction({
      body: { action: "mark_answer_heard" },
      accessToken: "token-123",
      endpoint: "/functions/gameRoomAction",
      headers: {},
      invoke: async () => null,
      request: async () => ({
        ok: false,
        status: 409,
        json: async () => ({
          error: "Account identity is being updated.",
          code: "active_lease",
          retryable: true,
        }),
      }),
    }),
    (error) => isRetryableRoomActionConflict(error),
  );
});

test("a hung SDK get_room call fails at its read deadline", async () => {
  await assert.rejects(
    dispatchGameRoomAction({
      body: { action: "get_room", room_id: "room-1" },
      accessToken: null,
      endpoint: "/unused",
      headers: {},
      invoke: async () => new Promise(() => {}),
      request: async () => null,
      deadlineMilliseconds: 20,
    }),
    (error) => error.status === 408
      && error.code === "room_read_timeout"
      && error.retryable === true,
  );
});

test("a hung body-token get_room request is aborted at its read deadline", async () => {
  let requestSignal = null;
  await assert.rejects(
    dispatchGameRoomAction({
      body: { action: "get_room", room_id: "room-1" },
      accessToken: "token-123",
      endpoint: "/functions/gameRoomAction",
      headers: {},
      invoke: async () => null,
      request: async (_url, options) => {
        requestSignal = options.signal;
        return new Promise(() => {});
      },
      deadlineMilliseconds: 20,
    }),
    (error) => error.status === 408
      && error.code === "room_read_timeout",
  );
  assert.equal(requestSignal?.aborted, true);
});

test("the get_room deadline also bounds a stalled response body", async () => {
  let requestSignal = null;
  await assert.rejects(
    dispatchGameRoomAction({
      body: { action: "get_room", room_id: "room-1" },
      accessToken: "token-123",
      endpoint: "/functions/gameRoomAction",
      headers: {},
      invoke: async () => null,
      request: async (_url, options) => {
        requestSignal = options.signal;
        return {
          ok: true,
          status: 200,
          json: async () => new Promise(() => {}),
        };
      },
      deadlineMilliseconds: 20,
    }),
    (error) => error.status === 408
      && error.code === "room_read_timeout",
  );
  assert.equal(requestSignal?.aborted, true);
});

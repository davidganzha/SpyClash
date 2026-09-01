import assert from "node:assert/strict";
import test from "node:test";

import {
  buildGameRoomActionHeaders,
  completeGameStartAfterIntro,
  gameDurationMinutes,
  gameDurationSeconds,
  gameTimerSnapshot,
  isAuthoritativeDetectiveVoteRefreshConflict,
  isDetectiveVoteRoundChangedConflict,
  isInactiveDetectiveVoteConflict,
  roomPollDelayMilliseconds,
  shouldRefreshForGameRoomSignal,
} from "./gameRoomSync.js";

test("room requests send both supported app-id headers", () => {
  assert.deepEqual(buildGameRoomActionHeaders({
    appId: "69a0e57fa939f578082f8091",
    functionsVersion: "preview-7",
  }), {
    "Content-Type": "application/json",
    "Base44-App-Id": "69a0e57fa939f578082f8091",
    "X-App-Id": "69a0e57fa939f578082f8091",
    "Base44-Functions-Version": "preview-7",
  });
});

test("intro completion waits for server deadline and retries an early 409", async () => {
  let now = Date.parse("2026-07-27T10:00:03.000Z");
  const sleeps = [];
  let completions = 0;
  const room = {
    id: "room-1",
    status: "roulette",
    intro_started_at: "2026-07-27T10:00:00.000Z",
  };

  const result = await completeGameStartAfterIntro({
    room,
    now: () => now,
    sleep: async (milliseconds) => {
      sleeps.push(milliseconds);
      now += milliseconds;
    },
    refreshRoom: async () => room,
    completeStart: async () => {
      completions += 1;
      if (completions === 1) {
        throw Object.assign(new Error("The game intro is still in progress."), { status: 409 });
      }
      return { ...room, status: "playing" };
    },
  });

  assert.equal(result.status, "playing");
  assert.equal(completions, 2);
  assert.equal(sleeps[0], 5_250);
  assert.equal(sleeps[1], 300);
});

test("intro completion adopts another participant's idempotent completion", async () => {
  const playing = { id: "room-1", status: "playing" };
  let completeCalls = 0;
  const result = await completeGameStartAfterIntro({
    room: {
      id: "room-1",
      status: "roulette",
      intro_started_at: "2026-07-27T10:00:00.000Z",
    },
    now: () => Date.parse("2026-07-27T10:00:09.000Z"),
    refreshRoom: async () => playing,
    completeStart: async () => {
      completeCalls += 1;
      return playing;
    },
  });

  assert.equal(result, playing);
  assert.equal(completeCalls, 0);
});

test("intro completion adopts authoritative playing state after a typed active lease", async () => {
  const roulette = {
    id: "room-1",
    status: "roulette",
    intro_started_at: "2026-07-27T10:00:00.000Z",
  };
  const playing = { ...roulette, status: "playing" };
  let refreshCalls = 0;
  let completeCalls = 0;

  const result = await completeGameStartAfterIntro({
    room: roulette,
    now: () => Date.parse("2026-07-27T10:00:09.000Z"),
    refreshRoom: async () => {
      refreshCalls += 1;
      return refreshCalls === 1 ? roulette : playing;
    },
    completeStart: async () => {
      completeCalls += 1;
      throw Object.assign(new Error("Account identity is being updated."), {
        status: 409,
        code: "active_lease",
        retryable: true,
      });
    },
  });

  assert.equal(result, playing);
  assert.equal(completeCalls, 1);
  assert.equal(refreshCalls, 2);
});

test("intro completion retries a typed CAS conflict while roulette remains authoritative", async () => {
  const roulette = {
    id: "room-1",
    status: "roulette",
    intro_started_at: "2026-07-27T10:00:00.000Z",
  };
  const sleeps = [];
  let completeCalls = 0;

  const result = await completeGameStartAfterIntro({
    room: roulette,
    now: () => Date.parse("2026-07-27T10:00:09.000Z"),
    sleep: async (milliseconds) => sleeps.push(milliseconds),
    refreshRoom: async () => roulette,
    completeStart: async () => {
      completeCalls += 1;
      if (completeCalls === 1) {
        throw Object.assign(new Error("Room write contention"), {
          status: 409,
          code: "cas_contention",
          retryable: true,
        });
      }
      return { ...roulette, status: "playing" };
    },
  });

  assert.equal(result.status, "playing");
  assert.equal(completeCalls, 2);
  assert.deepEqual(sleeps, [300]);
});

test("intro completion keeps untyped and nonretryable lease conflicts visible", async () => {
  const roulette = {
    id: "room-1",
    status: "roulette",
    intro_started_at: "2026-07-27T10:00:00.000Z",
  };
  const failures = [
    Object.assign(new Error("Untyped conflict"), { status: 409 }),
    Object.assign(new Error("Nonretryable lease"), {
      status: 409,
      code: "active_lease",
      retryable: false,
    }),
  ];

  for (const failure of failures) {
    await assert.rejects(
      completeGameStartAfterIntro({
        room: roulette,
        now: () => Date.parse("2026-07-27T10:00:09.000Z"),
        refreshRoom: async () => roulette,
        completeStart: async () => { throw failure; },
      }),
      (error) => error === failure,
    );
  }
});

test("timer freezes on pause and subtracts accumulated pause after resume", () => {
  const baseRoom = {
    game_started_at: "2026-07-27T10:00:00.000Z",
    game_duration_seconds: 600,
    game_paused_total_seconds: 20,
  };
  const paused = gameTimerSnapshot({
    ...baseRoom,
    game_paused_at: "2026-07-27T10:02:00.000Z",
  }, Date.parse("2026-07-27T10:05:00.000Z"));
  assert.equal(paused.paused, true);
  assert.equal(paused.elapsedSeconds, 100);
  assert.equal(paused.remainingSeconds, 500);

  const resumed = gameTimerSnapshot({
    ...baseRoom,
    game_paused_at: null,
    game_paused_total_seconds: 200,
  }, Date.parse("2026-07-27T10:05:00.000Z"));
  assert.equal(resumed.paused, false);
  assert.equal(resumed.elapsedSeconds, 100);
  assert.equal(resumed.remainingSeconds, 500);
});

test("timer clamps at zero without creating a post-game guess phase", () => {
  const snapshot = gameTimerSnapshot({
    game_started_at: "2026-07-27T10:00:00.000Z",
    game_duration_seconds: 60,
    game_paused_at: null,
    game_paused_total_seconds: 30,
  }, Date.parse("2026-07-27T10:01:40.000Z"));

  assert.equal(snapshot.elapsedSeconds, 70);
  assert.equal(snapshot.remainingSeconds, 0);
  assert.equal("guessRemainingSeconds" in snapshot, false);
});

test("only the exact typed inactive detective-vote conflict is reconciled", () => {
  const inactiveVote = {
    status: 409,
    code: "detective_vote_inactive",
  };

  assert.equal(
    isInactiveDetectiveVoteConflict("cast_detective_vote", inactiveVote),
    true,
  );

  const visibleFailures = [
    ["cast_detective_vote", { status: 409 }],
    ["cast_detective_vote", { status: 409, code: "cas_contention" }],
    ["cast_detective_vote", { status: 409, code: "DETECTIVE_VOTE_INACTIVE" }],
    ["cast_detective_vote", { status: 400, code: "detective_vote_inactive" }],
    ["request_vote", inactiveVote],
  ];

  for (const [action, error] of visibleFailures) {
    assert.equal(isInactiveDetectiveVoteConflict(action, error), false);
  }
});

test("only an exact cast round-change conflict is silently refreshed", () => {
  const changed = { status: 409, code: "detective_vote_round_changed" };
  assert.equal(
    isDetectiveVoteRoundChangedConflict("cast_detective_vote", changed),
    true,
  );
  for (const [action, error] of [
    ["request_vote", changed],
    ["cast_detective_vote", { ...changed, status: 400 }],
    ["cast_detective_vote", { ...changed, code: "active_lease" }],
    ["cast_detective_vote", { status: 409 }],
  ]) {
    assert.equal(isDetectiveVoteRoundChangedConflict(action, error), false);
  }
});

test("post-retry inactive and round-change conflicts both refresh authoritatively", () => {
  for (const code of ["detective_vote_inactive", "detective_vote_round_changed"]) {
    assert.equal(
      isAuthoritativeDetectiveVoteRefreshConflict("cast_detective_vote", {
        status: 409,
        code,
      }),
      true,
    );
  }
  assert.equal(
    isAuthoritativeDetectiveVoteRefreshConflict("cast_detective_vote", {
      status: 409,
      code: "active_lease",
      retryable: true,
    }),
    false,
  );
});

test("duration helpers enforce the shared one-to-fifteen minute contract", () => {
  assert.equal(gameDurationMinutes({ game_duration_seconds: 720 }), 12);
  assert.equal(gameDurationMinutes({ game_duration_seconds: 12 }, 10), 10);
  assert.equal(gameDurationSeconds(0), 60);
  assert.equal(gameDurationSeconds(12), 720);
  assert.equal(gameDurationSeconds(99), 900);
});

test("room polling uses bounded backoff and slows down in the background", () => {
  assert.equal(roomPollDelayMilliseconds({ consecutiveFailures: 0 }), 2_000);
  assert.equal(roomPollDelayMilliseconds({ consecutiveFailures: 1 }), 4_000);
  assert.equal(roomPollDelayMilliseconds({ consecutiveFailures: 2 }), 8_000);
  assert.equal(roomPollDelayMilliseconds({ consecutiveFailures: 20 }), 30_000);
  assert.equal(roomPollDelayMilliseconds({ consecutiveFailures: 0, hidden: true }), 20_000);
});

test("room realtime wakeups are scoped to the current room and participant", () => {
  const expected = { roomId: "room-1", userId: "user-1" };
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: { room_id: "room-1", user_id: "user-1", state: "active" },
  }, expected), true);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "create",
    data: { room_id: "room-2", user_id: "user-1", state: "active" },
  }, expected), false);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: { room_id: "room-1", user_id: "user-2", state: "active" },
  }, expected), false);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "delete",
    data: { room_id: "room-1", user_id: "user-1", state: "closed" },
  }, expected), false);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      room_revision: 14,
      state: "active",
    },
  }, { ...expected, currentRoomRevision: 14 }), false);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      room_revision: 15,
      state: "active",
    },
  }, { ...expected, currentRoomRevision: 14 }), true);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      room_revision: 13,
      state: "closed",
    },
  }, { ...expected, currentRoomRevision: 14 }), false);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      room_revision: 14,
      state: "closed",
    },
  }, { ...expected, currentRoomRevision: 14 }), true);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      room_revision: 15,
      state: "closed",
    },
  }, { ...expected, currentRoomRevision: 14 }), true);
  assert.equal(shouldRefreshForGameRoomSignal({
    type: "update",
    data: {
      room_id: "room-1",
      user_id: "user-1",
      state: "closed",
    },
  }, { ...expected, currentRoomRevision: 14 }), false);
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  createExpiredRoomFinalizer,
  expiredRoomFinalizeRetryDelayMilliseconds,
  finalizeExpiredRoomWithBackoff,
  isRetryableExpiredRoomFinalizeError,
} from "./expiredRoomFinalizer.js";

const actor = "actor@example.com";
const expiredAt = "2026-08-30T12:00:00.000Z";
const nowMilliseconds = Date.parse("2026-08-30T12:10:01.000Z");

function room(patch = {}) {
  return {
    id: "room-1",
    match_id: "match-1",
    room_revision: 10,
    status: "playing",
    winner: "",
    players: [{ email: actor }, { email: "second@example.com" }],
    game_started_at: expiredAt,
    game_duration_seconds: 600,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    ...patch,
  };
}

function retryable(status = 409, code = "active_lease") {
  return Object.assign(new Error(code), {
    status,
    code,
    retryable: true,
  });
}

function input(patch = {}) {
  const finished = room({
    room_revision: 11,
    status: "finished",
    winner: "spy",
  });
  return {
    room: room(),
    actorEmail: actor,
    currentRoom: () => room(),
    refreshRoom: async () => room(),
    finalizeRoom: async () => finished,
    acceptRoom: () => {},
    now: () => nowMilliseconds,
    sleep: async () => {},
    random: () => 0.5,
    ...patch,
  };
}

test("component finalizer keeps one in-flight bounded run per match", async () => {
  const controller = createExpiredRoomFinalizer();
  let releases;
  let calls = 0;
  const pending = new Promise((resolve) => { releases = resolve; });
  const scoped = input({
    finalizeRoom: async () => {
      calls += 1;
      await pending;
      return room({ status: "finished", winner: "detectives" });
    },
  });

  const first = controller.run(scoped);
  const second = controller.run(scoped);
  assert.equal(first, second);
  assert.equal(calls, 1);
  releases();
  const finished = await first;
  const afterFinish = await controller.run({
    ...scoped,
    room: finished,
  });
  assert.equal(afterFinish, finished);
  assert.equal(calls, 1);
});

test("a retry waits, reads authoritative state, and never sends a second write when finished", async () => {
  const sleeps = [];
  const accepted = [];
  let finalizations = 0;
  let refreshes = 0;
  const finished = room({ room_revision: 12, status: "finished", winner: "spy" });
  const result = await finalizeExpiredRoomWithBackoff(input({
    finalizeRoom: async () => {
      finalizations += 1;
      throw retryable();
    },
    refreshRoom: async () => {
      refreshes += 1;
      return finished;
    },
    acceptRoom: (value) => accepted.push(value),
    sleep: async (milliseconds) => sleeps.push(milliseconds),
  }));

  assert.equal(result, finished);
  assert.equal(finalizations, 1);
  assert.equal(refreshes, 1);
  assert.deepEqual(sleeps, [1_000]);
  assert.deepEqual(accepted, [finished]);
});

test("typed lease failures retry with bounded exponential delays and a confirming read", async () => {
  const sleeps = [];
  let finalizations = 0;
  let refreshes = 0;
  const failure = retryable(503, "lifecycle_unavailable");
  await assert.rejects(
    finalizeExpiredRoomWithBackoff(input({
      maxAttempts: 99,
      finalizeRoom: async () => {
        finalizations += 1;
        throw failure;
      },
      refreshRoom: async () => {
        refreshes += 1;
        return room();
      },
      sleep: async (milliseconds) => sleeps.push(milliseconds),
    })),
    (error) => error === failure,
  );

  assert.equal(finalizations, 6);
  assert.equal(refreshes, 5);
  assert.deepEqual(sleeps, [1_000, 2_000, 4_000, 8_000, 8_000]);
});

test("a local realtime finish cancels the pending retry without another read or write", async () => {
  let current = room();
  let finalizations = 0;
  let refreshes = 0;
  const result = await finalizeExpiredRoomWithBackoff(input({
    currentRoom: () => current,
    finalizeRoom: async () => {
      finalizations += 1;
      throw retryable();
    },
    refreshRoom: async () => {
      refreshes += 1;
      return room();
    },
    sleep: async () => {
      current = room({ status: "finished", winner: "detectives" });
    },
  }));

  assert.equal(result, current);
  assert.equal(finalizations, 1);
  assert.equal(refreshes, 0);
});

test("a changed match or resumed timer is never finalized from the stale match", async () => {
  for (const authoritative of [
    room({ match_id: "match-2" }),
    room({ game_started_at: "2026-08-30T12:09:59.000Z" }),
  ]) {
    let finalizations = 0;
    const result = await finalizeExpiredRoomWithBackoff(input({
      currentRoom: () => authoritative,
      finalizeRoom: async () => {
        finalizations += 1;
        throw retryable();
      },
    }));
    assert.equal(result, authoritative);
    assert.equal(finalizations, 0);
  }
});

test("a paused no-op does not poison the match and resume can finalize later", async () => {
  const controller = createExpiredRoomFinalizer();
  const paused = room({ game_paused_at: "2026-08-30T12:10:00.000Z" });
  let current = paused;
  let finalizations = 0;
  const scoped = input({
    room: paused,
    currentRoom: () => current,
    finalizeRoom: async () => {
      finalizations += 1;
      return room({ status: "finished", winner: "spy" });
    },
  });

  assert.equal(await controller.run(scoped), paused);
  current = room();
  const result = await controller.run({ ...scoped, room: current });
  assert.equal(result.status, "finished");
  assert.equal(finalizations, 1);
});

test("exhaustion performs one delayed read-confirmed recovery round", async () => {
  const controller = createExpiredRoomFinalizer();
  const failure = retryable(503, "lifecycle_unavailable");
  let finalizations = 0;
  let refreshes = 0;
  const sleeps = [];
  const scoped = input({
    maxAttempts: 1,
    finalizeRoom: async () => {
      finalizations += 1;
      if (finalizations === 1) throw failure;
      return room({ status: "finished", winner: "detectives" });
    },
    refreshRoom: async () => {
      refreshes += 1;
      return room();
    },
    sleep: async (milliseconds) => sleeps.push(milliseconds),
  });

  const recovered = await controller.run(scoped);
  assert.equal(recovered.status, "finished");
  assert.equal(finalizations, 2);
  assert.equal(refreshes, 1);
  assert.deepEqual(sleeps, [30_000]);
});

test("legacy room scope cannot cross into a replacement match", async () => {
  const legacy = room({ match_id: "", game_started_at: expiredAt });
  const replacement = room({ match_id: "match-2", game_started_at: expiredAt });
  let finalizations = 0;
  const result = await finalizeExpiredRoomWithBackoff(input({
    room: legacy,
    currentRoom: () => replacement,
    finalizeRoom: async () => {
      finalizations += 1;
      return room({ status: "finished", winner: "spy" });
    },
  }));
  assert.equal(result, replacement);
  assert.equal(finalizations, 0);
});

test("disposing a controller aborts pending backoff and prevents later writes", async () => {
  const controller = createExpiredRoomFinalizer();
  let finalizations = 0;
  const pending = controller.run(input({
    finalizeRoom: async () => {
      finalizations += 1;
      throw retryable();
    },
    sleep: undefined,
  }));

  await Promise.resolve();
  controller.dispose();
  await assert.rejects(pending, (error) => error?.name === "AbortError");
  assert.equal(finalizations, 1);
});

test("every finalization write carries the immutable match identity", async () => {
  const payloads = [];
  await finalizeExpiredRoomWithBackoff(input({
    finalizeRoom: async (roomID, expectedScope) => {
      payloads.push({ roomID, expectedScope });
      return room({ status: "finished", winner: "spy" });
    },
  }));
  await finalizeExpiredRoomWithBackoff(input({
    room: room({ match_id: "", game_started_at: expiredAt }),
    currentRoom: () => room({ match_id: "", game_started_at: expiredAt }),
    finalizeRoom: async (roomID, expectedScope) => {
      payloads.push({ roomID, expectedScope });
      return room({
        match_id: "",
        game_started_at: expiredAt,
        status: "finished",
        winner: "detectives",
      });
    },
  }));

  assert.deepEqual(payloads, [
    {
      roomID: "room-1",
      expectedScope: {
        expected_match_id: "match-1",
        expected_game_started_at: undefined,
      },
    },
    {
      roomID: "room-1",
      expectedScope: {
        expected_match_id: undefined,
        expected_game_started_at: expiredAt,
      },
    },
  ]);
});

test("only typed lifecycle conflicts and transient transport statuses are retried", () => {
  assert.equal(isRetryableExpiredRoomFinalizeError(retryable()), true);
  assert.equal(isRetryableExpiredRoomFinalizeError(retryable(429, "rate_limit")), true);
  assert.equal(isRetryableExpiredRoomFinalizeError(retryable(503, "unavailable")), true);
  assert.equal(isRetryableExpiredRoomFinalizeError({ status: 409, code: "active_lease" }), false);
  assert.equal(isRetryableExpiredRoomFinalizeError({ status: 400 }), false);
});

test("retry jitter stays bounded around the capped exponential schedule", () => {
  assert.equal(expiredRoomFinalizeRetryDelayMilliseconds(0, () => 0), 750);
  assert.equal(expiredRoomFinalizeRetryDelayMilliseconds(0, () => 1), 1_250);
  assert.equal(expiredRoomFinalizeRetryDelayMilliseconds(9, () => 0.5), 8_000);
});

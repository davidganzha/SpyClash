import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertGameActionAllowedByDeadline,
  assertGameActionAllowedWhilePaused,
  finishGamePauseTransitionPatch,
  gameActiveElapsedSeconds,
  gameTimerDeadlineMilliseconds,
  hasGameTimerElapsed,
  PAUSE_BLOCKED_GAME_ACTIONS,
  pauseGameTransitionPatch,
  resumeGameTransitionPatch,
} from "./game-timer-policy.ts";

function playingRoom(overrides: Record<string, unknown> = {}) {
  return {
    status: "playing",
    host_email: "host@example.com",
    game_started_at: "2026-07-21T12:00:00.000Z",
    game_duration_seconds: 60,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    ...overrides,
  };
}

function errorCode(error: Error): string | undefined {
  return (error as Error & { code?: string }).code;
}

Deno.test("host pause and resume are idempotent and accumulate once", () => {
  const room = playingRoom();
  const pause = pauseGameTransitionPatch(
    room,
    "HOST@example.com",
    "2026-07-21T12:00:20.000Z",
  );
  assertEquals(pause, {
    game_paused_at: "2026-07-21T12:00:20.000Z",
  });

  const paused = { ...room, ...pause };
  assertEquals(
    pauseGameTransitionPatch(
      paused,
      "host@example.com",
      "2026-07-21T12:00:40.000Z",
    ),
    {},
  );

  const resume = resumeGameTransitionPatch(
    paused,
    "host@example.com",
    "2026-07-21T12:00:50.000Z",
  );
  assertEquals(resume, {
    game_paused_at: null,
    game_paused_total_seconds: 30,
  });

  const resumed = { ...paused, ...resume };
  assertEquals(
    resumeGameTransitionPatch(
      resumed,
      "host@example.com",
      "2026-07-21T12:01:10.000Z",
    ),
    {},
  );
  assertEquals(
    gameActiveElapsedSeconds(
      resumed,
      Date.parse("2026-07-21T12:01:20.000Z"),
    ),
    50,
  );
});

Deno.test("pause policy is host-only and requires a live timer", () => {
  const forbidden = assertThrows(
    () =>
      pauseGameTransitionPatch(
        playingRoom(),
        "detective@example.com",
        "2026-07-21T12:00:20.000Z",
      ),
    Error,
    "Host access required",
  );
  assertEquals(errorCode(forbidden), "host_access_required");

  const forbiddenResume = assertThrows(
    () =>
      resumeGameTransitionPatch(
        playingRoom({
          game_paused_at: "2026-07-21T12:00:20.000Z",
        }),
        "detective@example.com",
        "2026-07-21T12:00:30.000Z",
      ),
    Error,
    "Host access required",
  );
  assertEquals(errorCode(forbiddenResume), "host_access_required");

  const inactive = assertThrows(
    () =>
      pauseGameTransitionPatch(
        playingRoom({ game_started_at: null }),
        "host@example.com",
        "2026-07-21T12:00:20.000Z",
      ),
    Error,
    "start timestamp",
  );
  assertEquals(errorCode(inactive), "invalid_game_timer");

  const elapsed = assertThrows(
    () =>
      pauseGameTransitionPatch(
        playingRoom(),
        "host@example.com",
        "2026-07-21T12:01:00.000Z",
      ),
    Error,
    "already elapsed",
  );
  assertEquals(errorCode(elapsed), "game_timer_elapsed");
});

Deno.test("active pause freezes elapsed time and extends the deadline", () => {
  const paused = playingRoom({
    game_paused_at: "2026-07-21T12:00:20.000Z",
    game_paused_total_seconds: 10,
  });
  const now = Date.parse("2026-07-21T12:01:40.000Z");
  assertEquals(gameActiveElapsedSeconds(paused, now), 10);
  assertEquals(
    gameTimerDeadlineMilliseconds(paused, now, 30),
    Date.parse("2026-07-21T12:03:00.000Z"),
  );
});

Deno.test("resume and finish use the same integer pause floor rule", () => {
  const paused = playingRoom({
    game_paused_at: "2026-07-21T12:00:20.000Z",
    game_paused_total_seconds: 4,
  });
  assertEquals(
    resumeGameTransitionPatch(
      paused,
      "host@example.com",
      "2026-07-21T12:00:30.600Z",
    ).game_paused_total_seconds,
    14,
  );
  assertEquals(
    finishGamePauseTransitionPatch(
      paused,
      "2026-07-21T12:00:30.600Z",
    ),
    { game_paused_at: null, game_paused_total_seconds: 14 },
  );
});

Deno.test("paused room blocks every gameplay mutation but not recovery", () => {
  const paused = playingRoom({
    game_paused_at: "2026-07-21T12:00:20.000Z",
  });
  for (const action of PAUSE_BLOCKED_GAME_ACTIONS) {
    const error = assertThrows(
      () => assertGameActionAllowedWhilePaused(paused, action),
      Error,
      "game is paused",
    );
    assertEquals(errorCode(error), "game_paused");
  }

  for (
    const action of [
      "pause_game",
      "resume_game",
      "leave_room",
      "finalize_expired_room",
      "finish_room",
    ]
  ) {
    assertEquals(assertGameActionAllowedWhilePaused(paused, action), undefined);
  }
  for (const action of PAUSE_BLOCKED_GAME_ACTIONS) {
    assertEquals(
      assertGameActionAllowedWhilePaused(playingRoom(), action),
      undefined,
    );
  }
});

Deno.test("the exact 0:00 boundary closes every gameplay action immediately", () => {
  const room = playingRoom();
  const beforeDeadline = Date.parse("2026-07-21T12:00:59.999Z");
  const deadline = Date.parse("2026-07-21T12:01:00.000Z");

  assertEquals(hasGameTimerElapsed(room, beforeDeadline), false);
  assertEquals(hasGameTimerElapsed(room, deadline), true);

  for (
    const action of ["request_vote", "cast_detective_vote", "submit_spy_guess"]
  ) {
    assertEquals(
      assertGameActionAllowedByDeadline(room, action, beforeDeadline),
      undefined,
    );
  }
  for (const action of ["finalize_expired_room", "finish_room", "leave_room"]) {
    assertEquals(
      assertGameActionAllowedByDeadline(room, action, deadline),
      undefined,
    );
  }

  for (
    const action of [
      "advance_question",
      "request_vote",
      "cast_detective_vote",
      "submit_spy_guess",
    ]
  ) {
    const error = assertThrows(
      () => assertGameActionAllowedByDeadline(room, action, deadline),
      Error,
      "timer has elapsed",
    );
    assertEquals(errorCode(error), "game_timer_elapsed");
  }
});

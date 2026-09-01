import {
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createTerminalPhaseTiming,
  spyGuessResponseTiming,
} from "./terminal-timing.ts";

Deno.test("terminal timing reports every completed phase without identity fields", () => {
  let now = 100;
  const timing = createTerminalPhaseTiming(() => now);

  now = 110;
  timing.begin("terminal_claim");
  now = 125;
  timing.complete("terminal_claim");
  now = 130;
  timing.begin("push_enqueue");
  now = 150;
  timing.complete("push_enqueue");
  now = 155;
  timing.begin("history_archive");
  now = 185;
  timing.complete("history_archive");
  now = 190;
  timing.begin("room_commit");
  now = 230;
  timing.complete("room_commit");
  now = 235;
  timing.begin("push_commit");
  now = 285;
  timing.complete("push_commit");
  now = 300;

  const report = timing.report("completed", 4);
  assertEquals(report, {
    terminal_claim_ms: 15,
    push_enqueue_ms: 20,
    history_archive_ms: 30,
    room_commit_ms: 40,
    push_commit_ms: 50,
    total_ms: 200,
    player_count: 4,
    outcome: "completed",
    failed_phase: "",
  });
  for (const forbidden of ["room_id", "user_id", "email", "spy_guess"]) {
    assertFalse(JSON.stringify(report).includes(forbidden));
  }
});

Deno.test("terminal timing preserves the active failed phase", () => {
  let now = 0;
  const timing = createTerminalPhaseTiming(() => now);
  now = 1;
  timing.begin("terminal_claim");
  now = 6;
  timing.complete("terminal_claim");
  now = 7;
  timing.begin("push_enqueue");
  now = 17;

  assertEquals(timing.report("failed", 3), {
    terminal_claim_ms: 5,
    push_enqueue_ms: 10,
    history_archive_ms: 0,
    room_commit_ms: 0,
    push_commit_ms: 0,
    total_ms: 17,
    player_count: 3,
    outcome: "failed",
    failed_phase: "push_enqueue",
  });
});

Deno.test("spy guess response timing includes work before the action", () => {
  const report = spyGuessResponseTiming({
    requestStartedAt: 10,
    actionStartedAt: 130,
    actionCompletedAt: 360,
    responseReadyAt: 430,
    postCommitSideEffectsMS: 70,
    outcome: "completed",
  });

  assertEquals(report, {
    pre_action_ms: 120,
    action_core_ms: 230,
    post_commit_side_effects_ms: 70,
    total_ms: 420,
    outcome: "completed",
  });
  assertEquals(Object.keys(report), [
    "pre_action_ms",
    "action_core_ms",
    "post_commit_side_effects_ms",
    "total_ms",
    "outcome",
  ]);
});

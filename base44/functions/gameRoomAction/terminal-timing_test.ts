import {
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createOpaqueTimingID,
  createSpyGuessSideEffectTiming,
  createTerminalPhaseTiming,
  normalizeOpaqueTimingID,
  spyGuessResponseTiming,
} from "./terminal-timing.ts";

const timingID = "123e4567-e89b-42d3-a456-426614174000";

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
    timingID,
    requestStartedAt: 10,
    actionStartedAt: 130,
    actionCompletedAt: 360,
    responseReadyAt: 430,
    postCommitSideEffectsMS: 70,
    sideEffects: {
      profile_repair_ms: 12,
      push_function_invoke_ms: 44,
      signal_fanout_ms: 8,
    },
    outcome: "completed",
  });

  assertEquals(report, {
    timing_id: timingID,
    pre_action_ms: 120,
    action_core_ms: 230,
    profile_repair_ms: 12,
    push_function_invoke_ms: 44,
    signal_fanout_ms: 8,
    post_commit_side_effects_ms: 70,
    total_ms: 420,
    outcome: "completed",
  });
  assertEquals(Object.keys(report), [
    "timing_id",
    "pre_action_ms",
    "action_core_ms",
    "profile_repair_ms",
    "push_function_invoke_ms",
    "signal_fanout_ms",
    "post_commit_side_effects_ms",
    "total_ms",
    "outcome",
  ]);
});

Deno.test("opaque timing ids are generated and normalized without accepting content", () => {
  assertEquals(createOpaqueTimingID(() => timingID.toUpperCase()), timingID);
  assertEquals(
    normalizeOpaqueTimingID(` ${timingID.toUpperCase()} `),
    timingID,
  );
  assertEquals(normalizeOpaqueTimingID("room-123:user@example.com"), "");
  assertEquals(createOpaqueTimingID(() => "guess-content"), "");
  assertEquals(
    createOpaqueTimingID(() => {
      throw new Error("random source unavailable");
    }),
    "",
  );
});

Deno.test("spy guess side-effect timing accumulates only allowlisted phases", () => {
  let now = 0;
  const timing = createSpyGuessSideEffectTiming(() => now);
  timing.begin("profile_repair");
  now = 11;
  timing.complete("profile_repair");
  timing.begin("push_function_invoke");
  now = 36;
  timing.complete("push_function_invoke");
  timing.begin("signal_fanout");
  now = 43;
  timing.complete("signal_fanout");

  assertEquals(timing.snapshot(), {
    profile_repair_ms: 11,
    push_function_invoke_ms: 25,
    signal_fanout_ms: 7,
  });
});

Deno.test("terminal and response reports share only the opaque correlation id", () => {
  let now = 0;
  const terminal = createTerminalPhaseTiming(() => now);
  now = 5;
  const terminalReport = terminal.report("completed", 2, timingID);
  const responseReport = spyGuessResponseTiming({
    timingID,
    requestStartedAt: 0,
    actionStartedAt: 1,
    actionCompletedAt: 3,
    responseReadyAt: 5,
    postCommitSideEffectsMS: 2,
    outcome: "completed",
  });

  assertEquals(terminalReport.timing_id, responseReport.timing_id);
  const allowedTerminalFields = new Set([
    "timing_id",
    "terminal_claim_ms",
    "push_enqueue_ms",
    "history_archive_ms",
    "room_commit_ms",
    "push_commit_ms",
    "total_ms",
    "player_count",
    "outcome",
    "failed_phase",
  ]);
  const allowedResponseFields = new Set([
    "timing_id",
    "pre_action_ms",
    "action_core_ms",
    "profile_repair_ms",
    "push_function_invoke_ms",
    "signal_fanout_ms",
    "post_commit_side_effects_ms",
    "total_ms",
    "outcome",
  ]);
  assertEquals(
    Object.keys(terminalReport).every((field) =>
      allowedTerminalFields.has(field)
    ),
    true,
  );
  assertEquals(
    Object.keys(responseReport).every((field) =>
      allowedResponseFields.has(field)
    ),
    true,
  );
});

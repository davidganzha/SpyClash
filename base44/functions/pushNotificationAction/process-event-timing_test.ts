import {
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createProcessEventTiming,
  normalizeProcessEventTimingID,
} from "./process-event-timing.ts";

const timingID = "123e4567-e89b-42d3-a456-426614174000";

Deno.test("process-event timing separates ActivityKit from ordinary push", () => {
  let now = 100;
  const timing = createProcessEventTiming(timingID, () => now);
  now = 110;
  timing.begin("live_activity");
  now = 145;
  timing.complete("live_activity");
  now = 150;
  timing.begin("ordinary_push");
  now = 210;
  timing.complete("ordinary_push");
  now = 220;

  assertEquals(timing.report("completed"), {
    timing_id: timingID,
    live_activity_ms: 35,
    ordinary_push_ms: 60,
    total_ms: 120,
    outcome: "completed",
    failed_phase: "",
  });
});

Deno.test("invalid or missing process-event timing ids are inert", () => {
  assertEquals(normalizeProcessEventTimingID(undefined), "");
  assertEquals(normalizeProcessEventTimingID("room:user:guess"), "");
  assertEquals(createProcessEventTiming("not-a-uuid").timingID, "");
});

Deno.test("process-event timing has a strict privacy field allowlist", () => {
  let now = 0;
  const timing = createProcessEventTiming(timingID, () => now);
  timing.begin("live_activity");
  now = 8;
  const report = timing.report("failed");

  assertEquals(Object.keys(report), [
    "timing_id",
    "live_activity_ms",
    "ordinary_push_ms",
    "total_ms",
    "outcome",
    "failed_phase",
  ]);
  assertEquals(report.failed_phase, "live_activity");
  for (
    const forbidden of [
      "room_id",
      "match_id",
      "source_event_id",
      "user_id",
      "email",
      "guess",
      "token",
    ]
  ) {
    assertFalse(Object.prototype.hasOwnProperty.call(report, forbidden));
  }
});

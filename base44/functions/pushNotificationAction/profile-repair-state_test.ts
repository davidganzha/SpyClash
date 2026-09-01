import { assertEquals } from "jsr:@std/assert@1";
import { finishedProfileRepairAlreadyCompleted } from "./profile-repair-state.ts";

function completedRoom(overrides: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    status: "finished",
    match_id: "match-1",
    game_finished_event_id: "game-finished:match-1",
    replay_source_match_id: "",
    terminal_intent: {
      match_id: "match-1",
      profile_side_effect_dispatch: {
        event_id: "game-finished:match-1",
        state: "completed",
      },
    },
    ...overrides,
  };
}

Deno.test("completed profile repair for the current finished match is reusable", () => {
  assertEquals(finishedProfileRepairAlreadyCompleted(completedRoom()), true);
});

Deno.test("incomplete or missing profile repair is not reusable", () => {
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({
      terminal_intent: {
        match_id: "match-1",
        profile_side_effect_dispatch: {
          event_id: "game-finished:match-1",
          state: "processing",
        },
      },
    })),
    false,
  );
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({
      terminal_intent: { match_id: "match-1" },
    })),
    false,
  );
});

Deno.test("stale event or different terminal match cannot skip repair", () => {
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({
      terminal_intent: {
        match_id: "match-1",
        profile_side_effect_dispatch: {
          event_id: "game-finished:match-old",
          state: "completed",
        },
      },
    })),
    false,
  );
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({
      terminal_intent: {
        match_id: "match-old",
        profile_side_effect_dispatch: {
          event_id: "game-finished:match-1",
          state: "completed",
        },
      },
    })),
    false,
  );
});

Deno.test("non-finished, replayed, and legacy blank-match rooms retain repair", () => {
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({ status: "playing" })),
    false,
  );
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({
      status: "waiting",
      replay_source_match_id: "match-1",
    })),
    false,
  );
  assertEquals(
    finishedProfileRepairAlreadyCompleted(completedRoom({ match_id: "" })),
    false,
  );
});

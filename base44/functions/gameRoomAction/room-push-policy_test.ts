import { assertEquals } from "jsr:@std/assert@1";
import { shouldSynchronizeLiveActivity } from "./room-push-policy.ts";

Deno.test("rapid round actions never wait for Live Activity delivery", () => {
  const room = { match_id: "match-1", status: "playing" };

  for (
    const action of [
      "mark_answer_heard",
      "advance_question",
      "start_association",
      "advance_association",
      "stop_association_spin",
      "continue_round",
      "request_vote",
      "cast_detective_vote",
      "pause_game",
      "resume_game",
    ]
  ) {
    assertEquals(
      shouldSynchronizeLiveActivity(action, room),
      false,
      `${action} must return without waiting for APNs`,
    );
  }
});

Deno.test("game lifecycle boundaries still synchronize Live Activities", () => {
  assertEquals(
    shouldSynchronizeLiveActivity("complete_game_start", {
      match_id: "match-1",
      status: "playing",
    }),
    true,
  );
  assertEquals(
    shouldSynchronizeLiveActivity("submit_spy_guess", {
      match_id: "match-1",
      status: "finished",
    }),
    true,
  );
});

Deno.test("Live Activity synchronization requires a persisted match", () => {
  assertEquals(
    shouldSynchronizeLiveActivity("complete_game_start", {
      status: "playing",
    }),
    false,
  );
  assertEquals(
    shouldSynchronizeLiveActivity("mark_answer_heard", {
      match_id: "match-1",
      status: "playing",
    }),
    false,
  );
});

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { assertExpectedTimerFinalizationScope } from "./terminal-finalization-scope.ts";

const room = {
  id: "room-1",
  match_id: "match-1",
  game_started_at: "2026-08-31T08:00:00.000Z",
};

Deno.test("match finalization requires the exact client-read generation", () => {
  assertExpectedTimerFinalizationScope(room, {
    expected_match_id: "match-1",
  });
  assertExpectedTimerFinalizationScope(room, {
    expected_match_id: "match-1",
    expected_game_started_at: room.game_started_at,
  });
});

Deno.test("legacy finalization binds the exact start identity and cannot cross into a new match", async () => {
  assertExpectedTimerFinalizationScope({ ...room, match_id: "" }, {
    expected_game_started_at: room.game_started_at,
  });
  const error = await assertRejects(
    async () =>
      assertExpectedTimerFinalizationScope(room, {
        expected_game_started_at: room.game_started_at,
      }),
    Error,
  );
  assertEquals((error as any).code, "finalization_scope_changed");
  assertEquals((error as any).retryable, false);
});

Deno.test("a reset between authoritative read and write fails closed", async () => {
  for (
    const expected of [
      { expected_match_id: "match-old" },
      {
        expected_match_id: "match-1",
        expected_game_started_at: "2026-08-31T07:00:00.000Z",
      },
    ]
  ) {
    const error = await assertRejects(
      async () => assertExpectedTimerFinalizationScope(room, expected),
      Error,
    );
    assertEquals((error as any).status, 409);
    assertEquals((error as any).code, "finalization_scope_changed");
  }
});

Deno.test("legacy clients remain compatible during the rolling upgrade", () => {
  assertExpectedTimerFinalizationScope(room, {});
});

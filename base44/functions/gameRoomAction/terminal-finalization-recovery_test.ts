import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { reconcileTerminalFinalizationAfterLeaseConflict } from "./terminal-finalization-recovery.ts";

function conflict(code = "active_lease", retryable = true) {
  return Object.assign(new Error(code), { code, retryable });
}

Deno.test("a competing finalizer returns the committed terminal room without another write", async () => {
  const rooms = [
    { id: "room-1", status: "playing", terminal_intent: null },
    { id: "room-1", status: "playing", terminal_intent: { winner: "spy" } },
    {
      id: "room-1",
      status: "finished",
      winner: "spy",
      game_finished_event_id: "game-finished:match-1",
    },
  ];
  const delays: number[] = [];
  let reads = 0;
  let validations = 0;
  const result = await reconcileTerminalFinalizationAfterLeaseConflict({
    action: "finalize_expired_room",
    error: conflict(),
    refetch: async () => rooms[reads++] || rooms.at(-1)!,
    validate: () => validations += 1,
    delay: async (milliseconds) => {
      delays.push(milliseconds);
    },
  });

  assertEquals(result.status, "finished");
  assertEquals(reads, 3);
  assertEquals(validations, 3);
  assertEquals(delays, [80, 200, 420]);
});

Deno.test("non-finalizers and non-retryable lifecycle conflicts never reconcile", async () => {
  for (
    const [action, error] of [
      ["pause_game", conflict()],
      ["finalize_expired_room", conflict("deletion_in_progress", false)],
    ] as const
  ) {
    let reads = 0;
    await assertRejects(
      () =>
        reconcileTerminalFinalizationAfterLeaseConflict({
          action,
          error,
          refetch: async () => {
            reads += 1;
            return { id: "room-1", status: "finished" };
          },
          validate: () => {},
          delay: async () => {},
        }),
      Error,
      error.message,
    );
    assertEquals(reads, 0);
  }
});

Deno.test("an unrelated active lease remains the original typed conflict", async () => {
  const original = conflict("cas_contention");
  let reads = 0;
  const error = await assertRejects(
    () =>
      reconcileTerminalFinalizationAfterLeaseConflict({
        action: "finish_room",
        error: original,
        refetch: async () => {
          reads += 1;
          return { id: "room-1", status: "playing" };
        },
        validate: () => {},
        delay: async () => {},
        retryDelays: [1, 2],
      }),
    Error,
  );
  assertEquals(error, original);
  assertEquals(reads, 2);
});

Deno.test("a deleted room becomes a terminal 404 during reconciliation", async () => {
  const error = await assertRejects(
    () =>
      reconcileTerminalFinalizationAfterLeaseConflict({
        action: "finalize_expired_room",
        error: conflict(),
        refetch: async () => null,
        validate: () => {},
        delay: async () => {},
        retryDelays: [1],
      }),
    Error,
  );
  assertEquals((error as any).status, 404);
});

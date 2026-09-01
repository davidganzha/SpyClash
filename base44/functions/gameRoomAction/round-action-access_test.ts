import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertActiveRoundActor,
  assertRoundActionMode,
} from "./round-action-access.ts";

Deno.test("round actions are scoped to their exact game mode", () => {
  assertRoundActionMode({ game_mode: " QUESTIONS " }, "questions");
  assertRoundActionMode({ game_mode: "associations" }, "associations");

  const error = assertThrows(() =>
    assertRoundActionMode({ game_mode: "associations" }, "questions")
  ) as Error & { status?: number; code?: string };
  assertEquals(error.status, 409);
  assertEquals(error.code, "round_mode_mismatch");
});

Deno.test("round continuation rejects spectators with canonical identity", () => {
  const active = [{ email: "active@example.com" }];
  assertActiveRoundActor(active, " ACTIVE@example.com ");

  const error = assertThrows(() =>
    assertActiveRoundActor(active, "spectator@example.com")
  ) as Error & { status?: number; code?: string };
  assertEquals(error.status, 403);
  assertEquals(error.code, "round_actor_inactive");
});

Deno.test("round access fails closed for missing mode and actor identity", () => {
  assertThrows(
    () => assertRoundActionMode({}, "questions"),
    Error,
    "questions round is not active",
  );
  assertThrows(
    () => assertActiveRoundActor([{ email: "active@example.com" }], ""),
    Error,
    "Only an active operative",
  );
});

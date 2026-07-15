import { assertEquals } from "jsr:@std/assert@1";
import { nextRoundNumber } from "./game-round.ts";

Deno.test("continuing question results advances the visible round", () => {
  assertEquals(nextRoundNumber(1), 2);
  assertEquals(nextRoundNumber(4), 5);
  assertEquals(nextRoundNumber("invalid"), 2);
});

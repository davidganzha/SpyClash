import { assertEquals } from "jsr:@std/assert@1";
import { retiredAdvanceRoundResponse } from "./retired.ts";

Deno.test("retired advanceRound fails closed without touching GameRoom", async () => {
  const response = retiredAdvanceRoundResponse();
  assertEquals(response.status, 410);
  assertEquals((await response.json()).code, "endpoint_retired");
});

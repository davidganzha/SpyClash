import { assertEquals } from "jsr:@std/assert@1";
import { internalPushSecret } from "./internal-push.ts";

Deno.test("game room sender rejects missing and short internal push secrets", () => {
  assertEquals(internalPushSecret(undefined), null);
  assertEquals(internalPushSecret("short-secret"), null);
  assertEquals(internalPushSecret(`  ${"a".repeat(32)}  `), "a".repeat(32));
});

import { assertEquals } from "jsr:@std/assert@1";
import {
  internalPushSecret,
  matchesInternalPushSecret,
} from "./internal-push.ts";

Deno.test("game room sender rejects missing and short internal push secrets", () => {
  assertEquals(internalPushSecret(undefined), null);
  assertEquals(internalPushSecret("short-secret"), null);
  assertEquals(internalPushSecret(`  ${"a".repeat(32)}  `), "a".repeat(32));
});

Deno.test("internal push secret comparison is strong and exact", () => {
  const secret = "a".repeat(32);
  assertEquals(matchesInternalPushSecret(secret, secret), true);
  assertEquals(matchesInternalPushSecret(secret, `${"a".repeat(31)}b`), false);
  assertEquals(matchesInternalPushSecret("short", "short"), false);
});

import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  classifyObjectionableMaterial,
  ObjectionableCommunityContentError,
  requireSafeCommunityText,
  safeCommunityAvatar,
  safeCommunityDisplayName,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";

Deno.test("room participant identity is sanitized before sharing", () => {
  assertEquals(safeCommunityDisplayName("Signal Raven"), "Signal Raven");
  assertEquals(safeCommunityDisplayName("f.u.c.k"), "OPERATIVE");
  assertEquals(safeCommunityAvatar("🎭"), "🎭");
  assertEquals(safeCommunityAvatar("hostile free-form text"), "🕵️");
});

Deno.test("room start rejects unsafe pack content and suppresses legacy content", () => {
  assertThrows(
    () => requireSafeCommunityText("k1ll yourself", "Word pack item"),
    ObjectionableCommunityContentError,
  );
  assertEquals(classifyObjectionableMaterial("Embassy"), null);
  assertEquals(
    safeCommunityTextForDisplay("f.u.c.k", "CLASSIFIED"),
    "CLASSIFIED",
  );
});

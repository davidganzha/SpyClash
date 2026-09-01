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
  assertEquals(safeCommunityAvatar("🦅"), "🦅");
  assertEquals(safeCommunityAvatar("hostile free-form text"), "🕵️");
});

Deno.test("room identity safety catches zalup variants and falls back", () => {
  for (
    const value of [
      "ZALUPA",
      "ЗАЛУПА",
      "zalup",
      "залуп",
      "za.lu-pa",
      "za lu pa",
      "zal upa",
      "zal u p a",
      "за лу па",
      "zаlupa",
      "3a1up4",
      "zаluрa",
      "z@lup@",
      "za|upa",
      "z a l u p a",
      "з а л у п а",
      "z4lup4",
    ]
  ) {
    assertEquals(classifyObjectionableMaterial(value), "abusive_language");
    assertEquals(safeCommunityDisplayName(value), "OPERATIVE");
  }
  assertEquals(classifyObjectionableMaterial("Pizza Lupin"), null);
  assertEquals(safeCommunityDisplayName("Pizza Lupin"), "Pizza Lupin");
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

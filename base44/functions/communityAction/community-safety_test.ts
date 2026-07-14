import { assertEquals } from "jsr:@std/assert@1";
import {
  blockedByUserID,
  classifyObjectionableMaterial,
  friendshipBlocksPair,
  normalizeCommunityReportReason,
  ObjectionableCommunityContentError,
  requireSafeCommunityText,
  safeCommunityAvatar,
  safeCommunityDisplayName,
  safeCommunityTextForDisplay,
  sanitizeCommunityReportDetails,
  validateSharedWordPackContent,
} from "./community-safety.ts";

Deno.test("server safety classifier catches objectionable text and common evasion", () => {
  assertEquals(classifyObjectionableMaterial("f.u.c.k"), "abusive_language");
  assertEquals(
    classifyObjectionableMaterial("k1ll yourself"),
    "self_harm_encouragement",
  );
  assertEquals(
    classifyObjectionableMaterial("Я тебя убью"),
    "violence_or_threats",
  );
  assertEquals(classifyObjectionableMaterial("ordinary field note"), null);
  assertEquals(classifyObjectionableMaterial("Scunthorpe mission"), null);
});

Deno.test("unsafe public names are replaced without leaking their original text", () => {
  assertEquals(safeCommunityDisplayName("  Signal   Raven  "), "Signal Raven");
  assertEquals(safeCommunityDisplayName("f.u.c.k"), "OPERATIVE");
  assertEquals(safeCommunityDisplayName("\u0000\u0007"), "OPERATIVE");
});

Deno.test("public avatars are allowlisted so legacy free-form UGC cannot leak", () => {
  assertEquals(safeCommunityAvatar("🎭"), "🎭");
  assertEquals(safeCommunityAvatar("harassing avatar text"), "🕵️");
  assertEquals(safeCommunityAvatar("https://example.invalid/tracker"), "🕵️");
});

Deno.test("report inputs are bounded and reasons are allowlisted", () => {
  assertEquals(normalizeCommunityReportReason(" Harassment "), "harassment");
  assertEquals(normalizeCommunityReportReason("made_up"), null);
  assertEquals(sanitizeCommunityReportDetails(" x ".repeat(300)).length, 500);
});

Deno.test("shared word-pack contract rejects unsafe names categories and words", () => {
  assertEquals(
    validateSharedWordPackContent({
      name: "Cinema",
      category: "Movies",
      words: ["Arrival", "Alien", "Arrival"],
    }),
    { name: "Cinema", category: "Movies", words: ["Arrival", "Alien"] },
  );
  let rejected = false;
  try {
    validateSharedWordPackContent({
      name: "Cinema",
      category: "Movies",
      words: ["Arrival", "k1ll yourself"],
    });
  } catch (error) {
    rejected = error instanceof ObjectionableCommunityContentError;
  }
  assertEquals(rejected, true);
  assertEquals(requireSafeCommunityText("  safe   word ", "Word"), "safe word");
  assertEquals(
    safeCommunityTextForDisplay("f.u.c.k", "CLASSIFIED"),
    "CLASSIFIED",
  );
});

Deno.test("blocked relationships retain a single unblock owner", () => {
  const blocked = {
    requester_id: "user-a",
    addressee_id: "user-b",
    blocked_by_id: "user-b",
    status: "blocked",
  };
  assertEquals(friendshipBlocksPair(blocked, "user-a", "user-b"), true);
  assertEquals(friendshipBlocksPair(blocked, "user-a", "user-c"), false);
  assertEquals(blockedByUserID(blocked), "user-b");
  assertEquals(blockedByUserID({ ...blocked, blocked_by_id: "" }), "user-a");
});

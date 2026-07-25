import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  constantTimeEqual,
  normalizeAPNSToken,
  preferences,
  requireActivityBinding,
  requireBundleID,
} from "./contracts.ts";

Deno.test("APNs token contract normalizes formatting without accepting arbitrary text", () => {
  const token = "AA".repeat(32);
  assertEquals(normalizeAPNSToken(`<${token}>`), token.toLowerCase());
  assertThrows(() => normalizeAPNSToken("not-a-token"));
  assertThrows(() => normalizeAPNSToken("ab"));
});

Deno.test("push preferences default safely and preserve explicit opt-outs", () => {
  assertEquals(preferences({ room_invites: false }), {
    friendRequests: true,
    roomInvites: false,
    gameUpdates: true,
  });
  assertThrows(() => requireBundleID("com.attacker.clone"));
});

Deno.test("per-activity token requires activity, room, and provider match bindings", () => {
  assertEquals(
    requireActivityBinding({
      activity_id: "activity-1",
      room_id: "room-1",
      match_id: "provider-match-1",
    }),
    { activityID: "activity-1", roomID: "room-1", matchID: "provider-match-1" },
  );
  assertThrows(() => requireActivityBinding({ room_id: "room-1" }));
});

Deno.test("internal worker secret comparison is length-safe", () => {
  assertEquals(constantTimeEqual("same-secret", "same-secret"), true);
  assertEquals(constantTimeEqual("same-secret", "same-secrex"), false);
  assertEquals(constantTimeEqual("short", "shorter"), false);
});

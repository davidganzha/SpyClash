import { assertEquals, assertNotStrictEquals } from "jsr:@std/assert@1";
import {
  sendAlertPush,
  sendLiveActivityPush,
  withoutNotificationSound,
} from "./apns.ts";

Deno.test("APNs transport strips sound without mutating alert payloads", () => {
  const payload = {
    aps: {
      alert: { title: "Invite", body: "Join the room" },
      category: "ROOM_INVITE",
      sound: "default",
    },
    event_type: "room_invite",
    room_id: "room-1",
  };

  const sanitized = withoutNotificationSound(payload);
  assertNotStrictEquals(sanitized, payload);
  assertNotStrictEquals(sanitized.aps, payload.aps);
  assertEquals(sanitized, {
    aps: {
      alert: { title: "Invite", body: "Join the room" },
      category: "ROOM_INVITE",
    },
    event_type: "room_invite",
    room_id: "room-1",
  });
  assertEquals(payload.aps.sound, "default");
});

Deno.test("all ordinary SpyClash push events remain silent at transport", () => {
  for (
    const eventType of [
      "friend_request",
      "room_invite",
      "game_started",
      "game_finished",
    ]
  ) {
    const sanitized = withoutNotificationSound({
      aps: { alert: eventType, sound: "legacy.caf" },
      event_type: eventType,
    });
    assertEquals("sound" in (sanitized.aps as Record<string, unknown>), false);
    assertEquals(sanitized.event_type, eventType);
  }
});

Deno.test("Live Activity start update and end payloads remain silent", () => {
  for (const event of ["start", "update", "end"]) {
    const sanitized = withoutNotificationSound({
      aps: {
        timestamp: 1_725_000_000,
        event,
        sound: "default",
        "content-state": { round: 2, phase: "asking" },
      },
    });
    assertEquals(sanitized, {
      aps: {
        timestamp: 1_725_000_000,
        event,
        "content-state": { round: 2, phase: "asking" },
      },
    });
  }
});

Deno.test("local APNs topic misconfiguration never revokes valid client tokens", async () => {
  const previous = Deno.env.get("APNS_TOPIC");
  Deno.env.set("APNS_TOPIC", "com.example.wrong-topic");
  try {
    const common = {
      token: "ab".repeat(32),
      environment: "sandbox" as const,
      bundleID: "com.spyclash.app",
      collapseID: "test",
      expiration: 0,
      payload: { aps: {} },
    };
    const alert = await sendAlertPush(common);
    const activity = await sendLiveActivityPush(common);
    assertEquals(alert, {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "topic_mismatch",
    });
    assertEquals(activity, alert);
  } finally {
    if (previous === undefined) Deno.env.delete("APNS_TOPIC");
    else Deno.env.set("APNS_TOPIC", previous);
  }
});

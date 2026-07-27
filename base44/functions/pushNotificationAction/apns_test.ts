import {
  assertEquals,
  assertLessOrEqual,
  assertNotStrictEquals,
} from "jsr:@std/assert@1";
import {
  APNS_MAX_PAYLOAD_BYTES,
  sendAlertPush,
  sendLiveActivityPush,
  serializeAlertPayload,
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
      bundleID: "com.spyclash.ios",
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

Deno.test("alert payload truncation is deterministic, Unicode-safe, and preserves routing", () => {
  const payload = {
    aps: {
      alert: {
        title: `Новости ${"🚀".repeat(600)}`,
        body: `Привет ${"мир🌍".repeat(1_200)}`,
      },
      category: "GLOBAL_ANNOUNCEMENT",
      sound: "default",
    },
    event_type: "global_announcement",
    announcement_id: "announcement-1",
    route: "spyclash://notifications?id=announcement-1",
  };
  const first = serializeAlertPayload(payload);
  const second = serializeAlertPayload(payload);
  assertEquals(first?.json, second?.json);
  assertLessOrEqual(first?.byteLength || Infinity, APNS_MAX_PAYLOAD_BYTES);
  assertEquals(first?.payload.event_type, payload.event_type);
  assertEquals(first?.payload.announcement_id, payload.announcement_id);
  assertEquals(first?.payload.route, payload.route);
  assertEquals(
    "sound" in (first?.payload.aps as Record<string, unknown>),
    false,
  );
  // JSON parsing proves no UTF-16 surrogate was cut in half.
  JSON.parse(first?.json || "");
});

Deno.test("irreducibly oversized routing payload fails before network and is not retried", async () => {
  const previous = Deno.env.get("APNS_TOPIC");
  Deno.env.set("APNS_TOPIC", "com.spyclash.ios");
  try {
    const common = {
      token: "ab".repeat(32),
      environment: "sandbox" as const,
      bundleID: "com.spyclash.ios",
      collapseID: "test",
      expiration: 0,
      payload: {
        aps: { alert: { title: "T", body: "B" } },
        route: "x".repeat(APNS_MAX_PAYLOAD_BYTES + 100),
      },
      fetcher: () => {
        throw new Error("network must not be reached");
      },
    };
    assertEquals(await sendAlertPush(common), {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "payload_too_large",
    });
    assertEquals(await sendLiveActivityPush(common), {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "payload_too_large",
    });
  } finally {
    if (previous === undefined) Deno.env.delete("APNS_TOPIC");
    else Deno.env.set("APNS_TOPIC", previous);
  }
});

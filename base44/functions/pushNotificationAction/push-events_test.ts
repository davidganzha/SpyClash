import { assertEquals } from "jsr:@std/assert@1";
import {
  alertCollapseID,
  alertPayload,
  claimPushEvent,
  completePushEvent,
  preferenceAllows,
  pushEventLifecycleUserIDs,
  validatePushSource,
} from "./push-events.ts";

class Store {
  constructor(public records: Record<string, any>[]) {}
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).map((record) => structuredClone(record));
  }
  async updateMany(filter: Record<string, any>, update: Record<string, any>) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) return record;
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    return { updated };
  }
}

function service(entities: Record<string, Store>) {
  return { asServiceRole: { entities } };
}

Deno.test("friend request push is delivered only while its server source is pending", async () => {
  const event = {
    event_type: "friend_request",
    source_event_id: "event-1",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
  };
  const base44 = service({
    Friendship: new Store([{
      request_event_id: "event-1",
      requester_id: "actor",
      addressee_id: "recipient",
      status: "pending",
    }]),
    User: new Store([{ id: "actor", display_name: "Raven" }]),
  });
  assertEquals(await validatePushSource(base44, event), {
    valid: true,
    actorName: "Raven",
  });
  base44.asServiceRole.entities.Friendship.records[0].status = "accepted";
  assertEquals((await validatePushSource(base44, event)).valid, false);
});

Deno.test("fresh outbox row retries instead of being lost before its source write lands", async () => {
  const base44 = service({
    Friendship: new Store([]),
    User: new Store([]),
  });
  const source = await validatePushSource(base44, {
    event_type: "friend_request",
    source_event_id: "event-pending",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
    created_at: new Date().toISOString(),
  });
  assertEquals(source.valid, false);
  assertEquals(source.retryable, true);
});

Deno.test("outbox claim is exact-CAS and a completed event cannot be reclaimed", async () => {
  const store = new Store([{
    id: "event",
    state: "pending",
    lease_token: "",
    lease_until: "2026-01-01T00:00:00.000Z",
    revision: "r1",
    attempt_count: 0,
  }]);
  const event = structuredClone(store.records[0]);
  const claimed = await claimPushEvent(
    store,
    event,
    new Date("2026-07-15T12:00:00.000Z"),
    (() => {
      const values = ["lease", "revision"];
      return () => values.shift() || "unused";
    })(),
  );
  assertEquals(Boolean(claimed), true);
  assertEquals(await claimPushEvent(store, event), null);
  assertEquals(
    await completePushEvent({
      store,
      claimed: claimed!,
      state: "delivered",
      deliveredCount: 1,
      deliveredTokenHashes: ["token-a", "token-a"],
    }),
    true,
  );
  assertEquals(store.records[0].delivered_token_hashes, ["token-a"]);
  assertEquals(await claimPushEvent(store, store.records[0]), null);
});

Deno.test("retry completion preserves the per-device success ledger", async () => {
  const claimed = {
    id: "event-retry",
    state: "processing",
    lease_token: "lease",
    revision: "r1",
    delivered_count: 1,
    failed_count: 1,
    delivered_token_hashes: ["already-delivered"],
  };
  const store = new Store([structuredClone(claimed)]);
  assertEquals(
    await completePushEvent({
      store,
      claimed,
      state: "retry",
      nextAttemptAt: "2026-07-15T12:05:00.000Z",
    }),
    true,
  );
  assertEquals(store.records[0].delivered_count, 1);
  assertEquals(store.records[0].failed_count, 1);
  assertEquals(store.records[0].delivered_token_hashes, ["already-delivered"]);
});

Deno.test("ordinary lock-screen payload contains routing but never secret game data", () => {
  const payload = alertPayload(
    {
      event_type: "game_started",
      source_event_id: "event-1",
      room_id: "room-1",
      match_id: "match-1",
      word: "TOP SECRET",
      spy_email: "spy@example.com",
    },
    { valid: true },
    "en-US",
  );
  const encoded = JSON.stringify(payload);
  assertEquals(payload.event_type, "game_started");
  assertEquals(encoded.includes("TOP SECRET"), false);
  assertEquals(encoded.includes("spy@example.com"), false);
  assertEquals(
    (payload.aps as Record<string, any>).category,
    "SPYCLASH_GAME_UPDATE",
  );
  assertEquals("sound" in (payload.aps as Record<string, any>), false);
});

Deno.test("registration opt-outs are applied per notification family", () => {
  const registration = {
    status: "active",
    alert_authorized: true,
    friend_requests_enabled: false,
    room_invites_enabled: true,
    game_updates_enabled: true,
    announcements_enabled: true,
  };
  assertEquals(preferenceAllows(registration, "friend_request"), false);
  assertEquals(preferenceAllows(registration, "room_invite"), true);
  assertEquals(preferenceAllows(registration, "global_announcement"), true);
  assertEquals(
    preferenceAllows(
      { ...registration, announcements_enabled: false },
      "global_announcement",
    ),
    false,
  );
  assertEquals(
    preferenceAllows(
      { ...registration, alert_authorized: false },
      "room_invite",
    ),
    false,
  );
});

Deno.test("global announcement source and payload are localized without sound", async () => {
  const event = {
    event_type: "global_announcement",
    source_type: "notification_announcement",
    source_event_id: "announcement-1",
    announcement_id: "announcement-1",
    recipient_user_id: "recipient",
  };
  const base44 = service({
    NotificationAnnouncement: new Store([{
      id: "announcement-1",
      status: "published",
      importance: "important",
      published_at: "2020-01-01T00:00:00.000Z",
      title_en: "Build 29",
      body_en: "Swipe navigation is ready.",
      title_ru: "Сборка 29",
      body_ru: "Свайпы готовы.",
      action_deep_link: "spyclash://notifications?id=announcement-1",
      expires_at: "2099-01-01T00:00:00.000Z",
    }]),
  });
  const source = await validatePushSource(base44, event);
  assertEquals(source.valid, true);
  const payload = alertPayload(event, source, "ru-RU");
  assertEquals(payload.event_type, "global_announcement");
  assertEquals(payload.announcement_id, "announcement-1");
  assertEquals((payload.aps as Record<string, any>).alert.title, "Сборка 29");
  assertEquals(
    (payload.aps as Record<string, any>).category,
    "SPYCLASH_ANNOUNCEMENT",
  );
  assertEquals("sound" in (payload.aps as Record<string, any>), false);
  assertEquals(alertCollapseID(event), "announcement:announcement-1");
});

Deno.test("privacy-bearing notifications lease both actor and recipient", () => {
  assertEquals(
    pushEventLifecycleUserIDs({
      event_type: "friend_request",
      actor_user_id: "actor",
      recipient_user_id: "recipient",
    }),
    ["actor", "recipient"],
  );
  assertEquals(
    pushEventLifecycleUserIDs({
      event_type: "game_started",
      actor_user_id: "actor",
      recipient_user_id: "recipient",
    }),
    ["recipient"],
  );
});

Deno.test("game start and finish share one APNs collapse identity", () => {
  const start = alertCollapseID({
    event_type: "game_started",
    match_id: "match-1",
    source_event_id: "start-event",
  });
  const finish = alertCollapseID({
    event_type: "game_finished",
    match_id: "match-1",
    source_event_id: "finish-event",
  });
  assertEquals(start, "game:match-1");
  assertEquals(finish, start);
  assertEquals(
    alertCollapseID({
      event_type: "friend_request",
      source_event_id: "friend-event",
    }),
    "event:friend-event",
  );
});

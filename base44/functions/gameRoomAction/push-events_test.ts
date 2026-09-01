import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  commitGamePushEvents,
  enqueueGamePushEvents,
  gamePushCommitCoversRecipients,
  gamePushExpiry,
  gamePushRecipientUserIDs,
} from "./push-events.ts";

class Store {
  records: Record<string, any>[] = [];
  throwAfterNextCreate = false;
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }
  async create(record: Record<string, any>) {
    this.records.push({ id: `row-${this.records.length + 1}`, ...record });
    if (this.throwAfterNextCreate) {
      this.throwAfterNextCreate = false;
      throw new Error("lost create response");
    }
  }
  async updateMany(
    filter: Record<string, any>,
    update: Record<string, any>,
  ) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        return record;
      }
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    return { updated };
  }
}

Deno.test("game event fans out once per stable participant id", async () => {
  const store = new Store();
  let persistenceBoundaries = 0;
  const input = {
    base44: { asServiceRole: { entities: { PushNotificationEvent: store } } },
    room: {
      id: "room-1",
      participant_user_ids: ["a", "b", "a"],
      players: [{ user_id: "b" }, { user_id: "c" }],
    },
    eventType: "game_started" as const,
    sourceEventID: "source-1",
    matchID: "match-1",
    persist: async <T>(writer: () => Promise<T>) => {
      persistenceBoundaries += 1;
      return await writer();
    },
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => crypto.randomUUID(),
  };
  await enqueueGamePushEvents(input);
  assertEquals(
    store.records.every((record) => record.inbox_visible === false),
    true,
  );
  await enqueueGamePushEvents({ ...input, sourceCommitted: true });
  assertEquals(persistenceBoundaries, 2);
  assertEquals(store.records.map((record) => record.recipient_user_id), [
    "a",
    "b",
    "c",
  ]);
  assertEquals(
    store.records.every((record) =>
      record.inbox_projection_version === 1 &&
      record.inbox_kind === "game_started" &&
      record.inbox_action_deep_link === "spyclash://game?room_id=room-1" &&
      record.inbox_visible === false && Boolean(record.inbox_committed_at)
    ),
    true,
  );
  assertEquals(
    store.records.every((record) =>
      record.inbox_title_uk === "Гра почалася" &&
      record.inbox_body_uk === "Ваша місія SpyClash уже почалася."
    ),
    true,
  );
});

Deno.test("a partial batched enqueue retries without duplicate recipients", async () => {
  const store = new Store();
  store.throwAfterNextCreate = true;
  const input = {
    base44: { asServiceRole: { entities: { PushNotificationEvent: store } } },
    room: {
      id: "room-1",
      participant_user_ids: ["a", "b"],
      players: [],
    },
    eventType: "game_finished" as const,
    sourceEventID: "finish-1",
    matchID: "match-1",
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => crypto.randomUUID(),
  };

  await assertRejects(() => enqueueGamePushEvents(input), Error);
  await enqueueGamePushEvents(input);
  assertEquals(store.records.map((record) => record.recipient_user_id), [
    "a",
    "b",
  ]);
});

Deno.test("authoritative finish commit revives an exhausted pre-commit row", async () => {
  const store = new Store();
  store.records = [{
    id: "event-a",
    source_event_id: "game-finished:match-1",
    event_type: "game_finished",
    room_id: "room-1",
    state: "cancelled",
    lease_token: "old-worker",
    revision: "cancelled-revision",
    inbox_visible: false,
    inbox_committed_at: null,
  }];
  const committed = await commitGamePushEvents({
    store,
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    eventType: "game_finished",
    sourceEventID: "game-finished:match-1",
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => "recovered-revision",
  });
  assertEquals(committed, 1);
  assertEquals(store.records[0].state, "retry");
  assertEquals(store.records[0].attempt_count, 0);
  assertEquals(store.records[0].inbox_committed_at, "2026-07-15T12:00:00.000Z");
  assertEquals(store.records[0].last_error_code, "committed_finish_recovered");
});

Deno.test("finish outbox proof requires an exact committed row for every terminal recipient", async () => {
  const store = new Store();
  const room = {
    id: "room-1",
    participant_user_ids: ["user-c", "user-a"],
    players: [{ user_id: "user-b" }, { user_id: "user-a" }],
  };
  const sourceEventID = "game-finished:match-1";
  const input = {
    base44: { asServiceRole: { entities: { PushNotificationEvent: store } } },
    room,
    eventType: "game_finished" as const,
    sourceEventID,
    matchID: "match-1",
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-09-01T12:00:00.000Z"),
    randomUUID: () => crypto.randomUUID(),
  };
  await enqueueGamePushEvents(input);
  const recipients = gamePushRecipientUserIDs(room);
  assertEquals(recipients, ["user-a", "user-b", "user-c"]);
  assertEquals(
    await gamePushCommitCoversRecipients({
      store,
      eventType: "game_finished",
      sourceEventID,
      recipientUserIDs: recipients,
    }),
    false,
  );

  await commitGamePushEvents({
    store,
    persist: input.persist,
    eventType: "game_finished",
    sourceEventID,
    now: input.now,
  });
  assertEquals(
    await gamePushCommitCoversRecipients({
      store,
      eventType: "game_finished",
      sourceEventID,
      recipientUserIDs: recipients,
    }),
    true,
  );

  store.records.find((row) => row.recipient_user_id === "user-b")!
    .inbox_committed_at = null;
  // An unrelated committed row must never substitute for the missing member.
  store.records.push({
    ...store.records[0],
    id: "ghost",
    recipient_user_id: "ghost",
    dedupe_key: `game_finished:${sourceEventID}:ghost`,
  });
  assertEquals(
    await gamePushCommitCoversRecipients({
      store,
      eventType: "game_finished",
      sourceEventID,
      recipientUserIDs: recipients,
    }),
    false,
  );
});

Deno.test("game start alert expires with the match instead of lingering offline", () => {
  const now = new Date("2026-07-15T12:00:00.000Z");
  const room = {
    game_started_at: now.toISOString(),
    game_duration_seconds: 900,
  };
  assertEquals(
    gamePushExpiry(room, "game_started", now),
    "2026-07-15T12:20:00.000Z",
  );
  assertEquals(
    gamePushExpiry(room, "game_finished", now),
    "2026-07-15T13:00:00.000Z",
  );
});

Deno.test("game start alert expiry follows accumulated and active pauses", () => {
  const start = "2026-07-15T12:00:00.000Z";
  assertEquals(
    gamePushExpiry(
      {
        game_started_at: start,
        game_duration_seconds: 60,
        game_paused_total_seconds: 30,
      },
      "game_started",
      new Date(start),
    ),
    "2026-07-15T12:06:30.000Z",
  );

  assertEquals(
    gamePushExpiry(
      {
        game_started_at: start,
        game_duration_seconds: 60,
        game_paused_at: "2026-07-15T12:00:20.000Z",
        game_paused_total_seconds: 0,
      },
      "game_started",
      new Date("2026-07-15T12:01:00.000Z"),
    ),
    "2026-07-15T12:06:40.000Z",
  );
});

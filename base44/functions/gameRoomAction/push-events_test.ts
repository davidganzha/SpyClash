import { assertEquals } from "jsr:@std/assert@1";
import { enqueueGamePushEvents, gamePushExpiry } from "./push-events.ts";

class Store {
  records: Record<string, any>[] = [];
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }
  async create(record: Record<string, any>) {
    this.records.push({ id: `row-${this.records.length + 1}`, ...record });
  }
}

Deno.test("game event fans out once per stable participant id", async () => {
  const store = new Store();
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
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-15T12:00:00.000Z"),
    randomUUID: () => crypto.randomUUID(),
  };
  await enqueueGamePushEvents(input);
  await enqueueGamePushEvents(input);
  assertEquals(store.records.map((record) => record.recipient_user_id), [
    "a",
    "b",
    "c",
  ]);
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

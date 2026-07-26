import { assertEquals } from "jsr:@std/assert@1";
import {
  committedRoomPushEvents,
  repairCommittedRoomPushEvents,
  runCommittedRoomPushRepairIfFresh,
} from "./room-reconciliation.ts";

class Store {
  records: Record<string, any>[] = [];
  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }
  async create(record: Record<string, any>) {
    this.records.push({ id: `event-${this.records.length + 1}`, ...record });
  }
}

Deno.test("persisted game start identity repairs a missing outbox idempotently", async () => {
  const store = new Store();
  const room = {
    id: "room-1",
    status: "playing",
    match_id: "match-1",
    game_started_event_id: "start-1",
    participant_user_ids: ["user-b", "user-a", "user-a"],
    players: [{ user_id: "user-c" }],
    intro_started_at: "2026-07-26T12:00:00.000Z",
    game_duration_seconds: 900,
  };
  const input = {
    eventStore: store,
    room,
    persist: async <T>(writer: () => Promise<T>) => await writer(),
    now: new Date("2026-07-26T12:00:01.000Z"),
    randomUUID: () => "revision",
  };
  assertEquals(await repairCommittedRoomPushEvents(input), 3);
  assertEquals(await repairCommittedRoomPushEvents(input), 0);
  assertEquals(store.records.map((row) => row.recipient_user_id), [
    "user-a",
    "user-b",
    "user-c",
  ]);
  assertEquals(store.records.every((row) => row.state === "pending"), true);
});

Deno.test("finished rooms repair only the terminal event", async () => {
  assertEquals(
    committedRoomPushEvents({
      status: "finished",
      match_id: "match-1",
      game_started_event_id: "start-1",
      game_finished_event_id: "finish-1",
    }),
    [{
      eventType: "game_finished",
      sourceEventID: "finish-1",
      matchID: "match-1",
    }],
  );
});

Deno.test("old terminal identities are not resurrected as fresh alerts", async () => {
  const store = new Store();
  assertEquals(
    await repairCommittedRoomPushEvents({
      eventStore: store,
      room: {
        id: "room-old",
        status: "finished",
        match_id: "match-old",
        game_finished_event_id: "finish-old",
        participant_user_ids: ["user-a"],
        updated_date: "2026-07-26T09:00:00.000Z",
      },
      persist: async <T>(writer: () => Promise<T>) => await writer(),
      now: new Date("2026-07-26T12:00:00.000Z"),
    }),
    0,
  );
  assertEquals(store.records, []);
});

Deno.test("old terminal room skips the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old",
      status: "finished",
      match_id: "match-old",
      game_finished_event_id: "finish-old",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T09:00:00.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("expired game start skips the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old",
      status: "playing",
      match_id: "match-old",
      game_started_event_id: "start-old",
      participant_user_ids: ["user-a"],
      game_started_at: "2026-07-26T09:00:00.000Z",
      game_duration_seconds: 900,
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("old game start without a duration also skips repair", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-old-legacy",
      status: "playing",
      match_id: "match-old-legacy",
      game_started_event_id: "start-old-legacy",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T09:00:00.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 1;
    },
  });
  assertEquals(repaired, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("fresh room reaches the lease-producing repair callback", async () => {
  let repairCalls = 0;
  const repaired = await runCommittedRoomPushRepairIfFresh({
    room: {
      id: "room-current",
      status: "finished",
      match_id: "match-current",
      game_finished_event_id: "finish-current",
      participant_user_ids: ["user-a"],
      updated_date: "2026-07-26T11:59:30.000Z",
    },
    now: new Date("2026-07-26T12:00:00.000Z"),
    repair: async () => {
      repairCalls += 1;
      return 2;
    },
  });
  assertEquals(repaired, 2);
  assertEquals(repairCalls, 1);
});

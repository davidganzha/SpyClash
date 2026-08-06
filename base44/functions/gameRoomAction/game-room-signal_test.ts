import { assertEquals } from "jsr:@std/assert@1";
import {
  fanoutGameRoomSignalsBestEffort,
  GameRoomSignalRecord,
  GameRoomSignalStore,
  signalRecordsForRoom,
  upsertGameRoomSignal,
} from "./game-room-signal.ts";

class MemorySignalStore implements GameRoomSignalStore {
  rows: Array<Record<string, unknown>> = [];
  nextID = 1;
  failUsers = new Set<string>();
  createRaceRow: Record<string, unknown> | null = null;
  updateManyCalls = 0;

  create(data: GameRoomSignalRecord) {
    if (this.createRaceRow) {
      this.rows.push(this.createRaceRow);
      this.createRaceRow = null;
      return Promise.reject(new Error("duplicate logical key"));
    }
    if (this.failUsers.has(data.user_id)) {
      return Promise.reject(new Error("unavailable"));
    }
    const row = { id: `signal-${this.nextID++}`, ...data };
    this.rows.push(row);
    return Promise.resolve(row);
  }

  updateMany(
    query: Record<string, unknown>,
    update: Record<string, any>,
  ) {
    this.updateManyCalls += 1;
    const signal = update.$set as GameRoomSignalRecord;
    if (this.failUsers.has(signal.user_id)) {
      return Promise.reject(new Error("unavailable"));
    }
    let updated = 0;
    this.rows = this.rows.map((row) => {
      const matches = Object.entries(query).every(([key, value]) =>
        row[key] === value
      );
      if (!matches) return row;
      updated += 1;
      return { ...row, ...signal };
    });
    return Promise.resolve({ updated });
  }
}

const signal: GameRoomSignalRecord = {
  user_id: "user-1",
  room_id: "room-1",
  lobby_revision: 4,
  room_revision: 12,
  room_updated_at: "2026-08-06T12:00:00.000Z",
  state: "active",
};

Deno.test("room signals contain only deduplicated participant ids and wake-up metadata", () => {
  assertEquals(
    signalRecordsForRoom({
      id: "room-1",
      lobby_revision: 7,
      room_revision: 21,
      updated_date: "2026-08-06T12:00:01.000Z",
      participant_user_ids: ["user-1", "user-2", "user-1"],
      players: [
        { user_id: "user-2", email: "hidden@example.com" },
        { user_id: "user-3", name: "Hidden" },
      ],
      word: "Never projected",
      lobby_word_pool: [{ word: "Never projected" }],
    }),
    [
      {
        user_id: "user-1",
        room_id: "room-1",
        lobby_revision: 7,
        room_revision: 21,
        room_updated_at: "2026-08-06T12:00:01.000Z",
        state: "active",
      },
      {
        user_id: "user-2",
        room_id: "room-1",
        lobby_revision: 7,
        room_revision: 21,
        room_updated_at: "2026-08-06T12:00:01.000Z",
        state: "active",
      },
      {
        user_id: "user-3",
        room_id: "room-1",
        lobby_revision: 7,
        room_revision: 21,
        room_updated_at: "2026-08-06T12:00:01.000Z",
        state: "active",
      },
    ],
  );
});

Deno.test("signal upsert uses one write for an existing participant row", async () => {
  const store = new MemorySignalStore();
  assertEquals(await upsertGameRoomSignal(store, signal), "created");
  const callsAfterCreate = store.updateManyCalls;
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, room_revision: 13 }),
    "updated",
  );
  assertEquals(store.updateManyCalls, callsAfterCreate + 1);
  assertEquals(store.rows[0].room_revision, 13);
});

Deno.test("signal upsert converges after a create race", async () => {
  const store = new MemorySignalStore();
  store.createRaceRow = {
    id: "signal-raced",
    ...signal,
    room_revision: 2,
  };
  assertEquals(await upsertGameRoomSignal(store, signal), "updated");
  assertEquals(store.rows, [{ id: "signal-raced", ...signal }]);
});

Deno.test("signal fanout is best effort so polling remains a fallback", async () => {
  const store = new MemorySignalStore();
  store.failUsers.add("user-2");
  const errors: string[] = [];
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room: {
      id: "room-1",
      lobby_revision: 8,
      room_revision: 22,
      participant_user_ids: ["user-1", "user-2"],
    },
    logError: (message) => errors.push(message),
  });
  assertEquals(result, { attempted: 2, succeeded: 1, failed: 1 });
  assertEquals(errors, ["room signal fanout deferred"]);
  assertEquals(store.rows.map((row) => row.user_id), ["user-1"]);
});

Deno.test("rapid gameplay never recreates a signal removed by account cleanup", async () => {
  const store = new MemorySignalStore();
  assertEquals(
    await upsertGameRoomSignal(store, signal, { allowCreate: false }),
    "missing",
  );
  assertEquals(store.rows, []);
  assertEquals(store.updateManyCalls, 1);
});

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

  filter(query: Record<string, unknown>) {
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ),
    );
  }

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

  update(id: string, data: GameRoomSignalRecord) {
    if (this.failUsers.has(data.user_id)) {
      return Promise.reject(new Error("unavailable"));
    }
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing signal"));
    this.rows[index] = { id, ...data };
    return Promise.resolve(this.rows[index]);
  }
}

const signal: GameRoomSignalRecord = {
  user_id: "user-1",
  room_id: "room-1",
  lobby_revision: 4,
  state: "active",
};

Deno.test("room signals contain only deduplicated participant ids and wake-up metadata", () => {
  assertEquals(
    signalRecordsForRoom({
      id: "room-1",
      lobby_revision: 7,
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
        state: "active",
      },
      {
        user_id: "user-2",
        room_id: "room-1",
        lobby_revision: 7,
        state: "active",
      },
      {
        user_id: "user-3",
        room_id: "room-1",
        lobby_revision: 7,
        state: "active",
      },
    ],
  );
});

Deno.test("signal upsert creates, advances, and never downgrades a newer revision", async () => {
  const store = new MemorySignalStore();
  assertEquals(await upsertGameRoomSignal(store, signal), "created");
  assertEquals(await upsertGameRoomSignal(store, signal), "unchanged");
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, lobby_revision: 5 }),
    "updated",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, lobby_revision: 3 }),
    "unchanged",
  );
  assertEquals(store.rows[0].lobby_revision, 5);
});

Deno.test("signal upsert converges after a create race", async () => {
  const store = new MemorySignalStore();
  store.createRaceRow = {
    id: "signal-raced",
    ...signal,
    lobby_revision: 2,
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
      participant_user_ids: ["user-1", "user-2"],
    },
    logError: (message) => errors.push(message),
  });
  assertEquals(result, { attempted: 2, succeeded: 1, failed: 1 });
  assertEquals(errors, ["lobby signal fanout deferred"]);
  assertEquals(store.rows.map((row) => row.user_id), ["user-1"]);
});

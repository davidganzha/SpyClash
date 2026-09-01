import { assertEquals } from "jsr:@std/assert@1";
import {
  fanoutGameRoomSignalsBestEffort,
  GameRoomSignalRecord,
  GameRoomSignalStore,
  hasDurableClosedRoomSignal,
  signalRecordsForRecipients,
  signalRecordsForRoom,
  upsertGameRoomSignal,
} from "./game-room-signal.ts";

Deno.test("only the latest personal room signal can prove a completed exit", () => {
  const closed = {
    user_id: "user-1",
    room_id: "room-1",
    room_revision: 4,
    lobby_revision: 2,
    state: "closed",
  };
  assertEquals(
    hasDurableClosedRoomSignal([closed], "room-1", "user-1"),
    true,
  );
  assertEquals(
    hasDurableClosedRoomSignal([closed], "room-1", "user-1", 5),
    false,
  );
  assertEquals(
    hasDurableClosedRoomSignal(
      [
        closed,
        { ...closed, room_revision: 5, state: "active" },
      ],
      "room-1",
      "user-1",
    ),
    false,
  );
  assertEquals(
    hasDurableClosedRoomSignal(
      [
        { ...closed, state: "active" },
        closed,
      ],
      "room-1",
      "user-1",
    ),
    true,
  );
});

class MemorySignalStore implements GameRoomSignalStore {
  rows: Array<Record<string, unknown>> = [];
  nextID = 1;
  failUsers = new Set<string>();
  createRaceRow: Record<string, unknown> | null = null;
  filterCalls = 0;
  updateCalls = 0;

  filter(query: Record<string, unknown>) {
    this.filterCalls += 1;
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

  update(id: string, signal: GameRoomSignalRecord) {
    this.updateCalls += 1;
    if (this.failUsers.has(signal.user_id)) {
      return Promise.reject(new Error("unavailable"));
    }
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing"));
    this.rows[index] = { ...this.rows[index], ...signal };
    return Promise.resolve(this.rows[index]);
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

Deno.test("membership removal emits active remaining and closed removed recipients", () => {
  const records = signalRecordsForRecipients(
    {
      id: "room-1",
      lobby_revision: 8,
      room_revision: 22,
    },
    [
      { user_id: "host-user", state: "active" },
      { user_id: "remaining-user", state: "active" },
      { user_id: "removed-user", state: "closed" },
      { user_id: "removed-user", state: "active" },
    ],
  );

  assertEquals(
    records.map(({ user_id, state }) => ({ user_id, state })),
    [
      { user_id: "host-user", state: "active" },
      { user_id: "remaining-user", state: "active" },
      { user_id: "removed-user", state: "closed" },
    ],
  );
});

Deno.test("signal upsert uses one write for an existing participant row", async () => {
  const store = new MemorySignalStore();
  assertEquals(await upsertGameRoomSignal(store, signal), "created");
  const callsAfterCreate = store.updateCalls;
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, room_revision: 13 }),
    "updated",
  );
  assertEquals(store.updateCalls, callsAfterCreate + 1);
  assertEquals(store.rows[0].room_revision, 13);
});

Deno.test("closed dominates active at equal revision but a newer revision can reopen", async () => {
  const store = new MemorySignalStore();
  store.rows = [{ id: "signal-1", ...signal }];

  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      room_updated_at: "2026-08-06T11:59:59.000Z",
      state: "closed",
    }),
    "updated",
  );
  assertEquals(store.rows[0].state, "closed");

  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      room_updated_at: "2026-08-06T12:00:01.000Z",
      state: "active",
    }),
    "unchanged",
  );
  assertEquals(store.rows[0].state, "closed");

  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      room_revision: 13,
      state: "active",
    }),
    "updated",
  );
  assertEquals(store.rows[0].state, "active");
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

Deno.test("signal fanout reads the room rows once and emits addressable updates", async () => {
  const store = new MemorySignalStore();
  store.rows = [
    { id: "signal-1", ...signal, user_id: "user-1", room_revision: 20 },
    { id: "signal-2", ...signal, user_id: "user-2", room_revision: 20 },
  ];
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room: {
      id: "room-1",
      lobby_revision: 8,
      room_revision: 22,
      participant_user_ids: ["user-1", "user-2"],
    },
  });
  assertEquals(result, { attempted: 2, succeeded: 2, failed: 0 });
  assertEquals(store.filterCalls, 1);
  assertEquals(store.updateCalls, 2);
  assertEquals(store.rows.map((row) => row.room_revision), [22, 22]);
});

Deno.test("recipient-specific fanout writes active and closed states in one room read", async () => {
  const store = new MemorySignalStore();
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room: {
      id: "room-1",
      lobby_revision: 8,
      room_revision: 22,
    },
    recipients: [
      { user_id: "remaining-user", state: "active" },
      { user_id: "removed-user", state: "closed" },
    ],
  });

  assertEquals(result, { attempted: 2, succeeded: 2, failed: 0 });
  assertEquals(store.filterCalls, 1);
  assertEquals(
    store.rows.map(({ user_id, state }) => ({ user_id, state })),
    [
      { user_id: "remaining-user", state: "active" },
      { user_id: "removed-user", state: "closed" },
    ],
  );
});

Deno.test("logical room close persists its server receipt before physical deletion", async () => {
  const store = new MemorySignalStore();
  store.rows = [{
    id: "signal-1",
    ...signal,
    state: "active",
    room_revision: 23,
  }];
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room: {
      id: "room-1",
      lobby_revision: 9,
      room_revision: 23,
      participant_user_ids: ["user-1", "user-2"],
    },
    state: "closed",
    closeReceipt: {
      intent_id: "close-1",
      // Waiting lobbies have no match yet and still need a durable close.
      match_id: "",
    },
  });

  assertEquals(result, { attempted: 2, succeeded: 2, failed: 0 });
  assertEquals(
    store.rows.map((row) => ({
      user_id: row.user_id,
      state: row.state,
      close_intent_id: row.close_intent_id,
      close_match_id: row.close_match_id,
    })),
    [
      {
        user_id: "user-1",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "",
      },
      {
        user_id: "user-2",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "",
      },
    ],
  );
});

Deno.test("full-fanout completion upgrades every exact closed receipt", async () => {
  const store = new MemorySignalStore();
  const room = {
    id: "room-1",
    match_id: "match-1",
    lobby_revision: 9,
    room_revision: 23,
    participant_user_ids: ["user-1", "user-2"],
  };
  await fanoutGameRoomSignalsBestEffort({
    store,
    room,
    state: "closed",
    closeReceipt: { intent_id: "close-1", match_id: "match-1" },
  });
  const completion = {
    intent_id: "close-1",
    room_id: "room-1",
    match_id: "match-1",
    host_user_id: "user-1",
    participant_user_ids: ["user-1", "user-2"],
    participant_count: 2,
    completed_at: "2026-09-01T12:01:00.000Z",
  };
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room,
    state: "closed",
    closeReceipt: {
      intent_id: "close-1",
      match_id: "match-1",
      completion,
    },
  });
  assertEquals(result, { attempted: 2, succeeded: 2, failed: 0 });
  assertEquals(
    store.rows.map((row) => row.close_completion),
    [completion, completion],
  );
});

Deno.test("rapid gameplay never recreates a signal removed by account cleanup", async () => {
  const store = new MemorySignalStore();
  assertEquals(
    await upsertGameRoomSignal(store, signal, { allowCreate: false }),
    "missing",
  );
  assertEquals(store.rows, []);
  assertEquals(store.filterCalls, 1);
  assertEquals(store.updateCalls, 0);
});

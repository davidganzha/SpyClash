import {
  fanoutGameRoomSignalsBestEffort,
  GameRoomSignalRecord,
  GameRoomSignalStore,
  lobbyModeSignalProjectionForRoom,
  projectedLobbyModeFromSignal,
  signalRecordsForRoom,
  upsertGameRoomSignal,
} from "../overlays/projection-safe-game-room-signal.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const actualJSON = JSON.stringify(actual);
  const expectedJSON = JSON.stringify(expected);
  if (actualJSON !== expectedJSON) {
    throw new Error(
      `${
        message ? `${message}: ` : ""
      }expected ${expectedJSON}, got ${actualJSON}`,
    );
  }
}

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

class MemorySignalStore implements GameRoomSignalStore {
  rows: Array<Record<string, unknown>> = [];
  nextID = 1;
  createCalls = 0;

  filter(query: Record<string, unknown>) {
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ),
    );
  }

  create(data: GameRoomSignalRecord) {
    this.createCalls += 1;
    const row = { id: `signal-${this.nextID++}`, ...data };
    this.rows.push(row);
    return Promise.resolve(row);
  }

  update(id: string, data: GameRoomSignalRecord) {
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing"));
    // Base44 may retain omitted optional values. Tests intentionally model
    // that merge behavior so projection_kind remains the activation boundary.
    this.rows[index] = { ...this.rows[index], ...data };
    return Promise.resolve(this.rows[index]);
  }
}

const baseSignal: GameRoomSignalRecord = {
  user_id: "user-1",
  room_id: "room-1",
  lobby_revision: 7,
  room_revision: 40,
  room_updated_at: "2026-09-02T12:00:00.000Z",
  state: "active",
  projection_kind: "none",
};

Deno.test("generic room signals expose only wake-up metadata and deactivate projections", () => {
  const records = signalRecordsForRoom({
    id: "room-1",
    lobby_revision: 7,
    room_revision: 40,
    updated_date: "2026-09-02T12:00:00.000Z",
    participant_user_ids: ["user-1", "user-2"],
    players: [{ user_id: "user-2", email: "secret@example.com" }],
    word: "must not leak",
    lobby_word_pool: [{ word: "must not leak" }],
  });

  assertEquals(records.map((record) => record.projection_kind), [
    "none",
    "none",
  ]);
  for (const record of records) {
    assert(!("word" in record), "room word leaked into personal signal");
    assert(
      !("players" in record),
      "player payload leaked into personal signal",
    );
    assert(
      !("lobby_word_pool" in record),
      "lobby word pool leaked into personal signal",
    );
  }
});

Deno.test("lobby mode projection is a strict safe allowlist", () => {
  const projection = lobbyModeSignalProjectionForRoom(
    {
      game_mode: "associations",
      word: "must not leak",
      players: [{ email: "secret@example.com" }],
    },
    {
      projectionID: "00000000-0000-4000-8000-000000000001",
      emittedAt: "2026-09-02T12:00:00.100Z",
    },
  );
  assertEquals(projection, {
    projection_kind: "lobby_mode_v1",
    projection_id: "00000000-0000-4000-8000-000000000001",
    projected_game_mode: "associations",
    projection_committed_at: "2026-09-02T12:00:00.100Z",
    projection_emitted_at: "2026-09-02T12:00:00.100Z",
  });
  assertEquals(
    lobbyModeSignalProjectionForRoom({ game_mode: "invalid" }),
    null,
  );

  const forged = signalRecordsForRoom(
    {
      id: "room-1",
      lobby_revision: 7,
      room_revision: 41,
      participant_user_ids: ["user-1"],
    },
    "active",
    [],
    {
      projection_kind: "lobby_mode_v1",
      projection_id: "not-a-uuid",
      projected_game_mode: "questions",
      projection_emitted_at: "not-a-date",
    },
  );
  assertEquals(forged[0].projection_kind, "none");
  assertEquals(projectedLobbyModeFromSignal(forged[0]), null);
});

Deno.test("same-revision direct projections order by emitted time then UUID", async () => {
  const store = new MemorySignalStore();
  const first = lobbyModeSignalProjectionForRoom(
    { game_mode: "questions" },
    {
      projectionID: "00000000-0000-4000-8000-000000000001",
      emittedAt: "2026-09-02T12:00:00.000Z",
    },
  )!;
  const second = lobbyModeSignalProjectionForRoom(
    { game_mode: "associations" },
    {
      projectionID: "00000000-0000-4000-8000-000000000002",
      emittedAt: "2026-09-02T12:00:01.000Z",
    },
  )!;
  const tieBreakWinner = lobbyModeSignalProjectionForRoom(
    { game_mode: "questions" },
    {
      projectionID: "00000000-0000-4000-8000-000000000003",
      emittedAt: "2026-09-02T12:00:01.000Z",
    },
  )!;

  assertEquals(
    await upsertGameRoomSignal(store, { ...baseSignal, ...first }),
    "created",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...baseSignal, ...second }),
    "updated",
  );
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "associations",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...baseSignal, ...tieBreakWinner }),
    "updated",
  );
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "questions",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...baseSignal, ...second }),
    "unchanged",
  );
});

Deno.test("newer generic or closed signals make retained projection fields inert", async () => {
  const store = new MemorySignalStore();
  const projection = lobbyModeSignalProjectionForRoom(
    { game_mode: "associations" },
    {
      projectionID: "00000000-0000-4000-8000-000000000001",
      emittedAt: "2026-09-02T12:00:00.000Z",
    },
  )!;
  await upsertGameRoomSignal(store, { ...baseSignal, ...projection });
  assertEquals(
    await upsertGameRoomSignal(store, {
      ...baseSignal,
      room_revision: 41,
      room_updated_at: "2026-09-02T12:00:01.000Z",
      projection_kind: "none",
    }),
    "updated",
  );
  assertEquals(store.rows[0].projected_game_mode, "associations");
  assertEquals(projectedLobbyModeFromSignal(store.rows[0]), null);

  assertEquals(
    await upsertGameRoomSignal(store, {
      ...baseSignal,
      room_revision: 42,
      state: "closed",
      projection_kind: "none",
    }),
    "updated",
  );
  assertEquals(projectedLobbyModeFromSignal(store.rows[0]), null);
});

Deno.test("mode CAS fanout updates two existing personal rows without creating recipients", async () => {
  const store = new MemorySignalStore();
  store.rows = [
    { id: "signal-1", ...baseSignal, user_id: "host-user" },
    { id: "signal-2", ...baseSignal, user_id: "guest-user" },
  ];
  const room = {
    id: "room-1",
    lobby_revision: 7,
    room_revision: 41,
    game_mode: "associations",
    participant_user_ids: ["host-user", "guest-user"],
    word: "must not leak",
    players: [{ user_id: "guest-user", email: "secret@example.com" }],
  };
  const projection = lobbyModeSignalProjectionForRoom(room, {
    projectionID: "00000000-0000-4000-8000-000000000001",
    emittedAt: "2026-09-02T12:00:00.100Z",
  });
  const result = await fanoutGameRoomSignalsBestEffort({
    store,
    room,
    projection,
    allowCreate: false,
  });

  assertEquals(result, { attempted: 2, succeeded: 2, failed: 0 });
  assertEquals(store.createCalls, 0);
  for (const row of store.rows) {
    assertEquals(row.room_revision, 41);
    assertEquals(row.projection_kind, "lobby_mode_v1");
    assertEquals(row.projected_game_mode, "associations");
    assert(!("word" in row), "room word leaked into personal signal row");
    assert(
      !("players" in row),
      "player payload leaked into personal signal row",
    );
  }
});

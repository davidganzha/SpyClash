import { roomCloseCompletionWithActivityEndQueued } from "./room-close-intent.ts";
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  compareAndSetGameRoomSignal,
  fanoutGameRoomSignalsBestEffort,
  GameRoomSignalRecord,
  GameRoomSignalStore,
  hasDurableClosedRoomSignal,
  lobbyModeSignalProjectionForRoom,
  projectedLobbyModeFromSignal,
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

  updateMany(
    filter: Record<string, unknown>,
    update: { $set: Partial<GameRoomSignalRecord> },
  ) {
    this.updateCalls += 1;
    if (this.failUsers.has(String(update.$set.user_id))) {
      return Promise.reject(new Error("unavailable"));
    }
    let updated = 0;
    for (let index = 0; index < this.rows.length; index += 1) {
      if (
        !Object.entries(filter).every(([key, value]) => {
          if (value && typeof value === "object" && "$exists" in value) {
            return (this.rows[index][key] !== undefined) === value.$exists;
          }
          return JSON.stringify(this.rows[index][key]) ===
            JSON.stringify(value);
        })
      ) continue;
      this.rows[index] = { ...this.rows[index], ...update.$set };
      updated += 1;
    }
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
  projection_kind: "none",
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
        projection_kind: "none",
      },
      {
        user_id: "user-2",
        room_id: "room-1",
        lobby_revision: 7,
        room_revision: 21,
        room_updated_at: "2026-08-06T12:00:01.000Z",
        state: "active",
        projection_kind: "none",
      },
      {
        user_id: "user-3",
        room_id: "room-1",
        lobby_revision: 7,
        room_revision: 21,
        room_updated_at: "2026-08-06T12:00:01.000Z",
        state: "active",
        projection_kind: "none",
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

Deno.test("lobby mode projection carries only the safe committed direct fields", () => {
  const projection = lobbyModeSignalProjectionForRoom(
    {
      id: "room-1",
      game_mode: "associations",
      updated_date: "2026-09-02T12:00:00.000Z",
      word: "must not leak",
      players: [{ email: "hidden@example.com" }],
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
    // The room timestamp is deliberately stale pre-CAS state. The direct
    // metric must use the server time captured only after CAS returned.
    projection_committed_at: "2026-09-02T12:00:00.100Z",
    projection_emitted_at: "2026-09-02T12:00:00.100Z",
  });

  assertEquals(
    lobbyModeSignalProjectionForRoom(
      { game_mode: "questions" },
      {
        projectionID: "00000000-0000-4000-8000-000000000002",
        emittedAt: "2026-09-02T12:00:01.250Z",
      },
    ),
    {
      projection_kind: "lobby_mode_v1",
      projection_id: "00000000-0000-4000-8000-000000000002",
      projected_game_mode: "questions",
      projection_committed_at: "2026-09-02T12:00:01.250Z",
      projection_emitted_at: "2026-09-02T12:00:01.250Z",
    },
  );
});

Deno.test("newer lobby mode projections update at one authoritative revision by timestamp and id", async () => {
  const store = new MemorySignalStore();
  const firstProjection = lobbyModeSignalProjectionForRoom(
    { game_mode: "questions" },
    {
      projectionID: "00000000-0000-4000-8000-000000000001",
      emittedAt: "2026-09-02T12:00:00.000Z",
    },
  )!;
  const secondProjection = lobbyModeSignalProjectionForRoom(
    { game_mode: "associations" },
    {
      projectionID: "00000000-0000-4000-8000-000000000002",
      emittedAt: "2026-09-02T12:00:01.000Z",
    },
  )!;
  const equalTimestampProjection = lobbyModeSignalProjectionForRoom(
    { game_mode: "questions" },
    {
      projectionID: "00000000-0000-4000-8000-000000000003",
      emittedAt: "2026-09-02T12:00:01.000Z",
    },
  )!;

  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, ...firstProjection }),
    "created",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, ...secondProjection }),
    "updated",
  );
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "associations",
  );
  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      ...firstProjection,
    }),
    "unchanged",
  );
  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      ...equalTimestampProjection,
    }),
    "updated",
  );
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "questions",
  );
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, ...secondProjection }),
    "unchanged",
  );
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "questions",
  );
});

Deno.test("newer generic and closed signals deactivate retained direct projection fields", async () => {
  const store = new MemorySignalStore();
  const projection = lobbyModeSignalProjectionForRoom(
    { game_mode: "associations" },
    {
      projectionID: "00000000-0000-4000-8000-000000000001",
      emittedAt: "2026-09-02T12:00:00.000Z",
    },
  )!;
  await upsertGameRoomSignal(store, { ...signal, ...projection });
  assertEquals(
    projectedLobbyModeFromSignal(store.rows[0])?.projected_game_mode,
    "associations",
  );

  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      room_revision: 13,
      room_updated_at: "2026-09-02T12:00:01.000Z",
      projection_kind: "none",
    }),
    "updated",
  );
  // Base44 updates may retain omitted optional values. The explicit kind is
  // therefore the only activation boundary and makes those values inert.
  assertEquals(store.rows[0].projected_game_mode, "associations");
  assertEquals(store.rows[0].projection_kind, "none");
  assertEquals(projectedLobbyModeFromSignal(store.rows[0]), null);

  await upsertGameRoomSignal(store, {
    ...signal,
    room_revision: 14,
    ...projection,
    projection_id: "00000000-0000-4000-8000-000000000004",
    projection_emitted_at: "2026-09-02T12:00:02.000Z",
  });
  assertEquals(
    await upsertGameRoomSignal(store, {
      ...signal,
      room_revision: 14,
      state: "closed",
      projection_kind: "none",
    }),
    "updated",
  );
  assertEquals(store.rows[0].state, "closed");
  assertEquals(store.rows[0].projection_kind, "none");
  assertEquals(projectedLobbyModeFromSignal(store.rows[0]), null);
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

function deferredSignalWrite() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

for (const closedRevision of [13, 14]) {
  Deno.test(`a delayed active CAS cannot reopen closed revision ${closedRevision}`, async () => {
    const store = new MemorySignalStore();
    store.rows = [{ id: "signal-1", ...signal }];
    const started = deferredSignalWrite();
    const finish = deferredSignalWrite();
    const update = store.updateMany.bind(store);
    let delay = true;
    store.updateMany = async (filter, patch) => {
      if (delay && patch.$set.state === "active") {
        delay = false;
        started.resolve();
        await finish.promise;
      }
      return await update(filter, patch);
    };
    const stale = upsertGameRoomSignal(store, { ...signal, room_revision: 13 });
    await started.promise;
    await upsertGameRoomSignal(store, {
      ...signal,
      room_revision: closedRevision,
      state: "closed",
    });
    finish.resolve();
    assertEquals(await stale, "unchanged");
    assertEquals(store.rows[0].room_revision, closedRevision);
    assertEquals(store.rows[0].state, "closed");
  });
}

Deno.test("reordered concurrent mode projections retain the newest direct projection", async () => {
  const store = new MemorySignalStore();
  store.rows = [{ id: "signal-1", ...signal }];
  const earlier = lobbyModeSignalProjectionForRoom({ game_mode: "questions" }, {
    projectionID: "00000000-0000-4000-8000-000000000001",
    emittedAt: "2026-09-06T09:00:00.000Z",
  })!;
  const later = lobbyModeSignalProjectionForRoom(
    { game_mode: "associations" },
    {
      projectionID: "00000000-0000-4000-8000-000000000002",
      emittedAt: "2026-09-06T09:00:01.000Z",
    },
  )!;
  const started = deferredSignalWrite();
  const finish = deferredSignalWrite();
  const update = store.updateMany.bind(store);
  let delay = true;
  store.updateMany = async (filter, patch) => {
    if (delay) {
      delay = false;
      started.resolve();
      await finish.promise;
    }
    return await update(filter, patch);
  };
  const stale = upsertGameRoomSignal(store, { ...signal, ...earlier });
  await started.promise;
  await upsertGameRoomSignal(store, { ...signal, ...later });
  finish.resolve();
  assertEquals(await stale, "unchanged");
  assertEquals(projectedLobbyModeFromSignal(store.rows[0]), later);
});

for (const allowCreate of [true, false]) {
  Deno.test(`account cleanup between read and CAS never recreates a signal (allowCreate=${allowCreate})`, async () => {
    const store = new MemorySignalStore();
    store.rows = [{ id: "signal-1", ...signal }];
    const update = store.updateMany.bind(store);
    store.updateMany = (filter, patch) => {
      store.rows = [];
      return update(filter, patch);
    };
    assertEquals(
      await upsertGameRoomSignal(store, { ...signal, room_revision: 13 }, {
        allowCreate,
      }),
      "missing",
    );
    assertEquals(store.rows, []);
    assertEquals(store.nextID, 1);
    assertEquals(store.updateCalls, 1);
  });
}

Deno.test("a committed signal with a lost CAS response is reconciled without a second write", async () => {
  const store = new MemorySignalStore();
  store.rows = [{ id: "signal-1", ...signal }];
  const update = store.updateMany.bind(store);
  store.updateMany = async (filter, patch) => {
    await update(filter, patch);
    throw new Error("response lost after commit");
  };
  assertEquals(
    await upsertGameRoomSignal(store, { ...signal, state: "closed" }),
    "unchanged",
  );
  assertEquals(store.rows[0].state, "closed");
  assertEquals(store.updateCalls, 1);
  assertEquals(store.filterCalls, 2);
});

Deno.test("signal CAS contention is bounded and leaves the authoritative row intact", async () => {
  const store = new MemorySignalStore();
  store.rows = [{ id: "signal-1", ...signal }];
  store.updateMany = () => {
    store.updateCalls += 1;
    return Promise.resolve({ updated: 0 });
  };
  await assertRejects(
    () => upsertGameRoomSignal(store, { ...signal, room_revision: 13 }),
    Error,
    "changed concurrently",
  );
  assertEquals(store.updateCalls, 3);
  assertEquals(store.filterCalls, 4);
  assertEquals(store.rows[0].room_revision, 12);
});

Deno.test("a stale close completion CAS cannot overwrite a replacement completion", async () => {
  const store = new MemorySignalStore();
  const original = {
    id: "signal-1",
    ...signal,
    state: "closed",
    close_completion: { intent_id: "close-1" },
  };
  store.rows = [{
    ...original,
    close_completion: { intent_id: "close-2", activity_end_queued: true },
  }];
  assertEquals(
    await compareAndSetGameRoomSignal(store, original, {
      close_completion: { intent_id: "close-1", activity_end_queued: true },
    }),
    false,
  );
  assertEquals(store.rows[0].close_completion, {
    intent_id: "close-2",
    activity_end_queued: true,
  });
});

Deno.test("a signal CAS does not match a row whose recipient binding changed", async () => {
  const store = new MemorySignalStore();
  const original = { id: "signal-1", ...signal };
  store.rows = [{ ...original, user_id: "replacement" }];
  assertEquals(
    await compareAndSetGameRoomSignal(store, original, { room_revision: 13 }),
    false,
  );
  assertEquals(store.rows[0].room_revision, 12);
});

Deno.test("a full-fanout receipt retry cannot revoke a concurrently queued Activity end", async () => {
  const store = new MemorySignalStore();
  const closed: GameRoomSignalRecord = {
    ...signal,
    state: "closed",
    close_intent_id: "close-1",
    close_match_id: "match-1",
  };
  const completion = {
    intent_id: "close-1",
    match_id: "match-1",
    room_id: "room-1",
    host_user_id: "user-1",
    participant_user_ids: ["user-1"],
    participant_count: 1,
    completed_at: "2026-09-06T09:00:00.000Z",
  };
  const queued = roomCloseCompletionWithActivityEndQueued({
    completion,
    now: new Date("2026-09-06T09:00:01.000Z"),
  });
  const original = { id: "signal-1", ...closed };
  store.rows = [original];
  const started = deferredSignalWrite();
  const finish = deferredSignalWrite();
  const update = store.updateMany.bind(store);
  let delay = true;
  store.updateMany = async (filter, patch) => {
    if (delay) {
      delay = false;
      started.resolve();
      await finish.promise;
    }
    return await update(filter, patch);
  };
  const stale = upsertGameRoomSignal(store, {
    ...closed,
    close_completion: completion,
  });
  await started.promise;
  assertEquals(
    await compareAndSetGameRoomSignal(store, original, {
      close_completion: queued,
    }),
    true,
  );
  finish.resolve();
  assertEquals(await stale, "unchanged");
  assertEquals(store.rows[0].close_completion, queued);
  assertEquals(store.updateCalls, 2);
});

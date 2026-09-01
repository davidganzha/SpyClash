import { assertEquals } from "jsr:@std/assert@1";
import {
  fanoutGameRoomSignalsBestEffort,
  type GameRoomSignalRecord,
  type GameRoomSignalStore,
  lobbyModeSignalProjectionForRepair,
  lobbyModeSignalProjectionForRoom,
} from "./game-room-signal.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  lobbyMutationPatch,
  validateLobbyMutation,
} from "./lobby-state-policy.ts";
import { projectRoomForClient } from "./room-projection.ts";
import { gameModePatch } from "./room-interaction-safety.ts";
import { runLatestRoomSignalAfterLeaseContention } from "./post-lease-signal.ts";
import { writeRoomWithCAS } from "./room-write-cas.ts";

class MemoryRoomStore {
  room: Record<string, any>;

  constructor(room: Record<string, any>) {
    this.room = { ...room };
  }

  updateMany(
    filter: Record<string, unknown>,
    update: Record<string, any>,
  ) {
    if (
      this.room.id !== filter.id ||
      this.room.room_revision !== filter.room_revision
    ) {
      return Promise.resolve({ updated: 0 });
    }
    this.room = { ...this.room, ...(update.$set || {}) };
    return Promise.resolve({ updated: 1 });
  }
}

class MemorySignalStore implements GameRoomSignalStore {
  rows: Array<Record<string, unknown>> = [];
  private nextID = 1;
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
    if (index < 0) return Promise.reject(new Error("missing signal"));
    this.rows[index] = { ...this.rows[index], ...data };
    return Promise.resolve(this.rows[index]);
  }
}

Deno.test("accepted lobby mutation signals the same authoritative pool to three participants", async () => {
  const participants = [
    { userID: "user-host", email: "host@example.com" },
    { userID: "user-guest-a", email: "guest-a@example.com" },
    { userID: "user-guest-b", email: "guest-b@example.com" },
  ];
  const startingRoom: Record<string, any> = {
    id: "room-1",
    code: "SYNC16",
    host_email: participants[0].email,
    status: "waiting",
    players: participants.map(({ userID, email }) => ({
      user_id: userID,
      email,
      name: userID,
    })),
    participant_user_ids: participants.map(({ userID }) => userID),
    lobby_schema_version: 2,
    lobby_revision: 4,
    room_revision: 10,
    game_mode: "questions",
    game_duration_seconds: 900,
    lobby_spy_count: 1,
    spies_know_each_other: false,
    lobby_word_source: "manual",
    lobby_source_pack_id: "old-pack",
    lobby_source_name: "Old pack",
    lobby_theme: "Old theme",
    lobby_category: "Old category",
    lobby_word_count: 2,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "old-1", word: "Old one", enabled: true },
      { id: "old-2", word: "Old two", enabled: true },
    ],
  };
  const mutation = validateLobbyMutation({
    mutation_id: "lobby-mutation-5",
    expected_revision: 4,
    state: {
      game_mode: "associations",
      game_duration_seconds: 600,
      lobby_spy_count: 2,
      spies_know_each_other: true,
      lobby_word_source: "saved",
      lobby_source_pack_id: "city-pack",
      lobby_source_name: "City pack",
      lobby_theme: "Night cities",
      lobby_category: "Places",
      lobby_word_count: 3,
      lobby_word_count_mode: "custom",
      lobby_word_pool: [
        { id: "kyiv", word: "Kyiv", enabled: true },
        { id: "london", word: "London", enabled: true },
        { id: "tokyo", word: "Tokyo", enabled: false },
      ],
    },
  });

  const roomStore = new MemoryRoomStore(startingRoom);
  const committedRoom = await writeRoomWithCAS({
    store: roomStore,
    room: startingRoom,
    patch: lobbyMutationPatch(startingRoom, mutation),
    randomUUID: () => "room-write-11",
  });
  assertEquals(committedRoom.lobby_revision, 5);
  assertEquals(committedRoom.room_revision, 11);

  const signalStore = new MemorySignalStore();
  assertEquals(
    await fanoutGameRoomSignalsBestEffort({
      store: signalStore,
      room: committedRoom,
    }),
    { attempted: 3, succeeded: 3, failed: 0 },
  );

  for (const participant of participants) {
    const signal = signalStore.rows.find((row) =>
      row.user_id === participant.userID
    );
    assertEquals(signal?.room_id, "room-1");
    assertEquals(signal?.lobby_revision, 5);
    assertEquals(signal?.room_revision, 11);

    const projection = projectRoomForClient(committedRoom, {
      email: participant.email,
    });
    assertEquals(projection?.lobby_revision, 5);
    assertEquals(projection?.room_revision, 11);
    assertEquals(projection?.game_mode, "associations");
    assertEquals(projection?.lobby_theme, "Night cities");
    assertEquals(projection?.lobby_category, "Places");
    assertEquals(projection?.lobby_word_count, 3);
    assertEquals(projection?.lobby_word_count_mode, "custom");
    assertEquals(projection?.lobby_word_pool, [
      { id: "kyiv", word: "Kyiv", enabled: true },
      { id: "london", word: "London", enabled: true },
      { id: "tokyo", word: "Tokyo", enabled: false },
    ]);
  }
});

Deno.test("mode-only CAS fans out one safe direct projection without advancing lobby revision", async () => {
  const participants = ["user-host", "user-guest"];
  const startingRoom: Record<string, any> = {
    id: "room-mode",
    host_email: "host@example.com",
    status: "waiting",
    participant_user_ids: participants,
    players: [
      { user_id: participants[0], email: "host@example.com" },
      { user_id: participants[1], email: "guest@example.com" },
    ],
    lobby_revision: 7,
    room_revision: 40,
    updated_date: "2026-09-02T12:00:00.000Z",
    game_mode: "questions",
    word: "must not leak",
    lobby_word_pool: [{ word: "must not leak" }],
  };
  const roomStore = new MemoryRoomStore(startingRoom);
  const committedRoom = await writeRoomWithCAS({
    store: roomStore,
    room: startingRoom,
    patch: gameModePatch(startingRoom, "associations"),
    randomUUID: () => "room-write-41",
  });
  const projection = lobbyModeSignalProjectionForRoom(committedRoom, {
    projectionID: "00000000-0000-4000-8000-000000000041",
    emittedAt: "2026-09-02T12:00:00.100Z",
  });
  const signalStore = new MemorySignalStore();

  assertEquals(committedRoom.room_revision, 41);
  assertEquals(committedRoom.lobby_revision, 7);
  assertEquals(
    await fanoutGameRoomSignalsBestEffort({
      store: signalStore,
      room: committedRoom,
      projection,
    }),
    { attempted: 2, succeeded: 2, failed: 0 },
  );
  for (const row of signalStore.rows) {
    assertEquals(row.room_revision, 41);
    assertEquals(row.lobby_revision, 7);
    assertEquals(row.projection_kind, "lobby_mode_v1");
    assertEquals(row.projection_id, "00000000-0000-4000-8000-000000000041");
    assertEquals(row.projected_game_mode, "associations");
    assertEquals(
      row.projection_committed_at,
      "2026-09-02T12:00:00.100Z",
    );
    assertEquals(row.projection_emitted_at, "2026-09-02T12:00:00.100Z");
    assertEquals("word" in row, false);
    assertEquals("lobby_word_pool" in row, false);
    assertEquals("players" in row, false);
  }
});

Deno.test("mode signal repair preserves the original projection at the same authoritative revision", async () => {
  const participants = ["user-host", "user-guest"];
  const committedRoom: Record<string, any> = {
    id: "room-mode-repair",
    status: "waiting",
    participant_user_ids: participants,
    players: participants.map((user_id) => ({ user_id })),
    lobby_revision: 7,
    room_revision: 41,
    game_mode: "associations",
  };
  const committedProjection = lobbyModeSignalProjectionForRoom(committedRoom, {
    projectionID: "00000000-0000-4000-8000-000000000041",
    emittedAt: "2026-09-02T12:00:00.100Z",
  });
  const signalStore = new MemorySignalStore();
  signalStore.rows = participants.map((userID) => ({
    id: `signal-${userID}`,
    user_id: userID,
    room_id: committedRoom.id,
    lobby_revision: 7,
    room_revision: 40,
    state: "active",
    projection_kind: "none",
  }));
  let attempts = 0;
  let latestReads = 0;
  const delays: number[] = [];

  const completed = await runLatestRoomSignalAfterLeaseContention({
    initial: committedRoom,
    attempt: async (candidate) => {
      attempts += 1;
      if (attempts === 1) {
        throw new BillingIdentityLifecycleError(
          "active_lease",
          "another post-commit fanout still owns the identity lease",
        );
      }
      const projection = lobbyModeSignalProjectionForRepair(
        committedRoom,
        candidate,
        committedProjection,
      );
      const result = await fanoutGameRoomSignalsBestEffort({
        store: signalStore,
        room: candidate,
        projection,
        allowCreate: false,
      });
      return result.failed === 0;
    },
    loadLatest: () => {
      latestReads += 1;
      return Promise.resolve({ ...committedRoom });
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
  });

  assertEquals(completed, true);
  assertEquals(attempts, 2);
  assertEquals(latestReads, 1);
  assertEquals(delays, [25]);
  assertEquals(signalStore.createCalls, 0);
  assertEquals(signalStore.rows.length, 2);
  for (const row of signalStore.rows) {
    assertEquals(row.room_revision, 41);
    assertEquals(row.lobby_revision, 7);
    assertEquals(row.projection_kind, "lobby_mode_v1");
    assertEquals(
      row.projection_id,
      "00000000-0000-4000-8000-000000000041",
    );
    assertEquals(
      row.projection_committed_at,
      "2026-09-02T12:00:00.100Z",
    );
    assertEquals(row.projected_game_mode, "associations");
  }
});

Deno.test("mode signal repair downgrades a later authoritative revision to a generic refresh", async () => {
  const committedRoom: Record<string, any> = {
    id: "room-mode-repair-later-write",
    status: "waiting",
    participant_user_ids: ["user-host", "user-guest"],
    players: [
      { user_id: "user-host" },
      { user_id: "user-guest" },
    ],
    lobby_revision: 7,
    room_revision: 41,
    game_mode: "associations",
  };
  const committedProjection = lobbyModeSignalProjectionForRoom(committedRoom, {
    projectionID: "00000000-0000-4000-8000-000000000041",
    emittedAt: "2026-09-02T12:00:00.100Z",
  });
  const laterKickRoom = {
    ...committedRoom,
    participant_user_ids: ["user-host"],
    players: [{ user_id: "user-host" }],
    room_revision: 42,
  };
  const signalStore = new MemorySignalStore();
  signalStore.rows = [{
    id: "signal-user-host",
    user_id: "user-host",
    room_id: committedRoom.id,
    lobby_revision: 7,
    room_revision: 40,
    state: "active",
    projection_kind: "none",
  }];
  let attempts = 0;

  const completed = await runLatestRoomSignalAfterLeaseContention({
    initial: committedRoom,
    attempt: async (candidate) => {
      attempts += 1;
      if (attempts === 1) {
        throw new BillingIdentityLifecycleError(
          "active_lease",
          "a later membership write owns the identity lease",
        );
      }
      const result = await fanoutGameRoomSignalsBestEffort({
        store: signalStore,
        room: candidate,
        projection: lobbyModeSignalProjectionForRepair(
          committedRoom,
          candidate,
          committedProjection,
        ),
        allowCreate: false,
      });
      return result.failed === 0;
    },
    loadLatest: () => Promise.resolve(laterKickRoom),
    delay: () => Promise.resolve(),
  });

  assertEquals(completed, true);
  assertEquals(attempts, 2);
  assertEquals(signalStore.rows, [{
    id: "signal-user-host",
    user_id: "user-host",
    room_id: committedRoom.id,
    lobby_revision: 7,
    room_revision: 42,
    state: "active",
    projection_kind: "none",
  }]);
});

import { assertEquals } from "jsr:@std/assert@1";
import {
  fanoutGameRoomSignalsBestEffort,
  type GameRoomSignalRecord,
  type GameRoomSignalStore,
} from "./game-room-signal.ts";
import {
  lobbyMutationPatch,
  validateLobbyMutation,
} from "./lobby-state-policy.ts";
import { projectRoomForClient } from "./room-projection.ts";
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

  filter(query: Record<string, unknown>) {
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ),
    );
  }

  create(data: GameRoomSignalRecord) {
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

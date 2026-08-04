import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  projectRoomForClient,
  shouldRedactRoomSecret,
} from "./room-projection.ts";

Deno.test("active spy projection hides secret data and internal identities", () => {
  const room = {
    id: "room-1",
    match_id: "opaque-match-7d1c",
    code: "ABC123",
    host_email: "host@example.com",
    status: "playing",
    spy_email: "spy@example.com",
    word: "Embassy",
    category: "Places",
    players: [
      {
        user_id: "hidden-id",
        email: "spy@example.com",
        name: "Raven",
        avatar: "🎭",
      },
    ],
    participant_user_ids: ["hidden-id"],
    created_by: "hidden@example.com",
    word_pool: [{ word: "Embassy", enabled: true }],
    intro_started_at: "2026-07-21T12:00:00.000Z",
    game_paused_at: "2026-07-21T12:01:00.000Z",
    game_paused_total_seconds: 12,
  };
  const projected = projectRoomForClient(room, { email: "SPY@example.com" });
  assert(projected);
  assertEquals(
    shouldRedactRoomSecret(room, { email: "SPY@example.com" }),
    true,
  );
  assertEquals(projected.word, "CLASSIFIED");
  assertEquals(projected.secret_word, "CLASSIFIED");
  assertEquals(projected.spy_email, "spy@example.com");
  assertEquals(projected.word_pool, [{ word: "Embassy", enabled: true }]);
  assertEquals(projected.intro_started_at, "2026-07-21T12:00:00.000Z");
  assertEquals(projected.game_paused_at, "2026-07-21T12:01:00.000Z");
  assertEquals(projected.game_paused_total_seconds, 12);
  assertEquals(projected.match_id, "opaque-match-7d1c");
  assertEquals("participant_user_ids" in projected, false);
  assertEquals("created_by" in projected, false);
  assertEquals("game_started_event_id" in projected, false);
  assertEquals("game_finished_event_id" in projected, false);
  assertEquals("user_id" in projected.players[0], false);
});

Deno.test("detective sees a safe secret only after authenticated room projection", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "playing",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
    },
    { email: "detective@example.com" },
  );
  assert(projected);
  assertEquals(projected.word, "Embassy");
  assertEquals(projected.spy_email, "");
});

Deno.test("spectator cannot identify the spy before the room finishes", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "roulette",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
      word_pool: [{ word: "Embassy", enabled: true }],
    },
    { email: "spectator@example.com" },
  );
  assert(projected);
  assertEquals(projected.spy_email, "");
  assertEquals(projected.word_pool, [{ word: "Embassy", enabled: true }]);
});

Deno.test("finished projection reveals the resolved spy and word", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "finished",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
    },
    { email: "detective@example.com" },
  );
  assert(projected);
  assertEquals(projected.spy_email, "spy@example.com");
  assertEquals(projected.word, "Embassy");
  assertEquals(projected.secret_word, "Embassy");
});

Deno.test("waiting lobby projection synchronizes the safe draft but keeps source identity host-only", () => {
  const room = {
    id: "room-1",
    code: "ABC123",
    host_email: "host@example.com",
    status: "waiting",
    players: [],
    game_mode: "associations",
    game_duration_seconds: 300,
    lobby_schema_version: 1,
    lobby_revision: 4,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-private-1",
    lobby_source_name: "City pack",
    lobby_theme: "Cities",
    lobby_category: "Places",
    lobby_word_count: 2,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "embassy", word: "Embassy", enabled: true },
      { id: "harbor", word: "Harbor", enabled: false },
    ],
    lobby_last_mutation_id: "hidden-mutation",
    lobby_last_mutation_fingerprint: "hidden-fingerprint",
  };

  const guest = projectRoomForClient(room, { email: "guest@example.com" });
  assert(guest);
  assertEquals(guest.lobby_revision, 4);
  assertEquals(guest.lobby_word_source, "saved");
  assertEquals(guest.lobby_source_pack_id, "");
  assertEquals(guest.lobby_word_count_mode, "custom");
  assertEquals(guest.lobby_word_pool, [
    { id: "embassy", word: "Embassy", enabled: true },
    { id: "harbor", word: "Harbor", enabled: false },
  ]);
  assertEquals("lobby_last_mutation_id" in guest, false);
  assertEquals("lobby_last_mutation_fingerprint" in guest, false);

  const host = projectRoomForClient(room, { email: "HOST@example.com" });
  assertEquals(host?.lobby_source_pack_id, "pack-private-1");
});

Deno.test("active-room projection retains only the lobby revision and redacts the draft", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      host_email: "host@example.com",
      status: "roulette",
      players: [],
      lobby_schema_version: 1,
      lobby_revision: 9,
      lobby_word_source: "ai",
      lobby_theme: "Secret theme",
      lobby_category: "Secret category",
      lobby_word_count: 2,
      lobby_word_count_mode: "custom",
      lobby_word_pool: [
        { id: "one", word: "Disabled draft word", enabled: false },
        { id: "two", word: "Selected word", enabled: true },
      ],
    },
    { email: "host@example.com" },
  );
  assert(projected);
  assertEquals(projected.lobby_schema_version, 1);
  assertEquals(projected.lobby_revision, 9);
  assertEquals(projected.lobby_word_source, "none");
  assertEquals(projected.lobby_theme, "");
  assertEquals(projected.lobby_category, "");
  assertEquals(projected.lobby_word_count, 0);
  assertEquals(projected.lobby_word_pool, []);
});

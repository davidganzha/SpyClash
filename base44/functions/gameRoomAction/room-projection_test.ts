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
  };
  const projected = projectRoomForClient(room, { email: "spy@example.com" });
  assert(projected);
  assertEquals(
    shouldRedactRoomSecret(room, { email: "spy@example.com" }),
    true,
  );
  assertEquals(projected.word, "CLASSIFIED");
  assertEquals(projected.secret_word, "CLASSIFIED");
  assertEquals(projected.word_pool, []);
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
});

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { aggregateLeaderboard, isRankedOnlineHistory } from "./leaderboard.ts";

const TEST_PSEUDONYM_KEY = "test-only-leaderboard-key-32-bytes-minimum";
const OTHER_TEST_PSEUDONYM_KEY = "different-test-only-leaderboard-key-32-bytes";

Deno.test("leaderboard includes only ranked online games", () => {
  assertEquals(
    isRankedOnlineHistory({ match_type: "online", ranked: true }),
    true,
  );
  assertEquals(
    isRankedOnlineHistory({ match_type: "local", room_code: "ABC123" }),
    false,
  );
  assertEquals(isRankedOnlineHistory({ room_code: "ABC123" }), true);
  assertEquals(isRankedOnlineHistory({ room_code: "LOCAL" }), false);
});

Deno.test("leaderboard projection aggregates ratings without exposing emails or game secrets", async () => {
  const entries = await aggregateLeaderboard(
    [
      {
        id: "history-1",
        player_user_id: "user-alpha",
        player_email: "alpha@example.com",
        match_type: "online",
        ranked: true,
        role: "detective",
        won: true,
        word: "Embassy",
        room_code: "ABC123",
      },
      {
        id: "history-2",
        player_user_id: "user-bravo",
        player_email: "bravo@example.com",
        match_type: "online",
        ranked: true,
        role: "spy",
        won: true,
        word: "Satellite",
        room_code: "ABC123",
      },
      {
        id: "history-3",
        player_user_id: "user-alpha",
        player_email: "alpha@example.com",
        match_type: "local",
        ranked: false,
        role: "spy",
        won: true,
      },
      {
        id: "legacy-history",
        player_email: "legacy@example.com",
        match_type: "online",
        ranked: true,
        role: "spy",
        won: true,
      },
    ],
    "user-alpha",
    TEST_PSEUDONYM_KEY,
  );

  assertEquals(entries.length, 2);
  assertEquals(entries[0].rating, 60);
  assertEquals(entries[1].rating, 30);
  assertEquals(entries[1].display_name, "YOU");
  for (const entry of entries) {
    assert(!("email" in entry));
    assert(!("player_email" in entry));
    assert(!("word" in entry));
    assert(!("room_code" in entry));
  }
});

Deno.test("leaderboard public identity is stable across email changes", async () => {
  const before = await aggregateLeaderboard(
    [{
      player_user_id: "stable-user-id",
      player_email: "old@example.com",
      match_type: "online",
      ranked: true,
      role: "detective",
      won: true,
    }],
    "different-viewer",
    TEST_PSEUDONYM_KEY,
  );
  const after = await aggregateLeaderboard(
    [{
      player_user_id: "stable-user-id",
      player_email: "new@example.com",
      match_type: "online",
      ranked: true,
      role: "detective",
      won: true,
    }],
    "different-viewer",
    TEST_PSEUDONYM_KEY,
  );

  assertEquals(before[0].id, after[0].id);
  assertEquals(before[0].display_name, after[0].display_name);
});

Deno.test("leaderboard fails closed without a strong server pseudonym key", async () => {
  await assertRejects(
    () => aggregateLeaderboard([], "viewer", undefined),
    Error,
    "SPYCLASH_PSEUDONYM_KEY",
  );
  await assertRejects(
    () => aggregateLeaderboard([], "viewer", "too-short"),
    Error,
    "at least 32 bytes",
  );
});

Deno.test("leaderboard aliases are keyed and never expose raw identity", async () => {
  const record = {
    player_user_id: "raw-base44-user-id",
    player_email: "classified@example.com",
    match_type: "online",
    ranked: true,
    role: "detective",
    won: true,
  };
  const first = await aggregateLeaderboard(
    [record],
    "different-viewer",
    TEST_PSEUDONYM_KEY,
  );
  const second = await aggregateLeaderboard(
    [record],
    "different-viewer",
    OTHER_TEST_PSEUDONYM_KEY,
  );

  assert(first[0].id.startsWith("operative:"));
  assert(first[0].id !== second[0].id);
  assert(!JSON.stringify(first[0]).includes("raw-base44-user-id"));
  assert(!JSON.stringify(first[0]).includes("classified@example.com"));
});

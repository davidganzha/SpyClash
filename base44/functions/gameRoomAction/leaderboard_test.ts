import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  aggregateLeaderboard,
  isRankedOnlineHistory,
  loadAllLeaderboardHistory,
} from "./leaderboard.ts";

const TEST_PSEUDONYM_KEY = "test-only-leaderboard-key-32-bytes-minimum";
const OTHER_TEST_PSEUDONYM_KEY = "different-test-only-leaderboard-key-32-bytes";

Deno.test("leaderboard includes only ranked online games", () => {
  assertEquals(
    isRankedOnlineHistory({
      player_user_id: "user-a",
      match_type: "online",
      ranked: true,
    }),
    true,
  );
  assertEquals(
    isRankedOnlineHistory({
      match_type: "online",
      ranked: true,
      spy_count: 1,
      player_user_id: "user-a",
    }),
    true,
  );
  assertEquals(
    isRankedOnlineHistory({
      match_type: "online",
      ranked: true,
      spy_count: 2,
      player_user_id: "user-a",
    }),
    false,
  );
  assertEquals(
    isRankedOnlineHistory({
      player_user_id: "user-a",
      match_type: "local",
      room_code: "ABC123",
    }),
    false,
  );
  assertEquals(
    isRankedOnlineHistory({
      player_user_id: "user-a",
      room_code: "ABC123",
    }),
    true,
  );
  assertEquals(
    isRankedOnlineHistory({
      player_user_id: "user-a",
      room_code: "LOCAL",
    }),
    false,
  );
  assertEquals(
    isRankedOnlineHistory({
      player_email: "legacy@example.com",
      match_type: "online",
      ranked: true,
    }),
    false,
  );
});

Deno.test("duplicate match-player rows count once with a deterministic winner", async () => {
  const entries = await aggregateLeaderboard(
    [
      {
        id: "later-duplicate",
        created_date: "2026-09-01T12:00:01.000Z",
        result_key: "game-result:v1:match-1:user-a",
        match_id: "match-1",
        player_user_id: "user-a",
        match_type: "online",
        ranked: true,
        role: "spy",
        won: false,
      },
      {
        id: "first-authoritative",
        created_date: "2026-09-01T12:00:00.000Z",
        match_id: "match-1",
        player_user_id: "user-a",
        match_type: "online",
        ranked: true,
        role: "spy",
        won: true,
      },
    ],
    "user-a",
    TEST_PSEUDONYM_KEY,
  );

  assertEquals(entries[0].games, 1);
  assertEquals(entries[0].wins, 1);
  assertEquals(entries[0].rating, 60);
});

Deno.test("leaderboard paginates ranked history past the former 20k cap", async () => {
  const rows = Array.from({ length: 20_101 }, (_, index) => ({
    id: `history-${String(index).padStart(5, "0")}`,
    match_id: `match-${index}`,
    player_user_id: "user-a",
    match_type: "online",
    ranked: true,
    spy_count: 1,
    role: "detective",
    won: true,
  }));
  const store = {
    filter(
      _query: Record<string, unknown>,
      _sort?: string,
      limit = 100,
      skip = 0,
    ) {
      return Promise.resolve(rows.slice(skip, skip + limit));
    },
  };

  const loaded = await loadAllLeaderboardHistory(store);
  const entries = await aggregateLeaderboard(
    loaded,
    "user-a",
    TEST_PSEUDONYM_KEY,
  );

  assertEquals(loaded.length, 20_101);
  assertEquals(entries[0].games, 20_101);
  assertEquals(entries[0].rating, 603_030);
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

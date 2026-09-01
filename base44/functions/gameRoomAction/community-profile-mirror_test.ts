import { assertEquals } from "jsr:@std/assert@1";
import {
  type CommunityProfileMirrorStore,
  type CommunityProfileUserMirrorStore,
  reconcileCommunityProfileMirrors,
} from "./community-profile-mirror.ts";

type Entity = Record<string, unknown>;

class MemoryHistoryStore implements CommunityProfileMirrorStore {
  constructor(public rows: Entity[]) {}

  filter(
    query: Record<string, unknown>,
    _sort?: string,
    limit = 100,
    skip = 0,
  ) {
    const matching = this.rows.filter((row) =>
      Object.entries(query).every(([key, value]) => row[key] === value)
    );
    return Promise.resolve(matching.slice(skip, skip + limit));
  }
}

class MemoryUserStore implements CommunityProfileUserMirrorStore {
  updates: Array<{ id: string; patch: Entity }> = [];

  constructor(public rows: Entity[]) {}

  filter(query: Record<string, unknown>) {
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ),
    );
  }

  update(id: string, patch: Entity) {
    this.updates.push({ id, patch: structuredClone(patch) });
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing user"));
    this.rows[index] = { ...this.rows[index], ...patch };
    return Promise.resolve(this.rows[index]);
  }
}

function rankedHistory(
  id: string,
  userID: string,
  role: "spy" | "detective",
  won: boolean,
  overrides: Entity = {},
): Entity {
  return {
    id,
    player_user_id: userID,
    match_type: "online",
    ranked: true,
    spy_count: 1,
    role,
    won,
    ...overrides,
  };
}

Deno.test("community mirrors derive absolute ranked single-spy totals", async () => {
  const history = new MemoryHistoryStore([
    rankedHistory("history-1", "user-a", "detective", true),
    rankedHistory("history-2", "user-a", "spy", false),
    rankedHistory("local", "user-a", "spy", true, {
      match_type: "local",
      ranked: false,
    }),
    rankedHistory("unranked", "user-a", "spy", true, { ranked: false }),
    rankedHistory("multi-spy", "user-a", "spy", true, { spy_count: 2 }),
    rankedHistory("other-user", "user-b", "spy", true),
    {
      id: "legacy-email-only",
      player_email: "a@example.com",
      match_type: "online",
      ranked: true,
      spy_count: 1,
      role: "spy",
      won: true,
    },
  ]);
  const users = new MemoryUserStore([{
    id: "user-a",
    rating: 900,
    games_played: 99,
    games_won: 98,
  }]);
  const boundaries: string[] = [];

  const result = await reconcileCommunityProfileMirrors({
    historyStore: history,
    userStore: users,
    playerUserIDs: ["user-a", "user-a", ""],
    // The confirmed current-match overlay may already be visible in the
    // query; it must not be counted twice.
    knownHistoryRecords: [
      rankedHistory("history-1", "user-a", "detective", true),
    ],
    beforeUserUpdate: (userID) => {
      boundaries.push(userID);
      return Promise.resolve();
    },
  });

  assertEquals(result, [{
    userID: "user-a",
    stats: { rating: -10, games: 2, wins: 1, losses: 1 },
    status: "updated",
  }]);
  assertEquals(users.updates, [{
    id: "user-a",
    patch: { rating: -10, games_played: 2, games_won: 1 },
  }]);
  assertEquals(boundaries, ["user-a"]);
});

Deno.test("community mirror reconciliation is idempotent across retries", async () => {
  const history = new MemoryHistoryStore([
    rankedHistory("history-1", "user-a", "detective", true),
  ]);
  const users = new MemoryUserStore([{
    id: "user-a",
    rating: 0,
    games_played: 0,
    games_won: 0,
  }]);
  let boundaryCalls = 0;
  const reconcile = () =>
    reconcileCommunityProfileMirrors({
      historyStore: history,
      userStore: users,
      playerUserIDs: ["user-a"],
      beforeUserUpdate: () => {
        boundaryCalls += 1;
        return Promise.resolve();
      },
    });

  assertEquals((await reconcile())[0].status, "updated");
  assertEquals((await reconcile())[0].status, "unchanged");
  assertEquals(users.rows[0], {
    id: "user-a",
    rating: 30,
    games_played: 1,
    games_won: 1,
  });
  assertEquals(users.updates.length, 1);
  assertEquals(boundaryCalls, 1);
});

Deno.test("community mirror reads every history page before writing absolute totals", async () => {
  const history = new MemoryHistoryStore(
    Array.from(
      { length: 101 },
      (_, index) =>
        rankedHistory(
          `history-${index}`,
          "user-a",
          "detective",
          true,
        ),
    ),
  );
  const users = new MemoryUserStore([{
    id: "user-a",
    rating: 0,
    games_played: 0,
    games_won: 0,
  }]);

  await reconcileCommunityProfileMirrors({
    historyStore: history,
    userStore: users,
    playerUserIDs: ["user-a"],
  });

  assertEquals(users.updates, [{
    id: "user-a",
    patch: { rating: 3_030, games_played: 101, games_won: 101 },
  }]);
});

Deno.test("retry repairs a mirror after history persisted before the mirror write", async () => {
  const history = new MemoryHistoryStore([
    rankedHistory("history-1", "user-a", "detective", true),
  ]);
  const users = new MemoryUserStore([{
    id: "user-a",
    rating: 30,
    games_played: 1,
    games_won: 1,
  }]);

  const justPersisted = rankedHistory(
    "history-2",
    "user-a",
    "spy",
    false,
    { match_id: "match-current" },
  );
  const result = await reconcileCommunityProfileMirrors({
    historyStore: history,
    userStore: users,
    playerUserIDs: ["user-a"],
    // Model a successful create followed by a temporarily stale filter read.
    knownHistoryRecords: [justPersisted],
  });

  assertEquals(result[0], {
    userID: "user-a",
    stats: { rating: -10, games: 2, wins: 1, losses: 1 },
    status: "updated",
  });
  assertEquals(users.rows[0], {
    id: "user-a",
    rating: -10,
    games_played: 2,
    games_won: 1,
  });
});

Deno.test("deleted users are skipped instead of recreating profile identity", async () => {
  const history = new MemoryHistoryStore([
    rankedHistory("history-1", "deleted-user", "spy", true),
  ]);
  const users = new MemoryUserStore([]);
  let boundaryCalls = 0;

  const result = await reconcileCommunityProfileMirrors({
    historyStore: history,
    userStore: users,
    playerUserIDs: ["deleted-user"],
    beforeUserUpdate: () => {
      boundaryCalls += 1;
      return Promise.resolve();
    },
  });

  assertEquals(result, [{
    userID: "deleted-user",
    stats: { rating: 0, games: 0, wins: 0, losses: 0 },
    status: "missing_user",
  }]);
  assertEquals(users.updates, []);
  assertEquals(boundaryCalls, 0);
});

Deno.test("response-lost duplicate rows cannot inflate absolute mirrors", async () => {
  const first = rankedHistory("first", "user-a", "spy", true, {
    match_id: "match-1",
    result_key: "game-result:v1:match-1:user-a",
    created_date: "2026-09-01T00:00:00.000Z",
  });
  const duplicate = rankedHistory("duplicate", "user-a", "spy", false, {
    match_id: "match-1",
    result_key: "game-result:v1:match-1:user-a",
    created_date: "2026-09-01T00:00:01.000Z",
  });
  const history = new MemoryHistoryStore([duplicate, first]);
  const users = new MemoryUserStore([{
    id: "user-a",
    rating: 0,
    games_played: 0,
    games_won: 0,
  }]);

  await reconcileCommunityProfileMirrors({
    historyStore: history,
    userStore: users,
    playerUserIDs: ["user-a"],
  });

  assertEquals(users.rows[0], {
    id: "user-a",
    rating: 60,
    games_played: 1,
    games_won: 1,
  });
});

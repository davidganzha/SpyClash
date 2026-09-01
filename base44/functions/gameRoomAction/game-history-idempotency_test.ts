import { assertEquals } from "jsr:@std/assert@1";
import {
  gameHistoryResultKey,
  type GameHistoryResultStore,
  persistGameHistoryResult,
} from "./game-history-idempotency.ts";

type Entity = Record<string, unknown>;

class MemoryStore implements GameHistoryResultStore {
  rows: Entity[] = [];
  creates = 0;
  loseNextCreateResponse = false;

  filter(query: Entity, _sort?: string, limit = 100, skip = 0) {
    const rows = this.rows.filter((row) =>
      Object.entries(query).every(([key, value]) => row[key] === value)
    );
    return Promise.resolve(structuredClone(rows.slice(skip, skip + limit)));
  }

  create(value: Entity) {
    this.creates += 1;
    const created = {
      id: `history-${this.creates}`,
      created_date: `2026-09-01T00:00:0${this.creates}.000Z`,
      ...structuredClone(value),
    };
    this.rows.push(created);
    if (this.loseNextCreateResponse) {
      this.loseNextCreateResponse = false;
      return Promise.reject(new Error("response lost"));
    }
    return Promise.resolve(created);
  }
}

function record(overrides: Entity = {}): Entity {
  return {
    match_id: "match-1",
    player_user_id: "user-1",
    player_email: "player@example.com",
    match_type: "online",
    ranked: true,
    role: "detective",
    won: true,
    ...overrides,
  };
}

Deno.test("response-lost history create is recovered and retry stays idempotent", async () => {
  const store = new MemoryStore();
  store.loseNextCreateResponse = true;

  const first = await persistGameHistoryResult({ store, record: record() });
  const retry = await persistGameHistoryResult({ store, record: record() });

  assertEquals(first.status, "recovered");
  assertEquals(retry.status, "existing");
  assertEquals(store.creates, 1);
  assertEquals(store.rows.length, 1);
  assertEquals(
    store.rows[0].result_key,
    gameHistoryResultKey("match-1", "user-1"),
  );
});

Deno.test("rollout row without result_key is recovered only by stable owner", async () => {
  const store = new MemoryStore();
  store.rows = [{
    id: "legacy-stable",
    match_id: "match-1",
    player_user_id: "user-1",
    player_email: "old@example.com",
  }];

  const result = await persistGameHistoryResult({
    store,
    record: record({ player_email: "new@example.com" }),
  });

  assertEquals(result.status, "existing");
  assertEquals(store.creates, 0);
  assertEquals(store.rows.length, 1);
});

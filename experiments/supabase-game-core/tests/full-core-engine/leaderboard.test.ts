import assert from "node:assert/strict";
import { aggregateLeaderboard } from "../../supabase/functions/full-game-core/rules/leaderboard.ts";
import { aggregateCompetitiveStats, aggregateCompetitiveRoleStats } from "../../supabase/functions/full-game-core/rules/competitive-stats.ts";
import { readLeaderboard } from "../../supabase/functions/full-game-core/leaderboard-service.ts";

const secret = "isolated-test-pseudonym-key-32-bytes-minimum";
const a = "00000000-0000-4000-8000-000000000001";
const b = "00000000-0000-4000-8000-000000000002";
const c = "00000000-0000-4000-8000-000000000003";
let n = 0;
const result = (id: string, role: string, won: boolean, extra: Record<string, unknown> = {}) => ({
  id: `row${++n}`, match_id: `match${n}`, player_user_id: id, player_email: id + "@example.test",
  match_type: "online", ranked: true, room_code: "ABC234", role, won, spy_count: 1,
  word: "Never public", ...extra,
});
Deno.test("original competitive rating, dedup, role rates and single-spy eligibility", () => {
  const win = result(a, "spy", true);
  const records = [win, { ...win, id: "duplicate" }, result(a, "spy", false), result(a, "detective", true), result(a, "detective", false), result(a, "spy", true, { spy_count: 2 }), result(a, "spy", true, { match_type: "local" }), result(a, "spy", true, { ranked: false })];
  assert.deepEqual(aggregateCompetitiveStats(records).get(a), { rating: 30, games: 4, wins: 2, losses: 2 });
  assert.deepEqual(aggregateCompetitiveRoleStats(records).get(a), { spyGames: 2, spyWins: 1, detectiveGames: 2, detectiveWins: 1 });
});
Deno.test("original leaderboard tie breakers, opaque aliases and viewer marker", async () => {
  const records = [result(a, "spy", true), result(b, "detective", true), result(b, "detective", true), result(c, "spy", true)];
  const entries = await aggregateLeaderboard(records, b, secret);
  assert.equal(entries.length, 3);
  assert.equal(entries[0].display_name, "YOU"); assert.equal(entries[0].wins, 2); assert.equal(entries[0].is_current_user, true);
  const aAlone = (await aggregateLeaderboard(records.filter(r => r.player_user_id === a), a, secret))[0];
  assert.equal(entries[1].id, aAlone.id, "equal rating/wins/games uses stable original user-ID tie break");
  assert.match(entries[1].id, /^operative:[a-f0-9]{16}$/);
  const wire = JSON.stringify(entries);
  for (const raw of [a, b, c, "@example.test", "Never public", secret]) assert.ok(!wire.includes(raw));
  assert.deepEqual(Object.keys(entries[0]).sort(), ["display_name", "games", "id", "is_current_user", "losses", "rating", "wins"]);
  const differentKey = await aggregateLeaderboard(records, b, secret + "rotate");
  assert.notEqual(differentKey[0].id, entries[0].id);
  await assert.rejects(() => aggregateLeaderboard(records, b, "short"));
});
Deno.test("database reader returns exact original entries envelope and fails closed without key", async () => {
  const record = result(a, "spy", true);
  const queries: string[] = [];
  const db = async (sql: TemplateStringsArray) => {
    const text = sql.join(""); queries.push(text);
    return text.includes("configuration") ? [{ value: secret }] : [{ result: record, created_at: new Date("2026-10-12T12:00:00Z") }];
  };
  const response = await readLeaderboard(db, { id: a });
  assert.deepEqual(Object.keys(response), ["entries"]); assert.equal(response.entries[0].rating, 60);
  assert.equal(queries.length, 2); assert.ok(queries[1].includes("full_game_private.history"));
  await assert.rejects(() => readLeaderboard(async () => [], { id: a }));
});

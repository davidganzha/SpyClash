import { aggregateLeaderboard } from "./rules/leaderboard.ts";

/** Original rating/ranking/pseudonym contract over transactionally retained results.
 * The HMAC key is private database configuration, never a client setting or log.
 * Stable UUIDs identify history internally; only HMAC aliases leave this reader.
 */
export async function readLeaderboard(
  db: any,
  actor: { id: string },
): Promise<{ entries: Awaited<ReturnType<typeof aggregateLeaderboard>> }> {
  const [configuration] = await db`
    select value from full_game_private.configuration
    where key = 'leaderboard_pseudonym'
  `;
  if (!configuration || typeof configuration.value !== "string") {
    throw new Error("Leaderboard pseudonym configuration unavailable");
  }
  // Match the original all-history aggregation, including canonical rankable
  // row validation, deduplication, tie breaking and the top-100 boundary.
  const rows = await db`
    select result, created_at from full_game_private.history
    order by created_at asc, match_id, player_id
  `;
  const records = rows.map((row: { result: Record<string, unknown>; created_at: Date | string }) => ({
    ...row.result,
    id: row.result.result_key,
    created_date: row.created_at instanceof Date ? row.created_at.toISOString() : String(row.created_at),
  }));
  return { entries: await aggregateLeaderboard(records, actor.id, configuration.value) };
}

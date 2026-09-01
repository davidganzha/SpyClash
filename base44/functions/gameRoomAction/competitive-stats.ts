export type CompetitiveStats = {
  rating: number;
  games: number;
  wins: number;
  losses: number;
};

type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function hasSingleSpy(record: Entity): boolean {
  const rawSpyCount = clean(record?.spy_count);
  // Rows retained before multi-spy shipped have no frozen count; those games
  // were necessarily single-spy and remain leaderboard-compatible.
  if (!rawSpyCount) return true;
  const spyCount = Number(rawSpyCount);
  return Number.isInteger(spyCount) && spyCount === 1;
}

export function isRankedOnlineHistory(
  record: Entity,
): boolean {
  // Mutable email is intentionally never a competitive identity. Historical
  // email-only rows remain visible to their owner but do not affect mirrors,
  // role rates, or the public leaderboard.
  if (!clean(record?.player_user_id)) return false;
  if (!hasSingleSpy(record)) return false;

  const matchType = clean(record?.match_type).toLocaleLowerCase();
  if (matchType) return matchType === "online" && record?.ranked !== false;
  if (record?.ranked === false) return false;

  const roomCode = clean(record?.room_code).toUpperCase();
  return /^[A-Z0-9]{6}$/.test(roomCode);
}

function logicalResultKey(record: Entity, index: number): string {
  const matchID = clean(record?.match_id);
  const userID = clean(record?.player_user_id);
  if (matchID && userID) return `match-player:${matchID}:${userID}`;
  const resultKey = clean(record?.result_key);
  if (resultKey) return `result:${resultKey}`;
  const id = clean(record?.id);
  return id ? `id:${id}` : `unkeyed:${index}`;
}

function canonicalRow(left: Entity, right: Entity): Entity {
  const compare = clean(left?.created_date).localeCompare(
    clean(right?.created_date),
  ) || clean(left?.id).localeCompare(clean(right?.id)) ||
    JSON.stringify(left).localeCompare(JSON.stringify(right));
  return compare <= 0 ? left : right;
}

export function deduplicateCompetitiveHistory(
  records: readonly Entity[],
): Entity[] {
  const canonical = new Map<string, Entity>();
  records.forEach((record, index) => {
    const resultKey = logicalResultKey(record, index);
    const existing = canonical.get(resultKey);
    canonical.set(
      resultKey,
      existing ? canonicalRow(existing, record) : record,
    );
  });
  return [...canonical.values()];
}

export function competitiveRatingDelta(
  record: Entity,
): number {
  const detective = clean(record?.role).toLocaleLowerCase() === "detective";
  if (record?.won === true) return detective ? 30 : 60;
  return detective ? -20 : -40;
}

export function aggregateCompetitiveStats(
  records: readonly Entity[],
): Map<string, CompetitiveStats> {
  const table = new Map<string, CompetitiveStats>();

  for (const record of deduplicateCompetitiveHistory(records)) {
    if (!isRankedOnlineHistory(record)) continue;
    // Email is mutable and enumerable. Competitive identity is always the
    // opaque Base44 user id; legacy email-only rows remain intentionally
    // unlinked instead of being attached to the wrong account.
    const userID = clean(record?.player_user_id);
    if (!userID) continue;
    const stats = table.get(userID) || {
      rating: 0,
      games: 0,
      wins: 0,
      losses: 0,
    };
    stats.games += 1;
    stats.rating += competitiveRatingDelta(record);
    if (record?.won === true) stats.wins += 1;
    else stats.losses += 1;
    table.set(userID, stats);
  }

  return table;
}

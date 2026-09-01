import {
  aggregateCompetitiveRoleStats,
  aggregateCompetitiveStats,
  type CompetitiveRoleStats,
  type CompetitiveStats,
} from "./competitive-stats.ts";

type Entity = Record<string, unknown>;

export type CommunityProfileMirrorStore = {
  filter(
    query: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ): Promise<Entity[]>;
};

export type CommunityProfileUserMirrorStore = CommunityProfileMirrorStore & {
  update(id: string, patch: Entity): Promise<unknown>;
};

export type CommunityProfileMirrorResult = {
  userID: string;
  stats: CompetitiveStats;
  status: "updated" | "unchanged" | "missing_user";
};

const HISTORY_PAGE_SIZE = 100;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function uniqueUserIDs(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

function mirrorNumber(value: unknown): number | null {
  if (value === null || value === undefined || clean(value) === "") return null;
  const candidate = Number(value);
  return Number.isFinite(candidate) ? candidate : null;
}

function historyKeys(record: Entity): string[] {
  const keys: string[] = [];
  const id = clean(record?.id);
  if (id) keys.push(`id:${id}`);
  const matchID = clean(record?.match_id);
  const playerUserID = clean(record?.player_user_id);
  if (matchID && playerUserID) {
    keys.push(`match-player:${matchID}:${playerUserID}`);
  }
  return keys;
}

function appendKnownHistory(
  records: Entity[],
  knownHistoryRecords: readonly Entity[],
  userID: string,
): Entity[] {
  const knownKeys = new Set(records.flatMap(historyKeys));
  for (const record of knownHistoryRecords) {
    if (clean(record?.player_user_id) !== userID) continue;
    const keys = historyKeys(record);
    if (keys.some((key) => knownKeys.has(key))) continue;
    records.push(record);
    for (const key of keys) knownKeys.add(key);
  }
  return records;
}

async function loadUserHistory(
  store: CommunityProfileMirrorStore,
  userID: string,
  knownHistoryRecords: readonly Entity[],
): Promise<Entity[]> {
  const records: Entity[] = [];
  const seenIDs = new Set<string>();

  for (let skip = 0;; skip += HISTORY_PAGE_SIZE) {
    const page = await store.filter(
      { player_user_id: userID },
      "-created_date",
      HISTORY_PAGE_SIZE,
      skip,
    ) || [];
    const unseen = page.filter((record) => {
      const id = clean(record?.id);
      if (!id) return true;
      if (seenIDs.has(id)) return false;
      seenIDs.add(id);
      return true;
    });
    records.push(...unseen);
    if (page.length < HISTORY_PAGE_SIZE) break;
  }

  // A successful create is authoritative even if a follow-up list query is
  // briefly stale. The overlay is deduplicated against the durable read and
  // never contains a record whose create call failed.
  return appendKnownHistory(records, knownHistoryRecords, userID);
}

function emptyStats(): CompetitiveStats {
  return { rating: 0, games: 0, wins: 0, losses: 0 };
}

function emptyRoleStats(): CompetitiveRoleStats {
  return {
    spyGames: 0,
    spyWins: 0,
    detectiveGames: 0,
    detectiveWins: 0,
  };
}

export async function reconcileCommunityProfileMirrors(input: {
  historyStore: CommunityProfileMirrorStore;
  userStore: CommunityProfileUserMirrorStore;
  playerUserIDs: readonly unknown[];
  knownHistoryRecords?: readonly Entity[];
  beforeUserUpdate?: (userID: string) => Promise<void>;
}): Promise<CommunityProfileMirrorResult[]> {
  const results: CommunityProfileMirrorResult[] = [];

  for (const userID of uniqueUserIDs(input.playerUserIDs)) {
    const [history, users] = await Promise.all([
      loadUserHistory(
        input.historyStore,
        userID,
        input.knownHistoryRecords || [],
      ),
      input.userStore.filter({ id: userID }),
    ]);
    const user = users?.[0];
    if (!user) {
      results.push({ userID, stats: emptyStats(), status: "missing_user" });
      continue;
    }

    const stats = aggregateCompetitiveStats(history).get(userID) ||
      emptyStats();
    const roleStats = aggregateCompetitiveRoleStats(history).get(userID) ||
      emptyRoleStats();
    const patch = {
      rating: stats.rating,
      games_played: stats.games,
      games_won: stats.wins,
      spy_games_played: roleStats.spyGames,
      spy_games_won: roleStats.spyWins,
      detective_games_played: roleStats.detectiveGames,
      detective_games_won: roleStats.detectiveWins,
    };
    const unchanged = mirrorNumber(user.rating) === patch.rating &&
      mirrorNumber(user.games_played) === patch.games_played &&
      mirrorNumber(user.games_won) === patch.games_won &&
      mirrorNumber(user.spy_games_played) === patch.spy_games_played &&
      mirrorNumber(user.spy_games_won) === patch.spy_games_won &&
      mirrorNumber(user.detective_games_played) ===
        patch.detective_games_played &&
      mirrorNumber(user.detective_games_won) === patch.detective_games_won;
    if (unchanged) {
      results.push({ userID, stats, status: "unchanged" });
      continue;
    }

    await input.beforeUserUpdate?.(userID);
    await input.userStore.update(userID, patch);
    results.push({ userID, stats, status: "updated" });
  }

  return results;
}

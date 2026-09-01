import { aggregateCompetitiveStats } from "./competitive-stats.ts";

export { isRankedOnlineHistory } from "./competitive-stats.ts";

const HISTORY_PAGE_SIZE = 100;
const MAX_LEADERBOARD_ENTRIES = 100;
const PSEUDONYM_KEY_ENV = "SPYCLASH_PSEUDONYM_KEY";

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function requirePseudonymKey(value: unknown): string {
  const key = String(value ?? "");
  if (new TextEncoder().encode(key).byteLength < 32) {
    throw new Error(
      `${PSEUDONYM_KEY_ENV} must be configured with at least 32 bytes`,
    );
  }
  return key;
}

async function privacySafePlayerID(
  userID: string,
  pseudonymKey: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pseudonymKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`spyclash-leaderboard-user:v1:${userID}`),
  );
  const suffix = Array.from(new Uint8Array(digest).slice(0, 8))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `operative:${suffix}`;
}

export async function aggregateLeaderboard(
  records: readonly Record<string, any>[],
  viewerUserIDValue: unknown,
  pseudonymKeyValue: unknown,
) {
  // Public aliases must be unlinkable without a server-held secret. Refuse to
  // produce even an empty leaderboard if release configuration is incomplete.
  const pseudonymKey = requirePseudonymKey(pseudonymKeyValue);
  const table = aggregateCompetitiveStats(records);

  const viewerUserID = clean(viewerUserIDValue);
  const ranked = [...table.entries()]
    .sort(([leftUserID, left], [rightUserID, right]) =>
      right.rating - left.rating ||
      right.wins - left.wins ||
      right.games - left.games ||
      leftUserID.localeCompare(rightUserID)
    )
    .slice(0, MAX_LEADERBOARD_ENTRIES);

  return await Promise.all(ranked.map(async ([userID, stats]) => {
    const id = await privacySafePlayerID(userID, pseudonymKey);
    const isCurrentUser = userID === viewerUserID;
    return {
      id,
      display_name: isCurrentUser
        ? "YOU"
        : `OPERATIVE-${id.slice(-6).toUpperCase()}`,
      rating: stats.rating,
      games: stats.games,
      wins: stats.wins,
      losses: stats.losses,
      is_current_user: isCurrentUser,
    };
  }));
}

export async function loadLeaderboard(
  base44: any,
  viewer: Record<string, any>,
) {
  const records = await loadAllLeaderboardHistory(
    base44.asServiceRole.entities.GameHistory,
  );

  return {
    entries: await aggregateLeaderboard(
      records,
      viewer?.id,
      Deno.env.get(PSEUDONYM_KEY_ENV),
    ),
  };
}

export async function loadAllLeaderboardHistory(
  store: {
    filter(
      query: Record<string, unknown>,
      sort?: string,
      limit?: number,
      skip?: number,
    ): Promise<Record<string, any>[]>;
  },
  pageSize = HISTORY_PAGE_SIZE,
): Promise<Record<string, any>[]> {
  const records: Record<string, any>[] = [];
  const seenIDs = new Set<string>();
  const seenFullPageFingerprints = new Set<string>();
  const boundedPageSize = Math.max(1, Math.min(Number(pageSize) || 100, 500));

  for (let skip = 0;;) {
    const page = await store.filter(
      {},
      "-created_date",
      boundedPageSize,
      skip,
    ) || [];
    if (page.length === boundedPageSize) {
      const fingerprint = page.map((record) =>
        clean(record?.id) || JSON.stringify(record)
      ).join("\n");
      if (seenFullPageFingerprints.has(fingerprint)) {
        throw new Error("GameHistory pagination repeated a full page");
      }
      seenFullPageFingerprints.add(fingerprint);
    }
    const unseen = page.filter((record: Record<string, any>) => {
      const id = clean(record?.id);
      if (!id) return true;
      if (seenIDs.has(id)) return false;
      seenIDs.add(id);
      return true;
    });
    records.push(...unseen);
    skip += page.length;
    if (page.length < boundedPageSize) break;
  }
  return records;
}

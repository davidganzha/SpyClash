const HISTORY_PAGE_SIZE = 100;
const MAX_HISTORY_RECORDS = 20_000;
const MAX_LEADERBOARD_ENTRIES = 100;
const PSEUDONYM_KEY_ENV = "SPYCLASH_PSEUDONYM_KEY";

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function isRankedOnlineHistory(record: Record<string, any>): boolean {
  const matchType = clean(record?.match_type).toLocaleLowerCase();
  if (matchType) return matchType === "online" && record?.ranked !== false;
  if (record?.ranked === false) return false;

  const roomCode = clean(record?.room_code).toUpperCase();
  return /^[A-Z0-9]{6}$/.test(roomCode);
}

function ratingDelta(record: Record<string, any>): number {
  const detective = clean(record?.role).toLocaleLowerCase() === "detective";
  if (record?.won === true) return detective ? 30 : 60;
  return detective ? -20 : -40;
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
  const table = new Map<
    string,
    { rating: number; games: number; wins: number; losses: number }
  >();

  for (const record of records) {
    if (!isRankedOnlineHistory(record)) continue;
    // Email is mutable and enumerable. Only the opaque Base44 user id may
    // participate in the public identity projection. Legacy rows without one
    // are omitted instead of making email-derived identifiers guessable.
    const userID = clean(record?.player_user_id);
    if (!userID) continue;
    const stats = table.get(userID) || {
      rating: 0,
      games: 0,
      wins: 0,
      losses: 0,
    };
    stats.games += 1;
    stats.rating += ratingDelta(record);
    if (record?.won === true) stats.wins += 1;
    else stats.losses += 1;
    table.set(userID, stats);
  }

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
  const records: Record<string, any>[] = [];
  const seenIDs = new Set<string>();

  for (
    let skip = 0;
    skip < MAX_HISTORY_RECORDS;
    skip += HISTORY_PAGE_SIZE
  ) {
    const page = await base44.asServiceRole.entities.GameHistory.filter(
      {},
      "-created_date",
      HISTORY_PAGE_SIZE,
      skip,
    ) || [];
    const unseen = page.filter((record: Record<string, any>) => {
      const id = clean(record?.id);
      if (!id) return true;
      if (seenIDs.has(id)) return false;
      seenIDs.add(id);
      return true;
    });
    records.push(...unseen);
    if (page.length < HISTORY_PAGE_SIZE || !unseen.length) break;
  }

  return {
    entries: await aggregateLeaderboard(
      records,
      viewer?.id,
      Deno.env.get(PSEUDONYM_KEY_ENV),
    ),
  };
}

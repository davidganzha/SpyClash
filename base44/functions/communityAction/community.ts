import {
  safeCommunityAvatar,
  safeCommunityDisplayName,
} from "./community-safety.ts";

const SPY_ID_NAMESPACE = "com.spyclash.spyid.v2:";
const SPY_ID_CAPACITY = 1_000_000;
const RESERVED_MANUAL_SPY_IDS = new Set(["067-067"]);
const RADAR_INVITE_POLICIES = new Set(["ask", "automatic", "blocked"]);
export const PROFILE_COMMENT_MAX_LENGTH = 280;

export type RadarInvitePolicy = "ask" | "automatic" | "blocked";

export function normalizeRadarInvitePolicy(
  value: unknown,
): RadarInvitePolicy | null {
  const policy = String(value || "").trim().toLowerCase();
  return RADAR_INVITE_POLICIES.has(policy) ? policy as RadarInvitePolicy : null;
}

export function normalizeSpyID(value: unknown): string | null {
  const match = String(value || "")
    .trim()
    .match(/^([0-9]{3})[- ]?([0-9]{3})$/);
  return match ? `${match[1]}-${match[2]}` : null;
}

export function isReservedManualSpyID(value: unknown): boolean {
  const spyID = normalizeSpyID(value);
  return spyID !== null && RESERVED_MANUAL_SPY_IDS.has(spyID);
}

export async function stableSpyID(
  userID: string,
  attempt = 0,
): Promise<string> {
  const normalizedUserID = String(userID || "").trim();
  if (!normalizedUserID) {
    throw new Error("User ID required for SPY ID allocation");
  }

  const normalizedAttempt = Math.max(0, Math.trunc(attempt));
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      `${SPY_ID_NAMESPACE}${normalizedUserID}:${normalizedAttempt}`,
    ),
  );
  const value = new DataView(digest).getUint32(0, false) % SPY_ID_CAPACITY;
  const compact = String(value).padStart(6, "0");
  return `${compact.slice(0, 3)}-${compact.slice(3)}`;
}

export function preferredSpyIDOwner<T extends Record<string, unknown>>(
  users: T[],
): T | null {
  return [...users].sort((first, second) => {
    const firstCreated = Date.parse(
      String(first.created_date || first.created_at || ""),
    );
    const secondCreated = Date.parse(
      String(second.created_date || second.created_at || ""),
    );
    const firstTime = Number.isFinite(firstCreated)
      ? firstCreated
      : Number.MAX_SAFE_INTEGER;
    const secondTime = Number.isFinite(secondCreated)
      ? secondCreated
      : Number.MAX_SAFE_INTEGER;
    if (firstTime !== secondTime) return firstTime - secondTime;
    return String(first.id || "").localeCompare(String(second.id || ""));
  })[0] || null;
}

export function normalizeCommunityQuery(value: unknown): string {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, 64)
    .toLocaleLowerCase();
}

export function profileMatchesCommunityQuery(
  user: Record<string, unknown>,
  value: unknown,
): boolean {
  const query = normalizeCommunityQuery(value);
  if (!query) return true;

  const name = safeCommunityDisplayName(
    user.display_name || user.full_name || "",
  )
    .toLocaleLowerCase();
  const spyID = normalizeSpyID(user.spy_id) || "";
  const compactSpyID = spyID.replace("-", "");
  const compactQuery = query.replace(/[- ]/g, "");

  return name.includes(query) || spyID.includes(query) ||
    compactSpyID.includes(compactQuery);
}

export function sanitizeProfileComment(value: unknown): string | null {
  const comment = String(value || "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.trim().replace(/[ \t]+/g, " "))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  if (!comment || comment.length > PROFILE_COMMENT_MAX_LENGTH) return null;
  return comment;
}

export function roomAcceptsCommunityInvites(status: unknown): boolean {
  return String(status || "").trim().toLowerCase() === "waiting";
}

export function friendshipAllowsRoomInvite(
  friendships: Array<Record<string, unknown>>,
  firstUserID: unknown,
  secondUserID: unknown,
): boolean {
  const first = String(firstUserID || "").trim();
  const second = String(secondUserID || "").trim();
  if (!first || !second || first === second) return false;

  const pair = friendships.filter((friendship) => {
    const requester = String(friendship.requester_id || "").trim();
    const addressee = String(friendship.addressee_id || "").trim();
    return (requester === first && addressee === second) ||
      (requester === second && addressee === first);
  });
  if (
    pair.some((friendship) =>
      String(friendship.status || "").trim().toLowerCase() === "blocked"
    )
  ) {
    return false;
  }
  return pair.some((friendship) =>
    String(friendship.status || "").trim().toLowerCase() === "accepted"
  );
}

export function publicProfile(user: Record<string, unknown>) {
  const gamesPlayed = Number(user.games_played || 0);
  const gamesWon = Number(user.games_won || 0);

  return {
    id: String(user.id || ""),
    spy_id: normalizeSpyID(user.spy_id) || "",
    display_name: safeCommunityDisplayName(
      user.display_name || user.full_name || "OPERATIVE",
    ),
    avatar: safeCommunityAvatar(user.avatar),
    spy_card_theme: String(user.spy_card_theme || "field"),
    spy_card_accent: String(user.spy_card_accent || "signal_red"),
    spy_card_badge: String(user.spy_card_badge || "operative"),
    rating: Number(user.rating || 0),
    games_played: gamesPlayed,
    games_won: gamesWon,
    win_rate: gamesPlayed > 0 ? Math.round((gamesWon / gamesPlayed) * 100) : 0,
  };
}

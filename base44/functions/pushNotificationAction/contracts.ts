export const SPYCLASH_BUNDLE_ID = "com.spyclash.ios";

export class PushContractError extends Error {
  constructor(
    message: string,
    public readonly status = 422,
    public readonly code = "invalid_push_request",
  ) {
    super(message);
    this.name = "PushContractError";
  }
}

export function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function boundedText(value: unknown, maximum: number): string {
  return clean(value).slice(0, maximum);
}

export function requireInstallationID(value: unknown): string {
  const installationID = clean(value);
  if (installationID.length < 16 || installationID.length > 200) {
    throw new PushContractError("A valid installation identifier is required.");
  }
  return installationID;
}

export function normalizeAPNSToken(value: unknown): string {
  const token = clean(value)
    .replace(/^<|>$/g, "")
    .replace(/[\s-]/g, "")
    .toLowerCase();
  if (
    token.length < 32 || token.length > 256 || token.length % 2 !== 0 ||
    !/^[0-9a-f]+$/.test(token)
  ) {
    throw new PushContractError("A valid APNs token is required.");
  }
  return token;
}

export function requireEnvironment(value: unknown): "sandbox" | "production" {
  const environment = clean(value).toLowerCase();
  if (environment !== "sandbox" && environment !== "production") {
    throw new PushContractError("APNs environment is invalid.");
  }
  return environment;
}

export function requireBundleID(value: unknown): string {
  const bundleID = clean(value);
  if (bundleID !== SPYCLASH_BUNDLE_ID) {
    throw new PushContractError(
      "Push registration is for an unknown app.",
      403,
    );
  }
  return bundleID;
}

export type PushPreferences = {
  friendRequests: boolean;
  roomInvites: boolean;
  gameUpdates: boolean;
  announcements: boolean;
};

export function preferences(
  value: unknown,
  fallback: PushPreferences = {
    friendRequests: true,
    roomInvites: true,
    gameUpdates: true,
    announcements: true,
  },
): PushPreferences {
  const source = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  return {
    friendRequests: typeof source.friend_requests === "boolean"
      ? source.friend_requests
      : fallback.friendRequests,
    roomInvites: typeof source.room_invites === "boolean"
      ? source.room_invites
      : fallback.roomInvites,
    gameUpdates: typeof source.game_updates === "boolean"
      ? source.game_updates
      : fallback.gameUpdates,
    announcements: typeof source.announcements === "boolean"
      ? source.announcements
      : fallback.announcements,
  };
}

export function requireLiveActivityKind(
  value: unknown,
): "push_to_start" | "activity" {
  const kind = clean(value).toLowerCase();
  if (kind !== "push_to_start" && kind !== "activity") {
    throw new PushContractError("Live Activity token kind is invalid.");
  }
  return kind;
}

export function requireActivityBinding(body: Record<string, unknown>): {
  activityID: string;
  roomID: string;
  matchID: string;
} {
  const activityID = boundedText(body.activity_id, 200);
  const roomID = boundedText(body.room_id, 200);
  const matchID = boundedText(body.match_id, 200);
  if (!activityID || !roomID || !matchID) {
    throw new PushContractError(
      "Activity, room, and match identifiers are required for an update token.",
    );
  }
  return { activityID, roomID, matchID };
}

export function constantTimeEqual(first: unknown, second: unknown): boolean {
  const left = new TextEncoder().encode(clean(first));
  const right = new TextEncoder().encode(clean(second));
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] || 0) ^ (right[index] || 0);
  }
  return difference === 0;
}

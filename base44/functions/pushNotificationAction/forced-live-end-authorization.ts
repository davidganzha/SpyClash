import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

export type ForcedLiveEndAuthorization =
  | "committed"
  | "cleared"
  | "changed"
  | "deferred";

function closeIntentMatches(
  room: Entity,
  roomID: string,
  matchID: string,
): boolean {
  const intent = room?.close_intent;
  return Boolean(clean(intent?.id)) &&
    clean(intent?.room_id) === roomID &&
    clean(intent?.match_id) === matchID;
}

function terminalRoom(room: Entity): boolean {
  return ["finished", "ended"].includes(
    clean(room?.status).toLowerCase(),
  );
}

function hasCommittedFinishedReceipt(
  registration: Entity,
  matchID: string,
): boolean {
  return clean(registration?.pending_force_end_commit_id) ===
    `game-finished:${matchID}`;
}

function closeCommitPrefix(matchID: string): string {
  return `room-close:${matchID}:`;
}

export function roomCloseCommitReceiptID(
  matchIDValue: unknown,
  intentIDValue: unknown,
): string {
  const matchID = clean(matchIDValue);
  const intentID = clean(intentIDValue);
  return matchID && intentID ? `${closeCommitPrefix(matchID)}${intentID}` : "";
}

function hasCommittedCloseReceipt(
  registration: Entity,
  matchID: string,
): boolean {
  const receipt = clean(registration?.pending_force_end_commit_id);
  const prefix = closeCommitPrefix(matchID);
  return receipt.startsWith(prefix) && receipt.length > prefix.length;
}

export function committedCloseSignalReceipt(
  signal: Entity,
  roomID: string,
  matchID: string,
  userID = "",
): string {
  const intentID = clean(signal?.close_intent_id);
  return clean(signal?.room_id) === roomID &&
      clean(signal?.state) === "closed" &&
      Boolean(intentID) &&
      clean(signal?.close_match_id) === matchID &&
      (!userID || clean(signal?.user_id) === userID)
    ? roomCloseCommitReceiptID(matchID, intentID)
    : "";
}

export async function committedRoomCloseReceipt(input: {
  signalStore: any;
  roomID: unknown;
  matchID: unknown;
  userID?: unknown;
}): Promise<string> {
  if (!input.signalStore) return "";
  const roomID = clean(input.roomID);
  const matchID = clean(input.matchID);
  const userID = clean(input.userID);
  if (!roomID || !matchID) return "";
  const signals = await input.signalStore.filter(
    {
      room_id: roomID,
      state: "closed",
      ...(userID ? { user_id: userID } : {}),
    },
    "created_date",
    100,
    0,
  ) || [];
  return clean(
    signals.map((signal: Entity) =>
      committedCloseSignalReceipt(signal, roomID, matchID, userID)
    ).find(Boolean),
  );
}

/**
 * Authorize an ActivityKit terminal push while the registration user's
 * lifecycle lease is held. A live room is authoritative; after physical room
 * deletion, a server-written closed signal carrying the close intent is the
 * durable commit receipt. An unproved absence is deferred, never treated as
 * permission to end a still-active session.
 */
export async function authorizeForcedLiveActivityEnd(input: {
  roomStore: any;
  signalStore: any;
  liveStore: any;
  registration: Entity;
  roomID: string;
  matchID: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<ForcedLiveEndAuthorization> {
  const roomID = clean(input.roomID);
  const matchID = clean(input.matchID);
  // This receipt is copied only by the trusted terminal caller after the
  // finished room and its exact push outbox are committed. It must dominate a
  // stale pre-finish GameRoom replica; no negative replica read may erase it.
  if (
    hasCommittedFinishedReceipt(input.registration, matchID) ||
    hasCommittedCloseReceipt(input.registration, matchID)
  ) {
    return "committed";
  }
  const rooms = await input.roomStore.filter(
    { id: roomID },
    "created_date",
    2,
    0,
  ) || [];
  const room = rooms.find((candidate: Entity) =>
    clean(candidate?.id) === roomID
  );

  if (room) {
    if (clean(room.match_id) !== matchID) return "committed";
    if (terminalRoom(room) || closeIntentMatches(room, roomID, matchID)) {
      return "committed";
    }
    // A cross-function replica may still return the pre-intent room after the
    // durable close signal was committed. The server-only receipt dominates
    // that stale active projection and must be checked before clearing.
    if (
      await committedRoomCloseReceipt({
        signalStore: input.signalStore,
        roomID,
        matchID,
      })
    ) {
      return "committed";
    }

    // Even a newer-looking active replica is not a cancellation receipt: a
    // normal mutation can land after the pre-lease enqueue and before the
    // close intent. Only a terminal marker or closed signal may consume the
    // prepared force-end; every negative read remains retryable.
    return "deferred";
  }

  // GameRoom absence alone is not proof: an eventually consistent or failed
  // read must not terminate an active Lock Screen session. The closed signal
  // is written before physical deletion and survives it as the commit receipt.
  return await committedRoomCloseReceipt({
      signalStore: input.signalStore,
      roomID,
      matchID,
    })
    ? "committed"
    : "deferred";
}

import { isRoomWriteCASConflict } from "./room-write-cas.ts";

type Room = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function assertSameMatch(initial: Room, latest: Room): void {
  if (
    clean(initial.id) !== clean(latest.id) ||
    clean(initial.match_id) !== clean(latest.match_id)
  ) {
    throw Object.assign(new Error("The room has moved to a different match."), {
      status: 409,
      code: "room_action_stale",
    });
  }
}

// These fields neither choose the next question/speaker nor change player
// eligibility. A final vote still changes spectators, status or terminal_intent
// and therefore cannot be crossed. Fields written by the action stay protected.
const INDEPENDENT_FIELDS = new Set([
  "room_revision",
  "room_last_write_token",
  "updated_date",
  "cards_read",
  "vote_requests",
  "detective_votes",
  "detective_vote_round_id",
]);

function equivalent(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) &&
      left.length === right.length &&
      left.every((value, index) => equivalent(value, right[index]));
  }
  if (
    left && right && typeof left === "object" && typeof right === "object"
  ) {
    const a = left as Room;
    const b = right as Room;
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].every((key) =>
      equivalent(a[key], b[key])
    );
  }
  return false;
}

function sameActionInputs(initial: Room, latest: Room, patch: Room): boolean {
  return [...new Set([...Object.keys(initial), ...Object.keys(latest)])].every(
    (key) => {
      if (INDEPENDENT_FIELDS.has(key) && !(key in patch)) return true;
      return equivalent(initial[key], latest[key]);
    },
  );
}

/**
 * Rebase one already-computed gameplay transition only across independent
 * acknowledgements/votes. Random choices are fixed and successful side effects
 * are never replayed. A response-lost write is handled exclusively by the CAS
 * token reconciler; only an explicit zero-write CAS conflict enters this loop.
 */
export async function commitRoomActionTransition(input: {
  initialRoom: Room;
  patch: Room;
  validate: (room: Room) => void;
  write: (room: Room, patch: Room) => Promise<Room>;
  read: (roomID: string) => Promise<Room | null>;
  delay?: (milliseconds: number) => Promise<void>;
}): Promise<Room> {
  let latest = input.initialRoom;
  const wait = input.delay ??
    ((milliseconds) =>
      new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  for (let attempt = 0; attempt < 6; attempt += 1) {
    input.validate(latest);
    try {
      return await input.write(latest, input.patch);
    } catch (error) {
      if (!isRoomWriteCASConflict(error) || attempt === 5) throw error;
      await wait(20 + attempt * 35);
      const refreshed = await input.read(clean(input.initialRoom.id));
      if (!refreshed) {
        throw Object.assign(new Error("Room not found"), { status: 404 });
      }
      assertSameMatch(input.initialRoom, refreshed);
      input.validate(refreshed);
      if (
        sameActionInputs(
          { ...input.initialRoom, ...input.patch },
          refreshed,
          input.patch,
        )
      ) return refreshed;
      if (!sameActionInputs(input.initialRoom, refreshed, input.patch)) {
        throw error;
      }
      latest = refreshed;
    }
  }
  throw new Error("Room action retry exhausted unexpectedly.");
}

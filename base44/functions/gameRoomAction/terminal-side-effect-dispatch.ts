import { roomWriteRevision, writeRoomWithCAS } from "./room-write-cas.ts";

type Entity = Record<string, any>;

const DEFAULT_DISPATCH_LEASE_MILLISECONDS = 2 * 60 * 1_000;
const CLAIM_ATTEMPTS = 6;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

async function readRoom(store: any, roomID: string): Promise<Entity | null> {
  const rows = await store.filter({ id: roomID }, "created_date", 2, 0) || [];
  return rows.find((room: Entity) => clean(room.id) === roomID) || null;
}

function rawTerminalIntent(room: Entity): Entity | null {
  return room?.terminal_intent && typeof room.terminal_intent === "object" &&
      !Array.isArray(room.terminal_intent)
    ? room.terminal_intent
    : null;
}

function dispatchState(room: Entity): Entity | null {
  const intent = rawTerminalIntent(room);
  const state = intent?.side_effect_dispatch;
  return state && typeof state === "object" && !Array.isArray(state)
    ? state
    : null;
}

function roomStillOwnsTerminalSource(
  room: Entity | null,
  sourceEventID: string,
): room is Entity {
  if (
    !room || clean(room.status).toLowerCase() !== "finished" ||
    clean(room.game_finished_event_id) !== sourceEventID
  ) return false;
  const terminalMatchID = clean(room.terminal_intent?.match_id);
  const roomMatchID = clean(room.match_id);
  return Boolean(terminalMatchID) &&
    sourceEventID === `game-finished:${terminalMatchID}` &&
    (!roomMatchID || roomMatchID === terminalMatchID);
}

function dispatchLeaseActive(
  room: Entity,
  sourceEventID: string,
  now: Date,
): boolean {
  const state = dispatchState(room);
  if (clean(state?.event_id) !== sourceEventID) return false;
  const leaseUntil = Date.parse(clean(state?.lease_until));
  return clean(state?.state) === "processing" &&
    Number.isFinite(leaseUntil) && leaseUntil > now.getTime();
}

export type TerminalSideEffectDispatchClaim = {
  roomID: string;
  sourceEventID: string;
  token: string;
  room: Entity;
};

export type TerminalSideEffectClaimResult =
  | {
    status: "claimed";
    claim: TerminalSideEffectDispatchClaim;
    room: Entity;
  }
  | {
    status: "completed" | "deferred" | "missing" | "stale" | "contended";
    room: Entity | null;
  };

export async function claimTerminalSideEffectDispatch(input: {
  store: any;
  room: Entity;
  now?: Date;
  randomUUID?: () => string;
  leaseMilliseconds?: number;
}): Promise<TerminalSideEffectClaimResult> {
  const roomID = clean(input.room?.id);
  const sourceEventID = clean(input.room?.game_finished_event_id);
  if (!roomID || !sourceEventID) return { status: "stale", room: input.room };
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const leaseMilliseconds = Math.max(
    1_000,
    Number(input.leaseMilliseconds) || DEFAULT_DISPATCH_LEASE_MILLISECONDS,
  );
  let room = await readRoom(input.store, roomID);

  for (let attempt = 0; attempt < CLAIM_ATTEMPTS; attempt += 1) {
    if (!room) return { status: "missing", room: null };
    if (!roomStillOwnsTerminalSource(room, sourceEventID)) {
      return { status: "stale", room };
    }
    const state = dispatchState(room);
    if (
      clean(state?.event_id) === sourceEventID &&
      clean(state?.state) === "completed"
    ) return { status: "completed", room };
    if (dispatchLeaseActive(room, sourceEventID, now)) {
      return { status: "deferred", room };
    }
    if (roomWriteRevision(room) === null) {
      return { status: "deferred", room };
    }

    const claimID = randomUUID();
    const token = `terminal-dispatch:${claimID}`;
    const sideEffectDispatch = {
      event_id: sourceEventID,
      state: "processing",
      token,
      lease_until: new Date(now.getTime() + leaseMilliseconds).toISOString(),
    };
    try {
      const claimedRoom = await writeRoomWithCAS({
        store: input.store,
        room,
        patch: {
          terminal_intent: {
            ...rawTerminalIntent(room),
            side_effect_dispatch: sideEffectDispatch,
          },
        },
        read: (id) => readRoom(input.store, id),
        randomUUID: () => `terminal-dispatch-claim:${claimID}`,
      });
      if (!roomStillOwnsTerminalSource(claimedRoom, sourceEventID)) {
        return { status: "stale", room: claimedRoom };
      }
      return {
        status: "claimed",
        claim: { roomID, sourceEventID, token, room: claimedRoom },
        room: claimedRoom,
      };
    } catch {
      room = await readRoom(input.store, roomID);
      const reconciled = dispatchState(room || {});
      if (
        roomStillOwnsTerminalSource(room, sourceEventID) &&
        clean(reconciled?.event_id) === sourceEventID &&
        clean(reconciled?.state) === "processing" &&
        clean(reconciled?.token) === token
      ) {
        return {
          status: "claimed",
          claim: { roomID, sourceEventID, token, room },
          room,
        };
      }
    }
  }
  return {
    status: "contended",
    room: await readRoom(input.store, roomID),
  };
}

export async function completeTerminalSideEffectDispatch(input: {
  store: any;
  claim: TerminalSideEffectDispatchClaim;
  now?: Date;
  randomUUID?: () => string;
}): Promise<{ completed: boolean; room: Entity | null }> {
  const now = input.now || new Date();
  const room = await readRoom(input.store, input.claim.roomID);
  const state = dispatchState(room || {});
  if (
    !roomStillOwnsTerminalSource(room, input.claim.sourceEventID) ||
    clean(state?.event_id) !== input.claim.sourceEventID ||
    clean(state?.state) !== "processing" ||
    clean(state?.token) !== input.claim.token ||
    roomWriteRevision(room) === null
  ) return { completed: false, room };

  const completionID = (input.randomUUID || (() => crypto.randomUUID()))();
  try {
    const completedRoom = await writeRoomWithCAS({
      store: input.store,
      room,
      patch: {
        terminal_intent: {
          ...rawTerminalIntent(room),
          side_effect_dispatch: {
            ...state,
            state: "completed",
            lease_until: now.toISOString(),
            completed_at: now.toISOString(),
          },
        },
      },
      read: (id) => readRoom(input.store, id),
      randomUUID: () => `terminal-dispatch-complete:${completionID}`,
    });
    const completedState = dispatchState(completedRoom);
    return {
      completed:
        roomStillOwnsTerminalSource(completedRoom, input.claim.sourceEventID) &&
        clean(completedState?.event_id) === input.claim.sourceEventID &&
        clean(completedState?.state) === "completed" &&
        clean(completedState?.token) === input.claim.token,
      room: completedRoom,
    };
  } catch {
    const latest = await readRoom(input.store, input.claim.roomID);
    const latestState = dispatchState(latest || {});
    return {
      completed:
        roomStillOwnsTerminalSource(latest, input.claim.sourceEventID) &&
        clean(latestState?.event_id) === input.claim.sourceEventID &&
        clean(latestState?.state) === "completed" &&
        clean(latestState?.token) === input.claim.token,
      room: latest,
    };
  }
}

export type TerminalSideEffectRunResult = {
  outcome: "performed" | "completed" | "deferred" | "failed";
  room: Entity | null;
};

export async function runTerminalSideEffectsSingleFlight(input: {
  store: any;
  room: Entity;
  dispatch: (claimedRoom: Entity) => Promise<boolean>;
  now?: Date;
  randomUUID?: () => string;
  leaseMilliseconds?: number;
}): Promise<TerminalSideEffectRunResult> {
  const result = await claimTerminalSideEffectDispatch(input);
  if (result.status !== "claimed") {
    return {
      outcome: result.status === "completed" ? "completed" : "deferred",
      room: result.room,
    };
  }
  try {
    if (!(await input.dispatch(result.room))) {
      return {
        outcome: "failed",
        room: await readRoom(input.store, result.claim.roomID),
      };
    }
    const completion = await completeTerminalSideEffectDispatch({
      store: input.store,
      claim: result.claim,
      now: input.now,
      randomUUID: input.randomUUID,
    });
    return {
      outcome: completion.completed ? "performed" : "failed",
      room: completion.room,
    };
  } catch {
    // Leave the bounded claim in place. A later retry takes over after expiry,
    // preventing a transient outage from fanning out through every client.
    return {
      outcome: "failed",
      room: await readRoom(input.store, result.claim.roomID),
    };
  }
}

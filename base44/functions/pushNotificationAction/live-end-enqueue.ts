import { clean, PushContractError } from "./contracts.ts";
import { withPushWriterLeases } from "./device-registration.ts";
import { queueLiveRetry } from "./live-delivery.ts";

type Entity = Record<string, any>;
const PAGE_SIZE = 100;

async function allMatching(
  store: any,
  filter: Record<string, unknown>,
): Promise<Entity[]> {
  const records: Entity[] = [];
  for (let skip = 0;; skip += PAGE_SIZE) {
    const page = await store.filter(filter, "created_date", PAGE_SIZE, skip) ||
      [];
    records.push(...page);
    if (page.length < PAGE_SIZE) return records;
  }
}

function unique(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

function closeCompletionCore(value: Entity): Entity | null {
  const participantUserIDs = unique(
    Array.isArray(value?.participant_user_ids)
      ? value.participant_user_ids
      : [],
  );
  if (
    !clean(value?.intent_id) || !clean(value?.room_id) ||
    !clean(value?.host_user_id) || !participantUserIDs.length ||
    !participantUserIDs.includes(clean(value?.host_user_id)) ||
    Number(value?.participant_count) !== participantUserIDs.length ||
    !Number.isFinite(Date.parse(clean(value?.completed_at)))
  ) return null;
  return {
    intent_id: clean(value.intent_id),
    room_id: clean(value.room_id),
    match_id: clean(value.match_id),
    host_user_id: clean(value.host_user_id),
    participant_user_ids: participantUserIDs,
    participant_count: participantUserIDs.length,
    completed_at: clean(value.completed_at),
  };
}

export function closeCompletionAuthorizesLiveEndQueue(input: {
  signals: readonly Entity[];
  completion: Entity;
  roomID: string;
  matchID: string;
  terminalCommitID: string;
}): boolean {
  const expected = closeCompletionCore(input.completion);
  const expectedCommitID = expected
    ? `room-close:${expected.match_id}:${expected.intent_id}`
    : "";
  if (
    !expected || expected.room_id !== input.roomID ||
    expected.match_id !== input.matchID ||
    input.terminalCommitID !== expectedCommitID
  ) return false;
  return expected.participant_user_ids.every((userID: string) =>
    input.signals.some((signal) => {
      const actual = closeCompletionCore(signal?.close_completion);
      return clean(signal?.user_id) === userID &&
        clean(signal?.room_id) === expected.room_id &&
        clean(signal?.state) === "closed" &&
        clean(signal?.close_intent_id) === expected.intent_id &&
        clean(signal?.close_match_id) === expected.match_id &&
        actual !== null && JSON.stringify(actual) === JSON.stringify(expected);
    })
  );
}

function exactActiveRegistration(
  registration: Entity,
  roomID: string,
  matchID: string,
): boolean {
  return clean(registration.status) === "active" &&
    clean(registration.token_kind) === "activity" &&
    clean(registration.room_id) === roomID &&
    clean(registration.match_id) === matchID &&
    clean(registration.provider_match_id) === matchID;
}

type LeaseRunner = (input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  action: (
    persist: <T>(writer: () => Promise<T>) => Promise<T>,
  ) => Promise<boolean>;
}) => Promise<boolean>;

export type RoomLiveActivityEndQueue = {
  room: Entity;
  roomID: string;
  matchID: string;
  roomRevision: number;
  registrations: Entity[];
  queued: number;
  skipped: number;
  alreadyQueued: boolean;
  receipt: "queued" | "already_queued" | "no_active_registrations";
};

function hasExactPendingEnd(
  registration: Entity,
  roomID: string,
  matchID: string,
  terminalCommitID = "",
): boolean {
  const deliveryState = clean(registration.delivery_state);
  const deliverable = deliveryState === "retry" ||
    deliveryState === "processing";
  return deliverable && registration.pending_force_end === true &&
    clean(registration.pending_room_id) === roomID &&
    clean(registration.pending_match_id) === matchID &&
    (!terminalCommitID ||
      clean(registration.pending_force_end_commit_id) === terminalCommitID);
}

export async function enqueueRoomLiveActivityEnd(input: {
  roomStore: any;
  liveStore: any;
  lifecycleStore: any;
  signalStore?: any;
  validatedRoomSnapshot?: Entity;
  roomID: unknown;
  matchID: unknown;
  terminalCommitID?: unknown;
  closeCompletion?: unknown;
  leaseRunner?: LeaseRunner;
  now?: Date;
}): Promise<RoomLiveActivityEndQueue> {
  const roomID = clean(input.roomID);
  const matchID = clean(input.matchID);
  const terminalCommitID = clean(input.terminalCommitID);
  if (!roomID || !matchID) {
    throw new PushContractError("Room and match are required.");
  }

  const validatedSnapshot = input.validatedRoomSnapshot;
  const exactSnapshot = validatedSnapshot &&
      clean(validatedSnapshot.id) === roomID &&
      clean(validatedSnapshot.match_id) === matchID
    ? validatedSnapshot
    : null;
  const rooms = exactSnapshot
    ? []
    : await allMatching(input.roomStore, { id: roomID });
  const visibleRoom = exactSnapshot ||
    rooms.find((candidate) => clean(candidate.id) === roomID);
  const suppliedCompletion = input.closeCompletion as Entity | undefined;
  const completionSignals = suppliedCompletion && input.signalStore
    ? await allMatching(input.signalStore, { room_id: roomID })
    : [];
  const completionAuthorized = Boolean(
    suppliedCompletion && input.signalStore &&
      closeCompletionAuthorizesLiveEndQueue({
        signals: completionSignals,
        completion: suppliedCompletion,
        roomID,
        matchID,
        terminalCommitID,
      }),
  );
  if (suppliedCompletion && !completionAuthorized) {
    throw new PushContractError(
      "The room close completion is invalid.",
      409,
      "invalid_room_close_completion",
    );
  }
  if (
    !completionAuthorized &&
    (!visibleRoom || clean(visibleRoom.match_id) !== matchID)
  ) {
    throw new PushContractError(
      "The room end source is stale.",
      409,
      "stale_match_binding",
    );
  }
  const room = completionAuthorized
    ? {
      ...(visibleRoom || {}),
      id: roomID,
      match_id: matchID,
      updated_date: completionSignals
        .map((signal) => clean(signal?.room_updated_at))
        .filter((value) => Number.isFinite(Date.parse(value)))
        .sort()
        .at(-1) || clean(suppliedCompletion?.completed_at),
      close_intent: {
        id: clean(suppliedCompletion?.intent_id),
        room_id: roomID,
        match_id: matchID,
      },
    }
    : visibleRoom!;
  const closeIntent = room?.close_intent;
  const exactCloseCommitID = clean(closeIntent?.id) &&
      clean(closeIntent?.room_id) === roomID &&
      clean(closeIntent?.match_id) === matchID
    ? `room-close:${matchID}:${clean(closeIntent.id)}`
    : "";
  const exactFinishedCommitID = clean(room?.game_finished_event_id) ===
      `game-finished:${matchID}`
    ? `game-finished:${matchID}`
    : "";
  if (
    terminalCommitID &&
    ![exactCloseCommitID, exactFinishedCommitID].filter(Boolean).includes(
      terminalCommitID,
    )
  ) {
    throw new PushContractError(
      "The terminal commit receipt is invalid.",
      400,
      "invalid_terminal_commit_receipt",
    );
  }

  const parsedRevision = Date.parse(clean(room.updated_date));
  const now = input.now || new Date();
  const roomRevision = Number.isFinite(parsedRevision)
    ? parsedRevision
    : now.getTime();
  const registrations = (await allMatching(input.liveStore, {
    status: "active",
    room_id: roomID,
    token_kind: "activity",
  })).filter((registration) =>
    exactActiveRegistration(registration, roomID, matchID)
  );

  // The nested function can outlive its caller's short deadline. A retry must
  // be able to observe the first call's durable intent and return immediately,
  // without waiting for the same lifecycle leases again.
  const alreadyQueued = registrations.every((registration) =>
    hasExactPendingEnd(registration, roomID, matchID, terminalCommitID)
  );
  if (alreadyQueued) {
    return {
      room,
      roomID,
      matchID,
      roomRevision,
      registrations,
      queued: 0,
      skipped: 0,
      alreadyQueued: true,
      receipt: registrations.length === 0
        ? "no_active_registrations"
        : "already_queued",
    };
  }
  const leaseRunner = input.leaseRunner || withPushWriterLeases;

  let queued = 0;
  let skipped = 0;
  const queueRegistration = async (
    registration: Entity,
    leasedUserID: string,
    persist: <T>(writer: () => Promise<T>) => Promise<T>,
  ) => {
    const registrationID = clean(registration.id);
    const current = (await allMatching(input.liveStore, {
      id: registrationID,
    }))[0];
    if (
      !current || clean(current.user_id) !== leasedUserID ||
      !exactActiveRegistration(current, roomID, matchID)
    ) {
      skipped += 1;
      return;
    }
    const didQueue = await persist(() =>
      queueLiveRetry({
        store: input.liveStore,
        registrationID,
        roomID,
        matchID,
        roomRevision,
        forceEnd: true,
        terminalCommitID,
        now,
      })
    );
    if (didQueue) {
      queued += 1;
      return;
    }

    const latest = (await allMatching(input.liveStore, {
      id: registrationID,
    }))[0];
    if (latest && exactActiveRegistration(latest, roomID, matchID)) {
      throw new PushContractError(
        "Live Activity end could not be queued.",
        503,
        "live_end_queue_contention",
      );
    }
    skipped += 1;
  };
  const registrationsByUser = new Map<string, Entity[]>();
  for (const registration of registrations) {
    const userID = clean(registration.user_id);
    const group = registrationsByUser.get(userID) || [];
    group.push(registration);
    registrationsByUser.set(userID, group);
  }
  for (const [userID, group] of registrationsByUser) {
    await leaseRunner({
      lifecycleStore: input.lifecycleStore,
      userIDs: [userID],
      action: async (persist) => {
        await persist(async () => undefined);
        for (const registration of group) {
          await queueRegistration(registration, userID, persist);
        }
        return true;
      },
    });
  }

  return {
    room,
    roomID,
    matchID,
    roomRevision,
    registrations,
    queued,
    skipped,
    alreadyQueued: false,
    receipt: "queued",
  };
}

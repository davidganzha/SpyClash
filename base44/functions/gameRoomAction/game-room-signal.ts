export type GameRoomSignalState = "active" | "closed";

export type GameRoomSignalRecord = {
  user_id: string;
  room_id: string;
  lobby_revision: number;
  room_revision: number;
  room_updated_at?: string;
  state: GameRoomSignalState;
  close_intent_id?: string;
  close_match_id?: string;
  close_completion?: Record<string, unknown>;
};

export type GameRoomCloseReceipt = {
  intent_id: unknown;
  match_id: unknown;
  completion?: Record<string, unknown>;
};

export type GameRoomSignalRecipient = {
  user_id: unknown;
  state: GameRoomSignalState;
};

export type GameRoomSignalStore = {
  filter(query: Record<string, unknown>): Promise<Record<string, unknown>[]>;
  create(data: GameRoomSignalRecord): Promise<unknown>;
  update(id: string, data: GameRoomSignalRecord): Promise<unknown>;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function revision(value: unknown): number {
  const candidate = Number(value);
  return Number.isInteger(candidate) && candidate >= 0 ? candidate : 0;
}

function timestamp(value: unknown): number {
  const parsed = Date.parse(clean(value));
  return Number.isFinite(parsed) ? parsed : 0;
}

function unique(values: unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

export function hasDurableClosedRoomSignal(
  rows: readonly Record<string, unknown>[],
  roomIDValue: unknown,
  userIDValue: unknown,
  minimumRoomRevisionValue: unknown = 0,
): boolean {
  const roomID = clean(roomIDValue);
  const userID = clean(userIDValue);
  const matching = rows.filter((row) =>
    clean(row?.room_id) === roomID && clean(row?.user_id) === userID
  );
  if (!roomID || !userID || !matching.length) return false;
  const minimumRoomRevision = revision(minimumRoomRevisionValue);
  const latestRoomRevision = Math.max(
    ...matching.map((row) => revision(row?.room_revision)),
  );
  if (latestRoomRevision < minimumRoomRevision) return false;
  const atRoomRevision = matching.filter((row) =>
    revision(row?.room_revision) === latestRoomRevision
  );
  const latestLobbyRevision = Math.max(
    ...atRoomRevision.map((row) => revision(row?.lobby_revision)),
  );
  // Closure wins at one exact authoritative revision. A genuine later rejoin
  // carries a higher room/lobby revision and therefore reopens the signal.
  return atRoomRevision.some((row) =>
    revision(row?.lobby_revision) === latestLobbyRevision &&
    clean(row?.state) === "closed"
  );
}

function signalRecord(
  room: Record<string, unknown>,
  userID: string,
  state: GameRoomSignalState,
  closeReceipt?: GameRoomCloseReceipt,
): GameRoomSignalRecord | null {
  const roomID = clean(room?.id);
  if (!roomID || !userID) return null;
  const roomUpdatedAt = clean(room?.updated_date);
  return {
    user_id: userID,
    room_id: roomID,
    lobby_revision: revision(room?.lobby_revision),
    room_revision: revision(room?.room_revision),
    ...(timestamp(roomUpdatedAt) > 0 ? { room_updated_at: roomUpdatedAt } : {}),
    state,
    ...(clean(closeReceipt?.intent_id)
      ? {
        close_intent_id: clean(closeReceipt?.intent_id),
        close_match_id: clean(closeReceipt?.match_id),
        ...(closeReceipt?.completion
          ? { close_completion: closeReceipt.completion }
          : {}),
      }
      : {}),
  };
}

export function signalRecordsForRecipients(
  room: Record<string, unknown>,
  recipients: readonly GameRoomSignalRecipient[],
  closeReceipt?: GameRoomCloseReceipt,
): GameRoomSignalRecord[] {
  const states = new Map<string, GameRoomSignalState>();
  for (const recipient of recipients) {
    const userID = clean(recipient?.user_id);
    if (!userID) continue;
    const nextState = recipient?.state === "closed" ? "closed" : "active";
    const currentState = states.get(userID);
    // A recipient can be present in a stale participant mirror and in an exact
    // removed-recipient override. Closing must win within that same fanout.
    if (!currentState || nextState === "closed") states.set(userID, nextState);
  }
  return [...states.entries()].flatMap(([userID, state]) => {
    const record = signalRecord(room, userID, state, closeReceipt);
    return record ? [record] : [];
  });
}

export function signalRecordsForRoom(
  room: Record<string, unknown>,
  state: GameRoomSignalState = "active",
  additionalRecipientUserIDs: unknown[] = [],
  closeReceipt?: GameRoomCloseReceipt,
): GameRoomSignalRecord[] {
  const players = Array.isArray(room?.players) ? room.players : [];
  const participantIDs = unique([
    ...(Array.isArray(room?.participant_user_ids)
      ? room.participant_user_ids
      : []),
    ...players.map((player) =>
      clean((player as Record<string, unknown>)?.user_id)
    ),
    ...additionalRecipientUserIDs,
  ]);
  return signalRecordsForRecipients(
    room,
    participantIDs.map((userID) => ({ user_id: userID, state })),
    closeReceipt,
  );
}

export async function upsertGameRoomSignal(
  store: GameRoomSignalStore,
  signal: GameRoomSignalRecord,
  options: {
    allowCreate?: boolean;
    existingRows?: Record<string, unknown>[];
  } = {},
): Promise<"created" | "updated" | "unchanged" | "missing"> {
  const query = { user_id: signal.user_id, room_id: signal.room_id };
  const existing = options.existingRows ?? await store.filter(query) ?? [];
  const writable = existing.filter((row) => clean(row?.id));
  const updates = writable.filter((row) => {
    const existingRoomRevision = revision(row?.room_revision);
    const existingLobbyRevision = revision(row?.lobby_revision);
    if (existingRoomRevision > signal.room_revision) return false;
    if (existingRoomRevision < signal.room_revision) return true;
    if (existingLobbyRevision > signal.lobby_revision) return false;
    if (existingLobbyRevision < signal.lobby_revision) return true;
    const existingState = clean(row?.state);
    // At the same authoritative revision, closure is monotonic. A delayed
    // active fanout must not reopen a kicked user or a deleted room, while a
    // strictly newer revision can still represent a legitimate rejoin.
    if (existingState === "closed" && signal.state === "active") return false;
    if (existingState !== "closed" && signal.state === "closed") return true;
    if (
      clean(signal.close_intent_id) &&
      (clean(row?.close_intent_id) !== clean(signal.close_intent_id) ||
        clean(row?.close_match_id) !== clean(signal.close_match_id))
    ) return true;
    if (
      signal.close_completion &&
      JSON.stringify(row?.close_completion || null) !==
        JSON.stringify(signal.close_completion)
    ) return true;
    return timestamp(row?.room_updated_at) < timestamp(signal.room_updated_at);
  });
  if (updates.length) {
    await Promise.all(
      updates.map((row) => store.update(clean(row.id), signal)),
    );
    return "updated";
  }
  if (writable.length) return "unchanged";
  if (options.allowCreate === false) return "missing";

  try {
    await store.create(signal);
    return "created";
  } catch (createError) {
    const raced = await store.filter(query) ?? [];
    const racedResult = await upsertGameRoomSignal(store, signal, {
      allowCreate: false,
      existingRows: raced,
    });
    if (racedResult !== "missing") return racedResult;
    throw createError;
  }
}

export async function fanoutGameRoomSignalsBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  state?: GameRoomSignalState;
  additionalRecipientUserIDs?: unknown[];
  recipients?: readonly GameRoomSignalRecipient[];
  closeReceipt?: GameRoomCloseReceipt;
  allowCreate?: boolean;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = input.recipients
    ? signalRecordsForRecipients(
      input.room,
      input.recipients,
      input.closeReceipt,
    )
    : signalRecordsForRoom(
      input.room,
      input.state || "active",
      input.additionalRecipientUserIDs || [],
      input.closeReceipt,
    );
  if (!signals.length) return { attempted: 0, succeeded: 0, failed: 0 };

  let existing: Record<string, unknown>[];
  try {
    existing = await input.store.filter({ room_id: signals[0].room_id }) ?? [];
  } catch (error) {
    input.logError?.("room signal fanout deferred", error);
    return {
      attempted: signals.length,
      succeeded: 0,
      failed: signals.length,
    };
  }
  const settled = await Promise.allSettled(
    signals.map((signal) =>
      upsertGameRoomSignal(input.store, signal, {
        allowCreate: input.allowCreate !== false,
        existingRows: existing.filter((row) =>
          clean(row?.user_id) === signal.user_id &&
          clean(row?.room_id) === signal.room_id
        ),
      })
    ),
  );
  const failures = settled.filter((result) =>
    result.status === "rejected" || result.value === "missing"
  );
  for (const failure of failures) {
    input.logError?.(
      "room signal fanout deferred",
      failure.status === "rejected"
        ? failure.reason
        : new Error("room signal row missing"),
    );
  }
  return {
    attempted: signals.length,
    succeeded: signals.length - failures.length,
    failed: failures.length,
  };
}

export type GameRoomSignalState = "active" | "closed";

export type GameRoomSignalRecord = {
  user_id: string;
  room_id: string;
  lobby_revision: number;
  room_revision: number;
  room_updated_at?: string;
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

export function signalRecordsForRoom(
  room: Record<string, unknown>,
  state: GameRoomSignalState = "active",
  additionalRecipientUserIDs: unknown[] = [],
): GameRoomSignalRecord[] {
  const roomID = clean(room?.id);
  if (!roomID) return [];
  const players = Array.isArray(room?.players) ? room.players : [];
  const roomUpdatedAt = clean(room?.updated_date);
  const participantIDs = unique([
    ...(Array.isArray(room?.participant_user_ids)
      ? room.participant_user_ids
      : []),
    ...players.map((player) =>
      clean((player as Record<string, unknown>)?.user_id)
    ),
    ...additionalRecipientUserIDs,
  ]);
  return participantIDs.map((userID) => ({
    user_id: userID,
    room_id: roomID,
    lobby_revision: revision(room?.lobby_revision),
    room_revision: revision(room?.room_revision),
    ...(timestamp(roomUpdatedAt) > 0 ? { room_updated_at: roomUpdatedAt } : {}),
    state,
  }));
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
    return existingLobbyRevision < signal.lobby_revision ||
      timestamp(row?.room_updated_at) < timestamp(signal.room_updated_at) ||
      clean(row?.state) !== signal.state;
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

/**
 * Ensures that the actor introduced by create/join has one addressable signal
 * row while the caller still holds that actor's lifecycle lease. The helper is
 * best effort because authoritative polling remains the delivery fallback.
 * Bulk fanout can then run after lease release with creation disabled.
 */
export async function bootstrapGameRoomSignalForUserBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  userID: unknown;
  state?: GameRoomSignalState;
  logError?: (message: string, error: unknown) => void;
}): Promise<boolean> {
  const userID = clean(input.userID);
  if (!userID) return false;
  const signal = signalRecordsForRoom(
    input.room,
    input.state || "active",
    [userID],
  ).find((candidate) => candidate.user_id === userID);
  if (!signal) return false;

  try {
    return (await upsertGameRoomSignal(input.store, signal)) !== "missing";
  } catch (error) {
    input.logError?.("room signal bootstrap deferred", error);
    return false;
  }
}

export async function fanoutGameRoomSignalsBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  state?: GameRoomSignalState;
  additionalRecipientUserIDs?: unknown[];
  allowCreate?: boolean;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = signalRecordsForRoom(
    input.room,
    input.state || "active",
    input.additionalRecipientUserIDs || [],
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

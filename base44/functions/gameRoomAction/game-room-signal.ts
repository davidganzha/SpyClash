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
  create(data: GameRoomSignalRecord): Promise<unknown>;
  updateMany(
    filter: Record<string, unknown>,
    update: Record<string, unknown>,
  ): Promise<{ updated?: number }>;
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
  options: { allowCreate?: boolean } = {},
): Promise<"created" | "updated" | "missing"> {
  const query = { user_id: signal.user_id, room_id: signal.room_id };
  const updated = await store.updateMany(query, { $set: signal });
  if (Number(updated?.updated) > 0) return "updated";
  if (options.allowCreate === false) return "missing";

  try {
    await store.create(signal);
    return "created";
  } catch (createError) {
    // A concurrent initial fanout may have created the logical row. Updating
    // the key again converges every duplicate without a read-before-write loop.
    const raced = await store.updateMany(query, { $set: signal });
    if (Number(raced?.updated) > 0) return "updated";
    throw createError;
  }
}

export async function fanoutGameRoomSignalsBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  state?: GameRoomSignalState;
  allowCreate?: boolean;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = signalRecordsForRoom(input.room, input.state || "active");
  const settled = await Promise.allSettled(
    signals.map((signal) =>
      upsertGameRoomSignal(input.store, signal, {
        allowCreate: input.allowCreate !== false,
      })
    ),
  );
  const failures = settled.filter((result) => result.status === "rejected");
  for (const failure of failures) {
    input.logError?.(
      "room signal fanout deferred",
      (failure as PromiseRejectedResult).reason,
    );
  }
  return {
    attempted: signals.length,
    succeeded: signals.length - failures.length,
    failed: failures.length,
  };
}

export type GameRoomSignalState = "active" | "closed";

export type GameRoomSignalRecord = {
  user_id: string;
  room_id: string;
  lobby_revision: number;
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
    state,
  }));
}

async function updateExistingSignals(
  store: GameRoomSignalStore,
  existing: Record<string, unknown>[],
  signal: GameRoomSignalRecord,
): Promise<"updated" | "unchanged"> {
  const writable = existing.filter((row) => clean(row?.id));
  const updates = writable.filter((row) => {
    const existingRevision = revision(row?.lobby_revision);
    return existingRevision < signal.lobby_revision ||
      (existingRevision === signal.lobby_revision &&
        clean(row?.state) !== signal.state);
  });
  if (!updates.length) return "unchanged";
  await Promise.all(
    updates.map((row) => store.update(clean(row.id), signal)),
  );
  return "updated";
}

export async function upsertGameRoomSignal(
  store: GameRoomSignalStore,
  signal: GameRoomSignalRecord,
): Promise<"created" | "updated" | "unchanged"> {
  const query = { user_id: signal.user_id, room_id: signal.room_id };
  const existing = await store.filter(query) || [];
  if (existing.length) {
    return await updateExistingSignals(store, existing, signal);
  }

  try {
    await store.create(signal);
    return "created";
  } catch (createError) {
    // Base44 entities do not expose a portable unique-upsert operation. If two
    // fanouts race, re-read the logical key and converge every duplicate row.
    const raced = await store.filter(query) || [];
    if (!raced.length) throw createError;
    return await updateExistingSignals(store, raced, signal);
  }
}

export async function fanoutGameRoomSignalsBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  state?: GameRoomSignalState;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = signalRecordsForRoom(input.room, input.state || "active");
  const settled = await Promise.allSettled(
    signals.map((signal) => upsertGameRoomSignal(input.store, signal)),
  );
  const failures = settled.filter((result) => result.status === "rejected");
  for (const failure of failures) {
    input.logError?.(
      "lobby signal fanout deferred",
      (failure as PromiseRejectedResult).reason,
    );
  }
  return {
    attempted: signals.length,
    succeeded: signals.length - failures.length,
    failed: failures.length,
  };
}

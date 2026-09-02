export type GameRoomSignalState = "active" | "closed";
export type GameRoomSignalProjectionKind = "none" | "lobby_mode_v1";
export type ProjectedLobbyGameMode = "questions" | "associations";

export type LobbyModeGameRoomSignalProjection = {
  projection_kind: "lobby_mode_v1";
  projection_id: string;
  projected_game_mode: ProjectedLobbyGameMode;
  projection_committed_at?: string;
  projection_emitted_at: string;
};

export type GameRoomSignalRecord = {
  user_id: string;
  room_id: string;
  lobby_revision: number;
  room_revision: number;
  room_updated_at?: string;
  state: GameRoomSignalState;
  projection_kind: GameRoomSignalProjectionKind;
  projection_id?: string;
  projected_game_mode?: ProjectedLobbyGameMode;
  projection_committed_at?: string;
  projection_emitted_at?: string;
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

function isUUID(value: unknown): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(clean(value));
}

function projectedLobbyGameMode(
  value: unknown,
): ProjectedLobbyGameMode | null {
  const mode = clean(value);
  return mode === "questions" || mode === "associations" ? mode : null;
}

function projectionKind(value: unknown): GameRoomSignalProjectionKind {
  return clean(value) === "lobby_mode_v1" ? "lobby_mode_v1" : "none";
}

function safeLobbyModeProjection(
  value: unknown,
): LobbyModeGameRoomSignalProjection | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  const mode = projectedLobbyGameMode(candidate.projected_game_mode);
  const projectionID = clean(candidate.projection_id);
  const emittedAt = clean(candidate.projection_emitted_at);
  if (
    projectionKind(candidate.projection_kind) !== "lobby_mode_v1" || !mode ||
    !isUUID(projectionID) || timestamp(emittedAt) <= 0
  ) return null;
  const committedAt = clean(candidate.projection_committed_at);
  return {
    projection_kind: "lobby_mode_v1",
    projection_id: projectionID,
    projected_game_mode: mode,
    ...(timestamp(committedAt) > 0
      ? { projection_committed_at: committedAt }
      : {}),
    projection_emitted_at: emittedAt,
  };
}

export function lobbyModeSignalProjectionForRoom(
  room: Record<string, unknown>,
  options: {
    projectionID?: string;
    emittedAt?: string;
  } = {},
): LobbyModeGameRoomSignalProjection | null {
  const mode = projectedLobbyGameMode(room?.game_mode);
  if (!mode) return null;
  const projectionID = clean(options.projectionID) || crypto.randomUUID();
  // The CAS result can retain the pre-write entity timestamp. Capture the
  // server clock only after CAS completes instead of claiming that stale
  // timestamp belongs to the committed mode change.
  const emittedAt = clean(options.emittedAt) || new Date().toISOString();
  return safeLobbyModeProjection({
    projection_kind: "lobby_mode_v1",
    projection_id: projectionID,
    projected_game_mode: mode,
    projection_committed_at: emittedAt,
    projection_emitted_at: emittedAt,
  });
}

export function projectedLobbyModeFromSignal(
  signal: Record<string, unknown>,
): LobbyModeGameRoomSignalProjection | null {
  if (clean(signal?.state) !== "active") return null;
  return safeLobbyModeProjection(signal);
}

function unique(values: unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

export function signalRecordsForRoom(
  room: Record<string, unknown>,
  state: GameRoomSignalState = "active",
  additionalRecipientUserIDs: unknown[] = [],
  projection?: LobbyModeGameRoomSignalProjection | null,
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
  const safeProjection = state === "active"
    ? safeLobbyModeProjection(projection)
    : null;
  return participantIDs.map((userID) => ({
    user_id: userID,
    room_id: roomID,
    lobby_revision: revision(room?.lobby_revision),
    room_revision: revision(room?.room_revision),
    ...(timestamp(roomUpdatedAt) > 0 ? { room_updated_at: roomUpdatedAt } : {}),
    state,
    projection_kind: safeProjection?.projection_kind || "none",
    ...(safeProjection || {}),
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
    if (existingLobbyRevision < signal.lobby_revision) return true;
    if (clean(row?.state) !== signal.state) return true;
    const existingProjectionKind = projectionKind(row?.projection_kind);
    const nextProjectionKind = projectionKind(signal.projection_kind);
    if (existingProjectionKind !== nextProjectionKind) {
      // A later generic signal must explicitly deactivate retained direct
      // fields. Conversely, only a fully validated direct projection may
      // replace a generic hint at this exact authoritative revision.
      if (nextProjectionKind === "none") {
        return timestamp(signal.room_updated_at) >=
          timestamp(row?.room_updated_at);
      }
      return projectedLobbyModeFromSignal(signal) !== null;
    }
    if (nextProjectionKind === "lobby_mode_v1") {
      const existingProjection = projectedLobbyModeFromSignal(row);
      const nextProjection = projectedLobbyModeFromSignal(signal);
      if (!nextProjection) return false;
      if (!existingProjection) return true;
      const existingEmittedAt = timestamp(
        existingProjection.projection_emitted_at,
      );
      const nextEmittedAt = timestamp(nextProjection.projection_emitted_at);
      if (nextEmittedAt > existingEmittedAt) return true;
      if (nextEmittedAt < existingEmittedAt) return false;
      if (nextProjection.projection_id > existingProjection.projection_id) {
        return true;
      }
    }
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
  projection?: LobbyModeGameRoomSignalProjection | null;
  allowCreate?: boolean;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = signalRecordsForRoom(
    input.room,
    input.state || "active",
    input.additionalRecipientUserIDs || [],
    input.projection,
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

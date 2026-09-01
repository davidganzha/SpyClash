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

function explicitRevision(value: unknown): number | null {
  const candidate = Number(value);
  return Number.isInteger(candidate) && candidate >= 0 ? candidate : null;
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
  // `writeRoomWithCAS` deliberately avoids a post-commit read, so its merged
  // result can still carry the pre-CAS `updated_date`. Capture one server time
  // only after that CAS has returned and use it as the explicit commit-time
  // approximation. This keeps the metric complete without a network hop and
  // never pretends the stale entity timestamp belongs to the committed write.
  const emittedAt = clean(options.emittedAt) || new Date().toISOString();
  return safeLobbyModeProjection({
    projection_kind: "lobby_mode_v1",
    projection_id: projectionID,
    projected_game_mode: mode,
    projection_committed_at: emittedAt,
    projection_emitted_at: emittedAt,
  });
}

export function lobbyModeSignalProjectionForRepair(
  committedRoom: Record<string, unknown>,
  authoritativeRoom: Record<string, unknown>,
  projection: unknown,
): LobbyModeGameRoomSignalProjection | null {
  const safeProjection = safeLobbyModeProjection(projection);
  const committedRoomRevision = explicitRevision(committedRoom?.room_revision);
  const authoritativeRoomRevision = explicitRevision(
    authoritativeRoom?.room_revision,
  );
  const committedLobbyRevision = explicitRevision(
    committedRoom?.lobby_revision,
  );
  const authoritativeLobbyRevision = explicitRevision(
    authoritativeRoom?.lobby_revision,
  );
  if (
    !safeProjection ||
    !clean(committedRoom?.id) ||
    clean(authoritativeRoom?.id) !== clean(committedRoom?.id) ||
    committedRoomRevision === null ||
    authoritativeRoomRevision !== committedRoomRevision ||
    committedLobbyRevision === null ||
    authoritativeLobbyRevision !== committedLobbyRevision ||
    projectedLobbyGameMode(authoritativeRoom?.game_mode) !==
      safeProjection.projected_game_mode
  ) return null;
  return safeProjection;
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
  projection?: LobbyModeGameRoomSignalProjection | null,
): GameRoomSignalRecord | null {
  const roomID = clean(room?.id);
  if (!roomID || !userID) return null;
  const roomUpdatedAt = clean(room?.updated_date);
  const safeProjection = state === "active"
    ? safeLobbyModeProjection(projection)
    : null;
  return {
    user_id: userID,
    room_id: roomID,
    lobby_revision: revision(room?.lobby_revision),
    room_revision: revision(room?.room_revision),
    ...(timestamp(roomUpdatedAt) > 0 ? { room_updated_at: roomUpdatedAt } : {}),
    state,
    projection_kind: safeProjection?.projection_kind || "none",
    ...(safeProjection || {}),
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
  projection?: LobbyModeGameRoomSignalProjection | null,
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
    const record = signalRecord(room, userID, state, closeReceipt, projection);
    return record ? [record] : [];
  });
}

export function signalRecordsForRoom(
  room: Record<string, unknown>,
  state: GameRoomSignalState = "active",
  additionalRecipientUserIDs: unknown[] = [],
  closeReceipt?: GameRoomCloseReceipt,
  projection?: LobbyModeGameRoomSignalProjection | null,
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
    projection,
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
    const existingProjectionKind = projectionKind(row?.projection_kind);
    const nextProjectionKind = projectionKind(signal.projection_kind);
    if (existingProjectionKind !== nextProjectionKind) {
      // Every newly emitted generic/closed signal writes `none`. This explicit
      // discriminator makes any legacy projection fields retained by the
      // entity merge inert, while a valid direct projection may replace a
      // generic hint at the same authoritative revision.
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
      // UUID is a deterministic tie-breaker for the rare same-millisecond
      // emission. This prevents reordered duplicate deliveries from flipping
      // the personal signal back and forth forever.
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

export async function fanoutGameRoomSignalsBestEffort(input: {
  store: GameRoomSignalStore;
  room: Record<string, unknown>;
  state?: GameRoomSignalState;
  additionalRecipientUserIDs?: unknown[];
  recipients?: readonly GameRoomSignalRecipient[];
  closeReceipt?: GameRoomCloseReceipt;
  projection?: LobbyModeGameRoomSignalProjection | null;
  allowCreate?: boolean;
  logError?: (message: string, error: unknown) => void;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const signals = input.recipients
    ? signalRecordsForRecipients(
      input.room,
      input.recipients,
      input.closeReceipt,
      input.projection,
    )
    : signalRecordsForRoom(
      input.room,
      input.state || "active",
      input.additionalRecipientUserIDs || [],
      input.closeReceipt,
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

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function statusError(message: string, status: number, code?: string): Error {
  return Object.assign(new Error(message), {
    status,
    ...(code ? { code } : {}),
  });
}

export type SpyClashGameMode = "questions" | "associations";
export type LobbySetting = "mode" | "duration" | "lobby";

export function roomHasParticipantIdentity(
  room: Record<string, unknown> | null | undefined,
  user: Record<string, unknown> | null | undefined,
): boolean {
  if (!room || !user) return false;
  const userEmail = clean(user.email);
  const userID = clean(user.id);
  if (!userEmail || !userID) return false;
  const players = Array.isArray(room.players) ? room.players : [];
  return players.some((candidate) => {
    const player = candidate as Record<string, unknown>;
    return clean(player?.email) === userEmail &&
      clean(player?.user_id) === userID;
  });
}

export function leaveAlreadyComplete(
  room: Record<string, unknown> | null | undefined,
  userEmailValue: unknown,
): boolean {
  if (!room) return true;
  const userEmail = clean(userEmailValue);
  const players = Array.isArray(room.players) ? room.players : [];
  return !userEmail ||
    !players.some((player) =>
      clean((player as Record<string, unknown>)?.email) === userEmail
    );
}

export function liveActivityEndQueueMatchesRoom(
  room: Record<string, unknown> | null | undefined,
  queuedRoomIDValue: unknown,
  queuedMatchIDValue: unknown,
): boolean {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  return Boolean(
    roomID && matchID &&
      clean(queuedRoomIDValue) === roomID &&
      clean(queuedMatchIDValue) === matchID,
  );
}

export function liveActivityEndQueueCoversRegistrations(
  room: Record<string, unknown> | null | undefined,
  registrations: readonly Record<string, unknown>[],
): boolean {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  if (!roomID || !matchID) return true;
  const closeIntent = room?.close_intent as Record<string, unknown> | undefined;
  const expectedCommitID = clean(closeIntent?.id) &&
      clean(closeIntent?.room_id) === roomID &&
      clean(closeIntent?.match_id) === matchID
    ? `room-close:${matchID}:${clean(closeIntent?.id)}`
    : clean(room?.game_finished_event_id) === `game-finished:${matchID}`
    ? `game-finished:${matchID}`
    : "";

  const exactActive = registrations.filter((registration) =>
    clean(registration?.status).toLowerCase() === "active" &&
    clean(registration?.token_kind) === "activity" &&
    clean(registration?.room_id) === roomID &&
    clean(registration?.match_id) === matchID &&
    clean(registration?.provider_match_id) === matchID
  );
  return exactActive.every((registration) =>
    registration?.pending_force_end === true &&
    clean(registration?.pending_room_id) === roomID &&
    clean(registration?.pending_match_id) === matchID &&
    (!expectedCommitID ||
      clean(registration?.pending_force_end_commit_id) === expectedCommitID) &&
    ["retry", "processing"].includes(
      clean(registration?.delivery_state).toLowerCase(),
    )
  );
}

export async function loadActiveRoomLiveActivityRegistrations(
  store: {
    filter: (
      query: Record<string, unknown>,
      sort: string,
      limit: number,
      skip: number,
    ) => Promise<Record<string, unknown>[] | null | undefined>;
  },
  roomIDValue: unknown,
  pageSize = 100,
): Promise<Record<string, unknown>[]> {
  const roomID = clean(roomIDValue);
  if (!roomID) return [];
  const boundedPageSize = Math.max(1, Math.floor(pageSize));
  const registrations: Record<string, unknown>[] = [];
  for (let skip = 0;; skip += boundedPageSize) {
    const page = await store.filter(
      { status: "active", room_id: roomID, token_kind: "activity" },
      "created_date",
      boundedPageSize,
      skip,
    ) || [];
    registrations.push(...page);
    if (page.length < boundedPageSize) return registrations;
  }
}

export function assertLobbySettingsAccess(
  room: Record<string, unknown>,
  user: Record<string, unknown>,
  setting: LobbySetting,
): void {
  if (clean(room?.host_email) !== clean(user?.email)) {
    throw statusError("Host access required", 403);
  }
  if (clean(room?.status || "waiting").toLowerCase() !== "waiting") {
    const message = setting === "mode"
      ? "Game mode can only change in the lobby"
      : setting === "duration"
      ? "Duration can only change in the lobby"
      : "Lobby state can only change while waiting";
    throw statusError(
      message,
      409,
    );
  }
}

export function validatedGameMode(value: unknown): SpyClashGameMode {
  const mode = clean(value);
  if (mode !== "questions" && mode !== "associations") {
    throw statusError("Invalid game mode", 400);
  }
  return mode;
}

export function validatedGameDuration(value: unknown): number {
  const durationSeconds = Number(value);
  if (
    !Number.isInteger(durationSeconds) || durationSeconds < 60 ||
    durationSeconds > 900
  ) {
    throw statusError(
      "Duration must be between 1 and 15 minutes",
      400,
    );
  }
  return durationSeconds;
}

export function gameModePatch(
  room: Record<string, unknown>,
  mode: SpyClashGameMode,
): Record<string, unknown> {
  return clean(room?.game_mode) === mode ? {} : { game_mode: mode };
}

export function roomHasGameMode(
  room: Record<string, unknown>,
  mode: SpyClashGameMode,
): boolean {
  return clean(room?.game_mode) === mode;
}

export function gameDurationPatch(
  room: Record<string, unknown>,
  durationSeconds: number,
): Record<string, unknown> {
  return Number(room?.game_duration_seconds) === durationSeconds
    ? {}
    : { game_duration_seconds: durationSeconds };
}

export function roomHasGameDuration(
  room: Record<string, unknown>,
  durationSeconds: number,
): boolean {
  return Number(room?.game_duration_seconds) === durationSeconds;
}

export async function deleteRoomAndVerify(input: {
  roomID: string;
  deleteByID: (roomID: string) => Promise<unknown>;
  fetchByID: (roomID: string) => Promise<unknown | null | undefined>;
  afterVerifiedDelete?: () => Promise<void>;
  delay?: (milliseconds: number) => Promise<void>;
  attempts?: number;
}): Promise<void> {
  const attempts = Math.max(1, input.attempts ?? 6);
  const wait = input.delay ??
    ((milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)));

  // Deletion itself is deliberately issued once. Only the eventually
  // consistent verification read is retried.
  await input.deleteByID(input.roomID);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (!await input.fetchByID(input.roomID)) {
      await input.afterVerifiedDelete?.();
      return;
    }
    if (attempt + 1 < attempts) await wait(20 + attempt * 35);
  }

  throw statusError(
    "The room could not be deleted; retry.",
    409,
    "room_delete_unverified",
  );
}

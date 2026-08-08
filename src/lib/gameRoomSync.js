export const ONLINE_GAME_INTRO_MILLISECONDS = 8_000;
export const ONLINE_GAME_INTRO_GRACE_MILLISECONDS = 250;
export const POST_GAME_GUESS_SECONDS = 30;
export const ROOM_POLL_FALLBACK_INTERVAL_MILLISECONDS = 2_000;
export const ROOM_POLL_MAX_INTERVAL_MILLISECONDS = 30_000;
export const ROOM_POLL_ERROR_THRESHOLD = 2;

function normalizedStatus(room) {
  return String(room?.status ?? "").trim().toLowerCase();
}

function normalizedIdentifier(value) {
  return String(value ?? "").trim();
}

function normalizedRevision(value) {
  if (value === null || value === undefined || String(value).trim() === "") {
    return null;
  }
  const revision = Number(value);
  return Number.isSafeInteger(revision) && revision >= 0 ? revision : null;
}

export function shouldRefreshForGameRoomSignal(
  event,
  { roomId, userId = null, currentRoomRevision = null },
) {
  if (!["create", "update"].includes(String(event?.type || "").toLocaleLowerCase())) {
    return false;
  }
  const signal = event?.data;
  if (!signal || normalizedIdentifier(signal.room_id) !== normalizedIdentifier(roomId)) {
    return false;
  }
  const expectedUserId = normalizedIdentifier(userId);
  if (expectedUserId && normalizedIdentifier(signal.user_id) !== expectedUserId) {
    return false;
  }

  const signalRevision = normalizedRevision(signal.room_revision);
  const currentRevision = normalizedRevision(currentRoomRevision);
  if (
    String(signal.state || "active").toLocaleLowerCase() !== "closed"
    && signalRevision !== null
    && currentRevision !== null && currentRevision >= signalRevision
  ) {
    return false;
  }
  return true;
}

function parsedTimestamp(value) {
  const milliseconds = Date.parse(String(value ?? "").trim());
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

export function buildGameRoomActionHeaders({ appId, functionsVersion = null }) {
  const normalizedAppId = String(appId ?? "").trim();
  const headers = {
    "Content-Type": "application/json",
    "Base44-App-Id": normalizedAppId,
    "X-App-Id": normalizedAppId,
  };
  if (String(functionsVersion ?? "").trim()) {
    headers["Base44-Functions-Version"] = String(functionsVersion).trim();
  }
  return headers;
}

export function gameDurationMinutes(room, fallbackMinutes = 10) {
  const seconds = Number(room?.game_duration_seconds);
  if (!Number.isInteger(seconds) || seconds < 60 || seconds > 900) {
    return fallbackMinutes;
  }
  return Math.max(1, Math.min(15, Math.round(seconds / 60)));
}

export function gameDurationSeconds(minutes) {
  const normalized = Math.max(1, Math.min(15, Math.round(Number(minutes) || 1)));
  return normalized * 60;
}

export function roomPollDelayMilliseconds({
  baseIntervalMilliseconds = ROOM_POLL_FALLBACK_INTERVAL_MILLISECONDS,
  consecutiveFailures = 0,
  hidden = false,
  maxIntervalMilliseconds = ROOM_POLL_MAX_INTERVAL_MILLISECONDS,
} = {}) {
  const base = Math.max(
    250,
    Number(baseIntervalMilliseconds) || ROOM_POLL_FALLBACK_INTERVAL_MILLISECONDS,
  );
  const exponent = Math.max(0, Math.min(6, Math.floor(Number(consecutiveFailures) || 0)));
  const backedOff = base * (2 ** exponent);
  const visibilityFloor = hidden ? 20_000 : 0;
  return Math.min(
    Math.max(base, Number(maxIntervalMilliseconds) || ROOM_POLL_MAX_INTERVAL_MILLISECONDS),
    Math.max(backedOff, visibilityFloor),
  );
}

export function gameTimerSnapshot(room, nowMilliseconds = Date.now()) {
  const durationSeconds = Number(room?.game_duration_seconds);
  const startedAt = parsedTimestamp(room?.game_started_at);
  if (!Number.isInteger(durationSeconds) || durationSeconds < 0 || startedAt === null) {
    return {
      valid: false,
      paused: Boolean(String(room?.game_paused_at ?? "").trim()),
      elapsedSeconds: 0,
      remainingSeconds: Number.isInteger(durationSeconds) ? Math.max(0, durationSeconds) : null,
      guessRemainingSeconds: POST_GAME_GUESS_SECONDS,
    };
  }

  const pausedAt = parsedTimestamp(room?.game_paused_at);
  const pausedTotalSeconds = Math.max(0, Math.floor(Number(room?.game_paused_total_seconds) || 0));
  const effectiveNow = pausedAt ?? nowMilliseconds;
  const elapsedSeconds = Math.max(
    0,
    Math.floor((effectiveNow - startedAt) / 1_000) - pausedTotalSeconds,
  );
  const remainingSeconds = Math.max(0, durationSeconds - elapsedSeconds);
  const overtimeSeconds = Math.max(0, elapsedSeconds - durationSeconds);

  return {
    valid: Number.isFinite(nowMilliseconds),
    paused: pausedAt !== null,
    elapsedSeconds,
    remainingSeconds,
    guessRemainingSeconds: Math.max(0, POST_GAME_GUESS_SECONDS - overtimeSeconds),
  };
}

export function introCompletionDelayMilliseconds(
  room,
  nowMilliseconds = Date.now(),
  graceMilliseconds = ONLINE_GAME_INTRO_GRACE_MILLISECONDS,
) {
  const introStartedAt = parsedTimestamp(room?.intro_started_at);
  if (introStartedAt === null || !Number.isFinite(nowMilliseconds)) return 0;
  return Math.max(
    0,
    introStartedAt + ONLINE_GAME_INTRO_MILLISECONDS + Math.max(0, graceMilliseconds) - nowMilliseconds,
  );
}

export function isGameIntroInProgressError(error) {
  if (Number(error?.status) !== 409) return false;
  if (error?.code === "game_intro_in_progress") return true;
  return /intro.*(?:progress|started)|still in progress/i.test(String(error?.message ?? ""));
}

function isRecoverableGameIntroCompletionError(error) {
  if (isGameIntroInProgressError(error)) return true;
  const code = String(error?.code ?? "").trim().toLowerCase();
  return Number(error?.status) === 409
    && error?.retryable === true
    && ["active_lease", "cas_contention"].includes(code);
}

const defaultSleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/**
 * Completes the server-clocked intro. Any room participant may safely call it;
 * the backend serializes and deduplicates competing completions.
 */
export async function completeGameStartAfterIntro({
  room,
  refreshRoom,
  completeStart,
  now = () => Date.now(),
  sleep = defaultSleep,
  maxAttempts = 30,
}) {
  let currentRoom = room;
  let lastError = null;

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (normalizedStatus(currentRoom) === "playing") return currentRoom;
    if (normalizedStatus(currentRoom) !== "roulette") {
      throw new Error("Mission intro is no longer active");
    }

    const delay = introCompletionDelayMilliseconds(currentRoom, now());
    if (delay > 0) await sleep(delay);

    const refreshedRoom = await refreshRoom(currentRoom.id);
    if (refreshedRoom) currentRoom = refreshedRoom;
    if (normalizedStatus(currentRoom) === "playing") return currentRoom;

    try {
      return await completeStart(currentRoom);
    } catch (error) {
      if (!isRecoverableGameIntroCompletionError(error)) throw error;
      lastError = error;

      const retryRoom = await refreshRoom(currentRoom.id);
      if (retryRoom) currentRoom = retryRoom;
      if (normalizedStatus(currentRoom) === "playing") return currentRoom;

      const retryDelay = Math.max(
        300,
        introCompletionDelayMilliseconds(currentRoom, now()),
      );
      await sleep(retryDelay);
    }
  }

  throw lastError || new Error("Unable to complete the synchronized game intro");
}

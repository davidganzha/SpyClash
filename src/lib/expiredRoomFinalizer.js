import { gameTimerSnapshot } from "./gameRoomSync.js";

export const EXPIRED_ROOM_FINALIZE_MAX_ATTEMPTS = 6;

const RETRY_INITIAL_DELAY_MILLISECONDS = 1_000;
const RETRY_DELAY_CAP_MILLISECONDS = 8_000;
const RETRY_JITTER_MINIMUM = 0.75;
const RETRY_JITTER_RANGE = 0.5;
const EXHAUSTION_COOLDOWN_MILLISECONDS = 30_000;

function abortError(signal) {
  if (signal?.reason instanceof Error) return signal.reason;
  return Object.assign(new Error("Expired-room finalization was cancelled"), {
    name: "AbortError",
    code: "finalization_cancelled",
  });
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw abortError(signal);
}

const defaultSleep = (milliseconds, signal) => new Promise((resolve, reject) => {
  throwIfAborted(signal);
  const timer = setTimeout(() => {
    signal?.removeEventListener?.("abort", handleAbort);
    resolve();
  }, milliseconds);
  const handleAbort = () => {
    clearTimeout(timer);
    reject(abortError(signal));
  };
  signal?.addEventListener?.("abort", handleAbort, { once: true });
});

function clean(value) {
  return String(value ?? "").trim();
}

function normalized(value) {
  return clean(value).toLocaleLowerCase();
}

function roomScope(room) {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  const gameStartedAt = clean(room?.game_started_at);
  if (!roomID || (!matchID && !gameStartedAt)) return null;
  return {
    roomID,
    matchID,
    gameStartedAt,
    token: matchID ? `match:${matchID}` : `legacy:${gameStartedAt}`,
  };
}

function sameRoomAndMatch(scope, room) {
  const candidate = roomScope(room);
  return Boolean(
    scope
    && candidate
    && candidate.roomID === scope.roomID
    && candidate.token === scope.token,
  );
}

function actorIsPlayer(room, actorEmail) {
  const actor = normalized(actorEmail);
  return Boolean(actor) && (Array.isArray(room?.players) ? room.players : []).some(
    (player) => normalized(player?.email) === actor,
  );
}

function roomResolution(scope, room, actorEmail, nowMilliseconds) {
  if (!sameRoomAndMatch(scope, room)) return "superseded";
  if (normalized(room?.status) === "finished") return "finished";
  if (normalized(room?.status) !== "playing" || !actorIsPlayer(room, actorEmail)) {
    return "superseded";
  }
  const timer = gameTimerSnapshot(room, nowMilliseconds);
  return timer.valid && !timer.paused && timer.remainingSeconds === 0
    ? "expired"
    : "superseded";
}

export function expiredRoomFinalizationKey(room) {
  const scope = roomScope(room);
  if (!scope) return null;
  return `${scope.roomID}:${scope.token}`;
}

export function expiredRoomFinalizeRetryDelayMilliseconds(attempt, random = Math.random) {
  const baseDelay = Math.min(
    RETRY_DELAY_CAP_MILLISECONDS,
    RETRY_INITIAL_DELAY_MILLISECONDS * (2 ** Math.max(0, Number(attempt) || 0)),
  );
  const sample = Math.max(0, Math.min(1, Number(random()) || 0));
  return Math.round(baseDelay * (RETRY_JITTER_MINIMUM + (sample * RETRY_JITTER_RANGE)));
}

function expiredRoomFinalizeCooldownMilliseconds(random = Math.random) {
  const sample = Math.max(0, Math.min(1, Number(random()) || 0));
  return Math.round(
    EXHAUSTION_COOLDOWN_MILLISECONDS
      * (RETRY_JITTER_MINIMUM + (sample * RETRY_JITTER_RANGE)),
  );
}

export function isRetryableExpiredRoomFinalizeError(error) {
  const status = Number(error?.status);
  const code = normalized(error?.code);
  if (
    status === 409
    && error?.retryable === true
    && ["active_lease", "cas_contention"].includes(code)
  ) return true;
  if ([408, 425, 429, 500, 502, 503, 504].includes(status)) return true;
  return !Number.isFinite(status) || status <= 0;
}

/**
 * Runs one bounded finalization sequence for one immutable room/match scope.
 * A failed write is never repeated until a delayed authoritative read confirms
 * that the same match is still playing and expired.
 */
export async function finalizeExpiredRoomWithBackoff({
  room,
  actorEmail,
  currentRoom = () => room,
  refreshRoom,
  finalizeRoom,
  acceptRoom = (_updatedRoom) => {},
  now = () => Date.now(),
  sleep = defaultSleep,
  random = Math.random,
  maxAttempts = EXPIRED_ROOM_FINALIZE_MAX_ATTEMPTS,
  signal = null,
}) {
  throwIfAborted(signal);
  const scope = roomScope(room);
  if (!scope || roomResolution(scope, room, actorEmail, now()) !== "expired") return room;
  if (typeof refreshRoom !== "function" || typeof finalizeRoom !== "function") {
    throw new TypeError("Expired-room finalization requires refreshRoom and finalizeRoom");
  }

  const attempts = Math.max(
    1,
    Math.min(
      EXPIRED_ROOM_FINALIZE_MAX_ATTEMPTS,
      Number.isFinite(Number(maxAttempts)) ? Math.trunc(Number(maxAttempts)) : 1,
    ),
  );
  let lastError = null;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (attempt > 0) {
      await sleep(expiredRoomFinalizeRetryDelayMilliseconds(attempt - 1, random), signal);
    }
    throwIfAborted(signal);

    const localRoom = currentRoom() || room;
    const localResolution = roomResolution(scope, localRoom, actorEmail, now());
    if (localResolution !== "expired") return localRoom;

    if (attempt > 0) {
      let refreshed;
      try {
        refreshed = await refreshRoom(scope.roomID);
        throwIfAborted(signal);
      } catch (error) {
        throwIfAborted(signal);
        lastError = error;
        if (!isRetryableExpiredRoomFinalizeError(error)) throw error;
        continue;
      }
      if (refreshed?.id) acceptRoom(refreshed);
      if (roomResolution(scope, refreshed, actorEmail, now()) !== "expired") return refreshed;
    }

    try {
      throwIfAborted(signal);
      const finalized = await finalizeRoom(scope.roomID, {
        expected_match_id: scope.matchID || undefined,
        expected_game_started_at: scope.matchID ? undefined : scope.gameStartedAt,
      });
      throwIfAborted(signal);
      if (finalized?.id) acceptRoom(finalized);
      if (roomResolution(scope, finalized, actorEmail, now()) !== "expired") return finalized;
      lastError = Object.assign(
        new Error("Expired-room finalization returned an unresolved room"),
        { status: 502, code: "finalization_unresolved", retryable: true },
      );
    } catch (error) {
      lastError = error;
      if (!isRetryableExpiredRoomFinalizeError(error)) throw error;
    }
  }

  throw lastError || new Error("Expired-room finalization was not confirmed");
}

/**
 * Component-scoped single-flight registry. A match gets one bounded run for the
 * lifetime of the Game page, even if React effects are evaluated repeatedly.
 */
export function createExpiredRoomFinalizer() {
  const runs = new Map();
  const confirmedFinished = new Map();
  let disposed = false;
  return {
    run(options) {
      const key = expiredRoomFinalizationKey(options?.room);
      if (!key) return Promise.resolve(options?.room || null);
      if (disposed) return Promise.reject(abortError({ aborted: true }));
      if (confirmedFinished.has(key)) return Promise.resolve(confirmedFinished.get(key));
      if (runs.has(key)) return runs.get(key).promise;

      const controller = new AbortController();
      const promise = (async () => {
        try {
          return await finalizeExpiredRoomWithBackoff({
            ...options,
            signal: controller.signal,
          });
        } catch (error) {
          throwIfAborted(controller.signal);
          if (!isRetryableExpiredRoomFinalizeError(error)) throw error;

          const cooldownSleep = typeof options?.sleep === "function"
            ? options.sleep
            : defaultSleep;
          await cooldownSleep(
            expiredRoomFinalizeCooldownMilliseconds(options?.random),
            controller.signal,
          );
          throwIfAborted(controller.signal);

          const localRoom = options?.currentRoom?.() || options?.room;
          const originalScope = roomScope(options?.room);
          if (
            expiredRoomFinalizationKey(localRoom) !== key
            || roomResolution(
              originalScope,
              localRoom,
              options?.actorEmail,
              options?.now?.() ?? Date.now(),
            ) !== "expired"
          ) return localRoom;
          const refreshed = await options.refreshRoom(localRoom.id);
          throwIfAborted(controller.signal);
          if (refreshed?.id) options?.acceptRoom?.(refreshed);
          if (expiredRoomFinalizationKey(refreshed) !== key) return refreshed;

          return await finalizeExpiredRoomWithBackoff({
            ...options,
            room: refreshed,
            maxAttempts: 1,
            signal: controller.signal,
          });
        }
      })().then((result) => {
        if (
          normalized(result?.status) === "finished"
          && expiredRoomFinalizationKey(result) === key
        ) {
          confirmedFinished.set(key, result);
        }
        return result;
      }).finally(() => {
        if (runs.get(key)?.promise === promise) runs.delete(key);
      });
      runs.set(key, { controller, promise });
      return promise;
    },
    cancel(roomOrKey) {
      const key = typeof roomOrKey === "string"
        ? roomOrKey
        : expiredRoomFinalizationKey(roomOrKey);
      const entry = key ? runs.get(key) : null;
      if (!entry) return;
      runs.delete(key);
      entry.controller.abort(abortError({ aborted: true }));
    },
    dispose() {
      disposed = true;
      for (const { controller } of runs.values()) {
        controller.abort(abortError({ aborted: true }));
      }
      runs.clear();
    },
  };
}

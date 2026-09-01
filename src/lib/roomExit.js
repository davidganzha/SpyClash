import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
  normalizedGameRoomExitAction,
} from "./gameRoomExit.js";

const ACTIVE_ROOM_STORAGE_KEY = "spy_active_room_id";
const PENDING_ROOM_EXIT_STORAGE_KEY = "spy_pending_room_exit_id";
const PENDING_ROOM_EXIT_ACTION_STORAGE_KEY = "spy_pending_room_exit_action";
export const PENDING_ROOM_CLOSE_RETRY_DELAYS_MILLISECONDS = Object.freeze([
  1_000,
  2_000,
  4_000,
  8_000,
]);
const defaultSleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const pendingRoomExitCompletions = new Map();

function resolvedStorage(storage) {
  if (storage !== undefined) return storage;
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}

function normalizedRoomId(roomId) {
  return String(roomId ?? "").trim();
}

function confirmsRoomExit(error) {
  const status = Number(error?.status || error?.response?.status);
  return status === 403 || status === 404;
}

function shouldRetryRoomClose(error) {
  const rawStatus = error?.status || error?.response?.status;
  const status = Number(rawStatus);
  if (!Number.isFinite(status) || status <= 0) return true;
  if ([408, 425, 429].includes(status)) return true;
  if (status >= 500 && status <= 599) return true;
  if (status !== 409 || error?.retryable !== true) return false;

  const code = String(error?.code || "").trim().toLocaleLowerCase();
  return code === "active_lease" || code === "cas_contention";
}

export function pendingRoomExitId(storage = undefined) {
  try {
    return normalizedRoomId(
      resolvedStorage(storage)?.getItem(PENDING_ROOM_EXIT_STORAGE_KEY),
    ) || null;
  } catch {
    return null;
  }
}

export function roomExitIsPending(roomId, storage = undefined) {
  const normalized = normalizedRoomId(roomId);
  return Boolean(normalized) && pendingRoomExitId(storage) === normalized;
}

export function pendingRoomExitAction(storage = undefined) {
  const target = resolvedStorage(storage);
  if (!pendingRoomExitId(target)) return null;
  try {
    return normalizedGameRoomExitAction(
      target?.getItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY),
    );
  } catch {
    return GAME_ROOM_LEAVE_ACTION;
  }
}

export function markRoomExitPending(
  roomId,
  storage = undefined,
  action = GAME_ROOM_LEAVE_ACTION,
) {
  const normalized = normalizedRoomId(roomId);
  if (!normalized) return null;

  try {
    const target = resolvedStorage(storage);
    target?.removeItem(ACTIVE_ROOM_STORAGE_KEY);
    target?.removeItem(PENDING_ROOM_EXIT_STORAGE_KEY);
    target?.removeItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY);
    target?.setItem(
      PENDING_ROOM_EXIT_ACTION_STORAGE_KEY,
      normalizedGameRoomExitAction(action),
    );
    target?.setItem(PENDING_ROOM_EXIT_STORAGE_KEY, normalized);
  } catch {
    // Navigation must remain available when storage is unavailable.
  }
  return normalized;
}

export function clearPendingRoomExit(roomId = null, storage = undefined) {
  try {
    const target = resolvedStorage(storage);
    const pending = pendingRoomExitId(target);
    const normalized = normalizedRoomId(roomId);
    if (!normalized || pending === normalized) {
      target?.removeItem(PENDING_ROOM_EXIT_STORAGE_KEY);
      target?.removeItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY);
    }
  } catch {
    // The server leave already succeeded; storage cleanup is best effort.
  }
}

function pendingExitMatches(roomId, action, storage) {
  return pendingRoomExitId(storage) === roomId
    && pendingRoomExitAction(storage) === action;
}

async function runPendingRoomExitCompletion({
  roomId,
  action,
  performExit,
  storage,
  sleep,
  closeRetryDelaysMilliseconds,
}) {
  let failures = 0;
  let attempted = false;
  while (true) {
    if (attempted && !pendingExitMatches(roomId, action, storage)) {
      return true;
    }
    attempted = true;

    try {
      await performExit(roomId);
      clearPendingRoomExit(roomId, storage);
      return true;
    } catch (error) {
      if (confirmsRoomExit(error)) {
        clearPendingRoomExit(roomId, storage);
        return true;
      }
      if (action !== GAME_ROOM_CLOSE_ACTION) return false;
      if (!shouldRetryRoomClose(error)) return false;
      if (!pendingExitMatches(roomId, action, storage)) return true;

      const delayIndex = Math.min(
        failures,
        Math.max(0, closeRetryDelaysMilliseconds.length - 1),
      );
      const delay = Number(closeRetryDelaysMilliseconds[delayIndex]);
      if (!Number.isFinite(delay) || delay < 0) return false;
      failures += 1;
      await sleep(delay);
    }
  }
}

export function completePendingRoomExit({
  roomId,
  action = GAME_ROOM_LEAVE_ACTION,
  performExit,
  storage = undefined,
  sleep = defaultSleep,
  closeRetryDelaysMilliseconds = PENDING_ROOM_CLOSE_RETRY_DELAYS_MILLISECONDS,
}) {
  const normalizedRoom = normalizedRoomId(roomId);
  const normalizedAction = normalizedGameRoomExitAction(action);
  if (!normalizedRoom || typeof performExit !== "function") return Promise.resolve(false);

  const completionKey = `${normalizedAction}:${normalizedRoom}`;
  const inFlight = pendingRoomExitCompletions.get(completionKey);
  if (inFlight) return inFlight;

  const completion = runPendingRoomExitCompletion({
    roomId: normalizedRoom,
    action: normalizedAction,
    performExit,
    storage,
    sleep,
    closeRetryDelaysMilliseconds,
  });
  pendingRoomExitCompletions.set(completionKey, completion);
  const clearSingleFlight = () => {
    if (pendingRoomExitCompletions.get(completionKey) === completion) {
      pendingRoomExitCompletions.delete(completionKey);
    }
  };
  completion.then(clearSingleFlight, clearSingleFlight);
  return completion;
}

export function exitRoomImmediately({
  roomId,
  action = GAME_ROOM_LEAVE_ACTION,
  leaveRoom,
  navigateHome,
  storage = undefined,
}) {
  const normalized = markRoomExitPending(roomId, storage, action);
  if (!normalized) return Promise.resolve(false);

  navigateHome();
  return Promise.resolve()
    .then(() => completePendingRoomExit({
      roomId: normalized,
      action,
      performExit: leaveRoom,
      storage,
    }));
}

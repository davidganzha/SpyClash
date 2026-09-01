import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
  normalizedGameRoomExitAction,
  normalizedGameRoomExitMembershipID,
  normalizedGameRoomExitRevision,
} from "./gameRoomExit.js";

const ACTIVE_ROOM_STORAGE_KEY = "spy_active_room_id";
const PENDING_ROOM_EXIT_STORAGE_KEY = "spy_pending_room_exit_id";
const PENDING_ROOM_EXIT_ACTION_STORAGE_KEY = "spy_pending_room_exit_action";
const PENDING_ROOM_EXIT_REVISION_STORAGE_KEY = "spy_pending_room_exit_revision";
const PENDING_ROOM_EXIT_MEMBERSHIP_STORAGE_KEY = "spy_pending_room_exit_membership_id";
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

export function pendingRoomExitRevision(storage = undefined) {
  const target = resolvedStorage(storage);
  if (!pendingRoomExitId(target)) return null;
  try {
    const rawRevision = target?.getItem(PENDING_ROOM_EXIT_REVISION_STORAGE_KEY);
    return normalizedGameRoomExitRevision(rawRevision);
  } catch {
    return null;
  }
}

export function pendingRoomExitMembershipID(storage = undefined) {
  const target = resolvedStorage(storage);
  if (!pendingRoomExitId(target)) return null;
  try {
    return normalizedGameRoomExitMembershipID(
      target?.getItem(PENDING_ROOM_EXIT_MEMBERSHIP_STORAGE_KEY),
    );
  } catch {
    return null;
  }
}

export function pendingRoomExitMarker(storage = undefined) {
  const roomId = pendingRoomExitId(storage);
  if (!roomId) return null;
  return {
    roomId,
    action: pendingRoomExitAction(storage),
    expectedRevision: pendingRoomExitRevision(storage),
    expectedMembershipID: pendingRoomExitMembershipID(storage),
  };
}

function writePendingRoomExitMarker(marker, storage) {
  const target = resolvedStorage(storage);
  target?.removeItem(ACTIVE_ROOM_STORAGE_KEY);
  target?.removeItem(PENDING_ROOM_EXIT_STORAGE_KEY);
  target?.removeItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY);
  target?.removeItem(PENDING_ROOM_EXIT_REVISION_STORAGE_KEY);
  target?.removeItem(PENDING_ROOM_EXIT_MEMBERSHIP_STORAGE_KEY);
  target?.setItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY, marker.action);
  target?.setItem(PENDING_ROOM_EXIT_STORAGE_KEY, marker.roomId);
  if (marker.expectedRevision !== null) {
    target?.setItem(
      PENDING_ROOM_EXIT_REVISION_STORAGE_KEY,
      marker.expectedRevision,
    );
  }
  if (marker.expectedMembershipID !== null) {
    target?.setItem(
      PENDING_ROOM_EXIT_MEMBERSHIP_STORAGE_KEY,
      marker.expectedMembershipID,
    );
  }
}

export function markRoomExitPending(
  roomId,
  storage = undefined,
  action = GAME_ROOM_LEAVE_ACTION,
  expectedRevision = null,
  expectedMembershipID = null,
) {
  const normalized = normalizedRoomId(roomId);
  if (!normalized) return null;

  try {
    const target = resolvedStorage(storage);
    const requestedRevision = normalizedGameRoomExitRevision(expectedRevision);
    const requestedMembershipID = normalizedGameRoomExitMembershipID(
      expectedMembershipID,
    );
    writePendingRoomExitMarker({
      roomId: normalized,
      action: normalizedGameRoomExitAction(action),
      expectedRevision: requestedRevision,
      expectedMembershipID: requestedMembershipID,
    }, target);
  } catch {
    // Navigation must remain available when storage is unavailable.
  }
  return normalized;
}

function pendingExitMatches(marker, storage) {
  const current = pendingRoomExitMarker(storage);
  return Boolean(current)
    && current.roomId === marker.roomId
    && current.action === marker.action
    && current.expectedRevision === marker.expectedRevision
    && current.expectedMembershipID === marker.expectedMembershipID;
}

export function clearPendingRoomExit(
  roomId = null,
  storage = undefined,
  expectedMarker = null,
) {
  try {
    const target = resolvedStorage(storage);
    const pending = pendingRoomExitId(target);
    const normalized = normalizedRoomId(roomId);
    if (normalized && pending !== normalized) return false;
    if (expectedMarker?.force !== true && !expectedMarker) return false;
    if (
      expectedMarker?.force !== true
      && !pendingExitMatches({
        roomId: normalized || pending,
        action: normalizedGameRoomExitAction(expectedMarker?.action),
        expectedRevision: normalizedGameRoomExitRevision(
          expectedMarker?.expectedRevision,
        ),
        expectedMembershipID: normalizedGameRoomExitMembershipID(
          expectedMarker?.expectedMembershipID,
        ),
      }, target)
    ) return false;
    target?.removeItem(PENDING_ROOM_EXIT_STORAGE_KEY);
    target?.removeItem(PENDING_ROOM_EXIT_ACTION_STORAGE_KEY);
    target?.removeItem(PENDING_ROOM_EXIT_REVISION_STORAGE_KEY);
    target?.removeItem(PENDING_ROOM_EXIT_MEMBERSHIP_STORAGE_KEY);
    return true;
  } catch {
    // The server leave already succeeded; storage cleanup is best effort.
    return false;
  }
}

function transitionPendingRoomExitAction(marker, nextAction, storage) {
  if (!pendingExitMatches(marker, storage)) return null;
  const nextMarker = {
    ...marker,
    action: normalizedGameRoomExitAction(nextAction),
  };
  try {
    writePendingRoomExitMarker(nextMarker, storage);
    return nextMarker;
  } catch {
    return null;
  }
}

async function runPendingRoomExitCompletion({
  roomId,
  action,
  expectedRevision,
  expectedMembershipID,
  performExit,
  performLeaveFallback,
  storage,
  sleep,
  closeRetryDelaysMilliseconds,
}) {
  const marker = {
    roomId,
    action,
    expectedRevision,
    expectedMembershipID,
  };
  let failures = 0;
  while (true) {
    if (!pendingExitMatches(marker, storage)) return true;

    try {
      await performExit(roomId, expectedRevision, expectedMembershipID);
      clearPendingRoomExit(roomId, storage, marker);
      return true;
    } catch (error) {
      if (
        action === GAME_ROOM_CLOSE_ACTION
        && Number(error?.status || error?.response?.status) === 403
      ) {
        // Host authority moved, so the durable remaining intent is now an
        // ordinary leave. Persist that before the fallback starts: the request
        // may commit after a local timeout or the app may close mid-flight.
        const leaveMarker = transitionPendingRoomExitAction(
          marker,
          GAME_ROOM_LEAVE_ACTION,
          storage,
        );
        if (!leaveMarker) return true;
        if (typeof performLeaveFallback !== "function") return false;
        try {
          await performLeaveFallback(
            roomId,
            expectedRevision,
            expectedMembershipID,
          );
          clearPendingRoomExit(roomId, storage, leaveMarker);
          return true;
        } catch (fallbackError) {
          if (confirmsRoomExit(fallbackError)) {
            clearPendingRoomExit(roomId, storage, leaveMarker);
            return true;
          }
          // Preserve the leave marker for a later bounded Home/remount retry.
          return false;
        }
      }
      if (confirmsRoomExit(error)) {
        clearPendingRoomExit(roomId, storage, marker);
        return true;
      }
      if (action !== GAME_ROOM_CLOSE_ACTION) return false;
      if (!shouldRetryRoomClose(error)) return false;
      if (!pendingExitMatches(marker, storage)) return true;

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
  expectedRevision: requestedRevisionValue = null,
  expectedMembershipID: requestedMembershipValue = null,
  performExit,
  performLeaveFallback = null,
  storage = undefined,
  sleep = defaultSleep,
  closeRetryDelaysMilliseconds = PENDING_ROOM_CLOSE_RETRY_DELAYS_MILLISECONDS,
}) {
  const normalizedRoom = normalizedRoomId(roomId);
  const normalizedAction = normalizedGameRoomExitAction(action);
  const persistedMarker = pendingRoomExitMarker(storage);
  const persistedRevision = persistedMarker?.roomId === normalizedRoom
    ? persistedMarker.expectedRevision
    : null;
  const persistedMembershipID = persistedMarker?.roomId === normalizedRoom
    ? persistedMarker.expectedMembershipID
    : null;
  const requestedRevision = normalizedGameRoomExitRevision(requestedRevisionValue);
  const requestedMembershipID = normalizedGameRoomExitMembershipID(
    requestedMembershipValue,
  );
  const expectedRevision = requestedRevision ?? persistedRevision;
  const expectedMembershipID = requestedMembershipID ?? persistedMembershipID;
  if (!normalizedRoom || typeof performExit !== "function") return Promise.resolve(false);

  // One membership generation can legitimately transition from close -> leave
  // after a 403. Home/remount shares that worker, while a later rejoin/exit
  // generation receives an independent completion that the old worker cannot
  // clear.
  const completionKey = [
    normalizedRoom,
    expectedRevision ?? "legacy",
    expectedMembershipID ?? "legacy",
  ].join(":");
  const inFlight = pendingRoomExitCompletions.get(completionKey);
  if (inFlight) return inFlight;

  const completion = runPendingRoomExitCompletion({
    roomId: normalizedRoom,
    action: normalizedAction,
    expectedRevision,
    expectedMembershipID,
    performExit,
    performLeaveFallback,
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
  expectedRevision = null,
  expectedMembershipID = null,
  performExit,
  performLeaveFallback = null,
  navigateHome,
  storage = undefined,
}) {
  const normalized = markRoomExitPending(
    roomId,
    storage,
    action,
    expectedRevision,
    expectedMembershipID,
  );
  if (!normalized) return Promise.resolve(false);

  navigateHome();
  return Promise.resolve()
    .then(() => completePendingRoomExit({
      roomId: normalized,
      action,
      expectedRevision,
      expectedMembershipID,
      performExit,
      performLeaveFallback,
      storage,
    }));
}

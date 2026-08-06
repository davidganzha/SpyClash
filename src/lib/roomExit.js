const ACTIVE_ROOM_STORAGE_KEY = "spy_active_room_id";
const PENDING_ROOM_EXIT_STORAGE_KEY = "spy_pending_room_exit_id";

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

export function markRoomExitPending(roomId, storage = undefined) {
  const normalized = normalizedRoomId(roomId);
  if (!normalized) return null;

  try {
    const target = resolvedStorage(storage);
    target?.removeItem(ACTIVE_ROOM_STORAGE_KEY);
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
    }
  } catch {
    // The server leave already succeeded; storage cleanup is best effort.
  }
}

export function exitRoomImmediately({
  roomId,
  leaveRoom,
  navigateHome,
  storage = undefined,
}) {
  const normalized = markRoomExitPending(roomId, storage);
  if (!normalized) return Promise.resolve(false);

  navigateHome();
  return Promise.resolve()
    .then(() => leaveRoom(normalized))
    .then(() => {
      clearPendingRoomExit(normalized, storage);
      return true;
    })
    .catch(() => false);
}

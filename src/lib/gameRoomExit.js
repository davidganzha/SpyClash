export const GAME_ROOM_LEAVE_ACTION = "leave_room";
export const GAME_ROOM_CLOSE_ACTION = "close_room";

function clean(value) {
  return String(value ?? "").trim();
}

function normalizedEmail(value) {
  return clean(value).toLocaleLowerCase();
}

export function normalizedGameRoomExitAction(action) {
  return clean(action) === GAME_ROOM_CLOSE_ACTION
    ? GAME_ROOM_CLOSE_ACTION
    : GAME_ROOM_LEAVE_ACTION;
}

export function gameRoomExitAction({
  hostEmail,
  userEmail,
  closeForHost = false,
}) {
  const host = normalizedEmail(hostEmail);
  const user = normalizedEmail(userEmail);
  return closeForHost && host && user && host === user
    ? GAME_ROOM_CLOSE_ACTION
    : GAME_ROOM_LEAVE_ACTION;
}

export function gameRoomExitPayload({ action, roomId }) {
  const normalizedRoomId = clean(roomId);
  if (!normalizedRoomId) throw new TypeError("Room ID is required for room exit");
  return {
    action: normalizedGameRoomExitAction(action),
    room_id: normalizedRoomId,
  };
}

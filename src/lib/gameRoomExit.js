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

export function normalizedGameRoomExitRevision(value) {
  const candidate = clean(value);
  if (!candidate) return null;
  const revision = Number(candidate);
  return Number.isInteger(revision) && revision >= 0 ? revision : null;
}

export function normalizedGameRoomExitMembershipID(value) {
  return clean(value) || null;
}

export function gameRoomExitExpectedRevision(room) {
  return normalizedGameRoomExitRevision(room?.room_revision) ?? 0;
}

export function gameRoomExitExpectedMembershipID(room) {
  return normalizedGameRoomExitMembershipID(room?.viewer_membership_id);
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

export function gameRoomExitPayload({
  action,
  roomId,
  expectedRevision = null,
  expectedMembershipID = null,
}) {
  const normalizedRoomId = clean(roomId);
  if (!normalizedRoomId) throw new TypeError("Room ID is required for room exit");
  const revision = normalizedGameRoomExitRevision(expectedRevision);
  const membershipID = normalizedGameRoomExitMembershipID(expectedMembershipID);
  return {
    action: normalizedGameRoomExitAction(action),
    room_id: normalizedRoomId,
    ...(revision === null ? {} : { expected_revision: revision }),
    ...(membershipID === null ? {} : { expected_membership_id: membershipID }),
  };
}

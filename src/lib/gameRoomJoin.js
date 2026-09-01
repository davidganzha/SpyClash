function clean(value) {
  return String(value ?? "").trim();
}

export function createGameRoomJoinMembershipID(
  randomUUID = () => globalThis.crypto.randomUUID(),
) {
  const membershipID = clean(randomUUID());
  if (!membershipID) throw new TypeError("Join membership ID is required");
  return membershipID;
}

export function gameRoomJoinPayload({
  roomId = null,
  roomCode = null,
  player,
  joinMembershipID = null,
  expectedMembershipID = null,
  randomUUID = undefined,
}) {
  const stableJoinMembershipID = clean(joinMembershipID)
    || createGameRoomJoinMembershipID(randomUUID);
  const expected = clean(expectedMembershipID);
  return {
    action: "join_room",
    room_id: roomId,
    room_code: roomCode,
    player,
    join_membership_id: stableJoinMembershipID,
    ...(expected ? { expected_membership_id: expected } : {}),
  };
}

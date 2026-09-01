import {
  friendshipAllowsRoomInvite,
  incomingRoomInviteHasAcceptedFriendship,
  isReservedManualSpyID,
  normalizeCommunityQuery,
  normalizeRadarInvitePolicy,
  normalizeSpyID,
  preferredSpyIDOwner,
  profileMatchesCommunityQuery,
  publicProfile,
  requireAcceptedFriendshipForRoomInviteAction,
  roomAcceptsCommunityInvites,
  sanitizeProfileComment,
  stableSpyID,
} from "./community.ts";

Deno.test("Radar invite policy accepts only the shared account enum", () => {
  if (normalizeRadarInvitePolicy(" AUTOMATIC ") !== "automatic") {
    throw new Error("automatic policy was not normalized");
  }
  for (const policy of ["ask", "blocked"]) {
    if (normalizeRadarInvitePolicy(policy) !== policy) {
      throw new Error(`${policy} policy was rejected`);
    }
  }
  for (const invalid of ["", "auto", "friends_only", null]) {
    if (normalizeRadarInvitePolicy(invalid) !== null) {
      throw new Error(`invalid Radar policy was accepted: ${invalid}`);
    }
  }
});

Deno.test("normalizes canonical and compact SPY IDs", () => {
  const expected = "004-219";
  if (normalizeSpyID("004219") !== expected) {
    throw new Error("compact SPY ID was not normalized");
  }
  if (normalizeSpyID(expected) !== expected) {
    throw new Error("canonical SPY ID changed");
  }
  if (normalizeSpyID("004 219") !== expected) {
    throw new Error("spaced SPY ID was not normalized");
  }
  if (normalizeSpyID("not-an-id") !== null) {
    throw new Error("invalid SPY ID was accepted");
  }
  if (normalizeSpyID("A1B2-C3D4-E5F6-0123-4567") !== null) {
    throw new Error("legacy SPY ID was accepted");
  }
});

Deno.test("derives stable six digit SPY IDs with a collision probe", async () => {
  const first = await stableSpyID("user-1");
  if (first !== "333-910") {
    throw new Error(`SPY ID derivation contract drifted: ${first}`);
  }
  if (!/^[0-9]{3}-[0-9]{3}$/.test(first)) {
    throw new Error(`unexpected SPY ID format: ${first}`);
  }
  if (first !== await stableSpyID("user-1")) {
    throw new Error("SPY ID derivation is not stable");
  }
  if (first === await stableSpyID("user-1", 1)) {
    throw new Error("collision probe did not advance");
  }
});

Deno.test("manual SPY ID 067-067 is reserved from automatic allocation", () => {
  for (const value of ["067-067", "067067", "067 067"]) {
    if (!isReservedManualSpyID(value)) {
      throw new Error(`manual SPY ID was not reserved: ${value}`);
    }
  }
  for (const value of ["067-068", "not-an-id", null]) {
    if (isReservedManualSpyID(value)) {
      throw new Error(`ordinary SPY ID was reserved: ${value}`);
    }
  }
});

Deno.test("duplicate SPY ID ownership is deterministic", () => {
  const owner = preferredSpyIDOwner([
    { id: "user-b", created_date: "2026-01-02T00:00:00.000Z" },
    { id: "user-a", created_date: "2026-01-01T00:00:00.000Z" },
  ]);
  if (owner?.id !== "user-a") {
    throw new Error("oldest account did not win the duplicate claim");
  }
});

Deno.test("public profile never exposes private identity fields", () => {
  const profile = publicProfile({
    id: "user-1",
    email: "secret@example.com",
    full_name: "Secret Name",
    display_name: "Cipher",
    spy_id: "104-827",
    games_played: 4,
    games_won: 3,
    spy_games_played: 2,
    spy_games_won: 1,
    detective_games_played: 2,
    detective_games_won: 2,
  });
  if ("email" in profile || "full_name" in profile) {
    throw new Error("private identity leaked into public profile");
  }
  if (profile.win_rate !== 75) throw new Error("win rate is incorrect");
  if (
    profile.spy_games_played !== 2 || profile.spy_games_won !== 1 ||
    profile.spy_win_rate !== 50
  ) {
    throw new Error("spy role statistics are incorrect");
  }
  if (
    profile.detective_games_played !== 2 ||
    profile.detective_games_won !== 2 ||
    profile.detective_win_rate !== 100
  ) {
    throw new Error("detective role statistics are incorrect");
  }
});

Deno.test("public profile keeps additive role statistics safe for legacy rows", () => {
  const profile = publicProfile({
    id: "legacy-user",
    games_played: 0,
    games_won: 0,
    spy_games_played: -1,
    spy_games_won: "invalid",
  });
  if (
    profile.spy_games_played !== 0 || profile.spy_games_won !== 0 ||
    profile.spy_win_rate !== 0 || profile.detective_games_played !== 0 ||
    profile.detective_games_won !== 0 || profile.detective_win_rate !== 0
  ) {
    throw new Error("legacy role statistics did not use zero-safe projection");
  }
});

Deno.test("community directory searches display names and formatted SPY IDs", () => {
  const profile = { display_name: "Red Raven", spy_id: "004-219" };
  if (!profileMatchesCommunityQuery(profile, "raven")) {
    throw new Error("display name was not searchable");
  }
  if (!profileMatchesCommunityQuery(profile, "004219")) {
    throw new Error("compact SPY ID was not searchable");
  }
  if (profileMatchesCommunityQuery(profile, "cipher")) {
    throw new Error("unrelated profile matched");
  }
  if (normalizeCommunityQuery("  RED   RAVEN  ") !== "red raven") {
    throw new Error("directory query was not normalized");
  }
});

Deno.test("profile comments are normalized and bounded", () => {
  if (
    sanitizeProfileComment("  Clean   signal\r\n\r\n\r\nConfirmed  ") !==
      "Clean signal\n\nConfirmed"
  ) {
    throw new Error("profile comment was not normalized");
  }
  if (sanitizeProfileComment("   ") !== null) {
    throw new Error("empty profile comment was accepted");
  }
  if (sanitizeProfileComment("x".repeat(281)) !== null) {
    throw new Error("oversized profile comment was accepted");
  }
});

Deno.test("community room invites are limited to waiting rooms", () => {
  if (!roomAcceptsCommunityInvites("WAITING")) {
    throw new Error("waiting room rejected invites");
  }
  for (const status of ["ready_voting", "roulette", "playing", "finished"]) {
    if (roomAcceptsCommunityInvites(status)) {
      throw new Error(`${status} room accepted an invite`);
    }
  }
});

Deno.test("room invites require one accepted unblocked friendship", () => {
  const users = ["user-a", "user-b"] as const;
  const relationship = (status: string, reverse = false) => ({
    id: `${status}-${reverse}`,
    requester_id: reverse ? users[1] : users[0],
    addressee_id: reverse ? users[0] : users[1],
    status,
  });

  if (!friendshipAllowsRoomInvite([relationship("accepted")], ...users)) {
    throw new Error("accepted friendship was rejected");
  }
  if (!friendshipAllowsRoomInvite([relationship("accepted", true)], ...users)) {
    throw new Error("reverse accepted friendship was rejected");
  }
  for (const status of ["pending", "declined", "removed", ""]) {
    if (friendshipAllowsRoomInvite([relationship(status)], ...users)) {
      throw new Error(`${status || "blank"} friendship allowed a room invite`);
    }
  }
  if (
    friendshipAllowsRoomInvite(
      [relationship("accepted"), relationship("blocked", true)],
      ...users,
    )
  ) {
    throw new Error("blocked duplicate relationship allowed a room invite");
  }
  if (
    friendshipAllowsRoomInvite(
      [{ ...relationship("accepted"), addressee_id: "user-c" }],
      ...users,
    )
  ) {
    throw new Error("unrelated accepted friendship allowed a room invite");
  }
});

Deno.test("incoming room invites disappear when friendship is removed", () => {
  const accepted = [{
    id: "friendship-1",
    requester_id: "user-a",
    addressee_id: "user-b",
    status: "accepted",
  }];

  for (const status of ["pending", "accepted"]) {
    const invite = {
      id: `invite-${status}`,
      sender_user_id: "user-a",
      recipient_user_id: "user-b",
      status,
    };
    if (!incomingRoomInviteHasAcceptedFriendship(invite, accepted, "user-b")) {
      throw new Error(`accepted friend's ${status} invite was hidden`);
    }
    if (incomingRoomInviteHasAcceptedFriendship(invite, [], "user-b")) {
      throw new Error(
        `stale ${status} invite remained visible after friendship removal`,
      );
    }
    if (incomingRoomInviteHasAcceptedFriendship(invite, accepted, "user-c")) {
      throw new Error(`${status} invite was visible to a different recipient`);
    }
  }
});

Deno.test("room invite acceptance rechecks friendship without blocking cleanup", async () => {
  let cleanupRelationshipLoads = 0;
  for (const action of ["decline_room_invite", "consume_room_invite"]) {
    await requireAcceptedFriendshipForRoomInviteAction(
      action,
      () => {
        cleanupRelationshipLoads += 1;
        throw new Error("cleanup loaded friendships");
      },
      "user-a",
      "user-b",
    );
  }
  if (cleanupRelationshipLoads !== 0) {
    throw new Error("cleanup depended on a friendship lookup");
  }

  const invalidFriendships = [
    [],
    [{
      requester_id: "user-a",
      addressee_id: "user-b",
      status: "pending",
    }],
    [{
      requester_id: "user-a",
      addressee_id: "user-b",
      status: "declined",
    }],
    [{
      requester_id: "user-a",
      addressee_id: "user-b",
      status: "blocked",
    }],
    [{
      requester_id: "user-a",
      addressee_id: "user-b",
      status: "accepted",
    }, {
      requester_id: "user-b",
      addressee_id: "user-a",
      status: "blocked",
    }],
  ];
  for (const friendships of invalidFriendships) {
    let rejection: unknown = null;
    try {
      await requireAcceptedFriendshipForRoomInviteAction(
        "accept_room_invite",
        () => Promise.resolve(friendships),
        "user-a",
        "user-b",
      );
    } catch (error) {
      rejection = error;
    }
    if (
      !(rejection instanceof Error) ||
      (rejection as Error & { status?: number }).status !== 403
    ) {
      throw new Error("accept_room_invite was not rejected without friendship");
    }
  }

  await requireAcceptedFriendshipForRoomInviteAction(
    "accept_room_invite",
    () =>
      Promise.resolve([{
        requester_id: "user-a",
        addressee_id: "user-b",
        status: "accepted",
      }]),
    "user-a",
    "user-b",
  );
});

import {
  communityActionRequiresProfileWriteLease,
  normalizeCommunityQuery,
  normalizeRadarInvitePolicy,
  normalizeSpyID,
  preferredSpyIDOwner,
  profileMatchesCommunityQuery,
  publicProfile,
  roomAcceptsCommunityInvites,
  sanitizeProfileComment,
  stableSpyID,
} from "./community.ts";

Deno.test("community reads do not acquire the profile writer lease", () => {
  for (const action of ["state", "directory", "search", "profile"]) {
    if (communityActionRequiresProfileWriteLease(action)) {
      throw new Error(`${action} unexpectedly requires a writer lease`);
    }
  }
  for (
    const action of [
      "send_request",
      "add_comment",
      "report",
      "set_radar_invite_policy",
    ]
  ) {
    if (!communityActionRequiresProfileWriteLease(action)) {
      throw new Error(`${action} unexpectedly bypasses the writer lease`);
    }
  }
});

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
  });
  if ("email" in profile || "full_name" in profile) {
    throw new Error("private identity leaked into public profile");
  }
  if (profile.win_rate !== 75) throw new Error("win rate is incorrect");
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

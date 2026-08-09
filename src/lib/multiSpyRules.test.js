import assert from "node:assert/strict";
import test from "node:test";

import {
  isAllowedSpyCount,
  isClientUpdateRequiredError,
  isRankedSpyRoom,
  isSpyEmailForRoom,
  maxSpyCountForPlayerCount,
  normalizeSpyCount,
  projectedSpyEmails,
  projectedSpyTeammates,
  publicSpyCount,
  resultSpyPlayers,
  withMultiSpyActionCapability,
  withMultiSpyPlayerCapability,
} from "./multiSpyRules.js";

test("spy count follows the approved 3-5, 6-8, and 9-12 bands", () => {
  assert.deepEqual(
    Array.from({ length: 12 }, (_, index) => maxSpyCountForPlayerCount(index + 1)),
    [1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3],
  );
  assert.equal(isAllowedSpyCount(5, 2), false);
  assert.equal(isAllowedSpyCount(6, 2), true);
  assert.equal(isAllowedSpyCount(8, 3), false);
  assert.equal(isAllowedSpyCount(9, 3), true);
  assert.equal(isAllowedSpyCount(2, 1), false);
  assert.equal(normalizeSpyCount(9), 3);
  assert.equal(normalizeSpyCount(2, 5), 1);
});

test("role membership prefers the projected plural contract and falls back to legacy", () => {
  const plural = {
    spy_emails: [" First@Example.com ", "second@example.com", "FIRST@example.com"],
    spy_email: "legacy@example.com",
  };
  assert.deepEqual(projectedSpyEmails(plural), ["first@example.com", "second@example.com"]);
  assert.equal(isSpyEmailForRoom(plural, "SECOND@example.com"), true);
  assert.equal(isSpyEmailForRoom(plural, "legacy@example.com"), false);
  assert.deepEqual(projectedSpyEmails({ spy_email: "Legacy@Example.com" }), ["legacy@example.com"]);
});

test("teammates remain hidden unless both the switch and viewer-safe projection allow them", () => {
  const room = {
    spies_know_each_other: false,
    spy_emails: ["one@example.com", "two@example.com"],
    players: [
      { email: "one@example.com", name: "One" },
      { email: "two@example.com", name: "Two" },
      { email: "detective@example.com", name: "Detective" },
    ],
  };
  assert.deepEqual(projectedSpyTeammates(room, "one@example.com"), []);
  assert.deepEqual(
    projectedSpyTeammates({ ...room, spies_know_each_other: true }, "one@example.com")
      .map((player) => player.email),
    ["two@example.com"],
  );
  assert.deepEqual(
    projectedSpyTeammates({ ...room, spies_know_each_other: true }, "detective@example.com"),
    [],
  );
});

test("result roster may use only projected and explicitly revealed spy identities", () => {
  const room = {
    spy_emails: ["one@example.com"],
    revealed_spy_emails: ["two@example.com"],
    players: [
      { email: "one@example.com" },
      { email: "two@example.com" },
      { email: "detective@example.com" },
    ],
  };
  assert.deepEqual(
    resultSpyPlayers(room).map((player) => player.email),
    ["one@example.com", "two@example.com"],
  );
});

test("public count makes multi-spy presentation unranked", () => {
  assert.equal(publicSpyCount({}), 1);
  assert.equal(publicSpyCount({ lobby_spy_count: 2 }), 2);
  assert.equal(isRankedSpyRoom({ lobby_spy_count: 1, ranked: true }), true);
  assert.equal(isRankedSpyRoom({ lobby_spy_count: 2, ranked: true }), false);
  assert.equal(isRankedSpyRoom({ lobby_spy_count: 1, ranked: false }), false);
});

test("all room requests and player envelopes advertise multi_spy_v1 once", () => {
  assert.deepEqual(withMultiSpyActionCapability({
    action: "get_room",
    client_capabilities: ["legacy", "multi_spy_v1"],
  }), {
    action: "get_room",
    client_capabilities: ["legacy", "multi_spy_v1"],
  });
  assert.deepEqual(withMultiSpyPlayerCapability({ name: "Raven" }), {
    name: "Raven",
    client_capabilities: ["multi_spy_v1"],
  });
  assert.equal(isClientUpdateRequiredError({ code: "MULTI_SPY_CLIENT_UPDATE_REQUIRED" }), true);
});

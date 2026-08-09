import assert from "node:assert/strict";
import test from "node:test";

import {
  isOnlineGameHistory,
  isRankedOnlineGameHistory,
  mergePlayerGameHistory,
} from "./gameHistoryPolicy.js";

test("accepts explicitly ranked online matches", () => {
  assert.equal(isOnlineGameHistory({ match_type: "online", ranked: true }), true);
  assert.equal(isOnlineGameHistory({ match_type: "online", ranked: false }), true);
});

test("rejects local matches but keeps unranked online history visible", () => {
  assert.equal(isOnlineGameHistory({ match_type: "local", room_code: "ABC123" }), false);
  assert.equal(isOnlineGameHistory({ ranked: false, room_code: "ABC123" }), true);
  assert.equal(isRankedOnlineGameHistory({ match_type: "online", ranked: false }), false);
  assert.equal(isRankedOnlineGameHistory({ match_type: "online", ranked: true, spy_count: 2 }), false);
  assert.equal(isRankedOnlineGameHistory({ match_type: "online", ranked: true, spy_count: 1 }), true);
});

test("keeps legacy online room history", () => {
  assert.equal(isOnlineGameHistory({ room_code: "IX82UN" }), true);
  assert.equal(isOnlineGameHistory({ room_code: "z0ct88" }), true);
});

test("rejects records without a valid online-room identity", () => {
  assert.equal(isOnlineGameHistory({ room_code: "LOCAL" }), false);
  assert.equal(isOnlineGameHistory({ room_code: "" }), false);
  assert.equal(isOnlineGameHistory({}), false);
});

test("stable-id and legacy-email history merge without duplicates in newest-first order", () => {
  const stable = [
    { id: "new", match_type: "online", ranked: true, created_date: "2026-07-03T00:00:00Z" },
    { id: "shared", match_type: "online", ranked: true, created_date: "2026-07-02T00:00:00Z" },
  ];
  const legacy = [
    { id: "shared", room_code: "ABC123", created_date: "2026-07-02T00:00:00Z" },
    { id: "legacy", room_code: "OLD123", created_date: "2026-07-01T00:00:00Z" },
    { id: "local", match_type: "local", created_date: "2026-07-04T00:00:00Z" },
    { id: "multi", match_type: "online", ranked: false, spy_count: 2, created_date: "2026-07-05T00:00:00Z" },
  ];

  assert.deepEqual(
    mergePlayerGameHistory([stable, legacy]).map(record => record.id),
    ["multi", "new", "shared", "legacy"],
  );
  assert.deepEqual(
    mergePlayerGameHistory([stable, legacy], 2).map(record => record.id),
    ["multi", "new"],
  );
});

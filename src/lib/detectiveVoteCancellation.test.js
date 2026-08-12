import assert from "node:assert/strict";
import test from "node:test";

import {
  DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS,
  detectiveVoteCancellationIdentity,
  detectiveVoteCancellationWindow,
  hasDetectiveVoteCancellationEvent,
} from "./detectiveVoteCancellation.js";

const presentAt = "2026-08-12T12:00:00.600Z";
const eventRoom = {
  detective_vote_cancellation_event_id: "cancel-event-1",
  detective_vote_cancellation_round_id: "vote-round-7",
  detective_vote_cancellation_present_at: presentAt,
  detective_vote_cancellation_reason: "no_viable_candidate",
};

test("durable cancellation identity requires the complete typed envelope", () => {
  assert.deepEqual(detectiveVoteCancellationIdentity(eventRoom), {
    id: "cancel-event-1",
    roundID: "vote-round-7",
    reason: "no_viable_candidate",
    presentAtISO: presentAt,
    presentAtMs: Date.parse(presentAt),
  });
  assert.equal(hasDetectiveVoteCancellationEvent(eventRoom), true);

  for (const field of [
    "detective_vote_cancellation_event_id",
    "detective_vote_cancellation_round_id",
    "detective_vote_cancellation_present_at",
    "detective_vote_cancellation_reason",
  ]) {
    assert.equal(
      detectiveVoteCancellationIdentity({ ...eventRoom, [field]: "" }),
      null,
    );
  }
  assert.equal(detectiveVoteCancellationIdentity({
    ...eventRoom,
    detective_vote_cancellation_reason: "legacy_reason",
  }), null);
  assert.equal(detectiveVoteCancellationIdentity({
    ...eventRoom,
    detective_vote_cancellation_present_at: "not-a-date",
  }), null);
});

test("cancellation window synchronizes future, in-progress, and expired clients", () => {
  const startsAtMs = Date.parse(presentAt);

  assert.deepEqual(
    detectiveVoteCancellationWindow(eventRoom, startsAtMs - 600),
    {
      ...detectiveVoteCancellationIdentity(eventRoom),
      endsAtMs: startsAtMs + DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS,
      delayMs: 600,
      elapsedMs: 0,
      remainingMs: DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS + 600,
    },
  );

  const inProgress = detectiveVoteCancellationWindow(eventRoom, startsAtMs + 1_750);
  assert.equal(inProgress.delayMs, 0);
  assert.equal(inProgress.elapsedMs, 1_750);
  assert.equal(
    inProgress.remainingMs,
    DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS - 1_750,
  );

  assert.equal(
    detectiveVoteCancellationWindow(
      eventRoom,
      startsAtMs + DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS,
    ),
    null,
  );
  assert.equal(detectiveVoteCancellationWindow(eventRoom, Number.NaN), null);
});

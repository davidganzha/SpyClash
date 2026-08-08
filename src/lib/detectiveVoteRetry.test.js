import assert from "node:assert/strict";
import test from "node:test";

import {
  DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS,
  recoverDetectiveVoteCastConflict,
} from "./detectiveVoteRetry.js";

const actor = "actor@example.com";
const target = "target@example.com";

function room(patch = {}) {
  return {
    id: "room-1",
    match_id: "match-1",
    room_revision: 10,
    detective_vote_round_id: "round-a",
    status: "playing",
    winner: "",
    players: [
      { email: actor },
      { email: target },
      { email: "p3@example.com" },
      { email: "p4@example.com" },
      { email: "p5@example.com" },
      { email: "p6@example.com" },
    ],
    spectators: [],
    eliminated_emails: [],
    vote_requests: [actor, target, "p3@example.com", "p4@example.com"],
    detective_votes: [],
    game_started_at: "2026-08-08T12:00:00.000Z",
    game_duration_seconds: 600,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    ...patch,
  };
}

function retryable(code = "active_lease") {
  return Object.assign(new Error(code), {
    status: 409,
    code,
    retryable: true,
  });
}

function input(patch = {}) {
  return {
    action: "cast_detective_vote",
    error: retryable(),
    room: room(),
    actorEmail: actor,
    targetEmail: target,
    now: () => Date.parse("2026-08-08T12:01:00.000Z"),
    sleep: () => Promise.resolve(),
    refreshRoom: () => Promise.resolve(room()),
    castVote: () => Promise.resolve(room({
      detective_votes: [{ voter_email: actor, voted_for_email: target }],
    })),
    ...patch,
  };
}

test("wrong action, untyped error, and changed match remain visible", async () => {
  const failures = [
    { action: "request_vote" },
    { error: Object.assign(new Error("untyped"), { status: 409 }) },
    { refreshRoom: () => Promise.resolve(room({ match_id: "match-2" })) },
  ];

  for (const patch of failures) {
    const scoped = input(patch);
    await assert.rejects(
      recoverDetectiveVoteCastConflict(scoped),
      (error) => error === scoped.error,
    );
  }
});

test("reopened Round B is adopted without replaying stale Round A", async () => {
  let casts = 0;
  const reopened = room({
    detective_vote_round_id: "round-b",
    detective_votes: [{
      voter_email: actor,
      voted_for_email: target,
    }],
  });
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(reopened),
    castVote: () => {
      casts += 1;
      return Promise.resolve(reopened);
    },
  }));
  assert.equal(result, reopened);
  assert.equal(casts, 0);
});

test("Round B request phase with a blank id adopts without stale Round A replay", async () => {
  let casts = 0;
  const requestPhase = room({
    detective_vote_round_id: "",
    vote_requests: ["p3@example.com", "p4@example.com"],
    detective_votes: [],
  });
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(requestPhase),
    castVote: () => {
      casts += 1;
      return Promise.resolve(requestPhase);
    },
  }));
  assert.equal(result, requestPhase);
  assert.equal(casts, 0);
});

test("target leave is adopted without replay or an active-lease error", async () => {
  let casts = 0;
  const afterLeave = room({
    players: room().players.filter((player) => player.email !== target),
    detective_vote_round_id: "",
    vote_requests: [],
    detective_votes: [],
  });
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(afterLeave),
    castVote: () => {
      casts += 1;
      return Promise.resolve(afterLeave);
    },
  }));
  assert.equal(result, afterLeave);
  assert.equal(casts, 0);
});

test("finished terminal is accepted without replaying the cast", async () => {
  let casts = 0;
  const finished = room({
    status: "finished",
    winner: "detectives",
    detective_vote_round_id: "",
  });
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(finished),
    castVote: () => {
      casts += 1;
      return Promise.resolve(finished);
    },
  }));
  assert.equal(result, finished);
  assert.equal(casts, 0);
});

test("atomic cancellation and innocent ejection are authoritative success", async () => {
  const cancelled = room({
    detective_vote_round_id: "",
    vote_requests: [],
    detective_votes: [],
  });
  const ejected = room({
    detective_vote_round_id: "",
    spectators: [target],
    eliminated_emails: [target],
    vote_requests: [],
    detective_votes: [],
  });
  for (const settled of [cancelled, ejected]) {
    const result = await recoverDetectiveVoteCastConflict(input({
      refreshRoom: () => Promise.resolve(settled),
    }));
    assert.equal(result, settled);
  }
});

test("the exact persisted actor-target vote is accepted", async () => {
  const persisted = room({
    detective_votes: [{
      voter_email: "ACTOR@example.com",
      voted_for_email: "TARGET@example.com",
    }],
  });
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(persisted),
  }));
  assert.equal(result, persisted);
});

test("an authoritative unpaused deadline is accepted without another cast", async () => {
  let casts = 0;
  const expired = room();
  const result = await recoverDetectiveVoteCastConflict(input({
    now: () => Date.parse("2026-08-08T12:10:00.000Z"),
    refreshRoom: () => Promise.resolve(expired),
    castVote: () => {
      casts += 1;
      return Promise.resolve(expired);
    },
  }));
  assert.equal(result, expired);
  assert.equal(casts, 0);
});

test("pending terminal with the exact vote replays recovery until finished", async () => {
  const pending = room({
    detective_vote_round_id: "",
    terminal_reconciliation_pending: true,
    vote_requests: [],
    detective_votes: [{
      voter_email: actor,
      voted_for_email: target,
    }],
  });
  const finished = room({
    status: "finished",
    winner: "spy",
    detective_vote_round_id: "",
  });
  const sleeps = [];
  let casts = 0;
  const result = await recoverDetectiveVoteCastConflict(input({
    refreshRoom: () => Promise.resolve(pending),
    castVote: ({ expectedVoteRoundID }) => {
      casts += 1;
      assert.equal(expectedVoteRoundID, "round-a");
      return Promise.resolve(finished);
    },
    sleep: async (milliseconds) => sleeps.push(milliseconds),
  }));
  assert.equal(result, finished);
  assert.equal(casts, 1);
  assert.deepEqual(sleeps, [250]);
});

test("active absent vote retries the same immutable cast with capped exhaustion", async () => {
  const conflict = retryable("cas_contention");
  const sleeps = [];
  const payloads = [];
  const scoped = input({
    maxAttempts: 99,
    sleep: async (milliseconds) => sleeps.push(milliseconds),
    castVote: async (payload) => {
      payloads.push(payload);
      throw conflict;
    },
  });

  await assert.rejects(
    recoverDetectiveVoteCastConflict(scoped),
    (error) => error === conflict,
  );
  assert.equal(payloads.length, DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS);
  assert.deepEqual(payloads, Array(DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS).fill({
    roomId: "room-1",
    targetEmail: target,
    expectedVoteRoundID: "round-a",
  }));
  assert.deepEqual(sleeps, [250, 500, 1_000, 2_000, 4_000, 8_000, 8_000, 8_000]);
});

test("nonretryable cast failure is never hidden", async () => {
  const failure = Object.assign(new Error("self vote"), {
    status: 400,
    code: "self_vote_not_allowed",
  });
  const scoped = input({
    castVote: async () => { throw failure; },
  });
  await assert.rejects(
    recoverDetectiveVoteCastConflict(scoped),
    (error) => error === failure,
  );
});

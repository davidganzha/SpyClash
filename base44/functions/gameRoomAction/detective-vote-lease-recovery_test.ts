import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { reconcileDetectiveVoteCastAfterActiveIdentityLease } from "./detective-vote-lease-recovery.ts";

function activeLease(): BillingIdentityLifecycleError {
  return new BillingIdentityLifecycleError(
    "active_lease",
    "Another participant owns the lifecycle lease.",
  );
}

function room(patch: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    match_id: "match-1",
    detective_vote_round_id: "round-a",
    status: "playing",
    winner: "",
    terminal_intent: null,
    players: [
      { email: "actor@example.com" },
      { email: "target@example.com" },
      { email: "other-1@example.com" },
      { email: "other-2@example.com" },
      { email: "other-3@example.com" },
      { email: "other-4@example.com" },
    ],
    spectators: [],
    eliminated_emails: [],
    vote_requests: [
      "actor@example.com",
      "target@example.com",
      "other-1@example.com",
      "other-2@example.com",
    ],
    detective_votes: [],
    ...patch,
  };
}

function recoveryInput(
  error: unknown,
  refetch: () => Promise<ReturnType<typeof room>>,
) {
  return {
    action: "cast_detective_vote",
    error,
    requestEnteredActiveVote: true,
    expectedMatchID: "match-1",
    expectedRoundID: "round-a",
    actorEmail: "actor@example.com",
    targetEmail: "target@example.com",
    refetch,
    assertParticipant: () => {},
    delay: () => Promise.resolve(),
  };
}

Deno.test("active-lease cast returns an atomically cancelled vote read-only", async () => {
  const leaseError = activeLease();
  const cancelled = room({
    detective_vote_round_id: "",
    vote_requests: [],
    detective_votes: [],
  });
  let reads = 0;
  const result = await reconcileDetectiveVoteCastAfterActiveIdentityLease(
    recoveryInput(leaseError, () => {
      reads += 1;
      return Promise.resolve(cancelled);
    }),
  );
  assertEquals(result, cancelled);
  assertEquals(reads, 1);
});

Deno.test("active-lease cast returns only its exact persisted actor-target vote", async () => {
  const leaseError = activeLease();
  const persisted = room({
    detective_votes: [{
      voter_email: "ACTOR@example.com",
      voted_for_email: "TARGET@example.com",
    }],
  });
  const result = await reconcileDetectiveVoteCastAfterActiveIdentityLease(
    recoveryInput(leaseError, () => Promise.resolve(persisted)),
  );
  assertEquals(result, persisted);

  let reads = 0;
  const wrongActorVote = room({
    detective_votes: [{
      voter_email: "other-1@example.com",
      voted_for_email: "target@example.com",
    }],
  });
  const rejected = await assertRejects(
    () =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease(
        recoveryInput(leaseError, () => {
          reads += 1;
          return Promise.resolve(wrongActorVote);
        }),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(rejected, leaseError);
  assertEquals(reads, 6);
});

Deno.test("active-lease cast accepts one-CAS innocent ejection without terminal intent", async () => {
  const leaseError = activeLease();
  const ejected = room({
    detective_vote_round_id: "",
    spectators: ["target@example.com"],
    eliminated_emails: ["target@example.com"],
    vote_requests: [],
    detective_votes: [],
  });
  const result = await reconcileDetectiveVoteCastAfterActiveIdentityLease(
    recoveryInput(leaseError, () => Promise.resolve(ejected)),
  );
  assertEquals(result, ejected);
});

Deno.test("pending terminal waits for the leased finisher and returns finished room", async () => {
  const leaseError = activeLease();
  const pending = room({
    detective_vote_round_id: "",
    terminal_intent: {
      match_id: "match-1",
      winner: "detectives",
      decided_at: "2026-08-08T12:00:00.000Z",
    },
    vote_requests: [],
    detective_votes: [],
  });
  const finished = room({
    detective_vote_round_id: "",
    status: "finished",
    winner: "detectives",
    terminal_intent: pending.terminal_intent,
    vote_requests: [],
    detective_votes: [],
  });
  const rooms = [pending, finished];
  const delays: number[] = [];
  let reads = 0;
  const result = await reconcileDetectiveVoteCastAfterActiveIdentityLease({
    ...recoveryInput(leaseError, () => Promise.resolve(rooms[reads++])),
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
  });
  assertEquals(result, finished);
  assertEquals(reads, 2);
  assertEquals(delays, [25]);
});

Deno.test("pending terminal that never finishes preserves the active-lease retry", async () => {
  const leaseError = activeLease();
  const pending = room({
    detective_vote_round_id: "",
    terminal_intent: {
      match_id: "match-1",
      winner: "spy",
      decided_at: "2026-08-08T12:00:00.000Z",
    },
    vote_requests: [],
    detective_votes: [],
  });
  const delays: number[] = [];
  let reads = 0;
  const rejected = await assertRejects(
    () =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease({
        ...recoveryInput(leaseError, () => {
          reads += 1;
          return Promise.resolve(pending);
        }),
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(rejected, leaseError);
  assertEquals(reads, 6);
  assertEquals(delays, [25, 50, 100, 200, 400]);
});

Deno.test("wrong match and missing participant fail closed", async () => {
  const leaseError = activeLease();
  let participantChecks = 0;
  const wrongMatch = await assertRejects(
    () =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease({
        ...recoveryInput(
          leaseError,
          () => Promise.resolve(room({ match_id: "match-2" })),
        ),
        assertParticipant: () => {
          participantChecks += 1;
        },
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(wrongMatch, leaseError);
  assertEquals(participantChecks, 0);

  const membershipError = Object.assign(new Error("Not a room participant"), {
    status: 403,
  });
  const missingParticipant = await assertRejects(
    () =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease({
        ...recoveryInput(
          leaseError,
          () => Promise.resolve(room({ vote_requests: [] })),
        ),
        assertParticipant: () => {
          throw membershipError;
        },
      }),
    Error,
    "Not a room participant",
  );
  assertEquals(missingParticipant, membershipError);
});

Deno.test("reopened ballot round never acknowledges an identical actor-target vote", async () => {
  const leaseError = activeLease();
  let reads = 0;
  const reopened = room({
    detective_vote_round_id: "round-b",
    detective_votes: [{
      voter_email: "actor@example.com",
      voted_for_email: "target@example.com",
    }],
  });
  const rejected = await assertRejects(
    () =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease(
        recoveryInput(leaseError, () => {
          reads += 1;
          return Promise.resolve(reopened);
        }),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(rejected, leaseError);
  assertEquals(reads, 1);
});

Deno.test("later, stale, and non-active-lease casts never enter reconciliation", async () => {
  const leaseError = activeLease();
  const cases = [
    {
      error: leaseError,
      action: "request_vote",
      requestEnteredActiveVote: true,
    },
    {
      error: leaseError,
      action: "cast_detective_vote",
      requestEnteredActiveVote: false,
    },
    {
      error: new BillingIdentityLifecycleError(
        "cas_contention",
        "CAS contention",
      ),
      action: "cast_detective_vote",
      requestEnteredActiveVote: true,
    },
    {
      error: Object.assign(new Error("untyped"), { code: "active_lease" }),
      action: "cast_detective_vote",
      requestEnteredActiveVote: true,
    },
  ];

  for (const blocked of cases) {
    let reads = 0;
    const rejected = await assertRejects(() =>
      reconcileDetectiveVoteCastAfterActiveIdentityLease({
        ...recoveryInput(blocked.error, () => {
          reads += 1;
          return Promise.resolve(room({ vote_requests: [] }));
        }),
        action: blocked.action,
        requestEnteredActiveVote: blocked.requestEnteredActiveVote,
      })
    );
    assertEquals(rejected, blocked.error);
    assertEquals(reads, 0);
  }
});

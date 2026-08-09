import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  appendImmutableDetectiveVote,
  assertDetectiveVoteRoundIdentity,
  bindDetectiveVoteRoundIdentity,
  canonicalDetectiveVotes,
  detectiveVoteCastTransition,
  detectiveVoteLeavePatch,
  detectiveVoteRequestThreshold,
  detectiveVoteRequestTransition,
  detectiveVoteRoundDecision,
  isDetectiveVotingActive,
  resolvedDetectiveVoteCastTransition,
} from "./detective-vote-policy.ts";

const active = ["p1", "p2", "p3", "p4", "p5", "p6"];
const openRequests = ["p1", "p2", "p3", "p4"];

function vote(voter: string, target: string) {
  return { voter_email: voter, voted_for_email: target };
}

function errorCode(error: Error): string | undefined {
  return (error as Error & { code?: string }).code;
}

Deno.test("vote opening remains majority-based and counts distinct active requests", () => {
  assertEquals(detectiveVoteRequestThreshold(6), 4);
  assertEquals(detectiveVoteRequestThreshold(5), 3);
  assertEquals(detectiveVoteRequestThreshold(0), 0);
  assertEquals(
    isDetectiveVotingActive(active, ["p1", "P2", "p2", "p3"]),
    false,
  );
  assertEquals(
    isDetectiveVotingActive(active, ["p1", "P2", "p3", "p4", "gone"]),
    true,
  );
});

Deno.test("opening transition creates one server round identity at the threshold", () => {
  let ids = 0;
  const beforeThreshold = detectiveVoteRequestTransition(
    active,
    ["p1", "p2"],
    "p3",
    "",
    () => `round-${++ids}`,
  );
  assertEquals(beforeThreshold.patch, {
    vote_requests: ["p1", "p2", "p3"],
  });
  assertEquals(ids, 0);

  const opens = detectiveVoteRequestTransition(
    active,
    ["p1", "p2", "p3"],
    "p4",
    "",
    () => `round-${++ids}`,
  );
  assertEquals(opens.patch, {
    vote_requests: ["p1", "p2", "p3", "p4"],
    detective_vote_round_id: "round-1",
  });

  const activeReplay = detectiveVoteRequestTransition(
    active,
    openRequests,
    "p4",
    "round-1",
    () => `round-${++ids}`,
  );
  assertEquals(activeReplay.patch, {});
  assertEquals(ids, 1);
});

Deno.test("legacy active ballot is lazily bound once and a concurrent initializer fails closed", () => {
  assertEquals(
    bindDetectiveVoteRoundIdentity("", "", "round-a", true),
    { roundID: "round-a", initialize: true },
  );
  assertEquals(
    bindDetectiveVoteRoundIdentity("round-a", "", "round-a", true),
    { roundID: "round-a", initialize: false },
  );
  const raced = assertThrows(
    () => bindDetectiveVoteRoundIdentity("round-b", "", "round-a", true),
    Error,
    "round changed",
  );
  assertEquals(errorCode(raced), "detective_vote_round_changed");
});

Deno.test("explicit Round A cast cannot enter reopened Round B", () => {
  assertEquals(
    assertDetectiveVoteRoundIdentity("round-a", "round-a", "round-a"),
    "round-a",
  );
  const changed = assertThrows(
    () => assertDetectiveVoteRoundIdentity("round-b", "round-a", "round-b"),
    Error,
    "round changed",
  );
  assertEquals(errorCode(changed), "detective_vote_round_changed");
});

Deno.test("any active-player leave clears ballot state before thresholds can change", () => {
  const activeBallot = detectiveVoteLeavePatch(
    active,
    openRequests,
    [vote("p2", "p1"), vote("p3", "p1")],
    "p6",
    "round-a",
  );
  assertEquals(activeBallot, {
    vote_requests: [],
    detective_votes: [],
    detective_vote_round_id: "",
  });

  // Six players need four requests. If an unrequested player left while three
  // requests were retained, five remaining players would suddenly satisfy the
  // threshold with no round identity. The entire pre-threshold state is reset.
  const thresholdCrossing = detectiveVoteLeavePatch(
    active,
    ["p1", "p2", "p3"],
    [],
    "p6",
    "",
  );
  assertEquals(thresholdCrossing, {
    vote_requests: [],
    detective_votes: [],
    detective_vote_round_id: "",
  });

  const spectatorLeave = detectiveVoteLeavePatch(
    active,
    ["p1", "p2"],
    [],
    "spectator",
    "",
  );
  assertEquals(spectatorLeave.vote_requests, ["p1", "p2"]);
});

Deno.test("six-player 5-1 vote ejects the spy target", () => {
  const decision = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p1"),
    vote("p4", "p1"),
    vote("p5", "p1"),
    vote("p6", "p1"),
    vote("p1", "p2"),
  ]);
  assertEquals(decision.outcome, "eject");
  assertEquals(decision.threshold, 5);
  if (decision.outcome === "eject") {
    assertEquals(decision.ejected_email, "p1");
  }
});

Deno.test("six-player 4-2 vote cancels without ejecting the plurality", () => {
  const decision = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p1"),
    vote("p4", "p1"),
    vote("p5", "p1"),
    vote("p1", "p2"),
    vote("p6", "p2"),
  ]);
  assertEquals(decision.outcome, "cancel");
  assertEquals(decision.threshold, 5);
});

Deno.test("six-player 3-2 vote cancels with one voter remaining", () => {
  const decision = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p1"),
    vote("p4", "p1"),
    vote("p1", "p2"),
    vote("p5", "p2"),
  ]);
  assertEquals(decision.outcome, "cancel");
  assertEquals(decision.viable_candidate_emails, []);
});

Deno.test("four votes remain viable only when an eligible fifth voter remains", () => {
  const candidateAlreadyVoted = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p1"),
    vote("p4", "p1"),
    vote("p5", "p1"),
    vote("p1", "p2"),
  ]);
  assertEquals(candidateAlreadyVoted.outcome, "continue");
  assertEquals(candidateAlreadyVoted.viable_candidate_emails, ["p1"]);

  const candidateIsOnlyRemainingVoter = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p1"),
    vote("p4", "p1"),
    vote("p5", "p1"),
    vote("p6", "p2"),
  ]);
  assertEquals(candidateIsOnlyRemainingVoter.outcome, "cancel");
});

Deno.test("cross-votes preserve only candidates whose own dissent is allowed", () => {
  const possible = detectiveVoteRoundDecision(active, [
    vote("p1", "p2"),
    vote("p2", "p1"),
  ]);
  assertEquals(possible.outcome, "continue");
  assertEquals(possible.viable_candidate_emails, ["p1", "p2"]);

  const impossible = detectiveVoteRoundDecision(active, [
    vote("p2", "p1"),
    vote("p3", "p4"),
  ]);
  assertEquals(impossible.outcome, "cancel");
});

Deno.test("first cast is immutable while an exact replay is idempotent", () => {
  const first = appendImmutableDetectiveVote(active, [], "p2", "p1");
  assertEquals(first.added, true);
  assertEquals(first.votes, [vote("p2", "p1")]);

  const replay = appendImmutableDetectiveVote(
    active,
    first.votes,
    "P2",
    "P1",
  );
  assertEquals(replay.added, false);
  assertEquals(replay.votes, first.votes);

  const changed = assertThrows(
    () => appendImmutableDetectiveVote(active, first.votes, "p2", "p3"),
    Error,
    "already locked",
  );
  assertEquals(errorCode(changed), "detective_vote_already_cast");
});

Deno.test("self-votes and inactive voters or targets are rejected", () => {
  const selfVote = assertThrows(
    () => appendImmutableDetectiveVote(active, [], "P1", "p1"),
    Error,
    "yourself",
  );
  assertEquals(errorCode(selfVote), "self_vote_not_allowed");

  const inactiveVoter = assertThrows(
    () => appendImmutableDetectiveVote(active, [], "gone", "p1"),
    Error,
    "Spectators",
  );
  assertEquals(errorCode(inactiveVoter), "detective_voter_inactive");

  const inactiveTarget = assertThrows(
    () => appendImmutableDetectiveVote(active, [], "p1", "gone"),
    Error,
    "no longer active",
  );
  assertEquals(errorCode(inactiveTarget), "detective_vote_target_inactive");
});

Deno.test("canonical votes discard self, inactive, and duplicate legacy rows", () => {
  assertEquals(
    canonicalDetectiveVotes(active, [
      vote("p1", "p1"),
      vote("gone", "p1"),
      vote("p2", "gone"),
      vote("p3", "p1"),
      vote("P3", "P2"),
    ]),
    [vote("p3", "p2")],
  );
});

Deno.test("cast transition clears both arrays atomically when N-S becomes impossible", () => {
  const transition = detectiveVoteCastTransition(
    active,
    openRequests,
    [
      vote("p2", "p1"),
      vote("p3", "p1"),
      vote("p4", "p1"),
      vote("p1", "p2"),
    ],
    "p5",
    "p2",
  );
  assertEquals(transition.decision.outcome, "cancel");
  assertEquals(transition.patch, {
    detective_votes: [],
    vote_requests: [],
    detective_vote_round_id: "",
  });
});

Deno.test("persisted N-S decision survives a post-CAS failure and retries", () => {
  const transition = detectiveVoteCastTransition(
    active,
    openRequests,
    [
      vote("p2", "p1"),
      vote("p3", "p1"),
      vote("p4", "p1"),
      vote("p5", "p1"),
    ],
    "p6",
    "p1",
  );
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.patch.vote_requests, undefined);
  assertEquals(transition.patch.detective_votes?.length, 5);

  // Simulate a process failure after the vote CAS but before finishRoom/the
  // innocent ejection patch. A retry observes the same immutable decision and
  // performs no new write before reconciling that decision.
  const retry = detectiveVoteCastTransition(
    active,
    openRequests,
    transition.patch.detective_votes ?? [],
    "p6",
    "p1",
  );
  assertEquals(retry.decision.outcome, "eject");
  assertEquals(retry.added, false);
  assertEquals(retry.patch, {});

  const lateCast = detectiveVoteCastTransition(
    active,
    openRequests,
    transition.patch.detective_votes ?? [],
    "p1",
    "p2",
  );
  assertEquals(lateCast.decision.outcome, "eject");
  assertEquals(lateCast.added, false);
  assertEquals(lateCast.patch, {});
});

Deno.test("cast transition rejects a stale request after cancellation", () => {
  const inactive = assertThrows(
    () => detectiveVoteCastTransition(active, [], [], "p6", "p1"),
    Error,
    "no longer active",
  );
  assertEquals(errorCode(inactive), "detective_vote_inactive");
});

Deno.test("cast transition returns no write for an exact active replay", () => {
  const transition = detectiveVoteCastTransition(
    active,
    openRequests,
    [vote("p2", "p1")],
    "p2",
    "p1",
  );
  assertEquals(transition.added, false);
  assertEquals(transition.patch, {});
});

Deno.test("spy ejection atomically closes voting with detectives terminal source", () => {
  const transition = resolvedDetectiveVoteCastTransition(
    ["spy", "d1", "d2"],
    ["spy", "d1"],
    [vote("d1", "spy")],
    "d2",
    "spy",
    "spy",
    [],
    [],
  );
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.terminal_winner, "detectives");
  assertEquals(transition.patch.vote_requests, []);
  assertEquals(transition.patch.detective_vote_round_id, "");
  assertEquals(transition.patch.detective_votes, [
    vote("d1", "spy"),
    vote("d2", "spy"),
  ]);
  assertEquals(transition.terminal_patch, {
    detective_votes: [vote("d1", "spy"), vote("d2", "spy")],
  });
});

Deno.test("three-player innocent ejection atomically carries spy terminal source", () => {
  const transition = resolvedDetectiveVoteCastTransition(
    ["spy", "d1", "d2"],
    ["spy", "d1"],
    [vote("spy", "d1")],
    "d2",
    "d1",
    "spy",
    ["old"],
    ["older"],
  );
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.terminal_winner, "spy");
  assertEquals(transition.patch, {
    detective_votes: [],
    vote_requests: [],
    spectators: ["old", "d1"],
    eliminated_emails: ["older", "d1"],
    detective_vote_round_id: "",
  });
});

Deno.test("innocent ejection with two detectives remaining is one atomic nonterminal patch", () => {
  const transition = resolvedDetectiveVoteCastTransition(
    ["spy", "d1", "d2", "d3"],
    ["spy", "d1", "d2"],
    [vote("spy", "d1"), vote("d2", "d1")],
    "d3",
    "d1",
    "spy",
    [],
    [],
  );
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.terminal_winner, null);
  assertEquals(transition.patch, {
    detective_votes: [],
    vote_requests: [],
    spectators: ["d1"],
    eliminated_emails: ["d1"],
    detective_vote_round_id: "",
  });
});

Deno.test("six-player two-spy accusation needs four votes and first spy ejection continues", () => {
  const active = ["s1", "s2", "d1", "d2", "d3", "d4"];
  const spies = ["s1", "s2"];
  const threeVotes = detectiveVoteRoundDecision(active, [
    vote("d1", "s1"),
    vote("d2", "s1"),
    vote("d3", "s1"),
  ], spies);
  assertEquals(threeVotes.outcome, "continue");
  assertEquals(threeVotes.threshold, 4);

  const transition = resolvedDetectiveVoteCastTransition(
    active,
    ["d1", "d2", "d3", "d4"],
    threeVotes.votes,
    "d4",
    "s1",
    spies,
    [],
    [],
  );
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.decision.threshold, 4);
  assertEquals(transition.terminal_winner, null);
  assertEquals(transition.patch.spectators, ["s1"]);
  assertEquals(transition.patch.eliminated_emails, ["s1"]);
});

Deno.test("last active spy ejection ends for detectives and nine/three needs six votes", () => {
  const active = ["s3", "d1", "d2", "d3", "d4", "d5", "d6"];
  const spies = ["s1", "s2", "s3"];
  const existing = [
    vote("d1", "s3"),
    vote("d2", "s3"),
    vote("d3", "s3"),
    vote("d4", "s3"),
    vote("d5", "s3"),
  ];
  const transition = resolvedDetectiveVoteCastTransition(
    active,
    ["d1", "d2", "d3", "d4"],
    existing,
    "d6",
    "s3",
    spies,
    ["s1", "s2"],
    ["s1", "s2"],
  );
  assertEquals(transition.decision.threshold, 6);
  assertEquals(transition.decision.outcome, "eject");
  assertEquals(transition.terminal_winner, "detectives");
  assertEquals(transition.patch.spectators, ["s1", "s2", "s3"]);
});

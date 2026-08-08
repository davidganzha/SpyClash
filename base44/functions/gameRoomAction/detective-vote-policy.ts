type VoteRecord = Record<string, unknown>;

export type CanonicalDetectiveVote = {
  voter_email: string;
  voted_for_email: string;
};

export type DetectiveVoteRoundDecision =
  | {
    outcome: "continue";
    threshold: number;
    votes: CanonicalDetectiveVote[];
    viable_candidate_emails: string[];
  }
  | {
    outcome: "cancel";
    threshold: number;
    votes: CanonicalDetectiveVote[];
    viable_candidate_emails: [];
  }
  | {
    outcome: "eject";
    threshold: number;
    votes: CanonicalDetectiveVote[];
    viable_candidate_emails: string[];
    ejected_email: string;
  };

export type DetectiveVoteCastTransition = {
  decision: DetectiveVoteRoundDecision;
  added: boolean;
  patch: {
    detective_votes?: CanonicalDetectiveVote[];
    vote_requests?: string[];
    detective_vote_round_id?: string;
  };
};

export type ResolvedDetectiveVoteCastTransition = {
  decision: DetectiveVoteRoundDecision;
  added: boolean;
  patch: {
    detective_votes?: CanonicalDetectiveVote[];
    vote_requests?: string[];
    spectators?: string[];
    eliminated_emails?: string[];
    detective_vote_round_id?: string;
  };
  terminal_winner: "spy" | "detectives" | null;
  terminal_patch: {
    detective_votes?: CanonicalDetectiveVote[];
  };
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizedEmail(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function voteError(message: string, status: number, code: string): Error {
  return Object.assign(new Error(message), { status, code });
}

function canonicalActiveEmailMap(
  activeEmailValues: readonly unknown[],
): Map<string, string> {
  const canonical = new Map<string, string>();
  for (const value of activeEmailValues) {
    const email = clean(value);
    const key = normalizedEmail(email);
    if (key && !canonical.has(key)) canonical.set(key, email);
  }
  return canonical;
}

function uniqueCanonicalStrings(values: readonly unknown[]): string[] {
  const canonical = new Map<string, string>();
  for (const value of values) {
    const item = clean(value);
    const key = normalizedEmail(item);
    if (key && !canonical.has(key)) canonical.set(key, item);
  }
  return [...canonical.values()];
}

export function detectiveVoteRequestThreshold(
  activeCountValue: unknown,
): number {
  const activeCount = Number(activeCountValue);
  if (!Number.isSafeInteger(activeCount) || activeCount <= 0) return 0;
  // Opening a vote remains a simple majority decision. The stricter N-1 rule
  // below applies only to the final accusation/ejection itself.
  return Math.ceil(activeCount * 0.51);
}

export function isDetectiveVotingActive(
  activeEmailValues: readonly unknown[],
  voteRequestValues: readonly unknown[],
): boolean {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const requests = new Set(
    voteRequestValues.map(normalizedEmail).filter((email) => active.has(email)),
  );
  const threshold = detectiveVoteRequestThreshold(active.size);
  return threshold > 0 && requests.size >= threshold;
}

export function assertDetectiveVoteRoundIdentity(
  currentRoundIDValue: unknown,
  explicitExpectedRoundIDValue: unknown,
  serverCapturedRoundIDValue: unknown,
): string {
  const currentRoundID = clean(currentRoundIDValue);
  const explicitExpectedRoundID = clean(explicitExpectedRoundIDValue);
  const serverCapturedRoundID = clean(serverCapturedRoundIDValue);
  const expectedRoundID = explicitExpectedRoundID || serverCapturedRoundID;
  if (
    !currentRoundID || !expectedRoundID || currentRoundID !== expectedRoundID
  ) {
    throw voteError(
      "Detective voting round changed; refresh the room",
      409,
      "detective_vote_round_changed",
    );
  }
  return currentRoundID;
}

export function bindDetectiveVoteRoundIdentity(
  currentRoundIDValue: unknown,
  explicitExpectedRoundIDValue: unknown,
  serverCapturedRoundIDValue: unknown,
  votingActive: boolean,
): { roundID: string; initialize: boolean } {
  const currentRoundID = clean(currentRoundIDValue);
  if (currentRoundID) {
    return {
      roundID: assertDetectiveVoteRoundIdentity(
        currentRoundID,
        explicitExpectedRoundIDValue,
        serverCapturedRoundIDValue,
      ),
      initialize: false,
    };
  }

  const explicitExpectedRoundID = clean(explicitExpectedRoundIDValue);
  const serverCapturedRoundID = clean(serverCapturedRoundIDValue);
  if (explicitExpectedRoundID || !serverCapturedRoundID || !votingActive) {
    throw voteError(
      "Detective voting round changed; refresh the room",
      409,
      "detective_vote_round_changed",
    );
  }
  return { roundID: serverCapturedRoundID, initialize: true };
}

export function detectiveVoteRequestTransition(
  activeEmailValues: readonly unknown[],
  voteRequestValues: readonly unknown[],
  requesterEmailValue: unknown,
  currentRoundIDValue: unknown,
  createRoundID: () => string,
): { patch: { vote_requests?: string[]; detective_vote_round_id?: string } } {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const requesterKey = normalizedEmail(requesterEmailValue);
  const requesterEmail = active.get(requesterKey);
  if (!requesterEmail) {
    throw voteError(
      "Spectators cannot request a vote",
      403,
      "detective_voter_inactive",
    );
  }

  const currentRequests = uniqueCanonicalStrings(voteRequestValues).filter((
    email,
  ) => active.has(normalizedEmail(email)));
  const alreadyRequested = currentRequests.some((email) =>
    normalizedEmail(email) === requesterKey
  );
  const nextRequests = alreadyRequested
    ? currentRequests
    : [...currentRequests, requesterEmail];
  const nextActive = isDetectiveVotingActive(
    [...active.values()],
    nextRequests,
  );
  const currentRoundID = clean(currentRoundIDValue);
  const patch: {
    vote_requests?: string[];
    detective_vote_round_id?: string;
  } = {};
  if (!alreadyRequested) patch.vote_requests = nextRequests;
  if (nextActive && !currentRoundID) {
    const createdRoundID = clean(createRoundID());
    if (!createdRoundID) {
      throw voteError(
        "Detective voting round identity could not be created",
        503,
        "detective_vote_round_unavailable",
      );
    }
    patch.detective_vote_round_id = createdRoundID;
  } else if (!nextActive && currentRoundID) {
    patch.detective_vote_round_id = "";
  }
  return { patch };
}

export function detectiveVoteLeavePatch(
  activeEmailValues: readonly unknown[],
  voteRequestValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
  leavingEmailValue: unknown,
  currentRoundIDValue: unknown,
): {
  vote_requests: string[];
  detective_votes: CanonicalDetectiveVote[];
  detective_vote_round_id: string;
} {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const leavingKey = normalizedEmail(leavingEmailValue);
  const leavingWasActive = active.has(leavingKey);
  const persistedVotes = canonicalDetectiveVotes(
    [...active.values()],
    rawVotes,
  );
  if (
    leavingWasActive && (
      voteRequestValues.length > 0 ||
      persistedVotes.length > 0 ||
      Boolean(clean(currentRoundIDValue))
    )
  ) {
    return {
      vote_requests: [],
      detective_votes: [],
      detective_vote_round_id: "",
    };
  }

  return {
    vote_requests: uniqueCanonicalStrings(voteRequestValues).filter((email) =>
      normalizedEmail(email) !== leavingKey
    ),
    detective_votes: canonicalDetectiveVotes(
      [...active.values()],
      persistedVotes,
    ).filter((vote) =>
      normalizedEmail(vote.voter_email) !== leavingKey &&
      normalizedEmail(vote.voted_for_email) !== leavingKey
    ),
    detective_vote_round_id: clean(currentRoundIDValue),
  };
}

/**
 * Canonicalizes the persisted table and fails closed on invalid legacy rows.
 * A voter contributes at most one vote, their latest valid persisted row wins,
 * and self-votes never count toward either ejection or mathematical viability.
 */
export function canonicalDetectiveVotes(
  activeEmailValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
): CanonicalDetectiveVote[] {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const byVoter = new Map<string, CanonicalDetectiveVote>();

  for (const rawVote of rawVotes) {
    const voterKey = normalizedEmail(rawVote?.voter_email);
    const targetKey = normalizedEmail(rawVote?.voted_for_email);
    const voterEmail = active.get(voterKey);
    const targetEmail = active.get(targetKey);
    if (!voterEmail || !targetEmail || voterKey === targetKey) continue;
    byVoter.set(voterKey, {
      voter_email: voterEmail,
      voted_for_email: targetEmail,
    });
  }

  return [...active.keys()].flatMap((voterKey) => {
    const vote = byVoter.get(voterKey);
    return vote ? [vote] : [];
  });
}

export function appendImmutableDetectiveVote(
  activeEmailValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
  voterEmailValue: unknown,
  targetEmailValue: unknown,
): { votes: CanonicalDetectiveVote[]; added: boolean } {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const voterKey = normalizedEmail(voterEmailValue);
  const targetKey = normalizedEmail(targetEmailValue);
  const voterEmail = active.get(voterKey);
  const targetEmail = active.get(targetKey);

  if (!voterEmail) {
    throw voteError("Spectators cannot vote", 403, "detective_voter_inactive");
  }
  if (!targetEmail) {
    throw voteError(
      "Target is no longer active",
      400,
      "detective_vote_target_inactive",
    );
  }
  if (voterKey === targetKey) {
    throw voteError(
      "You cannot vote for yourself",
      400,
      "self_vote_not_allowed",
    );
  }

  const votes = canonicalDetectiveVotes(activeEmailValues, rawVotes);
  const existing = votes.find((vote) =>
    normalizedEmail(vote.voter_email) === voterKey
  );
  if (existing) {
    if (normalizedEmail(existing.voted_for_email) === targetKey) {
      return { votes, added: false };
    }
    throw voteError(
      "Your vote is already locked for this voting round",
      409,
      "detective_vote_already_cast",
    );
  }

  return {
    votes: [...votes, {
      voter_email: voterEmail,
      voted_for_email: targetEmail,
    }],
    added: true,
  };
}

/**
 * An accusation succeeds only with N-1 votes from the current active table.
 * Uncast votes are treated as immutable future choices, and a remaining voter
 * cannot be counted as a possible vote for themselves. Once no candidate can
 * mathematically reach N-1, the round is cancelled immediately.
 */
export function detectiveVoteRoundDecision(
  activeEmailValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
): DetectiveVoteRoundDecision {
  const active = canonicalActiveEmailMap(activeEmailValues);
  const activeEmails = [...active.values()];
  const votes = canonicalDetectiveVotes(activeEmails, rawVotes);
  const threshold = activeEmails.length > 1 ? activeEmails.length - 1 : 1;
  const countByCandidate = new Map<string, number>();
  for (const vote of votes) {
    const candidateKey = normalizedEmail(vote.voted_for_email);
    countByCandidate.set(
      candidateKey,
      (countByCandidate.get(candidateKey) ?? 0) + 1,
    );
  }

  const ejectedEmail = activeEmails.find((email) =>
    (countByCandidate.get(normalizedEmail(email)) ?? 0) >= threshold
  );
  if (ejectedEmail) {
    return {
      outcome: "eject",
      threshold,
      votes,
      viable_candidate_emails: [ejectedEmail],
      ejected_email: ejectedEmail,
    };
  }

  const voted = new Set(votes.map((vote) => normalizedEmail(vote.voter_email)));
  const unvoted = activeEmails.filter((email) =>
    !voted.has(normalizedEmail(email))
  );
  const viableCandidateEmails = activeEmails.filter((candidateEmail) => {
    const candidateKey = normalizedEmail(candidateEmail);
    const currentVotes = countByCandidate.get(candidateKey) ?? 0;
    const eligibleRemainingVotes = unvoted.filter((voterEmail) =>
      normalizedEmail(voterEmail) !== candidateKey
    ).length;
    return currentVotes + eligibleRemainingVotes >= threshold;
  });

  if (!viableCandidateEmails.length) {
    return {
      outcome: "cancel",
      threshold,
      votes,
      viable_candidate_emails: [],
    };
  }

  return {
    outcome: "continue",
    threshold,
    votes,
    viable_candidate_emails: viableCandidateEmails,
  };
}

/**
 * Builds the single CAS patch for a cast from one latest room snapshot.
 * Cancellation clears both arrays atomically. A successful N-1 accusation
 * keeps its request gate and immutable vote table until the existing
 * retry-safe terminal/ejection transition clears them. That persisted decision
 * can therefore be reconciled after a process failure following this CAS.
 */
export function detectiveVoteCastTransition(
  activeEmailValues: readonly unknown[],
  voteRequestValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
  voterEmailValue: unknown,
  targetEmailValue: unknown,
): DetectiveVoteCastTransition {
  if (!isDetectiveVotingActive(activeEmailValues, voteRequestValues)) {
    throw voteError(
      "Detective voting is no longer active",
      409,
      "detective_vote_inactive",
    );
  }

  const persistedDecision = detectiveVoteRoundDecision(
    activeEmailValues,
    rawVotes,
  );
  if (persistedDecision.outcome === "eject") {
    return {
      decision: persistedDecision,
      added: false,
      patch: {},
    };
  }

  const appended = appendImmutableDetectiveVote(
    activeEmailValues,
    rawVotes,
    voterEmailValue,
    targetEmailValue,
  );
  const decision = detectiveVoteRoundDecision(
    activeEmailValues,
    appended.votes,
  );
  if (!appended.added) return { decision, added: false, patch: {} };
  if (decision.outcome === "cancel") {
    return {
      decision,
      added: true,
      patch: {
        detective_votes: [],
        vote_requests: [],
        detective_vote_round_id: "",
      },
    };
  }
  if (decision.outcome === "eject") {
    return {
      decision,
      added: true,
      patch: { detective_votes: decision.votes },
    };
  }
  return {
    decision,
    added: true,
    patch: { detective_votes: decision.votes },
  };
}

/**
 * Converts an N-1 vote into one durable room CAS. A spy accusation carries a
 * detectives terminal source. An innocent accusation atomically moves that
 * player to the eliminated spectator set; if only one detective then remains,
 * the same patch also carries a spy terminal source.
 */
export function resolvedDetectiveVoteCastTransition(
  activeEmailValues: readonly unknown[],
  voteRequestValues: readonly unknown[],
  rawVotes: readonly VoteRecord[],
  voterEmailValue: unknown,
  targetEmailValue: unknown,
  spyEmailValue: unknown,
  spectatorEmailValues: readonly unknown[],
  eliminatedEmailValues: readonly unknown[],
): ResolvedDetectiveVoteCastTransition {
  const transition = detectiveVoteCastTransition(
    activeEmailValues,
    voteRequestValues,
    rawVotes,
    voterEmailValue,
    targetEmailValue,
  );
  if (transition.decision.outcome !== "eject") {
    return {
      ...transition,
      terminal_winner: null,
      terminal_patch: {},
    };
  }

  const accused = transition.decision.ejected_email;
  const accusedKey = normalizedEmail(accused);
  const spyKey = normalizedEmail(spyEmailValue);
  if (spyKey && accusedKey === spyKey) {
    return {
      ...transition,
      patch: {
        detective_votes: transition.decision.votes,
        vote_requests: [],
        detective_vote_round_id: "",
      },
      terminal_winner: "detectives",
      terminal_patch: { detective_votes: transition.decision.votes },
    };
  }

  const spectators = uniqueCanonicalStrings([
    ...spectatorEmailValues,
    accused,
  ]);
  const eliminated = uniqueCanonicalStrings([
    ...eliminatedEmailValues,
    accused,
  ]);
  const remainingActive = canonicalActiveEmailMap(activeEmailValues);
  remainingActive.delete(accusedKey);
  const spyRemainsActive = Boolean(spyKey && remainingActive.has(spyKey));
  const detectiveCount =
    [...remainingActive.keys()].filter((email) => email !== spyKey).length;

  return {
    ...transition,
    patch: {
      detective_votes: [],
      vote_requests: [],
      spectators,
      eliminated_emails: eliminated,
      detective_vote_round_id: "",
    },
    terminal_winner: spyRemainsActive && detectiveCount <= 1 ? "spy" : null,
    terminal_patch: {},
  };
}

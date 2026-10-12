type Room = Record<string, any>;

export type ReplayEligibility = {
  players: Record<string, any>[];
  emails: string[];
  userIDs: string[];
  removedUserIDs: string[];
};

export type ReplayVoteTransition = {
  patch: Room;
  votes: string[];
  eligibleEmails: string[];
  unanimous: boolean;
};

export type ReplayVoteState = {
  votes: string[];
  eligibleEmails: string[];
  unanimous: boolean;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizedEmail(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function policyError(message: string, status: number, code: string): Error {
  return Object.assign(new Error(message), { status, code });
}

function roomPlayers(room: Room): Record<string, any>[] {
  return Array.isArray(room?.players)
    ? room.players.filter((player) =>
      player && typeof player === "object" && !Array.isArray(player)
    )
    : [];
}

/**
 * Returns the one authoritative replay roster without disclosing the private
 * departure tombstones used to derive it. Stable user ids win over duplicate
 * email aliases; legacy players without an id remain keyed by email.
 */
export function replayEligibility(room: Room): ReplayEligibility {
  const departed = new Set(
    (Array.isArray(room?.departed_player_emails)
      ? room.departed_player_emails
      : []).map(normalizedEmail).filter(Boolean),
  );
  const seenUserIDs = new Set<string>();
  const seenEmails = new Set<string>();
  const players: Record<string, any>[] = [];
  const removedUserIDs = new Set<string>();

  for (const player of roomPlayers(room)) {
    const userID = clean(player?.user_id);
    const email = clean(player?.email);
    const emailKey = normalizedEmail(email);
    if (!emailKey) continue;
    if (departed.has(emailKey)) {
      if (userID) removedUserIDs.add(userID);
      continue;
    }
    if (
      seenEmails.has(emailKey) ||
      (userID && seenUserIDs.has(userID))
    ) {
      continue;
    }
    seenEmails.add(emailKey);
    if (userID) seenUserIDs.add(userID);
    players.push({
      ...player,
      email,
      ...(userID ? { user_id: userID } : {}),
    });
  }

  return {
    players,
    emails: players.map((player) => clean(player.email)),
    userIDs: players.map((player) => clean(player.user_id)).filter(Boolean),
    removedUserIDs: [...removedUserIDs],
  };
}

export function replayEligiblePlayerEmails(room: Room): string[] {
  return replayEligibility(room).emails;
}

function canonicalVotes(room: Room, eligibility: ReplayEligibility): string[] {
  const eligible = new Map(
    eligibility.players.map((player) => [
      normalizedEmail(player.email),
      clean(player.email),
    ]),
  );
  const votes = Array.isArray(room?.ready_players) ? room.ready_players : [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (const vote of votes) {
    const key = normalizedEmail(vote);
    const email = eligible.get(key);
    if (!email || seen.has(key)) continue;
    seen.add(key);
    result.push(email);
  }
  return result;
}

export function replayVoteState(room: Room): ReplayVoteState {
  if (clean(room?.status || "waiting").toLocaleLowerCase() !== "finished") {
    throw policyError(
      "Replay voting is not active",
      409,
      "replay_vote_inactive",
    );
  }
  const eligibility = replayEligibility(room);
  const votes = canonicalVotes(room, eligibility);
  const voteKeys = new Set(votes.map(normalizedEmail));
  return {
    votes,
    eligibleEmails: eligibility.emails,
    unanimous: eligibility.emails.length > 0 &&
      eligibility.emails.every((email) => voteKeys.has(normalizedEmail(email))),
  };
}

function sameStrings(left: readonly unknown[], right: readonly string[]) {
  return left.length === right.length &&
    left.every((value, index) => clean(value) === right[index]);
}

export function replayVoteTransition(
  room: Room,
  actorEmailValue: unknown,
): ReplayVoteTransition {
  const eligibility = replayEligibility(room);
  const currentState = replayVoteState(room);
  const actorKey = normalizedEmail(actorEmailValue);
  const actor = eligibility.players.find((player) =>
    normalizedEmail(player.email) === actorKey
  );
  if (!actor) {
    throw policyError(
      "This operative cannot vote in this replay",
      403,
      "room_access_revoked",
    );
  }

  const currentVotes = currentState.votes;
  const alreadyVoted = currentVotes.some((email) =>
    normalizedEmail(email) === actorKey
  );
  const votes = alreadyVoted
    ? currentVotes
    : [...currentVotes, clean(actor.email)];
  const voteKeys = new Set(votes.map(normalizedEmail));
  const unanimous = eligibility.emails.length > 0 &&
    eligibility.emails.every((email) => voteKeys.has(normalizedEmail(email)));
  const rawVotes = Array.isArray(room?.ready_players) ? room.ready_players : [];
  return {
    patch: sameStrings(rawVotes, votes) ? {} : { ready_players: votes },
    votes,
    eligibleEmails: eligibility.emails,
    unanimous,
  };
}

export function replayResetMembershipPatch(room: Room): Room {
  const eligibility = replayEligibility(room);
  if (!eligibility.players.length) {
    throw policyError(
      "The room has no operatives who can replay",
      409,
      "replay_no_players",
    );
  }
  const eligibleUserIDs = new Set(eligibility.userIDs);
  const removedUserIDs = new Set(eligibility.removedUserIDs);
  const participantUserIDs = Array.isArray(room?.participant_user_ids)
    ? room.participant_user_ids.map(clean).filter(Boolean)
    : [];
  const nextParticipantUserIDs =
    eligibility.players.every((player) => Boolean(clean(player?.user_id)))
      ? [...eligibleUserIDs]
      : [
        ...new Set(
          participantUserIDs.filter((userID) => !removedUserIDs.has(userID)),
        ),
      ];
  const hostKey = normalizedEmail(room?.host_email);
  const host = eligibility.players.find((player) =>
    normalizedEmail(player.email) === hostKey
  );
  return {
    players: eligibility.players,
    participant_user_ids: nextParticipantUserIDs,
    host_email: clean(host?.email ?? eligibility.players[0].email),
    departed_player_emails: [],
  };
}

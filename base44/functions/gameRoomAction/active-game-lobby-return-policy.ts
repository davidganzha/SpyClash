type Room = Record<string, any>;

export type ActiveGameLobbyReturnTransition = {
  patch: Room;
  didReset: boolean;
  votes: string[];
  requiredVotes: number;
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

function roomPlayers(room: Room): Record<string, unknown>[] {
  return Array.isArray(room?.players)
    ? room.players.filter((player) =>
      player && typeof player === "object" && !Array.isArray(player)
    )
    : [];
}

function canonicalNonDepartedPlayers(room: Room): Record<string, unknown>[] {
  const departed = new Set(
    (Array.isArray(room?.departed_player_emails)
      ? room.departed_player_emails
      : []).map(normalizedEmail).filter(Boolean),
  );
  const seenUserIDs = new Set<string>();
  const seenEmails = new Set<string>();
  const players: Record<string, unknown>[] = [];
  for (const player of roomPlayers(room)) {
    const userID = clean(player.user_id);
    const email = clean(player.email);
    const emailKey = normalizedEmail(email);
    if (
      !emailKey ||
      departed.has(emailKey) ||
      (userID && seenUserIDs.has(userID)) ||
      seenEmails.has(emailKey)
    ) {
      continue;
    }
    if (userID) seenUserIDs.add(userID);
    seenEmails.add(emailKey);
    players.push({
      ...player,
      ...(userID ? { user_id: userID } : {}),
      email,
    });
  }
  return players;
}

export function activeGameLobbyEligiblePlayerEmails(room: Room): string[] {
  return canonicalNonDepartedPlayers(room)
    .map((player) => clean(player.email))
    .filter(Boolean);
}

function canonicalVotes(
  room: Room,
  eligiblePlayers: readonly Record<string, unknown>[],
): string[] {
  const eligible = new Map(
    eligiblePlayers.map((player) => [
      normalizedEmail(player.email),
      clean(player.email),
    ]),
  );
  const seen = new Set<string>();
  const result: string[] = [];
  const values = Array.isArray(room?.ready_players) ? room.ready_players : [];
  for (const value of values) {
    const key = normalizedEmail(value);
    const canonical = eligible.get(key);
    if (!canonical || seen.has(key)) continue;
    seen.add(key);
    result.push(canonical);
  }
  return result;
}

function sameStrings(
  left: readonly unknown[],
  right: readonly string[],
): boolean {
  return left.length === right.length &&
    left.every((value, index) => clean(value) === right[index]);
}

export function activeGameLobbyResetPatch(room: Room): Room {
  const players = canonicalNonDepartedPlayers(room);
  if (!players.length) {
    throw policyError(
      "The room has no operatives who can return to the lobby",
      409,
      "return_to_lobby_no_players",
    );
  }
  const playerUserIDs = [
    ...new Set(players.map((player) => clean(player.user_id)).filter(Boolean)),
  ];
  const hostKey = normalizedEmail(room?.host_email);
  const host = players.find((player) =>
    normalizedEmail(player.email) === hostKey
  );

  return {
    status: "waiting",
    players,
    participant_user_ids: playerUserIDs,
    host_email: clean(host?.email ?? players[0].email),
    departed_player_emails: [],
    spy_email: "",
    spy_emails: [],
    revealed_spy_emails: [],
    secret_word: "",
    word: "",
    category: "",
    spy_guess: "",
    detective_votes: [],
    detective_vote_round_id: "",
    detective_vote_cancellation_event_id: "",
    detective_vote_cancellation_round_id: "",
    detective_vote_cancellation_present_at: "",
    detective_vote_cancellation_reason: "",
    winner: "",
    cards_read: [],
    vote_requests: [],
    spectators: [],
    eliminated_emails: [],
    ready_players: [],
    question_phase: "asking",
    questions_in_round: 0,
    round_number: 1,
    current_answer: "",
    current_answer_feedback: null,
    current_asker_email: "",
    current_answerer_email: "",
    roulette_target_email: "",
    player_feedback: [],
    word_pool: [],
    replay_source_match_id: "",
    match_id: "",
    terminal_intent: null,
    intro_started_at: null,
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    game_started_event_id: "",
    game_finished_event_id: "",
    countdown_started_at: null,
  };
}

export function activeGameLobbyReturnTransition(
  room: Room,
  actorEmailValue: unknown,
  requestedVoteValue: unknown,
): ActiveGameLobbyReturnTransition {
  const eligiblePlayers = canonicalNonDepartedPlayers(room);
  const actorKey = normalizedEmail(actorEmailValue);
  const actor = eligiblePlayers.find((player) =>
    normalizedEmail(player.email) === actorKey
  );
  if (!actor) {
    throw policyError(
      "Only a current room player can vote to return to the lobby",
      403,
      "return_to_lobby_not_player",
    );
  }

  const status = clean(room?.status || "waiting").toLocaleLowerCase();
  if (status !== "playing") {
    throw policyError(
      "Return-to-lobby voting is not active",
      409,
      "return_to_lobby_vote_inactive",
    );
  }
  if (typeof requestedVoteValue !== "boolean") {
    throw policyError(
      "Return-to-lobby vote must be a boolean",
      400,
      "return_to_lobby_vote_invalid",
    );
  }

  const votes = canonicalVotes(room, eligiblePlayers);
  const actorEmail = clean(actor.email);
  const actorAlreadyVoted = votes.some((email) =>
    normalizedEmail(email) === actorKey
  );
  const nextVotes = requestedVoteValue
    ? (actorAlreadyVoted ? votes : [...votes, actorEmail])
    : votes.filter((email) => normalizedEmail(email) !== actorKey);
  const voteKeys = new Set(nextVotes.map(normalizedEmail));
  const unanimous = eligiblePlayers.every((player) =>
    voteKeys.has(normalizedEmail(player.email))
  );
  if (unanimous) {
    return {
      patch: activeGameLobbyResetPatch(room),
      didReset: true,
      votes: nextVotes,
      requiredVotes: eligiblePlayers.length,
    };
  }

  const rawVotes = Array.isArray(room?.ready_players) ? room.ready_players : [];
  return {
    patch: sameStrings(rawVotes, nextVotes) ? {} : { ready_players: nextVotes },
    didReset: false,
    votes: nextVotes,
    requiredVotes: eligiblePlayers.length,
  };
}

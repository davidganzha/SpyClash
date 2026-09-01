type Room = Record<string, any>;

export type LobbyKickTarget = {
  target_user_id?: unknown;
  target_email?: unknown;
};

export type LobbyKickTransition = {
  patch: Room;
  removedPlayer: Record<string, unknown>;
  removedRecordCount: number;
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

function validatedTargetUserID(value: unknown): string {
  const userID = clean(value);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(userID)) {
    throw policyError(
      "Kick target user id is invalid",
      400,
      "kick_target_invalid",
    );
  }
  return userID;
}

function validatedTargetEmail(value: unknown): string {
  const email = clean(value);
  if (
    email.length > 254 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  ) {
    throw policyError(
      "Kick target email is invalid",
      400,
      "kick_target_invalid",
    );
  }
  return email;
}

function canonicalEmailListWithoutTarget(
  value: unknown,
  targetEmailKey: string,
): string[] {
  const canonical = new Map<string, string>();
  const values = Array.isArray(value) ? value : [];
  for (const candidate of values) {
    const email = clean(candidate);
    const key = normalizedEmail(email);
    if (!key || key === targetEmailKey || canonical.has(key)) continue;
    canonical.set(key, email);
  }
  return [...canonical.values()];
}

function canonicalRemainingPlayers(
  players: readonly Record<string, unknown>[],
  removedUserIDs: ReadonlySet<string>,
  targetEmailKey: string,
): Record<string, unknown>[] {
  const seenUserIDs = new Set<string>();
  const seenEmails = new Set<string>();
  const result: Record<string, unknown>[] = [];
  for (const player of players) {
    const userID = clean(player.user_id);
    const email = clean(player.email);
    const emailKey = normalizedEmail(email);
    if (
      removedUserIDs.has(userID) ||
      emailKey === targetEmailKey ||
      !emailKey ||
      (userID && seenUserIDs.has(userID)) ||
      seenEmails.has(emailKey)
    ) {
      continue;
    }
    if (userID) seenUserIDs.add(userID);
    seenEmails.add(emailKey);
    result.push({
      ...player,
      ...(userID ? { user_id: userID } : {}),
      email,
    });
  }
  return result;
}

export function lobbyKickTransition(
  room: Room,
  actorEmailValue: unknown,
  target: LobbyKickTarget,
): LobbyKickTransition {
  const actorKey = normalizedEmail(actorEmailValue);
  const hostKey = normalizedEmail(room?.host_email);
  if (!actorKey || actorKey !== hostKey) {
    throw policyError(
      "Only the room host can remove an operative",
      403,
      "kick_host_required",
    );
  }

  const status = clean(room?.status || "waiting").toLocaleLowerCase();
  if (!["waiting", "ready_voting"].includes(status)) {
    throw policyError(
      "Operatives can only be removed from the lobby",
      409,
      "kick_status_invalid",
    );
  }

  const players = roomPlayers(room);
  const suppliedUserID = clean(target?.target_user_id);
  const hasStableUserID = Boolean(suppliedUserID);
  const targetUserID = hasStableUserID
    ? validatedTargetUserID(suppliedUserID)
    : "";
  const targetEmail = hasStableUserID
    ? ""
    : validatedTargetEmail(target?.target_email);
  const targetEmailKey = normalizedEmail(targetEmail);
  const matches = hasStableUserID
    ? players.filter((player) => clean(player.user_id) === targetUserID)
    : players.filter((player) =>
      normalizedEmail(player.email) === targetEmailKey
    );
  if (!matches.length) {
    throw policyError(
      "Kick target is not a room player",
      404,
      "kick_target_unknown",
    );
  }

  const matchingEmailKeys = new Set(
    matches.map((player) => normalizedEmail(player.email)).filter(Boolean),
  );
  const matchingUserIDs = new Set(
    matches.map((player) => clean(player.user_id)).filter(Boolean),
  );
  if (
    matchingEmailKeys.size !== 1 ||
    (!hasStableUserID && matchingUserIDs.size > 1)
  ) {
    throw policyError(
      "Kick target identity is ambiguous",
      409,
      "kick_target_ambiguous",
    );
  }
  const resolvedEmailKey = [...matchingEmailKeys][0];
  const resolvedMatches = players.filter((player) =>
    (hasStableUserID && clean(player.user_id) === targetUserID) ||
    normalizedEmail(player.email) === resolvedEmailKey
  );
  const resolvedUserIDs = new Set(
    resolvedMatches.map((player) => clean(player.user_id)).filter(Boolean),
  );
  if (
    hasStableUserID &&
    [...resolvedUserIDs].some((userID) => userID !== targetUserID)
  ) {
    throw policyError(
      "Kick target identity is ambiguous",
      409,
      "kick_target_ambiguous",
    );
  }
  const hostUserIDs = new Set(
    players.filter((player) => normalizedEmail(player.email) === hostKey)
      .map((player) => clean(player.user_id)).filter(Boolean),
  );
  if (
    resolvedEmailKey === hostKey ||
    (hasStableUserID && hostUserIDs.has(targetUserID))
  ) {
    throw policyError(
      "The room host cannot be removed",
      409,
      "kick_host_forbidden",
    );
  }

  const removedUserIDs = new Set(resolvedUserIDs);
  const remainingPlayers = canonicalRemainingPlayers(
    players,
    removedUserIDs,
    resolvedEmailKey,
  );
  const participantUserIDs = [
    ...new Set(
      remainingPlayers.map((player) => clean(player.user_id)).filter(Boolean),
    ),
  ];
  const feedback =
    (Array.isArray(room?.player_feedback) ? room.player_feedback : []).filter((
      item,
    ) => normalizedEmail(item?.email) !== resolvedEmailKey);

  return {
    removedPlayer: {
      ...resolvedMatches[0],
      ...(clean(resolvedMatches[0].user_id)
        ? { user_id: clean(resolvedMatches[0].user_id) }
        : {}),
      email: clean(resolvedMatches[0].email),
    },
    removedRecordCount: resolvedMatches.length,
    patch: {
      status: "waiting",
      players: remainingPlayers,
      participant_user_ids: participantUserIDs,
      ready_players: [],
      spectators: canonicalEmailListWithoutTarget(
        room?.spectators,
        resolvedEmailKey,
      ),
      cards_read: canonicalEmailListWithoutTarget(
        room?.cards_read,
        resolvedEmailKey,
      ),
      eliminated_emails: canonicalEmailListWithoutTarget(
        room?.eliminated_emails,
        resolvedEmailKey,
      ),
      departed_player_emails: canonicalEmailListWithoutTarget(
        room?.departed_player_emails,
        resolvedEmailKey,
      ),
      incompatible_player_emails: canonicalEmailListWithoutTarget(
        room?.incompatible_player_emails,
        resolvedEmailKey,
      ),
      spy_emails: canonicalEmailListWithoutTarget(
        room?.spy_emails,
        resolvedEmailKey,
      ),
      revealed_spy_emails: canonicalEmailListWithoutTarget(
        room?.revealed_spy_emails,
        resolvedEmailKey,
      ),
      spy_email: normalizedEmail(room?.spy_email) === resolvedEmailKey
        ? ""
        : clean(room?.spy_email),
      vote_requests: [],
      detective_votes: [],
      detective_vote_round_id: "",
      detective_vote_cancellation_event_id: "",
      detective_vote_cancellation_round_id: "",
      detective_vote_cancellation_present_at: "",
      detective_vote_cancellation_reason: "",
      player_feedback: feedback,
      ...(normalizedEmail(room?.current_asker_email) === resolvedEmailKey
        ? { current_asker_email: "" }
        : {}),
      ...(normalizedEmail(room?.current_answerer_email) === resolvedEmailKey
        ? { current_answerer_email: "" }
        : {}),
      ...(normalizedEmail(room?.roulette_target_email) === resolvedEmailKey
        ? { roulette_target_email: "" }
        : {}),
    },
  };
}

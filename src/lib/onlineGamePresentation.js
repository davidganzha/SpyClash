const ASSOCIATION_STATE_MAX_LENGTH = 64 * 1024;
const ASSOCIATION_SPOKEN_LIMIT = 64;
const CLASSIFIED_WORD = "classified";

function clean(value) {
  return String(value ?? "").trim();
}

function normalizedEmail(value) {
  return clean(value).toLocaleLowerCase();
}

function normalizedStatus(room) {
  return clean(room?.status || "waiting").toLocaleLowerCase();
}

function normalizedRoundPhase(room) {
  const phase = clean(room?.question_phase).toLocaleLowerCase();
  return ["asking", "answering", "countdown", "results"].includes(phase)
    ? phase
    : "asking";
}

function normalizedGameMode(room) {
  return clean(room?.game_mode).toLocaleLowerCase() === "associations"
    ? "associations"
    : "questions";
}

function roomPlayers(room) {
  if (!Array.isArray(room?.players)) return [];

  const seen = new Set();
  return room.players.flatMap((player) => {
    if (!player || typeof player !== "object" || Array.isArray(player)) return [];
    const email = normalizedEmail(player.email);
    if (!email || seen.has(email)) return [];
    seen.add(email);
    return [{ ...player }];
  });
}

function normalizedEmailSet(value) {
  if (!Array.isArray(value)) return new Set();
  return new Set(value.map(normalizedEmail).filter(Boolean));
}

function activePlayersForRoom(room) {
  const spectators = normalizedEmailSet(room?.spectators);
  return roomPlayers(room).filter((player) => !spectators.has(normalizedEmail(player.email)));
}

function activeVoteRequestsForRoom(room, activePlayers) {
  const activeEmails = new Set(activePlayers.map((player) => normalizedEmail(player.email)));
  const seen = new Set();
  if (!Array.isArray(room?.vote_requests)) return [];

  return room.vote_requests.flatMap((value) => {
    const email = normalizedEmail(value);
    if (!email || !activeEmails.has(email) || seen.has(email)) return [];
    seen.add(email);
    return [clean(value)];
  });
}

function voteState(room, userEmail) {
  const activePlayers = activePlayersForRoom(room);
  const activeVoteRequests = activeVoteRequestsForRoom(room, activePlayers);
  const voteThreshold = activePlayers.length > 0
    ? Math.ceil(activePlayers.length * 0.51)
    : 0;
  const viewerEmail = normalizedEmail(userEmail);
  const votes = Array.isArray(room?.detective_votes) ? room.detective_votes : [];
  const myVote = votes.find((vote) =>
    vote && typeof vote === "object" && !Array.isArray(vote)
      && normalizedEmail(vote.voter_email) === viewerEmail
  );

  return {
    activePlayers,
    activeVoteRequests,
    voteThreshold,
    isVotingActive: voteThreshold > 0 && activeVoteRequests.length >= voteThreshold,
    myVote: myVote ? { ...myVote } : null,
    hasRequestedVote: Boolean(viewerEmail)
      && activeVoteRequests.some((email) => normalizedEmail(email) === viewerEmail),
  };
}

function roleGateState(room) {
  const players = roomPlayers(room);
  const cardsRead = normalizedEmailSet(room?.cards_read);
  const allRoleCardsRead = players.length > 0
    && players.every((player) => cardsRead.has(normalizedEmail(player.email)));

  return {
    allRoleCardsRead,
    hasStartedTimer: Boolean(clean(room?.game_started_at)),
  };
}

function onlineSubphase(room, isVotingActive, roleGate) {
  const status = normalizedStatus(room);
  if (status === "finished") return "finished";
  if (status !== "playing") return null;
  if (!roleGate.allRoleCardsRead || !roleGate.hasStartedTimer) return "role_gate";
  if (isVotingActive) return "voting";
  return "active";
}

function visibleSecretWord(room) {
  const word = clean(room?.secret_word) || clean(room?.word);
  if (!word || word.toLocaleLowerCase() === CLASSIFIED_WORD) return null;
  return word;
}

function canStopAssociationSpin(room, userEmail, presentationState) {
  if (presentationState.subphase !== "active"
    || presentationState.isPaused
    || presentationState.gameMode !== "associations"
    || !presentationState.associationState.spinning
    || !presentationState.isPlayer
    || presentationState.isSpectator) {
    return false;
  }

  // Any active client may settle this idempotent presentation-only phase.
  // Restricting it to the host/current speaker leaves the whole room spinning
  // forever when either device is backgrounded or temporarily offline.
  return true;
}

export function associationSpinSettlementDelayMs(room, userEmail) {
  const viewerEmail = normalizedEmail(userEmail);
  const activeEmails = activePlayersForRoom(room).map((player) =>
    normalizedEmail(player.email)
  );
  if (!viewerEmail || !activeEmails.includes(viewerEmail)) return null;

  const prioritizedEmails = [];
  const addCandidate = (email) => {
    const normalized = normalizedEmail(email);
    if (activeEmails.includes(normalized) && !prioritizedEmails.includes(normalized)) {
      prioritizedEmails.push(normalized);
    }
  };
  addCandidate(room?.current_asker_email);
  addCandidate(room?.host_email);
  activeEmails.forEach(addCandidate);

  const rank = prioritizedEmails.indexOf(viewerEmail);
  return rank < 0 ? null : 2_000 + rank * 1_500;
}

/**
 * Decodes the server's association round envelope without trusting arbitrary
 * JSON shapes stored in current_answer.
 */
export function parseAssociationRoundState(value) {
  if (typeof value !== "string" || value.length > ASSOCIATION_STATE_MAX_LENGTH) {
    return { spoken: [], spinning: false };
  }

  try {
    const parsed = JSON.parse(value);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
      || !Array.isArray(parsed.spoken) || typeof parsed.spinning !== "boolean"
      || parsed.spoken.some((email) => typeof email !== "string")) {
      return { spoken: [], spinning: false };
    }

    const seen = new Set();
    const spoken = [];
    for (const value of parsed.spoken) {
      const email = clean(value);
      const key = normalizedEmail(email);
      if (!key || seen.has(key)) continue;
      seen.add(key);
      spoken.push(email);
      if (spoken.length >= ASSOCIATION_SPOKEN_LIMIT) break;
    }
    return { spoken, spinning: parsed.spinning };
  } catch {
    return { spoken: [], spinning: false };
  }
}

/**
 * Returns the action exposed by the current iOS OnlineRoundState contract.
 * Presentation gates are derived from room fields; no synthetic status is sent
 * back to the server.
 */
export function onlineRoundCommand(room, userEmail) {
  const viewerEmail = normalizedEmail(userEmail);
  const players = roomPlayers(room);
  const isPlayer = Boolean(viewerEmail)
    && players.some((player) => normalizedEmail(player.email) === viewerEmail);
  const isPaused = Boolean(clean(room?.game_paused_at));
  const votes = voteState(room, userEmail);
  const roleGate = roleGateState(room);
  const subphase = onlineSubphase(room, votes.isVotingActive, roleGate);

  if (subphase !== "active" || isPaused || !isPlayer) return null;

  const roundPhase = normalizedRoundPhase(room);
  if (roundPhase === "results") return "continue_round";

  if (normalizedGameMode(room) === "associations") {
    const associationState = parseAssociationRoundState(room?.current_answer);
    if (associationState.spinning) return null;

    const speakerEmail = normalizedEmail(room?.current_asker_email);
    if (!speakerEmail) {
      return normalizedEmail(room?.host_email) === viewerEmail
        ? "start_association"
        : null;
    }
    return speakerEmail === viewerEmail ? "advance_association" : null;
  }

  return roundPhase === "asking"
    && normalizedEmail(room?.current_asker_email) === viewerEmail
    ? "mark_answer_heard"
    : null;
}

/**
 * Builds a side-effect-free, viewer-safe model for the online-game UI.
 */
export function deriveOnlineGamePresentation(room, userEmail) {
  const viewerEmail = normalizedEmail(userEmail);
  const players = roomPlayers(room);
  const isPlayer = Boolean(viewerEmail)
    && players.some((player) => normalizedEmail(player.email) === viewerEmail);
  const spectatorEmails = normalizedEmailSet(room?.spectators);
  const isSpectator = Boolean(viewerEmail) && spectatorEmails.has(viewerEmail);
  const isHost = Boolean(viewerEmail)
    && normalizedEmail(room?.host_email) === viewerEmail;
  const isSpy = isPlayer && !isSpectator
    && normalizedEmail(room?.spy_email) === viewerEmail;
  const viewerRole = isSpectator
    ? "spectator"
    : isSpy
      ? "spy"
      : isPlayer
        ? "detective"
        : "observer";
  const secretWord = visibleSecretWord(room);
  const canSeeSecretWord = viewerRole === "detective" && secretWord !== null;
  const votes = voteState(room, userEmail);
  const roleGate = roleGateState(room);
  const subphase = onlineSubphase(room, votes.isVotingActive, roleGate);
  const isPaused = Boolean(clean(room?.game_paused_at));
  const associationState = parseAssociationRoundState(room?.current_answer);
  const gameMode = normalizedGameMode(room);
  const roundPhase = normalizedRoundPhase(room);
  const cardsRead = normalizedEmailSet(room?.cards_read);
  const state = {
    status: normalizedStatus(room),
    subphase,
    isPaused,
    viewerRole,
    isPlayer,
    isHost,
    isSpy,
    isSpectator,
    canSeeSecretWord,
    secretWord: canSeeSecretWord ? secretWord : null,
    hasReadRoleCard: Boolean(viewerEmail) && cardsRead.has(viewerEmail),
    cardsReadCount: cardsRead.size,
    allRoleCardsRead: roleGate.allRoleCardsRead,
    activePlayers: votes.activePlayers,
    activeVoteRequests: votes.activeVoteRequests,
    voteThreshold: votes.voteThreshold,
    isVotingActive: votes.isVotingActive,
    myVote: votes.myVote,
    hasRequestedVote: votes.hasRequestedVote,
    gameMode,
    roundPhase,
    associationState,
    roundCommand: onlineRoundCommand(room, userEmail),
  };

  const canSettleAssociationSpin = canStopAssociationSpin(room, userEmail, state);
  return {
    ...state,
    canStopAssociationSpin: canSettleAssociationSpin,
    associationSpinSettlementDelayMs: canSettleAssociationSpin
      ? associationSpinSettlementDelayMs(room, userEmail)
      : null,
  };
}

/**
 * Uses the server timestamp as the shared countdown clock, matching iOS.
 */
export function countdownRemainingSeconds(
  room,
  nowMs = Date.now(),
  durationSeconds = 0,
) {
  if (normalizedRoundPhase(room) !== "countdown") return 0;

  const duration = Number(durationSeconds);
  const safeDuration = Number.isFinite(duration) ? Math.max(duration, 0) : 0;
  const startedAt = Date.parse(clean(room?.countdown_started_at));
  const currentTime = Number(nowMs);
  if (!Number.isFinite(startedAt) || !Number.isFinite(currentTime)) {
    return safeDuration;
  }

  return Math.max(safeDuration - (currentTime - startedAt) / 1_000, 0);
}

/**
 * Rejects delayed realtime/poll responses that predate the room currently on
 * screen. Base44's projected updated_date is the shared ordering signal; when
 * either side has no valid timestamp we keep compatibility with legacy rows.
 */
export function shouldAcceptOnlineRoomSnapshot(currentRoom, nextRoom) {
  if (!nextRoom?.id) return false;
  if (!currentRoom?.id) return true;
  if (clean(currentRoom.id) !== clean(nextRoom.id)) return false;

  const currentUpdatedAt = Date.parse(clean(currentRoom.updated_date));
  const nextUpdatedAt = Date.parse(clean(nextRoom.updated_date));
  if (!Number.isFinite(currentUpdatedAt) || !Number.isFinite(nextUpdatedAt)) {
    return true;
  }
  return nextUpdatedAt >= currentUpdatedAt;
}

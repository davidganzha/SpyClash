// @ts-nocheck -- Original dynamic room documents retain their native JSON contract.
// Rules are vendored from the original game; persistence and external side effects
// are replaced by one atomic PostgreSQL transaction owned by the handler.
import { requireSafeCommunityText, safeCommunityAvatar, safeCommunityDisplayName } from "./rules/content-safety.ts";
import { projectRoomForClient } from "./rules/room-projection.ts";
import { assertAuthoritativeLobbyReady, hasAuthoritativeLobbyState, lobbyMutationPatch, validateLobbyMutation, lobbyStateFromRoom, selectedAuthoritativeLobbyWordPool } from "./rules/lobby-state-policy.ts";
import { canonicalClientCapabilities, canonicalSpyEmails, lobbySpyCount, spiesKnowEachOther, validatedLobbySpyCount, assertMultiSpyCapableRoster, compatibleRosterForSpyCount, lobbyMembershipClampPatch, serverSpyAssignment, playerSupportsMultiSpy, roomHasDepartedPlayer, departedPlayerEmails, activeDepartureTransition, assertActiveSpyGuesser, spyGuessWinner, spyTeamTerminalWinner } from "./rules/multi-spy-policy.ts";
import { assertGameActionAllowedByDeadline, assertGameActionAllowedWhilePaused, hasGameTimerElapsed, pauseGameTransitionPatch, resumeGameTransitionPatch, finishGamePauseTransitionPatch, gameTimerDeadlineMilliseconds } from "./rules/game-timer-policy.ts";
import { assertIntroCompletionAccess, introStartedAtForCompletion, serverIntroStartPatch, roleCardReadTransitionPatch, buildTerminalIntent, terminalIntentFromRoom, terminalPatchFromIntent, preTimerMembershipTransitionPatch, deriveExpiredGameWinner, rejectRetiredResultRecording, assertRankedTerminalRoom, rankedMatchIdentity } from "./rules/room-result-policy.ts";
import { initialQuestionTurn, advanceQuestionTurn, encodeQuestionTurnOrderState, questionRosterChangePatch } from "./rules/question-turn-order.ts";
import { initialAssociationTurn, advanceAssociationTurn, reconcileAssociationTurnState, encodeAssociationTurnState, associationRosterChangePatch } from "./rules/association-turn-order.ts";
import { detectiveVoteRequestTransition, detectiveVoteLeavePatch, isDetectiveVotingActive, bindDetectiveVoteRoundIdentity, scheduledDetectiveVoteCancellationEvent, resolvedDetectiveVoteCastTransition } from "./rules/detective-vote-policy.ts";
import { assertLobbySettingsAccess, validatedGameMode, validatedGameDuration, gameModePatch, gameDurationPatch } from "./rules/room-interaction-safety.ts";
import { activeGameLobbyReturnTransition } from "./rules/active-game-lobby-return-policy.ts";
import { lobbyKickTransition } from "./rules/lobby-kick-policy.ts";
import { replayVoteTransition, replayVoteState, replayResetMembershipPatch } from "./rules/replay-policy.ts";
import { replayAutoStartPatch, replayAutoStartAlreadyComplete, replaySourceMatchID, assertExpectedReplaySourceMatch } from "./rules/replay-auto-start-policy.ts";
import { hostDepartureUsesMembershipTransition } from "./rules/finished-room-departure-policy.ts";
import { assertExpectedMembershipGeneration, playerMembershipGeneration, validatedMembershipGeneration } from "./rules/room-membership-generation.ts";
import { terminalOutboxCommitPatch, terminalOutboxCommitRecipientUserIDs, assertTerminalOutboxCommitBeforeAuthorityReset } from "./rules/terminal-outbox-commit.ts";
import { assertExpectedTimerFinalizationScope } from "./rules/terminal-finalization-scope.ts";
import { assertActiveRoundActor, assertRoundActionMode } from "./rules/round-action-access.ts";
import { hasValidEnabledStartWordPool } from "./rules/start-word-pool-policy.ts";
import { nextRoundNumber } from "./rules/game-round.ts";
import { gameHistoryResultKey } from "./rules/game-history-idempotency.ts";

export type GameRecord = Record<string, any>;
export type GameActor = { id: string; email: string; full_name?: string; nickname?: string; avatar_url?: string; display_name?: string; avatar?: string };
export type GameInput = { room: GameRecord | null; actor: GameActor; action: string; payload: GameRecord; now: number; random?: () => number; uuid?: () => string; roomID?: string; roomCode?: string };
export type GameTransition = { room: GameRecord; history?: GameRecord[]; events?: GameRecord[] };

function clean(value) {
  return String(value || "").trim();
}

function uniqueStrings(values) {
  return [...new Set((values || []).map(clean).filter(Boolean))];
}

function normalizedStatus(room) {
  return clean(room?.status || "waiting").toLowerCase();
}

function players(room) {
  return (Array.isArray(room?.players) ? room.players : []).map((player) => ({
    ...player,
    email: clean(player?.email),
    name: safeCommunityDisplayName(player?.name),
    avatar: safeCommunityAvatar(player?.avatar),
  }));
}

function spectators(room) {
  return Array.isArray(room?.spectators) ? room.spectators : [];
}

function voteRequests(room) {
  return Array.isArray(room?.vote_requests) ? room.vote_requests : [];
}

function detectiveVotes(room) {
  return Array.isArray(room?.detective_votes) ? room.detective_votes : [];
}

function detectiveVoteRoundID(room) {
  return clean(room?.detective_vote_round_id);
}

function explicitExpectedVoteRoundID(body) {
  // `expected_vote_round_id` is canonical. The longer alias is accepted only
  // during the rollout so an already-built client candidate is not stranded.
  return clean(
    body?.expected_vote_round_id || body?.expected_detective_vote_round_id,
  );
}

function detectiveVotingActive(room) {
  const activeEmails = activePlayers(room).map((player) => player.email);
  return normalizedStatus(room) === "playing" &&
    isDetectiveVotingActive(activeEmails, voteRequests(room));
}

function readyPlayers(room) {
  return Array.isArray(room?.ready_players) ? room.ready_players : [];
}

function cardsRead(room) {
  return Array.isArray(room?.cards_read) ? room.cards_read : [];
}

function activePlayers(room) {
  const out = new Set(spectators(room));
  return players(room).filter((player) => !out.has(player.email));
}

function playerInRoom(room, email) {
  return players(room).some((player) => player.email === email);
}

function playerFromUser(user, body = {}) {
  const incoming = body?.player || {};
  const clientCapabilities = canonicalClientCapabilities(
    incoming?.client_capabilities ?? body?.client_capabilities,
  );
  return {
    user_id: clean(user.id),
    email: user.email,
    name: safeCommunityDisplayName(
      clean(incoming.name) || clean(user.display_name) || clean(user.full_name),
    ),
    avatar: safeCommunityAvatar(clean(incoming.avatar) || clean(user.avatar)),
    client_capabilities: clientCapabilities,
  };
}

function mergePlayers(existingPlayers, player) {
  const byEmail = new Map();
  for (const existing of existingPlayers || []) {
    if (clean(existing?.email)) {
      byEmail.set(existing.email, existing);
    }
  }
  byEmail.set(player.email, {
    ...(byEmail.get(player.email) || {}),
    ...player,
    email: player.email,
  });
  return [...byEmail.values()];
}

function requirePlayer(room, user) {
  if (!playerInRoom(room, user.email)) {
    throw Object.assign(new Error("Not a player in this room"), {
      status: 403,
      code: "room_access_revoked",
    });
  }
}

function requireHost(room, user) {
  if (room?.host_email !== user.email) {
    throw Object.assign(new Error("Host access required"), { status: 403 });
  }
}

function displayWord(room) {
  return clean(room?.word) || clean(room?.secret_word);
}

function shouldSpyWin(room) {
  return spyTeamTerminalWinner(room) === "spy";
}

function clientUpdateRequiredError() {
  return Object.assign(
    new Error("Update SpyClash to continue in this multi-spy room"),
    { status: 426, code: "client_update_required" },
  );
}

function validatedStartPatch(room, payload, assignment) {
  const roomPlayers = players(room);
  const emails = new Set(roomPlayers.map((player) => player.email));
  const spyEmails = uniqueStrings(assignment?.spy_emails);
  const spyEmail = clean(assignment?.spy_email);
  const askerEmail = clean(payload?.current_asker_email);
  const answererEmail = clean(payload?.current_answerer_email);
  const secretWord = requireSafeCommunityText(
    clean(payload?.word || payload?.secret_word),
    "Secret word",
  );
  const gameMode = clean(payload?.game_mode);
  const durationSeconds = Number(payload?.game_duration_seconds);
  const wordPool = Array.isArray(payload?.word_pool)
    ? payload.word_pool
      .map((entry) => ({
        word: requireSafeCommunityText(clean(entry?.word), "Word pack item"),
        enabled: entry?.enabled !== false,
      }))
      .filter((entry) => entry.word)
      .slice(0, 500)
    : [];

  if (roomPlayers.length < 3) {
    throw Object.assign(new Error("Need at least 3 operatives"), {
      status: 400,
    });
  }
  if (
    spyEmails.length !== lobbySpyCount(room) ||
    spyEmail !== spyEmails[0] ||
    spyEmails.some((email) => !emails.has(email))
  ) {
    throw Object.assign(new Error("Every spy must be a unique room player"), {
      status: 400,
      code: "spy_assignment_invalid",
    });
  }
  if (
    !emails.has(askerEmail) || !emails.has(answererEmail) ||
    askerEmail === answererEmail
  ) {
    throw Object.assign(
      new Error("Question vector must use two room players"),
      { status: 400 },
    );
  }
  if (!secretWord) {
    throw Object.assign(new Error("Secret word is required"), { status: 400 });
  }
  if (!["questions", "associations"].includes(gameMode)) {
    throw Object.assign(new Error("Invalid game mode"), { status: 400 });
  }
  if (
    !Number.isInteger(durationSeconds) || durationSeconds < 60 ||
    durationSeconds > 900
  ) {
    throw Object.assign(
      new Error("Duration must be between 1 and 15 minutes"),
      { status: 400 },
    );
  }
  if (!hasValidEnabledStartWordPool(wordPool, secretWord)) {
    throw Object.assign(new Error("Word pool is invalid"), { status: 400 });
  }

  return {
    spy_email: spyEmail,
    spy_emails: spyEmails,
    secret_word: secretWord,
    word: secretWord,
    category: requireSafeCommunityText(
      clean(payload?.category) || "CLASSIC",
      "Word pack category",
    ),
    round_number: 1,
    questions_in_round: 0,
    current_asker_email: askerEmail,
    current_answerer_email: answererEmail,
    game_duration_seconds: durationSeconds,
    question_phase: "asking",
    current_answer: "",
    current_answer_feedback: null,
    spy_guess: "",
    player_feedback: [],
    word_pool: wordPool,
    game_mode: gameMode,
  };
}

function replayResetPatch(room, user, body, requiresReplayVotes = true) {
  requireHost(room, user);
  if (normalizedStatus(room) !== "finished") {
    throw Object.assign(
      new Error("A replay can start only after the match is fully finished."),
      { status: 409, code: "replay_before_terminal_commit" },
    );
  }
  assertTerminalOutboxCommitBeforeAuthorityReset(room);
  if (requiresReplayVotes && !replayVoteState(room).unanimous) {
    throw Object.assign(
      new Error("Every remaining operative must vote before replay."),
      { status: 409, code: "replay_votes_incomplete" },
    );
  }
  const legacyLobbySettings = hasAuthoritativeLobbyState(room) ? {} : {
    game_mode: clean(body?.game_mode) || clean(room.game_mode) || "questions",
    game_duration_seconds: Number(
      body?.game_duration_seconds || room.game_duration_seconds || 900,
    ),
  };
  const replayMembership = replayResetMembershipPatch(room);
  const replayPlayers = replayMembership.players;
  return {
    status: "waiting",
    ...replayMembership,
    spy_email: "",
    spy_emails: [],
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
    replay_source_match_id: requiresReplayVotes
      ? replaySourceMatchID(room)
      : "",
    match_id: "",
    terminal_intent: null,
    intro_started_at: null,
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    game_started_event_id: "",
    game_finished_event_id: "",
    countdown_started_at: null,
    ...lobbyMembershipClampPatch(room, replayPlayers.length),
    ...legacyLobbySettings,
  };
}

function failure(message: string, code: string, status = 409): never {
  throw Object.assign(new Error(message), { code, status });
}
function secureRandom(): number {
  const values = new Uint32Array(1);
  crypto.getRandomValues(values);
  return values[0] / 0x100000000;
}

/** Actor-only original projection. Raw server state is never a client response. */
export function projectGame(room: GameRecord, actor: GameActor): GameRecord {
  if (room.closed || normalizedStatus(room) === "ended") failure("Room is closed", "room_closed", 404);
  requirePlayer(room, actor);
  if (roomHasDepartedPlayer(room, actor.email)) failure("This operative left the mission", "room_departed", 403);
  return projectRoomForClient(room, actor);
}

/** Informational clock boundary; a paused/unstarted game has no running deadline. */
export function gameDeadline(room: GameRecord): number | null {
  if (normalizedStatus(room) !== "playing" || !clean(room.game_started_at) || clean(room.game_paused_at)) return null;
  return gameTimerDeadlineMilliseconds(room);
}

/**
 * Synchronous, transaction-local engine. The caller owns Auth, request receipts,
 * the room row lock, revision increment, and atomic persistence of every output.
 * Inputs are cloned; no global clock/random overrides, leases, network or SDK.
 */
export function reduceGame(input: GameInput): GameTransition {
  if (!Number.isFinite(input.now)) failure("Invalid server time", "invalid_server_time", 500);
  if (!input.actor?.id || !input.actor?.email) failure("Authentication required", "unauthenticated", 401);
  if (!input.payload || typeof input.payload !== "object" || Array.isArray(input.payload)) failure("Invalid payload", "invalid_payload", 400);
  const user = { ...input.actor, email: clean(input.actor.email).toLowerCase(), display_name: input.actor.display_name || input.actor.nickname || input.actor.full_name, avatar: input.actor.avatar || input.actor.avatar_url };
  const body = structuredClone(input.payload);
  // Private capture markers from the old transport are never caller authority.
  for (const key of Object.keys(body)) if (key.startsWith("__")) delete body[key];
  const action = clean(input.action);
  const at = new Date(input.now).toISOString();
  const uuid = input.uuid ?? (() => crypto.randomUUID());
  const random = input.random ?? secureRandom;
  const randomIndex = (upper: number): number => {
    const value = random();
    if (!Number.isInteger(upper) || upper < 1 || !Number.isFinite(value) || value < 0 || value >= 1) failure("Invalid server entropy", "invalid_server_random", 500);
    return Math.floor(value * upper);
  };
  let room: GameRecord = input.room ? structuredClone(input.room) : null;
  const history: GameRecord[] = [];
  const events: GameRecord[] = [];
  const patch = (value: GameRecord) => { room = { ...room, ...value }; };
  const emit = (type: string, id: string, extra: GameRecord = {}) => events.push({ event_id: id, type, room_id: room.id, match_id: clean(room.match_id), created_at: at, ...extra });
  const result = (): GameTransition => ({ room, ...(history.length ? { history } : {}), ...(events.length ? { events } : {}) });
  const close = () => {
    if (!room.closed) {
      patch({ status: "ended", closed: true, closed_at: at });
      emit("room_closed", `room-closed:${room.id}`, { recipient_user_ids: uniqueStrings(room.participant_user_ids) });
    }
  };
  const finish = (winner: string, terminalPatch: GameRecord = {}) => {
    if (normalizedStatus(room) === "finished") return;
    const intent = terminalIntentFromRoom(room) || buildTerminalIntent(room, winner, terminalPatch, at);
    patch({ ...terminalPatchFromIntent(intent), ...finishGamePauseTransitionPatch(room, intent.decided_at), terminal_intent: intent, status: "finished", winner: intent.winner, detective_vote_round_id: "", ready_players: [], game_finished_event_id: `game-finished:${intent.match_id}` });
    assertRankedTerminalRoom(room, room.winner);
    const spies = canonicalSpyEmails(room);
    for (const player of players(room)) {
      const isSpy = spies.includes(player.email);
      history.push({ match_id: intent.match_id, result_key: gameHistoryResultKey(intent.match_id, player.user_id), player_user_id: player.user_id, player_email: player.email, room_code: room.code, match_type: "online", ranked: spies.length === 1, role: isSpy ? "spy" : "detective", word: displayWord(room) || "CLASSIFIED", category: clean(room.category) || "CLASSIC", winner: room.winner, player_count: players(room).length, spy_count: spies.length, won: room.winner === "spy" ? isSpy : !isSpy });
    }
    const recipients = terminalOutboxCommitRecipientUserIDs(room);
    emit("game_finished", room.game_finished_event_id, { winner: room.winner, recipient_user_ids: recipients });
    // This certificate is valid only because the handler persists room/history/
    // outbox/receipt in the same transaction. Never persist the room alone.
    patch(terminalOutboxCommitPatch({ room, recipientUserIDs: recipients, committedAt: new Date(input.now) }));
  };
  const requireLive = () => {
    if (normalizedStatus(room) !== "playing") failure("Mission is not playing", "room_action_inactive");
  };
  const requireMatch = () => {
    if (!clean(room.match_id) || (clean(body.expected_match_id) && clean(body.expected_match_id) !== clean(room.match_id))) failure("This command belongs to another match", "room_match_generation_conflict");
  };

  if (action === "create_room") {
    if (room) failure("Room already exists", "room_exists");
    const player = { ...playerFromUser(user, body), membership_id: validatedMembershipGeneration(null, uuid) };
    room = {
      id: input.roomID || uuid(), code: input.roomCode || Array.from({ length: 6 }, () => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[randomIndex(32)]).join(""),
      host_email: user.email, status: "waiting", closed: false, players: [player], participant_user_ids: [user.id],
      game_mode: "questions", game_duration_seconds: 900, lobby_spy_count: 1, spies_know_each_other: false,
      spy_emails: [], spy_email: "", incompatible_player_emails: [], departed_player_emails: [],
      lobby_schema_version: 2, lobby_revision: 0, room_revision: 0,
      lobby_word_source: "none", lobby_source_pack_id: "", lobby_source_name: "", lobby_theme: "", lobby_category: "", lobby_word_count: 0, lobby_word_count_mode: "recommended", lobby_word_pool: [], lobby_last_mutation_id: "", lobby_last_mutation_fingerprint: "",
      replay_source_match_id: "", intro_started_at: null, game_started_at: null, game_paused_at: null, game_paused_total_seconds: 0,
      ready_players: [], cards_read: [], spectators: [], eliminated_emails: [], vote_requests: [], detective_votes: [],
      detective_vote_round_id: "", detective_vote_cancellation_event_id: "", detective_vote_cancellation_round_id: "", detective_vote_cancellation_present_at: "", detective_vote_cancellation_reason: "", winner: "", created_date: at,
    };
    return result();
  }
  if (!room) failure("Room not found", "room_not_found", 404);
  if (room.closed || normalizedStatus(room) === "ended") {
    requirePlayer(room, user);
    if (action === "close_room") { requireHost(room, user); return result(); }
    if (action === "leave_room") return result();
    failure("Room is closed", "room_closed", 404);
  }
  if (action === "leave_room" && (!playerInRoom(room, user.email) || roomHasDepartedPlayer(room, user.email))) return result();
  if (action !== "join_room") {
    requirePlayer(room, user);
    if (roomHasDepartedPlayer(room, user.email)) failure("This operative left the mission", "room_departed", 403);
    if (lobbySpyCount(room) > 1 && !playerSupportsMultiSpy(players(room).find((p) => p.email === user.email))) throw clientUpdateRequiredError();
  }
  if (["get_room", "get_active_room"].includes(action)) return result();
  if (action === "record_finished_online_game") return rejectRetiredResultRecording();
  if (body.expected_match_id && !["vote_play_again", "reset_room_for_replay"].includes(action) && clean(body.expected_match_id) !== clean(room.match_id)) failure("This command belongs to another match", "room_match_generation_conflict");
  if (body.expected_membership_id && ["toggle_ready", "leave_room", "close_room"].includes(action)) assertExpectedMembershipGeneration({ room, user, expected: body.expected_membership_id });
  if (["toggle_ready", "begin_ready_check"].includes(action) && body.expected_lobby_revision !== undefined && Number(body.expected_lobby_revision) !== Number(room.lobby_revision)) failure("Lobby settings changed", "lobby_revision_conflict");
  if (["advance_question", "advance_association", "start_association", "stop_association_spin", "mark_answer_heard", "continue_round"].includes(action)) {
    if (!Number.isSafeInteger(body.expected_revision) || body.expected_revision !== Number(room.room_revision)) failure("The game turn changed; refresh before continuing", "room_revision_conflict");
  }
  assertGameActionAllowedWhilePaused(room, action);
  if (action !== "cast_detective_vote") assertGameActionAllowedByDeadline(room, action, input.now);

  switch (action) {
    case "join_room": {
      const player = { ...playerFromUser(user, body), membership_id: validatedMembershipGeneration(body.join_membership_id, uuid) };
      const existing = players(room).find((p) => p.email === user.email);
      if (lobbySpyCount(room) > 1 && !playerSupportsMultiSpy(player)) throw clientUpdateRequiredError();
      if (roomHasDepartedPlayer(room, user.email) && normalizedStatus(room) !== "waiting") failure("Operative left this mission", "room_departed");
      if (!existing && normalizedStatus(room) !== "waiting") failure("Room no longer accepts players", "room_join_inactive");
      if (!existing && players(room).length >= 12) failure("Room is full", "room_full");
      if (existing) {
        const generation = playerMembershipGeneration(room, existing);
        if (player.membership_id !== generation && clean(body.expected_membership_id) !== generation) player.membership_id = generation;
      }
      const without = (values) => uniqueStrings(values).filter((email) => clean(email).toLowerCase() !== user.email);
      patch({ players: mergePlayers(players(room), player), participant_user_ids: uniqueStrings([...(room.participant_user_ids || []), user.id]), spectators: normalizedStatus(room) === "waiting" ? without(room.spectators) : room.spectators, eliminated_emails: normalizedStatus(room) === "waiting" ? without(room.eliminated_emails) : room.eliminated_emails, departed_player_emails: without(room.departed_player_emails), incompatible_player_emails: without(room.incompatible_player_emails) });
      break;
    }
    case "begin_ready_check":
      requireHost(room, user);
      if (normalizedStatus(room) !== "waiting") failure("Ready check requires lobby", "ready_check_inactive");
      if (players(room).length < 3) failure("Need at least 3 operatives", "not_enough_players", 400);
      validatedLobbySpyCount(lobbySpyCount(room), players(room).length); assertMultiSpyCapableRoster(room); assertAuthoritativeLobbyReady(room);
      patch({ status: "ready_voting", ready_players: [] }); break;
    case "return_to_waiting":
      requireHost(room, user);
      if (normalizedStatus(room) !== "ready_voting") failure("Ready check is not active", "ready_check_inactive");
      patch({ status: "waiting", ready_players: [] }); break;
    case "toggle_ready": {
      if (normalizedStatus(room) !== "ready_voting") failure("Ready check is not active", "ready_check_inactive");
      const ready = readyPlayers(room);
      patch({ ready_players: ready.includes(user.email) ? ready.filter((email) => email !== user.email) : [...ready, user.email] }); break;
    }
    case "update_game_mode":
      assertLobbySettingsAccess(room, user, "mode"); patch(gameModePatch(room, validatedGameMode(body.mode))); break;
    case "update_game_duration":
      assertLobbySettingsAccess(room, user, "duration"); patch(gameDurationPatch(room, validatedGameDuration(body.game_duration_seconds))); break;
    case "update_lobby_state": {
      assertLobbySettingsAccess(room, user, "lobby");
      const state = body.state && typeof body.state === "object" && !Array.isArray(body.state) ? body.state : {};
      const requested = validateLobbyMutation({ mutation_id: body.mutation_id, expected_revision: body.expected_revision, state: { ...state, lobby_spy_count: state.lobby_spy_count ?? lobbySpyCount(room), spies_know_each_other: state.spies_know_each_other ?? spiesKnowEachOther(room) } });
      const roster = compatibleRosterForSpyCount(room, requested.state.lobby_spy_count);
      const effective = roster.effectiveSpyCount === requested.state.lobby_spy_count ? requested : validateLobbyMutation({ mutation_id: body.mutation_id, expected_revision: body.expected_revision, state: { ...requested.state, lobby_spy_count: roster.effectiveSpyCount } });
      const removed = new Set(roster.removedEmails.map((e) => e.toLowerCase()));
      const removedIDs = new Set(players(room).filter((p) => removed.has(p.email.toLowerCase())).map((p) => p.user_id));
      patch({ ...lobbyMutationPatch(room, effective), ...(removed.size ? { players: roster.players, participant_user_ids: uniqueStrings(room.participant_user_ids).filter((id) => !removedIDs.has(id)), ready_players: readyPlayers(room).filter((e) => !removed.has(e.toLowerCase())), incompatible_player_emails: uniqueStrings([...(room.incompatible_player_emails || []), ...roster.removedEmails]).slice(-12) } : {}) }); break;
    }
    case "kick_player": {
      const transition = lobbyKickTransition(room, user.email, body);
      if (body.expected_target_membership_id && clean(body.expected_target_membership_id) !== playerMembershipGeneration(room, transition.removedPlayer)) failure("Kick target rejoined", "kick_target_membership_conflict");
      patch({ ...transition.patch, ...lobbyMembershipClampPatch(room, transition.patch.players.length) }); break;
    }
    case "arm_roulette": {
      requireHost(room, user);
      if (normalizedStatus(room) === "roulette" && canonicalSpyEmails(room).length) { serverSpyAssignment(room, randomIndex); break; }
      if (!["waiting", "ready_voting"].includes(normalizedStatus(room))) failure("Mission requires lobby", "game_start_inactive");
      if (players(room).length < 3) failure("Need at least 3 operatives", "not_enough_players", 400);
      validatedLobbySpyCount(lobbySpyCount(room), players(room).length); assertMultiSpyCapableRoster(room); assertAuthoritativeLobbyReady(room);
      if (normalizedStatus(room) === "ready_voting" && !players(room).every((p) => readyPlayers(room).includes(p.email))) failure("All operatives must be ready", "players_not_ready");
      if (!Number.isInteger(body.expected_lobby_revision) || body.expected_lobby_revision !== Number(room.lobby_revision)) failure("Lobby settings changed", "lobby_revision_conflict");
      const state = lobbyStateFromRoom(room), pool = selectedAuthoritativeLobbyWordPool(room);
      if (pool.length < 2) failure("Choose at least two enabled words", "lobby_word_pool_incomplete");
      const order = [...players(room)];
      for (let i = order.length - 1; i > 0; i--) { const j = randomIndex(i + 1); [order[i], order[j]] = [order[j], order[i]]; }
      const word = pool[randomIndex(pool.length)].word;
      const plan = { word, secret_word: word, word_pool: pool, category: state.lobby_category || state.lobby_source_name || "CLASSIC", game_mode: state.game_mode, game_duration_seconds: state.game_duration_seconds, current_asker_email: order[0].email, current_answerer_email: order[1].email };
      const assignment = serverSpyAssignment(room, randomIndex);
      const question = plan.game_mode === "questions" ? initialQuestionTurn({ activePlayers: players(room), currentAskerEmail: plan.current_asker_email, currentAnswererEmail: plan.current_answerer_email, randomIndex }) : null;
      patch({ ...validatedStartPatch(room, plan, assignment), ...(question ? { current_answer: encodeQuestionTurnOrderState(question.state) } : {}), ...serverIntroStartPatch(at), status: "roulette", roulette_target_email: plan.current_asker_email, game_started_at: null, game_paused_at: null, game_paused_total_seconds: 0 }); break;
    }
    case "complete_game_start":
      if (normalizedStatus(room) === "playing" && room.match_id && room.game_started_event_id) break;
      assertIntroCompletionAccess(room, user.email, input.now);
      patch({ status: "playing", match_id: uuid(), terminal_intent: null, intro_started_at: introStartedAtForCompletion(room, at), game_started_at: null, game_paused_at: null, game_paused_total_seconds: 0, game_started_event_id: uuid(), game_finished_event_id: "", ready_players: [], cards_read: [], vote_requests: [], detective_votes: [], detective_vote_round_id: "", detective_vote_cancellation_event_id: "", detective_vote_cancellation_round_id: "", detective_vote_cancellation_present_at: "", detective_vote_cancellation_reason: "", spectators: [], eliminated_emails: [], winner: "" });
      emit("game_started", room.game_started_event_id, { recipient_user_ids: uniqueStrings(room.participant_user_ids) }); break;
    case "mark_role_card_read":
      patch(roleCardReadTransitionPatch(room, user.email, at));
      if (players(room).every((p) => cardsRead(room).includes(p.email)) && shouldSpyWin(room)) finish("spy"); break;
    case "pause_game": patch(pauseGameTransitionPatch(room, user.email, at)); break;
    case "resume_game": patch(resumeGameTransitionPatch(room, user.email, at)); break;
    case "advance_question":
    case "mark_answer_heard": {
      requireLive(); assertRoundActionMode(room, "questions"); assertActiveRoundActor(activePlayers(room), user.email);
      if (clean(room.current_asker_email) !== user.email) failure("Only current asker can advance", "round_actor_required", 403);
      if (action === "mark_answer_heard" && room.question_phase !== "asking") failure("No answer awaiting confirmation", "question_phase_conflict");
      const next = Number(room.questions_in_round || 0) + 1;
      if (next >= 8) patch({ question_phase: "results", countdown_started_at: null });
      else { const turn = advanceQuestionTurn({ activePlayers: activePlayers(room), rawState: room.current_answer, currentAskerEmail: room.current_asker_email, currentAnswererEmail: room.current_answerer_email, randomIndex }); patch({ current_asker_email: turn.askerEmail, current_answerer_email: turn.answererEmail, questions_in_round: next, current_answer: encodeQuestionTurnOrderState(turn.state), question_phase: "asking", countdown_started_at: null }); }
      break;
    }
    case "continue_round": {
      requireLive(); assertRoundActionMode(room, "questions"); assertActiveRoundActor(activePlayers(room), user.email);
      if (room.question_phase !== "results") failure("Round results are not active", "question_phase_conflict");
      const turn = advanceQuestionTurn({ activePlayers: activePlayers(room), rawState: room.current_answer, currentAskerEmail: room.current_asker_email, currentAnswererEmail: room.current_answerer_email, randomIndex });
      patch({ current_asker_email: turn.askerEmail, current_answerer_email: turn.answererEmail, current_answer: encodeQuestionTurnOrderState(turn.state), question_phase: "asking", round_number: nextRoundNumber(room.round_number), questions_in_round: 0, current_answer_feedback: null, player_feedback: [] }); break;
    }
    case "start_association": {
      requireLive(); requireHost(room, user); assertRoundActionMode(room, "associations");
      const active = activePlayers(room);
      if (active.some((p) => p.email === room.current_asker_email)) { const state = reconcileAssociationTurnState({ activePlayers: active, rawState: room.current_answer, currentSpeakerEmail: room.current_asker_email, random }); patch({ current_answer: encodeAssociationTurnState(state), question_phase: "asking" }); }
      else { const next = initialAssociationTurn({ activePlayers: active, random }); patch({ current_asker_email: next.speakerEmail, current_answer: encodeAssociationTurnState(next.state), question_phase: "asking" }); }
      break;
    }
    case "advance_association": {
      requireLive(); assertRoundActionMode(room, "associations"); assertActiveRoundActor(activePlayers(room), user.email);
      if (room.current_asker_email !== user.email) failure("Only current speaker can advance", "round_actor_required", 403);
      const next = advanceAssociationTurn({ activePlayers: activePlayers(room), currentSpeakerEmail: room.current_asker_email, rawState: room.current_answer, random });
      patch({ round_number: Number(room.round_number || 1) + (next.startsNewRound ? 1 : 0), current_asker_email: next.speakerEmail, current_answer: encodeAssociationTurnState(next.state), question_phase: "asking" }); break;
    }
    case "stop_association_spin": {
      requireLive(); assertRoundActionMode(room, "associations"); assertActiveRoundActor(activePlayers(room), user.email);
      const state = reconcileAssociationTurnState({ activePlayers: activePlayers(room), rawState: room.current_answer, currentSpeakerEmail: room.current_asker_email, random });
      patch({ current_answer: encodeAssociationTurnState({ ...state, spinning: false }) }); break;
    }
    case "request_vote": {
      requireLive(); requireMatch(); assertActiveRoundActor(activePlayers(room), user.email);
      if (shouldSpyWin(room)) { finish("spy"); break; }
      patch(detectiveVoteRequestTransition(activePlayers(room).map((p) => p.email), voteRequests(room), user.email, detectiveVoteRoundID(room), uuid).patch); break;
    }
    case "cast_detective_vote": {
      requireLive(); requireMatch();
      if (hasGameTimerElapsed(room, input.now)) { patch({ detective_votes: [], vote_requests: [], detective_vote_round_id: "" }); finish(deriveExpiredGameWinner(room, input.now)); break; }
      if (shouldSpyWin(room)) { finish("spy"); break; }
      if (!detectiveVotingActive(room)) failure("Detective voting is no longer active", "detective_vote_inactive");
      const explicit = explicitExpectedVoteRoundID(body);
      const binding = bindDetectiveVoteRoundIdentity(detectiveVoteRoundID(room), explicit, detectiveVoteRoundID(room) || uuid(), true);
      const event = scheduledDetectiveVoteCancellationEvent({ eventID: uuid(), roundID: binding.roundID }, input.now);
      const resolution = resolvedDetectiveVoteCastTransition(activePlayers(room).map((p) => p.email), voteRequests(room), detectiveVotes(room), user.email, clean(body.target_email), canonicalSpyEmails(room), spectators(room), room.eliminated_emails || [], event);
      let next = { ...resolution.patch };
      if (resolution.decision.outcome === "eject" && !resolution.terminal_winner) {
        const changed = { ...room, ...next };
        if (room.game_mode === "associations") { const turn = associationRosterChangePatch({ activePlayers: activePlayers(changed), currentSpeakerEmail: room.current_asker_email, currentAnswererEmail: room.current_answerer_email, rawState: room.current_answer, random }); Object.assign(next, turn.patch); if (turn.startsNewRound) next.round_number = Number(room.round_number || 1) + 1; }
        else Object.assign(next, questionRosterChangePatch({ activePlayers: activePlayers(changed), currentAskerEmail: room.current_asker_email, currentAnswererEmail: room.current_answerer_email, questionPhase: room.question_phase, rawState: room.current_answer, randomIndex }));
      }
      if (binding.initialize && resolution.decision.outcome === "continue" && !Object.hasOwn(next, "detective_vote_round_id")) next.detective_vote_round_id = binding.roundID;
      patch(next);
      if (resolution.terminal_winner) finish(resolution.terminal_winner, resolution.terminal_patch); break;
    }
    case "submit_spy_guess":
      requireLive(); requireMatch(); assertActiveSpyGuesser(room, user.email);
      { const guess = requireSafeCommunityText(clean(body.guess), "Spy guess"); finish(spyGuessWinner(displayWord(room), guess), { spy_guess: guess }); } break;
    case "finalize_expired_room":
    case "finish_room":
      if (action === "finish_room") requireHost(room, user);
      assertExpectedTimerFinalizationScope(room, body);
      if (normalizedStatus(room) !== "finished") finish(deriveExpiredGameWinner(room, input.now)); break;
    case "vote_return_to_lobby":
      requireHost(room, user); requireMatch(); patch(activeGameLobbyReturnTransition(room, user.email, body.return_to_lobby_vote).patch); break;
    case "vote_play_again": {
      const source = clean(body.expected_match_id) || (["roulette", "playing"].includes(normalizedStatus(room)) ? room.replay_source_match_id : replaySourceMatchID(room));
      if (replayAutoStartAlreadyComplete(room, source)) break;
      assertExpectedReplaySourceMatch(room, source);
      const vote = replayVoteTransition(room, user.email); patch(vote.patch);
      if (vote.unanimous) patch(replayAutoStartPatch(room, { expectedSourceMatchID: source, startedAt: at, randomIndex })); break;
    }
    case "reset_room_for_replay": patch(replayResetPatch(room, user, body)); break;
    case "return_finished_room_to_lobby":
      requireHost(room, user);
      if (normalizedStatus(room) !== "waiting" || room.match_id) patch(replayResetPatch(room, user, body, false)); break;
    case "close_room":
      requireHost(room, user); assertExpectedMembershipGeneration({ room, user, expected: body.expected_membership_id, expectedRevision: body.expected_revision }); close(); break;
    case "leave_room": {
      assertExpectedMembershipGeneration({ room, user, expected: body.expected_membership_id, expectedRevision: body.expected_revision });
      if (!hostDepartureUsesMembershipTransition(room, user.email)) { close(); break; }
      const votes = detectiveVoteLeavePatch(activePlayers(room).map((p) => p.email), voteRequests(room), detectiveVotes(room), user.email, detectiveVoteRoundID(room));
      if (normalizedStatus(room) === "playing" && clean(room.game_started_at)) {
        const departure = activeDepartureTransition(room, user.email, { random, randomIndex });
        patch({ ...departure.patch, ...votes, player_feedback: (room.player_feedback || []).filter((p) => p.email !== user.email) });
        if (departure.terminalWinner) finish(departure.terminalWinner);
      } else {
        const next = players(room).filter((p) => p.email !== user.email);
        const without = (values) => uniqueStrings(values).filter((e) => e.toLowerCase() !== user.email);
        patch({ players: next, ...(room.host_email === user.email ? { host_email: next[0]?.email || "" } : {}), participant_user_ids: uniqueStrings(room.participant_user_ids).filter((id) => id !== user.id), spectators: without(room.spectators), ready_players: without(room.ready_players), cards_read: without(room.cards_read), eliminated_emails: without(room.eliminated_emails), ...votes, player_feedback: (room.player_feedback || []).filter((p) => p.email !== user.email), ...lobbyMembershipClampPatch(room, next.length) });
        patch(preTimerMembershipTransitionPatch(room, at));
        if (!next.length) close();
      }
      break;
    }
    default: failure("Unsupported game command", "unsupported_action", 400);
  }
  return result();
}

// @ts-nocheck -- Legacy dynamic Base44 room state is validated at runtime.
import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  requireSafeCommunityText,
  safeCommunityAvatar,
  safeCommunityDisplayName,
} from "./content-safety.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  assertExactRoomLeaseCoverage,
  assertRoomWriteLeases,
  assertRoomWriterLeaseForUser,
  retryRoomMembershipChangeBeforeAction,
  withRoomWriteLeases,
} from "./room-write-lifecycle.ts";
import { projectRoomForClient } from "./room-projection.ts";
import { loadLeaderboard } from "./leaderboard.ts";
import {
  assertIntroCompletionAccess,
  assertRankedTerminalRoom,
  assertServerRankedFinishSource,
  buildTerminalIntent,
  deriveExpiredGameWinner,
  historyRecordsForMatch,
  introStartedAtForCompletion,
  preTimerMembershipTransitionPatch,
  rankedMatchIdentity,
  rejectRetiredResultRecording,
  roleCardReadTransitionPatch,
  serverIntroStartPatch,
  terminalIntentFromRoom,
  terminalPatchFromIntent,
} from "./room-result-policy.ts";
import {
  assertGameActionAllowedByDeadline,
  assertGameActionAllowedWhilePaused,
  finishGamePauseTransitionPatch,
  pauseGameTransitionPatch,
  resumeGameTransitionPatch,
} from "./game-timer-policy.ts";
import { resolveRoomActionUser } from "./request-auth.ts";
import { commitGamePushEvents, enqueueGamePushEvents } from "./push-events.ts";
import { nextRoundNumber } from "./game-round.ts";
import { internalPushSecret } from "./internal-push.ts";
import {
  assertLobbySettingsAccess,
  deleteRoomAndVerify,
  gameDurationPatch,
  gameModePatch,
  leaveAlreadyComplete,
  roomHasGameDuration,
  roomHasGameMode,
  roomHasParticipantIdentity,
  validatedGameDuration,
  validatedGameMode,
} from "./room-interaction-safety.ts";
import { hasValidEnabledStartWordPool } from "./start-word-pool-policy.ts";
import {
  assertAuthoritativeLobbyReady,
  authoritativeStartPayload,
  hasAuthoritativeLobbyState,
  lobbyMutationPatch,
  roomHasLobbyMutation,
  validateLobbyMutation,
} from "./lobby-state-policy.ts";
import { fanoutGameRoomSignalsBestEffort } from "./game-room-signal.ts";

function jsonError(message, status = 400) {
  return Response.json({ error: message }, { status });
}

function clean(value) {
  return String(value || "").trim();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
  return {
    user_id: clean(user.id),
    email: user.email,
    name: safeCommunityDisplayName(
      clean(incoming.name) || clean(user.display_name) || clean(user.full_name),
    ),
    avatar: safeCommunityAvatar(clean(incoming.avatar) || clean(user.avatar)),
  };
}

function roomForClient(room, viewer) {
  return projectRoomForClient(room, viewer);
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
  const spyEmail = clean(room?.spy_email);
  if (!spyEmail) return false;

  const active = activePlayers(room);
  if (!active.some((player) => player.email === spyEmail)) return false;

  const detectiveCount =
    active.filter((player) => player.email !== spyEmail).length;
  return detectiveCount <= 1;
}

function parseAssociationState(raw) {
  try {
    const parsed = JSON.parse(String(raw || ""));
    return {
      spoken: Array.isArray(parsed?.spoken) ? parsed.spoken : [],
      spinning: Boolean(parsed?.spinning),
    };
  } catch {
    return { spoken: [], spinning: false };
  }
}

function encodeAssociationState(state) {
  return JSON.stringify({
    spoken: Array.isArray(state?.spoken) ? state.spoken : [],
    spinning: Boolean(state?.spinning),
  });
}

async function fetchRoom(base44, roomId) {
  const rooms = await base44.asServiceRole.entities.GameRoom.filter({
    id: roomId,
  });
  return rooms?.[0] || null;
}

async function fetchRoomByCode(base44, roomCode) {
  const code = clean(roomCode).toUpperCase();
  if (!code) return null;
  const rooms = await base44.asServiceRole.entities.GameRoom.filter({ code });
  return rooms?.[0] || null;
}

async function assertRoomPersistenceBoundary(base44) {
  const context = base44.__spyclashRoomWriteLeaseContext;
  if (!context) {
    throw Object.assign(
      new Error("Room persistence requires a lifecycle lease."),
      {
        status: 503,
        code: "missing_lifecycle_lease",
      },
    );
  }
  await assertRoomWriteLeases(context);
}

async function assertRoomHistoryPersistenceBoundary(base44, userID) {
  const context = base44.__spyclashRoomWriteLeaseContext;
  if (!context) {
    throw Object.assign(
      new Error("Game history persistence requires a lifecycle lease."),
      { status: 503, code: "missing_lifecycle_lease" },
    );
  }
  await assertRoomWriterLeaseForUser(context, userID);
}

function pendingTerminalIntent(room) {
  const intent = terminalIntentFromRoom(room);
  return intent && normalizedStatus(room) !== "finished" ? intent : null;
}

function assertRoomMutationOpen(room, allowPendingTerminal = false) {
  if (!allowPendingTerminal && pendingTerminalIntent(room)) {
    throw Object.assign(
      new Error(
        "The room has a terminal decision pending reconciliation. Retry the action.",
      ),
      { status: 409, code: "terminal_reconciliation_pending" },
    );
  }
}

async function updateRoom(base44, room, data, options = {}) {
  await assertRoomPersistenceBoundary(base44);
  const latest = await fetchRoom(base44, room.id);
  if (!latest) {
    throw Object.assign(new Error("Room not found"), { status: 404 });
  }
  assertRoomMutationOpen(latest, options.allowPendingTerminal === true);

  // Every room mutation already holds writer leases for the complete,
  // re-fetched participant set. Base44's system `updated_date` cannot be used
  // as an updateMany CAS predicate: production returns zero updated rows even
  // when the record has not changed. That made the mandatory legacy
  // participant-id backfill fail before mode, duration, or leave could run.
  // Serialize with the verified leases, write by stable entity id, then
  // re-read the persisted record for the next transition.
  await base44.asServiceRole.entities.GameRoom.update(latest.id, data);
  const persisted = await fetchRoom(base44, latest.id);
  if (!persisted) {
    throw Object.assign(new Error("Room not found after update"), {
      status: 404,
      code: "room_write_missing",
    });
  }
  return persisted;
}

async function updateRoomWithRetry(
  base44,
  room,
  buildPatch,
  verify,
  attempts = 6,
  options = {},
) {
  let latest = room;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    latest = await fetchRoom(base44, latest.id);
    if (!latest) {
      throw Object.assign(new Error("Room not found"), { status: 404 });
    }
    assertRoomMutationOpen(latest, options.allowPendingTerminal === true);

    const patch = buildPatch(latest) || {};
    if (!Object.keys(patch).length) {
      if (!verify || verify(latest)) return latest;
      await delay(20 + attempt * 35);
      continue;
    }

    await assertRoomPersistenceBoundary(base44);
    await base44.asServiceRole.entities.GameRoom.update(latest.id, patch);
    latest = await fetchRoom(base44, latest.id);
    if (!latest) {
      throw Object.assign(new Error("Room not found"), { status: 404 });
    }

    if (!verify || verify(latest)) {
      return latest;
    }

    await delay(20 + attempt * 35);
  }

  throw Object.assign(
    new Error("The room update could not be verified; retry the action."),
    { status: 409, code: "room_write_unverified" },
  );
}

async function endRoomLiveActivitiesBeforeDelete(base44, room) {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  if (!roomID || !matchID) return;
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!internalSecret) {
    throw Object.assign(
      new Error("Live Activity end delivery is not configured."),
      { status: 503, code: "push_internal_secret_invalid" },
    );
  }
  try {
    await base44.asServiceRole.functions.invoke("pushNotificationAction", {
      action: "end_room_live_activities",
      room_id: roomID,
      match_id: matchID,
      internal_secret: internalSecret,
    });
  } catch (error) {
    console.error(
      "room Live Activity end deferred",
      error instanceof Error ? error.message : error,
    );
    throw Object.assign(
      new Error("Could not queue the Lock Screen session end; retry."),
      { status: 503, code: "live_activity_end_unavailable" },
    );
  }
}

async function deleteRoom(base44, room) {
  await assertRoomPersistenceBoundary(base44);
  const latest = await fetchRoom(base44, room.id);
  if (!latest) return { success: true };
  assertRoomMutationOpen(latest);
  // The internal receiver durably marks every exact per-activity token before
  // the ephemeral room is removed. If that boundary cannot be confirmed, keep
  // the room so a caller retry can still produce a real ActivityKit `end`.
  await endRoomLiveActivitiesBeforeDelete(base44, latest);
  await assertRoomPersistenceBoundary(base44);
  await deleteRoomAndVerify({
    roomID: latest.id,
    deleteByID: (roomID) =>
      base44.asServiceRole.entities.GameRoom.delete(roomID),
    fetchByID: (roomID) => fetchRoom(base44, roomID),
    delay,
  });
  return { success: true };
}

function randomRoomCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return [...bytes].map((byte) => alphabet[byte % alphabet.length]).join("");
}

async function generateUniqueRoomCode(base44) {
  for (let attempt = 0; attempt < 16; attempt += 1) {
    const code = randomRoomCode();
    const existing = await base44.asServiceRole.entities.GameRoom.filter({
      code,
    });
    if (!existing?.length) {
      return code;
    }
  }

  throw Object.assign(new Error("Unable to generate room code"), {
    status: 503,
  });
}

async function archiveRoomResult(base44, room, winner) {
  const roomPlayers = players(room);
  assertRankedTerminalRoom(room, winner);
  const matchIdentity = rankedMatchIdentity(room);

  const queried = await base44.asServiceRole.entities.GameHistory.filter({
    match_id: matchIdentity.id,
  });
  const existing = historyRecordsForMatch(queried || [], room);
  const archivedEmails = new Set(
    (existing || []).map((record) => clean(record?.player_email)).filter(
      Boolean,
    ),
  );
  const archivedUserIDs = new Set(
    (existing || []).map((record) => clean(record?.player_user_id)).filter(
      Boolean,
    ),
  );

  for (const player of roomPlayers) {
    if (
      (clean(player.user_id) && archivedUserIDs.has(clean(player.user_id))) ||
      archivedEmails.has(player.email)
    ) continue;

    const isSpy = player.email === room.spy_email;
    const won = winner === "spy" ? isSpy : !isSpy;
    // Re-prove the exact player's live lifecycle lease immediately before
    // creating their retained history row. This prevents a deleteAccount race
    // from recreating raw identity after that player's cleanup completed.
    await assertRoomHistoryPersistenceBoundary(base44, player.user_id);
    await base44.asServiceRole.entities.GameHistory.create({
      match_id: matchIdentity.id,
      player_user_id: clean(player.user_id),
      player_email: player.email,
      room_code: room.code,
      match_type: "online",
      ranked: true,
      role: isSpy ? "spy" : "detective",
      word: displayWord(room) || "CLASSIFIED",
      category: clean(room.category) || "CLASSIC",
      winner,
      player_count: roomPlayers.length,
      won,
    });
  }
}

async function claimTerminalIntent(
  base44,
  room,
  requestedWinner,
  requestedPatch = {},
  attempts = 8,
) {
  let latest = room;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    latest = await fetchRoom(base44, latest.id);
    if (!latest) {
      throw Object.assign(new Error("Room not found"), { status: 404 });
    }

    const existing = terminalIntentFromRoom(latest);
    if (existing) return { room: latest, intent: existing };

    assertServerRankedFinishSource(latest);
    const intent = buildTerminalIntent(
      latest,
      requestedWinner,
      requestedPatch,
    );
    await assertRoomPersistenceBoundary(base44);
    await base44.asServiceRole.entities.GameRoom.update(latest.id, {
      terminal_intent: intent,
    });
    const claimed = await fetchRoom(base44, latest.id);
    const persisted = terminalIntentFromRoom(claimed);
    if (!claimed || !persisted) {
      throw Object.assign(
        new Error("The terminal decision could not be confirmed."),
        { status: 503, code: "terminal_intent_unconfirmed" },
      );
    }
    return { room: claimed, intent: persisted };
  }

  throw Object.assign(
    new Error("The terminal decision raced with another room update."),
    { status: 409, code: "terminal_intent_conflict" },
  );
}

async function finishRoom(base44, room, winner, terminalPatch = {}) {
  assertServerRankedFinishSource(room);
  const claimed = await claimTerminalIntent(
    base44,
    room,
    winner,
    terminalPatch,
  );
  const persistedPatch = terminalPatchFromIntent(claimed.intent);
  const finishedPausePatch = finishGamePauseTransitionPatch(
    claimed.room,
    claimed.intent.decided_at,
  );
  const finishedEventID = `game-finished:${clean(claimed.intent.match_id)}`;
  await enqueueGamePushEvents({
    base44,
    room: claimed.room,
    eventType: "game_finished",
    sourceEventID: finishedEventID,
    matchID: clean(claimed.intent.match_id),
    persist: async (writer) => {
      await assertRoomPersistenceBoundary(base44);
      return await writer();
    },
  });
  const terminal = {
    ...claimed.room,
    ...persistedPatch,
    ...finishedPausePatch,
    status: "finished",
    winner: claimed.intent.winner,
    game_finished_event_id: finishedEventID,
  };
  // The immutable CAS-claimed terminal intent is persisted first. A retry can
  // only reconcile that same winner/payload, so history and room state cannot
  // diverge even if either write phase is interrupted.
  await archiveRoomResult(base44, terminal, claimed.intent.winner);
  const finished = await updateRoomWithRetry(
    base44,
    claimed.room,
    (latest) => {
      const intent = terminalIntentFromRoom(latest);
      if (!intent || intent.match_id !== claimed.intent.match_id) {
        throw Object.assign(
          new Error("The terminal decision changed during reconciliation."),
          { status: 409, code: "terminal_intent_changed" },
        );
      }
      const pausePatch = finishGamePauseTransitionPatch(
        latest,
        intent.decided_at,
      );
      if (normalizedStatus(latest) === "finished") {
        if (clean(latest.winner) !== intent.winner) {
          throw Object.assign(
            new Error("The finished room conflicts with its terminal intent."),
            { status: 409, code: "terminal_state_conflict" },
          );
        }
        return {
          ...pausePatch,
          ...(clean(latest.game_finished_event_id) === finishedEventID
            ? {}
            : { game_finished_event_id: finishedEventID }),
        };
      }
      return {
        ...terminalPatchFromIntent(intent),
        ...pausePatch,
        status: "finished",
        winner: intent.winner,
        game_finished_event_id: finishedEventID,
      };
    },
    (latest) =>
      normalizedStatus(latest) === "finished" &&
      clean(latest.winner) === claimed.intent.winner,
    6,
    { allowPendingTerminal: true },
  );
  const committed = await commitGamePushEvents({
    store: base44.asServiceRole.entities.PushNotificationEvent,
    persist: async (writer) => {
      await assertRoomPersistenceBoundary(base44);
      return await writer();
    },
    eventType: "game_finished",
    sourceEventID: finishedEventID,
  });
  const expectedInboxRecipients = uniqueStrings([
    ...(finished.participant_user_ids || []),
    ...players(finished).map((player) => player.user_id),
  ]).length;
  if (committed < expectedInboxRecipients) {
    throw Object.assign(new Error("Game finish inbox commit failed"), {
      status: 503,
    });
  }
  return finished;
}

async function createRoom(base44, user, body) {
  const player = playerFromUser(user, body);
  const code = await generateUniqueRoomCode(base44);

  await assertRoomPersistenceBoundary(base44);
  const created = await base44.asServiceRole.entities.GameRoom.create({
    code,
    host_email: user.email,
    status: "waiting",
    players: [player],
    participant_user_ids: [clean(user.id)],
    game_mode: "questions",
    game_duration_seconds: 900,
    lobby_schema_version: 1,
    lobby_revision: 0,
    lobby_word_source: "none",
    lobby_source_pack_id: "",
    lobby_source_name: "",
    lobby_theme: "",
    lobby_category: "",
    lobby_word_count: 0,
    lobby_word_count_mode: "recommended",
    lobby_word_pool: [],
    lobby_last_mutation_id: "",
    lobby_last_mutation_fingerprint: "",
    intro_started_at: null,
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    ready_players: [],
    winner: "",
  });
  return created;
}

async function joinRoom(base44, room, user, body) {
  const player = playerFromUser(user, body);
  const alreadyJoined = playerInRoom(room, user.email);
  if (!alreadyJoined && normalizedStatus(room) !== "waiting") {
    throw Object.assign(new Error("Room is no longer accepting operatives"), {
      status: 409,
    });
  }
  if (!alreadyJoined && players(room).length >= 12) {
    throw Object.assign(new Error("Room is full"), { status: 409 });
  }
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      if (playerInRoom(latest, user.email)) {
        const current = players(latest).find((candidate) =>
          candidate.email === user.email
        );
        const participantIDs = uniqueStrings([
          ...(latest.participant_user_ids || []),
          user.id,
        ]);
        if (
          clean(current?.user_id) === clean(user.id) &&
          clean(current?.name) === clean(player.name) &&
          clean(current?.avatar) === clean(player.avatar) &&
          participantIDs.length === (latest.participant_user_ids || []).length
        ) return {};
        return {
          players: mergePlayers(players(latest), player),
          participant_user_ids: participantIDs,
        };
      }
      if (
        normalizedStatus(latest) !== "waiting" || players(latest).length >= 12
      ) {
        throw Object.assign(
          new Error("Room is no longer accepting operatives"),
          { status: 409 },
        );
      }
      return {
        players: mergePlayers(players(latest), player),
        participant_user_ids: uniqueStrings([
          ...(latest.participant_user_ids || []),
          user.id,
        ]),
      };
    },
    // The player object is the authoritative membership record. The mirrored
    // participant_user_ids field is only an indexed lookup aid and can lag or
    // be omitted by field-level schema rules. Requiring both made a successful
    // player write surface as a false 409 on production.
    (latest) => roomHasParticipantIdentity(latest, user),
  );
}

async function beginReadyCheck(base44, room, user) {
  requireHost(room, user);
  if (normalizedStatus(room) !== "waiting") {
    throw Object.assign(
      new Error("Ready check can only start from the lobby"),
      { status: 409 },
    );
  }
  if (players(room).length < 3) {
    throw Object.assign(new Error("Need at least 3 operatives"), {
      status: 400,
    });
  }
  assertAuthoritativeLobbyReady(room);
  return await updateRoom(base44, room, {
    status: "ready_voting",
    ready_players: [],
  });
}

async function returnToWaiting(base44, room, user) {
  requireHost(room, user);
  if (normalizedStatus(room) !== "ready_voting") {
    throw Object.assign(new Error("Room is not in ready check"), {
      status: 409,
    });
  }
  return await updateRoom(base44, room, {
    status: "waiting",
    ready_players: [],
  });
}

async function toggleReady(base44, room, user) {
  requirePlayer(room, user);
  if (normalizedStatus(room) !== "ready_voting") {
    throw Object.assign(new Error("Ready check is not active"), {
      status: 409,
    });
  }
  const shouldBeReady = !readyPlayers(room).includes(user.email);

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const ready = readyPlayers(latest);
      const nextReady = shouldBeReady
        ? uniqueStrings([...ready, user.email])
        : ready.filter((email) => email !== user.email);
      return { ready_players: nextReady };
    },
    (latest) => readyPlayers(latest).includes(user.email) === shouldBeReady,
  );
}

async function votePlayAgain(base44, room, user) {
  requirePlayer(room, user);
  if (normalizedStatus(room) !== "finished") {
    throw Object.assign(new Error("Replay voting is not active"), {
      status: 409,
      code: "replay_vote_inactive",
    });
  }
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      if (normalizedStatus(latest) !== "finished") {
        throw Object.assign(new Error("Replay voting is not active"), {
          status: 409,
          code: "replay_vote_inactive",
        });
      }
      const ready = readyPlayers(latest);
      return ready.includes(user.email)
        ? {}
        : { ready_players: uniqueStrings([...ready, user.email]) };
    },
    (latest) => readyPlayers(latest).includes(user.email),
  );
}

async function resetRoomForReplay(base44, room, user, body) {
  requireHost(room, user);
  if (normalizedStatus(room) !== "finished") {
    throw Object.assign(
      new Error("A replay can start only after the match is fully finished."),
      { status: 409, code: "replay_before_terminal_commit" },
    );
  }
  const legacyLobbySettings = hasAuthoritativeLobbyState(room) ? {} : {
    game_mode: clean(body?.game_mode) || clean(room.game_mode) || "questions",
    game_duration_seconds: Number(
      body?.game_duration_seconds || room.game_duration_seconds || 900,
    ),
  };
  return await updateRoom(base44, room, {
    status: "waiting",
    spy_email: "",
    secret_word: "",
    word: "",
    category: "",
    spy_guess: "",
    detective_votes: [],
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
    match_id: "",
    terminal_intent: null,
    intro_started_at: null,
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    game_started_event_id: "",
    game_finished_event_id: "",
    countdown_started_at: null,
    ...legacyLobbySettings,
  });
}

async function updateGameMode(base44, room, user, body) {
  assertLobbySettingsAccess(room, user, "mode");
  const mode = validatedGameMode(body?.mode);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      assertLobbySettingsAccess(latest, user, "mode");
      return gameModePatch(latest, mode);
    },
    (latest) => roomHasGameMode(latest, mode),
  );
}

async function updateGameDuration(base44, room, user, body) {
  assertLobbySettingsAccess(room, user, "duration");
  const durationSeconds = validatedGameDuration(body?.game_duration_seconds);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      assertLobbySettingsAccess(latest, user, "duration");
      return gameDurationPatch(latest, durationSeconds);
    },
    (latest) => roomHasGameDuration(latest, durationSeconds),
  );
}

async function updateLobbyState(base44, room, user, body) {
  assertLobbySettingsAccess(room, user, "lobby");
  const mutation = validateLobbyMutation({
    mutation_id: body?.mutation_id,
    expected_revision: body?.expected_revision,
    state: body?.state,
  });
  const updated = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      assertLobbySettingsAccess(latest, user, "lobby");
      return lobbyMutationPatch(latest, mutation);
    },
    (latest) => roomHasLobbyMutation(latest, mutation),
  );

  await fanoutGameRoomSignalsBestEffort({
    store: base44.asServiceRole.entities.GameRoomSignal,
    room: updated,
    logError: (message, error) =>
      console.error(message, error?.message || error),
  });
  return updated;
}

function validatedStartPatch(room, payload) {
  const roomPlayers = players(room);
  const emails = new Set(roomPlayers.map((player) => player.email));
  const spyEmail = clean(payload?.spy_email);
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
  if (!emails.has(spyEmail)) {
    throw Object.assign(new Error("Spy must be a room player"), {
      status: 400,
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

async function armRoulette(base44, room, user, body) {
  requireHost(room, user);
  const roomPlayers = players(room);
  const status = normalizedStatus(room);
  if (!["waiting", "ready_voting"].includes(status)) {
    throw Object.assign(new Error("Mission can only start from the lobby"), {
      status: 409,
    });
  }
  if (roomPlayers.length < 3) {
    throw Object.assign(new Error("Need at least 3 operatives"), {
      status: 400,
    });
  }
  if (
    status === "ready_voting" &&
    !roomPlayers.every((player) => readyPlayers(room).includes(player.email))
  ) {
    throw Object.assign(new Error("All operatives must be ready"), {
      status: 409,
    });
  }

  const target = clean(body?.roulette_target_email) || roomPlayers[0]?.email;
  if (!roomPlayers.some((player) => player.email === target)) {
    throw Object.assign(new Error("Roulette target is not in this room"), {
      status: 400,
    });
  }

  const startPayload = authoritativeStartPayload(
    room,
    body?.plan || {},
    body?.expected_lobby_revision,
  );
  const startPatch = validatedStartPatch(room, startPayload);
  return await updateRoom(base44, room, {
    ...startPatch,
    ...serverIntroStartPatch(),
    status: "roulette",
    roulette_target_email: target,
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
  });
}

async function enqueueCommittedGameStart(base44, room) {
  const matchID = clean(room?.match_id);
  const startedEventID = clean(room?.game_started_event_id);
  if (
    normalizedStatus(room) !== "playing" || !matchID || !startedEventID
  ) {
    throw Object.assign(
      new Error("The committed game start could not be confirmed."),
      { status: 503, code: "game_start_commit_unconfirmed" },
    );
  }
  await enqueueGamePushEvents({
    base44,
    room,
    eventType: "game_started",
    sourceEventID: startedEventID,
    matchID,
    persist: async (writer) => {
      await assertRoomPersistenceBoundary(base44);
      return await writer();
    },
    sourceCommitted: true,
  });
}

async function completeGameStart(base44, room, user) {
  requirePlayer(room, user);
  // The request path refetches this room while holding the complete participant
  // writer-lease set. Therefore only one caller can leave roulette; every
  // competing or crash-retry caller observes these persisted IDs and merely
  // reconciles the deduplicated push rows below.
  if (
    normalizedStatus(room) === "playing" && clean(room.match_id) &&
    clean(room.game_started_event_id)
  ) {
    await enqueueCommittedGameStart(base44, room);
    return room;
  }
  assertIntroCompletionAccess(room, user.email);

  const matchID = crypto.randomUUID();
  const startedEventID = crypto.randomUUID();
  const committed = await updateRoom(base44, room, {
    status: "playing",
    match_id: matchID,
    terminal_intent: null,
    intro_started_at: introStartedAtForCompletion(room),
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    game_started_event_id: startedEventID,
    game_finished_event_id: "",
    ready_players: [],
    cards_read: [],
    vote_requests: [],
    detective_votes: [],
    spectators: [],
    eliminated_emails: [],
    winner: "",
  });
  await enqueueCommittedGameStart(base44, committed);
  return committed;
}

async function markRoleCardRead(base44, room, user) {
  requirePlayer(room, user);
  const updatedReadRoom = await updateRoomWithRetry(
    base44,
    room,
    (latest) => roleCardReadTransitionPatch(latest, user.email),
    (latest) =>
      cardsRead(latest).some((email) =>
        clean(email).toLocaleLowerCase() ===
          clean(user.email).toLocaleLowerCase()
      ),
  );

  const allCardsRead = players(updatedReadRoom).length > 0 &&
    players(updatedReadRoom).every((player) =>
      cardsRead(updatedReadRoom).some((email) =>
        clean(email).toLocaleLowerCase() ===
          clean(player.email).toLocaleLowerCase()
      )
    );
  if (allCardsRead && shouldSpyWin(updatedReadRoom)) {
    return await finishRoom(base44, updatedReadRoom, "spy");
  }

  return updatedReadRoom;
}

async function pauseGame(base44, room, user) {
  const pausedAt = new Date().toISOString();
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => pauseGameTransitionPatch(latest, user.email, pausedAt),
    (latest) => Boolean(clean(latest.game_paused_at)),
  );
}

async function resumeGame(base44, room, user) {
  const resumedAt = new Date().toISOString();
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => resumeGameTransitionPatch(latest, user.email, resumedAt),
    (latest) => !clean(latest.game_paused_at),
  );
}

async function advanceQuestion(base44, room, user) {
  requirePlayer(room, user);
  if (clean(room.current_asker_email) !== clean(user.email)) {
    throw Object.assign(
      new Error("Only the current asker can advance the round"),
      {
        status: 403,
      },
    );
  }
  const active = activePlayers(room);
  if (active.length < 2) {
    throw Object.assign(new Error("Need at least 2 active operatives"), {
      status: 400,
    });
  }

  const nextQuestions = Number(room.questions_in_round || 0) + 1;
  if (nextQuestions >= 8) {
    return await updateRoom(base44, room, { question_phase: "results" });
  }

  const currentAnswererIndex = Math.max(
    0,
    active.findIndex((player) => player.email === room.current_answerer_email),
  );
  const nextAskerIndex = currentAnswererIndex;
  let nextAnswererIndex = (currentAnswererIndex + 1) % active.length;
  if (nextAnswererIndex === nextAskerIndex) {
    nextAnswererIndex = (nextAnswererIndex + 1) % active.length;
  }

  return await updateRoom(base44, room, {
    current_asker_email: active[nextAskerIndex].email,
    current_answerer_email: active[nextAnswererIndex].email,
    questions_in_round: nextQuestions,
    current_answer: "",
    question_phase: "asking",
  });
}

async function advanceAssociation(base44, room, user) {
  requirePlayer(room, user);
  if (clean(room.current_asker_email) !== clean(user.email)) {
    throw Object.assign(
      new Error("Only the current speaker can advance the round"),
      {
        status: 403,
      },
    );
  }
  const active = activePlayers(room);
  if (!active.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }

  const state = parseAssociationState(room.current_answer);
  const spoken = [...state.spoken];
  if (room.current_asker_email && !spoken.includes(room.current_asker_email)) {
    spoken.push(room.current_asker_email);
  }

  const remaining = active.filter((player) => !spoken.includes(player.email));
  const startsNewRound = remaining.length === 0;
  const pool = startsNewRound ? active : remaining;
  const nextSpeaker = pool[Math.floor(Math.random() * pool.length)] ||
    active[0];
  const nextRound = startsNewRound
    ? Number(room.round_number || 1) + 1
    : Number(room.round_number || 1);

  return await updateRoom(base44, room, {
    round_number: nextRound,
    current_asker_email: nextSpeaker.email,
    current_answer: encodeAssociationState({
      spoken: startsNewRound ? [] : spoken,
      spinning: true,
    }),
    question_phase: "asking",
  });
}

async function startAssociation(base44, room, user) {
  requireHost(room, user);
  if (clean(room.game_mode) !== "associations") {
    throw Object.assign(new Error("Association mode is not active"), {
      status: 409,
    });
  }
  const active = activePlayers(room);
  if (!active.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }
  const next = active[Math.floor(Math.random() * active.length)];
  return await updateRoom(base44, room, {
    current_asker_email: next.email,
    current_answer: encodeAssociationState({ spoken: [], spinning: true }),
    question_phase: "asking",
  });
}

async function stopAssociationSpin(base44, room, user) {
  requirePlayer(room, user);
  if (
    clean(room.host_email) !== clean(user.email) &&
    clean(room.current_asker_email) !== clean(user.email)
  ) {
    throw Object.assign(
      new Error("Only the host or current speaker can stop the spin"),
      {
        status: 403,
      },
    );
  }
  const state = parseAssociationState(room.current_answer);
  if (!state.spinning) return room;
  return await updateRoom(base44, room, {
    current_answer: encodeAssociationState({
      spoken: state.spoken,
      spinning: false,
    }),
  });
}

async function markAnswerHeard(base44, room, user) {
  requirePlayer(room, user);
  if (clean(room.current_asker_email) !== clean(user.email)) {
    throw Object.assign(
      new Error("Only the current asker can confirm the answer"),
      {
        status: 403,
      },
    );
  }
  if (clean(room.question_phase) !== "asking") {
    throw Object.assign(
      new Error("The question is not awaiting confirmation"),
      {
        status: 409,
      },
    );
  }
  return await updateRoom(base44, room, {
    question_phase: "countdown",
    countdown_started_at: new Date().toISOString(),
  });
}

async function continueRound(base44, room, user) {
  requirePlayer(room, user);
  if (clean(room.question_phase) !== "results") {
    throw Object.assign(new Error("Round results are not active"), {
      status: 409,
    });
  }
  return await updateRoom(base44, room, {
    question_phase: "asking",
    round_number: nextRoundNumber(room.round_number),
    questions_in_round: 0,
    current_answer: "",
    current_answer_feedback: null,
    player_feedback: [],
  });
}

async function requestVote(base44, room, user) {
  requirePlayer(room, user);
  if (!activePlayers(room).some((player) => player.email === user.email)) {
    throw Object.assign(new Error("Spectators cannot request a vote"), {
      status: 403,
    });
  }

  if (shouldSpyWin(room)) {
    return await finishRoom(base44, room, "spy");
  }

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const requests = voteRequests(latest);
      return requests.includes(user.email)
        ? {}
        : { vote_requests: uniqueStrings([...requests, user.email]) };
    },
    (latest) => voteRequests(latest).includes(user.email),
  );
}

async function castDetectiveVote(base44, room, user, body) {
  requirePlayer(room, user);
  const active = activePlayers(room);
  const targetEmail = clean(body?.target_email);

  if (!active.some((player) => player.email === user.email)) {
    throw Object.assign(new Error("Spectators cannot vote"), { status: 403 });
  }
  if (!active.some((player) => player.email === targetEmail)) {
    throw Object.assign(new Error("Target is no longer active"), {
      status: 400,
    });
  }
  if (
    targetEmail.toLocaleLowerCase() === clean(user.email).toLocaleLowerCase()
  ) {
    throw Object.assign(new Error("You cannot vote for yourself"), {
      status: 400,
      code: "self_vote_not_allowed",
    });
  }

  if (shouldSpyWin(room)) {
    return await finishRoom(base44, room, "spy");
  }

  const votedRoom = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const votes = detectiveVotes(latest).filter((vote) =>
        vote.voter_email !== user.email
      );
      votes.push({ voter_email: user.email, voted_for_email: targetEmail });
      return { detective_votes: votes };
    },
    (latest) =>
      detectiveVotes(latest).some(
        (vote) =>
          vote.voter_email === user.email &&
          vote.voted_for_email === targetEmail,
      ),
  );

  const activeAfterVote = activePlayers(votedRoom);
  const activeEmails = new Set(activeAfterVote.map((player) => player.email));
  const votes = detectiveVotes(votedRoom).filter(
    (vote) =>
      activeEmails.has(vote.voter_email) &&
      activeEmails.has(vote.voted_for_email),
  );

  if (votes.length < activeAfterVote.length) {
    return votedRoom;
  }

  const counts = new Map();
  for (const vote of votes) {
    counts.set(
      vote.voted_for_email,
      (counts.get(vote.voted_for_email) || 0) + 1,
    );
  }

  const accused = [...counts.entries()].sort((lhs, rhs) => {
    if (lhs[1] === rhs[1]) return lhs[0].localeCompare(rhs[0]);
    return rhs[1] - lhs[1];
  })[0]?.[0];

  if (accused === votedRoom.spy_email) {
    return await finishRoom(base44, votedRoom, "detectives", {
      detective_votes: votes,
    });
  }

  const nextSpectators = spectators(votedRoom);
  if (accused && !nextSpectators.includes(accused)) {
    nextSpectators.push(accused);
  }

  const updated = await updateRoom(base44, votedRoom, {
    detective_votes: [],
    vote_requests: [],
    spectators: nextSpectators,
  });

  if (shouldSpyWin(updated)) {
    return await finishRoom(base44, updated, "spy");
  }

  return updated;
}

async function submitSpyGuess(base44, room, user, body) {
  requirePlayer(room, user);
  if (user.email !== room.spy_email) {
    throw Object.assign(new Error("Only the spy can guess the word"), {
      status: 403,
    });
  }

  const guess = requireSafeCommunityText(clean(body?.guess), "Spy guess");
  const correct = guess.localeCompare(displayWord(room), undefined, {
    sensitivity: "accent",
  }) === 0;
  const winner = correct ? "spy" : "detectives";
  return await finishRoom(base44, room, winner, {
    spy_guess: guess,
  });
}

async function leaveRoom(base44, room, user) {
  if (leaveAlreadyComplete(room, user.email)) return { success: true };

  const hostLeaving = clean(room.host_email).toLocaleLowerCase() ===
    clean(user.email).toLocaleLowerCase();
  const leavingDuringPreTimer =
    ["roulette", "playing"].includes(normalizedStatus(room)) &&
    !clean(room.game_started_at);
  if (hostLeaving && !leavingDuringPreTimer) {
    return await deleteRoom(base44, room);
  }

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const leavingEmail = clean(user.email).toLocaleLowerCase();
      const nextPlayers = players(latest).filter((player) =>
        clean(player.email).toLocaleLowerCase() !== leavingEmail
      );
      const membershipPatch = {
        players: nextPlayers,
        ...(clean(latest.host_email).toLocaleLowerCase() === leavingEmail
          ? { host_email: clean(nextPlayers[0]?.email) }
          : {}),
        participant_user_ids: uniqueStrings(latest?.participant_user_ids)
          .filter((userID) => userID !== clean(user.id)),
        status:
          nextPlayers.length === 0 && normalizedStatus(latest) === "finished"
            ? "waiting"
            : normalizedStatus(latest),
        spectators: spectators(latest).filter((email) =>
          clean(email).toLocaleLowerCase() !== leavingEmail
        ),
        ready_players: readyPlayers(latest).filter((email) =>
          clean(email).toLocaleLowerCase() !== leavingEmail
        ),
        cards_read: cardsRead(latest).filter((email) =>
          clean(email).toLocaleLowerCase() !== leavingEmail
        ),
        eliminated_emails: uniqueStrings(latest?.eliminated_emails).filter((
          email,
        ) => clean(email).toLocaleLowerCase() !== leavingEmail),
        vote_requests: voteRequests(latest).filter((email) =>
          clean(email).toLocaleLowerCase() !== leavingEmail
        ),
        detective_votes: detectiveVotes(latest).filter(
          (vote) =>
            clean(vote.voter_email).toLocaleLowerCase() !== leavingEmail &&
            clean(vote.voted_for_email).toLocaleLowerCase() !== leavingEmail,
        ),
        player_feedback:
          (Array.isArray(latest?.player_feedback) ? latest.player_feedback : [])
            .filter((feedback) =>
              clean(feedback?.email).toLocaleLowerCase() !== leavingEmail
            ),
      };
      return {
        ...membershipPatch,
        ...preTimerMembershipTransitionPatch({
          ...latest,
          ...membershipPatch,
        }),
      };
    },
    (latest) => !playerInRoom(latest, user.email),
  );
}

async function userIDForEmail(base44, emailValue) {
  const email = clean(emailValue).toLocaleLowerCase();
  if (!email) return null;
  const rows = await base44.asServiceRole.entities.User.filter({ email });
  const exact = (rows || []).filter((candidate) =>
    clean(candidate?.email).toLocaleLowerCase() === email
  );
  if (exact.length > 1) {
    throw Object.assign(new Error("Room participant identity is ambiguous"), {
      status: 409,
      code: "ambiguous_participant",
    });
  }
  return clean(exact[0]?.id) || null;
}

async function roomParticipantUserIDs(base44, room, actor) {
  const actorID = clean(actor?.id);
  const actorEmail = clean(actor?.email).toLocaleLowerCase();
  const emails = uniqueStrings([
    clean(room?.host_email).toLocaleLowerCase(),
    ...players(room).map((player) => clean(player.email).toLocaleLowerCase()),
  ]);
  const ids = [];
  for (const email of emails) {
    if (email === actorEmail && actorID) {
      ids.push(actorID);
      continue;
    }
    const userID = await userIDForEmail(base44, email);
    if (!userID) {
      throw Object.assign(
        new Error(
          "A referenced room participant no longer has an active account",
        ),
        { status: 409, code: "participant_missing" },
      );
    }
    ids.push(userID);
  }
  return uniqueStrings(ids);
}

async function roomLifecycleUserIDs(base44, room, actor) {
  return uniqueStrings([
    ...await roomParticipantUserIDs(base44, room, actor),
    clean(actor?.id),
  ]);
}

async function backfillRoomParticipantUserIDs(base44, room, userIDs) {
  const current = uniqueStrings(room?.participant_user_ids).sort();
  const expected = uniqueStrings(userIDs).sort();
  let playersChanged = false;
  const migratedPlayers = [];
  for (const player of players(room)) {
    const stableUserID = await userIDForEmail(base44, player?.email);
    if (!stableUserID) {
      throw Object.assign(new Error("Room participant identity is missing"), {
        status: 409,
        code: "participant_missing",
      });
    }
    const suppliedUserID = clean(player?.user_id);
    if (suppliedUserID && suppliedUserID !== stableUserID) {
      throw Object.assign(
        new Error("Room participant identity does not match its account."),
        { status: 409, code: "participant_identity_mismatch" },
      );
    }
    if (clean(player?.user_id) !== stableUserID) playersChanged = true;
    migratedPlayers.push({ ...player, user_id: stableUserID });
  }
  if (
    !playersChanged &&
    current.length === expected.length &&
    current.every((value, index) => value === expected[index])
  ) return room;
  const patch = {
    participant_user_ids: expected,
  };
  if (playersChanged) patch.players = migratedPlayers;
  return await updateRoom(base44, room, patch, {
    allowPendingTerminal: true,
  });
}

function activeRoomStatus(room) {
  return ["waiting", "ready_voting", "roulette", "playing"].includes(
    normalizedStatus(room),
  );
}

async function activeRoomForUser(base44, user, preferredRoomID) {
  if (preferredRoomID) {
    const preferred = await fetchRoom(base44, preferredRoomID);
    if (
      preferred && playerInRoom(preferred, user.email) &&
      activeRoomStatus(preferred)
    ) return preferred;
  }

  const candidates = [];
  const hosted = await base44.asServiceRole.entities.GameRoom.filter({
    host_email: user.email,
  }) || [];
  candidates.push(...hosted);
  try {
    const participating = await base44.asServiceRole.entities.GameRoom.filter({
      participant_user_ids: user.id,
    }) || [];
    candidates.push(...participating);
  } catch {
    // Legacy Base44 deployments may not support scalar matching in arrays.
    // The preferred id and host query remain bounded and never enumerate rooms.
  }
  return candidates
    .filter((room, index, all) =>
      all.findIndex((candidate) => clean(candidate.id) === clean(room.id)) ===
        index
    )
    .filter((room) => playerInRoom(room, user.email) && activeRoomStatus(room))
    .sort((left, right) =>
      Date.parse(clean(right.updated_date || right.created_date)) -
      Date.parse(clean(left.updated_date || left.created_date))
    )[0] || null;
}

async function executeRoomAction(base44, action, room, user, body) {
  const terminal = pendingTerminalIntent(room);
  if (terminal) {
    if (action === "join_room") {
      throw Object.assign(
        new Error("This match is finishing; joining is temporarily locked."),
        { status: 409, code: "terminal_reconciliation_pending" },
      );
    }
    // Any authenticated participant retry helps finish the immutable decision
    // before another mutation is allowed. The persisted intent, not this new
    // action's payload, remains the sole terminal source of truth.
    return await finishRoom(base44, room, terminal.winner);
  }

  assertGameActionAllowedWhilePaused(room, action);
  assertGameActionAllowedByDeadline(room, action);

  switch (action) {
    case "join_room":
      return await joinRoom(base44, room, user, body);
    case "begin_ready_check":
      return await beginReadyCheck(base44, room, user);
    case "return_to_waiting":
      return await returnToWaiting(base44, room, user);
    case "toggle_ready":
      return await toggleReady(base44, room, user);
    case "vote_play_again":
      return await votePlayAgain(base44, room, user);
    case "reset_room_for_replay":
      return await resetRoomForReplay(base44, room, user, body);
    case "update_game_mode":
      return await updateGameMode(base44, room, user, body);
    case "update_game_duration":
      return await updateGameDuration(base44, room, user, body);
    case "update_lobby_state":
      return await updateLobbyState(base44, room, user, body);
    case "arm_roulette":
      return await armRoulette(base44, room, user, body);
    case "complete_game_start":
      return await completeGameStart(base44, room, user, body);
    case "mark_role_card_read":
      return await markRoleCardRead(base44, room, user);
    case "pause_game":
      return await pauseGame(base44, room, user);
    case "resume_game":
      return await resumeGame(base44, room, user);
    case "advance_question":
      return await advanceQuestion(base44, room, user);
    case "advance_association":
      return await advanceAssociation(base44, room, user);
    case "start_association":
      return await startAssociation(base44, room, user);
    case "stop_association_spin":
      return await stopAssociationSpin(base44, room, user);
    case "mark_answer_heard":
      return await markAnswerHeard(base44, room, user);
    case "continue_round":
      return await continueRound(base44, room, user);
    case "request_vote":
      return await requestVote(base44, room, user);
    case "cast_detective_vote":
      return await castDetectiveVote(base44, room, user, body);
    case "submit_spy_guess":
      return await submitSpyGuess(base44, room, user, body);
    case "finalize_expired_room": {
      const winner = deriveExpiredGameWinner(room);
      return await finishRoom(base44, room, winner);
    }
    case "finish_room": {
      requireHost(room, user);
      // `finish_room` is accepted only for a short compatibility window. Both
      // action names ignore any submitted winner: the server-owned elapsed
      // timer is the sole source of the terminal result.
      const winner = deriveExpiredGameWinner(room);
      return await finishRoom(base44, room, winner);
    }
    case "record_finished_online_game":
      return rejectRetiredResultRecording();
    case "leave_room":
      return await leaveRoom(base44, room, user);
    default:
      throw Object.assign(new Error(`Unsupported action: ${action}`), {
        status: 400,
      });
  }
}

async function dispatchRoomPushBestEffort(base44, room, action) {
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!internalSecret || !room?.id) return;
  const sourceEventIDs = [];
  if (
    clean(room.status) === "playing" && clean(room.game_started_event_id)
  ) {
    sourceEventIDs.push(clean(room.game_started_event_id));
  }
  if (clean(room.status) === "finished" && clean(room.game_finished_event_id)) {
    sourceEventIDs.push(clean(room.game_finished_event_id));
  }
  try {
    for (const sourceEventID of sourceEventIDs) {
      await base44.asServiceRole.functions.invoke("pushNotificationAction", {
        action: "process_event",
        source_event_id: sourceEventID,
        internal_secret: internalSecret,
      });
    }
    if (clean(room.match_id)) {
      await base44.asServiceRole.functions.invoke("pushNotificationAction", {
        action: "sync_live_activity",
        room_id: clean(room.id),
        match_id: clean(room.match_id),
        internal_secret: internalSecret,
      });
    }
  } catch (error) {
    console.error("room push dispatch deferred", error?.message || error);
  }
}

function lifecycleHTTPStatus(error) {
  if (!(error instanceof BillingIdentityLifecycleError)) {
    return Number(error?.status) || 500;
  }
  return ["deletion_in_progress", "active_lease", "cas_contention"].includes(
      error.code,
    )
    ? 409
    : 503;
}

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const accessToken = clean(body?.access_token);
    const appId = req.headers.get("Base44-App-Id") ||
      req.headers.get("X-App-Id");
    const serverUrl = req.headers.get("Base44-Api-Url") || "https://base44.app";

    if (!appId) {
      return jsonError("Unauthorized", 401);
    }

    const base44 = createClientFromRequest(req);

    // The function gateway does not accept every provider/SSO token as its
    // Authorization header. Verify that token directly against Base44, while
    // keeping createClientFromRequest for server-side service-role access.
    // If the browser has an authenticated SSO/cookie session but no readable
    // storage token, the request client is also allowed to resolve that user.
    let user;
    try {
      user = await resolveRoomActionUser({
        accessToken,
        appId,
        serverUrl,
        requestClient: base44,
        createIdentityClient: (config) => createClient(config),
      });
    } catch {
      return jsonError("Unauthorized", 401);
    }

    if (!user?.id || !user?.email) {
      return jsonError("Unauthorized", 401);
    }

    const action = clean(body?.action);
    const roomId = clean(body?.room_id);

    if (!action) return jsonError("Missing action");

    if (action === "get_leaderboard") {
      return Response.json(await loadLeaderboard(base44, user));
    }

    if (action === "get_active_room") {
      const active = await activeRoomForUser(base44, user, roomId);
      return Response.json(active ? roomForClient(active, user) : null);
    }

    if (action === "create_room") {
      const result = await withRoomWriteLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs: [user.id],
        action: async (context) => {
          base44.__spyclashRoomWriteLeaseContext = context;
          try {
            return await createRoom(base44, user, body);
          } finally {
            delete base44.__spyclashRoomWriteLeaseContext;
          }
        },
      });
      return Response.json(roomForClient(result, user));
    }

    const room = roomId
      ? await fetchRoom(base44, roomId)
      : await fetchRoomByCode(base44, body?.room_code || body?.code);

    if (action === "leave_room" && leaveAlreadyComplete(room, user.email)) {
      return Response.json({ success: true });
    }
    if (!room) return jsonError("Room not found", 404);
    if (action === "get_room") {
      requirePlayer(room, user);
      return Response.json(roomForClient(room, user));
    }

    if (action !== "join_room") requirePlayer(room, user);

    const result = await retryRoomMembershipChangeBeforeAction({
      attempt: async (markActionStarted) => {
        // Rebuild the acquisition set for every pre-action membership retry.
        // This is what lets two QR/code joins serialize instead of rejecting
        // the slower joiner with a user-visible 409.
        const acquisitionRoom = await fetchRoom(base44, room.id);
        if (!acquisitionRoom) {
          if (action === "leave_room") return { success: true };
          throw Object.assign(new Error("Room not found"), { status: 404 });
        }
        if (
          action === "leave_room" &&
          leaveAlreadyComplete(acquisitionRoom, user.email)
        ) {
          return { success: true };
        }
        if (action !== "join_room") requirePlayer(acquisitionRoom, user);

        const userIDs = await roomLifecycleUserIDs(
          base44,
          acquisitionRoom,
          user,
        );
        return await withRoomWriteLeases({
          lifecycleStore:
            base44.asServiceRole.entities.BillingIdentityLifecycle,
          userIDs,
          action: async (context) => {
            base44.__spyclashRoomWriteLeaseContext = context;
            try {
              // The pre-lease room is only an acquisition hint. Refetch under
              // the leases and require exact participant coverage. If another
              // join/leave won first, the outer bounded retry releases these
              // leases, refetches membership, and tries once more safely.
              const latestRoom = await fetchRoom(base44, room.id);
              if (!latestRoom) {
                if (action === "leave_room") return { success: true };
                throw Object.assign(new Error("Room not found"), {
                  status: 404,
                });
              }
              if (
                action === "leave_room" &&
                leaveAlreadyComplete(latestRoom, user.email)
              ) {
                return { success: true };
              }
              const latestParticipantUserIDs = await roomParticipantUserIDs(
                base44,
                latestRoom,
                user,
              );
              const latestUserIDs = uniqueStrings([
                ...latestParticipantUserIDs,
                user.id,
              ]);
              assertExactRoomLeaseCoverage(context, latestUserIDs);
              const migratedRoom = await backfillRoomParticipantUserIDs(
                base44,
                latestRoom,
                latestParticipantUserIDs,
              );
              markActionStarted();
              return await executeRoomAction(
                base44,
                action,
                migratedRoom,
                user,
                body,
              );
            } finally {
              delete base44.__spyclashRoomWriteLeaseContext;
            }
          },
        });
      },
    });
    if (result?.id) await dispatchRoomPushBestEffort(base44, result, action);
    return Response.json(result?.id ? roomForClient(result, user) : result);
  } catch (error) {
    console.error("gameRoomAction error:", error?.message || error);
    return jsonError(
      error?.message || "Internal error",
      lifecycleHTTPStatus(error),
    );
  }
});

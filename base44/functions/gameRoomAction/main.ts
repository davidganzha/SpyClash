// @ts-nocheck -- Legacy dynamic Base44 room state is validated at runtime.
import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  requireSafeCommunityText,
  safeCommunityAvatar,
  safeCommunityDisplayName,
} from "./content-safety.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  committedGameStartIdentity,
  repairCommittedGameStartWithFreshLeases,
} from "./committed-game-start-repair.ts";
import {
  assertExactRoomLeaseCoverage,
  assertRoomWriteLeases,
  assertRoomWriterLeaseForUser,
  reconcileCommittedGameStartAfterActiveIdentityLease,
  recoverSafeRoomActionAfterActiveIdentityLease,
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
  hasGameTimerElapsed,
  pauseGameTransitionPatch,
  resumeGameTransitionPatch,
} from "./game-timer-policy.ts";
import {
  canonicalRoomActionRequest,
  hasTrustedRoomActionContext,
  resolveRoomActionUser,
} from "./request-auth.ts";
import { storedRoomParticipantUserIDs } from "./room-participant-identity.ts";
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
import { questionAdvancePatch } from "./question-round-policy.ts";
import { shouldSynchronizeLiveActivity } from "./room-push-policy.ts";
import { reconcileTerminalFinalizationAfterLeaseConflict } from "./terminal-finalization-recovery.ts";
import { assertExpectedTimerFinalizationScope } from "./terminal-finalization-scope.ts";
import { runTerminalSideEffectsSingleFlight } from "./terminal-side-effect-dispatch.ts";
import {
  isRoomWriteCASConflict,
  roomWriteRevision,
  writeRoomWithCAS,
} from "./room-write-cas.ts";
import {
  bindDetectiveVoteRoundIdentity,
  canonicalDetectiveVotes,
  detectiveVoteLeavePatch,
  detectiveVoteRequestTransition,
  isDetectiveVotingActive,
  resolvedDetectiveVoteCastTransition,
  scheduledDetectiveVoteCancellationEvent,
} from "./detective-vote-policy.ts";
import { commitDetectiveVoteCastWithRetry } from "./detective-vote-write.ts";
import { reconcileDetectiveVoteCastAfterActiveIdentityLease } from "./detective-vote-lease-recovery.ts";
import {
  activeDepartureTransition,
  assertActiveSpyGuesser,
  assertMultiSpyCapableRoster,
  canonicalClientCapabilities,
  canonicalSpyEmails,
  compatibleRosterForSpyCount,
  departedPlayerEmails,
  lobbyMembershipClampPatch,
  lobbySpyCount,
  playerCapabilityRefreshNeeded,
  playerSupportsMultiSpy,
  refreshedPlayerCapabilities,
  roomClientRequiresMultiSpyUpdate,
  roomHasDepartedPlayer,
  serverSpyAssignment,
  spiesKnowEachOther,
  spyGuessWinner,
  spyTeamTerminalWinner,
  validatedLobbySpyCount,
} from "./multi-spy-policy.ts";

function jsonError(message, status = 400, details = {}) {
  const code = clean(details?.code);
  const retryable = details?.retryable === true;
  return Response.json({
    error: message,
    ...(code ? { code } : {}),
    ...(retryable ? { retryable: true } : {}),
  }, {
    status,
    headers: retryable ? { "retry-after": "1" } : undefined,
  });
}

function clean(value) {
  return String(value || "").trim();
}

function safeLogLabel(value) {
  const label = clean(value);
  return /^[a-z0-9_-]{1,64}$/i.test(label) ? label : null;
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

function detectiveVoteCastEnteredActiveRound(
  room,
  actorEmailValue,
  targetEmailValue,
  explicitExpectedRoundIDValue,
) {
  if (!detectiveVotingActive(room)) return false;
  const actorEmail = clean(actorEmailValue).toLocaleLowerCase();
  const targetEmail = clean(targetEmailValue).toLocaleLowerCase();
  if (!actorEmail || !targetEmail || actorEmail === targetEmail) return false;
  const activeEmails = new Set(
    activePlayers(room).map((player) =>
      clean(player.email).toLocaleLowerCase()
    ),
  );
  const currentRoundID = detectiveVoteRoundID(room);
  const explicitExpectedRoundID = clean(explicitExpectedRoundIDValue);
  return (!explicitExpectedRoundID ||
    explicitExpectedRoundID === currentRoundID) &&
    activeEmails.has(actorEmail) && activeEmails.has(targetEmail);
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

function roomHasPlayerCapabilities(room, email, capabilities) {
  const actorKey = clean(email).toLocaleLowerCase();
  const actor = players(room).find((player) =>
    clean(player?.email).toLocaleLowerCase() === actorKey
  );
  return Boolean(actor) && JSON.stringify(
        canonicalClientCapabilities(actor?.client_capabilities),
      ) === JSON.stringify(canonicalClientCapabilities(capabilities));
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
  return spyTeamTerminalWinner(room) === "spy";
}

function clientUpdateRequiredError() {
  return Object.assign(
    new Error("Update SpyClash to continue in this multi-spy room"),
    { status: 426, code: "client_update_required" },
  );
}

function assertRoomClientCompatible(room, user) {
  if (roomClientRequiresMultiSpyUpdate(room, user?.email)) {
    throw clientUpdateRequiredError();
  }
}

function roomLeaveAlreadyComplete(room, email) {
  if (!room) return true;
  if (pendingTerminalIntent(room)) return false;
  if (roomHasDepartedPlayer(room, email)) return true;
  return leaveAlreadyComplete(room, email);
}

function submittedClientCapabilities(body) {
  const incoming = body?.player || {};
  if (Object.prototype.hasOwnProperty.call(body || {}, "client_capabilities")) {
    return body.client_capabilities;
  }
  if (Object.prototype.hasOwnProperty.call(incoming, "client_capabilities")) {
    return incoming.client_capabilities;
  }
  return null;
}

function actorCapabilityRefreshNeeded(room, user, body) {
  const submitted = submittedClientCapabilities(body);
  return submitted !== null && normalizedStatus(room) === "waiting" &&
    playerCapabilityRefreshNeeded(players(room), user.email, submitted);
}

async function refreshActorCapabilities(base44, room, user, body) {
  const submitted = submittedClientCapabilities(body);
  if (submitted === null || normalizedStatus(room) !== "waiting") return room;
  const expectedCapabilities = canonicalClientCapabilities(submitted);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const refreshed = refreshedPlayerCapabilities(
        players(latest),
        user.email,
        expectedCapabilities,
      );
      return refreshed.changed ? { players: refreshed.players } : {};
    },
    (latest) => {
      const actor = players(latest).find((player) =>
        clean(player.email).toLocaleLowerCase() ===
          clean(user.email).toLocaleLowerCase()
      );
      return Boolean(actor) && JSON.stringify(
            canonicalClientCapabilities(actor.client_capabilities),
          ) === JSON.stringify(expectedCapabilities);
    },
  );
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
  if (base44.__spyclashFastRoomWriteContext === true) return;
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

const EXPLICIT_TIMER_FINALIZE_ACTIONS = new Set([
  "finalize_expired_room",
  "finish_room",
]);

async function waitForCommittedTerminalRoom(base44, room) {
  let latest = room;
  for (const milliseconds of [0, 80, 200, 420]) {
    if (milliseconds > 0) await delay(milliseconds);
    latest = await fetchRoom(base44, latest.id);
    if (!latest || normalizedStatus(latest) === "finished") return latest;
    if (!pendingTerminalIntent(latest)) return latest;
  }
  return latest;
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
  if (options.allowActiveIdentityLeaseRecovery !== true) {
    await assertRoomPersistenceBoundary(base44);
  }
  assertRoomMutationOpen(room, options.allowPendingTerminal === true);
  return await writeRoomWithCAS({
    store: base44.asServiceRole.entities.GameRoom,
    room,
    patch: data,
    read: (roomID) => fetchRoom(base44, roomID),
  });
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
    if (attempt > 0) {
      latest = await fetchRoom(base44, latest.id);
      if (!latest) {
        throw Object.assign(new Error("Room not found"), { status: 404 });
      }
    }
    assertRoomMutationOpen(latest, options.allowPendingTerminal === true);

    const patch = buildPatch(latest) || {};
    if (!Object.keys(patch).length) {
      if (!verify || verify(latest)) return latest;
      await delay(20 + attempt * 35);
      continue;
    }

    try {
      latest = await updateRoom(base44, latest, patch, options);
    } catch (error) {
      if (!isRoomWriteCASConflict(error) || attempt === attempts - 1) {
        throw error;
      }
      await delay(20 + attempt * 35);
      continue;
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

async function deleteRoom(base44, room, options = {}) {
  if (options.allowActiveIdentityLeaseRecovery !== true) {
    await assertRoomPersistenceBoundary(base44);
  }
  const latest = await fetchRoom(base44, room.id);
  if (!latest) return { success: true };
  assertRoomMutationOpen(latest);
  // The internal receiver durably marks every exact per-activity token before
  // the ephemeral room is removed. If that boundary cannot be confirmed, keep
  // the room so a caller retry can still produce a real ActivityKit `end`.
  await endRoomLiveActivitiesBeforeDelete(base44, latest);
  if (options.allowActiveIdentityLeaseRecovery !== true) {
    await assertRoomPersistenceBoundary(base44);
  }
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
  const spyEmails = canonicalSpyEmails(room);
  const spyKeys = new Set(
    spyEmails.map((email) => clean(email).toLocaleLowerCase()),
  );

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

    const isSpy = spyKeys.has(clean(player.email).toLocaleLowerCase());
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
      ranked: spyEmails.length === 1,
      role: isSpy ? "spy" : "detective",
      word: displayWord(room) || "CLASSIFIED",
      category: clean(room.category) || "CLASSIC",
      winner,
      player_count: roomPlayers.length,
      spy_count: spyEmails.length,
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
    let claimed;
    try {
      claimed = await updateRoom(base44, latest, {
        terminal_intent: intent,
        detective_vote_round_id: "",
      }, { allowPendingTerminal: true });
    } catch (error) {
      if (isRoomWriteCASConflict(error) && attempt < attempts - 1) {
        await delay(20 + attempt * 35);
        continue;
      }
      throw error;
    }
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
    detective_vote_round_id: "",
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
          ...(detectiveVoteRoundID(latest)
            ? { detective_vote_round_id: "" }
            : {}),
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
        detective_vote_round_id: "",
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
  const expectedPushRecipients = uniqueStrings([
    ...(finished.participant_user_ids || []),
    ...players(finished).map((player) => player.user_id),
  ]).length;
  if (committed < expectedPushRecipients) {
    throw Object.assign(new Error("Game finish push commit failed"), {
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
    lobby_spy_count: 1,
    spies_know_each_other: false,
    spy_emails: [],
    spy_email: "",
    incompatible_player_emails: [],
    departed_player_emails: [],
    lobby_schema_version: 2,
    lobby_revision: 0,
    room_revision: 0,
    room_last_write_token: `created:${crypto.randomUUID()}`,
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
    detective_vote_round_id: "",
    detective_vote_cancellation_event_id: "",
    detective_vote_cancellation_round_id: "",
    detective_vote_cancellation_present_at: "",
    detective_vote_cancellation_reason: "",
    winner: "",
  });
  return created;
}

async function joinRoom(base44, room, user, body) {
  const player = playerFromUser(user, body);
  const alreadyJoined = playerInRoom(room, user.email);
  const alreadyDeparted = roomHasDepartedPlayer(room, user.email);
  if (lobbySpyCount(room) > 1 && !playerSupportsMultiSpy(player)) {
    throw clientUpdateRequiredError();
  }
  if (alreadyDeparted && normalizedStatus(room) !== "waiting") {
    throw Object.assign(
      new Error("This operative already left the active mission"),
      { status: 409, code: "room_departed" },
    );
  }
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
      if (lobbySpyCount(latest) > 1 && !playerSupportsMultiSpy(player)) {
        throw clientUpdateRequiredError();
      }
      if (
        roomHasDepartedPlayer(latest, user.email) &&
        normalizedStatus(latest) !== "waiting"
      ) {
        throw Object.assign(
          new Error("This operative already left the active mission"),
          { status: 409, code: "room_departed" },
        );
      }
      if (playerInRoom(latest, user.email)) {
        const current = players(latest).find((candidate) =>
          candidate.email === user.email
        );
        const participantIDs = uniqueStrings([
          ...(latest.participant_user_ids || []),
          user.id,
        ]);
        const tombstonePresent = uniqueStrings(
          latest?.incompatible_player_emails,
        ).some((email) =>
          clean(email).toLocaleLowerCase() ===
            clean(user.email).toLocaleLowerCase()
        );
        const departedPresent = roomHasDepartedPlayer(latest, user.email);
        if (
          clean(current?.user_id) === clean(user.id) &&
          clean(current?.name) === clean(player.name) &&
          clean(current?.avatar) === clean(player.avatar) &&
          JSON.stringify(
              canonicalClientCapabilities(current?.client_capabilities),
            ) ===
            JSON.stringify(player.client_capabilities) &&
          participantIDs.length ===
            (latest.participant_user_ids || []).length &&
          !tombstonePresent && !departedPresent
        ) return {};
        return {
          players: mergePlayers(players(latest), player),
          participant_user_ids: participantIDs,
          spectators: spectators(latest).filter((email) =>
            clean(email).toLocaleLowerCase() !==
              clean(user.email).toLocaleLowerCase()
          ),
          eliminated_emails: uniqueStrings(latest?.eliminated_emails).filter(
            (email) =>
              clean(email).toLocaleLowerCase() !==
                clean(user.email).toLocaleLowerCase(),
          ),
          departed_player_emails: departedPlayerEmails(latest).filter(
            (email) =>
              clean(email).toLocaleLowerCase() !==
                clean(user.email).toLocaleLowerCase(),
          ),
          incompatible_player_emails: uniqueStrings(
            latest?.incompatible_player_emails,
          ).filter((email) =>
            clean(email).toLocaleLowerCase() !==
              clean(user.email).toLocaleLowerCase()
          ),
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
        incompatible_player_emails: uniqueStrings(
          latest?.incompatible_player_emails,
        ).filter((email) =>
          clean(email).toLocaleLowerCase() !==
            clean(user.email).toLocaleLowerCase()
        ),
        departed_player_emails: departedPlayerEmails(latest).filter((email) =>
          clean(email).toLocaleLowerCase() !==
            clean(user.email).toLocaleLowerCase()
        ),
      };
    },
    // The player object is the authoritative membership record. The mirrored
    // participant_user_ids field is only an indexed lookup aid and can lag or
    // be omitted by field-level schema rules. Requiring both made a successful
    // player write surface as a false 409 on production.
    (latest) =>
      roomHasParticipantIdentity(latest, user) &&
      !roomHasDepartedPlayer(latest, user.email) &&
      !uniqueStrings(latest?.incompatible_player_emails).some((email) =>
        clean(email).toLocaleLowerCase() ===
          clean(user.email).toLocaleLowerCase()
      ) && roomHasPlayerCapabilities(
        latest,
        user.email,
        player.client_capabilities,
      ),
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
  validatedLobbySpyCount(lobbySpyCount(room), players(room).length);
  assertMultiSpyCapableRoster(room);
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
  const departedKeys = new Set(
    departedPlayerEmails(room).map((email) => clean(email).toLocaleLowerCase()),
  );
  const replayPlayers = players(room).filter((player) =>
    !departedKeys.has(clean(player?.email).toLocaleLowerCase())
  );
  const removedUserIDs = new Set(
    players(room).filter((player) =>
      departedKeys.has(clean(player?.email).toLocaleLowerCase())
    ).map((player) => clean(player?.user_id)).filter(Boolean),
  );
  const replayHost =
    replayPlayers.some((player) =>
        clean(player?.email).toLocaleLowerCase() ===
          clean(room?.host_email).toLocaleLowerCase()
      )
      ? clean(room?.host_email)
      : clean(replayPlayers[0]?.email);
  return await updateRoom(base44, room, {
    status: "waiting",
    players: replayPlayers,
    participant_user_ids: uniqueStrings(room?.participant_user_ids).filter(
      (userID) => !removedUserIDs.has(clean(userID)),
    ),
    host_email: replayHost,
    departed_player_emails: [],
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
  const submittedState = body?.state && typeof body.state === "object" &&
      !Array.isArray(body.state)
    ? body.state
    : {};
  const requestedMutation = validateLobbyMutation({
    mutation_id: body?.mutation_id,
    expected_revision: body?.expected_revision,
    state: {
      ...submittedState,
      lobby_spy_count: Object.prototype.hasOwnProperty.call(
          submittedState,
          "lobby_spy_count",
        )
        ? submittedState.lobby_spy_count
        : lobbySpyCount(room),
      spies_know_each_other: Object.prototype.hasOwnProperty.call(
          submittedState,
          "spies_know_each_other",
        )
        ? submittedState.spies_know_each_other
        : spiesKnowEachOther(room),
    },
  });
  const requestedSpyCount = requestedMutation.state.lobby_spy_count;
  let effectiveMutation = requestedMutation;
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      assertLobbySettingsAccess(latest, user, "lobby");
      const roster = compatibleRosterForSpyCount(
        latest,
        requestedSpyCount,
      );
      effectiveMutation = roster.effectiveSpyCount === requestedSpyCount
        ? requestedMutation
        : validateLobbyMutation({
          mutation_id: body?.mutation_id,
          expected_revision: body?.expected_revision,
          state: {
            ...requestedMutation.state,
            lobby_spy_count: roster.effectiveSpyCount,
          },
        });
      const removedKeys = new Set(
        roster.removedEmails.map((email) => clean(email).toLocaleLowerCase()),
      );
      const removedUserIDs = new Set(
        players(latest).filter((player) =>
          removedKeys.has(clean(player?.email).toLocaleLowerCase())
        ).map((player) => clean(player?.user_id)).filter(Boolean),
      );
      return {
        ...lobbyMutationPatch(latest, effectiveMutation),
        ...(roster.removedEmails.length
          ? {
            players: roster.players,
            participant_user_ids: uniqueStrings(
              latest?.participant_user_ids,
            ).filter((userID) => !removedUserIDs.has(clean(userID))),
            ready_players: readyPlayers(latest).filter((email) =>
              !removedKeys.has(clean(email).toLocaleLowerCase())
            ),
            incompatible_player_emails: uniqueStrings([
              ...uniqueStrings(latest?.incompatible_player_emails),
              ...roster.removedEmails,
            ]).slice(-12),
          }
          : {}),
      };
    },
    (latest) =>
      roomHasLobbyMutation(latest, effectiveMutation) &&
      (effectiveMutation.state.lobby_spy_count <= 1 ||
        players(latest).every(playerSupportsMultiSpy)),
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

async function armRoulette(base44, room, user, body) {
  requireHost(room, user);
  const roomPlayers = players(room);
  const status = normalizedStatus(room);
  if (status === "roulette" && canonicalSpyEmails(room).length) {
    // Validate the already-committed frozen assignment before treating a lost
    // response as success. A partial/corrupt assignment must never be rerolled.
    serverSpyAssignment(room);
    return room;
  }
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
  validatedLobbySpyCount(lobbySpyCount(room), roomPlayers.length);
  assertMultiSpyCapableRoster(room);
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
  const assignment = serverSpyAssignment(room);
  const startPatch = validatedStartPatch(room, startPayload, assignment);
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
    detective_vote_round_id: "",
    detective_vote_cancellation_event_id: "",
    detective_vote_cancellation_round_id: "",
    detective_vote_cancellation_present_at: "",
    detective_vote_cancellation_reason: "",
    spectators: [],
    eliminated_emails: [],
    winner: "",
  });
  await enqueueCommittedGameStart(base44, committed);
  return committed;
}

async function repairDetectedCommittedGameStart(base44, detectedRoom, user) {
  const expected = committedGameStartIdentity(detectedRoom);
  if (!expected) {
    throw Object.assign(
      new Error("The committed game start could not be confirmed."),
      { status: 503, code: "game_start_commit_unconfirmed" },
    );
  }

  return await repairCommittedGameStartWithFreshLeases({
    expected,
    refetch: () => fetchRoom(base44, detectedRoom.id),
    assertParticipant: (candidate) => requirePlayer(candidate, user),
    lifecycleUserIDs: (candidate) =>
      roomLifecycleUserIDs(base44, candidate, user),
    withFreshLeases: (userIDs, repair) =>
      withRoomWriteLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs,
        action: async (context) => {
          base44.__spyclashRoomWriteLeaseContext = context;
          try {
            return await repair(context);
          } finally {
            delete base44.__spyclashRoomWriteLeaseContext;
          }
        },
      }),
    currentUserIDs: async (candidate) =>
      uniqueStrings([
        ...await roomParticipantUserIDs(base44, candidate, user),
        user.id,
      ]),
    assertExactLeaseCoverage: (context, userIDs) =>
      assertExactRoomLeaseCoverage(context, userIDs),
    assertLeasesActive: (context) => assertRoomWriteLeases(context),
    migrate: async (candidate, userIDs) => {
      const revisionMigratedRoom = await backfillRoomWriteRevision(
        base44,
        candidate,
      );
      return await backfillRoomParticipantUserIDs(
        base44,
        revisionMigratedRoom,
        userIDs,
      );
    },
    // The exact persisted match/event identity is checked immediately before
    // this call, so this can only take completeGameStart's idempotent branch.
    reconcile: (candidate) => completeGameStart(base44, candidate, user),
    fanout: async (candidate) => {
      await fanoutGameRoomSignalsBestEffort({
        store: base44.asServiceRole.entities.GameRoomSignal,
        room: candidate,
        logError: (message, error) =>
          console.error(message, error?.message || error),
      });
    },
  });
}

async function markRoleCardRead(base44, room, user, options = {}) {
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
    6,
    options,
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
  return await updateRoom(base44, room, questionAdvancePatch(room, active));
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
  if (!activePlayers(room).some((player) => player.email === user.email)) {
    throw Object.assign(new Error("Only active players can stop the spin"), {
      status: 403,
    });
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
  return await advanceQuestion(base44, room, user);
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
      const transition = detectiveVoteRequestTransition(
        activePlayers(latest).map((player) => player.email),
        voteRequests(latest),
        user.email,
        detectiveVoteRoundID(latest),
        () => crypto.randomUUID(),
      );
      return transition.patch;
    },
    (latest) => {
      const requested = voteRequests(latest).some((email) =>
        clean(email).toLocaleLowerCase() ===
          clean(user.email).toLocaleLowerCase()
      );
      return requested &&
        (!detectiveVotingActive(latest) ||
          Boolean(detectiveVoteRoundID(latest)));
    },
  );
}

async function castDetectiveVote(base44, room, user, body) {
  requirePlayer(room, user);
  const active = activePlayers(room);
  const targetEmail = clean(body?.target_email);
  const explicitExpectedRoundID = explicitExpectedVoteRoundID(body);
  const serverCapturedRoundID = clean(body?.__server_vote_cast_round_id);
  const boundRoundID = explicitExpectedRoundID || serverCapturedRoundID;
  const requestStartedDuringThisVote =
    body?.__server_vote_cast_started_active === true &&
    clean(body?.__server_vote_cast_match_id) === clean(room?.match_id) &&
    Boolean(boundRoundID);

  if (shouldSpyWin(room)) {
    return await finishRoom(base44, room, "spy");
  }
  if (!detectiveVotingActive(room)) {
    if (normalizedStatus(room) === "playing" && hasGameTimerElapsed(room)) {
      return await finishRoom(
        base44,
        room,
        deriveExpiredGameWinner(room),
      );
    }
    if (requestStartedDuringThisVote) {
      // This request entered while the same match's vote was active, then
      // waited behind the room lifecycle lease while another final cast
      // atomically cancelled or resolved it. Return that authoritative room;
      // a genuinely later stale request never receives this server-owned hint.
      return room;
    }
    throw Object.assign(new Error("Detective voting is no longer active"), {
      status: 409,
      code: "detective_vote_inactive",
    });
  }

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

  // Identity remains stable for this request, while each CAS attempt schedules
  // from its own fresh server time. The winning attempt therefore commits the
  // freshest presentation timestamp without ever minting a second event id.
  const cancellationEventIdentity = {
    eventID: crypto.randomUUID(),
    roundID: boundRoundID,
  };

  const votedRoom = await commitDetectiveVoteCastWithRetry({
    initialRoom: room,
    buildPatch: (latest) => {
      if (normalizedStatus(latest) !== "playing") {
        throw Object.assign(new Error("Detective voting is no longer active"), {
          status: 409,
          code: "detective_vote_inactive",
        });
      }
      const roundBinding = bindDetectiveVoteRoundIdentity(
        detectiveVoteRoundID(latest),
        explicitExpectedRoundID,
        serverCapturedRoundID,
        detectiveVotingActive(latest),
      );
      assertGameActionAllowedWhilePaused(latest, "cast_detective_vote");
      const nowMilliseconds = Date.now();
      if (hasGameTimerElapsed(latest, nowMilliseconds)) {
        const winner = deriveExpiredGameWinner(latest, nowMilliseconds);
        return {
          detective_votes: [],
          vote_requests: [],
          detective_vote_round_id: "",
          terminal_intent: buildTerminalIntent(latest, winner),
        };
      }
      assertGameActionAllowedByDeadline(
        latest,
        "cast_detective_vote",
        nowMilliseconds,
      );
      const cancellationEvent = scheduledDetectiveVoteCancellationEvent(
        cancellationEventIdentity,
        nowMilliseconds,
      );
      const latestActiveEmails = activePlayers(latest).map((player) =>
        player.email
      );
      const resolution = resolvedDetectiveVoteCastTransition(
        latestActiveEmails,
        voteRequests(latest),
        detectiveVotes(latest),
        user.email,
        targetEmail,
        canonicalSpyEmails(latest),
        spectators(latest),
        Array.isArray(latest?.eliminated_emails)
          ? latest.eliminated_emails
          : [],
        cancellationEvent,
      );
      const patch = { ...resolution.patch };
      if (
        roundBinding.initialize &&
        resolution.decision.outcome === "continue" &&
        !Object.prototype.hasOwnProperty.call(
          patch,
          "detective_vote_round_id",
        )
      ) {
        patch.detective_vote_round_id = roundBinding.roundID;
      }
      if (resolution.terminal_winner) {
        patch.terminal_intent = buildTerminalIntent(
          { ...latest, ...patch },
          resolution.terminal_winner,
          resolution.terminal_patch,
        );
      }
      return patch;
    },
    write: (latest, patch) => updateRoom(base44, latest, patch),
    read: (roomID) => fetchRoom(base44, roomID),
    isConflict: isRoomWriteCASConflict,
    isSettledAfterConflict: (latest) => {
      if (
        normalizedStatus(latest) === "finished" ||
        pendingTerminalIntent(latest)
      ) {
        return true;
      }
      const latestRoundID = detectiveVoteRoundID(latest);
      if (latestRoundID && latestRoundID !== boundRoundID) return false;
      // A concurrent cancellation/ejection is settled before the deadline.
      // At/after 0:00 this request must instead retry and atomically persist the
      // spy terminal, never return a merely closed playing room.
      if (hasGameTimerElapsed(latest)) return false;
      const latestActiveEmails = activePlayers(latest).map((player) =>
        player.email
      );
      const latestVotes = canonicalDetectiveVotes(
        latestActiveEmails,
        detectiveVotes(latest),
      );
      return !isDetectiveVotingActive(
        latestActiveEmails,
        voteRequests(latest),
      ) && latestVotes.length === 0;
    },
    delay,
  });

  const terminal = pendingTerminalIntent(votedRoom);
  return terminal
    ? await finishRoom(base44, votedRoom, terminal.winner)
    : votedRoom;
}

async function submitSpyGuess(base44, room, user, body) {
  requirePlayer(room, user);
  assertActiveSpyGuesser(room, user.email);

  const guess = requireSafeCommunityText(clean(body?.guess), "Spy guess");
  const winner = spyGuessWinner(displayWord(room), guess);
  return await finishRoom(base44, room, winner, {
    spy_guess: guess,
  });
}

async function leaveRoom(base44, room, user, options = {}) {
  if (roomLeaveAlreadyComplete(room, user.email)) return { success: true };

  const hostLeaving = clean(room.host_email).toLocaleLowerCase() ===
    clean(user.email).toLocaleLowerCase();
  const leavingDuringPreTimer =
    ["roulette", "playing"].includes(normalizedStatus(room)) &&
    !clean(room.game_started_at);
  const leavingDuringActiveGame = normalizedStatus(room) === "playing" &&
    Boolean(clean(room.game_started_at));
  if (hostLeaving && !leavingDuringPreTimer && !leavingDuringActiveGame) {
    return await deleteRoom(base44, room, options);
  }

  const updated = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const leavingEmail = clean(user.email).toLocaleLowerCase();
      const leavingVotePatch = detectiveVoteLeavePatch(
        activePlayers(latest).map((player) => player.email),
        voteRequests(latest),
        detectiveVotes(latest),
        user.email,
        detectiveVoteRoundID(latest),
      );
      const latestActiveGame = normalizedStatus(latest) === "playing" &&
        Boolean(clean(latest.game_started_at));
      if (latestActiveGame) {
        const departure = activeDepartureTransition(latest, user.email);
        const patch = {
          ...departure.patch,
          ...leavingVotePatch,
          player_feedback: (Array.isArray(latest?.player_feedback)
            ? latest.player_feedback
            : []).filter((feedback) =>
              clean(feedback?.email).toLocaleLowerCase() !== leavingEmail
            ),
        };
        if (departure.terminalWinner) {
          patch.terminal_intent = buildTerminalIntent(
            { ...latest, ...patch },
            departure.terminalWinner,
          );
        }
        return patch;
      }
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
        ...leavingVotePatch,
        player_feedback:
          (Array.isArray(latest?.player_feedback) ? latest.player_feedback : [])
            .filter((feedback) =>
              clean(feedback?.email).toLocaleLowerCase() !== leavingEmail
            ),
      };
      return {
        ...membershipPatch,
        ...lobbyMembershipClampPatch(latest, nextPlayers.length),
        ...preTimerMembershipTransitionPatch({
          ...latest,
          ...membershipPatch,
        }),
      };
    },
    (latest) =>
      !playerInRoom(latest, user.email) ||
      roomHasDepartedPlayer(latest, user.email),
    6,
    options,
  );
  const terminal = pendingTerminalIntent(updated);
  return terminal
    ? await finishRoom(base44, updated, terminal.winner)
    : updated;
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
  const stableUserIDs = storedRoomParticipantUserIDs({
    players: players(room),
    participantUserIDs: room?.participant_user_ids,
    hostEmail: room?.host_email,
    actor,
  });
  if (stableUserIDs) return stableUserIDs;

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
  const existingPlayers = players(room);
  const stablePlayerIDs = existingPlayers
    .map((player) => clean(player?.user_id))
    .filter(Boolean)
    .sort();
  if (
    stablePlayerIDs.length === existingPlayers.length &&
    stablePlayerIDs.length === expected.length &&
    stablePlayerIDs.every((value, index) => value === expected[index]) &&
    current.length === expected.length &&
    current.every((value, index) => value === expected[index])
  ) return room;
  let playersChanged = false;
  const migratedPlayers = [];
  for (const player of existingPlayers) {
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

async function backfillRoomWriteRevision(base44, room) {
  if (roomWriteRevision(room) !== null) return room;
  await assertRoomPersistenceBoundary(base44);
  const writeToken = `migrated:${crypto.randomUUID()}`;
  await base44.asServiceRole.entities.GameRoom.update(room.id, {
    room_revision: 0,
    room_last_write_token: writeToken,
  });
  return {
    ...room,
    room_revision: 0,
    room_last_write_token: writeToken,
  };
}

const FAST_ROOM_ACTIONS = new Set([
  "mark_role_card_read",
  "pause_game",
  "resume_game",
  "advance_question",
  "advance_association",
  "start_association",
  "stop_association_spin",
  "mark_answer_heard",
  "continue_round",
  "request_vote",
]);

function canUseFastRoomAction(action, room, user) {
  if (!FAST_ROOM_ACTIONS.has(action)) return false;
  if (roomWriteRevision(room) === null) return false;
  if (!roomHasParticipantIdentity(room, user)) return false;
  if (
    (action === "mark_role_card_read" || action === "request_vote") &&
    shouldSpyWin(room)
  ) return false;
  return true;
}

function activeRoomStatus(room) {
  return ["waiting", "ready_voting", "roulette", "playing"].includes(
    normalizedStatus(room),
  );
}

function roomIsVisibleToActiveParticipant(room, user) {
  return playerInRoom(room, user.email) &&
    !roomHasDepartedPlayer(room, user.email) && activeRoomStatus(room);
}

async function activeRoomForUser(base44, user, preferredRoomID) {
  if (preferredRoomID) {
    const preferred = await fetchRoom(base44, preferredRoomID);
    if (preferred && roomIsVisibleToActiveParticipant(preferred, user)) {
      return preferred;
    }
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
    .filter((room) => roomIsVisibleToActiveParticipant(room, user))
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

  if (action !== "join_room") {
    room = await refreshActorCapabilities(base44, room, user, body);
  }

  assertGameActionAllowedWhilePaused(room, action);
  // A cast owns a dedicated CAS retry. It rechecks the deadline against every
  // refreshed revision and persists a spy terminal if that retry crosses 0:00.
  // Checking only this pre-retry snapshot could either surface a false 409 or
  // allow a later refreshed vote to claim detectives after the deadline.
  if (action !== "cast_detective_vote") {
    assertGameActionAllowedByDeadline(room, action);
  }

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
      // Recheck under the participant lease set. A room can be reset to a new
      // match after the client's authoritative read but before this write.
      assertExpectedTimerFinalizationScope(room, body);
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

async function executeRoomActionWithSignal(
  base44,
  action,
  room,
  user,
  body,
  options = {},
) {
  const result = await executeRoomAction(base44, action, room, user, body);
  if (result?.id && !shouldDeferFinishedRoomSignal(result)) {
    await fanoutGameRoomSignalsBestEffort({
      store: base44.asServiceRole.entities.GameRoomSignal,
      room: result,
      allowCreate: options.allowSignalCreate !== false,
      logError: (message, error) =>
        console.error(message, error?.message || error),
    });
  }
  return result;
}

function isCommittedFinishedRoom(room) {
  return normalizedStatus(room) === "finished" &&
    Boolean(clean(room?.game_finished_event_id));
}

function shouldDeferFinishedRoomSignal(room) {
  return isCommittedFinishedRoom(room);
}

async function fanoutDeferredFinishedRoomSignal(base44, room) {
  if (!room?.id || !isCommittedFinishedRoom(room)) return true;
  const userIDs = uniqueStrings([
    ...(room.participant_user_ids || []),
    ...players(room).map((player) => player.user_id),
  ]);
  if (!userIDs.length) return true;
  try {
    const result = await withRoomWriteLeases({
      lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
      userIDs,
      attempts: 1,
      action: async () =>
        await fanoutGameRoomSignalsBestEffort({
          store: base44.asServiceRole.entities.GameRoomSignal,
          room,
          logError: (message, error) =>
            console.error(message, error?.message || error),
        }),
    });
    return Number(result?.failed) === 0;
  } catch (error) {
    // Polling remains the fallback. Never recreate an identity-bearing signal
    // after account deletion has acquired its opposing lifecycle marker.
    console.error("finished room signal deferred", error?.message || error);
    return false;
  }
}

async function dispatchRoomPushBestEffort(base44, room, action) {
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!internalSecret || !room?.id) return false;
  const sourceEventIDs = [];
  if (
    action === "complete_game_start" && clean(room.status) === "playing" &&
    clean(room.game_started_event_id)
  ) {
    sourceEventIDs.push(clean(room.game_started_event_id));
  }
  if (isCommittedFinishedRoom(room)) {
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
    // process_event already synchronizes the matching ActivityKit generation
    // before it drains the ordinary alert. Avoid invoking the same terminal
    // sync twice on the hottest post-game path.
    if (!sourceEventIDs.length && shouldSynchronizeLiveActivity(action, room)) {
      await base44.asServiceRole.functions.invoke("pushNotificationAction", {
        action: "sync_live_activity",
        room_id: clean(room.id),
        match_id: clean(room.match_id),
        internal_secret: internalSecret,
      });
    }
    return true;
  } catch (error) {
    console.error("room push dispatch deferred", error?.message || error);
    return false;
  }
}

async function dispatchRoomSideEffectsAfterLeases(base44, room, action) {
  if (!isCommittedFinishedRoom(room)) {
    await dispatchRoomPushBestEffort(base44, room, action);
    return room;
  }
  const run = await runTerminalSideEffectsSingleFlight({
    store: base44.asServiceRole.entities.GameRoom,
    room,
    dispatch: async (claimedRoom) => {
      if (!(await dispatchRoomPushBestEffort(base44, claimedRoom, action))) {
        return false;
      }
      // Polling is the realtime fallback. Once the durable push/ActivityKit
      // pipeline succeeds, a transient signal write must not cause it to be
      // replayed after the source lease expires.
      await fanoutDeferredFinishedRoomSignal(base44, claimedRoom);
      return true;
    },
  });
  if (run.outcome === "failed") {
    // The bounded source claim expires for a later explicit retry. Independently,
    // the scheduled push drain continues to repair and deliver the durable
    // outbox even when the initiating request disappears.
    console.error("terminal room side effects deferred");
  }
  return run.room;
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
  let actionForLog = null;
  let roomIDForLog = null;
  try {
    if (req.method !== "POST") {
      return jsonError("Method not allowed", 405);
    }
    if (!hasTrustedRoomActionContext(req)) {
      return jsonError("Unauthorized", 401);
    }
    const body = await req.json().catch(() => ({}));
    const accessToken = clean(body?.access_token);
    const base44 = createClientFromRequest(canonicalRoomActionRequest(req));

    // The function gateway does not accept every provider/SSO token as its
    // Authorization header. Verify that token directly against Base44, while
    // keeping createClientFromRequest for server-side service-role access.
    // If the browser has an authenticated SSO/cookie session but no readable
    // storage token, the request client is also allowed to resolve that user.
    let user;
    try {
      user = await resolveRoomActionUser({
        accessToken,
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
    actionForLog = safeLogLabel(action);

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
            const created = await createRoom(base44, user, body);
            await fanoutGameRoomSignalsBestEffort({
              store: base44.asServiceRole.entities.GameRoomSignal,
              room: created,
              logError: (message, error) =>
                console.error(message, error?.message || error),
            });
            return created;
          } finally {
            delete base44.__spyclashRoomWriteLeaseContext;
          }
        },
      });
      return Response.json(roomForClient(result, user));
    }

    let room = roomId
      ? await fetchRoom(base44, roomId)
      : await fetchRoomByCode(base44, body?.room_code || body?.code);
    roomIDForLog = safeLogLabel(room?.id);

    if (action === "leave_room" && roomLeaveAlreadyComplete(room, user.email)) {
      return Response.json({ success: true });
    }
    if (!room) return jsonError("Room not found", 404);
    if (
      action !== "join_room" && action !== "leave_room" &&
      roomHasDepartedPlayer(room, user.email)
    ) {
      throw Object.assign(new Error("This operative left the mission"), {
        status: 403,
        code: "room_departed",
      });
    }
    if (action !== "join_room") assertRoomClientCompatible(room, user);
    if (action === "get_room") {
      requirePlayer(room, user);
      return Response.json(roomForClient(room, user));
    }

    if (action !== "join_room") requirePlayer(room, user);

    if (action === "finalize_expired_room") {
      assertExpectedTimerFinalizationScope(room, body);
    }

    if (EXPLICIT_TIMER_FINALIZE_ACTIONS.has(action)) {
      if (normalizedStatus(room) === "finished") {
        room = await dispatchRoomSideEffectsAfterLeases(base44, room, action);
        if (!room) return jsonError("Room not found", 404);
        return Response.json(roomForClient(room, user));
      }
      if (pendingTerminalIntent(room)) {
        const reconciled = await waitForCommittedTerminalRoom(base44, room);
        if (!reconciled) return jsonError("Room not found", 404);
        room = reconciled;
        if (action === "finalize_expired_room") {
          assertExpectedTimerFinalizationScope(room, body);
        }
        if (normalizedStatus(room) === "finished") {
          room = await dispatchRoomSideEffectsAfterLeases(
            base44,
            room,
            action,
          );
          if (!room) return jsonError("Room not found", 404);
          return Response.json(roomForClient(room, user));
        }
      }
    }

    // Capture whether this exact server request entered during an active vote
    // before it can wait behind lifecycle leases. Client-supplied values are
    // overwritten, so only a genuinely concurrent request can reconcile a
    // vote that another final cast settles while this request is waiting.
    const actionBody = action === "cast_detective_vote"
      ? (() => {
        const explicitRoundID = explicitExpectedVoteRoundID(body);
        const enteredActiveRound = detectiveVoteCastEnteredActiveRound(
          room,
          user.email,
          body?.target_email,
          explicitRoundID,
        );
        const currentRoundID = detectiveVoteRoundID(room);
        return {
          ...body,
          __server_vote_cast_started_active: enteredActiveRound,
          __server_vote_cast_match_id: clean(room.match_id),
          // Legacy clients omit the expected id. An already-active room from
          // before this field existed is lazily assigned one; the same captured
          // value is committed with the cast CAS or invalidated by a winner.
          __server_vote_cast_round_id: currentRoundID ||
            (enteredActiveRound && !explicitRoundID ? crypto.randomUUID() : ""),
        };
      })()
      : body;

    // Capability refresh mutates the authenticated participant record and must
    // use the full lifecycle lease path even when the gameplay action itself
    // would normally qualify for an unleased fast CAS.
    const fastRoomAction = !actorCapabilityRefreshNeeded(
      room,
      user,
      actionBody,
    ) && canUseFastRoomAction(action, room, user);
    const startedAt = performance.now();
    let readOnlyCastLeaseRecovery = false;
    let result;
    if (fastRoomAction) {
      base44.__spyclashFastRoomWriteContext = true;
      try {
        result = await executeRoomActionWithSignal(
          base44,
          action,
          room,
          user,
          actionBody,
          { allowSignalCreate: false },
        );
      } finally {
        delete base44.__spyclashFastRoomWriteContext;
      }
    } else {
      result = await retryRoomMembershipChangeBeforeAction({
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
            roomLeaveAlreadyComplete(acquisitionRoom, user.email)
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
            attempts: EXPLICIT_TIMER_FINALIZE_ACTIONS.has(action)
              ? 1
              : undefined,
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
                  roomLeaveAlreadyComplete(latestRoom, user.email)
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
                const revisionMigratedRoom = await backfillRoomWriteRevision(
                  base44,
                  latestRoom,
                );
                const migratedRoom = await backfillRoomParticipantUserIDs(
                  base44,
                  revisionMigratedRoom,
                  latestParticipantUserIDs,
                );
                markActionStarted();
                return await executeRoomActionWithSignal(
                  base44,
                  action,
                  migratedRoom,
                  user,
                  actionBody,
                );
              } finally {
                delete base44.__spyclashRoomWriteLeaseContext;
              }
            },
          });
        },
      }).catch((error) => {
        if (EXPLICIT_TIMER_FINALIZE_ACTIONS.has(action)) {
          return reconcileTerminalFinalizationAfterLeaseConflict({
            action,
            error,
            refetch: () => fetchRoom(base44, room.id),
            validate: (candidate) => {
              requirePlayer(candidate, user);
              if (action === "finalize_expired_room") {
                assertExpectedTimerFinalizationScope(candidate, actionBody);
              }
            },
            delay,
          });
        }
        if (action === "cast_detective_vote") {
          return reconcileDetectiveVoteCastAfterActiveIdentityLease({
            action,
            error,
            requestEnteredActiveVote:
              actionBody?.__server_vote_cast_started_active === true,
            expectedMatchID: actionBody?.__server_vote_cast_match_id,
            expectedRoundID: explicitExpectedVoteRoundID(actionBody) ||
              actionBody?.__server_vote_cast_round_id,
            actorEmail: user.email,
            targetEmail: actionBody?.target_email,
            refetch: () => fetchRoom(base44, room.id),
            assertParticipant: (candidate) => requirePlayer(candidate, user),
            delay,
          }).then((recoveredRoom) => {
            // Reconciliation only observes the competing leased writer. Do not
            // fan out or invoke push functions from this unleased request.
            readOnlyCastLeaseRecovery = true;
            return recoveredRoom;
          });
        }
        if (action === "complete_game_start") {
          return reconcileCommittedGameStartAfterActiveIdentityLease({
            action,
            error,
            refetch: () => fetchRoom(base44, room.id),
            assertParticipant: (candidate) => requirePlayer(candidate, user),
            repair: (candidate) =>
              repairDetectedCommittedGameStart(base44, candidate, user),
          });
        }
        return recoverSafeRoomActionAfterActiveIdentityLease({
          action,
          error,
          recover: async () => {
            const recoveryRoom = await fetchRoom(base44, room.id);
            if (!recoveryRoom) {
              throw Object.assign(new Error("Room not found"), { status: 404 });
            }
            requirePlayer(recoveryRoom, user);
            console.warn(
              `${action} continuing through an active identity lease`,
              { room_id: clean(recoveryRoom.id) },
            );

            // This recovery is intentionally limited to the actor's
            // acknowledgement. Membership-changing actions must wait for the
            // participant leases held by committed-start reconciliation.
            const recoveryOptions = {
              allowActiveIdentityLeaseRecovery: true,
            };
            return await markRoleCardRead(
              base44,
              recoveryRoom,
              user,
              recoveryOptions,
            );
          },
        });
      });
    }
    if (fastRoomAction) {
      console.info("gameRoomAction fast-path timing", {
        action,
        room_id: clean(room.id),
        duration_ms: Math.round(performance.now() - startedAt),
        room_revision: roomWriteRevision(result),
      });
    }
    if (result?.id && !readOnlyCastLeaseRecovery) {
      // Finish push repair and ActivityKit delivery must complete after the
      // participant room leases are released and before realtime wakes every
      // client to unregister its token against the same account lease.
      result = await dispatchRoomSideEffectsAfterLeases(
        base44,
        result,
        action,
      );
      if (!result) return jsonError("Room not found", 404);
    }
    return Response.json(result?.id ? roomForClient(result, user) : result);
  } catch (error) {
    const status = lifecycleHTTPStatus(error);
    console.error("gameRoomAction error", {
      action: actionForLog,
      room_id: roomIDForLog,
      code: safeLogLabel(error?.code),
      status,
    });
    return jsonError(
      error?.message || "Internal error",
      status,
      { code: error?.code, retryable: error?.retryable },
    );
  }
});

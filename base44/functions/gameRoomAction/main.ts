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
import { reconcileCommunityProfileMirrors } from "./community-profile-mirror.ts";
import { runCommunityProfileBackfillPage } from "./community-profile-backfill.ts";
import {
  gameHistoryResultKey,
  persistGameHistoryResult,
} from "./game-history-idempotency.ts";
import {
  dueCommunityProfileRepairSources,
  ensureCommunityProfileRepairSource,
  pendingCommunityProfileRepairFields,
  repairCommunityProfileRecipients,
  runCommunityProfileRepair,
} from "./community-profile-repair-queue.ts";
import {
  activeGameLobbyReturnCanUseFastPath,
  activeGameLobbyReturnTransition,
} from "./active-game-lobby-return-policy.ts";
import { lobbyKickTransition } from "./lobby-kick-policy.ts";
import { hostDepartureUsesMembershipTransition } from "./finished-room-departure-policy.ts";
import {
  replayResetMembershipPatch,
  replayVoteState,
  replayVoteTransition,
} from "./replay-policy.ts";
import {
  assertExpectedReplaySourceMatch,
  replayAutoStartAlreadyComplete,
  replayAutoStartPatch,
  replaySourceMatchID,
} from "./replay-auto-start-policy.ts";
import {
  assertIntroCompletionAccess,
  assertRankedTerminalRoom,
  assertServerRankedFinishSource,
  buildTerminalIntent,
  deriveExpiredGameWinner,
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
import {
  allowsOrphanedActorIdentityRebind,
  canRebindOrphanedActorIdentity,
  roomIdentityLifecycleUserIDs,
  roomParticipantIdentityBackfillPlan,
  storedRoomParticipantUserIDs,
} from "./room-participant-identity.ts";
import {
  commitGamePushEvents,
  enqueueGamePushEvents,
  gamePushCommitCoversRecipients,
  gamePushRecipientUserIDs,
} from "./push-events.ts";
import {
  createOpaqueTimingID,
  createSpyGuessSideEffectTiming,
  createTerminalPhaseTiming,
  normalizeOpaqueTimingID,
  spyGuessResponseTiming,
} from "./terminal-timing.ts";
import { runWithWallClockDeadline } from "./operation-deadline.ts";
import {
  runLatestRoomSignalAfterLeaseContention,
  runPostLeaseSignalWithinDeadline,
} from "./post-lease-signal.ts";
import { nextRoundNumber } from "./game-round.ts";
import {
  internalPushSecret,
  matchesInternalPushSecret,
} from "./internal-push.ts";
import {
  assertLobbySettingsAccess,
  deleteRoomAndVerify,
  gameDurationPatch,
  gameModePatch,
  leaveAlreadyComplete,
  liveActivityEndQueueCoversRegistrations,
  liveActivityEndQueueMatchesRoom,
  loadActiveRoomLiveActivityRegistrations,
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
import {
  fanoutGameRoomSignalsBestEffort,
  hasDurableClosedRoomSignal,
  lobbyModeSignalProjectionForRepair,
  lobbyModeSignalProjectionForRoom,
} from "./game-room-signal.ts";
import { fanoutCommunityProfileInvalidations } from "./community-profile-signal.ts";
import {
  advanceAssociationTurn,
  associationRosterChangePatch,
  encodeAssociationTurnState,
  initialAssociationTurn,
  reconcileAssociationTurnState,
} from "./association-turn-order.ts";
import {
  questionAdvancePatch,
  questionContinueTurnPatch,
} from "./question-round-policy.ts";
import {
  encodeQuestionTurnOrderState,
  initialQuestionTurn,
  questionRosterChangePatch,
} from "./question-turn-order.ts";
import { shouldSynchronizeLiveActivity } from "./room-push-policy.ts";
import {
  assertActiveRoundActor,
  assertRoundActionMode,
} from "./round-action-access.ts";
import { reconcileTerminalFinalizationAfterLeaseConflict } from "./terminal-finalization-recovery.ts";
import { assertExpectedTimerFinalizationScope } from "./terminal-finalization-scope.ts";
import { runTerminalSideEffectsSingleFlight } from "./terminal-side-effect-dispatch.ts";
import {
  isRoomWriteCASConflict,
  roomWriteRevision,
  writeRoomWithCAS,
} from "./room-write-cas.ts";
import {
  assertExpectedMembershipGeneration,
  captureRoomExitMembershipGeneration,
  playerMembershipGeneration,
  validatedExpectedMembershipGeneration,
  validatedMembershipGeneration,
} from "./room-membership-generation.ts";
import {
  exactRoomCloseCompletion,
  exactRoomCloseIntent,
  newRoomCloseCompletion,
  newRoomCloseIntent,
  roomCloseActivityEndCommitID,
  roomCloseActivityEndIsQueued,
  roomCloseCompletionCoversSignals,
  roomCloseCompletionWithActivityEndQueued,
  verifiedRoomCloseCompletionDominatesSnapshot,
} from "./room-close-intent.ts";
import {
  assertTerminalOutboxCommitBeforeAuthorityReset,
  terminalOutboxCommitIsProven,
  terminalOutboxCommitPatch,
} from "./terminal-outbox-commit.ts";
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

function terminalIntentNeedsReconciliation(room) {
  const intent = terminalIntentFromRoom(room);
  return intent && !terminalOutboxCommitIsProven(room) ? intent : null;
}

function assertActionMatchGeneration(room, body) {
  const currentMatchID = clean(room?.match_id);
  const clientMatchID = clean(body?.expected_match_id);
  const serverCapturedMatchID = clean(body?.__server_action_match_id);
  if (
    !currentMatchID || (clientMatchID && clientMatchID !== currentMatchID) ||
    (serverCapturedMatchID && serverCapturedMatchID !== currentMatchID)
  ) {
    throw Object.assign(
      new Error("This action belongs to an older match. Refresh and retry."),
      { status: 409, code: "room_match_generation_conflict" },
    );
  }
  return currentMatchID;
}

function assertKickTargetMembershipGeneration(room, user, body) {
  const transition = lobbyKickTransition(room, user.email, {
    target_user_id: body?.target_user_id,
    target_email: body?.target_email,
  });
  const currentGeneration = playerMembershipGeneration(
    room,
    transition.removedPlayer,
  );
  const clientGeneration = clean(body?.expected_target_membership_id);
  const serverCapturedGeneration = clean(
    body?.__server_kick_target_membership_id,
  );
  if (
    !currentGeneration ||
    (clientGeneration && clientGeneration !== currentGeneration) ||
    (serverCapturedGeneration &&
      serverCapturedGeneration !== currentGeneration)
  ) {
    throw Object.assign(
      new Error("The kick target rejoined; refresh the lobby before retrying."),
      { status: 409, code: "kick_target_membership_conflict" },
    );
  }
  return { transition, generation: currentGeneration };
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

function assertRoomMutationOpen(
  room,
  allowPendingTerminal = false,
  allowCloseIntent = false,
) {
  if (!allowCloseIntent && room?.close_intent) {
    throw Object.assign(
      new Error("The room is already closing."),
      { status: 409, code: "room_close_pending", retryable: true },
    );
  }
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
  assertRoomMutationOpen(
    room,
    options.allowPendingTerminal === true,
    options.allowCloseIntent === true,
  );
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
    assertRoomMutationOpen(
      latest,
      options.allowPendingTerminal === true,
      options.allowCloseIntent === true,
    );

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

async function enqueueRoomLiveActivityEnd(
  base44,
  room,
  closeCompletion = null,
) {
  const roomID = clean(closeCompletion?.room_id || room?.id);
  const matchID = clean(closeCompletion?.match_id || room?.match_id);
  const closeIntent = exactRoomCloseIntent(room);
  const terminalCommitID = closeCompletion
    ? roomCloseActivityEndCommitID(closeCompletion)
    : normalizedStatus(room) === "finished"
    ? clean(room?.game_finished_event_id)
    : closeIntent && matchID
    ? `room-close:${matchID}:${clean(closeIntent.id)}`
    : "";
  // A waiting lobby has no ActivityKit match binding. The participant-lease
  // phase still records a durable no-work queue receipt before deletion.
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
    await runWithWallClockDeadline({
      timeoutMS: 2_000,
      operation: () =>
        base44.asServiceRole.functions.invoke("pushNotificationAction", {
          action: "enqueue_room_live_activity_end",
          room_id: roomID,
          match_id: matchID,
          ...(terminalCommitID ? { terminal_commit_id: terminalCommitID } : {}),
          ...(closeCompletion ? { close_completion: closeCompletion } : {}),
          internal_secret: internalSecret,
        }),
      timeoutError: () =>
        Object.assign(
          new Error("Live Activity end queue exceeded its deadline."),
          { status: 503, code: "live_activity_end_queue_timeout" },
        ),
    });
  } catch (error) {
    console.error(
      "room Live Activity end deferred",
      error instanceof Error ? error.message : error,
    );
    throw Object.assign(
      new Error("Could not queue the Lock Screen session end; retry."),
      {
        status: 503,
        code: clean(error?.code) || "live_activity_end_unavailable",
        retryable: true,
      },
    );
  }
}

function stageQueuedLiveActivityEndDelivery(base44, room) {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  if (!roomID || !matchID) return;
  base44.__spyclashPendingLiveActivityEndDelivery = {
    roomID,
    matchID,
  };
}

function stageCompletedRoomClose(base44, room, completion) {
  base44.__spyclashPendingCompletedRoomClose = { room, completion };
}

async function triggerQueuedLiveActivityEndDelivery(
  base44,
  roomIDValue,
  matchIDValue,
) {
  const roomID = clean(roomIDValue);
  const matchID = clean(matchIDValue);
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!internalSecret || !roomID || !matchID) return false;
  // This is only a prompt attempt. The enqueue intent remains the durable
  // boundary and the scheduled drain owns recovery if this nested invocation
  // is cancelled or misses a registration that arrives concurrently.
  const deliveryDeadlineEpochMS = Date.now() + 20_000;
  try {
    await runWithWallClockDeadline({
      timeoutMS: 250,
      operation: () =>
        base44.asServiceRole.functions.invoke("pushNotificationAction", {
          action: "deliver_queued_room_live_activity_end",
          room_id: roomID,
          match_id: matchID,
          deadline_epoch_ms: deliveryDeadlineEpochMS,
          internal_secret: internalSecret,
        }),
      timeoutError: () =>
        Object.assign(
          new Error("Prompt Live Activity end delivery was deferred."),
          { status: 503, code: "live_activity_end_delivery_deferred" },
        ),
    });
    return true;
  } catch (error) {
    console.warn(
      "prompt Live Activity end delivery deferred",
      error instanceof Error ? error.message : error,
    );
    return false;
  }
}

async function triggerStagedLiveActivityEndDelivery(base44) {
  const staged = base44.__spyclashPendingLiveActivityEndDelivery;
  delete base44.__spyclashPendingLiveActivityEndDelivery;
  if (!staged) return false;
  return await triggerQueuedLiveActivityEndDelivery(
    base44,
    staged.roomID,
    staged.matchID,
  );
}

function roomSignalRecipients(room, state = "active") {
  return uniqueStrings([
    ...(room?.participant_user_ids || []),
    ...players(room).map((player) => player.user_id),
  ]).map((userID) => ({ user_id: userID, state }));
}

function stageGameRoomSignalFanout(base44, input) {
  base44.__spyclashPendingGameRoomSignalFanout = input;
}

function authoritativeRoomForSignalRepair(currentRoom, observedRoom) {
  if (!observedRoom?.id) return null;
  const currentRevision = roomWriteRevision(currentRoom);
  const observedRevision = roomWriteRevision(observedRoom);
  if (currentRevision === null) return observedRoom;
  if (observedRevision === null || observedRevision < currentRevision) {
    // An eventually consistent read must never downgrade the already committed
    // CAS result that entered this post-commit signal path.
    return currentRoom;
  }
  return observedRoom;
}

function lobbyModeSignalCandidate(room, allowCreate, committedModeSignal) {
  if (!room?.id) return null;
  if (room?.close_intent || normalizedStatus(room) !== "waiting") {
    return {
      room,
      recipients: [],
      projection: null,
      allowCreate,
      obsolete: true,
    };
  }
  const projection = lobbyModeSignalProjectionForRepair(
    committedModeSignal?.room || {},
    room,
    committedModeSignal?.projection,
  );
  return {
    room,
    recipients: roomSignalRecipients(room, "active"),
    projection,
    allowCreate,
    obsolete: false,
  };
}

function authoritativeSignalReadPending() {
  return Object.assign(
    new Error("Authoritative room signal repair read is not visible yet."),
    { code: "room_signal_authoritative_read_pending", retryable: true },
  );
}

async function fanoutStagedGameRoomSignalsAfterLeases(base44) {
  const staged = base44.__spyclashPendingGameRoomSignalFanout;
  delete base44.__spyclashPendingGameRoomSignalFanout;
  if (!staged?.room?.id) return true;
  const recipients = Array.isArray(staged.recipients)
    ? staged.recipients
    : roomSignalRecipients(staged.room, staged.state || "active");
  const userIDs = uniqueStrings(
    recipients.map((recipient) => recipient?.user_id),
  );
  if (!userIDs.length) return true;
  const initialCandidate = {
    room: staged.room,
    recipients,
    projection: staged.projection,
    allowCreate: staged.allowCreate !== false,
    obsolete: false,
  };
  const isLobbyModeProjection = clean(staged.projection?.projection_kind) ===
    "lobby_mode_v1";
  const committedModeSignal = isLobbyModeProjection
    ? { room: staged.room, projection: staged.projection }
    : null;
  return await runPostLeaseSignalWithinDeadline({
    timeoutMS: 600,
    leasedOperation: async () => {
      const attempt = async (candidate, context) => {
        if (candidate.obsolete) return true;
        const candidateUserIDs = uniqueStrings(
          candidate.recipients.map((recipient) => recipient?.user_id),
        );
        if (!candidateUserIDs.length) return true;
        return await withRoomWriteLeases({
          lifecycleStore:
            base44.asServiceRole.entities.BillingIdentityLifecycle,
          userIDs: candidateUserIDs,
          // The outer bounded mode repair owns retry timing so every retry can
          // refetch the newest room revision before taking identity leases.
          attempts: 1,
          action: async (leaseContext) => {
            let exact = candidate;
            if (context.isRepair) {
              const observed = await fetchRoom(base44, candidate.room.id);
              if (!observed) throw authoritativeSignalReadPending();
              const authoritative = authoritativeRoomForSignalRepair(
                candidate.room,
                observed,
              );
              if (!authoritative) throw authoritativeSignalReadPending();
              exact = lobbyModeSignalCandidate(
                authoritative,
                candidate.allowCreate,
                committedModeSignal,
              );
              if (exact.obsolete) return true;
              assertExactRoomLeaseCoverage(
                leaseContext,
                exact.recipients.map((recipient) => recipient?.user_id),
              );
            }
            const result = await fanoutGameRoomSignalsBestEffort({
              store: base44.asServiceRole.entities.GameRoomSignal,
              room: exact.room,
              recipients: exact.recipients,
              projection: exact.projection,
              // Fast mode actions never recreate a signal removed by account
              // cleanup. Leased non-fast callers preserve their prior policy.
              allowCreate: exact.allowCreate,
              logError: (message, error) =>
                console.error(message, error?.message || error),
            });
            return Number(result?.failed) === 0;
          },
        });
      };

      if (!isLobbyModeProjection) {
        return await attempt(initialCandidate, {
          attempt: 1,
          isRepair: false,
        });
      }

      return await runLatestRoomSignalAfterLeaseContention({
        initial: initialCandidate,
        attempt,
        loadLatest: async (current) => {
          const observed = await fetchRoom(base44, current.room.id);
          if (!observed) return null;
          const authoritative = authoritativeRoomForSignalRepair(
            current.room,
            observed,
          );
          return authoritative
            ? lobbyModeSignalCandidate(
              authoritative,
              current.allowCreate,
              committedModeSignal,
            )
            : null;
        },
      });
    },
    // The independently owned lifecycle lease remains attached to late work,
    // while polling guarantees convergence if this bounded wake-up is delayed.
    logError: (message, error) =>
      console.error(message, error?.message || error),
  });
}

async function assertLiveActivityEndQueueCoverage(base44, room) {
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  if (!roomID || !matchID) return;
  const registrations = await runWithWallClockDeadline({
    timeoutMS: 600,
    operation: async () =>
      await loadActiveRoomLiveActivityRegistrations(
        base44.asServiceRole.entities.LiveActivityRegistration,
        roomID,
      ),
    timeoutError: () =>
      Object.assign(
        new Error("Live Activity end verification exceeded its deadline."),
        {
          status: 503,
          code: "live_activity_end_verification_timeout",
          retryable: true,
        },
      ),
  });
  if (!liveActivityEndQueueCoversRegistrations(room, registrations)) {
    throw Object.assign(
      new Error("A new Lock Screen token must be queued before closing."),
      {
        status: 503,
        code: "live_activity_end_coverage_incomplete",
        retryable: true,
      },
    );
  }
}

async function ensureRoomCloseIntent(base44, room) {
  const existing = exactRoomCloseIntent(room);
  if (existing) return room;
  if (room?.close_intent) {
    throw Object.assign(
      new Error("The room close intent is invalid."),
      { status: 503, code: "room_close_intent_invalid", retryable: true },
    );
  }
  const currentRevision = roomWriteRevision(room);
  if (currentRevision === null) {
    throw Object.assign(new Error("Room write revision is missing."), {
      status: 503,
      code: "room_revision_missing",
      retryable: true,
    });
  }
  const intent = newRoomCloseIntent({
    room,
    nextRoomRevision: currentRevision + 1,
    participantUserIDs: roomSignalRecipients(room).map((recipient) =>
      recipient.user_id
    ),
  });
  return await updateRoom(base44, room, { close_intent: intent }, {
    allowPendingTerminal: true,
    allowCloseIntent: true,
  });
}

async function persistClosedRoomSignals(base44, room) {
  const intent = exactRoomCloseIntent(room);
  if (!intent) {
    throw Object.assign(new Error("Room close intent is required."), {
      status: 503,
      code: "room_close_intent_missing",
      retryable: true,
    });
  }
  await assertRoomPersistenceBoundary(base44);
  const recipients = roomSignalRecipients(room, "closed");
  const result = await fanoutGameRoomSignalsBestEffort({
    store: base44.asServiceRole.entities.GameRoomSignal,
    room,
    recipients,
    closeReceipt: {
      intent_id: intent.id,
      match_id: intent.match_id,
    },
    logError: (message, error) =>
      console.error(message, error?.message || error),
  });
  if (Number(result?.failed) > 0) {
    throw Object.assign(
      new Error("Room closure signals could not be committed; retry."),
      { status: 503, code: "room_close_signal_deferred", retryable: true },
    );
  }

  // A per-recipient close receipt can be written before another recipient's
  // write fails. Publish the completion tombstone only in a second pass after
  // every close signal succeeded, so any one exact tombstone proves the whole
  // participant fanout reached its durable boundary.
  const completion = newRoomCloseCompletion({ room });
  const completionResult = await fanoutGameRoomSignalsBestEffort({
    store: base44.asServiceRole.entities.GameRoomSignal,
    room,
    recipients,
    closeReceipt: {
      intent_id: intent.id,
      match_id: intent.match_id,
      completion,
    },
    logError: (message, error) =>
      console.error(message, error?.message || error),
  });
  if (Number(completionResult?.failed) > 0) {
    throw Object.assign(
      new Error("Room closure completion could not be committed; retry."),
      { status: 503, code: "room_close_completion_deferred", retryable: true },
    );
  }
  const persistedSignals = await base44.asServiceRole.entities.GameRoomSignal
    .filter({ room_id: clean(room.id) }) || [];
  if (!roomCloseCompletionCoversSignals(persistedSignals, completion)) {
    throw Object.assign(
      new Error("Room closure completion is not yet visible; retry."),
      {
        status: 503,
        code: "room_close_completion_unverified",
        retryable: true,
      },
    );
  }
  return completion;
}

function unconfirmedRoomCloseError() {
  return Object.assign(
    new Error("Room closure is not yet confirmed; retry."),
    { status: 503, code: "room_close_unconfirmed", retryable: true },
  );
}

function unconfirmedRoomExitError() {
  return Object.assign(
    new Error("Room exit is not yet confirmed; retry."),
    { status: 503, code: "room_exit_unconfirmed", retryable: true },
  );
}

function expectedRoomExitRevision(body) {
  const value = body?.expected_revision;
  if (value === null || value === undefined || clean(value) === "") return null;
  const candidate = Number(value);
  return Number.isInteger(candidate) && candidate >= 0 ? candidate : null;
}

function expectedRoomExitMembershipID(body) {
  return validatedExpectedMembershipGeneration(body?.expected_membership_id);
}

function boundRoomExitMembershipID(body) {
  return expectedRoomExitMembershipID(body) ||
    clean(body?.__server_room_exit_membership_id);
}

async function durableRoomExitIsCommitted(
  base44,
  roomIDValue,
  userIDValue,
  expectedRevisionValue,
) {
  const roomID = clean(roomIDValue);
  const userID = clean(userIDValue);
  const expectedRevision = expectedRoomExitRevision({
    expected_revision: expectedRevisionValue,
  });
  if (
    !roomID || !userID || expectedRevision === null
  ) return false;
  let signals;
  try {
    signals = await base44.asServiceRole.entities.GameRoomSignal.filter({
      room_id: roomID,
    }) || [];
  } catch {
    throw unconfirmedRoomExitError();
  }
  return hasDurableClosedRoomSignal(
    signals,
    roomID,
    userID,
    expectedRevision,
  );
}

async function persistClosedRoomSignalForUserUnderLeases(
  base44,
  room,
  userIDValue,
  expectedRevisionValue,
) {
  const userID = clean(userIDValue);
  const expectedRevision = expectedRoomExitRevision({
    expected_revision: expectedRevisionValue,
  });
  const context = base44.__spyclashRoomWriteLeaseContext;
  if (!context || !userID) throw unconfirmedRoomExitError();
  if (
    expectedRevision !== null &&
    (roomWriteRevision(room) === null ||
      roomWriteRevision(room) < expectedRevision)
  ) throw unconfirmedRoomExitError();
  await assertRoomWriterLeaseForUser(context, userID);
  const closeIntent = exactRoomCloseIntent(room);
  const result = await fanoutGameRoomSignalsBestEffort({
    store: base44.asServiceRole.entities.GameRoomSignal,
    room,
    recipients: [{ user_id: userID, state: "closed" }],
    ...(closeIntent
      ? {
        closeReceipt: {
          intent_id: closeIntent.id,
          match_id: closeIntent.match_id,
        },
      }
      : {}),
    logError: (message, error) =>
      console.error(message, error?.message || error),
  });
  if (Number(result?.failed) > 0) throw unconfirmedRoomExitError();
  const persisted = await base44.asServiceRole.entities.GameRoomSignal.filter({
    user_id: userID,
    room_id: clean(room?.id),
  }) || [];
  if (
    !hasDurableClosedRoomSignal(
      persisted,
      room?.id,
      userID,
      expectedRevision ?? 0,
    )
  ) {
    // `unchanged` can mean a stale departed-room snapshot lost to a newer
    // active rejoin signal. Only the resulting latest personal signal may
    // acknowledge the exit.
    throw unconfirmedRoomExitError();
  }
}

async function persistClosedRoomSignalForUser(
  base44,
  room,
  userIDValue,
  expectedRevisionValue,
) {
  const userID = clean(userIDValue);
  if (!userID) throw unconfirmedRoomExitError();
  await withRoomWriteLeases({
    lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
    userIDs: [userID],
    action: async (context) => {
      base44.__spyclashRoomWriteLeaseContext = context;
      try {
        await persistClosedRoomSignalForUserUnderLeases(
          base44,
          room,
          userID,
          expectedRevisionValue,
        );
      } finally {
        delete base44.__spyclashRoomWriteLeaseContext;
      }
    },
  });
}

async function completedRoomCloseForHost(base44, roomIDValue, userIDValue) {
  const roomID = clean(roomIDValue);
  const userID = clean(userIDValue);
  if (!roomID || !userID) return null;
  let signals;
  try {
    signals = await base44.asServiceRole.entities.GameRoomSignal.filter({
      room_id: roomID,
    }) || [];
  } catch {
    throw unconfirmedRoomCloseError();
  }
  for (const signal of signals) {
    if (clean(signal?.user_id) !== userID) continue;
    const completion = exactRoomCloseCompletion(signal, roomID, userID);
    if (
      completion && clean(completion.host_user_id) === userID &&
      roomCloseCompletionCoversSignals(signals, completion)
    ) {
      return completion;
    }
  }
  return null;
}

function roomForCloseCompletion(completion) {
  return {
    id: clean(completion?.room_id),
    match_id: clean(completion?.match_id),
    close_intent: {
      id: clean(completion?.intent_id),
      room_id: clean(completion?.room_id),
      match_id: clean(completion?.match_id),
    },
  };
}

async function persistRoomCloseActivityEndQueuedUnderLeases(
  base44,
  completion,
) {
  const participantUserIDs = uniqueStrings(
    completion?.participant_user_ids || [],
  );
  const context = base44.__spyclashRoomWriteLeaseContext;
  if (!context || !participantUserIDs.length) {
    throw unconfirmedRoomCloseError();
  }
  assertExactRoomLeaseCoverage(context, participantUserIDs);
  const roomID = clean(completion?.room_id);
  const signals = await base44.asServiceRole.entities.GameRoomSignal.filter({
    room_id: roomID,
  }) || [];
  if (!roomCloseCompletionCoversSignals(signals, completion)) {
    throw unconfirmedRoomCloseError();
  }
  const durableQueuedCompletion = signals
    .map((signal) => exactRoomCloseCompletion(signal, roomID))
    .find((candidate) => roomCloseActivityEndIsQueued(candidate)) ||
    (roomCloseActivityEndIsQueued(completion)
      ? completion
      : roomCloseCompletionWithActivityEndQueued({ completion }));

  const rowsToUpdate = signals.filter((signal) => {
    const exact = exactRoomCloseCompletion(signal, roomID, signal?.user_id);
    return exact && clean(signal?.id) &&
      participantUserIDs.includes(clean(signal?.user_id)) &&
      !roomCloseActivityEndIsQueued(exact);
  });
  await Promise.all(
    rowsToUpdate.map((signal) =>
      base44.asServiceRole.entities.GameRoomSignal.update(clean(signal.id), {
        close_completion: durableQueuedCompletion,
      })
    ),
  );
  const persisted = await base44.asServiceRole.entities.GameRoomSignal.filter({
    room_id: roomID,
  }) || [];
  if (
    !roomCloseCompletionCoversSignals(persisted, durableQueuedCompletion) ||
    !participantUserIDs.every((userID) =>
      persisted.some((signal) => {
        const exact = exactRoomCloseCompletion(signal, roomID, userID);
        return clean(exact?.intent_id) === clean(completion?.intent_id) &&
          roomCloseActivityEndIsQueued(exact);
      })
    )
  ) {
    throw unconfirmedRoomCloseError();
  }
  return durableQueuedCompletion;
}

async function deleteCompletedRoomCloseUnderLeases(base44, completion) {
  const participantUserIDs = uniqueStrings(
    completion?.participant_user_ids || [],
  );
  const context = base44.__spyclashRoomWriteLeaseContext;
  if (!context || !participantUserIDs.length) {
    throw unconfirmedRoomCloseError();
  }
  assertExactRoomLeaseCoverage(context, participantUserIDs);
  await assertRoomPersistenceBoundary(base44);
  // The exact queue coverage is checked from durable registrations using the
  // completion itself, so an eventually-consistent missing GameRoom read can
  // never skip the ActivityKit phase. Only after that positive proof do all
  // participant tombstones receive the durable queue-complete marker.
  await assertLiveActivityEndQueueCoverage(
    base44,
    roomForCloseCompletion(completion),
  );
  completion = await persistRoomCloseActivityEndQueuedUnderLeases(
    base44,
    completion,
  );
  if (!roomCloseActivityEndIsQueued(completion)) {
    throw unconfirmedRoomCloseError();
  }
  const latest = await fetchRoom(base44, clean(completion.room_id));
  if (!verifiedRoomCloseCompletionDominatesSnapshot(completion, latest)) {
    throw unconfirmedRoomCloseError();
  }
  await deleteRoomAndVerify({
    roomID: clean(completion.room_id),
    deleteByID: async (roomID) => {
      try {
        return await base44.asServiceRole.entities.GameRoom.delete(roomID);
      } catch (error) {
        if (lifecycleHTTPStatus(error) === 404) return null;
        throw error;
      }
    },
    fetchByID: (roomID) => fetchRoom(base44, roomID),
    afterVerifiedDelete: async () => {
      stageQueuedLiveActivityEndDelivery(base44, {
        id: clean(completion.room_id),
        match_id: clean(completion.match_id),
      });
    },
    delay,
  });
  return { success: true };
}

async function recoverCompletedRoomClose(base44, completion, roomHint = null) {
  const participantUserIDs = uniqueStrings(
    completion?.participant_user_ids || [],
  );
  if (!participantUserIDs.length) throw unconfirmedRoomCloseError();
  const closingRoom = roomHint ||
    await fetchRoom(base44, clean(completion.room_id));
  if (!verifiedRoomCloseCompletionDominatesSnapshot(completion, closingRoom)) {
    throw unconfirmedRoomCloseError();
  }
  // This second phase runs after the original participant leases were
  // released. The push function can therefore acquire its per-user leases and
  // upgrade every prepared row with the exact close commit receipt. A stale
  // pre-intent room replica cannot override the already verified full-fanout
  // completion tombstone.
  // Completion fanout is the durable authorization source after a crash. The
  // push worker validates every participant tombstone, so it can enqueue the
  // exact close marker even when GameRoom temporarily reads as missing.
  await enqueueRoomLiveActivityEnd(base44, closingRoom, completion);
  const result = await withRoomWriteLeases({
    lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
    userIDs: participantUserIDs,
    action: async (context) => {
      base44.__spyclashRoomWriteLeaseContext = context;
      try {
        return await deleteCompletedRoomCloseUnderLeases(base44, completion);
      } finally {
        delete base44.__spyclashRoomWriteLeaseContext;
      }
    },
  });
  await triggerStagedLiveActivityEndDelivery(base44);
  return result;
}

async function finalizeStagedRoomCloseAfterLeases(base44) {
  const staged = base44.__spyclashPendingCompletedRoomClose;
  delete base44.__spyclashPendingCompletedRoomClose;
  if (!staged?.completion) return null;
  return await recoverCompletedRoomClose(
    base44,
    staged.completion,
    staged.room,
  );
}

async function deleteRoom(base44, room, options = {}) {
  if (options.allowActiveIdentityLeaseRecovery !== true) {
    await assertRoomPersistenceBoundary(base44);
  }
  let latest = await fetchRoom(base44, room.id);
  if (!latest) throw unconfirmedRoomCloseError();
  assertRoomMutationOpen(
    latest,
    options.allowPendingTerminal === true,
    true,
  );
  if (options.allowActiveIdentityLeaseRecovery !== true) {
    await assertRoomPersistenceBoundary(base44);
  }
  latest = await ensureTerminalOutboxCommitBeforeMutation(base44, latest);
  // Phase one commits the logical closure and the complete participant
  // tombstone under the original room leases. Physical deletion is staged for
  // a post-lease phase so ActivityKit can acquire its own per-user leases.
  const closingRoom = await ensureRoomCloseIntent(base44, latest);
  const completion = await persistClosedRoomSignals(base44, closingRoom);
  stageCompletedRoomClose(base44, closingRoom, completion);
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

function terminalHistoryRecords(room, winner) {
  const roomPlayers = players(room);
  assertRankedTerminalRoom(room, winner);
  const matchIdentity = rankedMatchIdentity(room);
  const spyEmails = canonicalSpyEmails(room);
  const spyKeys = new Set(
    spyEmails.map((email) => clean(email).toLocaleLowerCase()),
  );

  return roomPlayers.map((player) => {
    const isSpy = spyKeys.has(clean(player.email).toLocaleLowerCase());
    const won = winner === "spy" ? isSpy : !isSpy;
    const ranked = spyEmails.length === 1;
    return {
      match_id: matchIdentity.id,
      result_key: gameHistoryResultKey(matchIdentity.id, player.user_id),
      player_user_id: clean(player.user_id),
      player_email: player.email,
      room_code: room.code,
      match_type: "online",
      ranked,
      role: isSpy ? "spy" : "detective",
      word: displayWord(room) || "CLASSIFIED",
      category: clean(room.category) || "CLASSIC",
      winner,
      player_count: roomPlayers.length,
      spy_count: spyEmails.length,
      won,
      ...(ranked ? pendingCommunityProfileRepairFields() : {}),
    };
  });
}

async function archiveRoomResult(base44, room, winner) {
  const repairSources = [];
  for (const historyRecord of terminalHistoryRecords(room, winner)) {
    // Re-prove the exact player's live lifecycle lease immediately before
    // creating their retained history row. This prevents a deleteAccount race
    // from recreating raw identity after that player's cleanup completed.
    await assertRoomHistoryPersistenceBoundary(
      base44,
      historyRecord.player_user_id,
    );
    const persisted = await persistGameHistoryResult({
      store: base44.asServiceRole.entities.GameHistory,
      record: historyRecord,
    });
    if (historyRecord.ranked === true) {
      repairSources.push(
        await ensureCommunityProfileRepairSource({
          store: base44.asServiceRole.entities.GameHistory,
          record: {
            ...persisted.record,
            result_key: historyRecord.result_key,
          },
        }),
      );
    }
  }
  base44.__spyclashCommunityProfileRepairSources = {
    matchID: clean(room?.match_id),
    sources: repairSources,
  };
  return repairSources;
}

async function claimTerminalIntent(
  base44,
  room,
  requestedWinner,
  requestedPatch = {},
  attempts = 8,
  expectedMatchID = "",
) {
  let latest = room;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    latest = await fetchRoom(base44, latest.id);
    if (!latest) {
      throw Object.assign(new Error("Room not found"), { status: 404 });
    }
    if (
      clean(expectedMatchID) &&
      clean(latest.match_id) !== clean(expectedMatchID)
    ) {
      throw Object.assign(
        new Error("This terminal action belongs to an older match."),
        { status: 409, code: "room_match_generation_conflict" },
      );
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
        ready_players: [],
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

async function finishRoom(
  base44,
  room,
  winner,
  terminalPatch = {},
  options = {},
) {
  const terminalTiming = createTerminalPhaseTiming();
  let terminalOutcome = "failed";
  let timingRoom = room;

  try {
    terminalTiming.begin("terminal_claim");
    const claimed = await claimTerminalIntent(
      base44,
      room,
      winner,
      terminalPatch,
      8,
      options.expectedMatchID,
    );
    timingRoom = claimed.room;
    terminalTiming.complete("terminal_claim");
    const persistedPatch = terminalPatchFromIntent(claimed.intent);
    const finishedPausePatch = finishGamePauseTransitionPatch(
      claimed.room,
      claimed.intent.decided_at,
    );
    const finishedEventID = `game-finished:${clean(claimed.intent.match_id)}`;

    terminalTiming.begin("push_enqueue");
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
    terminalTiming.complete("push_enqueue");

    const terminal = {
      ...claimed.room,
      ...persistedPatch,
      ...finishedPausePatch,
      status: "finished",
      winner: claimed.intent.winner,
      detective_vote_round_id: "",
      ready_players: [],
      game_finished_event_id: finishedEventID,
    };
    // The immutable CAS-claimed terminal intent is persisted first. A retry can
    // only reconcile that same winner/payload, so history and room state cannot
    // diverge even if either write phase is interrupted.
    terminalTiming.begin("history_archive");
    await archiveRoomResult(base44, terminal, claimed.intent.winner);
    terminalTiming.complete("history_archive");

    terminalTiming.begin("room_commit");
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
              new Error(
                "The finished room conflicts with its terminal intent.",
              ),
              { status: 409, code: "terminal_state_conflict" },
            );
          }
          return {
            ...pausePatch,
            ...(detectiveVoteRoundID(latest)
              ? { detective_vote_round_id: "" }
              : {}),
            ...(readyPlayers(latest).length ? { ready_players: [] } : {}),
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
          ready_players: [],
          game_finished_event_id: finishedEventID,
        };
      },
      (latest) =>
        normalizedStatus(latest) === "finished" &&
        clean(latest.winner) === claimed.intent.winner,
      6,
      {
        allowPendingTerminal: true,
        allowCloseIntent: options.allowCloseIntent === true,
      },
    );
    timingRoom = finished;
    terminalTiming.complete("room_commit");

    terminalTiming.begin("push_commit");
    const committed = await commitGamePushEvents({
      store: base44.asServiceRole.entities.PushNotificationEvent,
      persist: async (writer) => {
        await assertRoomPersistenceBoundary(base44);
        return await writer();
      },
      eventType: "game_finished",
      sourceEventID: finishedEventID,
    });
    const expectedPushRecipientUserIDs = gamePushRecipientUserIDs(finished);
    if (committed < expectedPushRecipientUserIDs.length) {
      throw Object.assign(new Error("Game finish push commit failed"), {
        status: 503,
        code: "terminal_outbox_unconfirmed",
        retryable: true,
      });
    }
    const fullOutboxCommitted = await gamePushCommitCoversRecipients({
      store: base44.asServiceRole.entities.PushNotificationEvent,
      eventType: "game_finished",
      sourceEventID: finishedEventID,
      recipientUserIDs: expectedPushRecipientUserIDs,
    });
    if (!fullOutboxCommitted) {
      throw Object.assign(
        new Error("The complete game finish outbox is not yet visible."),
        {
          status: 503,
          code: "terminal_outbox_unconfirmed",
          retryable: true,
        },
      );
    }
    const outboxCommittedRoom = await updateRoomWithRetry(
      base44,
      finished,
      (latest) => {
        const intent = terminalIntentFromRoom(latest);
        if (
          !intent || intent.match_id !== claimed.intent.match_id ||
          normalizedStatus(latest) !== "finished" ||
          clean(latest.game_finished_event_id) !== finishedEventID
        ) {
          throw Object.assign(
            new Error("The terminal authority changed before outbox commit."),
            { status: 409, code: "terminal_intent_changed" },
          );
        }
        return terminalOutboxCommitIsProven(latest)
          ? {}
          : terminalOutboxCommitPatch({
            room: latest,
            recipientUserIDs: expectedPushRecipientUserIDs,
          });
      },
      (latest) => terminalOutboxCommitIsProven(latest),
      6,
      { allowPendingTerminal: true, allowCloseIntent: true },
    );
    timingRoom = outboxCommittedRoom;
    terminalTiming.complete("push_commit");
    terminalOutcome = "completed";
    return outboxCommittedRoom;
  } finally {
    try {
      console.info(
        "gameRoomAction terminal phase timing",
        terminalTiming.report(
          terminalOutcome,
          players(timingRoom).length,
          options.timingID,
        ),
      );
    } catch {
      // Timing diagnostics must never change the terminal game result.
    }
  }
}

async function ensureTerminalOutboxCommitBeforeMutation(base44, room) {
  const intent = terminalIntentFromRoom(room);
  if (!intent || terminalOutboxCommitIsProven(room)) return room;
  return await finishRoom(base44, room, intent.winner, {}, {
    expectedMatchID: intent.match_id,
    allowCloseIntent: true,
  });
}

async function createRoom(base44, user, body) {
  const player = {
    ...playerFromUser(user, body),
    membership_id: validatedMembershipGeneration(null),
  };
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
    replay_source_match_id: "",
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
  const player = {
    ...playerFromUser(user, body),
    membership_id: validatedMembershipGeneration(body?.join_membership_id),
  };
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
        const currentMembershipID = playerMembershipGeneration(
          latest,
          current || {},
        );
        const expectedMembershipID = expectedRoomExitMembershipID(body);
        const requestedMembershipID = clean(player.membership_id);
        const mayRotateMembership = requestedMembershipID ===
            currentMembershipID ||
          (expectedMembershipID &&
            expectedMembershipID === currentMembershipID);
        const effectivePlayer = {
          ...player,
          // A delayed retry from an older explicit join cannot overwrite a
          // newer rejoin. Rotation is a CAS from the viewer generation that
          // the client actually observed; identical retries stay idempotent.
          membership_id: mayRotateMembership
            ? requestedMembershipID
            : currentMembershipID,
        };
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
          clean(current?.name) === clean(effectivePlayer.name) &&
          clean(current?.avatar) === clean(effectivePlayer.avatar) &&
          playerMembershipGeneration(latest, current || {}) ===
            clean(effectivePlayer.membership_id) &&
          JSON.stringify(
              canonicalClientCapabilities(current?.client_capabilities),
            ) ===
            JSON.stringify(effectivePlayer.client_capabilities) &&
          participantIDs.length ===
            (latest.participant_user_ids || []).length &&
          !tombstonePresent && !departedPresent
        ) return {};
        return {
          players: mergePlayers(players(latest), effectivePlayer),
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

function returnToLobbyVoteMatches(room, actorEmailValue, requestedVote) {
  const status = normalizedStatus(room);
  if (status === "waiting") {
    return requestedVote === true && !clean(room?.match_id) &&
      !clean(room?.game_started_at) && readyPlayers(room).length === 0;
  }
  if (status !== "playing") return false;
  const actorKey = clean(actorEmailValue).toLocaleLowerCase();
  const hasVote = readyPlayers(room).some((email) =>
    clean(email).toLocaleLowerCase() === actorKey
  );
  return hasVote === requestedVote;
}

function returnToLobbyResetRequiresLeases() {
  return Object.assign(
    new Error(
      "The final return-to-lobby vote must retry with lifecycle leases.",
    ),
    {
      status: 409,
      code: "return_to_lobby_requires_leases",
      retryable: true,
    },
  );
}

async function voteReturnToLobby(base44, room, user, body, options = {}) {
  requirePlayer(room, user);
  assertActionMatchGeneration(room, body);
  const requestedVote = body?.return_to_lobby_vote;
  // Ordinary vote toggles are safe single-room CAS writes. A unanimous vote
  // also rewrites roster and match state, so only the participant-leased path
  // may commit that reset. One fast CAS attempt prevents a contention retry
  // from re-evaluating a formerly ordinary vote as an unleased final vote.
  const allowLobbyReturnReset = options.allowLobbyReturnReset !== false;
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const transition = activeGameLobbyReturnTransition(
        latest,
        user.email,
        requestedVote,
      );
      if (transition.didReset && !allowLobbyReturnReset) {
        throw returnToLobbyResetRequiresLeases();
      }
      return transition.patch;
    },
    (latest) => returnToLobbyVoteMatches(latest, user.email, requestedVote),
    allowLobbyReturnReset ? 6 : 1,
  );
}

function roomHasKickTarget(room, target) {
  const targetUserID = clean(target?.target_user_id);
  if (targetUserID) {
    return players(room).some((player) =>
      clean(player?.user_id) === targetUserID
    );
  }
  const targetEmail = clean(target?.target_email).toLocaleLowerCase();
  return players(room).some((player) =>
    clean(player?.email).toLocaleLowerCase() === targetEmail
  );
}

async function kickPlayer(base44, room, user, body) {
  const target = {
    target_user_id: body?.target_user_id,
    target_email: body?.target_email,
  };
  // Validate authority, status and target before entering the retry loop. The
  // same policy is reapplied to every refreshed CAS snapshot below.
  assertKickTargetMembershipGeneration(room, user, body);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const { transition } = assertKickTargetMembershipGeneration(
        latest,
        user,
        body,
      );
      const remainingPlayerCount = Array.isArray(transition.patch.players)
        ? transition.patch.players.length
        : 0;
      return {
        ...transition.patch,
        ...lobbyMembershipClampPatch(latest, remainingPlayerCount),
      };
    },
    (latest) =>
      normalizedStatus(latest) === "waiting" &&
      !roomHasKickTarget(latest, target),
  );
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

async function votePlayAgain(base44, room, user, body) {
  requirePlayer(room, user);
  room = await ensureTerminalOutboxCommitBeforeMutation(base44, room);
  const expectedSourceMatchID = clean(body?.expected_match_id) ||
    (["roulette", "playing"].includes(normalizedStatus(room))
      ? clean(room?.replay_source_match_id)
      : replaySourceMatchID(room));
  if (replayAutoStartAlreadyComplete(room, expectedSourceMatchID)) return room;
  assertExpectedReplaySourceMatch(room, expectedSourceMatchID);
  replayVoteTransition(room, user.email);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      if (replayAutoStartAlreadyComplete(latest, expectedSourceMatchID)) {
        return {};
      }
      assertExpectedReplaySourceMatch(latest, expectedSourceMatchID);
      const transition = replayVoteTransition(latest, user.email);
      if (!transition.unanimous) return transition.patch;
      return replayAutoStartPatch(
        { ...latest, ...transition.patch },
        { expectedSourceMatchID },
      );
    },
    (latest) => {
      if (replayAutoStartAlreadyComplete(latest, expectedSourceMatchID)) {
        return true;
      }
      try {
        return replayVoteTransition(latest, user.email).patch
          .ready_players === undefined;
      } catch {
        return false;
      }
    },
  );
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

async function resetRoomForReplay(base44, room, user, body) {
  room = await ensureTerminalOutboxCommitBeforeMutation(base44, room);
  replayResetPatch(room, user, body);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => replayResetPatch(latest, user, body),
    (latest) =>
      normalizedStatus(latest) === "waiting" &&
      !clean(latest.match_id) && !terminalIntentFromRoom(latest) &&
      !clean(latest.game_finished_event_id) &&
      readyPlayers(latest).length === 0,
  );
}

function finishedLobbyReturnAlreadyComplete(room) {
  return normalizedStatus(room) === "waiting" &&
    !clean(room?.match_id) && !terminalIntentFromRoom(room) &&
    !clean(room?.game_finished_event_id) &&
    readyPlayers(room).length === 0;
}

async function returnFinishedRoomToLobby(base44, room, user, body) {
  requireHost(room, user);
  room = await ensureTerminalOutboxCommitBeforeMutation(base44, room);
  if (finishedLobbyReturnAlreadyComplete(room)) return room;
  replayResetPatch(room, user, body, false);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) =>
      finishedLobbyReturnAlreadyComplete(latest)
        ? {}
        : replayResetPatch(latest, user, body, false),
    (latest) => finishedLobbyReturnAlreadyComplete(latest),
  );
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
  const initialQuestion = clean(startPayload?.game_mode) === "questions"
    ? initialQuestionTurn({
      activePlayers: roomPlayers,
      currentAskerEmail: startPayload?.current_asker_email,
      currentAnswererEmail: startPayload?.current_answerer_email,
    })
    : null;
  const startPatch = validatedStartPatch(room, startPayload, assignment);
  return await updateRoom(base44, room, {
    ...startPatch,
    ...(initialQuestion
      ? {
        current_answer: encodeQuestionTurnOrderState(initialQuestion.state),
      }
      : {}),
    ...serverIntroStartPatch(),
    status: "roulette",
    roulette_target_email: initialQuestion?.askerEmail || target,
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
      const identityBackfillPlan = await prepareRoomParticipantIdentityBackfill(
        base44,
        candidate,
        userIDs,
      );
      const revisionMigratedRoom = await backfillRoomWriteRevision(
        base44,
        candidate,
      );
      return await applyRoomParticipantIdentityBackfill(
        base44,
        revisionMigratedRoom,
        identityBackfillPlan,
      );
    },
    // The exact persisted match/event identity is checked immediately before
    // this call, so this can only take completeGameStart's idempotent branch.
    reconcile: (candidate) => completeGameStart(base44, candidate, user),
    fanout: async (candidate) => {
      await fanoutGameRoomSignalsBestEffort({
        store: base44.asServiceRole.entities.GameRoomSignal,
        room: candidate,
        allowCreate: false,
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
  assertRoundActionMode(room, "questions");
  const active = activePlayers(room);
  assertActiveRoundActor(active, user.email);
  if (clean(room.current_asker_email) !== clean(user.email)) {
    throw Object.assign(
      new Error("Only the current asker can advance the round"),
      {
        status: 403,
      },
    );
  }
  return await updateRoom(base44, room, questionAdvancePatch(room, active));
}

async function advanceAssociation(base44, room, user) {
  requirePlayer(room, user);
  assertRoundActionMode(room, "associations");
  const active = activePlayers(room);
  assertActiveRoundActor(active, user.email);
  if (clean(room.current_asker_email) !== clean(user.email)) {
    throw Object.assign(
      new Error("Only the current speaker can advance the round"),
      {
        status: 403,
      },
    );
  }
  if (!active.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }

  const transition = advanceAssociationTurn({
    activePlayers: active,
    currentSpeakerEmail: room.current_asker_email,
    rawState: room.current_answer,
  });
  const nextRound = transition.startsNewRound
    ? Number(room.round_number || 1) + 1
    : Number(room.round_number || 1);

  return await updateRoom(base44, room, {
    round_number: nextRound,
    current_asker_email: transition.speakerEmail,
    current_answer: encodeAssociationTurnState(transition.state),
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
  const currentSpeaker = active.find((player) =>
    clean(player.email).toLocaleLowerCase() ===
      clean(room.current_asker_email).toLocaleLowerCase()
  );
  if (currentSpeaker) {
    const existing = reconcileAssociationTurnState({
      activePlayers: active,
      rawState: room.current_answer,
      currentSpeakerEmail: room.current_asker_email,
    });
    const encodedState = encodeAssociationTurnState(existing);
    const patch = {};
    if (clean(room.current_answer) !== encodedState) {
      patch.current_answer = encodedState;
    }
    if (clean(room.question_phase) !== "asking") {
      patch.question_phase = "asking";
    }
    return Object.keys(patch).length
      ? await updateRoom(base44, room, patch)
      : room;
  }
  const initial = initialAssociationTurn({ activePlayers: active });
  return await updateRoom(base44, room, {
    current_asker_email: initial.speakerEmail,
    current_answer: encodeAssociationTurnState(initial.state),
    question_phase: "asking",
  });
}

async function stopAssociationSpin(base44, room, user) {
  requirePlayer(room, user);
  assertRoundActionMode(room, "associations");
  assertActiveRoundActor(activePlayers(room), user.email);
  const state = reconcileAssociationTurnState({
    activePlayers: activePlayers(room),
    rawState: room.current_answer,
    currentSpeakerEmail: room.current_asker_email,
  });
  const settledState = {
    spoken: state.spoken,
    spinning: false,
    order: state.order,
  };
  const encodedState = encodeAssociationTurnState(settledState);
  if (!state.spinning && clean(room.current_answer) === encodedState) {
    return room;
  }
  return await updateRoom(base44, room, {
    current_answer: encodedState,
  });
}

async function markAnswerHeard(base44, room, user) {
  requirePlayer(room, user);
  assertRoundActionMode(room, "questions");
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
  assertRoundActionMode(room, "questions");
  assertActiveRoundActor(activePlayers(room), user.email);
  if (clean(room.question_phase) !== "results") {
    throw Object.assign(new Error("Round results are not active"), {
      status: 409,
    });
  }
  const turnPatch = questionContinueTurnPatch(room, activePlayers(room));
  return await updateRoom(base44, room, {
    ...turnPatch,
    question_phase: "asking",
    round_number: nextRoundNumber(room.round_number),
    questions_in_round: 0,
    current_answer_feedback: null,
    player_feedback: [],
  });
}

async function requestVote(base44, room, user, body) {
  requirePlayer(room, user);
  const expectedMatchID = assertActionMatchGeneration(room, body);
  if (normalizedStatus(room) !== "playing") {
    throw Object.assign(
      new Error("Voting can only start during a live match."),
      {
        status: 409,
        code: "vote_match_inactive",
      },
    );
  }
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
      if (
        assertActionMatchGeneration(latest, body) !== expectedMatchID ||
        normalizedStatus(latest) !== "playing"
      ) {
        throw Object.assign(
          new Error("The voting match is no longer active."),
          {
            status: 409,
            code: "vote_match_inactive",
          },
        );
      }
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
      assertActionMatchGeneration(latest, body);
      if (normalizedStatus(latest) !== "playing") return false;
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
        resolution.decision.outcome === "eject" &&
        !resolution.terminal_winner
      ) {
        const nextRoom = { ...latest, ...patch };
        if (clean(latest?.game_mode) === "associations") {
          const associationTransition = associationRosterChangePatch({
            activePlayers: activePlayers(nextRoom),
            currentSpeakerEmail: latest.current_asker_email,
            currentAnswererEmail: latest.current_answerer_email,
            rawState: latest.current_answer,
          });
          Object.assign(patch, associationTransition.patch);
          if (associationTransition.startsNewRound) {
            patch.round_number = Number(latest.round_number || 1) + 1;
          }
        } else if (clean(latest?.game_mode) === "questions") {
          Object.assign(
            patch,
            questionRosterChangePatch({
              activePlayers: activePlayers(nextRoom),
              currentAskerEmail: latest.current_asker_email,
              currentAnswererEmail: latest.current_answerer_email,
              questionPhase: latest.question_phase,
              rawState: latest.current_answer,
            }),
          );
        }
      }
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

async function submitSpyGuess(base44, room, user, body, options = {}) {
  requirePlayer(room, user);
  const expectedMatchID = assertActionMatchGeneration(room, body);
  assertActiveSpyGuesser(room, user.email);

  const guess = requireSafeCommunityText(clean(body?.guess), "Spy guess");
  const winner = spyGuessWinner(displayWord(room), guess);
  return await finishRoom(base44, room, winner, {
    spy_guess: guess,
  }, { ...options, expectedMatchID });
}

async function closeRoom(base44, room, user, options = {}) {
  requirePlayer(room, user);
  requireHost(room, user);
  let closable = room;
  const terminal = pendingTerminalIntent(closable);
  if (terminal && !isCommittedFinishedRoom(closable)) {
    closable = await finishRoom(base44, closable, terminal.winner, {}, {
      allowCloseIntent: true,
    });
  }
  closable = await ensureTerminalOutboxCommitBeforeMutation(base44, closable);
  return await deleteRoom(base44, closable, {
    allowPendingTerminal: true,
    liveActivityEndQueuedRoomID: options.liveActivityEndQueuedRoomID,
    liveActivityEndQueuedMatchID: options.liveActivityEndQueuedMatchID,
  });
}

async function leaveRoom(base44, room, user, options = {}) {
  room = await ensureTerminalOutboxCommitBeforeMutation(base44, room);
  if (roomLeaveAlreadyComplete(room, user.email)) return { success: true };
  assertExpectedMembershipGeneration({
    room,
    user,
    expected: options.expectedMembershipID,
    expectedRevision: options.expectedRevision,
  });

  if (!hostDepartureUsesMembershipTransition(room, user.email)) {
    return await deleteRoom(base44, room, options);
  }

  const updated = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      assertExpectedMembershipGeneration({
        room: latest,
        user,
        expected: options.expectedMembershipID,
        expectedRevision: options.expectedRevision,
      });
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
  const result = terminal
    ? await finishRoom(base44, updated, terminal.winner)
    : updated;
  // The leaving account can have several devices subscribed to its exact
  // wake-up row. Persist its closed state while the actor lifecycle lease is
  // still held, including when this departure also commits a finished room.
  // The later generic finished-room fanout is at the same room revision, where
  // closed is monotonic and therefore cannot reopen this signal.
  await persistClosedRoomSignalForUserUnderLeases(
    base44,
    result,
    user.id,
    options.expectedRevision,
  );
  return result;
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

async function userIDExists(base44, userIDValue) {
  const userID = clean(userIDValue);
  if (!userID) return false;
  try {
    const candidate = await base44.asServiceRole.entities.User.get(userID);
    if (clean(candidate?.id) === userID) return true;
    throw Object.assign(new Error("User identity lookup was inconclusive."), {
      status: 503,
      code: "participant_identity_lookup_failed",
    });
  } catch (error) {
    if (Number(error?.status ?? error?.statusCode) === 404) return false;
    throw error;
  }
}

async function roomParticipantUserIDs(base44, room, actor, options = {}) {
  const stableUserIDs = storedRoomParticipantUserIDs({
    players: players(room),
    participantUserIDs: room?.participant_user_ids,
    hostEmail: room?.host_email,
    actor,
    allowActorIdentityMigration: options.allowOrphanedActorRebind === true,
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

async function roomLifecycleUserIDs(
  base44,
  room,
  actor,
  options = {},
  resolvedParticipantUserIDs = null,
) {
  const participantUserIDs = resolvedParticipantUserIDs ||
    await roomParticipantUserIDs(base44, room, actor, options);
  return roomIdentityLifecycleUserIDs({
    participantUserIDs,
    persistedParticipantUserIDs: room?.participant_user_ids,
    players: players(room),
    actor,
    allowActorIdentityMigration: options.allowOrphanedActorRebind === true,
  });
}

function assertTerminalIntentRecoveryScope(room, expected = {}) {
  const intent = terminalIntentFromRoom(room);
  if (!intent) return null;
  const expectedMatchID = clean(expected.matchID);
  const expectedDecidedAt = clean(expected.decidedAt);
  if (
    (expectedMatchID && intent.match_id !== expectedMatchID) ||
    (expectedDecidedAt && intent.decided_at !== expectedDecidedAt)
  ) {
    throw Object.assign(
      new Error("The terminal intent generation changed before recovery."),
      { status: 409, code: "terminal_intent_changed" },
    );
  }
  return intent;
}

async function reconcileTerminalIntentWithFreshLeases(
  base44,
  roomIDValue,
  expected = {},
) {
  const roomID = clean(roomIDValue);
  if (!roomID) {
    throw Object.assign(new Error("Room is required."), { status: 400 });
  }
  const acquisitionRoom = await fetchRoom(base44, roomID);
  if (!acquisitionRoom) {
    throw Object.assign(new Error("Room not found"), { status: 404 });
  }
  if (terminalOutboxCommitIsProven(acquisitionRoom)) return acquisitionRoom;
  const acquisitionIntent = assertTerminalIntentRecoveryScope(
    acquisitionRoom,
    expected,
  );
  if (!acquisitionIntent) return acquisitionRoom;
  const userIDs = await roomParticipantUserIDs(base44, acquisitionRoom, null);
  if (!userIDs.length) {
    throw Object.assign(new Error("Terminal participants are missing."), {
      status: 503,
      code: "terminal_participants_missing",
    });
  }
  return await withRoomWriteLeases({
    lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
    userIDs,
    action: async (context) => {
      base44.__spyclashRoomWriteLeaseContext = context;
      try {
        const latest = await fetchRoom(base44, roomID);
        if (!latest) {
          throw Object.assign(new Error("Room not found"), { status: 404 });
        }
        if (terminalOutboxCommitIsProven(latest)) return latest;
        const intent = assertTerminalIntentRecoveryScope(latest, {
          matchID: clean(expected.matchID) || acquisitionIntent.match_id,
          decidedAt: clean(expected.decidedAt) || acquisitionIntent.decided_at,
        });
        if (!intent) return latest;
        const latestUserIDs = await roomParticipantUserIDs(
          base44,
          latest,
          null,
        );
        assertExactRoomLeaseCoverage(context, latestUserIDs);
        return await finishRoom(base44, latest, intent.winner, {}, {
          expectedMatchID: intent.match_id,
        });
      } finally {
        delete base44.__spyclashRoomWriteLeaseContext;
      }
    },
  });
}

async function triggerTerminalIntentRecovery(base44, room) {
  const intent = terminalIntentNeedsReconciliation(room);
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!intent || !internalSecret || !clean(room?.id)) return false;
  try {
    await runWithWallClockDeadline({
      timeoutMS: 300,
      operation: () =>
        base44.asServiceRole.functions.invoke("gameRoomAction", {
          action: "reconcile_terminal_intent",
          room_id: clean(room.id),
          expected_match_id: intent.match_id,
          expected_decided_at: intent.decided_at,
          internal_secret: internalSecret,
        }),
      timeoutError: () => new Error("terminal recovery prompt accepted"),
    });
    return true;
  } catch (error) {
    // A wall-clock timeout means the durable nested invocation may still be
    // running. Polling can safely prompt the same immutable intent again.
    console.warn(
      "terminal intent recovery prompt deferred",
      error?.message || error,
    );
    return true;
  }
}

function participantIdentityMismatchError() {
  return Object.assign(
    new Error("Room participant identity does not match its account."),
    { status: 409, code: "participant_identity_mismatch" },
  );
}

async function authorizeOrphanedActorIdentityRebind(
  base44,
  room,
  options = {},
) {
  if (options.allowOrphanedActorRebind !== true) return null;
  const actor = options.actor || {};
  const actorID = clean(actor?.id);
  const actorEmail = clean(actor?.email).toLocaleLowerCase();
  const actorRows = players(room).filter((player) =>
    clean(player?.email).toLocaleLowerCase() === actorEmail
  );
  if (!actorID || !actorEmail || actorRows.length !== 1) return null;

  const player = actorRows[0];
  const suppliedUserID = clean(player?.user_id);
  if (!suppliedUserID || suppliedUserID === actorID) return null;

  const resolvedUserID = await userIDForEmail(base44, player?.email);
  const storedUserExists = await userIDExists(base44, suppliedUserID);
  if (
    !canRebindOrphanedActorIdentity({
      player,
      actor,
      hostEmail: room?.host_email,
      resolvedUserID,
      storedUserExists,
    })
  ) throw participantIdentityMismatchError();

  const leaseContext = base44.__spyclashRoomWriteLeaseContext;
  if (!leaseContext) throw participantIdentityMismatchError();
  // The old lifecycle row is intentionally included. A completed or
  // in-progress account deletion leaves it in `deleting`, so acquiring this
  // writer lease fails closed instead of resurrecting stale rooms.
  await assertRoomWriterLeaseForUser(leaseContext, suppliedUserID);
  await assertRoomWriterLeaseForUser(leaseContext, resolvedUserID);
  return {
    playerEmail: actorEmail,
    storedUserID: suppliedUserID,
    resolvedUserID,
  };
}

async function prepareRoomParticipantIdentityBackfill(
  base44,
  room,
  userIDs,
  options = {},
) {
  const expected = uniqueStrings(userIDs).sort();
  const existingPlayers = players(room);
  const stablePlayerIDs = existingPlayers
    .map((player) => clean(player?.user_id))
    .filter(Boolean)
    .sort();
  const current = uniqueStrings(room?.participant_user_ids).sort();
  const alreadyStable = stablePlayerIDs.length === existingPlayers.length &&
    stablePlayerIDs.length === expected.length &&
    stablePlayerIDs.every((value, index) => value === expected[index]) &&
    current.length === expected.length &&
    current.every((value, index) => value === expected[index]);

  // A fully indexed room already proved this mapping in
  // roomParticipantUserIDs. Legacy/rebind paths resolve every player exactly
  // once here and finish all identity validation before the first room write.
  const resolvedUserIDsByEmail = [];
  for (const player of existingPlayers) {
    const resolvedUserID = alreadyStable
      ? clean(player?.user_id)
      : await userIDForEmail(base44, player?.email);
    if (!resolvedUserID) {
      throw Object.assign(new Error("Room participant identity is missing"), {
        status: 409,
        code: "participant_missing",
      });
    }
    resolvedUserIDsByEmail.push({
      email: player?.email,
      userID: resolvedUserID,
    });
  }
  return roomParticipantIdentityBackfillPlan({
    players: existingPlayers,
    persistedParticipantUserIDs: room?.participant_user_ids,
    expectedParticipantUserIDs: expected,
    resolvedUserIDsByEmail,
    authorizedActorRebind: options.authorizedActorRebind,
  });
}

async function applyRoomParticipantIdentityBackfill(base44, room, plan) {
  if (!plan?.needsWrite) return room;
  return await updateRoom(base44, room, plan.patch, {
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
  "update_game_mode",
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
  "vote_return_to_lobby",
]);

function canUseFastRoomAction(action, room, user, body) {
  if (!FAST_ROOM_ACTIONS.has(action)) return false;
  if (roomWriteRevision(room) === null) return false;
  if (!roomHasParticipantIdentity(room, user)) return false;
  if (
    action === "update_game_mode" &&
    (normalizedStatus(room) !== "waiting" ||
      clean(room?.host_email) !== clean(user?.email))
  ) return false;
  if (
    (action === "mark_role_card_read" || action === "request_vote") &&
    shouldSpyWin(room)
  ) return false;
  if (action === "vote_return_to_lobby") {
    if (pendingTerminalIntent(room)) return false;
    // The pure transition classifier fails closed for the unanimous reset.
    // A fresh HTTP retry re-runs this decision against the latest revision.
    return activeGameLobbyReturnCanUseFastPath(
      room,
      user.email,
      body?.return_to_lobby_vote,
    );
  }
  return true;
}

function activeRoomStatus(room) {
  return ["waiting", "ready_voting", "roulette", "playing"].includes(
    normalizedStatus(room),
  );
}

function roomIsVisibleToActiveParticipant(room, user) {
  return playerInRoom(room, user.email) &&
    !roomHasDepartedPlayer(room, user.email) && !room?.close_intent &&
    activeRoomStatus(room);
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

async function executeRoomAction(
  base44,
  action,
  room,
  user,
  body,
  options = {},
) {
  if (room?.close_intent && action !== "close_room") {
    if (
      action === "leave_room" &&
      clean(room.host_email) === clean(user.email)
    ) {
      assertExpectedMembershipGeneration({
        room,
        user,
        expected: boundRoomExitMembershipID(body),
        expectedRevision: expectedRoomExitRevision(body),
      });
      return await deleteRoom(base44, room, {
        allowPendingTerminal: true,
      });
    }
    throw Object.assign(new Error("This room is closed."), {
      status: 404,
      code: "room_closed",
    });
  }
  const terminal = pendingTerminalIntent(room);
  if (terminal && action !== "close_room") {
    if (action === "join_room") {
      throw Object.assign(
        new Error("This match is finishing; joining is temporarily locked."),
        { status: 409, code: "terminal_reconciliation_pending" },
      );
    }
    // Any authenticated participant retry helps finish the immutable decision
    // before another mutation is allowed. The persisted intent, not this new
    // action's payload, remains the sole terminal source of truth.
    if (action === "leave_room") {
      const requestedMembershipID = boundRoomExitMembershipID(body);
      assertExpectedMembershipGeneration({
        room,
        user,
        expected: requestedMembershipID,
        expectedRevision: expectedRoomExitRevision(body),
      });
      const finished = await finishRoom(
        base44,
        room,
        terminal.winner,
        {},
        options,
      );
      return await leaveRoom(base44, finished, user, {
        liveActivityEndQueuedRoomID: body?.__server_live_activity_end_room_id,
        liveActivityEndQueuedMatchID: body?.__server_live_activity_end_match_id,
        // This request itself advanced the revision while reconciling the
        // immutable terminal intent. Bind the membership transition to that
        // exact freshly committed generation.
        expectedRevision: roomWriteRevision(finished),
        expectedMembershipID: requestedMembershipID,
      });
    }
    return await finishRoom(base44, room, terminal.winner, {}, options);
  }

  if (!["join_room", "close_room"].includes(action)) {
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
    case "vote_return_to_lobby":
      return await voteReturnToLobby(base44, room, user, body, options);
    case "kick_player":
      return await kickPlayer(base44, room, user, body);
    case "toggle_ready":
      return await toggleReady(base44, room, user);
    case "vote_play_again":
      return await votePlayAgain(base44, room, user, body);
    case "reset_room_for_replay":
      return await resetRoomForReplay(base44, room, user, body);
    case "return_finished_room_to_lobby":
      return await returnFinishedRoomToLobby(base44, room, user, body);
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
      return await requestVote(base44, room, user, body);
    case "cast_detective_vote":
      return await castDetectiveVote(base44, room, user, body);
    case "submit_spy_guess":
      return await submitSpyGuess(base44, room, user, body, options);
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
    case "close_room":
      assertExpectedMembershipGeneration({
        room,
        user,
        expected: boundRoomExitMembershipID(body),
        expectedRevision: expectedRoomExitRevision(body),
      });
      return await closeRoom(base44, room, user, {
        liveActivityEndQueuedRoomID: body?.__server_live_activity_end_room_id,
        liveActivityEndQueuedMatchID: body?.__server_live_activity_end_match_id,
        expectedRevision: expectedRoomExitRevision(body),
        expectedMembershipID: boundRoomExitMembershipID(body),
      });
    case "leave_room":
      return await leaveRoom(base44, room, user, {
        liveActivityEndQueuedRoomID: body?.__server_live_activity_end_room_id,
        liveActivityEndQueuedMatchID: body?.__server_live_activity_end_match_id,
        expectedRevision: expectedRoomExitRevision(body),
        expectedMembershipID: boundRoomExitMembershipID(body),
      });
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
  const result = await executeRoomAction(
    base44,
    action,
    room,
    user,
    body,
    options,
  );
  if (result?.id && !shouldDeferFinishedRoomSignal(result)) {
    let recipients;
    if (action === "kick_player" && normalizedStatus(result) === "waiting") {
      const transition = lobbyKickTransition(room, user.email, {
        target_user_id: body?.target_user_id,
        target_email: body?.target_email,
      });
      recipients = [
        ...roomSignalRecipients(result, "active"),
        ...uniqueStrings([transition.removedPlayer?.user_id]).map((userID) => ({
          user_id: userID,
          state: "closed",
        })),
      ];
    } else if (
      action === "leave_room" &&
      roomLeaveAlreadyComplete(result, user.email)
    ) {
      recipients = [
        ...roomSignalRecipients(result, "active"),
        { user_id: clean(user.id), state: "closed" },
      ];
    }
    stageGameRoomSignalFanout(base44, {
      room: result,
      recipients: recipients || roomSignalRecipients(result, "active"),
      projection: action === "update_game_mode"
        ? lobbyModeSignalProjectionForRoom(result)
        : null,
      allowCreate: options.allowSignalCreate !== false,
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
    const result = await runWithWallClockDeadline({
      timeoutMS: 600,
      operation: () =>
        withRoomWriteLeases({
          lifecycleStore:
            base44.asServiceRole.entities.BillingIdentityLifecycle,
          userIDs,
          attempts: 1,
          action: async () =>
            await fanoutGameRoomSignalsBestEffort({
              store: base44.asServiceRole.entities.GameRoomSignal,
              room,
              logError: (message, error) =>
                console.error(message, error?.message || error),
            }),
        }),
      timeoutError: () =>
        Object.assign(
          new Error("Finished room signal exceeded its response deadline."),
          { status: 503, code: "finished_signal_deadline" },
        ),
    });
    return Number(result?.failed) === 0;
  } catch (error) {
    // Polling remains the fallback. Never recreate an identity-bearing signal
    // after account deletion has acquired its opposing lifecycle marker.
    console.error("finished room signal deferred", error?.message || error);
    return false;
  }
}

async function rankedHistoryForMatch(base44, matchIDValue) {
  const matchID = clean(matchIDValue);
  if (!matchID) return [];
  const records = [];
  const seen = new Set();
  for (let skip = 0;; skip += 100) {
    const page = await base44.asServiceRole.entities.GameHistory.filter(
      { match_id: matchID },
      "created_date",
      100,
      skip,
    ) || [];
    for (const record of page) {
      if (
        clean(record?.match_id) !== matchID || record?.ranked !== true ||
        clean(record?.match_type).toLowerCase() !== "online"
      ) continue;
      const key = clean(record?.id) || clean(record?.result_key) ||
        `${clean(record?.player_user_id)}:${clean(record?.created_date)}`;
      if (!key || seen.has(key)) continue;
      seen.add(key);
      records.push(record);
    }
    if (page.length < 100) break;
  }
  const cached = base44.__spyclashCommunityProfileRepairSources;
  if (clean(cached?.matchID) === matchID) {
    for (const record of Array.isArray(cached?.sources) ? cached.sources : []) {
      const key = clean(record?.id) || clean(record?.result_key);
      if (
        !key || seen.has(key) || clean(record?.match_id) !== matchID ||
        record?.ranked !== true
      ) continue;
      seen.add(key);
      records.push(record);
    }
  }
  return records;
}

function profileRepairLifecycleIsGone(error) {
  return error instanceof BillingIdentityLifecycleError &&
    ["deletion_in_progress", "user_missing"].includes(clean(error.code));
}

async function withSingleProfileRepairLease(base44, userIDValue, action) {
  const userID = clean(userIDValue);
  if (!userID) return { status: "gone" };
  try {
    const value = await withRoomWriteLeases({
      lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
      userIDs: [userID],
      attempts: 1,
      action: (context) => action(context, userID),
    });
    return { status: "performed", value };
  } catch (error) {
    if (profileRepairLifecycleIsGone(error)) return { status: "gone" };
    console.error(
      "community profile single-user repair deferred",
      error?.message || error,
    );
    return { status: "deferred" };
  }
}

async function repairCommunityProfileHistorySource(
  base44,
  source,
  options = {},
) {
  const profileUserID = clean(source?.player_user_id);
  const matchID = clean(source?.match_id);
  if (!profileUserID || !matchID) {
    await options.afterMirror?.();
    return true;
  }

  const mirror = await withSingleProfileRepairLease(
    base44,
    profileUserID,
    async (context) => {
      const results = await reconcileCommunityProfileMirrors({
        historyStore: base44.asServiceRole.entities.GameHistory,
        userStore: base44.asServiceRole.entities.User,
        playerUserIDs: [profileUserID],
        knownHistoryRecords: [source],
        beforeUserUpdate: () =>
          assertRoomWriterLeaseForUser(context, profileUserID),
      });
      return results[0]?.status !== "missing_user";
    },
  );
  // A bounded terminal batch uses this barrier so every independent profile
  // mirror releases its User lease before any overlapping recipient signal
  // fanout begins. Non-terminal drains default to a batch size of one.
  await options.afterMirror?.();
  if (mirror.status === "deferred") return false;
  if (mirror.status === "gone" || mirror.value !== true) return true;

  const fanout = async () => {
    const matchHistory = await rankedHistoryForMatch(base44, matchID);
    const recipientUserIDs = uniqueStrings(
      matchHistory.map((record) => record?.player_user_id),
    );
    const result = await repairCommunityProfileRecipients({
      recipientUserIDs,
      concurrency: 4,
      repairRecipient: async (recipientUserID) => {
        const outcome = await withSingleProfileRepairLease(
          base44,
          recipientUserID,
          async () => {
            const signal = await fanoutCommunityProfileInvalidations({
              signalStore: base44.asServiceRole.entities.CommunityProfileSignal,
              recipientUserIDs: [recipientUserID],
              profileUserIDs: [profileUserID],
              logError: (message, error) =>
                console.error(message, error?.message || error),
            });
            return Number(signal?.failed) === 0;
          },
        );
        return outcome.status === "gone" ||
          (outcome.status === "performed" && outcome.value === true);
      },
    });
    return result.failedUserIDs.length === 0;
  };

  // A recipient owns one CommunityProfileSignal row. Independent player
  // mirrors may run concurrently, but their wake-up fanout must remain ordered
  // so one profile cannot overwrite another profile's signal mid-write.
  return typeof options.serializeFanout === "function"
    ? await options.serializeFanout(fanout)
    : await fanout();
}

async function runProfileRepairSources(base44, sources, options = {}) {
  const outcomes = [];
  const concurrency = Math.min(
    Math.max(Math.floor(Number(options.concurrency)) || 1, 1),
    4,
  );
  let fanoutTail = Promise.resolve();
  const serializeFanout = async (fanout) => {
    const run = fanoutTail.then(fanout, fanout);
    fanoutTail = run.then(() => undefined, () => undefined);
    return await run;
  };

  // Ranked participants update distinct User rows under distinct lifecycle
  // leases. Bound their expensive history reads/mirror writes concurrently,
  // while serializeFanout preserves the single wake-up row per recipient.
  for (let offset = 0; offset < sources.length; offset += concurrency) {
    const batch = sources.slice(offset, offset + concurrency);
    let mirrorsSettled = 0;
    let releaseMirrorBarrier;
    const mirrorBarrier = new Promise((resolve) => {
      releaseMirrorBarrier = resolve;
    });
    const settled = await Promise.allSettled(
      batch.map((source) => {
        let sourceSettled = false;
        const settleSource = () => {
          if (sourceSettled) return;
          sourceSettled = true;
          mirrorsSettled += 1;
          if (mirrorsSettled === batch.length) releaseMirrorBarrier();
        };
        return runCommunityProfileRepair({
          store: base44.asServiceRole.entities.GameHistory,
          source,
          repair: (claimedSource) => {
            return repairCommunityProfileHistorySource(
              base44,
              claimedSource,
              {
                afterMirror: async () => {
                  settleSource();
                  await mirrorBarrier;
                },
                serializeFanout,
              },
            );
          },
          logError: (message, error) =>
            console.error(message, error?.message || error),
        }).finally(() => {
          // Completed/deferred sources never enter repair(), and an unexpected
          // pre-barrier failure must not strand its batch behind the gate.
          settleSource();
        });
      }),
    );
    for (const [index, result] of settled.entries()) {
      if (result.status === "fulfilled") {
        outcomes.push(result.value);
        continue;
      }
      console.error(
        "community profile repair claim deferred",
        result.reason?.message || result.reason,
      );
      outcomes.push({ outcome: "failed", source: batch[index] });
    }
  }
  return outcomes;
}

async function repairFinishedCommunityProfilesAndSignals(base44, room) {
  if (!room?.id || !isCommittedFinishedRoom(room)) return true;
  const sources = (await rankedHistoryForMatch(base44, room.match_id))
    .filter((record) =>
      ["pending", "processing", "completed"].includes(
        clean(record?.profile_repair_state).toLowerCase(),
      )
    );
  if (!sources.length) return canonicalSpyEmails(room).length !== 1;
  const outcomes = await runProfileRepairSources(base44, sources, {
    concurrency: 4,
  });
  return outcomes.every((result) =>
    ["performed", "completed", "missing"].includes(result.outcome)
  );
}

async function dispatchRoomPushBestEffort(
  base44,
  room,
  action,
  options = {},
) {
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
  const timingID = normalizeOpaqueTimingID(options.timingID);
  const timing = options.sideEffectTiming;
  const responseDeadlineEpochMS = Date.now() + 2_000;
  const invokePushWithinResponseDeadline = (invocationBody) =>
    runWithWallClockDeadline({
      timeoutMS: Math.max(1, responseDeadlineEpochMS - Date.now()),
      operation: () =>
        base44.asServiceRole.functions.invoke(
          "pushNotificationAction",
          {
            ...invocationBody,
            deadline_epoch_ms: responseDeadlineEpochMS,
          },
        ),
      timeoutError: () =>
        Object.assign(
          new Error("Room push dispatch exceeded its response deadline."),
          { status: 503, code: "room_push_dispatch_timeout" },
        ),
    });
  timing?.begin("push_function_invoke");
  try {
    for (const sourceEventID of sourceEventIDs) {
      const invocationBody = {
        action: "process_event",
        source_event_id: sourceEventID,
        internal_secret: internalSecret,
        ...(timingID ? { timing_id: timingID } : {}),
      };
      await invokePushWithinResponseDeadline(invocationBody);
    }
    // process_event already synchronizes the matching ActivityKit generation
    // before it drains the ordinary alert. Avoid invoking the same terminal
    // sync twice on the hottest post-game path.
    if (!sourceEventIDs.length && shouldSynchronizeLiveActivity(action, room)) {
      const invocationBody = {
        action: "sync_live_activity",
        room_id: clean(room.id),
        match_id: clean(room.match_id),
        internal_secret: internalSecret,
        ...(timingID ? { timing_id: timingID } : {}),
      };
      await invokePushWithinResponseDeadline(invocationBody);
    }
    return true;
  } catch (error) {
    console.error("room push dispatch deferred", error?.message || error);
    return false;
  } finally {
    timing?.complete("push_function_invoke");
  }
}

async function dispatchRoomSideEffectsAfterLeases(
  base44,
  room,
  action,
  options = {},
) {
  if (!isCommittedFinishedRoom(room)) {
    await dispatchRoomPushBestEffort(base44, room, action, options);
    return room;
  }
  // The exact ActivityKit force-end intent was durably queued before the room
  // response when possible; the push outbox and unregister path are durable
  // fallbacks. The enqueue receiver owns its own lifecycle leases, so a caller
  // deadline cannot leave late writes outside their safety boundary.
  const timing = options.sideEffectTiming;
  timing?.begin("live_activity_end_enqueue");
  try {
    await enqueueRoomLiveActivityEnd(base44, room);
  } catch {
    // The finished push event is already durable. Do not hold the gameplay
    // result behind a transient internal invoke; token unregister also retains
    // a force-end intent for an observed finished room.
  } finally {
    timing?.complete("live_activity_end_enqueue");
  }
  timing?.begin("signal_fanout");
  try {
    await fanoutDeferredFinishedRoomSignal(base44, room);
  } finally {
    timing?.complete("signal_fanout");
  }
  await triggerQueuedLiveActivityEndDelivery(
    base44,
    room.id,
    room.match_id,
  );
  return room;
}

async function dispatchFinishedCommunityProfileSideEffects(base44, room) {
  return await runTerminalSideEffectsSingleFlight({
    store: base44.asServiceRole.entities.GameRoom,
    room,
    stateKey: "profile_side_effect_dispatch",
    dispatch: (claimedRoom) =>
      repairFinishedCommunityProfilesAndSignals(base44, claimedRoom),
  });
}

async function drainCommunityProfileRepairs(base44, limitValue) {
  const limit = Math.min(Math.max(Math.floor(Number(limitValue)) || 8, 1), 24);
  const sources = await dueCommunityProfileRepairSources({
    store: base44.asServiceRole.entities.GameHistory,
    limit,
  });
  const outcomes = await runProfileRepairSources(base44, sources);
  return {
    ok: outcomes.every((result) =>
      ["performed", "completed", "missing"].includes(result.outcome)
    ),
    selected: sources.length,
    performed: outcomes.filter((result) => result.outcome === "performed")
      .length,
    completed: outcomes.filter((result) => result.outcome === "completed")
      .length,
    deferred:
      outcomes.filter((result) =>
        ["deferred", "failed"].includes(result.outcome)
      ).length,
  };
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
  const requestStartedAt = performance.now();
  let actionForLog = null;
  let roomIDForLog = null;
  let actionStartedAt = null;
  let actionCompletedAt = null;
  let postCommitSideEffectsStartedAt = null;
  let postCommitSideEffectsMS = 0;
  let spyGuessTimingID = "";
  const spyGuessSideEffectTiming = createSpyGuessSideEffectTiming();
  const logSpyGuessResponseTiming = (outcome, responseReadyAt) => {
    if (actionForLog !== "submit_spy_guess") return;
    const completedAt = actionCompletedAt ?? responseReadyAt;
    const startedAt = actionStartedAt ?? completedAt;
    const sideEffectsMS = postCommitSideEffectsStartedAt === null
      ? postCommitSideEffectsMS
      : Math.max(
        0,
        Math.round(responseReadyAt - postCommitSideEffectsStartedAt),
      );
    try {
      console.info(
        "gameRoomAction spy-guess response timing",
        spyGuessResponseTiming({
          timingID: spyGuessTimingID,
          requestStartedAt,
          actionStartedAt: startedAt,
          actionCompletedAt: completedAt,
          responseReadyAt,
          postCommitSideEffectsMS: sideEffectsMS,
          sideEffects: spyGuessSideEffectTiming.snapshot(),
          outcome,
        }),
      );
    } catch {
      // Response diagnostics must never change the gameplay response.
    }
  };
  const respondWithSpyGuessTiming = (response, outcome) => {
    logSpyGuessResponseTiming(outcome, performance.now());
    return response;
  };
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
    const requestedAction = clean(body?.action);

    if (requestedAction === "reconcile_terminal_intent") {
      if (
        !matchesInternalPushSecret(
          Deno.env.get("PUSH_INTERNAL_SECRET"),
          body?.internal_secret,
        )
      ) {
        return jsonError("Unauthorized", 401);
      }
      const roomID = clean(body?.room_id);
      let reconciled = await reconcileTerminalIntentWithFreshLeases(
        base44,
        roomID,
        {
          matchID: body?.expected_match_id,
          decidedAt: body?.expected_decided_at,
        },
      );
      reconciled = await dispatchRoomSideEffectsAfterLeases(
        base44,
        reconciled,
        requestedAction,
      );
      return Response.json({
        ok: terminalOutboxCommitIsProven(reconciled),
        room_id: roomID,
        match_id: clean(reconciled?.match_id),
        status: normalizedStatus(reconciled),
        source_event_id: clean(reconciled?.game_finished_event_id),
      });
    }

    if (requestedAction === "drain_community_profile_repairs") {
      if (
        !matchesInternalPushSecret(
          Deno.env.get("PUSH_INTERNAL_SECRET"),
          body?.internal_secret,
        )
      ) {
        return jsonError("Unauthorized", 401);
      }
      return Response.json(
        await drainCommunityProfileRepairs(base44, body?.limit),
      );
    }

    if (requestedAction === "repair_finished_profile_side_effects") {
      if (
        !matchesInternalPushSecret(
          Deno.env.get("PUSH_INTERNAL_SECRET"),
          body?.internal_secret,
        )
      ) {
        return jsonError("Unauthorized", 401);
      }
      const roomID = clean(body?.room_id);
      const room = roomID ? await fetchRoom(base44, roomID) : null;
      if (!room) return jsonError("Room not found", 404);
      if (
        !isCommittedFinishedRoom(room) ||
        clean(body?.source_event_id) !== clean(room.game_finished_event_id)
      ) {
        return jsonError("Finished source event is stale", 409);
      }
      const run = await dispatchFinishedCommunityProfileSideEffects(
        base44,
        room,
      );
      return Response.json({
        ok: run.outcome === "performed" || run.outcome === "completed",
        outcome: run.outcome,
        room_id: roomID,
      });
    }

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

    const action = requestedAction;
    const roomId = clean(body?.room_id);
    actionForLog = safeLogLabel(action);
    if (action === "submit_spy_guess") {
      // A request-local UUID correlates timing-only logs across the two
      // functions. It is unrelated to room/user/content and is never persisted.
      spyGuessTimingID = createOpaqueTimingID();
    }
    const spyGuessTimingOptions = spyGuessTimingID
      ? {
        timingID: spyGuessTimingID,
        sideEffectTiming: spyGuessSideEffectTiming,
      }
      : {};

    if (!action) return jsonError("Missing action");

    if (action === "backfill_community_profiles") {
      if (clean(user.role).toLowerCase() !== "admin") {
        return jsonError("Forbidden", 403);
      }
      const backfillMode = clean(body?.mode || "plan").toLowerCase();
      if (!["plan", "apply"].includes(backfillMode)) {
        return jsonError(
          "Use mode plan for dry-run or mode apply for explicit writes",
          400,
        );
      }
      const apply = backfillMode === "apply";
      const backfill = await runCommunityProfileBackfillPage({
        historyStore: base44.asServiceRole.entities.GameHistory,
        cursor: body?.cursor,
        batchSize: body?.batch_size,
        apply,
        reconcileUser: async (userID) => {
          await withRoomWriteLeases({
            lifecycleStore:
              base44.asServiceRole.entities.BillingIdentityLifecycle,
            userIDs: [userID],
            action: async (context) => {
              await reconcileCommunityProfileMirrors({
                historyStore: base44.asServiceRole.entities.GameHistory,
                userStore: base44.asServiceRole.entities.User,
                playerUserIDs: [userID],
                beforeUserUpdate: () =>
                  assertRoomWriterLeaseForUser(context, userID),
              });
            },
          });
        },
      });
      return Response.json({ ok: true, mode: backfillMode, ...backfill });
    }

    if (action === "get_leaderboard") {
      return Response.json(await loadLeaderboard(base44, user));
    }

    if (action === "get_active_room") {
      let active = await activeRoomForUser(base44, user, roomId);
      if (active && terminalIntentNeedsReconciliation(active)) {
        await triggerTerminalIntentRecovery(base44, active);
        active = await fetchRoom(base44, active.id) || active;
      }
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
            stageGameRoomSignalFanout(base44, {
              room: created,
              recipients: roomSignalRecipients(created, "active"),
            });
            return created;
          } finally {
            delete base44.__spyclashRoomWriteLeaseContext;
          }
        },
      });
      await fanoutStagedGameRoomSignalsAfterLeases(base44);
      return Response.json(roomForClient(result, user));
    }

    // A full-fanout completion tombstone dominates an eventually consistent
    // active or missing GameRoom replica. Finish an interrupted physical
    // deletion under the original participant lease set before acknowledging
    // the host retry.
    if ((action === "close_room" || action === "leave_room") && roomId) {
      const completion = await completedRoomCloseForHost(
        base44,
        roomId,
        user.id,
      );
      if (completion) {
        roomIDForLog = safeLogLabel(roomId);
        return Response.json(
          await recoverCompletedRoomClose(base44, completion),
        );
      }
    }

    let room = roomId
      ? await fetchRoom(base44, roomId)
      : await fetchRoomByCode(base44, body?.room_code || body?.code);
    roomIDForLog = safeLogLabel(room?.id || roomId);

    if (action === "leave_room" && !room) {
      const completion = await completedRoomCloseForHost(
        base44,
        roomId,
        user.id,
      );
      if (completion) {
        return Response.json(
          await recoverCompletedRoomClose(base44, completion),
        );
      }
      if (
        !await durableRoomExitIsCommitted(
          base44,
          roomId,
          user.id,
          expectedRoomExitRevision(body),
        )
      ) {
        throw unconfirmedRoomExitError();
      }
      return Response.json({ success: true });
    }
    if (
      action === "leave_room" &&
      roomLeaveAlreadyComplete(room, user.email)
    ) {
      await persistClosedRoomSignalForUser(
        base44,
        room,
        user.id,
        expectedRoomExitRevision(body),
      );
      return Response.json({ success: true });
    }
    if (action === "close_room" && !room) {
      throw unconfirmedRoomCloseError();
    }
    if (!room) {
      return respondWithSpyGuessTiming(
        jsonError("Room not found", 404),
        "failed",
      );
    }
    if (room?.close_intent && action !== "close_room") {
      if (action === "leave_room") {
        if (clean(room.host_email) !== clean(user.email)) {
          await persistClosedRoomSignalForUser(
            base44,
            room,
            user.id,
            expectedRoomExitRevision(body),
          );
          return Response.json({ success: true });
        }
      } else {
        return respondWithSpyGuessTiming(
          jsonError("Room not found", 404, { code: "room_closed" }),
          "failed",
        );
      }
    }
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
      if (terminalIntentNeedsReconciliation(room)) {
        await triggerTerminalIntentRecovery(base44, room);
        const reconciled = await fetchRoom(base44, room.id);
        if (reconciled) room = reconciled;
      }
      return Response.json(roomForClient(room, user));
    }

    if (action !== "join_room") requirePlayer(room, user);
    // The pre-lease ActivityKit enqueue is externally visible. Prove host
    // authority before invoking it, then closeRoom repeats the check on the
    // refetched room under the participant lease set.
    if (action === "close_room") requireHost(room, user);

    if (action === "finalize_expired_room") {
      assertExpectedTimerFinalizationScope(room, body);
    }

    if (EXPLICIT_TIMER_FINALIZE_ACTIONS.has(action)) {
      if (normalizedStatus(room) === "finished") {
        const unfinishedOutbox = terminalIntentNeedsReconciliation(room);
        if (unfinishedOutbox) {
          room = await reconcileTerminalIntentWithFreshLeases(
            base44,
            room.id,
            {
              matchID: unfinishedOutbox.match_id,
              decidedAt: unfinishedOutbox.decided_at,
            },
          );
        }
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
          const unfinishedOutbox = terminalIntentNeedsReconciliation(room);
          if (unfinishedOutbox) {
            room = await reconcileTerminalIntentWithFreshLeases(
              base44,
              room.id,
              {
                matchID: unfinishedOutbox.match_id,
                decidedAt: unfinishedOutbox.decided_at,
              },
            );
          }
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
    const capturedActionBody = (() => {
      if (action === "cast_detective_vote") {
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
      }
      if (
        ["request_vote", "submit_spy_guess", "vote_return_to_lobby"].includes(
          action,
        )
      ) {
        return {
          ...body,
          __server_action_match_id: clean(room.match_id),
        };
      }
      if (action === "kick_player") {
        const captured = assertKickTargetMembershipGeneration(
          room,
          user,
          body,
        );
        return {
          ...body,
          __server_kick_target_membership_id: captured.generation,
        };
      }
      if (action === "leave_room" || action === "close_room") {
        return {
          ...body,
          // Never trust a caller-supplied private marker. Legacy clients omit
          // both public CAS fields, so capture the server-visible membership
          // before this request can wait behind another lifecycle writer.
          __server_room_exit_membership_id: captureRoomExitMembershipGeneration(
            {
              room,
              user,
              expected: expectedRoomExitMembershipID(body),
              expectedRevision: expectedRoomExitRevision(body),
            },
          ),
        };
      }
      return body;
    })();

    const mustQueueLiveActivityEndBeforeLeases = clean(room.match_id) &&
      action === "leave_room" && normalizedStatus(room) === "finished" &&
      hostDepartureUsesMembershipTransition(room, user.email);
    let liveActivityEndQueuedRoomID = "";
    let liveActivityEndQueuedMatchID = "";
    if (mustQueueLiveActivityEndBeforeLeases) {
      await enqueueRoomLiveActivityEnd(base44, room);
      liveActivityEndQueuedRoomID = clean(room.id);
      liveActivityEndQueuedMatchID = clean(room.match_id);
    }
    const actionBody = {
      ...capturedActionBody,
      // Always overwrite the private marker after canonical request parsing;
      // callers can never claim that the durable enqueue already happened.
      __server_live_activity_end_room_id: liveActivityEndQueuedRoomID,
      __server_live_activity_end_match_id: liveActivityEndQueuedMatchID,
    };

    // Capability refresh mutates the authenticated participant record and must
    // use the full lifecycle lease path even when the gameplay action itself
    // would normally qualify for an unleased fast CAS.
    const fastRoomAction = !actorCapabilityRefreshNeeded(
      room,
      user,
      actionBody,
    ) && canUseFastRoomAction(action, room, user, actionBody);
    const participantIdentityOptions = {
      allowOrphanedActorRebind: allowsOrphanedActorIdentityRebind(action),
    };
    actionStartedAt = performance.now();
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
          {
            allowSignalCreate: false,
            allowLobbyReturnReset: false,
            ...spyGuessTimingOptions,
          },
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
            if (action === "leave_room") {
              const completion = await completedRoomCloseForHost(
                base44,
                room.id,
                user.id,
              );
              if (completion) {
                return await recoverCompletedRoomClose(base44, completion);
              }
              if (
                !await durableRoomExitIsCommitted(
                  base44,
                  room.id,
                  user.id,
                  expectedRoomExitRevision(actionBody),
                )
              ) throw unconfirmedRoomExitError();
              return { success: true };
            }
            if (action === "close_room") {
              const completion = await completedRoomCloseForHost(
                base44,
                room.id,
                user.id,
              );
              if (!completion) throw unconfirmedRoomCloseError();
              return await recoverCompletedRoomClose(base44, completion);
            }
            throw Object.assign(new Error("Room not found"), { status: 404 });
          }
          if (
            action === "leave_room" &&
            roomLeaveAlreadyComplete(acquisitionRoom, user.email)
          ) {
            await persistClosedRoomSignalForUser(
              base44,
              acquisitionRoom,
              user.id,
              expectedRoomExitRevision(actionBody),
            );
            return { success: true };
          }
          if (action !== "join_room") requirePlayer(acquisitionRoom, user);

          const userIDs = await roomLifecycleUserIDs(
            base44,
            acquisitionRoom,
            user,
            participantIdentityOptions,
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
                  if (action === "leave_room") {
                    const completion = await completedRoomCloseForHost(
                      base44,
                      room.id,
                      user.id,
                    );
                    if (completion) {
                      return await deleteCompletedRoomCloseUnderLeases(
                        base44,
                        completion,
                      );
                    }
                    if (
                      !await durableRoomExitIsCommitted(
                        base44,
                        room.id,
                        user.id,
                        expectedRoomExitRevision(actionBody),
                      )
                    ) throw unconfirmedRoomExitError();
                    return { success: true };
                  }
                  if (action === "close_room") {
                    const completion = await completedRoomCloseForHost(
                      base44,
                      room.id,
                      user.id,
                    );
                    if (!completion) throw unconfirmedRoomCloseError();
                    return await deleteCompletedRoomCloseUnderLeases(
                      base44,
                      completion,
                    );
                  }
                  throw Object.assign(new Error("Room not found"), {
                    status: 404,
                  });
                }
                if (
                  action === "leave_room" &&
                  roomLeaveAlreadyComplete(latestRoom, user.email)
                ) {
                  await persistClosedRoomSignalForUserUnderLeases(
                    base44,
                    latestRoom,
                    user.id,
                    expectedRoomExitRevision(actionBody),
                  );
                  return { success: true };
                }
                const latestParticipantUserIDs = await roomParticipantUserIDs(
                  base44,
                  latestRoom,
                  user,
                  participantIdentityOptions,
                );
                const latestUserIDs = await roomLifecycleUserIDs(
                  base44,
                  latestRoom,
                  user,
                  participantIdentityOptions,
                  latestParticipantUserIDs,
                );
                assertExactRoomLeaseCoverage(context, latestUserIDs);
                const authorizedActorRebind =
                  await authorizeOrphanedActorIdentityRebind(
                    base44,
                    latestRoom,
                    {
                      ...participantIdentityOptions,
                      actor: user,
                    },
                  );
                const identityBackfillPlan =
                  await prepareRoomParticipantIdentityBackfill(
                    base44,
                    latestRoom,
                    latestParticipantUserIDs,
                    { authorizedActorRebind },
                  );
                await assertRoomWriteLeases(context);
                const revisionMigratedRoom = await backfillRoomWriteRevision(
                  base44,
                  latestRoom,
                );
                const migratedRoom = await applyRoomParticipantIdentityBackfill(
                  base44,
                  revisionMigratedRoom,
                  identityBackfillPlan,
                );
                markActionStarted();
                return await executeRoomActionWithSignal(
                  base44,
                  action,
                  migratedRoom,
                  user,
                  actionBody,
                  spyGuessTimingOptions,
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
    actionCompletedAt = performance.now();
    await fanoutStagedGameRoomSignalsAfterLeases(base44);
    await finalizeStagedRoomCloseAfterLeases(base44);
    await triggerStagedLiveActivityEndDelivery(base44);
    if (fastRoomAction) {
      console.info("gameRoomAction fast-path timing", {
        action,
        room_id: clean(room.id),
        duration_ms: Math.round(performance.now() - actionStartedAt),
        room_revision: roomWriteRevision(result),
      });
    }
    if (result?.id && !readOnlyCastLeaseRecovery) {
      // Post-lease terminal work is limited to the minimal ActivityKit sync and
      // bounded realtime signal. Durable history repair and ordinary push
      // delivery are owned by the scheduled worker.
      const sideEffectsStartedAt = performance.now();
      postCommitSideEffectsStartedAt = sideEffectsStartedAt;
      result = await dispatchRoomSideEffectsAfterLeases(
        base44,
        result,
        action,
        spyGuessTimingOptions,
      );
      postCommitSideEffectsMS = Math.round(
        performance.now() - sideEffectsStartedAt,
      );
      postCommitSideEffectsStartedAt = null;
      if (!result) {
        return respondWithSpyGuessTiming(
          jsonError("Room not found", 404),
          "failed",
        );
      }
    }
    return respondWithSpyGuessTiming(
      Response.json(result?.id ? roomForClient(result, user) : result),
      "completed",
    );
  } catch (error) {
    const status = lifecycleHTTPStatus(error);
    console.error("gameRoomAction error", {
      action: actionForLog,
      room_id: roomIDForLog,
      code: safeLogLabel(error?.code),
      status,
    });
    const response = jsonError(
      error?.message || "Internal error",
      status,
      { code: error?.code, retryable: error?.retryable },
    );
    logSpyGuessResponseTiming("failed", performance.now());
    return response;
  }
});

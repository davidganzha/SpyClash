import {
  assert,
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  assertGameActionAllowedByDeadline,
  assertGameActionAllowedWhilePaused,
} from "./game-timer-policy.ts";

const playingRoom = {
  status: "playing",
  game_started_at: "2026-09-01T12:00:00.000Z",
  game_duration_seconds: 60,
  game_paused_at: null,
  game_paused_total_seconds: 0,
};

Deno.test("return-to-lobby remains an explicit pause escape but cannot bypass an elapsed terminal", () => {
  assertEquals(
    assertGameActionAllowedWhilePaused(
      { ...playingRoom, game_paused_at: "2026-09-01T12:00:20.000Z" },
      "vote_return_to_lobby",
    ),
    undefined,
  );

  const elapsed = assertThrows(() =>
    assertGameActionAllowedByDeadline(
      playingRoom,
      "vote_return_to_lobby",
      Date.parse("2026-09-01T12:01:00.000Z"),
    )
  ) as Error & { code?: string };
  assertEquals(elapsed.code, "game_timer_elapsed");
});

Deno.test("gameRoomAction integrates lobby return, kick, and explicit host close through participant leases", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const vote = source.slice(
    source.indexOf("async function voteReturnToLobby"),
    source.indexOf("function roomHasKickTarget"),
  );
  assertStringIncludes(vote, "updateRoomWithRetry(");
  assertStringIncludes(vote, "activeGameLobbyReturnTransition(");
  assertStringIncludes(vote, "returnToLobbyVoteMatches(");
  assertStringIncludes(source, 'if (status !== "playing") return false;');
  for (
    const forbidden of ["finishRoom(", "archiveRoomResult(", "GameHistory"]
  ) {
    assertEquals(
      vote.includes(forbidden),
      false,
      `unanimous lobby return must not execute ${forbidden}`,
    );
  }

  const kick = source.slice(
    source.indexOf("async function kickPlayer"),
    source.indexOf("async function toggleReady"),
  );
  assertStringIncludes(
    kick,
    "assertKickTargetMembershipGeneration(room, user, body)",
  );
  assertStringIncludes(
    kick,
    "const { transition } = assertKickTargetMembershipGeneration(",
  );
  assertStringIncludes(kick, "lobbyMembershipClampPatch(");
  assertStringIncludes(kick, "updateRoomWithRetry(");
  assertStringIncludes(kick, 'normalizedStatus(latest) === "waiting"');

  assertStringIncludes(source, 'case "vote_return_to_lobby":');
  assertStringIncludes(source, 'case "kick_player":');
  assertStringIncludes(source, 'case "close_room":');
  assertStringIncludes(source, 'case "return_finished_room_to_lobby":');

  const finishedReset = source.slice(
    source.indexOf("function replayResetPatch"),
    source.indexOf("async function updateGameMode"),
  );
  assertStringIncludes(
    finishedReset,
    "requiresReplayVotes && !replayVoteState(room).unanimous",
  );
  assertStringIncludes(
    finishedReset,
    "replayResetPatch(latest, user, body)",
  );
  assertStringIncludes(
    finishedReset,
    "replayResetPatch(latest, user, body, false)",
  );
  assertStringIncludes(finishedReset, "finishedLobbyReturnAlreadyComplete(");
  assertStringIncludes(finishedReset, "updateRoomWithRetry(");
  assertEquals(
    source.slice(
      source.indexOf("const FAST_ROOM_ACTIONS"),
      source.indexOf("function canUseFastRoomAction"),
    ).includes('"return_finished_room_to_lobby"'),
    false,
  );

  const fastActions = source.slice(
    source.indexOf("const FAST_ROOM_ACTIONS"),
    source.indexOf("function canUseFastRoomAction"),
  );
  assertStringIncludes(fastActions, '"update_game_mode"');
  assertEquals(fastActions.includes('"vote_return_to_lobby"'), false);
  assertEquals(fastActions.includes('"kick_player"'), false);
  assertEquals(fastActions.includes('"close_room"'), false);

  const leasedPath = source.slice(
    source.indexOf("const userIDs = await roomLifecycleUserIDs("),
    source.indexOf("}).catch((error) =>"),
  );
  assertStringIncludes(leasedPath, "withRoomWriteLeases({");
  assertStringIncludes(leasedPath, "assertExactRoomLeaseCoverage(");
  assertStringIncludes(leasedPath, "executeRoomActionWithSignal(");

  const signalPath = source.slice(
    source.indexOf("async function executeRoomActionWithSignal"),
    source.indexOf("function isCommittedFinishedRoom"),
  );
  assertStringIncludes(signalPath, 'action === "kick_player"');
  assertStringIncludes(signalPath, 'action === "leave_room"');
  assertStringIncludes(signalPath, "transition.removedPlayer?.user_id");
  assertStringIncludes(signalPath, 'state: "closed"');
  assertStringIncludes(signalPath, "stageGameRoomSignalFanout(base44, {");
  assertStringIncludes(signalPath, 'action === "update_game_mode"');
  assertStringIncludes(signalPath, "lobbyModeSignalProjectionForRoom(result)");
  assertStringIncludes(
    signalPath,
    'recipients: recipients || roomSignalRecipients(result, "active")',
  );

  const postLeaseSignal = source.slice(
    source.indexOf("async function fanoutStagedGameRoomSignalsAfterLeases"),
    source.indexOf("async function assertLiveActivityEndQueueCoverage"),
  );
  assertStringIncludes(postLeaseSignal, "runPostLeaseSignalWithinDeadline({");
  assertStringIncludes(
    postLeaseSignal,
    "runLatestRoomSignalAfterLeaseContention({",
  );
  assertStringIncludes(postLeaseSignal, "withRoomWriteLeases({");
  assertStringIncludes(postLeaseSignal, "attempts: 1");
  assertStringIncludes(postLeaseSignal, "fetchRoom(base44, current.room.id)");
  assertStringIncludes(postLeaseSignal, "assertExactRoomLeaseCoverage(");
  assertStringIncludes(postLeaseSignal, "projection: staged.projection");
  assertStringIncludes(postLeaseSignal, "timeoutMS: 600");

  const deletePath = source.slice(
    source.indexOf("async function deleteRoom"),
    source.indexOf("function randomRoomCode"),
  );
  const closeIntent = deletePath.indexOf(
    "const closingRoom = await ensureRoomCloseIntent(base44, latest)",
  );
  const durableClosedSignal = deletePath.indexOf(
    "await persistClosedRoomSignals(base44, closingRoom)",
  );
  const stagedClose = deletePath.indexOf(
    "stageCompletedRoomClose(base44, closingRoom, completion)",
  );
  assert(
    closeIntent >= 0 && closeIntent < durableClosedSignal &&
      durableClosedSignal < stagedClose,
    "logical close and durable recipient signals must commit before staging phase two",
  );
  assertEquals(
    deletePath.includes("deleteRoomAndVerify({"),
    false,
    "phase one must release participant leases before physical deletion",
  );

  const completedDelete = source.slice(
    source.indexOf("async function deleteCompletedRoomCloseUnderLeases"),
    source.indexOf("async function recoverCompletedRoomClose"),
  );
  const queueCoverage = completedDelete.indexOf(
    "await assertLiveActivityEndQueueCoverage(",
  );
  const queueReceipt = completedDelete.indexOf(
    "await persistRoomCloseActivityEndQueuedUnderLeases(",
  );
  const physicalDelete = completedDelete.indexOf("await deleteRoomAndVerify({");
  assert(
    queueCoverage >= 0 && queueCoverage < queueReceipt &&
      queueReceipt < physicalDelete,
    "physical deletion requires exact queue coverage and a durable phase receipt",
  );

  const recovery = source.slice(
    source.indexOf("async function recoverCompletedRoomClose"),
    source.indexOf("async function finalizeStagedRoomCloseAfterLeases"),
  );
  assert(
    recovery.indexOf("await enqueueRoomLiveActivityEnd(") <
      recovery.indexOf("await withRoomWriteLeases({"),
    "ActivityKit queueing must finish before participant leases are reacquired",
  );

  const handler = source.slice(source.indexOf("Deno.serve(async"));
  const actionCompleted = handler.indexOf(
    "actionCompletedAt = performance.now()",
  );
  const postLeaseWake = handler.indexOf(
    "await fanoutStagedGameRoomSignalsAfterLeases(base44)",
    actionCompleted,
  );
  const finalizeClose = handler.indexOf(
    "await finalizeStagedRoomCloseAfterLeases(base44)",
    postLeaseWake,
  );
  const promptEndDelivery = handler.indexOf(
    "await triggerStagedLiveActivityEndDelivery(base44)",
    finalizeClose,
  );
  assert(
    actionCompleted >= 0 && actionCompleted < postLeaseWake &&
      postLeaseWake < finalizeClose && finalizeClose < promptEndDelivery,
    "kick/room signal fanout must begin only after mutation leases are released",
  );

  const close = source.slice(
    source.indexOf("async function closeRoom"),
    source.indexOf("async function leaveRoom"),
  );
  assertStringIncludes(close, "requirePlayer(room, user)");
  assertStringIncludes(close, "requireHost(room, user)");
  assertStringIncludes(
    close,
    "const terminal = pendingTerminalIntent(closable)",
  );
  assertStringIncludes(
    close,
    "closable = await finishRoom(base44, closable, terminal.winner, {}, {",
  );
  assertStringIncludes(close, "allowCloseIntent: true");
  assertStringIncludes(
    close,
    "closable = await ensureTerminalOutboxCommitBeforeMutation(base44, closable)",
  );
  assertStringIncludes(close, "return await deleteRoom(base44, closable, {");
  assertStringIncludes(close, "allowPendingTerminal: true");
  assertStringIncludes(
    close,
    "liveActivityEndQueuedRoomID: options.liveActivityEndQueuedRoomID",
  );
  assertStringIncludes(
    close,
    "liveActivityEndQueuedMatchID: options.liveActivityEndQueuedMatchID",
  );
  assertEquals(close.includes("hostDepartureUsesMembershipTransition"), false);

  const leave = source.slice(
    source.indexOf("async function leaveRoom"),
    source.indexOf("async function userIDForEmail"),
  );
  assertStringIncludes(leave, "hostDepartureUsesMembershipTransition(");

  const deletion = source.slice(
    source.indexOf("async function deleteRoom"),
    source.indexOf("function randomRoomCode"),
  );
  assertStringIncludes(
    deletion,
    "const closingRoom = await ensureRoomCloseIntent(base44, latest)",
  );
  assertStringIncludes(
    deletion,
    "await persistClosedRoomSignals(base44, closingRoom)",
  );
  assertStringIncludes(
    deletion,
    "assertRoomMutationOpen(\n    latest,",
  );
  assertStringIncludes(
    deletion,
    "stageCompletedRoomClose(base44, closingRoom, completion)",
  );
  assertEquals(deletion.includes("afterVerifiedDelete:"), false);
  assertEquals(deletion.includes("deleteRoomAndVerify({"), false);

  const completedDeletion = source.slice(
    source.indexOf("async function deleteCompletedRoomCloseUnderLeases"),
    source.indexOf("async function recoverCompletedRoomClose"),
  );
  assertStringIncludes(
    completedDeletion,
    "await persistRoomCloseActivityEndQueuedUnderLeases(",
  );
  assertStringIncludes(completedDeletion, "afterVerifiedDelete:");

  const preLeaseEnd = source.indexOf(
    "if (mustQueueLiveActivityEndBeforeLeases)",
  );
  const preflightHost = source.lastIndexOf(
    'if (action === "close_room") requireHost(room, user)',
    preLeaseEnd,
  );
  const leasedMutation = source.indexOf(
    "result = await retryRoomMembershipChangeBeforeAction",
    preLeaseEnd,
  );
  assert(
    preflightHost >= 0 && preflightHost < preLeaseEnd &&
      preLeaseEnd < leasedMutation,
    "room deletion must queue ActivityKit end before participant leases are acquired",
  );
  const preLeaseEndSource = source.slice(preLeaseEnd, leasedMutation);
  assertStringIncludes(
    preLeaseEndSource,
    "await enqueueRoomLiveActivityEnd(base44, room)",
  );
  assertStringIncludes(
    preLeaseEndSource,
    "__server_live_activity_end_room_id: liveActivityEndQueuedRoomID",
  );
  assertStringIncludes(
    preLeaseEndSource,
    "__server_live_activity_end_match_id: liveActivityEndQueuedMatchID",
  );

  const missingRoomRetryStart = source.indexOf(
    'if ((action === "close_room" || action === "leave_room") && roomId)',
  );
  const missingRoomRetry = source.slice(
    missingRoomRetryStart,
    source.indexOf("const capturedActionBody", missingRoomRetryStart),
  );
  assertStringIncludes(missingRoomRetry, "completedRoomCloseForHost(");
  assertStringIncludes(missingRoomRetry, "recoverCompletedRoomClose(");
  assertStringIncludes(missingRoomRetry, 'action === "close_room" && !room');
  assertStringIncludes(missingRoomRetry, 'action === "leave_room"');
  assertStringIncludes(missingRoomRetry, "roomLeaveAlreadyComplete(");
  assertStringIncludes(missingRoomRetry, "durableRoomExitIsCommitted(");
  assertStringIncludes(
    missingRoomRetry,
    "persistClosedRoomSignalForUser(",
  );
  assertStringIncludes(
    source.slice(
      source.indexOf(
        "async function persistClosedRoomSignalForUserUnderLeases",
      ),
      source.indexOf("async function persistClosedRoomSignalForUser("),
    ),
    "hasDurableClosedRoomSignal(",
  );
  assertStringIncludes(
    source,
    "if (!latest) throw unconfirmedRoomCloseError()",
  );
  assertEquals(
    source.includes(
      '["leave_room", "close_room"].includes(action)',
    ),
    false,
    "a transient missing read must never acknowledge an unproved host close",
  );
  assertStringIncludes(source, "throw unconfirmedRoomExitError()");

  const closeIntentHelper = source.slice(
    source.indexOf("async function ensureRoomCloseIntent"),
    source.indexOf("async function deleteRoom"),
  );
  assertStringIncludes(closeIntentHelper, "newRoomCloseIntent({");
  assertStringIncludes(closeIntentHelper, "persistClosedRoomSignals");
  assertStringIncludes(closeIntentHelper, "newRoomCloseCompletion({ room })");
  assertStringIncludes(
    closeIntentHelper,
    "roomCloseCompletionCoversSignals(",
  );
  assertEquals(
    closeIntentHelper.includes("!matchID"),
    false,
    "waiting-lobby close and sole-player leave must not require a match id",
  );

  const terminalGuard = source.indexOf(
    "const terminal = pendingTerminalIntent(room)",
  );
  const actionSwitch = source.indexOf("switch (action)", terminalGuard);
  const voteCase = source.indexOf('case "vote_return_to_lobby":', actionSwitch);
  assert(
    terminalGuard >= 0 && terminalGuard < actionSwitch &&
      actionSwitch < voteCase,
    "pending terminal reconciliation must win before lobby-return voting",
  );
  const terminalGuardSource = source.slice(terminalGuard, actionSwitch);
  assertStringIncludes(
    terminalGuardSource,
    'if (terminal && action !== "close_room")',
  );
  assertStringIncludes(
    terminalGuardSource,
    'if (!["join_room", "close_room"].includes(action))',
  );

  const completeStart = source.slice(
    source.indexOf("async function completeGameStart"),
    source.indexOf("async function repairDetectedCommittedGameStart"),
  );
  assertStringIncludes(completeStart, 'status: "playing"');
  assertStringIncludes(completeStart, "ready_players: []");
});

Deno.test("legacy leave and close bind the server membership before lifecycle waits", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const capturedStart = source.indexOf("const capturedActionBody");
  const capturedEnd = source.indexOf(
    "const mustQueueLiveActivityEndBeforeLeases",
    capturedStart,
  );
  const captured = source.slice(capturedStart, capturedEnd);
  assertStringIncludes(
    captured,
    'if (action === "leave_room" || action === "close_room")',
  );
  assertStringIncludes(captured, "captureRoomExitMembershipGeneration(");
  assertStringIncludes(captured, "__server_room_exit_membership_id:");
  assert(
    captured.indexOf("...body") <
      captured.indexOf("__server_room_exit_membership_id:"),
    "the server capture must overwrite any caller-supplied private marker",
  );

  const execute = source.slice(
    source.indexOf("async function executeRoomAction("),
    source.indexOf("async function executeRoomActionWithSignal("),
  );
  assertEquals(
    execute.match(/boundRoomExitMembershipID\(body\)/g)?.length,
    5,
    "every leave/close mutation guard must consume the captured generation",
  );

  const join = source.slice(
    source.indexOf("async function joinRoom("),
    source.indexOf("async function beginReadyCheck("),
  );
  assertStringIncludes(join, "expectedRoomExitMembershipID(body)");
  assertEquals(
    join.includes("boundRoomExitMembershipID(body)"),
    false,
    "a client private marker must never authorize membership rotation on join",
  );
});

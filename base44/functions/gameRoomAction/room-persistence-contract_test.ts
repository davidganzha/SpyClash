import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("room writes use a custom monotonic CAS instead of system timestamps", async () => {
  const source = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const casSource = await Deno.readTextFile(
    new URL("./room-write-cas.ts", import.meta.url),
  );

  assert(
    !casSource.includes("updated_date"),
    "GameRoom must not CAS against Base44's system updated_date field",
  );
  assert(
    !source.includes("entities.GameRoom.deleteMany("),
    "GameRoom deletion must use the stable entity id under writer leases",
  );
  assertStringIncludes(
    source,
    "writeRoomWithCAS({",
  );
  assertStringIncludes(
    casSource,
    "{ id: roomID, room_revision: expectedRevision }",
  );
  assertStringIncludes(
    source,
    "deleteRoomAndVerify({",
  );
  assertStringIncludes(
    source,
    "updateRoomWithRetry(\n    base44,\n    room,",
  );
  assertStringIncludes(
    source,
    'action === "leave_room" && roomLeaveAlreadyComplete(room, user.email)',
  );
});

Deno.test("association spin settlement is recoverable by every active player", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const stopAssociationSpin = source.slice(
    source.indexOf("async function stopAssociationSpin"),
    source.indexOf("async function markAnswerHeard"),
  );

  assertStringIncludes(stopAssociationSpin, "requirePlayer(room, user)");
  assertStringIncludes(
    stopAssociationSpin,
    "activePlayers(room).some((player) => player.email === user.email)",
  );
  assertEquals(
    stopAssociationSpin.includes("current_asker_email"),
    false,
    "spin settlement must not depend on the selected speaker's device",
  );
  assertEquals(
    stopAssociationSpin.includes("host_email"),
    false,
    "spin settlement must not depend on the host device",
  );
});

Deno.test("waiting rejoin refreshes capability while explicit active departure stays hidden", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const projection = await Deno.readTextFile(
    new URL("./room-projection.ts", import.meta.url),
  );
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL("../../entities/GameRoom.jsonc", import.meta.url),
    ),
  );

  const join = source.slice(
    source.indexOf("async function joinRoom"),
    source.indexOf("async function beginReadyCheck"),
  );
  assertStringIncludes(join, "playerFromUser(user, body)");
  assertStringIncludes(join, "mergePlayers(players(latest), player)");
  assertStringIncludes(join, "playerSupportsMultiSpy(player)");
  assertStringIncludes(join, "departed_player_emails:");
  assertStringIncludes(join, "roomHasDepartedPlayer(latest, user.email)");
  assertStringIncludes(join, 'normalizedStatus(latest) !== "waiting"');

  const activeLookup = source.slice(
    source.indexOf("function roomIsVisibleToActiveParticipant"),
    source.indexOf("async function executeRoomAction"),
  );
  assertStringIncludes(
    activeLookup,
    "!roomHasDepartedPlayer(room, user.email)",
  );

  const replay = source.slice(
    source.indexOf("async function resetRoomForReplay"),
    source.indexOf("async function updateGameMode"),
  );
  assertStringIncludes(replay, "const replayPlayers = players(room).filter(");
  assertStringIncludes(replay, "departed_player_emails: []");
  assertStringIncludes(
    replay,
    "...lobbyMembershipClampPatch(room, replayPlayers.length)",
  );

  const departurePolicy = await Deno.readTextFile(
    new URL("./multi-spy-policy.ts", import.meta.url),
  );
  const activeDeparture = departurePolicy.slice(
    departurePolicy.indexOf("export function activeDepartureTransition"),
  );
  assertStringIncludes(activeDeparture, "departed_player_emails: departed");
  assertEquals(
    activeDeparture.includes("cards_read:"),
    false,
    "post-start departure must preserve historical card acknowledgements",
  );

  assert("departed_player_emails" in schema.properties);
  assertEquals(
    schema.properties.departed_player_emails.rls.read.user_condition.role,
    "admin",
  );
  assertEquals(
    projection.includes("departed_player_emails"),
    false,
    "explicit departure tombstones are server-only",
  );
  const deleteAccount = await Deno.readTextFile(
    new URL("../deleteAccount/main.ts", import.meta.url),
  );
  assertStringIncludes(
    deleteAccount,
    "list(room.departed_player_emails).includes(email)",
  );
});

Deno.test("detective casts resolve N-S voting from the latest CAS snapshot", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const policy = await Deno.readTextFile(
    new URL("./detective-vote-policy.ts", import.meta.url),
  );
  const castVote = source.slice(
    source.indexOf("async function castDetectiveVote"),
    source.indexOf("async function submitSpyGuess"),
  );

  assertStringIncludes(castVote, "commitDetectiveVoteCastWithRetry({");
  assertStringIncludes(castVote, "buildPatch: (latest) => {");
  assertStringIncludes(castVote, "activePlayers(latest)");
  assertStringIncludes(castVote, "voteRequests(latest)");
  assertStringIncludes(castVote, "detectiveVotes(latest)");
  assertStringIncludes(castVote, "resolvedDetectiveVoteCastTransition(");
  assertStringIncludes(castVote, "canonicalSpyEmails(latest)");
  assertStringIncludes(castVote, "bindDetectiveVoteRoundIdentity(");
  assertStringIncludes(castVote, "explicitExpectedRoundID");
  assertStringIncludes(castVote, "serverCapturedRoundID");
  assertStringIncludes(
    castVote,
    'assertGameActionAllowedWhilePaused(latest, "cast_detective_vote")',
  );
  assertStringIncludes(
    castVote,
    "hasGameTimerElapsed(latest, nowMilliseconds)",
  );
  assertStringIncludes(
    castVote,
    "deriveExpiredGameWinner(latest, nowMilliseconds)",
  );
  assertStringIncludes(castVote, "terminal_intent: buildTerminalIntent(");
  assertStringIncludes(castVote, "{ ...latest, ...patch }");
  assertStringIncludes(castVote, "isSettledAfterConflict: (latest) => {");
  assertStringIncludes(
    castVote,
    "if (hasGameTimerElapsed(latest)) return false",
  );
  assertStringIncludes(castVote, "pendingTerminalIntent(votedRoom)");
  assertStringIncludes(castVote, "requestStartedDuringThisVote");
  assertStringIncludes(castVote, "return room;");
  assertEquals(
    castVote.includes("shouldSpyWin(updated)"),
    false,
    "innocent ejection and its possible spy terminal must share one CAS",
  );
  assertStringIncludes(policy, "resolvedDetectiveVoteCastTransition(");
  assertStringIncludes(policy, "spectators,");
  assertStringIncludes(policy, "eliminated_emails: eliminated");
  assertStringIncludes(policy, "activeSpyCount >= activeDetectiveCount");
  assertStringIncludes(policy, 'activeSpyCount === 0\n    ? "detectives"');

  const requestDispatch = source.slice(
    source.indexOf("const room = roomId"),
    source.indexOf("const elapsedMilliseconds = performance.now()"),
  );
  assertStringIncludes(
    requestDispatch,
    "__server_vote_cast_started_active: enteredActiveRound",
  );
  assertStringIncludes(
    requestDispatch,
    "__server_vote_cast_match_id: clean(room.match_id)",
  );
  assertStringIncludes(
    requestDispatch,
    "__server_vote_cast_round_id: currentRoundID ||",
  );
  assertStringIncludes(
    requestDispatch,
    "expectedRoundID: explicitExpectedVoteRoundID(actionBody) ||",
  );
  assertStringIncludes(
    requestDispatch,
    "migratedRoom,\n                  user,\n                  actionBody,",
  );
  assertStringIncludes(
    requestDispatch,
    "reconcileDetectiveVoteCastAfterActiveIdentityLease({",
  );
  assertStringIncludes(
    requestDispatch,
    "requestEnteredActiveVote:\n              actionBody?.__server_vote_cast_started_active === true",
  );
  assertStringIncludes(
    requestDispatch,
    "if (result?.id && !readOnlyCastLeaseRecovery)",
  );
  assertStringIncludes(
    source,
    'if (action !== "cast_detective_vote") {\n    assertGameActionAllowedByDeadline(room, action);',
  );
});

Deno.test("multi-spy history is retained for every role but excluded from rankings", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL("../../entities/GameHistory.jsonc", import.meta.url),
    ),
  );
  const archive = source.slice(
    source.indexOf("async function archiveRoomResult"),
    source.indexOf("async function claimTerminalIntent"),
  );
  assertStringIncludes(archive, "const spyEmails = canonicalSpyEmails(room)");
  assertStringIncludes(
    archive,
    "const isSpy = spyKeys.has(clean(player.email).toLocaleLowerCase())",
  );
  assertStringIncludes(archive, "ranked: spyEmails.length === 1");
  assertStringIncludes(archive, "spy_count: spyEmails.length");
  assertStringIncludes(archive, 'role: isSpy ? "spy" : "detective"');
  assert("spy_count" in schema.properties);
  assertEquals(schema.properties.spy_count.maximum, 3);
});

Deno.test("online intro, pause, and timer fields are wired into dispatch", async () => {
  const source = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL("../../entities/GameRoom.jsonc", import.meta.url),
    ),
  );

  for (
    const field of [
      "intro_started_at",
      "game_paused_at",
      "game_paused_total_seconds",
      "detective_vote_round_id",
    ]
  ) {
    assert(field in schema.properties, `${field} must exist in GameRoom`);
  }
  assertEquals(schema.properties.game_paused_total_seconds.default, 0);
  assertEquals(schema.properties.detective_vote_round_id.default, "");

  assertStringIncludes(source, 'case "pause_game":');
  assertStringIncludes(source, 'case "resume_game":');
  assertStringIncludes(
    source,
    "assertGameActionAllowedByDeadline(room, action)",
  );
  assertStringIncludes(source, 'code: "self_vote_not_allowed"');
  assertStringIncludes(
    source,
    "assertGameActionAllowedWhilePaused(room, action)",
  );
  assertStringIncludes(source, "preTimerMembershipTransitionPatch({");

  const startValidation = source.slice(
    source.indexOf("function validatedStartPatch"),
    source.indexOf("async function armRoulette"),
  );
  assertStringIncludes(
    startValidation,
    "hasValidEnabledStartWordPool(wordPool, secretWord)",
  );

  const roomDelete = source.slice(
    source.indexOf("async function deleteRoom"),
    source.indexOf("function randomRoomCode"),
  );
  const remoteEnd = roomDelete.indexOf(
    "await endRoomLiveActivitiesBeforeDelete(base44, latest)",
  );
  const postEndLeaseCheck = roomDelete.indexOf(
    "await assertRoomPersistenceBoundary(base44)",
    remoteEnd,
  );
  const entityDelete = roomDelete.indexOf("await deleteRoomAndVerify({");
  assert(
    remoteEnd >= 0 && remoteEnd < postEndLeaseCheck &&
      postEndLeaseCheck < entityDelete,
    "a persisted ActivityKit end intent and renewed lease must precede active room deletion",
  );

  const pushDispatchSource = source.slice(
    source.indexOf("async function dispatchRoomPushBestEffort"),
    source.indexOf("function lifecycleHTTPStatus"),
  );
  assertStringIncludes(pushDispatchSource, "internalPushSecret(");
  assertStringIncludes(
    pushDispatchSource,
    'action === "complete_game_start"',
  );
  assertStringIncludes(
    pushDispatchSource,
    "shouldSynchronizeLiveActivity(action, room)",
  );

  const leaveAction = source.slice(
    source.indexOf("async function leaveRoom"),
    source.indexOf("function activeRoomStatus"),
  );
  assertStringIncludes(leaveAction, "leavingDuringPreTimer");
  assertStringIncludes(leaveAction, "detectiveVoteLeavePatch(");
  assertStringIncludes(leaveAction, "...leavingVotePatch");
  assertStringIncludes(
    leaveAction,
    "{ host_email: clean(nextPlayers[0]?.email) }",
  );

  const executeAction = source.slice(
    source.indexOf("async function executeRoomAction"),
    source.indexOf("async function dispatchRoomPushBestEffort"),
  );
  const terminalReconciliation = executeAction.indexOf(
    "return await finishRoom(base44, room, terminal.winner)",
  );
  const pauseGuard = executeAction.indexOf(
    "assertGameActionAllowedWhilePaused(room, action)",
  );
  const actionSwitch = executeAction.indexOf("switch (action)");
  assert(
    terminalReconciliation >= 0 && terminalReconciliation < pauseGuard &&
      pauseGuard < actionSwitch,
    "pending terminal reconciliation must precede the pause mutation guard",
  );

  const completeStart = source.slice(
    source.indexOf("async function completeGameStart"),
    source.indexOf("async function markRoleCardRead"),
  );
  const committedGuard = completeStart.indexOf(
    'normalizedStatus(room) === "playing"',
  );
  const matchCreation = completeStart.indexOf(
    "const matchID = crypto.randomUUID()",
  );
  const roomCommit = completeStart.indexOf(
    "const committed = await updateRoom",
  );
  const existingReconciliation = completeStart.indexOf(
    "await enqueueCommittedGameStart(base44, room)",
  );
  const committedReconciliation = completeStart.lastIndexOf(
    "await enqueueCommittedGameStart(base44, committed)",
  );
  assert(
    committedGuard >= 0 && committedGuard < existingReconciliation &&
      existingReconciliation < matchCreation,
    "a repeated completion must reconcile only its persisted event identity",
  );
  assert(
    matchCreation >= 0 && matchCreation < roomCommit &&
      roomCommit < committedReconciliation,
    "game identity must be persisted before idempotent push enqueue",
  );
  assert(
    !completeStart.includes("enqueueGamePushEvents({"),
    "completion must never enqueue an uncommitted game identity",
  );
  assert(
    !completeStart.includes("validatedStartPatch"),
    "completion must commit the plan persisted by arm_roulette",
  );

  const leasedAction = source.slice(
    source.indexOf(
      "const fastRoomAction = !actorCapabilityRefreshNeeded(",
    ),
    source.indexOf("if (result?.id && !readOnlyCastLeaseRecovery)"),
  );
  const fastDispatch = leasedAction.indexOf(
    "result = await executeRoomActionWithSignal(",
  );
  const lease = leasedAction.indexOf("return await withRoomWriteLeases({");
  const refetch = leasedAction.indexOf("const latestRoom = await fetchRoom");
  const dispatch = leasedAction.indexOf(
    "return await executeRoomActionWithSignal(",
  );
  const recovery = leasedAction.indexOf("recover: async () =>");
  const recoveryBypass = leasedAction.indexOf(
    "allowActiveIdentityLeaseRecovery: true",
  );
  assert(
    fastDispatch >= 0 && fastDispatch < lease && lease < refetch &&
      refetch < dispatch &&
      dispatch < recovery && recovery < recoveryBypass,
    "rapid gameplay must bypass identity leases while lifecycle writes remain serialized",
  );
  assertStringIncludes(
    leasedAction,
    "actionBody,\n    ) && canUseFastRoomAction(action, room, user)",
  );
  assertStringIncludes(source, '"mark_role_card_read",');
  assertStringIncludes(source, '"request_vote",');
  assertEquals(
    source.match(/allowActiveIdentityLeaseRecovery: true/g)?.length,
    1,
    "only the explicit safe-action recovery may bypass a writer lease",
  );
  assertStringIncludes(
    leasedAction,
    "reconcileCommittedGameStartAfterActiveIdentityLease({",
  );
  assert(
    leasedAction.indexOf(
      "reconcileCommittedGameStartAfterActiveIdentityLease({",
    ) <
      recovery,
    "game start must reconcile by read before any safe-action write bypass",
  );
  assertStringIncludes(
    leasedAction,
    "assertParticipant: (candidate) => requirePlayer(candidate, user)",
  );
  assertStringIncludes(
    leasedAction,
    "repairDetectedCommittedGameStart(base44, candidate, user)",
  );

  const committedStartRepair = source.slice(
    source.indexOf("async function repairDetectedCommittedGameStart"),
    source.indexOf("async function markRoleCardRead"),
  );
  const freshLeaseAdapter = committedStartRepair.indexOf(
    "withFreshLeases: (userIDs, repair)",
  );
  const freshLeases = committedStartRepair.indexOf("withRoomWriteLeases({");
  const exactCoverage = committedStartRepair.indexOf(
    "assertExactRoomLeaseCoverage(context, userIDs)",
  );
  const idempotentReconcile = committedStartRepair.indexOf(
    "completeGameStart(base44, candidate, user)",
  );
  const activeLeaseAssertion = committedStartRepair.indexOf(
    "assertRoomWriteLeases(context)",
  );
  const signalRepair = committedStartRepair.indexOf(
    "fanoutGameRoomSignalsBestEffort({",
  );
  assert(
    freshLeaseAdapter >= 0 && freshLeaseAdapter < freshLeases &&
      freshLeases < exactCoverage && exactCoverage < activeLeaseAssertion &&
      activeLeaseAssertion < idempotentReconcile &&
      idempotentReconcile < signalRepair,
    "committed start repair must reacquire exact leases before enqueue and signal fanout",
  );

  const committedRepairSource = await Deno.readTextFile(
    new URL("./committed-game-start-repair.ts", import.meta.url),
  );
  const protectedRepair = committedRepairSource.slice(
    committedRepairSource.indexOf(
      "export async function repairCommittedGameStartWithFreshLeases",
    ),
  );
  const protectedLease = protectedRepair.indexOf(
    "return await input.withFreshLeases(",
  );
  const protectedReconcile = protectedRepair.indexOf(
    "const reconciledRoom = await input.reconcile(migratedRoom)",
  );
  const protectedActiveLease = protectedRepair.indexOf(
    "await input.assertLeasesActive(context)",
  );
  const protectedFanout = protectedRepair.indexOf(
    "await input.fanout(finalRoom)",
  );
  assert(
    protectedLease >= 0 && protectedLease < protectedReconcile &&
      protectedReconcile < protectedActiveLease &&
      protectedActiveLease < protectedFanout,
    "enqueue reconciliation and signal repair must execute inside the fresh lease callback",
  );

  const lifecycleSource = await Deno.readTextFile(
    new URL("./room-write-lifecycle.ts", import.meta.url),
  );
  const safeRecovery = lifecycleSource.slice(
    lifecycleSource.indexOf("const ACTIVE_LEASE_RECOVERY_ACTIONS"),
    lifecycleSource.indexOf("function boundedAttemptCount"),
  );
  assertEquals(
    safeRecovery.includes('"leave_room"'),
    false,
    "membership-changing leave must not bypass participant writer leases",
  );
  assertStringIncludes(safeRecovery, '"mark_role_card_read"');
  assertStringIncludes(safeRecovery, 'input.error.code === "active_lease"');
  assert(
    !safeRecovery.includes("deletion_in_progress"),
    "safe-action recovery must not bypass account deletion",
  );

  const errorHandler = source.slice(
    source.lastIndexOf("} catch (error) {"),
  );
  assertStringIncludes(
    errorHandler,
    "const status = lifecycleHTTPStatus(error)",
  );
  assertStringIncludes(errorHandler, "action: actionForLog");
  assertStringIncludes(errorHandler, "room_id: roomIDForLog");
  assertStringIncludes(errorHandler, "code: safeLogLabel(error?.code)");
  assertStringIncludes(errorHandler, "status,");
  assertEquals(errorHandler.includes("accessToken"), false);
  assertEquals(errorHandler.includes("user.email"), false);
  assertEquals(errorHandler.includes("error?.message || error"), false);

  const finalizeCase = source.slice(
    source.indexOf('case "finalize_expired_room":'),
    source.indexOf('case "finish_room":'),
  );
  assertStringIncludes(finalizeCase, "deriveExpiredGameWinner(room)");
  assert(
    !finalizeCase.includes("requireHost"),
    "any current participant may finalize an elapsed server timer",
  );

  const replayVote = source.slice(
    source.indexOf("async function votePlayAgain"),
    source.indexOf("async function resetRoomForReplay"),
  );
  assertStringIncludes(replayVote, 'normalizedStatus(room) !== "finished"');
  assertStringIncludes(replayVote, 'normalizedStatus(latest) !== "finished"');
});

Deno.test("authoritative lobby snapshots are revisioned, frozen into start, and preserved for replay", async () => {
  const source = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL("../../entities/GameRoom.jsonc", import.meta.url),
    ),
  );
  for (
    const field of [
      "lobby_schema_version",
      "lobby_revision",
      "lobby_spy_count",
      "spies_know_each_other",
      "spy_emails",
      "lobby_word_source",
      "lobby_source_pack_id",
      "lobby_source_name",
      "lobby_theme",
      "lobby_category",
      "lobby_word_count",
      "lobby_word_count_mode",
      "lobby_word_pool",
      "lobby_last_mutation_id",
      "lobby_last_mutation_fingerprint",
    ]
  ) {
    assert(field in schema.properties, `${field} must exist in GameRoom`);
  }
  assertEquals(schema.properties.lobby_revision.default, 0);
  assertEquals(schema.properties.lobby_schema_version.default, 2);
  assertEquals(schema.properties.lobby_spy_count.maximum, 3);
  assertEquals(schema.properties.spies_know_each_other.default, false);
  assertEquals(schema.properties.lobby_word_pool.maxItems, 200);

  const update = source.slice(
    source.indexOf("async function updateLobbyState"),
    source.indexOf("function validatedStartPatch"),
  );
  assertStringIncludes(
    update,
    'assertLobbySettingsAccess(room, user, "lobby")',
  );
  assertStringIncludes(update, "validateLobbyMutation({");
  assertStringIncludes(update, "updateRoomWithRetry(");
  assertStringIncludes(update, "assertLobbySettingsAccess(latest, user");
  assertStringIncludes(
    update,
    "lobbyMutationPatch(latest, effectiveMutation)",
  );
  assertStringIncludes(
    update,
    "roomHasLobbyMutation(latest, effectiveMutation)",
  );
  assertEquals(update.includes("fanoutGameRoomSignalsBestEffort({"), false);
  assertStringIncludes(source, "async function executeRoomActionWithSignal");

  const start = source.slice(
    source.indexOf("async function armRoulette"),
    source.indexOf("async function enqueueCommittedGameStart"),
  );
  const authoritative = start.indexOf("authoritativeStartPayload(");
  const assignment = start.indexOf(
    "const assignment = serverSpyAssignment(room)",
  );
  const validation = start.indexOf(
    "validatedStartPatch(room, startPayload, assignment)",
  );
  const commit = start.indexOf("return await updateRoom(base44, room");
  assert(
    authoritative >= 0 && authoritative < assignment &&
      assignment < validation && validation < commit,
    "arm_roulette must derive and validate the authoritative lobby before committing roulette",
  );
  assertStringIncludes(start, "body?.expected_lobby_revision");

  const replay = source.slice(
    source.indexOf("async function resetRoomForReplay"),
    source.indexOf("async function updateGameMode"),
  );
  assertStringIncludes(replay, "hasAuthoritativeLobbyState(room)");
  assertStringIncludes(replay, "word_pool: []");
  assertEquals(
    replay.includes("lobby_word_pool: []"),
    false,
    "replay resets only the frozen gameplay pool",
  );

  assertStringIncludes(source, 'case "update_lobby_state":');
});

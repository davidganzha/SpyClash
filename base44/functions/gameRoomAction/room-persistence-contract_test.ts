import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("room writes use lifecycle-serialized entity id operations", async () => {
  const source = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );

  assert(
    !source.includes("entities.GameRoom.updateMany("),
    "GameRoom must not CAS against Base44's system updated_date field",
  );
  assert(
    !source.includes("entities.GameRoom.deleteMany("),
    "GameRoom deletion must use the stable entity id under writer leases",
  );
  assertStringIncludes(
    source,
    "entities.GameRoom.update(latest.id",
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
    'action === "leave_room" && leaveAlreadyComplete(room, user.email)',
  );
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
    ]
  ) {
    assert(field in schema.properties, `${field} must exist in GameRoom`);
  }
  assertEquals(schema.properties.game_paused_total_seconds.default, 0);

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

  const leaveAction = source.slice(
    source.indexOf("async function leaveRoom"),
    source.indexOf("function activeRoomStatus"),
  );
  assertStringIncludes(leaveAction, "leavingDuringPreTimer");
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
      "const result = await retryRoomMembershipChangeBeforeAction",
    ),
    source.indexOf("if (result?.id) await dispatchRoomPushBestEffort"),
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
    lease >= 0 && lease < refetch && refetch < dispatch &&
      dispatch < recovery && recovery < recoveryBypass,
    "normal actions must serialize before bounded safe-action recovery",
  );
  assertEquals(
    source.match(/allowActiveIdentityLeaseRecovery: true/g)?.length,
    1,
    "only the explicit safe-action recovery may bypass a writer lease",
  );

  const lifecycleSource = await Deno.readTextFile(
    new URL("./room-write-lifecycle.ts", import.meta.url),
  );
  const safeRecovery = lifecycleSource.slice(
    lifecycleSource.indexOf("const ACTIVE_LEASE_RECOVERY_ACTIONS"),
    lifecycleSource.indexOf("function boundedAttemptCount"),
  );
  assertStringIncludes(safeRecovery, '"leave_room"');
  assertStringIncludes(safeRecovery, '"mark_role_card_read"');
  assertStringIncludes(safeRecovery, 'input.error.code === "active_lease"');
  assert(
    !safeRecovery.includes("deletion_in_progress"),
    "safe-action recovery must not bypass account deletion",
  );

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
  assertStringIncludes(update, "lobbyMutationPatch(latest, mutation)");
  assertStringIncludes(update, "roomHasLobbyMutation(latest, mutation)");
  assertEquals(update.includes("fanoutGameRoomSignalsBestEffort({"), false);
  assertStringIncludes(source, "async function executeRoomActionWithSignal");

  const start = source.slice(
    source.indexOf("async function armRoulette"),
    source.indexOf("async function enqueueCommittedGameStart"),
  );
  const authoritative = start.indexOf("authoritativeStartPayload(");
  const validation = start.indexOf("validatedStartPatch(room, startPayload)");
  const commit = start.indexOf("return await updateRoom(base44, room");
  assert(
    authoritative >= 0 && authoritative < validation && validation < commit,
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

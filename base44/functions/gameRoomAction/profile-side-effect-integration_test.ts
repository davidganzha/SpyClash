import { assert, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("terminal profile repair is post-commit, durable, and push-independent", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const finish = source.slice(
    source.indexOf("async function finishRoom"),
    source.indexOf("async function createRoom"),
  );
  const archive = source.slice(
    source.indexOf("async function archiveRoomResult"),
    source.indexOf("async function claimTerminalIntent"),
  );
  const repair = source.slice(
    source.indexOf("async function rankedHistoryForMatch"),
    source.indexOf("async function dispatchRoomPushBestEffort"),
  );
  const dispatch = source.slice(
    source.indexOf("async function dispatchRoomSideEffectsAfterLeases"),
    source.indexOf(
      "async function dispatchFinishedCommunityProfileSideEffects",
    ),
  );

  assertStringIncludes(archive, "persistGameHistoryResult({");
  assertStringIncludes(archive, "ensureCommunityProfileRepairSource({");
  assertStringIncludes(
    archive,
    "base44.__spyclashCommunityProfileRepairSources",
  );
  assert(!archive.includes("reconcileCommunityProfileMirrors({"));
  assertStringIncludes(finish, "const finished = await updateRoomWithRetry(");
  assertStringIncludes(repair, "reconcileCommunityProfileMirrors({");
  assertStringIncludes(repair, "knownHistoryRecords: [source]");
  assertStringIncludes(repair, "cached?.sources");
  assertStringIncludes(repair, "fanoutCommunityProfileInvalidations({");
  assertStringIncludes(repair, "runCommunityProfileRepair({");
  assertStringIncludes(repair, "userIDs: [userID]");
  assertStringIncludes(repair, "recipientUserIDs: [recipientUserID]");
  assert(!repair.includes("userIDs,\n      attempts: 1"));
  assertStringIncludes(
    dispatch,
    "await fanoutDeferredFinishedRoomSignal(base44, room)",
  );
  assert(
    !dispatch.includes("dispatchFinishedCommunityProfileSideEffects(") &&
      !dispatch.includes("runTerminalSideEffectsSingleFlight({"),
    "durable profile repair must not extend the finished gameplay response",
  );
});

Deno.test("scheduled push recovery wakes profile repair without coupling delivery", async () => {
  const source = await Deno.readTextFile(
    new URL("../pushNotificationAction/main.ts", import.meta.url),
  );
  const repair = source.slice(
    source.indexOf("async function repairFinishedRoomCommunityProfiles"),
    source.indexOf("async function roomForSourceEvent"),
  );
  const durableDrain = source.slice(
    source.indexOf("async function drainDurableCommunityProfileRepairs"),
    source.indexOf("async function roomForSourceEvent"),
  );
  const recent = source.slice(
    source.indexOf("async function reconcileRecentRoomOutboxes"),
    source.indexOf("function internalRequest"),
  );
  const processStart = source.indexOf("async function processEvents");
  const process = source.slice(
    processStart,
    source.indexOf("async function drain", processStart),
  );
  const drain = source.slice(
    source.indexOf("async function drain(base44"),
    source.indexOf("Deno.serve", source.indexOf("async function drain(base44")),
  );

  assertStringIncludes(repair, '"gameRoomAction"');
  assertStringIncludes(
    repair,
    "if (finishedProfileRepairAlreadyCompleted(room)) return true;",
  );
  assertStringIncludes(
    repair,
    'action: "repair_finished_profile_side_effects"',
  );
  assertStringIncludes(repair, "internalFunctionBody(response).outcome");
  assert(
    !recent.includes("await repairFinishedRoomCommunityProfiles("),
    "scheduled terminal/outbox scan must not be blocked by per-room profile invokes",
  );
  assertStringIncludes(process, "await repairFinishedRoomCommunityProfiles(");
  assertStringIncludes(repair, "return false;");
  assertStringIncludes(
    durableDrain,
    'action: "drain_community_profile_repairs"',
  );
  assertStringIncludes(
    durableDrain,
    "profileRepairDrainSummary(bounded.value)",
  );
  assertStringIncludes(durableDrain, "await runWithinDeadline({");
  assertStringIncludes(durableDrain, 'reason: "deadline_exceeded"');
  assertStringIncludes(drain, "await drainDurableCommunityProfileRepairs(");
  assertStringIncludes(drain, "community_profile_repairs:");
  assert(
    drain.indexOf("await reconcileRecentRoomOutboxes(") <
      drain.indexOf("await drainDurableCommunityProfileRepairs("),
    "scheduled terminal/outbox repair must run before profile repair",
  );
});

Deno.test("replay reset and room deletion cannot erase the durable history repair source", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const reset = source.slice(
    source.indexOf("function replayResetPatch"),
    source.indexOf("async function updateGameMode"),
  );
  const deletion = source.slice(
    source.indexOf("async function deleteRoom"),
    source.indexOf("function randomRoomCode"),
  );
  assertStringIncludes(reset, "replayVoteState(room).unanimous");
  assertStringIncludes(reset, "updateRoomWithRetry(");
  assert(!reset.includes("GameHistory"));
  assert(!deletion.includes("GameHistory"));
  assert(!deletion.includes("profile_repair_state"));
});

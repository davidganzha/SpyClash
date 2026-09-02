import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("polling prompts the trusted idempotent terminal finalizer", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const triggerStart = source.indexOf(
    "async function triggerTerminalIntentRecovery",
  );
  const triggerEnd = source.indexOf(
    "async function backfillRoomParticipantUserIDs",
    triggerStart,
  );
  const trigger = source.slice(triggerStart, triggerEnd);
  assertStringIncludes(trigger, 'functions.invoke("gameRoomAction"');
  assertStringIncludes(trigger, 'action: "reconcile_terminal_intent"');
  assertStringIncludes(trigger, "expected_match_id: intent.match_id");
  assertStringIncludes(trigger, "expected_decided_at: intent.decided_at");

  const getRoomStart = source.indexOf('if (action === "get_room")');
  const getRoomEnd = source.indexOf(
    'if (action !== "join_room")',
    getRoomStart,
  );
  assertStringIncludes(
    source.slice(getRoomStart, getRoomEnd),
    "await triggerTerminalIntentRecovery(base44, room)",
  );
});

Deno.test("trusted terminal finalizer reacquires the full participant lease set", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const start = source.indexOf(
    "async function reconcileTerminalIntentWithFreshLeases",
  );
  const end = source.indexOf(
    "async function triggerTerminalIntentRecovery",
    start,
  );
  const recovery = source.slice(start, end);
  assertStringIncludes(recovery, "await roomParticipantUserIDs(");
  assertStringIncludes(recovery, "await withRoomWriteLeases({");
  assertStringIncludes(recovery, "assertExactRoomLeaseCoverage(");
  assertStringIncludes(recovery, "return await finishRoom(");
  assertStringIncludes(recovery, "expectedMatchID: intent.match_id");

  const routeStart = source.indexOf(
    'if (requestedAction === "reconcile_terminal_intent")',
  );
  const routeEnd = source.indexOf(
    'if (requestedAction === "drain_community_profile_repairs")',
    routeStart,
  );
  const route = source.slice(routeStart, routeEnd);
  assertStringIncludes(route, "matchesInternalPushSecret(");
  assertStringIncludes(route, "reconcileTerminalIntentWithFreshLeases(");
  assertEquals(route.indexOf("dispatchRoomSideEffectsAfterLeases(") > 0, true);
});

Deno.test("terminal recovery reuses a persisted intent before validating a new ranked finish", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const claim = source.slice(
    source.indexOf("async function claimTerminalIntent"),
    source.indexOf("async function finishRoom"),
  );
  const existingIntent = claim.indexOf(
    "const existing = terminalIntentFromRoom(latest)",
  );
  const existingReturn = claim.indexOf(
    "if (existing) return { room: latest, intent: existing }",
  );
  const rankedGuard = claim.indexOf("assertServerRankedFinishSource(latest)");
  assertEquals(
    existingIntent >= 0 && existingIntent < existingReturn &&
      existingReturn < rankedGuard,
    true,
  );

  const finish = source.slice(
    source.indexOf("async function finishRoom"),
    source.indexOf("async function ensureTerminalOutboxCommitBeforeMutation"),
  );
  const terminalClaim = finish.slice(0, finish.indexOf("const claimed ="));
  assertEquals(terminalClaim.includes("assertServerRankedFinishSource"), false);
  assertStringIncludes(finish, "const claimed = await claimTerminalIntent(");
});

Deno.test("a finished room remains repairable until the full outbox receipt is durable", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const finish = source.slice(
    source.indexOf("async function finishRoom"),
    source.indexOf("async function ensureTerminalOutboxCommitBeforeMutation"),
  );
  const roomCommit = finish.indexOf(
    "const finished = await updateRoomWithRetry(",
  );
  const pushCommit = finish.indexOf(
    "const committed = await commitGamePushEvents(",
  );
  const coverage = finish.indexOf("await gamePushCommitCoversRecipients(");
  const receipt = finish.indexOf("terminalOutboxCommitPatch({");
  assertEquals(
    roomCommit >= 0 && roomCommit < pushCommit && pushCommit < coverage &&
      coverage < receipt,
    true,
  );
  assertStringIncludes(finish, "terminalOutboxCommitIsProven(latest)");
  assertStringIncludes(finish, 'code: "terminal_outbox_unconfirmed"');

  const recovery = source.slice(
    source.indexOf("async function reconcileTerminalIntentWithFreshLeases"),
    source.indexOf("async function triggerTerminalIntentRecovery"),
  );
  assertStringIncludes(
    recovery,
    "terminalOutboxCommitIsProven(acquisitionRoom)",
  );
  assertStringIncludes(recovery, "terminalOutboxCommitIsProven(latest)");
  assertEquals(recovery.includes("isCommittedFinishedRoom("), false);

  const polling = source.slice(
    source.indexOf('if (action === "get_room")'),
    source.indexOf(
      'if (action !== "join_room")',
      source.indexOf('if (action === "get_room")'),
    ),
  );
  assertStringIncludes(polling, "terminalIntentNeedsReconciliation(room)");
});

Deno.test("replay, lobby return, leave, and close retain terminal authority until outbox proof", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const replayVote = source.slice(
    source.indexOf("async function votePlayAgain"),
    source.indexOf("function replayResetPatch"),
  );
  const replayReset = source.slice(
    source.indexOf("function replayResetPatch"),
    source.indexOf("async function updateGameMode"),
  );
  const close = source.slice(
    source.indexOf("async function closeRoom"),
    source.indexOf("async function userIDForEmail"),
  );
  const deletion = source.slice(
    source.indexOf("async function deleteRoom"),
    source.indexOf("function randomRoomCode"),
  );
  assertStringIncludes(
    replayVote,
    "ensureTerminalOutboxCommitBeforeMutation(base44, room)",
  );
  assertStringIncludes(
    replayReset,
    "assertTerminalOutboxCommitBeforeAuthorityReset(room)",
  );
  assertEquals(
    (replayReset.match(
      /ensureTerminalOutboxCommitBeforeMutation\(base44, room\)/g,
    ) || [])
      .length,
    2,
  );
  assertStringIncludes(
    close,
    "ensureTerminalOutboxCommitBeforeMutation(base44, closable)",
  );
  assertStringIncludes(
    close,
    "ensureTerminalOutboxCommitBeforeMutation(base44, room)",
  );
  assertStringIncludes(
    deletion,
    "ensureTerminalOutboxCommitBeforeMutation(base44, latest)",
  );
});

Deno.test("verified close completion ignores stale pre-intent room replicas", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  for (
    const [start, end] of [
      [
        "async function deleteCompletedRoomCloseUnderLeases",
        "async function recoverCompletedRoomClose",
      ],
      [
        "async function recoverCompletedRoomClose",
        "async function finalizeStagedRoomCloseAfterLeases",
      ],
    ]
  ) {
    const path = source.slice(source.indexOf(start), source.indexOf(end));
    assertStringIncludes(
      path,
      "verifiedRoomCloseCompletionDominatesSnapshot(",
    );
    assertEquals(path.includes("exactRoomCloseIntent("), false);
  }
});

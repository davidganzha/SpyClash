import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("spy guess latency correlation is opaque, transient, and cross-function", async () => {
  const roomSource = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const pushSource = await Deno.readTextFile(
    new URL("../pushNotificationAction/main.ts", import.meta.url),
  );

  assertStringIncludes(
    roomSource,
    'if (action === "submit_spy_guess")',
  );
  assertStringIncludes(
    roomSource,
    "spyGuessTimingID = createOpaqueTimingID()",
  );
  assertEquals(
    roomSource.includes("body?.timing_id"),
    false,
    "gameRoomAction must never accept correlation from the gameplay caller",
  );
  const finishRoom = roomSource.slice(
    roomSource.indexOf("async function finishRoom"),
    roomSource.indexOf("async function createRoom"),
  );
  const responseTiming = roomSource.slice(
    roomSource.indexOf("const logSpyGuessResponseTiming"),
    roomSource.indexOf("const respondWithSpyGuessTiming"),
  );
  assertStringIncludes(finishRoom, "options.timingID");
  assertStringIncludes(responseTiming, "timingID: spyGuessTimingID");
  assertStringIncludes(
    roomSource,
    "...(timingID ? { timing_id: timingID } : {})",
  );
  assertStringIncludes(
    pushSource,
    "createProcessEventTiming(body?.timing_id)",
  );
  assertStringIncludes(
    pushSource,
    '"pushNotificationAction process-event timing"',
  );

  const persistenceSources = await Promise.all([
    Deno.readTextFile(new URL("./push-events.ts", import.meta.url)),
    Deno.readTextFile(
      new URL("./game-history-idempotency.ts", import.meta.url),
    ),
    Deno.readTextFile(
      new URL("../../entities/GameRoom.jsonc", import.meta.url),
    ),
    Deno.readTextFile(
      new URL("../../entities/GameHistory.jsonc", import.meta.url),
    ),
    Deno.readTextFile(
      new URL(
        "../../entities/push-notification-event.jsonc",
        import.meta.url,
      ),
    ),
  ]);
  assertEquals(
    persistenceSources.some((source) => source.includes("timing_id")),
    false,
    "the request-local correlation id must never enter room/history/outbox persistence",
  );
});

Deno.test("finished response attempts durable ActivityKit enqueue then bounded signal", async () => {
  const roomSource = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const pushSource = await Deno.readTextFile(
    new URL("../pushNotificationAction/main.ts", import.meta.url),
  );
  const handler = roomSource.slice(roomSource.indexOf("Deno.serve(async"));
  const leasedAction = handler.indexOf(
    "result = await retryRoomMembershipChangeBeforeAction",
  );
  const leasesReleased = handler.indexOf(
    "actionCompletedAt = performance.now()",
    leasedAction,
  );
  const postLeaseDispatch = handler.indexOf(
    "result = await dispatchRoomSideEffectsAfterLeases(",
    leasesReleased,
  );
  const response = handler.indexOf(
    "return respondWithSpyGuessTiming(",
    postLeaseDispatch,
  );
  assert(
    leasedAction >= 0 && leasedAction < leasesReleased &&
      leasesReleased < postLeaseDispatch && postLeaseDispatch < response,
    "participant lifecycle leases must finish before side effects and response",
  );

  const sideEffects = roomSource.slice(
    roomSource.indexOf("async function dispatchRoomSideEffectsAfterLeases"),
    roomSource.indexOf(
      "async function dispatchFinishedCommunityProfileSideEffects",
    ),
  );
  const liveActivityHelper = roomSource.slice(
    roomSource.indexOf("async function enqueueRoomLiveActivityEnd"),
    roomSource.indexOf("function roomSignalRecipients"),
  );
  assertStringIncludes(
    liveActivityHelper,
    'action: "enqueue_room_live_activity_end"',
  );
  assertStringIncludes(liveActivityHelper, "timeoutMS: 2_000");
  assertStringIncludes(
    liveActivityHelper,
    "runWithWallClockDeadline({",
  );
  assertEquals(liveActivityHelper.includes('action: "process_event"'), false);
  assertEquals(
    liveActivityHelper.includes('action: "sync_live_activity"'),
    false,
  );

  const ordinaryPushHelper = roomSource.slice(
    roomSource.indexOf("async function dispatchRoomPushBestEffort"),
    roomSource.indexOf("async function dispatchRoomSideEffectsAfterLeases"),
  );
  assertStringIncludes(ordinaryPushHelper, "responseDeadlineEpochMS");
  assertStringIncludes(ordinaryPushHelper, "Date.now() + 2_000");
  assertStringIncludes(ordinaryPushHelper, "runWithWallClockDeadline({");
  assertStringIncludes(ordinaryPushHelper, "deadline_epoch_ms:");
  assertStringIncludes(
    ordinaryPushHelper,
    "await invokePushWithinResponseDeadline(invocationBody)",
  );

  const processEventStart = pushSource.indexOf("async function processEvents");
  const processEventHelper = pushSource.slice(
    processEventStart,
    pushSource.indexOf("async function drain(", processEventStart),
  );
  assertStringIncludes(
    processEventHelper,
    "clampDeadline(body.deadline_epoch_ms, 50_000)",
  );

  const signalHelper = roomSource.slice(
    roomSource.indexOf("async function fanoutDeferredFinishedRoomSignal"),
    roomSource.indexOf("async function rankedHistoryForMatch"),
  );
  assertStringIncludes(signalHelper, "runWithWallClockDeadline({");
  assertStringIncludes(signalHelper, "timeoutMS: 600");
  const finishedBranch = sideEffects.slice(
    sideEffects.indexOf("// The exact ActivityKit force-end intent"),
  );
  assertStringIncludes(
    finishedBranch,
    "await fanoutDeferredFinishedRoomSignal(base44, room)",
  );
  assertEquals(finishedBranch.includes("functions.invoke"), false);
  assertEquals(finishedBranch.includes("sync_live_activity"), false);
  const liveEndAttempt = finishedBranch.indexOf(
    "await enqueueRoomLiveActivityEnd(base44, room)",
  );
  const signal = finishedBranch.indexOf(
    "await fanoutDeferredFinishedRoomSignal(base44, room)",
  );
  assert(
    liveEndAttempt >= 0 && liveEndAttempt < signal,
    "the bounded durable end attempt must start before realtime cleanup",
  );
  for (
    const deferredWork of [
      "dispatchFinishedCommunityProfileSideEffects(",
      "dispatchRoomPushBestEffort(",
      "runTerminalSideEffectsSingleFlight({",
    ]
  ) {
    assertEquals(
      finishedBranch.includes(deferredWork),
      false,
      `finished response must not await ${deferredWork}`,
    );
  }
  assert(
    finishedBranch.indexOf("await fanoutDeferredFinishedRoomSignal") <
      finishedBranch.lastIndexOf("return room"),
    "the bounded signal attempt must complete before the finished response",
  );
  const promptDelivery = finishedBranch.indexOf(
    "await triggerQueuedLiveActivityEndDelivery(",
  );
  assert(
    promptDelivery > signal &&
      promptDelivery < finishedBranch.lastIndexOf("return room"),
    "prompt ActivityKit delivery must start post-lease after the room signal",
  );

  const promptDeliveryHelper = roomSource.slice(
    roomSource.indexOf("async function triggerQueuedLiveActivityEndDelivery"),
    roomSource.indexOf("async function triggerStagedLiveActivityEndDelivery"),
  );
  assertStringIncludes(
    promptDeliveryHelper,
    'action: "deliver_queued_room_live_activity_end"',
  );
  assertStringIncludes(promptDeliveryHelper, "timeoutMS: 250");
  assertStringIncludes(promptDeliveryHelper, "Date.now() + 20_000");
  assertStringIncludes(promptDeliveryHelper, "deadline_epoch_ms:");
});

Deno.test("latency log payloads use timing-report allowlists only", async () => {
  const roomSource = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );
  const pushSource = await Deno.readTextFile(
    new URL("../pushNotificationAction/main.ts", import.meta.url),
  );

  const roomLog = roomSource.slice(
    roomSource.indexOf('"gameRoomAction spy-guess response timing"'),
    roomSource.indexOf(
      "// Response diagnostics must never change",
      roomSource.indexOf('"gameRoomAction spy-guess response timing"'),
    ),
  );
  const pushLog = pushSource.slice(
    pushSource.indexOf('"pushNotificationAction process-event timing"'),
    pushSource.indexOf('if (action === "sync_live_activity")'),
  );
  assertStringIncludes(roomLog, "spyGuessResponseTiming({");
  assertStringIncludes(pushLog, "timing.report(timingOutcome)");
  for (
    const forbidden of [
      "room_id",
      "match_id",
      "source_event_id",
      "user_id",
      "email",
      "spy_guess",
      "token",
      "body",
    ]
  ) {
    assertEquals(roomLog.includes(forbidden), false);
    assertEquals(pushLog.includes(forbidden), false);
  }
});

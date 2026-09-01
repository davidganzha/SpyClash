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

Deno.test("latency instrumentation preserves lease, push, signal, response order", async () => {
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
  const push = sideEffects.indexOf("await dispatchRoomPushBestEffort(");
  const signal = sideEffects.indexOf(
    "await fanoutDeferredFinishedRoomSignal(base44, claimedRoom)",
  );
  assert(
    push >= 0 && push < signal,
    "ActivityKit/push dispatch must remain before realtime token cleanup",
  );

  const processEvent = pushSource.slice(
    pushSource.indexOf("async function processEvents"),
    pushSource.indexOf("async function drain(base44"),
  );
  const liveActivity = processEvent.indexOf("await syncLiveActivities(base44");
  const ordinaryPush = processEvent.indexOf("eventWork = await runBounded(");
  assert(
    liveActivity >= 0 && liveActivity < ordinaryPush,
    "ActivityKit delivery must remain before ordinary push processing",
  );
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

import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("host transfer uses guarded CAS, full participant leases and active roster signals", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const transfer = source.slice(
    source.indexOf("async function transferHost("),
    source.indexOf("async function votePlayAgain("),
  );
  assertStringIncludes(
    transfer,
    "lobbyHostTransferTransition(room, user, body)",
  );
  assertStringIncludes(transfer, "updateRoom(base44, room, patch)");
  assertStringIncludes(transfer, "error.retryable = false");
  assertEquals(transfer.includes("updateRoomWithRetry"), false);
  assertEquals(transfer.includes("kickPlayer"), false);
  assertStringIncludes(
    source,
    'case "transfer_host":\n      return await transferHost(base44, room, user, body);',
  );

  const fast = source.slice(
    source.indexOf("const FAST_ROOM_ACTIONS"),
    source.indexOf("function canUseFastRoomAction"),
  );
  assertEquals(fast.includes('"transfer_host"'), false);
  const preflight = source.slice(
    source.indexOf("const capturedActionBody"),
    source.indexOf("const mustQueueLiveActivityEndBeforeLeases"),
  );
  assertStringIncludes(preflight, 'if (action === "transfer_host")');
  assertStringIncludes(
    preflight,
    "lobbyHostTransferTransition(room, user, body)",
  );

  const execute = source.slice(
    source.indexOf("async function executeRoomAction("),
    source.indexOf("async function executeRoomActionWithSignal("),
  );
  assertStringIncludes(
    execute,
    'if (action !== "transfer_host") {\n      room = await refreshActorCapabilities',
  );
  const signals = source.slice(
    source.indexOf("async function executeRoomActionWithSignal("),
    source.indexOf("function isCommittedFinishedRoom"),
  );
  assertEquals(
    signals.includes('action === "transfer_host"'),
    false,
    "transfer must not close any participant signal",
  );
  assertStringIncludes(
    signals,
    'recipients: recipients || roomSignalRecipients(result, "active")',
  );

  const leased = source.slice(
    source.indexOf("result = await retryRoomMembershipChangeBeforeAction"),
  );
  assertStringIncludes(
    leased,
    "assertExactRoomLeaseCoverage(context, latestUserIDs)",
  );
  assertStringIncludes(leased, "executeRoomActionWithSignal(");
  assertStringIncludes(leased, "migratedRoom,");
});

import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("late ActivityKit registration stores an exact durable terminal probe", async () => {
  const source = await Deno.readTextFile(
    new URL("./device-registration.ts", import.meta.url),
  );
  const start = source.indexOf("export async function registerLiveActivity");
  const end = source.indexOf(
    "export async function unregisterInstallation",
    start,
  );
  const registration = source.slice(start, end);

  assertStringIncludes(registration, "TERMINAL_REGISTRATION_PROBE_MS");
  assertStringIncludes(
    registration,
    "terminal_probe_started_at: needsTerminalProbe",
  );
  assertStringIncludes(
    registration,
    "terminal_probe_until: terminalProbeUntil",
  );
  assertStringIncludes(
    registration,
    "delivery_state: preserveForceEnd || needsTerminalProbe",
  );
  assertStringIncludes(registration, "pending_force_end: preserveForceEnd");
  assertStringIncludes(registration, "committedRoomCloseReceipt({");
});

Deno.test("probe checks terminal receipts before resolving a later active commit", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const proofStart = source.indexOf("async function terminalRegistrationProof");
  const proofEnd = source.indexOf(
    "async function terminalProbeRegistration",
    proofStart,
  );
  const proof = source.slice(proofStart, proofEnd);
  assertStringIncludes(proof, "committedGameFinishReceipt({");
  assertStringIncludes(proof, "committedRoomCloseReceipt({");
  assertStringIncludes(proof, "roomCloseCommitReceiptID(matchID, intent.id)");
  assertStringIncludes(
    proof,
    "clean(room?.terminal_intent?.match_id) === matchID",
  );
  assertStringIncludes(proof, 'state: "pending_terminal", room');

  const resolveStart = source.indexOf(
    "async function resolveTerminalRegistrationProbe",
  );
  const resolveEnd = source.indexOf(
    "async function probeLiveActivityTerminal",
    resolveStart,
  );
  const resolve = source.slice(resolveStart, resolveEnd);
  assertStringIncludes(resolve, 'proof.state === "terminal"');
  assertStringIncludes(
    resolve,
    "proof = await terminalRegistrationProof(input.base44, current)",
  );
  assertStringIncludes(resolve, "queueLiveRetry({");
  assertStringIncludes(resolve, "probeUntilMS <= now.getTime()");
  assertStringIncludes(resolve, 'delivery_state: "retry"');
  assertStringIncludes(resolve, "retry_requested: true");
  assertStringIncludes(resolve, 'last_error_code: "terminal_probe_unresolved"');
  assertEquals(resolve.includes("claimLiveDelivery({"), false);
  assertEquals(resolve.includes("sendLiveActivity"), false);
});

Deno.test("prompt, sync, and scheduled drain all route probe rows through the marker-first worker", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  assertStringIncludes(source, '"probe_live_activity_terminal"');
  assertStringIncludes(source, "await deliverForcedLiveActivityEnd({");
  assertStringIncludes(source, "await triggerLiveActivityTerminalProbe(");
  assertStringIncludes(source, "catch_up: catchUp");
  assertStringIncludes(source, "terminal_probe_prompt_unconfirmed");
  assertStringIncludes(source, 'return "terminal_probe_pending"');
  assertStringIncludes(source, "await probeLiveActivityTerminal(base44, {");

  const closeSyncStart = source.indexOf("if (room.close_intent)");
  const closeSyncEnd = source.indexOf("const participantIDs", closeSyncStart);
  const closeSync = source.slice(closeSyncStart, closeSyncEnd);
  assertStringIncludes(closeSync, "await endRoomLiveActivities(base44, {");
  assertStringIncludes(
    closeSync,
    "terminal_commit_id: roomCloseCommitReceiptID(matchID, intent.id)",
  );

  const processStart = source.indexOf("const processRegistration = async");
  const processEnd = source.indexOf("const groupsByUser", processStart);
  const process = source.slice(processStart, processEnd);
  assertEquals(
    process.indexOf("terminal_probe_started_at") <
      process.indexOf("claimLiveDelivery({"),
    true,
  );

  const drainStart = source.indexOf("async function drainLiveActivityRetries");
  const drainEnd = source.indexOf(
    "async function reconcileIdleLiveActivityDrift",
    drainStart,
  );
  const drain = source.slice(drainStart, drainEnd);
  assertEquals(
    drain.indexOf("terminal_probe_started_at") <
      drain.indexOf("pending_force_end === true"),
    true,
  );
});

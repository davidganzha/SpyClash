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

Deno.test("gameRoomAction integrates lobby return and kick through CAS and participant leases", async () => {
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
  assertStringIncludes(kick, "lobbyKickTransition(latest, user.email, target)");
  assertStringIncludes(kick, "lobbyMembershipClampPatch(");
  assertStringIncludes(kick, "updateRoomWithRetry(");
  assertStringIncludes(kick, 'normalizedStatus(latest) === "waiting"');

  assertStringIncludes(source, 'case "vote_return_to_lobby":');
  assertStringIncludes(source, 'case "kick_player":');
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
  assertEquals(fastActions.includes('"vote_return_to_lobby"'), false);
  assertEquals(fastActions.includes('"kick_player"'), false);

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
  assertStringIncludes(signalPath, "transition.removedPlayer?.user_id");
  assertStringIncludes(signalPath, "additionalRecipientUserIDs,");

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

  const completeStart = source.slice(
    source.indexOf("async function completeGameStart"),
    source.indexOf("async function repairDetectedCommittedGameStart"),
  );
  assertStringIncludes(completeStart, 'status: "playing"');
  assertStringIncludes(completeStart, "ready_players: []");
});

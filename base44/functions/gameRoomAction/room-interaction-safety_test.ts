import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertLobbySettingsAccess,
  deleteRoomAndVerify,
  gameDurationPatch,
  gameModePatch,
  leaveAlreadyComplete,
  liveActivityEndQueueCoversRegistrations,
  liveActivityEndQueueMatchesRoom,
  loadActiveRoomLiveActivityRegistrations,
  roomHasGameDuration,
  roomHasGameMode,
  roomHasParticipantIdentity,
  validatedGameDuration,
  validatedGameMode,
} from "./room-interaction-safety.ts";

function status(error: unknown): number | undefined {
  return (error as Error & { status?: number }).status;
}

Deno.test("leave is complete when the room disappeared or the actor already left", () => {
  assertEquals(leaveAlreadyComplete(null, "host@example.com"), true);
  assertEquals(
    leaveAlreadyComplete({
      players: [{ email: "player@example.com" }],
    }, "host@example.com"),
    true,
  );
  assertEquals(
    leaveAlreadyComplete({
      players: [{ email: "host@example.com" }],
    }, "host@example.com"),
    false,
  );
});

Deno.test("Live Activity end proof is bound to the exact room match generation", () => {
  const matchA = { id: "room-1", match_id: "match-a" };
  const replayedMatchB = { id: "room-1", match_id: "match-b" };

  assertEquals(
    liveActivityEndQueueMatchesRoom(matchA, "room-1", "match-a"),
    true,
  );
  assertEquals(
    liveActivityEndQueueMatchesRoom(replayedMatchB, "room-1", "match-a"),
    false,
  );
  assertEquals(
    liveActivityEndQueueMatchesRoom(matchA, "another-room", "match-a"),
    false,
  );
  assertEquals(liveActivityEndQueueMatchesRoom(matchA, "room-1", ""), false);
});

Deno.test("room deletion refuses a late exact registration missing the force-end queue", () => {
  const room = { id: "room-1", match_id: "match-a" };
  const queued = {
    status: "active",
    token_kind: "activity",
    room_id: "room-1",
    match_id: "match-a",
    provider_match_id: "match-a",
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-a",
    delivery_state: "retry",
  };
  const lateRegistration = {
    ...queued,
    pending_force_end: false,
    pending_room_id: "",
    pending_match_id: "",
  };

  assertEquals(liveActivityEndQueueCoversRegistrations(room, [queued]), true);
  assertEquals(
    liveActivityEndQueueCoversRegistrations(room, [queued, lateRegistration]),
    false,
  );
  assertEquals(
    liveActivityEndQueueCoversRegistrations(room, [
      lateRegistration,
      { ...lateRegistration, match_id: "older-match" },
    ]),
    false,
  );
  assertEquals(
    liveActivityEndQueueCoversRegistrations(room, [{
      ...queued,
      delivery_state: "failed",
    }]),
    false,
  );
});

Deno.test("logical close coverage requires the exact committed close receipt", () => {
  const room = {
    id: "room-1",
    match_id: "match-a",
    close_intent: {
      id: "close-1",
      room_id: "room-1",
      match_id: "match-a",
    },
  };
  const queued = {
    status: "active",
    token_kind: "activity",
    room_id: "room-1",
    match_id: "match-a",
    provider_match_id: "match-a",
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-a",
    pending_force_end_commit_id: "room-close:match-a:close-1",
    delivery_state: "retry",
  };

  assertEquals(liveActivityEndQueueCoversRegistrations(room, [queued]), true);
  assertEquals(
    liveActivityEndQueueCoversRegistrations(room, [{
      ...queued,
      pending_force_end_commit_id: null,
    }]),
    false,
  );
});

Deno.test("Live Activity close coverage reads every page before accepting deletion", async () => {
  const queued = Array.from({ length: 100 }, (_, index) => ({
    id: `queued-${index}`,
    status: "active",
    token_kind: "activity",
    room_id: "room-1",
    match_id: "match-a",
    provider_match_id: "match-a",
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-a",
    delivery_state: "retry",
  }));
  const rows = [
    ...queued,
    {
      ...queued[0],
      id: "late-page-two",
      pending_force_end: false,
      delivery_state: "idle",
    },
  ];
  const skips: number[] = [];
  const loaded = await loadActiveRoomLiveActivityRegistrations({
    filter: async (_query, _sort, limit, skip) => {
      skips.push(skip);
      return rows.slice(skip, skip + limit);
    },
  }, "room-1");

  assertEquals(skips, [0, 100]);
  assertEquals(loaded.length, 101);
  assertEquals(
    liveActivityEndQueueCoversRegistrations(
      { id: "room-1", match_id: "match-a" },
      loaded,
    ),
    false,
  );
});

Deno.test("join verification trusts the persisted player identity even when the lookup mirror is absent", () => {
  const user = { id: "user-2", email: "player@example.com" };
  const room = {
    players: [
      { user_id: "user-1", email: "host@example.com" },
      { user_id: "user-2", email: "player@example.com" },
    ],
  };

  assertEquals(roomHasParticipantIdentity(room, user), true);
  assertEquals(
    roomHasParticipantIdentity(room, {
      id: "attacker-id",
      email: "player@example.com",
    }),
    false,
  );
  assertEquals(
    roomHasParticipantIdentity(room, {
      id: "user-2",
      email: "attacker@example.com",
    }),
    false,
  );
});

Deno.test("only the host may change waiting-lobby settings", () => {
  assertLobbySettingsAccess(
    { host_email: "host@example.com", status: "waiting" },
    { email: "host@example.com" },
    "mode",
  );
  const nonHost = assertThrows(
    () =>
      assertLobbySettingsAccess(
        { host_email: "host@example.com", status: "waiting" },
        { email: "player@example.com" },
        "mode",
      ),
    Error,
    "Host access required",
  );
  assertEquals(status(nonHost), 403);

  for (const setting of ["mode", "duration", "lobby"] as const) {
    const activeGame = assertThrows(
      () =>
        assertLobbySettingsAccess(
          { host_email: "host@example.com", status: "playing" },
          { email: "host@example.com" },
          setting,
        ),
      Error,
    );
    assertEquals(status(activeGame), 409);
  }
});

Deno.test("game mode accepts the two supported modes and makes same-value retries no-ops", () => {
  for (const mode of ["questions", "associations"] as const) {
    assertEquals(validatedGameMode(mode), mode);
    assertEquals(gameModePatch({ game_mode: mode }, mode), {});
    assertEquals(roomHasGameMode({ game_mode: mode }, mode), true);
  }
  assertEquals(
    gameModePatch({ game_mode: "questions" }, "associations"),
    { game_mode: "associations" },
  );
  const error = assertThrows(() => validatedGameMode("roulette"), Error);
  assertEquals(status(error), 400);
});

Deno.test("duration accepts 60 through 900 whole seconds and makes same-value retries no-ops", () => {
  for (const duration of [60, 900]) {
    assertEquals(validatedGameDuration(duration), duration);
    assertEquals(
      gameDurationPatch({ game_duration_seconds: duration }, duration),
      {},
    );
    assertEquals(
      roomHasGameDuration({ game_duration_seconds: duration }, duration),
      true,
    );
  }
  assertEquals(
    gameDurationPatch({ game_duration_seconds: 60 }, 120),
    { game_duration_seconds: 120 },
  );
  for (const invalid of [59, 901, 60.5]) {
    const error = assertThrows(() => validatedGameDuration(invalid), Error);
    assertEquals(status(error), 400);
  }
});

Deno.test("delete verification retries reads but never repeats deletion", async () => {
  let deleteCount = 0;
  let readCount = 0;
  let closedFanoutCount = 0;
  const waits: number[] = [];
  await deleteRoomAndVerify({
    roomID: "room-1",
    deleteByID: async () => {
      deleteCount += 1;
    },
    fetchByID: async () => ++readCount < 6 ? { id: "room-1" } : null,
    afterVerifiedDelete: async () => {
      closedFanoutCount += 1;
    },
    delay: async (milliseconds) => {
      waits.push(milliseconds);
    },
  });
  assertEquals(deleteCount, 1);
  assertEquals(readCount, 6);
  assertEquals(closedFanoutCount, 1);
  assertEquals(waits, [20, 55, 90, 125, 160]);
});

Deno.test("delete verification returns a typed 409 only after bounded reads", async () => {
  let deleteCount = 0;
  let closedFanoutCount = 0;
  const error = await assertRejects(
    () =>
      deleteRoomAndVerify({
        roomID: "room-1",
        deleteByID: async () => {
          deleteCount += 1;
        },
        fetchByID: async () => ({ id: "room-1" }),
        afterVerifiedDelete: async () => {
          closedFanoutCount += 1;
        },
        delay: async () => {},
      }),
    Error,
    "could not be deleted",
  );
  assertEquals(deleteCount, 1);
  assertEquals(closedFanoutCount, 0);
  assertEquals(status(error), 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_delete_unverified",
  );
});

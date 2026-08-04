import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertLobbySettingsAccess,
  deleteRoomAndVerify,
  gameDurationPatch,
  gameModePatch,
  leaveAlreadyComplete,
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
  const waits: number[] = [];
  await deleteRoomAndVerify({
    roomID: "room-1",
    deleteByID: async () => {
      deleteCount += 1;
    },
    fetchByID: async () => ++readCount < 6 ? { id: "room-1" } : null,
    delay: async (milliseconds) => {
      waits.push(milliseconds);
    },
  });
  assertEquals(deleteCount, 1);
  assertEquals(readCount, 6);
  assertEquals(waits, [20, 55, 90, 125, 160]);
});

Deno.test("delete verification returns a typed 409 only after bounded reads", async () => {
  let deleteCount = 0;
  const error = await assertRejects(
    () =>
      deleteRoomAndVerify({
        roomID: "room-1",
        deleteByID: async () => {
          deleteCount += 1;
        },
        fetchByID: async () => ({ id: "room-1" }),
        delay: async () => {},
      }),
    Error,
    "could not be deleted",
  );
  assertEquals(deleteCount, 1);
  assertEquals(status(error), 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_delete_unverified",
  );
});

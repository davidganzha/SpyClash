import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertRankedTerminalRoom,
  buildTerminalIntent,
  deriveExpiredGameWinner,
  historyRecordsForMatch,
  rejectRetiredResultRecording,
  roleCardReadTransitionPatch,
  terminalIntentFromRoom,
} from "./room-result-policy.ts";

function startedRoom(overrides: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    code: "ABC123",
    status: "playing",
    players: [
      { user_id: "user-a", email: "a@example.com" },
      { user_id: "user-b", email: "b@example.com" },
      { user_id: "user-c", email: "c@example.com" },
    ],
    participant_user_ids: ["user-a", "user-b", "user-c"],
    spy_email: "b@example.com",
    word: "Embassy",
    game_started_at: "2026-07-14T12:00:00.000Z",
    game_duration_seconds: 60,
    match_id: "match-1",
    ...overrides,
  };
}

Deno.test("create-room to finish-room leaderboard farming is rejected", () => {
  const forged = startedRoom({
    players: [{ user_id: "attacker", email: "attacker@example.com" }],
    participant_user_ids: ["attacker"],
    spy_email: "attacker@example.com",
  });
  const error = assertThrows(
    () => deriveExpiredGameWinner(forged, Date.parse("2026-07-14T13:00:00Z")),
    Error,
    "at least three distinct",
  );
  assertEquals((error as Error & { status?: number }).status, 409);
});

Deno.test("finish-room ignores claimed winner and derives elapsed timeout", () => {
  const room = startedRoom();
  assertThrows(
    () => deriveExpiredGameWinner(room, Date.parse("2026-07-14T12:01:29Z")),
    Error,
    "deadline has not elapsed",
  );
  assertEquals(
    deriveExpiredGameWinner(room, Date.parse("2026-07-14T12:01:30Z")),
    "detectives",
  );
  assertRankedTerminalRoom(
    { ...room, status: "finished", winner: "detectives" },
    "detectives",
  );
});

Deno.test("duplicate or unauthenticated participants cannot be ranked", () => {
  const duplicate = startedRoom({
    players: [
      { user_id: "user-a", email: "a@example.com" },
      { user_id: "user-a", email: "copy@example.com" },
      { user_id: "user-c", email: "c@example.com" },
    ],
    participant_user_ids: ["user-a", "user-c"],
  });
  assertThrows(
    () =>
      assertRankedTerminalRoom(
        { ...duplicate, status: "finished", winner: "detectives" },
        "detectives",
      ),
    Error,
    "three distinct authenticated participants",
  );
});

Deno.test("generic client result replay endpoint is retired", () => {
  const error = assertThrows(
    () => rejectRetiredResultRecording(),
    Error,
    "result recording is retired",
  );
  assertEquals((error as Error & { status?: number }).status, 410);
  assertEquals(
    (error as Error & { code?: string }).code,
    "result_recording_retired",
  );
});

Deno.test("two replays in one room retain separate match histories", () => {
  const first = startedRoom({ match_id: "match-a" });
  const second = startedRoom({ match_id: "match-b" });
  const records = [
    {
      match_id: "match-a",
      room_code: "ABC123",
      player_user_id: "user-a",
    },
    {
      match_id: "match-b",
      room_code: "ABC123",
      player_user_id: "user-a",
    },
  ];

  assertEquals(historyRecordsForMatch(records, first), [records[0]]);
  assertEquals(historyRecordsForMatch(records, second), [records[1]]);
});

Deno.test("legacy in-flight match retry uses its deterministic fallback id", () => {
  const legacy = startedRoom({ match_id: "" });
  const records = [
    { room_code: "ABC123", player_user_id: "user-a" },
    {
      match_id: "legacy:room-1:2026-07-14T12:00:00.000Z",
      room_code: "ABC123",
      player_user_id: "user-a",
    },
  ];
  assertEquals(historyRecordsForMatch(records, legacy), [records[1]]);
});

Deno.test("role-card timer is written once on the completing transition", () => {
  const room = startedRoom({
    cards_read: ["a@example.com", "b@example.com"],
    game_started_at: null,
  });
  const first = roleCardReadTransitionPatch(
    room,
    "c@example.com",
    "2026-07-14T12:05:00.000Z",
  );
  assertEquals(first, {
    cards_read: ["a@example.com", "b@example.com", "c@example.com"],
    ready_players: [],
    game_started_at: "2026-07-14T12:05:00.000Z",
    game_duration_seconds: 60,
  });

  const completed = { ...room, ...first };
  assertEquals(
    roleCardReadTransitionPatch(
      completed,
      "c@example.com",
      "2026-07-14T12:30:00.000Z",
    ),
    {},
  );
  assertEquals(completed.game_started_at, "2026-07-14T12:05:00.000Z");
});

Deno.test("terminal intent pins the first winner and terminal payload", () => {
  const room = startedRoom();
  const intent = buildTerminalIntent(
    room,
    "spy",
    { spy_guess: "Embassy" },
    "2026-07-14T12:01:00.000Z",
  );
  const persisted = terminalIntentFromRoom({
    ...room,
    terminal_intent: intent,
  });
  assertEquals(persisted, intent);
  assertEquals(persisted?.winner, "spy");
  assertEquals(persisted?.spy_guess, "Embassy");
});

import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertIntroCompletionAccess,
  assertRankedTerminalRoom,
  assertServerRankedFinishSource,
  buildTerminalIntent,
  deriveExpiredGameWinner,
  historyRecordsForMatch,
  introStartedAtForCompletion,
  ONLINE_GAME_INTRO_SECONDS,
  preTimerMembershipTransitionPatch,
  rejectRetiredResultRecording,
  roleCardReadTransitionPatch,
  serverIntroStartPatch,
  terminalIntentFromRoom,
} from "./room-result-policy.ts";
import { resolvedDetectiveVoteCastTransition } from "./detective-vote-policy.ts";

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
    game_paused_at: null,
    game_paused_total_seconds: 0,
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

Deno.test("0:00 immediately derives the spy winner from server time", () => {
  const room = startedRoom();
  assertThrows(
    () =>
      deriveExpiredGameWinner(
        room,
        Date.parse("2026-07-14T12:00:59.999Z"),
      ),
    Error,
    "deadline has not elapsed",
  );
  assertEquals(
    deriveExpiredGameWinner(room, Date.parse("2026-07-14T12:01:00.000Z")),
    "spy",
  );
  assertRankedTerminalRoom(
    { ...room, status: "finished", winner: "spy" },
    "spy",
  );
});

Deno.test("three-player innocent ejection persists a recoverable spy terminal in one CAS", () => {
  const room: Record<string, any> = startedRoom({
    vote_requests: ["a@example.com", "b@example.com"],
    detective_votes: [{
      voter_email: "b@example.com",
      voted_for_email: "a@example.com",
    }],
    spectators: [],
    eliminated_emails: [],
  });
  const resolution = resolvedDetectiveVoteCastTransition(
    room.players.map((player: { email: string }) => player.email),
    room.vote_requests,
    room.detective_votes,
    "c@example.com",
    "a@example.com",
    room.spy_email,
    room.spectators,
    room.eliminated_emails,
  );
  assertEquals(resolution.terminal_winner, "spy");
  const postEjectionRoom = { ...room, ...resolution.patch };
  assertServerRankedFinishSource(postEjectionRoom);
  const intent = buildTerminalIntent(
    postEjectionRoom,
    resolution.terminal_winner,
    resolution.terminal_patch,
    "2026-07-14T12:00:20.000Z",
  );
  const committed = { ...postEjectionRoom, terminal_intent: intent };

  assertEquals(committed.spectators, ["a@example.com"]);
  assertEquals(committed.eliminated_emails, ["a@example.com"]);
  assertEquals(committed.detective_votes, []);
  assertEquals(committed.vote_requests, []);
  assertEquals(terminalIntentFromRoom(committed)?.winner, "spy");

  // A process may fail after the atomic CAS. Reconciliation of its persisted
  // intent still produces a valid finished spy result with no second ejection.
  assertRankedTerminalRoom(
    { ...committed, status: "finished", winner: intent.winner },
    intent.winner,
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
    game_paused_at: null,
    game_paused_total_seconds: 0,
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

Deno.test("duplicate role acknowledgement repairs all-read pre-timer state", () => {
  const room = startedRoom({
    cards_read: ["a@example.com", "b@example.com", "c@example.com"],
    game_started_at: null,
  });
  assertEquals(
    roleCardReadTransitionPatch(
      room,
      "c@example.com",
      "2026-07-14T12:05:00.000Z",
    ),
    {
      ready_players: [],
      game_started_at: "2026-07-14T12:05:00.000Z",
      game_duration_seconds: 60,
      game_paused_at: null,
      game_paused_total_seconds: 0,
    },
  );
});

Deno.test("server intro timestamp gates participant takeover at eight seconds", () => {
  const room = startedRoom({
    status: "roulette",
    host_email: "a@example.com",
    intro_started_at: "2026-07-14T12:00:00.000Z",
    game_started_at: null,
  });
  assertEquals(ONLINE_GAME_INTRO_SECONDS, 8);
  const eagerHost = assertThrows(
    () =>
      assertIntroCompletionAccess(
        room,
        "A@EXAMPLE.COM",
        Date.parse("2026-07-14T12:00:00.100Z"),
      ),
    Error,
    "still in progress",
  );
  assertEquals(
    (eagerHost as Error & { code?: string }).code,
    "game_intro_in_progress",
  );

  const tooEarly = assertThrows(
    () =>
      assertIntroCompletionAccess(
        room,
        "c@example.com",
        Date.parse("2026-07-14T12:00:07.999Z"),
      ),
    Error,
    "still in progress",
  );
  assertEquals(
    (tooEarly as Error & { code?: string }).code,
    "game_intro_in_progress",
  );
  assertEquals(
    assertIntroCompletionAccess(
      room,
      "c@example.com",
      Date.parse("2026-07-14T12:00:08.000Z"),
    ),
    undefined,
  );
  assertEquals(
    assertIntroCompletionAccess(
      room,
      "a@example.com",
      Date.parse("2026-07-14T12:00:08.000Z"),
    ),
    undefined,
  );

  const outsider = assertThrows(
    () =>
      assertIntroCompletionAccess(
        room,
        "outsider@example.com",
        Date.parse("2026-07-14T12:01:00.000Z"),
      ),
    Error,
    "Not a player",
  );
  assertEquals((outsider as Error & { status?: number }).status, 403);

  const invalidTimestamp = assertThrows(
    () =>
      assertIntroCompletionAccess(
        { ...room, intro_started_at: "not-a-date" },
        "a@example.com",
        Date.parse("2026-07-14T12:01:00.000Z"),
      ),
    Error,
    "timestamp is invalid",
  );
  assertEquals(
    (invalidTimestamp as Error & { code?: string }).code,
    "invalid_game_intro",
  );
});

Deno.test("intro start is server-owned and preserved by completion", () => {
  const patch = serverIntroStartPatch("2026-07-14T12:00:00.000Z");
  assertEquals(patch, {
    intro_started_at: "2026-07-14T12:00:00.000Z",
  });
  assertEquals(
    introStartedAtForCompletion(
      { intro_started_at: patch.intro_started_at },
      "2026-07-14T13:00:00.000Z",
    ),
    "2026-07-14T12:00:00.000Z",
  );
});

Deno.test("paused time extends ranked expiry and an active pause freezes it", () => {
  const resumed = startedRoom({ game_paused_total_seconds: 30 });
  assertThrows(
    () =>
      deriveExpiredGameWinner(
        resumed,
        Date.parse("2026-07-14T12:01:29.999Z"),
      ),
    Error,
    "deadline has not elapsed",
  );
  assertEquals(
    deriveExpiredGameWinner(
      resumed,
      Date.parse("2026-07-14T12:01:30.000Z"),
    ),
    "spy",
  );

  const paused = startedRoom({
    game_paused_at: "2026-07-14T12:00:20.000Z",
  });
  assertThrows(
    () =>
      deriveExpiredGameWinner(
        paused,
        Date.parse("2026-07-14T14:00:00.000Z"),
      ),
    Error,
    "deadline has not elapsed",
  );
});

Deno.test("legacy started room without pause fields remains unpaused", () => {
  const {
    game_paused_at: _pausedAt,
    game_paused_total_seconds: _pausedTotal,
    ...legacy
  } = startedRoom();
  assertEquals(
    deriveExpiredGameWinner(
      legacy,
      Date.parse("2026-07-14T12:01:00.000Z"),
    ),
    "spy",
  );
});

Deno.test("valid reveal leave starts timer once when all remaining cards are read", () => {
  const room = startedRoom({
    game_started_at: null,
    intro_started_at: "2026-07-14T11:59:50.000Z",
    cards_read: ["a@example.com", "b@example.com", "c@example.com"],
    ready_players: ["a@example.com"],
    current_asker_email: "departed@example.com",
    current_answerer_email: "b@example.com",
    roulette_target_email: "departed@example.com",
  });
  const first = preTimerMembershipTransitionPatch(
    room,
    "2026-07-14T12:05:00.000Z",
  );
  assertEquals(first, {
    current_asker_email: "a@example.com",
    roulette_target_email: "a@example.com",
    cards_read: ["a@example.com", "b@example.com", "c@example.com"],
    ready_players: [],
    game_started_at: "2026-07-14T12:05:00.000Z",
    game_paused_at: null,
    game_paused_total_seconds: 0,
  });
  assertEquals(
    preTimerMembershipTransitionPatch(
      { ...room, ...first },
      "2026-07-14T13:00:00.000Z",
    ),
    {},
  );
});

Deno.test("reveal leave keeps a valid table waiting for unread cards", () => {
  const room = startedRoom({
    game_started_at: null,
    cards_read: ["a@example.com", "b@example.com"],
    current_asker_email: "a@example.com",
    current_answerer_email: "b@example.com",
    roulette_target_email: "a@example.com",
  });
  assertEquals(preTimerMembershipTransitionPatch(room), {});

  const finalAck = roleCardReadTransitionPatch(
    room,
    "c@example.com",
    "2026-07-14T12:06:00.000Z",
  );
  assertEquals(finalAck.game_started_at, "2026-07-14T12:06:00.000Z");
});

Deno.test("pre-timer membership removes stale card acknowledgements", () => {
  const room = startedRoom({
    game_started_at: null,
    cards_read: [
      "a@example.com",
      "departed@example.com",
      "b@example.com",
    ],
    current_asker_email: "a@example.com",
    current_answerer_email: "b@example.com",
    roulette_target_email: "a@example.com",
  });
  assertEquals(preTimerMembershipTransitionPatch(room), {
    cards_read: ["a@example.com", "b@example.com"],
  });
});

Deno.test("roulette leave repairs a valid plan without starting the timer", () => {
  const room = startedRoom({
    status: "roulette",
    game_started_at: null,
    intro_started_at: "2026-07-14T12:00:00.000Z",
    cards_read: [],
    current_asker_email: "departed@example.com",
    current_answerer_email: "b@example.com",
    roulette_target_email: "departed@example.com",
  });
  const patch = preTimerMembershipTransitionPatch(room);
  assertEquals(patch, {
    current_asker_email: "a@example.com",
    roulette_target_email: "a@example.com",
  });
  assertEquals("game_started_at" in patch, false);
});

Deno.test("invalid reveal membership fails closed without a false timer", () => {
  for (
    const room of [
      startedRoom({
        game_started_at: null,
        spy_email: "departed@example.com",
        cards_read: ["a@example.com", "b@example.com", "c@example.com"],
      }),
      startedRoom({
        game_started_at: null,
        players: [
          { user_id: "user-a", email: "a@example.com" },
          { user_id: "user-b", email: "b@example.com" },
        ],
        participant_user_ids: ["user-a", "user-b"],
      }),
    ]
  ) {
    const patch = preTimerMembershipTransitionPatch(
      room,
      "2026-07-14T12:05:00.000Z",
    );
    assertEquals(patch.status, "waiting");
    assertEquals(patch.match_id, "");
    assertEquals(patch.spy_email, "");
    assertEquals(patch.word, "");
    assertEquals(patch.intro_started_at, null);
    assertEquals(patch.game_started_at, null);
    assertEquals(patch.game_paused_at, null);
    assertEquals(patch.game_paused_total_seconds, 0);
  }
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

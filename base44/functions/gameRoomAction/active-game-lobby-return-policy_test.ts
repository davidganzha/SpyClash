import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  activeGameLobbyEligiblePlayerEmails,
  activeGameLobbyResetPatch,
  activeGameLobbyReturnCanUseFastPath,
  activeGameLobbyReturnTransition,
} from "./active-game-lobby-return-policy.ts";

function player(index: number) {
  return {
    user_id: `user-${index}`,
    email: `p${index}@example.com`,
    name: `Player ${index}`,
  };
}

function activeRoom(
  overrides: Record<string, unknown> = {},
): Record<string, any> {
  return {
    id: "room-1",
    code: "RETURN",
    host_email: "p1@example.com",
    status: "playing",
    players: [player(1), player(2), player(3)],
    participant_user_ids: ["user-1", "user-2", "user-3"],
    departed_player_emails: [],
    ready_players: [],
    lobby_schema_version: 2,
    lobby_revision: 9,
    lobby_spy_count: 1,
    spies_know_each_other: false,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-9",
    lobby_source_name: "Night pack",
    lobby_theme: "Night cities",
    lobby_category: "Places",
    lobby_word_count: 3,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "kyiv", word: "Kyiv", enabled: true },
      { id: "london", word: "London", enabled: true },
      { id: "tokyo", word: "Tokyo", enabled: false },
    ],
    lobby_last_mutation_id: "mutation-9",
    lobby_last_mutation_fingerprint: "fingerprint-9",
    game_mode: "associations",
    game_duration_seconds: 600,
    spy_email: "p2@example.com",
    spy_emails: ["p2@example.com"],
    revealed_spy_emails: ["p2@example.com"],
    secret_word: "Kyiv",
    word: "Kyiv",
    category: "Places",
    spy_guess: "London",
    detective_votes: [{
      voter_email: "p1@example.com",
      voted_for_email: "p2@example.com",
    }],
    detective_vote_round_id: "vote-round-1",
    detective_vote_cancellation_event_id: "cancel-1",
    detective_vote_cancellation_round_id: "vote-round-1",
    detective_vote_cancellation_present_at: "2026-09-01T00:00:00.000Z",
    detective_vote_cancellation_reason: "no_viable_candidate",
    winner: "spy",
    cards_read: ["p1@example.com", "p2@example.com"],
    vote_requests: ["p1@example.com", "p3@example.com"],
    spectators: ["p3@example.com"],
    eliminated_emails: ["p3@example.com"],
    question_phase: "answering",
    questions_in_round: 4,
    round_number: 2,
    current_answer: "answer",
    current_answer_feedback: "like",
    current_asker_email: "p1@example.com",
    current_answerer_email: "p3@example.com",
    roulette_target_email: "p2@example.com",
    player_feedback: [{ email: "p1@example.com", likes: 2 }],
    word_pool: [{ word: "Kyiv", enabled: true }],
    match_id: "match-1",
    terminal_intent: { winner: "spy" },
    intro_started_at: "2026-09-01T00:00:00.000Z",
    game_started_at: "2026-09-01T00:00:05.000Z",
    game_paused_at: "2026-09-01T00:01:00.000Z",
    game_paused_total_seconds: 10,
    game_started_event_id: "started-1",
    game_finished_event_id: "finished-1",
    countdown_started_at: "2026-09-01T00:02:00.000Z",
    ...overrides,
  };
}

function errorDetails(error: unknown) {
  return error as Error & { status?: number; code?: string };
}

Deno.test("eligible emails use the canonical non-departed roster", () => {
  assertEquals(
    activeGameLobbyEligiblePlayerEmails(activeRoom({
      players: [
        player(1),
        { ...player(1), email: "alias@example.com" },
        { user_id: "user-2", email: " P2@EXAMPLE.COM " },
        { email: "p2@example.com" },
        player(3),
        { user_id: "missing-email" },
      ],
      departed_player_emails: [" p3@example.com ", "P3@EXAMPLE.COM"],
    })),
    ["p1@example.com", "P2@EXAMPLE.COM"],
  );
});

Deno.test("only a current non-departed player may vote", () => {
  const outsider = errorDetails(
    assertThrows(() =>
      activeGameLobbyReturnTransition(
        activeRoom(),
        "outsider@example.com",
        true,
      )
    ),
  );
  assertEquals(outsider.status, 403);
  assertEquals(outsider.code, "return_to_lobby_not_player");

  const departed = errorDetails(
    assertThrows(() =>
      activeGameLobbyReturnTransition(
        activeRoom({ departed_player_emails: [" P2@EXAMPLE.COM "] }),
        "p2@example.com",
        true,
      )
    ),
  );
  assertEquals(departed.status, 403);
  assertEquals(departed.code, "return_to_lobby_not_player");
});

Deno.test("return voting is limited to started playing rooms", () => {
  for (
    const status of [
      "waiting",
      "ready_voting",
      "roulette",
      "finished",
      "unknown",
    ]
  ) {
    const error = errorDetails(
      assertThrows(() =>
        activeGameLobbyReturnTransition(
          activeRoom({ status }),
          "p1@example.com",
          true,
        )
      ),
    );
    assertEquals(error.status, 409);
    assertEquals(error.code, "return_to_lobby_vote_inactive");
  }

  assertEquals(
    activeGameLobbyReturnTransition(
      activeRoom({ status: " PLAYING " }),
      "p1@example.com",
      true,
    ).patch,
    { ready_players: ["p1@example.com"] },
  );
});

Deno.test("vote intent must be an explicit boolean", () => {
  for (const value of [1, "true", null, undefined]) {
    const error = errorDetails(
      assertThrows(() =>
        activeGameLobbyReturnTransition(activeRoom(), "p1@example.com", value)
      ),
    );
    assertEquals(error.status, 400);
    assertEquals(error.code, "return_to_lobby_vote_invalid");
  }
});

Deno.test("repeat and cancellation converge idempotently", () => {
  const room = activeRoom();
  const first = activeGameLobbyReturnTransition(room, "p1@example.com", true);
  assertEquals(first.patch, { ready_players: ["p1@example.com"] });
  const voted = { ...room, ...first.patch };
  assertEquals(
    activeGameLobbyReturnTransition(voted, " P1@EXAMPLE.COM ", true).patch,
    {},
  );

  const cancellation = activeGameLobbyReturnTransition(
    voted,
    "p1@example.com",
    false,
  );
  assertEquals(cancellation.patch, { ready_players: [] });
  const cancelled = { ...voted, ...cancellation.patch };
  assertEquals(
    activeGameLobbyReturnTransition(cancelled, "p1@example.com", false).patch,
    {},
  );
});

Deno.test("votes are canonicalized, deduplicated, and restricted to the current roster", () => {
  const transition = activeGameLobbyReturnTransition(
    activeRoom({
      ready_players: [
        " P1@EXAMPLE.COM ",
        "p1@example.com",
        "departed@example.com",
      ],
    }),
    "p1@example.com",
    true,
  );
  assertEquals(transition.didReset, false);
  assertEquals(transition.votes, ["p1@example.com"]);
  assertEquals(transition.patch, { ready_players: ["p1@example.com"] });
});

Deno.test("cancelling a vote prevents a premature reset", () => {
  const transition = activeGameLobbyReturnTransition(
    activeRoom({ ready_players: ["p1@example.com", "p2@example.com"] }),
    "p2@example.com",
    false,
  );
  assertEquals(transition.didReset, false);
  assertEquals(transition.requiredVotes, 3);
  assertEquals(transition.patch, { ready_players: ["p1@example.com"] });
});

Deno.test("only a non-resetting return vote qualifies for the fast CAS path", () => {
  assertEquals(
    activeGameLobbyReturnCanUseFastPath(
      activeRoom(),
      "p1@example.com",
      true,
    ),
    true,
  );
  assertEquals(
    activeGameLobbyReturnCanUseFastPath(
      activeRoom({ ready_players: ["p1@example.com"] }),
      "p1@example.com",
      false,
    ),
    true,
  );
  assertEquals(
    activeGameLobbyReturnCanUseFastPath(
      activeRoom({ ready_players: ["p1@example.com", "p2@example.com"] }),
      "p3@example.com",
      true,
    ),
    false,
  );
});

Deno.test("the last current-player vote atomically resets gameplay and preserves the authoritative lobby", () => {
  const room = activeRoom({
    ready_players: ["p1@example.com", "p2@example.com"],
  });
  const transition = activeGameLobbyReturnTransition(
    room,
    " P3@EXAMPLE.COM ",
    true,
  );
  assertEquals(transition.didReset, true);
  assertEquals(transition.requiredVotes, 3);
  assertEquals(transition.votes, [
    "p1@example.com",
    "p2@example.com",
    "p3@example.com",
  ]);

  const reset = { ...room, ...transition.patch };
  assertEquals(reset.status, "waiting");
  assertEquals(reset.ready_players, []);
  assertEquals(reset.winner, "");
  assertEquals(reset.match_id, "");
  assertEquals(reset.terminal_intent, null);
  assertEquals(reset.spy_email, "");
  assertEquals(reset.spy_emails, []);
  assertEquals(reset.secret_word, "");
  assertEquals(reset.detective_votes, []);
  assertEquals(reset.vote_requests, []);
  assertEquals(reset.cards_read, []);
  assertEquals(reset.game_started_at, null);
  assertEquals(reset.game_paused_at, null);
  assertEquals(reset.game_paused_total_seconds, 0);
  assertEquals(reset.game_started_event_id, "");
  assertEquals(reset.game_finished_event_id, "");
  assertEquals(reset.countdown_started_at, null);
  assertEquals("game_history" in transition.patch, false);

  for (
    const key of [
      "lobby_schema_version",
      "lobby_revision",
      "lobby_spy_count",
      "spies_know_each_other",
      "lobby_word_source",
      "lobby_source_pack_id",
      "lobby_source_name",
      "lobby_theme",
      "lobby_category",
      "lobby_word_count",
      "lobby_word_count_mode",
      "lobby_word_pool",
      "lobby_last_mutation_id",
      "lobby_last_mutation_fingerprint",
      "game_mode",
      "game_duration_seconds",
    ]
  ) {
    assertEquals(reset[key], room[key], `${key} must survive the reset`);
    assertEquals(
      key in transition.patch,
      false,
      `${key} must not be rewritten`,
    );
  }
});

Deno.test("departed and duplicate roster entries do not count toward unanimity or return to waiting", () => {
  const room = activeRoom({
    host_email: "p3@example.com",
    players: [
      player(1),
      player(2),
      { ...player(2), email: "alias@example.com", name: "Duplicate" },
      player(3),
    ],
    participant_user_ids: ["user-1", "user-2", "user-2", "user-3"],
    departed_player_emails: [" P3@EXAMPLE.COM ", "p3@example.com"],
    ready_players: ["p1@example.com"],
  });
  const transition = activeGameLobbyReturnTransition(
    room,
    "p2@example.com",
    true,
  );
  assertEquals(transition.didReset, true);
  assertEquals(transition.requiredVotes, 2);
  assertEquals(transition.patch.players, [player(1), player(2)]);
  assertEquals(transition.patch.participant_user_ids, ["user-1", "user-2"]);
  assertEquals(transition.patch.host_email, "p1@example.com");
  assertEquals(transition.patch.departed_player_emails, []);
});

Deno.test("reset policy fails closed when no non-departed player remains", () => {
  const error = errorDetails(
    assertThrows(() =>
      activeGameLobbyResetPatch(activeRoom({
        departed_player_emails: [
          "p1@example.com",
          "p2@example.com",
          "p3@example.com",
        ],
      }))
    ),
  );
  assertEquals(error.status, 409);
  assertEquals(error.code, "return_to_lobby_no_players");
});

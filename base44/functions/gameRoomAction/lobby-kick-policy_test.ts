import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { lobbyKickTransition } from "./lobby-kick-policy.ts";

function player(index: number) {
  return {
    user_id: `user-${index}`,
    email: `p${index}@example.com`,
    name: `Player ${index}`,
  };
}

function lobbyRoom(
  overrides: Record<string, unknown> = {},
): Record<string, any> {
  return {
    id: "room-1",
    code: "KICK20",
    host_email: "p1@example.com",
    status: "ready_voting",
    players: [player(1), player(2), player(3), player(4)],
    participant_user_ids: [
      "user-1",
      "user-2",
      "user-3",
      "user-4",
      "user-2",
      "stale-user",
    ],
    ready_players: ["p1@example.com", "p2@example.com", "p3@example.com"],
    spectators: [" P2@EXAMPLE.COM ", "p3@example.com", "P3@example.com"],
    cards_read: ["p2@example.com", "p4@example.com"],
    eliminated_emails: ["p2@example.com", "p3@example.com"],
    departed_player_emails: ["p2@example.com", "former@example.com"],
    incompatible_player_emails: ["p2@example.com", "legacy@example.com"],
    spy_email: "p2@example.com",
    spy_emails: ["p2@example.com", "p3@example.com"],
    revealed_spy_emails: ["p2@example.com"],
    vote_requests: ["p1@example.com", "p2@example.com"],
    detective_votes: [
      { voter_email: "p1@example.com", voted_for_email: "p2@example.com" },
      { voter_email: "p2@example.com", voted_for_email: "p3@example.com" },
    ],
    detective_vote_round_id: "vote-round-1",
    detective_vote_cancellation_event_id: "cancel-1",
    detective_vote_cancellation_round_id: "vote-round-1",
    detective_vote_cancellation_present_at: "2026-09-01T00:00:00.000Z",
    detective_vote_cancellation_reason: "no_viable_candidate",
    player_feedback: [
      { email: "p2@example.com", likes: 1 },
      { email: "p3@example.com", likes: 2 },
    ],
    current_asker_email: "p2@example.com",
    current_answerer_email: "p3@example.com",
    roulette_target_email: "p2@example.com",
    lobby_schema_version: 2,
    lobby_revision: 7,
    lobby_spy_count: 2,
    spies_know_each_other: true,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-7",
    lobby_source_name: "City pack",
    lobby_theme: "Night cities",
    lobby_category: "Places",
    lobby_word_count: 3,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "kyiv", word: "Kyiv", enabled: true },
      { id: "london", word: "London", enabled: true },
      { id: "tokyo", word: "Tokyo", enabled: false },
    ],
    lobby_last_mutation_id: "mutation-7",
    lobby_last_mutation_fingerprint: "fingerprint-7",
    game_mode: "questions",
    game_duration_seconds: 600,
    ...overrides,
  };
}

function errorDetails(error: unknown) {
  return error as Error & { status?: number; code?: string };
}

Deno.test("kick is host-only with canonical email comparison", () => {
  const error = errorDetails(assertThrows(() =>
    lobbyKickTransition(
      lobbyRoom(),
      "p3@example.com",
      { target_user_id: "user-2" },
    )
  ));
  assertEquals(error.status, 403);
  assertEquals(error.code, "kick_host_required");

  const transition = lobbyKickTransition(
    lobbyRoom(),
    " P1@EXAMPLE.COM ",
    { target_user_id: "user-2" },
  );
  assertEquals(transition.removedPlayer.email, "p2@example.com");
});

Deno.test("kick is limited to waiting and ready-voting lobbies", () => {
  for (const status of ["roulette", "playing", "finished", "unknown"]) {
    const error = errorDetails(assertThrows(() =>
      lobbyKickTransition(
        lobbyRoom({ status }),
        "p1@example.com",
        { target_user_id: "user-2" },
      )
    ));
    assertEquals(error.status, 409);
    assertEquals(error.code, "kick_status_invalid");
  }

  assertEquals(
    lobbyKickTransition(
      lobbyRoom({ status: " WAITING " }),
      "p1@example.com",
      { target_user_id: "user-2" },
    ).patch.status,
    "waiting",
  );
});

Deno.test("host cannot kick self by stable id or validated email fallback", () => {
  for (
    const target of [
      { target_user_id: "user-1" },
      { target_email: " P1@EXAMPLE.COM " },
    ]
  ) {
    const error = errorDetails(
      assertThrows(() =>
        lobbyKickTransition(lobbyRoom(), "p1@example.com", target)
      ),
    );
    assertEquals(error.status, 409);
    assertEquals(error.code, "kick_host_forbidden");
  }
});

Deno.test("unknown stable id never falls back to a supplied email", () => {
  const idError = errorDetails(assertThrows(() =>
    lobbyKickTransition(
      lobbyRoom(),
      "p1@example.com",
      {
        target_user_id: "unknown-user",
        target_email: "p2@example.com",
      },
    )
  ));
  assertEquals(idError.status, 404);
  assertEquals(idError.code, "kick_target_unknown");

  const emailError = errorDetails(assertThrows(() =>
    lobbyKickTransition(
      lobbyRoom(),
      "p1@example.com",
      { target_email: "unknown@example.com" },
    )
  ));
  assertEquals(emailError.status, 404);
  assertEquals(emailError.code, "kick_target_unknown");
});

Deno.test("target identifiers are validated before lookup", () => {
  for (
    const target of [
      { target_user_id: "bad id" },
      { target_email: "not-an-email" },
      { target_email: "" },
      {},
    ]
  ) {
    const error = errorDetails(
      assertThrows(() =>
        lobbyKickTransition(lobbyRoom(), "p1@example.com", target)
      ),
    );
    assertEquals(error.status, 400);
    assertEquals(error.code, "kick_target_invalid");
  }
});

Deno.test("stable user id is primary and canonical whitespace is accepted", () => {
  const transition = lobbyKickTransition(
    lobbyRoom(),
    "p1@example.com",
    {
      target_user_id: " user-2 ",
      target_email: "p4@example.com",
    },
  );
  assertEquals(transition.removedPlayer, player(2));
  assertEquals(
    transition.patch.players.map((candidate: Record<string, unknown>) =>
      candidate.user_id
    ),
    ["user-1", "user-3", "user-4"],
  );
});

Deno.test("validated email fallback is case-insensitive and removes the exact logical player", () => {
  const transition = lobbyKickTransition(
    lobbyRoom(),
    "p1@example.com",
    { target_email: " P4@EXAMPLE.COM " },
  );
  assertEquals(transition.removedPlayer, player(4));
  assertEquals(transition.patch.participant_user_ids, [
    "user-1",
    "user-2",
    "user-3",
  ]);
});

Deno.test("duplicate records for one identity are all removed and remaining roster is canonicalized", () => {
  const transition = lobbyKickTransition(
    lobbyRoom({
      players: [
        player(1),
        player(2),
        { ...player(2), name: "Duplicate target" },
        player(3),
        { ...player(3), email: " P3@EXAMPLE.COM ", name: "Duplicate three" },
        player(4),
      ],
    }),
    "p1@example.com",
    { target_user_id: "user-2" },
  );
  assertEquals(transition.removedRecordCount, 2);
  assertEquals(transition.patch.players, [player(1), player(3), player(4)]);
  assertEquals(transition.patch.participant_user_ids, [
    "user-1",
    "user-3",
    "user-4",
  ]);
});

Deno.test("conflicting duplicate identity fails closed", () => {
  const conflictingID = errorDetails(assertThrows(() =>
    lobbyKickTransition(
      lobbyRoom({
        players: [
          player(1),
          player(2),
          { ...player(3), user_id: "user-2" },
        ],
      }),
      "p1@example.com",
      { target_user_id: "user-2" },
    )
  ));
  assertEquals(conflictingID.status, 409);
  assertEquals(conflictingID.code, "kick_target_ambiguous");

  const conflictingStableEmail = errorDetails(
    assertThrows(() =>
      lobbyKickTransition(
        lobbyRoom({
          players: [
            player(1),
            player(2),
            { ...player(3), email: "P2@example.com" },
          ],
        }),
        "p1@example.com",
        { target_user_id: "user-2" },
      )
    ),
  );
  assertEquals(conflictingStableEmail.status, 409);
  assertEquals(conflictingStableEmail.code, "kick_target_ambiguous");

  const conflictingEmail = errorDetails(assertThrows(() =>
    lobbyKickTransition(
      lobbyRoom({
        players: [
          player(1),
          player(2),
          { ...player(3), email: "P2@example.com" },
        ],
      }),
      "p1@example.com",
      { target_email: "p2@example.com" },
    )
  ));
  assertEquals(conflictingEmail.status, 409);
  assertEquals(conflictingEmail.code, "kick_target_ambiguous");
});

Deno.test("kick removes every membership mirror, clears votes, and cancels ready voting", () => {
  const transition = lobbyKickTransition(
    lobbyRoom(),
    "p1@example.com",
    { target_user_id: "user-2" },
  );
  const patch = transition.patch;
  assertEquals(patch.status, "waiting");
  assertEquals(patch.players, [player(1), player(3), player(4)]);
  assertEquals(patch.participant_user_ids, ["user-1", "user-3", "user-4"]);
  assertEquals(patch.ready_players, []);
  assertEquals(patch.spectators, ["p3@example.com"]);
  assertEquals(patch.cards_read, ["p4@example.com"]);
  assertEquals(patch.eliminated_emails, ["p3@example.com"]);
  assertEquals(patch.departed_player_emails, ["former@example.com"]);
  assertEquals(patch.incompatible_player_emails, ["legacy@example.com"]);
  assertEquals(patch.spy_email, "");
  assertEquals(patch.spy_emails, ["p3@example.com"]);
  assertEquals(patch.revealed_spy_emails, []);
  assertEquals(patch.vote_requests, []);
  assertEquals(patch.detective_votes, []);
  assertEquals(patch.detective_vote_round_id, "");
  assertEquals(patch.player_feedback, [{ email: "p3@example.com", likes: 2 }]);
  assertEquals(patch.current_asker_email, "");
  assertEquals("current_answerer_email" in patch, false);
  assertEquals(patch.roulette_target_email, "");
});

Deno.test("kick preserves authoritative lobby settings and leaves spy-count clamping to integration", () => {
  const room = lobbyRoom();
  const transition = lobbyKickTransition(
    room,
    "p1@example.com",
    { target_user_id: "user-2" },
  );
  const updated = { ...room, ...transition.patch };
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
    assertEquals(updated[key], room[key], `${key} must survive a kick`);
    assertEquals(
      key in transition.patch,
      false,
      `${key} belongs to main integration`,
    );
  }
});

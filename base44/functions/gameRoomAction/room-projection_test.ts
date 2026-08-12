import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  projectRoomForClient,
  shouldRedactRoomSecret,
} from "./room-projection.ts";

Deno.test("active spy projection hides secret data and internal identities", () => {
  const room = {
    id: "room-1",
    match_id: "opaque-match-7d1c",
    code: "ABC123",
    host_email: "host@example.com",
    status: "playing",
    spy_email: "spy@example.com",
    word: "Embassy",
    category: "Places",
    players: [
      {
        user_id: "hidden-id",
        email: "spy@example.com",
        name: "Raven",
        avatar: "🎭",
      },
    ],
    participant_user_ids: ["hidden-id"],
    created_by: "hidden@example.com",
    word_pool: [{ word: "Embassy", enabled: true }],
    intro_started_at: "2026-07-21T12:00:00.000Z",
    game_paused_at: "2026-07-21T12:01:00.000Z",
    game_paused_total_seconds: 12,
  };
  const projected = projectRoomForClient(room, { email: "SPY@example.com" });
  assert(projected);
  assertEquals(
    shouldRedactRoomSecret(room, { email: "SPY@example.com" }),
    true,
  );
  assertEquals(projected.word, "CLASSIFIED");
  assertEquals(projected.secret_word, "CLASSIFIED");
  assertEquals(projected.spy_email, "spy@example.com");
  assertEquals(projected.word_pool, [{ word: "Embassy", enabled: true }]);
  assertEquals(projected.intro_started_at, "2026-07-21T12:00:00.000Z");
  assertEquals(projected.game_paused_at, "2026-07-21T12:01:00.000Z");
  assertEquals(projected.game_paused_total_seconds, 12);
  assertEquals(projected.match_id, "opaque-match-7d1c");
  assertEquals("participant_user_ids" in projected, false);
  assertEquals("created_by" in projected, false);
  assertEquals("game_started_event_id" in projected, false);
  assertEquals("game_finished_event_id" in projected, false);
  assertEquals("user_id" in projected.players[0], false);
});

Deno.test("detective sees a safe secret only after authenticated room projection", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "playing",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
    },
    { email: "detective@example.com" },
  );
  assert(projected);
  assertEquals(projected.word, "Embassy");
  assertEquals(projected.spy_email, "");
});

Deno.test("spectator cannot identify the spy before the room finishes", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "roulette",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
      word_pool: [{ word: "Embassy", enabled: true }],
    },
    { email: "spectator@example.com" },
  );
  assert(projected);
  assertEquals(projected.spy_email, "");
  assertEquals(projected.word_pool, [{ word: "Embassy", enabled: true }]);
});

Deno.test("finished projection reveals the resolved spy and word", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      status: "finished",
      spy_email: "spy@example.com",
      word: "Embassy",
      players: [],
    },
    { email: "detective@example.com" },
  );
  assert(projected);
  assertEquals(projected.spy_email, "spy@example.com");
  assertEquals(projected.word, "Embassy");
  assertEquals(projected.secret_word, "Embassy");
  assertEquals(projected.terminal_reconciliation_pending, false);
});

Deno.test("projection exposes only a boolean for pending terminal reconciliation", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      match_id: "match-1",
      code: "ABC123",
      status: "playing",
      players: [{ email: "detective@example.com" }],
      detective_vote_round_id: "round-a",
      terminal_intent: {
        match_id: "match-1",
        winner: "detectives",
        decided_at: "2026-08-08T12:00:00.000Z",
        detective_votes: [{
          voter_email: "detective@example.com",
          voted_for_email: "spy@example.com",
        }],
      },
    },
    { email: "detective@example.com" },
  );
  assert(projected);
  assertEquals(projected.terminal_reconciliation_pending, true);
  assertEquals(projected.detective_vote_round_id, "round-a");
  assertEquals("terminal_intent" in projected, false);
});

Deno.test("legacy active ballot without a round id projects inactive for safe reinitialization", () => {
  const players = ["p1", "p2", "p3", "p4", "p5", "p6"].map((email) => ({
    email,
  }));
  const activeLegacy = projectRoomForClient({
    id: "room-1",
    match_id: "match-1",
    status: "playing",
    players,
    detective_vote_round_id: "",
    vote_requests: ["p1", "p2", "p3", "p4"],
    detective_votes: [{ voter_email: "p1", voted_for_email: "p2" }],
  }, { email: "p1" });
  assert(activeLegacy);
  assertEquals(activeLegacy.vote_requests, []);
  assertEquals(activeLegacy.detective_votes, []);

  const preThreshold = projectRoomForClient({
    id: "room-1",
    match_id: "match-1",
    status: "playing",
    players,
    detective_vote_round_id: "",
    vote_requests: ["p1", "p2", "p3"],
    detective_votes: [],
  }, { email: "p1" });
  assertEquals(preThreshold?.vote_requests, ["p1", "p2", "p3"]);
});

Deno.test("durable detective-vote cancellation presentation projects to every participant", () => {
  const projected = projectRoomForClient({
    id: "room-1",
    match_id: "match-1",
    status: "playing",
    players: [{ email: "p1" }, { email: "p2" }, { email: "p3" }],
    detective_vote_round_id: "",
    detective_vote_cancellation_event_id: "cancel-event-1",
    detective_vote_cancellation_round_id: "round-7",
    detective_vote_cancellation_present_at: "2026-08-12T12:00:03.000Z",
    detective_vote_cancellation_reason: "no_viable_candidate",
  }, { email: "p2" });

  assert(projected);
  assertEquals(
    projected.detective_vote_cancellation_event_id,
    "cancel-event-1",
  );
  assertEquals(projected.detective_vote_cancellation_round_id, "round-7");
  assertEquals(
    projected.detective_vote_cancellation_present_at,
    "2026-08-12T12:00:03.000Z",
  );
  assertEquals(
    projected.detective_vote_cancellation_reason,
    "no_viable_candidate",
  );
});

Deno.test("waiting lobby projection synchronizes the safe draft but keeps source identity host-only", () => {
  const room = {
    id: "room-1",
    code: "ABC123",
    host_email: "host@example.com",
    status: "waiting",
    players: [],
    game_mode: "associations",
    game_duration_seconds: 300,
    lobby_schema_version: 1,
    lobby_revision: 4,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-private-1",
    lobby_source_name: "City pack",
    lobby_theme: "Cities",
    lobby_category: "Places",
    lobby_word_count: 2,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "embassy", word: "Embassy", enabled: true },
      { id: "harbor", word: "Harbor", enabled: false },
    ],
    lobby_last_mutation_id: "hidden-mutation",
    lobby_last_mutation_fingerprint: "hidden-fingerprint",
  };

  const guest = projectRoomForClient(room, { email: "guest@example.com" });
  assert(guest);
  assertEquals(guest.lobby_revision, 4);
  assertEquals(guest.lobby_word_source, "saved");
  assertEquals(guest.lobby_source_pack_id, "");
  assertEquals(guest.lobby_word_count_mode, "custom");
  assertEquals(guest.lobby_word_pool, [
    { id: "embassy", word: "Embassy", enabled: true },
    { id: "harbor", word: "Harbor", enabled: false },
  ]);
  assertEquals("lobby_last_mutation_id" in guest, false);
  assertEquals("lobby_last_mutation_fingerprint" in guest, false);

  const host = projectRoomForClient(room, { email: "HOST@example.com" });
  assertEquals(host?.lobby_source_pack_id, "pack-private-1");
});

Deno.test("active-room projection retains only the lobby revision and redacts the draft", () => {
  const projected = projectRoomForClient(
    {
      id: "room-1",
      code: "ABC123",
      host_email: "host@example.com",
      status: "roulette",
      players: [],
      lobby_schema_version: 1,
      lobby_revision: 9,
      lobby_word_source: "ai",
      lobby_theme: "Secret theme",
      lobby_category: "Secret category",
      lobby_word_count: 2,
      lobby_word_count_mode: "custom",
      lobby_word_pool: [
        { id: "one", word: "Disabled draft word", enabled: false },
        { id: "two", word: "Selected word", enabled: true },
      ],
    },
    { email: "host@example.com" },
  );
  assert(projected);
  assertEquals(projected.lobby_schema_version, 2);
  assertEquals(projected.lobby_revision, 9);
  assertEquals(projected.lobby_word_source, "none");
  assertEquals(projected.lobby_theme, "");
  assertEquals(projected.lobby_category, "");
  assertEquals(projected.lobby_word_count, 0);
  assertEquals(projected.lobby_word_pool, []);
});

Deno.test("multi-spy projection keeps every role private unless teammate knowledge is enabled", () => {
  const players = Array.from({ length: 6 }, (_, index) => ({
    email: `p${index + 1}@example.com`,
    name: `P${index + 1}`,
    client_capabilities: ["multi_spy_v1"],
  }));
  const base = {
    id: "multi-room",
    code: "MULTI1",
    host_email: players[0].email,
    status: "playing",
    players,
    spectators: [],
    eliminated_emails: [],
    lobby_spy_count: 2,
    spies_know_each_other: false,
    spy_emails: [players[0].email, players[1].email],
    spy_email: players[0].email,
    word: "Embassy",
    game_mode: "questions",
  };

  const secondSpy = projectRoomForClient(base, { email: players[1].email })!;
  assertEquals(secondSpy.spy_email, players[1].email);
  assertEquals(secondSpy.spy_emails, [players[1].email]);
  assertEquals(secondSpy.word, "CLASSIFIED");
  assertEquals(secondSpy.exclusion_vote_threshold, 4);

  const teamAware = projectRoomForClient(
    { ...base, spies_know_each_other: true },
    { email: players[1].email },
  )!;
  assertEquals(teamAware.spy_email, players[1].email);
  assertEquals(teamAware.spy_emails, [players[0].email, players[1].email]);

  const detective = projectRoomForClient(base, { email: players[2].email })!;
  assertEquals(detective.spy_email, "");
  assertEquals(detective.spy_emails, []);
  assertEquals(detective.word, "Embassy");
});

Deno.test("ejected spy role is revealed while living teammates remain private", () => {
  const room = {
    id: "multi-room",
    code: "MULTI2",
    host_email: "d1@example.com",
    status: "playing",
    players: [
      { email: "s1@example.com" },
      { email: "s2@example.com" },
      { email: "d1@example.com" },
      { email: "d2@example.com" },
      { email: "d3@example.com" },
      { email: "d4@example.com" },
    ],
    spectators: ["s1@example.com"],
    eliminated_emails: ["s1@example.com"],
    lobby_spy_count: 2,
    spy_emails: ["s1@example.com", "s2@example.com"],
    spy_email: "s1@example.com",
    word: "Embassy",
  };
  const projected = projectRoomForClient(room, { email: "d1@example.com" })!;
  assertEquals(projected.revealed_spy_emails, ["s1@example.com"]);
  assertEquals(projected.spy_emails, []);
  assertEquals(projected.exclusion_vote_threshold, 4);
});

import {
  assert,
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  assertExpectedReplaySourceMatch,
  replayAutoStartAlreadyComplete,
  replayAutoStartPatch,
} from "./replay-auto-start-policy.ts";

function finishedRoom(overrides: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    status: "finished",
    match_id: "match-finished-1",
    terminal_intent: { match_id: "match-finished-1", winner: "detectives" },
    host_email: "a@example.com",
    players: [
      {
        user_id: "user-a",
        email: "a@example.com",
        client_capabilities: ["multi_spy_v1"],
      },
      {
        user_id: "user-b",
        email: "b@example.com",
        client_capabilities: ["multi_spy_v1"],
      },
      {
        user_id: "user-c",
        email: "c@example.com",
        client_capabilities: ["multi_spy_v1"],
      },
      {
        user_id: "user-d",
        email: "d@example.com",
        client_capabilities: ["multi_spy_v1"],
      },
    ],
    participant_user_ids: ["user-a", "user-b", "user-c", "user-d"],
    departed_player_emails: ["d@example.com"],
    ready_players: ["a@example.com", "b@example.com", "c@example.com"],
    lobby_schema_version: 2,
    lobby_revision: 7,
    lobby_spy_count: 1,
    spies_know_each_other: false,
    game_mode: "associations",
    game_duration_seconds: 420,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-1",
    lobby_source_name: "Archive",
    lobby_theme: "places",
    lobby_category: "LANDMARKS",
    lobby_word_count: 3,
    lobby_word_count_mode: "recommended",
    lobby_word_pool: [
      { id: "w1", word: "Embassy", enabled: true },
      { id: "w2", word: "Museum", enabled: true },
      { id: "w3", word: "Library", enabled: true },
      { id: "w4", word: "Disabled", enabled: false },
    ],
    room_revision: 20,
    winner: "detectives",
    spy_email: "b@example.com",
    spy_emails: ["b@example.com"],
    word: "Old Word",
    secret_word: "Old Word",
    game_finished_event_id: "game-finished:match-finished-1",
    ...overrides,
  };
}

function deterministicRandom(values: number[]) {
  let index = 0;
  return (upperBound: number) => {
    const value = values[index++] ?? 0;
    assert(value >= 0 && value < upperBound);
    return value;
  };
}

Deno.test("final unanimous vote atomically enters roulette with the same authoritative settings", () => {
  const patch = replayAutoStartPatch(finishedRoom(), {
    expectedSourceMatchID: "match-finished-1",
    startedAt: "2026-09-01T12:00:00.000Z",
    randomIndex: deterministicRandom([0, 1, 2, 1, 0]),
  });

  assertEquals(patch.status, "roulette");
  assertEquals(patch.replay_source_match_id, "match-finished-1");
  assertEquals(patch.match_id, "");
  assertEquals(patch.intro_started_at, "2026-09-01T12:00:00.000Z");
  assertEquals(patch.game_mode, "associations");
  assertEquals(patch.game_duration_seconds, 420);
  assertEquals(patch.category, "LANDMARKS");
  assertEquals(patch.word_pool, [
    { word: "Embassy", enabled: true },
    { word: "Museum", enabled: true },
    { word: "Library", enabled: true },
  ]);
  assertEquals(patch.word, "Library");
  assertEquals(patch.secret_word, "Library");
  assertEquals(patch.ready_players, []);
  assertEquals(patch.departed_player_emails, []);
  assertEquals(
    patch.players.map((player: Record<string, unknown>) => player.email),
    ["a@example.com", "b@example.com", "c@example.com"],
  );
  assertEquals(patch.participant_user_ids, ["user-a", "user-b", "user-c"]);
  assertEquals(patch.host_email, "a@example.com");
  assertEquals(patch.spy_emails.length, 1);
  assertEquals(patch.spy_email, patch.spy_emails[0]);
  assertEquals(patch.spy_email, "c@example.com");
  assert(patch.spy_email !== "b@example.com");
  assert(
    patch.players.some((player: Record<string, unknown>) =>
      player.email === patch.current_asker_email
    ),
  );
  assert(
    patch.players.some((player: Record<string, unknown>) =>
      player.email === patch.current_answerer_email
    ),
  );
  assertEquals(patch.roulette_target_email, patch.current_asker_email);
});

Deno.test("departures clamp replay spy settings before a fresh assignment", () => {
  const patch = replayAutoStartPatch(
    finishedRoom({
      lobby_spy_count: 2,
      departed_player_emails: ["d@example.com"],
      ready_players: ["a@example.com", "b@example.com", "c@example.com"],
    }),
    {
      expectedSourceMatchID: "match-finished-1",
      randomIndex: deterministicRandom([0, 1, 0, 0, 0]),
    },
  );

  assertEquals(patch.lobby_spy_count, 1);
  assertEquals(patch.lobby_revision, 8);
  assertEquals(patch.spy_emails.length, 1);
});

Deno.test("replay completion marker makes response-loss retries exact and generation-scoped", () => {
  const roulette = {
    ...finishedRoom(),
    status: "roulette",
    match_id: "",
    replay_source_match_id: "match-finished-1",
  };
  assertEquals(
    replayAutoStartAlreadyComplete(roulette, "match-finished-1"),
    true,
  );
  assertEquals(
    replayAutoStartAlreadyComplete(roulette, "older-match"),
    false,
  );
  assertEquals(
    replayAutoStartAlreadyComplete(
      { ...roulette, status: "waiting" },
      "match-finished-1",
    ),
    false,
  );
});

Deno.test("a stale generation is rejected before it can add even a non-final vote", () => {
  const stale = assertThrows(() =>
    assertExpectedReplaySourceMatch(finishedRoom(), "older-match")
  ) as Error & { code?: string };
  assertEquals(stale.code, "replay_source_changed");
  assertEquals(
    assertExpectedReplaySourceMatch(finishedRoom(), "match-finished-1"),
    "match-finished-1",
  );
});

Deno.test("auto-start fails closed for incomplete, stale, or undersized replay quorum", () => {
  const incomplete = assertThrows(() =>
    replayAutoStartPatch(finishedRoom({
      ready_players: ["a@example.com", "b@example.com"],
    }))
  ) as Error & { code?: string };
  assertEquals(incomplete.code, "replay_votes_incomplete");

  const stale = assertThrows(() =>
    replayAutoStartPatch(finishedRoom(), {
      expectedSourceMatchID: "older-match",
    })
  ) as Error & { code?: string };
  assertEquals(stale.code, "replay_source_changed");

  const tooSmall = assertThrows(() =>
    replayAutoStartPatch(finishedRoom({
      departed_player_emails: ["c@example.com", "d@example.com"],
      ready_players: ["a@example.com", "b@example.com"],
    }))
  ) as Error & { code?: string };
  assertEquals(tooSmall.code, "replay_not_enough_players");
});

Deno.test("gameRoomAction commits replay auto-start from the voter path without host authority", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const votePath = source.slice(
    source.indexOf("async function votePlayAgain"),
    source.indexOf("function replayResetPatch"),
  );
  assertStringIncludes(votePath, "replayAutoStartPatch(");
  assertStringIncludes(votePath, "assertExpectedReplaySourceMatch(");
  assertStringIncludes(votePath, "expectedSourceMatchID");
  assertEquals(votePath.includes("requireHost("), false);
});

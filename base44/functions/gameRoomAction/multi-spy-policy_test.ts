import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  activeDepartureTransition,
  assertActiveSpyGuesser,
  canonicalClientCapabilities,
  canonicalSpyEmails,
  compatibleRosterForSpyCount,
  exclusionVoteThreshold,
  lobbyMembershipClampPatch,
  maximumSpyCount,
  MULTI_SPY_CAPABILITY,
  playerCapabilityRefreshNeeded,
  refreshedPlayerCapabilities,
  roomClientRequiresMultiSpyUpdate,
  roomHasDepartedPlayer,
  sampleUniqueSpyEmails,
  serverSpyAssignment,
  spyGuessWinner,
  spyTeamTerminalWinner,
  validatedLobbySpyCount,
} from "./multi-spy-policy.ts";

function players(count: number, capable = true) {
  return Array.from({ length: count }, (_, index) => ({
    user_id: `u${index + 1}`,
    email: `p${index + 1}@example.com`,
    client_capabilities: capable ? [MULTI_SPY_CAPABILITY] : [],
  }));
}

function room(count: number, spyCount: number): Record<string, any> {
  const roomPlayers = players(count);
  return {
    status: "playing",
    host_email: roomPlayers[0].email,
    players: roomPlayers,
    lobby_spy_count: spyCount,
    spy_emails: roomPlayers.slice(0, spyCount).map((player) => player.email),
    spy_email: roomPlayers[0].email,
    spectators: [],
    eliminated_emails: [],
  };
}

Deno.test("spy count table is exhaustive for online rooms 3 through 12", () => {
  const expected = new Map([
    [3, 1],
    [4, 1],
    [5, 1],
    [6, 2],
    [7, 2],
    [8, 2],
    [9, 3],
    [10, 3],
    [11, 3],
    [12, 3],
  ]);
  for (let count = 3; count <= 12; count += 1) {
    assertEquals(maximumSpyCount(count), expected.get(count));
    for (let spies = 1; spies <= expected.get(count)!; spies += 1) {
      assertEquals(validatedLobbySpyCount(spies, count), spies);
    }
    const error = assertThrows(() =>
      validatedLobbySpyCount(expected.get(count)! + 1, count)
    ) as Error & { code?: string };
    assertEquals(error.code, "spy_count_invalid_for_player_count");
  }
});

Deno.test("capabilities are bounded, canonical, and opt-in", () => {
  assertEquals(
    canonicalClientCapabilities([
      MULTI_SPY_CAPABILITY,
      MULTI_SPY_CAPABILITY,
      "bad capability",
      "online_v2",
    ]),
    [MULTI_SPY_CAPABILITY, "online_v2"],
  );

  const refreshed = refreshedPlayerCapabilities(
    players(3, false),
    "P1@example.com",
    [MULTI_SPY_CAPABILITY],
  );
  assertEquals(refreshed.changed, true);
  assertEquals(refreshed.players[0].client_capabilities, [
    MULTI_SPY_CAPABILITY,
  ]);
  assertEquals(refreshed.players[1].client_capabilities, []);
  assertEquals(
    playerCapabilityRefreshNeeded(
      refreshed.players,
      "p1@example.com",
      [MULTI_SPY_CAPABILITY],
    ),
    false,
  );
  assertEquals(
    playerCapabilityRefreshNeeded(
      players(3, false),
      "p1@example.com",
      [MULTI_SPY_CAPABILITY],
    ),
    true,
  );

  const oldPlayers = players(6);
  oldPlayers[5].client_capabilities = [];
  assertEquals(
    roomClientRequiresMultiSpyUpdate({
      lobby_spy_count: 2,
      players: oldPlayers,
    }, "p6@example.com"),
    true,
  );
  assertEquals(
    roomClientRequiresMultiSpyUpdate({
      lobby_spy_count: 1,
      players: oldPlayers.slice(0, 5),
      incompatible_player_emails: ["P6@example.com"],
    }, "p6@example.com"),
    true,
  );
  assertEquals(
    roomClientRequiresMultiSpyUpdate({
      lobby_spy_count: 1,
      players: oldPlayers,
    }, "p6@example.com"),
    false,
  );
});

Deno.test("server assignment samples unique identities and retry never rerolls", () => {
  const armed = {
    status: "ready_voting",
    players: players(9),
    lobby_spy_count: 3,
    spy_emails: [],
    spy_email: "",
  };
  const first = serverSpyAssignment(armed, () => 0);
  assertEquals(first.spy_emails.length, 3);
  assertEquals(new Set(first.spy_emails).size, 3);
  const retry = serverSpyAssignment(
    { ...armed, ...first },
    (upper) => upper - 1,
  );
  assertEquals(retry, first);

  const independentlySampled = sampleUniqueSpyEmails(
    players(6).map((player) => player.email),
    2,
    (upper) => upper - 1,
  );
  assertEquals(independentlySampled, ["p1@example.com", "p2@example.com"]);
});

Deno.test("a partial frozen assignment fails closed without rerolling", () => {
  let randomCalls = 0;
  const partial = {
    status: "roulette",
    players: players(6),
    lobby_spy_count: 2,
    spy_emails: ["p1@example.com"],
    spy_email: "p1@example.com",
  };
  const error = assertThrows(() =>
    serverSpyAssignment(partial, () => {
      randomCalls += 1;
      return 0;
    })
  ) as Error & { code?: string; status?: number };
  assertEquals(error.code, "spy_assignment_invalid");
  assertEquals(error.status, 409);
  assertEquals(randomCalls, 0);
});

Deno.test("canonical role list falls back to the legacy singular field", () => {
  assertEquals(
    canonicalSpyEmails({
      players: players(3),
      spy_email: "P1@example.com",
    }),
    ["p1@example.com"],
  );
});

Deno.test("six/two and nine/three use N minus active S vote thresholds", () => {
  assertEquals(exclusionVoteThreshold(room(6, 2)), 4);
  assertEquals(exclusionVoteThreshold(room(9, 3)), 6);
  const afterSpyEjection = room(6, 2);
  afterSpyEjection.spectators = [afterSpyEjection.spy_emails[0]];
  assertEquals(exclusionVoteThreshold(afterSpyEjection), 4);
});

Deno.test("team terminal requires every spy gone or active parity", () => {
  const sixTwo = room(6, 2);
  assertEquals(spyTeamTerminalWinner(sixTwo), null);
  sixTwo.spectators = ["p3@example.com", "p4@example.com"];
  assertEquals(spyTeamTerminalWinner(sixTwo), "spy");

  const detectivesWin = room(6, 2);
  detectivesWin.spectators = ["p1@example.com", "p2@example.com"];
  assertEquals(spyTeamTerminalWinner(detectivesWin), "detectives");
});

Deno.test("either active spy shares the one guess outcome while eliminated spies are blocked", () => {
  const multi = room(6, 2);
  assertActiveSpyGuesser(multi, "p2@example.com");
  assertEquals(spyGuessWinner("Embassy", "embassy"), "spy");
  assertEquals(spyGuessWinner("Embassy", "Harbor"), "detectives");

  multi.spectators = ["p2@example.com"];
  const eliminated = assertThrows(() =>
    assertActiveSpyGuesser(multi, "p2@example.com")
  ) as Error & { code?: string };
  assertEquals(eliminated.code, "eliminated_spy_cannot_guess");

  const detective = assertThrows(() =>
    assertActiveSpyGuesser(multi, "p3@example.com")
  ) as Error & { code?: string };
  assertEquals(detective.code, "spy_access_required");
});

Deno.test("host selection removes incompatible roster without consent and clamps safely", () => {
  const roomPlayers = players(9);
  roomPlayers[8].client_capabilities = [];
  const result = compatibleRosterForSpyCount({
    host_email: roomPlayers[0].email,
    players: roomPlayers,
  }, 3);
  assertEquals(result.players.length, 8);
  assertEquals(result.removedEmails, ["p9@example.com"]);
  assertEquals(result.effectiveSpyCount, 2);

  const sixPlayers = players(6);
  sixPlayers[5].client_capabilities = [];
  const clampedToSingle = compatibleRosterForSpyCount({
    host_email: sixPlayers[0].email,
    players: sixPlayers,
  }, 2);
  assertEquals(clampedToSingle.players.length, 5);
  assertEquals(clampedToSingle.removedEmails, ["p6@example.com"]);
  assertEquals(clampedToSingle.effectiveSpyCount, 1);

  const responseLossRetry = compatibleRosterForSpyCount({
    host_email: roomPlayers[0].email,
    players: result.players,
    incompatible_player_emails: result.removedEmails,
  }, 3);
  assertEquals(responseLossRetry.removedEmails, []);
  assertEquals(responseLossRetry.effectiveSpyCount, 2);

  roomPlayers[0].client_capabilities = [];
  const error = assertThrows(() =>
    compatibleRosterForSpyCount({
      host_email: roomPlayers[0].email,
      players: roomPlayers,
    }, 2)
  ) as Error & { code?: string; status?: number };
  assertEquals(error.code, "client_update_required");
  assertEquals(error.status, 426);
});

Deno.test("waiting leave clamps spy count and invalidates the lobby replay token", () => {
  const patch = lobbyMembershipClampPatch({
    status: "ready_voting",
    lobby_spy_count: 3,
    lobby_revision: 7,
    lobby_last_mutation_id: "m7",
    lobby_last_mutation_fingerprint: "f7",
  }, 8);
  assertEquals(patch.status, "waiting");
  assertEquals(patch.ready_players, []);
  assertEquals(patch.lobby_spy_count, 2);
  assertEquals(patch.lobby_revision, 8);
  assertEquals(patch.lobby_last_mutation_id, "");
  assertEquals(patch.lobby_last_mutation_fingerprint, "");
});

Deno.test("active leave eliminates in place, transfers host, repairs vectors, and recalculates parity", () => {
  const activeRoom = room(6, 2);
  activeRoom.host_email = "p3@example.com";
  activeRoom.spectators = ["p6@example.com"];
  activeRoom.current_asker_email = "p3@example.com";
  activeRoom.current_answerer_email = "p4@example.com";
  activeRoom.roulette_target_email = "p3@example.com";
  activeRoom.current_answer = "pending";
  activeRoom.current_answer_feedback = "like";
  activeRoom.question_phase = "answering";
  activeRoom.countdown_started_at = "2026-08-09T12:00:00.000Z";
  activeRoom.cards_read = players(6).map((player) => player.email);
  const transition = activeDepartureTransition(activeRoom, "p3@example.com");
  assertEquals(transition.patch.host_email, "p1@example.com");
  assertEquals(transition.patch.spectators, [
    "p6@example.com",
    "p3@example.com",
  ]);
  assertEquals(transition.patch.departed_player_emails, ["p3@example.com"]);
  assertEquals(
    roomHasDepartedPlayer({
      ...activeRoom,
      ...transition.patch,
    }, "P3@example.com"),
    true,
  );
  assertEquals("players" in transition.patch, false);
  assertEquals("cards_read" in transition.patch, false);
  assertEquals(transition.patch.current_asker_email, "p4@example.com");
  assertEquals(transition.patch.current_answerer_email, "p1@example.com");
  assertEquals(transition.patch.roulette_target_email, "p1@example.com");
  assertEquals(transition.patch.question_phase, "asking");
  assertEquals(transition.patch.current_answer, "");
  assertEquals(transition.patch.current_answer_feedback, null);
  assertEquals(transition.patch.countdown_started_at, null);
  assertEquals(transition.terminalWinner, "spy");
});

Deno.test("active leave preserves an unrelated valid question vector", () => {
  const activeRoom = room(6, 2);
  activeRoom.current_asker_email = "p3@example.com";
  activeRoom.current_answerer_email = "p4@example.com";
  activeRoom.roulette_target_email = "p5@example.com";
  activeRoom.current_answer = "pending";
  activeRoom.question_phase = "answering";
  const transition = activeDepartureTransition(activeRoom, "p6@example.com");
  assertEquals("current_asker_email" in transition.patch, false);
  assertEquals("current_answerer_email" in transition.patch, false);
  assertEquals("roulette_target_email" in transition.patch, false);
  assertEquals("current_answer" in transition.patch, false);
});

Deno.test("association leave advances an active speaker by the persisted order without dropping state", () => {
  const activeRoom = room(7, 2);
  activeRoom.game_mode = "associations";
  activeRoom.current_asker_email = "p3@example.com";
  activeRoom.current_answerer_email = "p5@example.com";
  activeRoom.current_answer = JSON.stringify({
    spoken: ["p1@example.com", "p3@example.com"],
    spinning: false,
    order: [
      "p2@example.com",
      "p3@example.com",
      "p6@example.com",
      "p4@example.com",
      "p5@example.com",
      "p1@example.com",
      "p7@example.com",
    ],
  });

  const transition = activeDepartureTransition(activeRoom, "p3@example.com");
  const state = JSON.parse(transition.patch.current_answer);
  assertEquals(transition.terminalWinner, null);
  assertEquals(transition.patch.current_asker_email, "p6@example.com");
  assertEquals(transition.patch.current_answerer_email, "p5@example.com");
  assertEquals(state.order, [
    "p2@example.com",
    "p6@example.com",
    "p4@example.com",
    "p5@example.com",
    "p1@example.com",
    "p7@example.com",
  ]);
  assertEquals(state.spoken, ["p1@example.com"]);
  assertEquals(state.spinning, true);
});

Deno.test("association leave at the roster boundary starts the next round atomically", () => {
  const activeRoom = room(7, 2);
  activeRoom.game_mode = "associations";
  activeRoom.round_number = 4;
  activeRoom.current_asker_email = "p7@example.com";
  activeRoom.current_answerer_email = "p2@example.com";
  activeRoom.current_answer = JSON.stringify({
    spoken: [
      "p1@example.com",
      "p2@example.com",
      "p3@example.com",
      "p4@example.com",
      "p5@example.com",
      "p6@example.com",
    ],
    spinning: false,
    order: [
      "p1@example.com",
      "p2@example.com",
      "p3@example.com",
      "p4@example.com",
      "p5@example.com",
      "p6@example.com",
      "p7@example.com",
    ],
  });

  const transition = activeDepartureTransition(activeRoom, "p7@example.com");
  const state = JSON.parse(transition.patch.current_answer);
  assertEquals(transition.patch.round_number, 5);
  assertEquals(transition.patch.current_asker_email, "p1@example.com");
  assertEquals(state.order, [
    "p1@example.com",
    "p2@example.com",
    "p3@example.com",
    "p4@example.com",
    "p5@example.com",
    "p6@example.com",
  ]);
  assertEquals(state.spoken, []);
  assertEquals(state.spinning, true);
});

Deno.test("an expelled spectator can explicitly depart without rejoining play", () => {
  const activeRoom = room(6, 2);
  activeRoom.spectators = ["p3@example.com"];
  activeRoom.eliminated_emails = ["p3@example.com"];
  const transition = activeDepartureTransition(activeRoom, "P3@example.com");
  assertEquals(transition.patch, {
    departed_player_emails: ["p3@example.com"],
  });
  assertEquals(transition.terminalWinner, null);
  const retry = activeDepartureTransition({
    ...activeRoom,
    ...transition.patch,
  }, "p3@example.com");
  assertEquals(retry.patch, {});
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  countdownRemainingSeconds,
  deriveOnlineGamePresentation,
  onlineRoundCommand,
  parseAssociationRoundState,
  shouldAcceptOnlineRoomSnapshot,
} from "./onlineGamePresentation.js";

const players = [
  { email: "detective@example.com", name: "Detective", avatar: "D" },
  { email: "spy@example.com", name: "Spy", avatar: "S" },
  { email: "third@example.com", name: "Third", avatar: "T" },
];

function activeRoom(overrides = {}) {
  return {
    id: "room-1",
    status: "playing",
    host_email: "detective@example.com",
    players,
    spectators: [],
    cards_read: players.map((player) => player.email),
    game_started_at: "2026-08-04T10:00:00.000Z",
    game_paused_at: "",
    spy_email: "spy@example.com",
    secret_word: "Embassy",
    word: "Embassy",
    game_mode: "questions",
    question_phase: "asking",
    current_asker_email: "detective@example.com",
    current_answerer_email: "third@example.com",
    vote_requests: [],
    detective_votes: [],
    ...overrides,
  };
}

test("detective presentation receives the secret while spy and observer fail closed", () => {
  const detective = deriveOnlineGamePresentation(activeRoom(), "DETECTIVE@example.com");
  assert.equal(detective.viewerRole, "detective");
  assert.equal(detective.canSeeSecretWord, true);
  assert.equal(detective.secretWord, "Embassy");

  const spy = deriveOnlineGamePresentation(activeRoom(), "spy@example.com");
  assert.equal(spy.viewerRole, "spy");
  assert.equal(spy.canSeeSecretWord, false);
  assert.equal(spy.secretWord, null);

  const observer = deriveOnlineGamePresentation(activeRoom(), "outside@example.com");
  assert.equal(observer.viewerRole, "observer");
  assert.equal(observer.secretWord, null);
});

test("presentation derivation does not mutate or expose mutable room player objects", () => {
  const room = activeRoom();
  const before = JSON.stringify(room);
  const presentation = deriveOnlineGamePresentation(room, "detective@example.com");

  presentation.activePlayers[0].name = "Changed only in presentation";

  assert.equal(JSON.stringify(room), before);
  assert.equal(room.players[0].name, "Detective");
});

test("spectator never receives the secret, including after the room finishes", () => {
  const room = activeRoom({
    status: "finished",
    spectators: ["third@example.com"],
  });
  const presentation = deriveOnlineGamePresentation(room, "third@example.com");

  assert.equal(presentation.subphase, "finished");
  assert.equal(presentation.viewerRole, "spectator");
  assert.equal(presentation.canSeeSecretWord, false);
  assert.equal(presentation.secretWord, null);
  assert.equal(presentation.roundCommand, null);
});

test("playing room remains in role gate until every card and server timer are confirmed", () => {
  const unread = deriveOnlineGamePresentation(activeRoom({
    cards_read: ["detective@example.com", "spy@example.com"],
  }), "detective@example.com");
  assert.equal(unread.subphase, "role_gate");
  assert.equal(unread.allRoleCardsRead, false);
  assert.equal(unread.roundCommand, null);

  const noTimer = deriveOnlineGamePresentation(activeRoom({
    game_started_at: "",
  }), "detective@example.com");
  assert.equal(noTimer.subphase, "role_gate");
  assert.equal(noTimer.allRoleCardsRead, true);
  assert.equal(noTimer.roundCommand, null);
});

test("role-card acknowledgements ignore email case and surrounding whitespace", () => {
  const presentation = deriveOnlineGamePresentation(activeRoom({
    cards_read: [" DETECTIVE@EXAMPLE.COM ", "Spy@Example.com"],
  }), "detective@example.com");

  assert.equal(presentation.hasReadRoleCard, true);
  assert.equal(presentation.cardsReadCount, 2);
  assert.equal(presentation.allRoleCardsRead, false);
  assert.equal(presentation.subphase, "role_gate");
});

test("question command belongs only to the current asker and is case insensitive", () => {
  const room = activeRoom();
  assert.equal(onlineRoundCommand(room, " DETECTIVE@EXAMPLE.COM "), "mark_answer_heard");
  assert.equal(onlineRoundCommand(room, "third@example.com"), null);
  assert.equal(onlineRoundCommand(room, "outside@example.com"), null);
});

test("pause keeps the active subphase visible but blocks round commands", () => {
  const room = activeRoom({ game_paused_at: "2026-08-04T10:02:00.000Z" });
  const presentation = deriveOnlineGamePresentation(room, "detective@example.com");

  assert.equal(presentation.subphase, "active");
  assert.equal(presentation.isPaused, true);
  assert.equal(presentation.roundCommand, null);
});

test("active-player votes derive threshold, viewer vote, and voting subphase", () => {
  const room = activeRoom({
    spectators: ["third@example.com"],
    vote_requests: [
      "detective@example.com",
      "SPY@example.com",
      "third@example.com",
      "detective@example.com",
    ],
    detective_votes: [
      { voter_email: "DETECTIVE@example.com", voted_for_email: "spy@example.com" },
    ],
  });
  const presentation = deriveOnlineGamePresentation(room, "detective@example.com");

  assert.deepEqual(
    presentation.activePlayers.map((player) => player.email),
    ["detective@example.com", "spy@example.com"],
  );
  assert.deepEqual(presentation.activeVoteRequests, [
    "detective@example.com",
    "SPY@example.com",
  ]);
  assert.equal(presentation.voteThreshold, 2);
  assert.equal(presentation.isVotingActive, true);
  assert.equal(presentation.subphase, "voting");
  assert.equal(presentation.myVote?.voted_for_email, "spy@example.com");
  assert.equal(presentation.hasRequestedVote, true);
  assert.equal(presentation.roundCommand, null);
});

test("results can continue from any room player but never from an observer", () => {
  const room = activeRoom({ question_phase: "results" });
  assert.equal(onlineRoundCommand(room, "third@example.com"), "continue_round");
  assert.equal(onlineRoundCommand(room, "outside@example.com"), null);
});

test("association state parser accepts only the bounded typed envelope", () => {
  assert.deepEqual(
    parseAssociationRoundState(JSON.stringify({
      spoken: [" Spy@example.com ", "spy@example.com", "third@example.com"],
      spinning: true,
    })),
    { spoken: ["Spy@example.com", "third@example.com"], spinning: true },
  );
  assert.deepEqual(parseAssociationRoundState("legacy answer"), {
    spoken: [],
    spinning: false,
  });
  assert.deepEqual(parseAssociationRoundState(JSON.stringify({
    spoken: ["valid@example.com", 7],
    spinning: true,
  })), {
    spoken: [],
    spinning: false,
  });
});

test("association host starts an idle round and only current speaker advances it", () => {
  const idleRoom = activeRoom({
    game_mode: "associations",
    current_asker_email: "",
    current_answer: JSON.stringify({ spoken: [], spinning: false }),
  });
  assert.equal(onlineRoundCommand(idleRoom, "detective@example.com"), "start_association");
  assert.equal(onlineRoundCommand(idleRoom, "third@example.com"), null);

  const speakingRoom = activeRoom({
    game_mode: "associations",
    current_asker_email: "third@example.com",
    current_answer: JSON.stringify({
      spoken: ["detective@example.com"],
      spinning: false,
    }),
  });
  assert.equal(onlineRoundCommand(speakingRoom, "third@example.com"), "advance_association");
  assert.equal(onlineRoundCommand(speakingRoom, "detective@example.com"), null);
});

test("association spin exposes stop capability without inventing a round command", () => {
  const room = activeRoom({
    game_mode: "associations",
    current_asker_email: "third@example.com",
    current_answer: JSON.stringify({ spoken: [], spinning: true }),
  });
  const speaker = deriveOnlineGamePresentation(room, "third@example.com");
  const host = deriveOnlineGamePresentation(room, "detective@example.com");
  const spy = deriveOnlineGamePresentation(room, "spy@example.com");

  assert.equal(speaker.roundCommand, null);
  assert.equal(speaker.canStopAssociationSpin, true);
  assert.equal(host.canStopAssociationSpin, true);
  assert.equal(spy.canStopAssociationSpin, false);
});

test("server-clock countdown reports fractional remaining time and safe fallbacks", () => {
  const room = activeRoom({
    question_phase: "countdown",
    countdown_started_at: "2026-08-04T10:00:00.000Z",
  });
  assert.equal(
    countdownRemainingSeconds(room, Date.parse("2026-08-04T10:00:02.000Z")),
    3,
  );
  assert.equal(
    countdownRemainingSeconds(room, Date.parse("2026-08-04T10:00:02.500Z")),
    2.5,
  );
  assert.equal(
    countdownRemainingSeconds({ ...room, countdown_started_at: "bad timestamp" }),
    5,
  );
  assert.equal(countdownRemainingSeconds(activeRoom()), 0);
});

test("room snapshot ordering rejects stale and cross-room updates", () => {
  const current = {
    id: "room-1",
    updated_date: "2026-08-04T10:00:02.000Z",
  };

  assert.equal(shouldAcceptOnlineRoomSnapshot(null, current), true);
  assert.equal(shouldAcceptOnlineRoomSnapshot(current, {
    id: "room-1",
    updated_date: "2026-08-04T10:00:03.000Z",
  }), true);
  assert.equal(shouldAcceptOnlineRoomSnapshot(current, {
    id: "room-1",
    updated_date: "2026-08-04T10:00:01.000Z",
  }), false);
  assert.equal(shouldAcceptOnlineRoomSnapshot(current, {
    id: "room-2",
    updated_date: "2026-08-04T10:00:03.000Z",
  }), false);
  assert.equal(shouldAcceptOnlineRoomSnapshot(current, {
    id: "room-1",
  }), true);
  assert.equal(shouldAcceptOnlineRoomSnapshot(current, null), false);
});

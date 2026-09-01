import {
  assertEquals,
  assertNotEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import {
  advanceAssociationTurn,
  associationRosterChangePatch,
  encodeAssociationTurnState,
  initialAssociationTurn,
  reconcileAssociationTurnState,
} from "./association-turn-order.ts";

const players = [
  { email: "a@example.com" },
  { email: "b@example.com" },
  { email: "c@example.com" },
  { email: "d@example.com" },
];

Deno.test("association turn order is shuffled once and reused every round", () => {
  const initial = initialAssociationTurn({
    activePlayers: players,
    random: () => 0,
  });
  assertEquals(initial.state.order, [
    "b@example.com",
    "c@example.com",
    "d@example.com",
    "a@example.com",
  ]);

  let current = initial.speakerEmail;
  let state = initial.state;
  const firstRound = [current];
  for (let index = 1; index < players.length; index += 1) {
    const transition = advanceAssociationTurn({
      activePlayers: players,
      currentSpeakerEmail: current,
      rawState: encodeAssociationTurnState(state),
      random: () => 0.75,
    });
    assertEquals(transition.startsNewRound, false);
    current = transition.speakerEmail;
    state = transition.state;
    firstRound.push(current);
  }

  const nextRound = advanceAssociationTurn({
    activePlayers: players,
    currentSpeakerEmail: current,
    rawState: encodeAssociationTurnState(state),
    random: () => 0.75,
  });
  assertEquals(nextRound.startsNewRound, true);
  assertNotEquals(nextRound.speakerEmail, current);

  const secondRound = [nextRound.speakerEmail];
  current = nextRound.speakerEmail;
  state = nextRound.state;
  for (let index = 1; index < players.length; index += 1) {
    const transition = advanceAssociationTurn({
      activePlayers: players,
      currentSpeakerEmail: current,
      rawState: encodeAssociationTurnState(state),
      random: () => 0.25,
    });
    current = transition.speakerEmail;
    state = transition.state;
    secondRound.push(current);
  }

  assertEquals(firstRound, initial.state.order);
  assertEquals(secondRound, firstRound);
});

Deno.test("association order survives active roster changes without duplicates", () => {
  const transition = advanceAssociationTurn({
    activePlayers: [players[0], players[2], { email: "e@example.com" }],
    currentSpeakerEmail: "a@example.com",
    rawState: JSON.stringify({
      spoken: [],
      spinning: false,
      order: ["a@example.com", "b@example.com", "c@example.com"],
    }),
  });

  assertEquals(transition.state.order, [
    "a@example.com",
    "c@example.com",
    "e@example.com",
  ]);
  assertEquals(transition.speakerEmail, "c@example.com");
});

Deno.test("legacy association state migrates to one persisted safe order", () => {
  const transition = advanceAssociationTurn({
    activePlayers: players,
    currentSpeakerEmail: "a@example.com",
    rawState: JSON.stringify({
      spoken: ["a@example.com"],
      spinning: false,
    }),
    random: () => 0,
  });

  assertEquals(transition.startsNewRound, false);
  assertEquals(transition.state.order, [
    "a@example.com",
    "c@example.com",
    "d@example.com",
    "b@example.com",
  ]);
  assertNotEquals(transition.speakerEmail, "a@example.com");

  const persisted = advanceAssociationTurn({
    activePlayers: players,
    currentSpeakerEmail: transition.speakerEmail,
    rawState: encodeAssociationTurnState(transition.state),
    random: () => 0.75,
  });
  assertEquals(persisted.state.order, transition.state.order);
});

Deno.test("legacy initial state anchors the existing first speaker before persisting one order", () => {
  const reconciled = reconcileAssociationTurnState({
    activePlayers: players,
    currentSpeakerEmail: "c@example.com",
    rawState: JSON.stringify({ spoken: [], spinning: true }),
    random: () => 0,
  });

  assertEquals(reconciled.order[0], "c@example.com");
  assertEquals(new Set(reconciled.order).size, players.length);
  assertEquals(
    reconciled.order.sort(),
    players.map((player) => player.email).sort(),
  );
});

Deno.test("association roster repair advances an ejected speaker to the next stored survivor", () => {
  const transition = associationRosterChangePatch({
    activePlayers: [players[1], players[2], players[3]],
    currentSpeakerEmail: "a@example.com",
    currentAnswererEmail: "c@example.com",
    rawState: JSON.stringify({
      spoken: ["a@example.com"],
      spinning: false,
      order: players.map((player) => player.email),
    }),
  });
  const patch = transition.patch;
  const state = JSON.parse(String(patch.current_answer));

  assertEquals(transition.startsNewRound, false);
  assertEquals(patch.current_asker_email, "b@example.com");
  assertEquals(patch.current_answerer_email, "c@example.com");
  assertEquals(patch.question_phase, "asking");
  assertEquals(state.order, [
    "b@example.com",
    "c@example.com",
    "d@example.com",
  ]);
  assertEquals(state.spoken, []);
  assertEquals(state.spinning, true);
});

Deno.test("association roster repair filters a non-speaker departure without restarting spin", () => {
  const transition = associationRosterChangePatch({
    activePlayers: [players[0], players[1], players[3]],
    currentSpeakerEmail: "b@example.com",
    currentAnswererEmail: "a@example.com",
    rawState: JSON.stringify({
      spoken: ["a@example.com", "b@example.com", "c@example.com"],
      spinning: false,
      order: players.map((player) => player.email),
    }),
  });
  const patch = transition.patch;
  const state = JSON.parse(String(patch.current_answer));

  assertEquals(transition.startsNewRound, false);
  assertEquals(patch.current_asker_email, "b@example.com");
  assertEquals(state.order, [
    "a@example.com",
    "b@example.com",
    "d@example.com",
  ]);
  assertEquals(state.spoken, ["a@example.com", "b@example.com"]);
  assertEquals(state.spinning, false);
});

Deno.test("association ejection at the roster boundary starts the preserved next round", () => {
  const transition = associationRosterChangePatch({
    activePlayers: [players[0], players[1]],
    currentSpeakerEmail: "c@example.com",
    currentAnswererEmail: "a@example.com",
    rawState: JSON.stringify({
      spoken: ["a@example.com", "b@example.com"],
      spinning: false,
      order: ["a@example.com", "b@example.com", "c@example.com"],
    }),
  });
  const state = JSON.parse(String(transition.patch.current_answer));

  assertEquals(transition.startsNewRound, true);
  assertEquals(transition.patch.current_asker_email, "a@example.com");
  assertEquals(state.order, ["a@example.com", "b@example.com"]);
  assertEquals(state.spoken, []);
  assertEquals(state.spinning, true);
});

Deno.test("spin settlement preserves order and migrates a legacy state", () => {
  const preserved = reconcileAssociationTurnState({
    activePlayers: players,
    rawState: JSON.stringify({
      spoken: ["a@example.com"],
      spinning: true,
      order: [
        "d@example.com",
        "a@example.com",
        "c@example.com",
        "b@example.com",
      ],
    }),
    random: () => 0,
  });
  assertEquals(preserved.order, [
    "d@example.com",
    "a@example.com",
    "c@example.com",
    "b@example.com",
  ]);

  const migrated = reconcileAssociationTurnState({
    activePlayers: players,
    rawState: JSON.stringify({ spoken: [], spinning: true }),
    random: () => 0,
  });
  assertEquals(migrated.order, [
    "b@example.com",
    "c@example.com",
    "d@example.com",
    "a@example.com",
  ]);
});

Deno.test("gameRoomAction persists association order through start advance and stop", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const advance = source.slice(
    source.indexOf("async function advanceAssociation"),
    source.indexOf("async function startAssociation"),
  );
  const start = source.slice(
    source.indexOf("async function startAssociation"),
    source.indexOf("async function stopAssociationSpin"),
  );
  const stop = source.slice(
    source.indexOf("async function stopAssociationSpin"),
    source.indexOf("async function markAnswerHeard"),
  );

  assertStringIncludes(advance, "advanceAssociationTurn({");
  assertStringIncludes(
    advance,
    "current_answer: encodeAssociationTurnState(transition.state)",
  );
  assertStringIncludes(
    start,
    "initialAssociationTurn({ activePlayers: active })",
  );
  assertStringIncludes(start, "if (currentSpeaker) {");
  assertStringIncludes(start, "reconcileAssociationTurnState({");
  assertStringIncludes(
    start,
    "current_answer: encodeAssociationTurnState(initial.state)",
  );
  assertStringIncludes(stop, "reconcileAssociationTurnState({");
  assertStringIncludes(stop, "order: state.order");

  const cast = source.slice(
    source.indexOf("async function castDetectiveVote"),
    source.indexOf("async function submitSpyGuess"),
  );
  assertStringIncludes(
    cast,
    'resolution.decision.outcome === "eject"',
  );
  assertStringIncludes(cast, "associationRosterChangePatch({");
  assertStringIncludes(cast, "associationTransition.startsNewRound");
  assertStringIncludes(cast, "patch.round_number");
  assertStringIncludes(cast, "Object.assign(");

  const departurePolicy = await Deno.readTextFile(
    new URL("./multi-spy-policy.ts", import.meta.url),
  );
  const activeDeparture = departurePolicy.slice(
    departurePolicy.indexOf("export function activeDepartureTransition"),
  );
  assertStringIncludes(activeDeparture, "associationRosterChangePatch({");
  assertStringIncludes(
    activeDeparture,
    "associationTransition?.startsNewRound",
  );
});

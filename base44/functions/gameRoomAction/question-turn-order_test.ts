import {
  assert,
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  advanceQuestionTurn,
  encodeQuestionTurnOrderState,
  initialQuestionTurn,
  parseQuestionTurnOrderState,
  questionRosterChangePatch,
  questionTurnOrderState,
  reconcileQuestionTurn,
} from "./question-turn-order.ts";

const players = ["a", "b", "c", "d"].map((name) => ({
  email: `${name}@example.com`,
}));

function deterministicRandom(values: number[]) {
  let index = 0;
  return (upperBound: number) => {
    const value = values[index++] ?? 0;
    if (value < 0 || value >= upperBound) {
      throw new RangeError(
        `invalid deterministic value ${value}/${upperBound}`,
      );
    }
    return value;
  };
}

Deno.test("Questions preserves the validated roulette pair and securely shuffles the remainder", () => {
  const turn = initialQuestionTurn({
    activePlayers: players,
    currentAskerEmail: "c@example.com",
    currentAnswererEmail: "a@example.com",
    randomIndex: deterministicRandom([0]),
  });

  assertEquals(turn.state, {
    kind: "question_turn_order_v1",
    order: [
      "c@example.com",
      "a@example.com",
      "d@example.com",
      "b@example.com",
    ],
  });
  assertEquals(turn.askerEmail, "c@example.com");
  assertEquals(turn.answererEmail, "a@example.com");
  assertEquals(
    parseQuestionTurnOrderState(encodeQuestionTurnOrderState(turn.state)),
    turn.state,
  );
});

Deno.test("Questions reuses the same cyclic order across later cycles", () => {
  const state = questionTurnOrderState([
    "c@example.com",
    "d@example.com",
    "b@example.com",
    "a@example.com",
  ]);
  let turn = {
    askerEmail: "c@example.com",
    answererEmail: "d@example.com",
    state,
  };
  const answerers: string[] = [];

  for (let index = 0; index < 8; index += 1) {
    answerers.push(turn.answererEmail);
    turn = advanceQuestionTurn({
      activePlayers: players,
      rawState: encodeQuestionTurnOrderState(turn.state),
      currentAskerEmail: turn.askerEmail,
      currentAnswererEmail: turn.answererEmail,
    });
  }

  assertEquals(answerers, [
    "d@example.com",
    "b@example.com",
    "a@example.com",
    "c@example.com",
    "d@example.com",
    "b@example.com",
    "a@example.com",
    "c@example.com",
  ]);
  assertEquals(turn.state, state);
  assertEquals(turn.askerEmail, "c@example.com");
  assertEquals(turn.answererEmail, "d@example.com");
});

Deno.test("legacy Questions anchors the current pair and freezes remaining players once", () => {
  const turn = reconcileQuestionTurn({
    activePlayers: players,
    rawState: "",
    currentAskerEmail: "c@example.com",
    currentAnswererEmail: "a@example.com",
    randomIndex: deterministicRandom([0]),
  });

  assertEquals(turn.state.order, [
    "c@example.com",
    "a@example.com",
    "d@example.com",
    "b@example.com",
  ]);
  assertEquals(turn.askerEmail, "c@example.com");
  assertEquals(turn.answererEmail, "a@example.com");
});

Deno.test("roster reconciliation preserves survivor order and repairs either side of the pair", () => {
  const rawState = encodeQuestionTurnOrderState(questionTurnOrderState([
    "a@example.com",
    "b@example.com",
    "c@example.com",
    "d@example.com",
  ]));

  const withoutAsker = reconcileQuestionTurn({
    activePlayers: players.filter((player) => player.email !== "b@example.com"),
    rawState,
    currentAskerEmail: "b@example.com",
    currentAnswererEmail: "c@example.com",
  });
  assertEquals(withoutAsker.state.order, [
    "a@example.com",
    "c@example.com",
    "d@example.com",
  ]);
  assertEquals(withoutAsker.askerEmail, "c@example.com");
  assertEquals(withoutAsker.answererEmail, "d@example.com");

  const withoutAnswerer = questionRosterChangePatch({
    activePlayers: players.filter((player) => player.email !== "c@example.com"),
    rawState,
    currentAskerEmail: "b@example.com",
    currentAnswererEmail: "c@example.com",
  });
  assertEquals(withoutAnswerer.current_asker_email, "b@example.com");
  assertEquals(withoutAnswerer.current_answerer_email, "d@example.com");
  assertEquals(withoutAnswerer.question_phase, "asking");
  assertEquals(
    parseQuestionTurnOrderState(withoutAnswerer.current_answer).order,
    ["a@example.com", "b@example.com", "d@example.com"],
  );
});

Deno.test("results roster repair preserves the boundary and Continue advances once", () => {
  const rawState = encodeQuestionTurnOrderState(questionTurnOrderState([
    "a@example.com",
    "b@example.com",
    "c@example.com",
    "d@example.com",
  ]));

  const answererLeft = questionRosterChangePatch({
    activePlayers: players.filter((player) => player.email !== "d@example.com"),
    rawState,
    currentAskerEmail: "c@example.com",
    currentAnswererEmail: "d@example.com",
    questionPhase: "results",
  });
  assertEquals(answererLeft.current_asker_email, "c@example.com");
  assertEquals(answererLeft.current_answerer_email, "a@example.com");
  assertEquals("question_phase" in answererLeft, false);
  const afterAnswererLeft = advanceQuestionTurn({
    activePlayers: players.filter((player) => player.email !== "d@example.com"),
    rawState: answererLeft.current_answer,
    currentAskerEmail: answererLeft.current_asker_email,
    currentAnswererEmail: answererLeft.current_answerer_email,
  });
  assertEquals(afterAnswererLeft.askerEmail, "a@example.com");
  assertEquals(afterAnswererLeft.answererEmail, "b@example.com");

  const askerLeft = questionRosterChangePatch({
    activePlayers: players.filter((player) => player.email !== "c@example.com"),
    rawState,
    currentAskerEmail: "c@example.com",
    currentAnswererEmail: "d@example.com",
    questionPhase: "results",
  });
  assertEquals(askerLeft.current_asker_email, "b@example.com");
  assertEquals(askerLeft.current_answerer_email, "d@example.com");
  assertEquals("question_phase" in askerLeft, false);
  const afterAskerLeft = advanceQuestionTurn({
    activePlayers: players.filter((player) => player.email !== "c@example.com"),
    rawState: askerLeft.current_answer,
    currentAskerEmail: askerLeft.current_asker_email,
    currentAnswererEmail: askerLeft.current_answerer_email,
  });
  assertEquals(afterAskerLeft.askerEmail, "d@example.com");
  assertEquals(afterAskerLeft.answererEmail, "a@example.com");
});

Deno.test("Questions state ignores malformed and Association payloads", () => {
  assertEquals(parseQuestionTurnOrderState("not-json").order, []);
  assertEquals(
    parseQuestionTurnOrderState(JSON.stringify({
      spoken: [],
      spinning: true,
      order: ["a@example.com"],
    })).order,
    [],
  );
});

Deno.test("Questions start rejects undersized rosters and invalid RNG output", () => {
  assertThrows(
    () =>
      initialQuestionTurn({
        activePlayers: players.slice(0, 1),
        currentAskerEmail: "a@example.com",
        currentAnswererEmail: "b@example.com",
      }),
    Error,
    "Need at least 2 active operatives",
  );
  assertThrows(
    () =>
      initialQuestionTurn({
        activePlayers: players,
        currentAskerEmail: "a@example.com",
        currentAnswererEmail: "b@example.com",
        randomIndex: () => 99,
      }),
    RangeError,
    "Random index is outside the requested range",
  );
});

Deno.test("gameRoomAction persists the Questions order through start, continue, leave, and ejection", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const arm = source.slice(
    source.indexOf("async function armRoulette"),
    source.indexOf("async function enqueueCommittedGameStart"),
  );
  const committedRetry = arm.indexOf(
    'if (status === "roulette" && canonicalSpyEmails(room).length)',
  );
  const shuffle = arm.indexOf(
    "initialQuestionTurn({",
  );
  const commit = arm.indexOf("return await updateRoom(base44, room");
  assert(
    committedRetry >= 0 && committedRetry < shuffle && shuffle < commit,
    "a committed arm retry must return before a Questions order can be rerolled",
  );
  assertStringIncludes(
    arm,
    "current_answer: encodeQuestionTurnOrderState(initialQuestion.state)",
  );
  assertStringIncludes(
    arm,
    "currentAskerEmail: startPayload?.current_asker_email",
  );
  assertStringIncludes(
    arm,
    "currentAnswererEmail: startPayload?.current_answerer_email",
  );
  assertStringIncludes(
    arm,
    "roulette_target_email: initialQuestion?.askerEmail || target",
  );
  assertEquals(
    arm.includes("players:"),
    false,
    "Questions order must not be persisted by reordering the canonical roster",
  );

  const continuation = source.slice(
    source.indexOf("async function continueRound"),
    source.indexOf("async function requestVote"),
  );
  assertStringIncludes(continuation, "questionContinueTurnPatch(");
  assertStringIncludes(
    continuation,
    'assertRoundActionMode(room, "questions")',
  );
  assertStringIncludes(
    continuation,
    "assertActiveRoundActor(activePlayers(room), user.email)",
  );

  const advanceQuestion = source.slice(
    source.indexOf("async function advanceQuestion"),
    source.indexOf("async function advanceAssociation"),
  );
  assertStringIncludes(
    advanceQuestion,
    'assertRoundActionMode(room, "questions")',
  );

  const advanceAssociation = source.slice(
    source.indexOf("async function advanceAssociation"),
    source.indexOf("async function startAssociation"),
  );
  assertStringIncludes(
    advanceAssociation,
    'assertRoundActionMode(room, "associations")',
  );

  const ejection = source.slice(
    source.indexOf("async function castDetectiveVote"),
    source.indexOf("async function submitSpyGuess"),
  );
  assertStringIncludes(ejection, "questionRosterChangePatch({");
  assertStringIncludes(ejection, "questionPhase: latest.question_phase");
});

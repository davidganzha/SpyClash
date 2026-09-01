import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  questionAdvancePatch,
  questionContinueTurnPatch,
} from "./question-round-policy.ts";
import {
  encodeQuestionTurnOrderState,
  questionTurnOrderState,
} from "./question-turn-order.ts";

const players = [
  { email: "a@example.com" },
  { email: "b@example.com" },
  { email: "c@example.com" },
];
const orderState = encodeQuestionTurnOrderState(questionTurnOrderState(
  players.map((player) => player.email),
));

Deno.test("answer confirmation advances directly to the next pair", () => {
  assertEquals(
    questionAdvancePatch({
      current_asker_email: "a@example.com",
      current_answerer_email: "b@example.com",
      current_answer: orderState,
      questions_in_round: 2,
      countdown_started_at: "2026-08-06T12:00:00.000Z",
    }, players),
    {
      current_asker_email: "b@example.com",
      current_answerer_email: "c@example.com",
      questions_in_round: 3,
      current_answer: orderState,
      question_phase: "asking",
      countdown_started_at: null,
    },
  );
});

Deno.test("eighth confirmed answer enters results without a countdown", () => {
  assertEquals(
    questionAdvancePatch({
      current_asker_email: "c@example.com",
      current_answerer_email: "a@example.com",
      current_answer: orderState,
      questions_in_round: 7,
    }, players),
    { question_phase: "results", countdown_started_at: null },
  );
});

Deno.test("continue after the eighth answer advances exactly once before the next round", () => {
  const lastAnswerer = "a@example.com";
  const room = {
    current_asker_email: "c@example.com",
    current_answerer_email: lastAnswerer,
    current_answer: orderState,
    questions_in_round: 7,
  };
  const resultsPatch = questionAdvancePatch(room, players);
  const continuePatch = questionContinueTurnPatch(
    { ...room, ...resultsPatch },
    players,
  );

  assertEquals(resultsPatch, {
    question_phase: "results",
    countdown_started_at: null,
  });
  assertEquals(continuePatch, {
    current_asker_email: "a@example.com",
    current_answerer_email: "b@example.com",
    current_answer: orderState,
  });
  assertEquals(continuePatch.current_answerer_email === lastAnswerer, false);
});

Deno.test("question progression requires two active players", async () => {
  await assertRejects(
    async () => questionAdvancePatch({}, players.slice(0, 1)),
    Error,
    "Need at least 2 active operatives",
  );
});

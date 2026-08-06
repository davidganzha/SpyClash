import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { questionAdvancePatch } from "./question-round-policy.ts";

const players = [
  { email: "a@example.com" },
  { email: "b@example.com" },
  { email: "c@example.com" },
];

Deno.test("answer confirmation advances directly to the next pair", () => {
  assertEquals(
    questionAdvancePatch({
      current_answerer_email: "b@example.com",
      questions_in_round: 2,
      countdown_started_at: "2026-08-06T12:00:00.000Z",
    }, players),
    {
      current_asker_email: "b@example.com",
      current_answerer_email: "c@example.com",
      questions_in_round: 3,
      current_answer: "",
      question_phase: "asking",
      countdown_started_at: null,
    },
  );
});

Deno.test("eighth confirmed answer enters results without a countdown", () => {
  assertEquals(
    questionAdvancePatch({ questions_in_round: 7 }, players),
    { question_phase: "results", countdown_started_at: null },
  );
});

Deno.test("question progression requires two active players", async () => {
  await assertRejects(
    async () => questionAdvancePatch({}, players.slice(0, 1)),
    Error,
    "Need at least 2 active operatives",
  );
});

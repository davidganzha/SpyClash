import {
  advanceQuestionTurn,
  encodeQuestionTurnOrderState,
} from "./question-turn-order.ts";

type Entity = Record<string, any>;

export function questionAdvancePatch(
  room: Entity,
  activePlayers: Entity[],
): Entity {
  if (activePlayers.length < 2) {
    throw Object.assign(new Error("Need at least 2 active operatives"), {
      status: 400,
    });
  }

  const currentCount = Number(room.questions_in_round);
  const nextQuestions =
    (Number.isInteger(currentCount) && currentCount >= 0 ? currentCount : 0) +
    1;
  if (nextQuestions >= 8) {
    return {
      question_phase: "results",
      countdown_started_at: null,
    };
  }

  const turn = advanceQuestionTurn({
    activePlayers,
    rawState: room.current_answer,
    currentAskerEmail: room.current_asker_email,
    currentAnswererEmail: room.current_answerer_email,
  });

  return {
    current_asker_email: turn.askerEmail,
    current_answerer_email: turn.answererEmail,
    questions_in_round: nextQuestions,
    current_answer: encodeQuestionTurnOrderState(turn.state),
    question_phase: "asking",
    countdown_started_at: null,
  };
}

export function questionContinueTurnPatch(
  room: Entity,
  activePlayers: Entity[],
): Entity {
  const turn = advanceQuestionTurn({
    activePlayers,
    rawState: room.current_answer,
    currentAskerEmail: room.current_asker_email,
    currentAnswererEmail: room.current_answerer_email,
  });
  return {
    current_asker_email: turn.askerEmail,
    current_answerer_email: turn.answererEmail,
    current_answer: encodeQuestionTurnOrderState(turn.state),
  };
}

type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

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
  const nextQuestions = (Number.isInteger(currentCount) && currentCount >= 0
    ? currentCount
    : 0) + 1;
  if (nextQuestions >= 8) {
    return {
      question_phase: "results",
      countdown_started_at: null,
    };
  }

  const currentAnswererIndex = Math.max(
    0,
    activePlayers.findIndex((player) =>
      clean(player?.email) === clean(room.current_answerer_email)
    ),
  );
  const nextAskerIndex = currentAnswererIndex;
  let nextAnswererIndex = (currentAnswererIndex + 1) % activePlayers.length;
  if (nextAnswererIndex === nextAskerIndex) {
    nextAnswererIndex = (nextAnswererIndex + 1) % activePlayers.length;
  }

  return {
    current_asker_email: clean(activePlayers[nextAskerIndex]?.email),
    current_answerer_email: clean(activePlayers[nextAnswererIndex]?.email),
    questions_in_round: nextQuestions,
    current_answer: "",
    question_phase: "asking",
    countdown_started_at: null,
  };
}

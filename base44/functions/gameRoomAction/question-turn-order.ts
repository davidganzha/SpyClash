type Entity = Record<string, unknown>;

export const QUESTION_TURN_ORDER_KIND = "question_turn_order_v1";

export type QuestionTurnOrderState = {
  kind: typeof QUESTION_TURN_ORDER_KIND;
  order: string[];
};

export type QuestionTurn = {
  askerEmail: string;
  answererEmail: string;
  state: QuestionTurnOrderState;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function key(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function uniqueEmails(values: readonly unknown[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const email = clean(value);
    const emailKey = key(email);
    if (!emailKey || seen.has(emailKey)) continue;
    seen.add(emailKey);
    result.push(email);
  }
  return result;
}

function activeEmails(activePlayers: Entity[]): string[] {
  return uniqueEmails(activePlayers.map((player) => player?.email));
}

function secureRandomIndex(exclusiveUpperBound: number): number {
  if (!Number.isSafeInteger(exclusiveUpperBound) || exclusiveUpperBound <= 0) {
    throw new RangeError("Random upper bound must be a positive integer");
  }
  const range = 0x1_0000_0000;
  const limit = Math.floor(range / exclusiveUpperBound) * exclusiveUpperBound;
  const word = new Uint32Array(1);
  do crypto.getRandomValues(word); while (word[0] >= limit);
  return word[0] % exclusiveUpperBound;
}

function shuffled<T>(
  values: readonly T[],
  randomIndex: (exclusiveUpperBound: number) => number,
): T[] {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const swapIndex = randomIndex(index + 1);
    if (
      !Number.isSafeInteger(swapIndex) || swapIndex < 0 || swapIndex > index
    ) {
      throw new RangeError("Random index is outside the requested range");
    }
    [result[index], result[swapIndex]] = [
      result[swapIndex],
      result[index],
    ];
  }
  return result;
}

function state(order: readonly unknown[]): QuestionTurnOrderState {
  return {
    kind: QUESTION_TURN_ORDER_KIND,
    order: uniqueEmails(order),
  };
}

export function parseQuestionTurnOrderState(
  raw: unknown,
): QuestionTurnOrderState {
  try {
    const parsed = JSON.parse(String(raw || ""));
    if (parsed?.kind !== QUESTION_TURN_ORDER_KIND) return state([]);
    return state(Array.isArray(parsed?.order) ? parsed.order : []);
  } catch {
    return state([]);
  }
}

export function encodeQuestionTurnOrderState(
  value: Partial<QuestionTurnOrderState>,
): string {
  return JSON.stringify(state(Array.isArray(value.order) ? value.order : []));
}

export function questionTurnOrderState(
  orderedEmails: readonly unknown[],
): QuestionTurnOrderState {
  return state(orderedEmails);
}

function pairForOrder(
  order: string[],
  askerEmailValue?: unknown,
  answererEmailValue?: unknown,
): { askerEmail: string; answererEmail: string } {
  if (!order.length) return { askerEmail: "", answererEmail: "" };
  if (order.length === 1) {
    return { askerEmail: order[0], answererEmail: "" };
  }

  const askerKey = key(askerEmailValue);
  const answererKey = key(answererEmailValue);
  const askerIndex = order.findIndex((email) => key(email) === askerKey);
  const answererIndex = order.findIndex((email) => key(email) === answererKey);
  if (
    askerIndex >= 0 && answererIndex >= 0 && askerIndex !== answererIndex &&
    (askerIndex + 1) % order.length === answererIndex
  ) {
    return {
      askerEmail: order[askerIndex],
      answererEmail: order[answererIndex],
    };
  }

  // If the asker left, the previous answerer owns the next question. Otherwise
  // keep the current asker and repair only their successor.
  const resolvedAskerIndex = askerIndex >= 0
    ? askerIndex
    : answererIndex >= 0
    ? answererIndex
    : 0;
  return {
    askerEmail: order[resolvedAskerIndex],
    answererEmail: order[(resolvedAskerIndex + 1) % order.length],
  };
}

export function initialQuestionTurn(input: {
  activePlayers: Entity[];
  currentAskerEmail: unknown;
  currentAnswererEmail: unknown;
  randomIndex?: (exclusiveUpperBound: number) => number;
}): QuestionTurn {
  const emails = activeEmails(input.activePlayers);
  if (emails.length < 2) {
    throw Object.assign(new Error("Need at least 2 active operatives"), {
      status: 400,
    });
  }
  const activeByKey = new Map(emails.map((email) => [key(email), email]));
  const askerEmail = activeByKey.get(key(input.currentAskerEmail));
  const answererEmail = activeByKey.get(key(input.currentAnswererEmail));
  if (!askerEmail || !answererEmail || key(askerEmail) === key(answererEmail)) {
    throw Object.assign(
      new Error("Question vector must use two active operatives"),
      { status: 400 },
    );
  }

  // Preserve the client-selected visible roulette pair for compatibility,
  // then securely shuffle the remaining players once to freeze the cycle.
  const pairKeys = new Set([key(askerEmail), key(answererEmail)]);
  const remaining = emails.filter((email) => !pairKeys.has(key(email)));
  const order = [
    askerEmail,
    answererEmail,
    ...shuffled(remaining, input.randomIndex ?? secureRandomIndex),
  ];
  return {
    askerEmail,
    answererEmail,
    state: state(order),
  };
}

export function reconcileQuestionTurn(input: {
  activePlayers: Entity[];
  rawState: unknown;
  currentAskerEmail?: unknown;
  currentAnswererEmail?: unknown;
  randomIndex?: (exclusiveUpperBound: number) => number;
}): QuestionTurn {
  const emails = activeEmails(input.activePlayers);
  const activeByKey = new Map(emails.map((email) => [key(email), email]));
  const parsed = parseQuestionTurnOrderState(input.rawState);
  const retained: string[] = [];
  const retainedKeys = new Set<string>();

  for (const storedEmail of parsed.order) {
    const storedKey = key(storedEmail);
    const activeEmail = activeByKey.get(storedKey);
    if (!activeEmail || retainedKeys.has(storedKey)) continue;
    retainedKeys.add(storedKey);
    retained.push(activeEmail);
  }

  let order = retained;
  if (!order.length && emails.length) {
    const asker = activeByKey.get(key(input.currentAskerEmail));
    const answerer = activeByKey.get(key(input.currentAnswererEmail));
    const anchored = uniqueEmails([asker, answerer]);
    const anchoredKeys = new Set(anchored.map(key));
    const remaining = emails.filter((email) => !anchoredKeys.has(key(email)));
    order = [
      ...anchored,
      ...shuffled(remaining, input.randomIndex ?? secureRandomIndex),
    ];
  } else {
    // Active rooms cannot normally gain players. Appending an unexpected legacy
    // member without reshuffling keeps every already-frozen relative position.
    order = [
      ...order,
      ...emails.filter((email) => !retainedKeys.has(key(email))),
    ];
  }

  const pair = pairForOrder(
    order,
    input.currentAskerEmail,
    input.currentAnswererEmail,
  );
  return { ...pair, state: state(order) };
}

export function advanceQuestionTurn(input: {
  activePlayers: Entity[];
  rawState: unknown;
  currentAskerEmail?: unknown;
  currentAnswererEmail?: unknown;
  randomIndex?: (exclusiveUpperBound: number) => number;
}): QuestionTurn {
  const current = reconcileQuestionTurn(input);
  const order = current.state.order;
  if (order.length < 2) {
    throw Object.assign(new Error("Need at least 2 active operatives"), {
      status: 400,
    });
  }
  const answererIndex = order.findIndex((email) =>
    key(email) === key(current.answererEmail)
  );
  const nextAskerIndex = answererIndex >= 0 ? answererIndex : 0;
  return {
    askerEmail: order[nextAskerIndex],
    answererEmail: order[(nextAskerIndex + 1) % order.length],
    state: current.state,
  };
}

export function questionRosterChangePatch(input: {
  activePlayers: Entity[];
  currentAskerEmail?: unknown;
  currentAnswererEmail?: unknown;
  questionPhase?: unknown;
  rawState: unknown;
  randomIndex?: (exclusiveUpperBound: number) => number;
}): Record<string, unknown> {
  let turn = reconcileQuestionTurn(input);
  const isResults = key(input.questionPhase) === "results";
  const order = turn.state.order;
  const currentAskerIndex = order.findIndex((email) =>
    key(email) === key(input.currentAskerEmail)
  );
  const currentAnswererIndex = order.findIndex((email) =>
    key(email) === key(input.currentAnswererEmail)
  );

  if (
    isResults && currentAskerIndex < 0 && currentAnswererIndex >= 0 &&
    order.length >= 2
  ) {
    // Results still represent the already-completed pair. If its asker leaves,
    // retain the surviving answerer on the right side so Continue promotes that
    // player exactly once instead of skipping them in the preserved cycle.
    turn = {
      askerEmail:
        order[(currentAnswererIndex - 1 + order.length) % order.length],
      answererEmail: order[currentAnswererIndex],
      state: turn.state,
    };
  }

  const vectorChanged = key(turn.askerEmail) !== key(input.currentAskerEmail) ||
    key(turn.answererEmail) !== key(input.currentAnswererEmail);
  return {
    current_asker_email: turn.askerEmail,
    current_answerer_email: turn.answererEmail,
    current_answer: encodeQuestionTurnOrderState(turn.state),
    ...(vectorChanged && !isResults
      ? {
        question_phase: "asking",
        current_answer_feedback: null,
        countdown_started_at: null,
      }
      : {}),
  };
}

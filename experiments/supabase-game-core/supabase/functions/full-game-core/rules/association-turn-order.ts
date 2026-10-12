type Entity = Record<string, unknown>;

export type AssociationTurnState = {
  spoken: string[];
  spinning: boolean;
  order: string[];
};

export type AssociationRosterChangeResult = {
  patch: Record<string, unknown>;
  startsNewRound: boolean;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function key(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function uniqueActiveEmails(activePlayers: Entity[]): string[] {
  const seen = new Set<string>();
  const emails: string[] = [];
  for (const player of activePlayers) {
    const email = clean(player?.email);
    const emailKey = key(email);
    if (!emailKey || seen.has(emailKey)) continue;
    seen.add(emailKey);
    emails.push(email);
  }
  return emails;
}

function shuffled<T>(values: T[], random: () => number): T[] {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const sample = Math.min(Math.max(Number(random()) || 0, 0), 0.999999999);
    const swapIndex = Math.floor(sample * (index + 1));
    [result[index], result[swapIndex]] = [
      result[swapIndex],
      result[index],
    ];
  }
  return result;
}

function reconciledOrder(
  storedOrder: string[],
  activeEmails: string[],
  random: () => number,
  currentSpeakerEmail?: unknown,
): string[] {
  const activeByKey = new Map(activeEmails.map((email) => [key(email), email]));
  const seen = new Set<string>();
  const retained: string[] = [];

  for (const storedEmail of storedOrder) {
    const storedKey = key(storedEmail);
    const activeEmail = activeByKey.get(storedKey);
    if (!activeEmail || seen.has(storedKey)) continue;
    seen.add(storedKey);
    retained.push(activeEmail);
  }

  if (!retained.length) {
    const currentKey = key(currentSpeakerEmail);
    const current = activeEmails.find((email) => key(email) === currentKey);
    return current
      ? [
        current,
        ...shuffled(
          activeEmails.filter((email) => key(email) !== currentKey),
          random,
        ),
      ]
      : shuffled(activeEmails, random);
  }

  for (const activeEmail of activeEmails) {
    const activeKey = key(activeEmail);
    if (seen.has(activeKey)) continue;
    seen.add(activeKey);
    retained.push(activeEmail);
  }
  return retained;
}

export function parseAssociationTurnState(raw: unknown): AssociationTurnState {
  try {
    const parsed = JSON.parse(String(raw || ""));
    return {
      spoken: Array.isArray(parsed?.spoken)
        ? parsed.spoken.map(clean).filter(Boolean)
        : [],
      spinning: Boolean(parsed?.spinning),
      order: Array.isArray(parsed?.order)
        ? parsed.order.map(clean).filter(Boolean)
        : [],
    };
  } catch {
    return { spoken: [], spinning: false, order: [] };
  }
}

export function encodeAssociationTurnState(
  state: Partial<AssociationTurnState>,
): string {
  return JSON.stringify({
    spoken: Array.isArray(state.spoken) ? state.spoken : [],
    spinning: Boolean(state.spinning),
    order: Array.isArray(state.order) ? state.order : [],
  });
}

export function initialAssociationTurn(input: {
  activePlayers: Entity[];
  random?: () => number;
}): { speakerEmail: string; state: AssociationTurnState } {
  const activeEmails = uniqueActiveEmails(input.activePlayers);
  if (!activeEmails.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }
  const order = shuffled(activeEmails, input.random ?? Math.random);
  return {
    speakerEmail: order[0],
    state: { spoken: [], spinning: true, order },
  };
}

export function reconcileAssociationTurnState(input: {
  activePlayers: Entity[];
  rawState: unknown;
  currentSpeakerEmail?: unknown;
  random?: () => number;
}): AssociationTurnState {
  const activeEmails = uniqueActiveEmails(input.activePlayers);
  if (!activeEmails.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }
  const parsed = parseAssociationTurnState(input.rawState);
  const order = reconciledOrder(
    parsed.order,
    activeEmails,
    input.random ?? Math.random,
    input.currentSpeakerEmail,
  );
  const spokenKeys = new Set(parsed.spoken.map(key));
  return {
    spoken: order.filter((email) => spokenKeys.has(key(email))),
    spinning: parsed.spinning,
    order,
  };
}

export function advanceAssociationTurn(input: {
  activePlayers: Entity[];
  currentSpeakerEmail: unknown;
  rawState: unknown;
  random?: () => number;
}): {
  speakerEmail: string;
  startsNewRound: boolean;
  state: AssociationTurnState;
} {
  const activeEmails = uniqueActiveEmails(input.activePlayers);
  if (!activeEmails.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }

  const parsed = reconcileAssociationTurnState({
    activePlayers: input.activePlayers,
    rawState: input.rawState,
    currentSpeakerEmail: input.currentSpeakerEmail,
    random: input.random,
  });
  let order = parsed.order;
  const activeKeys = new Set(activeEmails.map(key));
  const spokenKeys = new Set(
    parsed.spoken.map(key).filter((emailKey) => activeKeys.has(emailKey)),
  );
  const currentKey = key(input.currentSpeakerEmail);
  if (activeKeys.has(currentKey)) spokenKeys.add(currentKey);

  const remaining = order.filter((email) => !spokenKeys.has(key(email)));
  const startsNewRound = remaining.length === 0;

  if (startsNewRound && order.length > 1 && key(order[0]) === currentKey) {
    const nextIndex = order.findIndex((email) => key(email) !== currentKey);
    order = [...order.slice(nextIndex), ...order.slice(0, nextIndex)];
  }

  const speakerEmail = startsNewRound ? order[0] : remaining[0];
  return {
    speakerEmail,
    startsNewRound,
    state: {
      spoken: startsNewRound
        ? []
        : order.filter((email) => spokenKeys.has(key(email))),
      spinning: true,
      order,
    },
  };
}

export function associationRosterChangePatch(input: {
  activePlayers: Entity[];
  currentSpeakerEmail: unknown;
  currentAnswererEmail?: unknown;
  rawState: unknown;
  random?: () => number;
}): AssociationRosterChangeResult {
  const activeEmails = uniqueActiveEmails(input.activePlayers);
  if (!activeEmails.length) {
    throw Object.assign(new Error("Need active operatives"), { status: 400 });
  }
  const activeByKey = new Map(activeEmails.map((email) => [key(email), email]));
  const parsed = parseAssociationTurnState(input.rawState);
  const state = reconcileAssociationTurnState({
    activePlayers: input.activePlayers,
    rawState: input.rawState,
    currentSpeakerEmail: input.currentSpeakerEmail,
    random: input.random,
  });
  const currentKey = key(input.currentSpeakerEmail);
  const retainedCurrent = activeByKey.get(currentKey);
  let speakerEmail = retainedCurrent || "";
  if (!speakerEmail && parsed.order.length) {
    const previousIndex = parsed.order.findIndex((email) =>
      key(email) === currentKey
    );
    if (previousIndex >= 0) {
      for (let offset = 1; offset <= parsed.order.length; offset += 1) {
        const candidate = activeByKey.get(
          key(parsed.order[(previousIndex + offset) % parsed.order.length]),
        );
        if (candidate) {
          speakerEmail = candidate;
          break;
        }
      }
    }
  }
  speakerEmail ||= state.order[0];

  const spokenKeys = new Set(state.spoken.map(key));
  const startsNewRound = !retainedCurrent &&
    state.order.every((email) => spokenKeys.has(key(email)));
  if (startsNewRound) speakerEmail = state.order[0];

  const answererKey = key(input.currentAnswererEmail);
  const retainedAnswerer = activeByKey.get(answererKey);
  const answererEmail = retainedAnswerer && key(retainedAnswerer) !==
      key(speakerEmail)
    ? retainedAnswerer
    : activeEmails.find((email) => key(email) !== key(speakerEmail)) || "";
  const speakerChanged = key(speakerEmail) !== currentKey;
  const answererChanged = key(answererEmail) !== answererKey;
  const nextState = {
    ...state,
    spoken: startsNewRound ? [] : state.spoken,
    spinning: speakerChanged ? true : state.spinning,
  };

  return {
    startsNewRound,
    patch: {
      current_asker_email: speakerEmail,
      current_answerer_email: answererEmail,
      current_answer: encodeAssociationTurnState(nextState),
      ...(speakerChanged || answererChanged
        ? {
          question_phase: "asking",
          current_answer_feedback: null,
          countdown_started_at: null,
        }
        : {}),
    },
  };
}

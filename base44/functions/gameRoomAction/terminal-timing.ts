export const TERMINAL_PHASES = [
  "terminal_claim",
  "push_enqueue",
  "history_archive",
  "room_commit",
  "push_commit",
] as const;

export type TerminalPhase = (typeof TERMINAL_PHASES)[number];
export type TimingOutcome = "completed" | "failed";

export const SPY_GUESS_SIDE_EFFECT_PHASES = [
  "profile_repair",
  "push_function_invoke",
  "signal_fanout",
] as const;

export type SpyGuessSideEffectPhase =
  (typeof SPY_GUESS_SIDE_EFFECT_PHASES)[number];

const opaqueTimingIDPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const phaseField = {
  terminal_claim: "terminal_claim_ms",
  push_enqueue: "push_enqueue_ms",
  history_archive: "history_archive_ms",
  room_commit: "room_commit_ms",
  push_commit: "push_commit_ms",
} as const;

const sideEffectField = {
  profile_repair: "profile_repair_ms",
  push_function_invoke: "push_function_invoke_ms",
  signal_fanout: "signal_fanout_ms",
} as const;

type TerminalTimingFields = Record<
  (typeof phaseField)[TerminalPhase],
  number
>;

export type SpyGuessSideEffectTimingFields = Record<
  (typeof sideEffectField)[SpyGuessSideEffectPhase],
  number
>;

function safeNow(clock: () => number, fallback: number) {
  try {
    const value = Number(clock());
    return Number.isFinite(value) ? value : fallback;
  } catch {
    return fallback;
  }
}

function elapsedMS(startedAt: number, completedAt: number) {
  return Math.max(0, Math.round(completedAt - startedAt));
}

export function normalizeOpaqueTimingID(value: unknown) {
  const candidate = typeof value === "string" ? value.trim().toLowerCase() : "";
  return opaqueTimingIDPattern.test(candidate) ? candidate : "";
}

export function createOpaqueTimingID(
  randomUUID: () => string = () => crypto.randomUUID(),
) {
  try {
    return normalizeOpaqueTimingID(randomUUID());
  } catch {
    return "";
  }
}

function emptyTerminalTimings(): TerminalTimingFields {
  return {
    terminal_claim_ms: 0,
    push_enqueue_ms: 0,
    history_archive_ms: 0,
    room_commit_ms: 0,
    push_commit_ms: 0,
  };
}

function emptySpyGuessSideEffectTimings(): SpyGuessSideEffectTimingFields {
  return {
    profile_repair_ms: 0,
    push_function_invoke_ms: 0,
    signal_fanout_ms: 0,
  };
}

export function createSpyGuessSideEffectTiming(
  clock: () => number = () => performance.now(),
) {
  const timings = emptySpyGuessSideEffectTimings();
  const activeStartedAt = new Map<SpyGuessSideEffectPhase, number>();

  return {
    begin(phase: SpyGuessSideEffectPhase) {
      activeStartedAt.set(phase, safeNow(clock, 0));
    },

    complete(phase: SpyGuessSideEffectPhase) {
      const startedAt = activeStartedAt.get(phase);
      if (startedAt === undefined) return;
      const completedAt = safeNow(clock, startedAt);
      const field = sideEffectField[phase];
      timings[field] += elapsedMS(startedAt, completedAt);
      activeStartedAt.delete(phase);
    },

    snapshot() {
      const reportedAt = safeNow(clock, 0);
      const snapshot = { ...timings };
      for (const [phase, startedAt] of activeStartedAt) {
        snapshot[sideEffectField[phase]] += elapsedMS(startedAt, reportedAt);
      }
      return snapshot;
    },
  };
}

export function createTerminalPhaseTiming(
  clock: () => number = () => performance.now(),
) {
  const startedAt = safeNow(clock, 0);
  const timings = emptyTerminalTimings();
  let activePhase: TerminalPhase | null = null;
  let activeStartedAt = startedAt;

  return {
    begin(phase: TerminalPhase) {
      activeStartedAt = safeNow(clock, activeStartedAt);
      activePhase = phase;
    },

    complete(phase: TerminalPhase) {
      if (activePhase !== phase) return;
      const completedAt = safeNow(clock, activeStartedAt);
      timings[phaseField[phase]] = elapsedMS(activeStartedAt, completedAt);
      activePhase = null;
    },

    report(
      outcome: TimingOutcome,
      playerCount: number,
      timingIDValue?: unknown,
    ) {
      const reportedAt = safeNow(clock, startedAt);
      const snapshot = { ...timings };
      if (activePhase) {
        snapshot[phaseField[activePhase]] = elapsedMS(
          activeStartedAt,
          reportedAt,
        );
      }
      const timingID = normalizeOpaqueTimingID(timingIDValue);
      return {
        ...(timingID ? { timing_id: timingID } : {}),
        ...snapshot,
        total_ms: elapsedMS(startedAt, reportedAt),
        player_count: Math.max(0, Math.round(Number(playerCount) || 0)),
        outcome,
        failed_phase: outcome === "failed" ? activePhase || "unknown" : "",
      };
    },
  };
}

export function spyGuessResponseTiming(input: {
  timingID?: unknown;
  requestStartedAt: number;
  actionStartedAt: number;
  actionCompletedAt: number;
  responseReadyAt: number;
  postCommitSideEffectsMS: number;
  sideEffects?: Partial<SpyGuessSideEffectTimingFields>;
  outcome: TimingOutcome;
}) {
  const timingID = normalizeOpaqueTimingID(input.timingID);
  const sideEffects = input.sideEffects || {};
  return {
    ...(timingID ? { timing_id: timingID } : {}),
    pre_action_ms: elapsedMS(input.requestStartedAt, input.actionStartedAt),
    action_core_ms: elapsedMS(input.actionStartedAt, input.actionCompletedAt),
    profile_repair_ms: Math.max(
      0,
      Math.round(Number(sideEffects.profile_repair_ms) || 0),
    ),
    push_function_invoke_ms: Math.max(
      0,
      Math.round(Number(sideEffects.push_function_invoke_ms) || 0),
    ),
    signal_fanout_ms: Math.max(
      0,
      Math.round(Number(sideEffects.signal_fanout_ms) || 0),
    ),
    post_commit_side_effects_ms: Math.max(
      0,
      Math.round(Number(input.postCommitSideEffectsMS) || 0),
    ),
    total_ms: elapsedMS(input.requestStartedAt, input.responseReadyAt),
    outcome: input.outcome,
  };
}

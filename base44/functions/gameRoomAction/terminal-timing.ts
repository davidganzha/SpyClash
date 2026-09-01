export const TERMINAL_PHASES = [
  "terminal_claim",
  "push_enqueue",
  "history_archive",
  "room_commit",
  "push_commit",
] as const;

export type TerminalPhase = (typeof TERMINAL_PHASES)[number];
export type TimingOutcome = "completed" | "failed";

const phaseField = {
  terminal_claim: "terminal_claim_ms",
  push_enqueue: "push_enqueue_ms",
  history_archive: "history_archive_ms",
  room_commit: "room_commit_ms",
  push_commit: "push_commit_ms",
} as const;

type TerminalTimingFields = Record<
  (typeof phaseField)[TerminalPhase],
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

function emptyTerminalTimings(): TerminalTimingFields {
  return {
    terminal_claim_ms: 0,
    push_enqueue_ms: 0,
    history_archive_ms: 0,
    room_commit_ms: 0,
    push_commit_ms: 0,
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

    report(outcome: TimingOutcome, playerCount: number) {
      const reportedAt = safeNow(clock, startedAt);
      const snapshot = { ...timings };
      if (activePhase) {
        snapshot[phaseField[activePhase]] = elapsedMS(
          activeStartedAt,
          reportedAt,
        );
      }
      return {
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
  requestStartedAt: number;
  actionStartedAt: number;
  actionCompletedAt: number;
  responseReadyAt: number;
  postCommitSideEffectsMS: number;
  outcome: TimingOutcome;
}) {
  return {
    pre_action_ms: elapsedMS(input.requestStartedAt, input.actionStartedAt),
    action_core_ms: elapsedMS(input.actionStartedAt, input.actionCompletedAt),
    post_commit_side_effects_ms: Math.max(
      0,
      Math.round(Number(input.postCommitSideEffectsMS) || 0),
    ),
    total_ms: elapsedMS(input.requestStartedAt, input.responseReadyAt),
    outcome: input.outcome,
  };
}

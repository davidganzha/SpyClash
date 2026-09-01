export const PROCESS_EVENT_TIMING_PHASES = [
  "live_activity",
  "ordinary_push",
] as const;

export type ProcessEventTimingPhase =
  (typeof PROCESS_EVENT_TIMING_PHASES)[number];
export type ProcessEventTimingOutcome = "completed" | "failed";

const opaqueTimingIDPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const phaseField = {
  live_activity: "live_activity_ms",
  ordinary_push: "ordinary_push_ms",
} as const;

type ProcessEventTimingFields = Record<
  (typeof phaseField)[ProcessEventTimingPhase],
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

export function normalizeProcessEventTimingID(value: unknown) {
  const candidate = typeof value === "string" ? value.trim().toLowerCase() : "";
  return opaqueTimingIDPattern.test(candidate) ? candidate : "";
}

export function createProcessEventTiming(
  timingIDValue: unknown,
  clock: () => number = () => performance.now(),
) {
  const timingID = normalizeProcessEventTimingID(timingIDValue);
  const startedAt = safeNow(clock, 0);
  const timings: ProcessEventTimingFields = {
    live_activity_ms: 0,
    ordinary_push_ms: 0,
  };
  let activePhase: ProcessEventTimingPhase | null = null;
  let activeStartedAt = startedAt;

  return {
    timingID,

    begin(phase: ProcessEventTimingPhase) {
      activeStartedAt = safeNow(clock, activeStartedAt);
      activePhase = phase;
    },

    complete(phase: ProcessEventTimingPhase) {
      if (activePhase !== phase) return;
      const completedAt = safeNow(clock, activeStartedAt);
      timings[phaseField[phase]] += elapsedMS(activeStartedAt, completedAt);
      activePhase = null;
    },

    report(outcome: ProcessEventTimingOutcome) {
      const reportedAt = safeNow(clock, startedAt);
      const snapshot = { ...timings };
      if (activePhase) {
        snapshot[phaseField[activePhase]] += elapsedMS(
          activeStartedAt,
          reportedAt,
        );
      }
      return {
        timing_id: timingID,
        ...snapshot,
        total_ms: elapsedMS(startedAt, reportedAt),
        outcome,
        failed_phase: outcome === "failed" ? activePhase || "unknown" : "",
      };
    },
  };
}

type Room = Record<string, any>;

type TimerState = {
  startedAtMilliseconds: number;
  durationSeconds: number;
  pausedAtMilliseconds: number | null;
  pausedTotalSeconds: number;
};

export const PAUSE_BLOCKED_GAME_ACTIONS = [
  "mark_role_card_read",
  "advance_question",
  "advance_association",
  "start_association",
  "stop_association_spin",
  "mark_answer_heard",
  "continue_round",
  "request_vote",
  "cast_detective_vote",
  "submit_spy_guess",
] as const;

const pauseBlockedGameActions = new Set<string>(PAUSE_BLOCKED_GAME_ACTIONS);

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function timerError(
  message: string,
  status = 409,
  code = "invalid_game_timer",
) {
  return Object.assign(new Error(message), { status, code });
}

function parsedTimestamp(value: unknown, label: string): number {
  const timestamp = Date.parse(clean(value));
  if (!Number.isFinite(timestamp)) {
    throw timerError(`${label} is invalid.`, 409, "invalid_game_timer");
  }
  return timestamp;
}

function transitionTimestamp(value: unknown): {
  milliseconds: number;
  iso: string;
} {
  const iso = clean(value);
  const milliseconds = Date.parse(iso);
  if (!iso || !Number.isFinite(milliseconds)) {
    throw timerError(
      "The game timer transition timestamp is invalid.",
      400,
      "invalid_game_timer_timestamp",
    );
  }
  return { milliseconds, iso };
}

function timerState(room: Room): TimerState {
  const startedAtMilliseconds = parsedTimestamp(
    room?.game_started_at,
    "The game start timestamp",
  );
  const durationSeconds = Number(room?.game_duration_seconds);
  if (
    !Number.isInteger(durationSeconds) || durationSeconds < 60 ||
    durationSeconds > 900
  ) {
    throw timerError("The game duration is invalid.");
  }

  const pausedTotalSeconds = Number(room?.game_paused_total_seconds ?? 0);
  if (!Number.isInteger(pausedTotalSeconds) || pausedTotalSeconds < 0) {
    throw timerError("The accumulated game pause is invalid.");
  }

  const pausedAtValue = clean(room?.game_paused_at);
  const pausedAtMilliseconds = pausedAtValue
    ? parsedTimestamp(pausedAtValue, "The game pause timestamp")
    : null;
  if (
    pausedAtMilliseconds !== null &&
    pausedAtMilliseconds < startedAtMilliseconds
  ) {
    throw timerError("The game pause predates the game timer.");
  }

  return {
    startedAtMilliseconds,
    durationSeconds,
    pausedAtMilliseconds,
    pausedTotalSeconds,
  };
}

function requirePlayingRoom(room: Room): void {
  if (clean(room?.status || "waiting").toLocaleLowerCase() !== "playing") {
    throw timerError(
      "The game timer is not active.",
      409,
      "game_timer_inactive",
    );
  }
}

function requireHost(room: Room, actorEmailValue: unknown): void {
  if (
    !clean(actorEmailValue) ||
    clean(room?.host_email).toLocaleLowerCase() !==
      clean(actorEmailValue).toLocaleLowerCase()
  ) {
    throw timerError("Host access required", 403, "host_access_required");
  }
}

function roundedSeconds(value: number): number {
  // The public room contract decodes this field as an integer on iOS. Keep a
  // deterministic floor rule so accumulated pause can never exceed wall-clock
  // elapsed time; each host pause/resume cycle can shorten the freeze by <1s.
  return Math.floor(value);
}

export function assertGameActionAllowedWhilePaused(
  room: Room,
  actionValue: unknown,
): void {
  if (!clean(room?.game_paused_at)) return;
  if (!pauseBlockedGameActions.has(clean(actionValue))) return;
  throw timerError(
    "The game is paused. Resume the timer before continuing.",
    409,
    "game_paused",
  );
}

export function assertGameActionAllowedByDeadline(
  room: Room,
  actionValue: unknown,
  nowMilliseconds = Date.now(),
  postGameGuessSeconds = 30,
): void {
  if (
    clean(room?.status || "waiting").toLocaleLowerCase() !== "playing" ||
    !clean(room?.game_started_at) ||
    clean(room?.game_paused_at)
  ) {
    return;
  }

  const action = clean(actionValue);
  const state = timerState(room);
  const elapsedSeconds = gameActiveElapsedSeconds(room, nowMilliseconds);
  if (elapsedSeconds < state.durationSeconds) return;

  if (
    action === "submit_spy_guess" &&
    elapsedSeconds < state.durationSeconds + Math.max(0, postGameGuessSeconds)
  ) {
    return;
  }
  if (["finalize_expired_room", "finish_room", "leave_room"].includes(action)) {
    return;
  }

  throw timerError(
    "The game timer has elapsed.",
    409,
    "game_timer_elapsed",
  );
}

export function gameActiveElapsedSeconds(
  room: Room,
  nowMilliseconds = Date.now(),
): number {
  const state = timerState(room);
  if (!Number.isFinite(nowMilliseconds)) {
    throw timerError(
      "The server game clock is invalid.",
      400,
      "invalid_game_timer_timestamp",
    );
  }
  if (
    state.pausedAtMilliseconds !== null &&
    nowMilliseconds < state.pausedAtMilliseconds
  ) {
    throw timerError("The server clock predates the active game pause.");
  }

  const effectiveNow = state.pausedAtMilliseconds ?? nowMilliseconds;
  const elapsedSeconds = (effectiveNow - state.startedAtMilliseconds) / 1_000 -
    state.pausedTotalSeconds;
  if (elapsedSeconds < 0) {
    throw timerError("The accumulated pause exceeds elapsed game time.");
  }
  return elapsedSeconds;
}

export function gameTimerDeadlineMilliseconds(
  room: Room,
  nowMilliseconds = Date.now(),
  graceSeconds = 0,
): number {
  const state = timerState(room);
  if (!Number.isFinite(nowMilliseconds) || !Number.isFinite(graceSeconds)) {
    throw timerError(
      "The server game clock is invalid.",
      400,
      "invalid_game_timer_timestamp",
    );
  }
  if (
    state.pausedAtMilliseconds !== null &&
    nowMilliseconds < state.pausedAtMilliseconds
  ) {
    throw timerError("The server clock predates the active game pause.");
  }
  const currentPauseSeconds = state.pausedAtMilliseconds === null
    ? 0
    : Math.max(0, (nowMilliseconds - state.pausedAtMilliseconds) / 1_000);
  return state.startedAtMilliseconds +
    (
        state.durationSeconds + state.pausedTotalSeconds +
        currentPauseSeconds + Math.max(0, graceSeconds)
      ) * 1_000;
}

export function pauseGameTransitionPatch(
  room: Room,
  actorEmailValue: unknown,
  pausedAtValue = new Date().toISOString(),
): Room {
  requireHost(room, actorEmailValue);
  requirePlayingRoom(room);
  const state = timerState(room);
  if (state.pausedAtMilliseconds !== null) return {};

  const pausedAt = transitionTimestamp(pausedAtValue);
  if (pausedAt.milliseconds < state.startedAtMilliseconds) {
    throw timerError("The game pause predates the game timer.");
  }
  const elapsedSeconds = gameActiveElapsedSeconds(room, pausedAt.milliseconds);
  if (elapsedSeconds >= state.durationSeconds) {
    throw timerError(
      "The game timer has already elapsed.",
      409,
      "game_timer_elapsed",
    );
  }
  return { game_paused_at: pausedAt.iso };
}

export function resumeGameTransitionPatch(
  room: Room,
  actorEmailValue: unknown,
  resumedAtValue = new Date().toISOString(),
): Room {
  requireHost(room, actorEmailValue);
  requirePlayingRoom(room);
  const state = timerState(room);
  if (state.pausedAtMilliseconds === null) return {};

  const resumedAt = transitionTimestamp(resumedAtValue);
  if (resumedAt.milliseconds < state.pausedAtMilliseconds) {
    throw timerError("The game resume predates the active pause.");
  }
  const pauseSeconds = (resumedAt.milliseconds - state.pausedAtMilliseconds) /
    1_000;
  return {
    game_paused_at: null,
    game_paused_total_seconds: roundedSeconds(
      state.pausedTotalSeconds + pauseSeconds,
    ),
  };
}

export function finishGamePauseTransitionPatch(
  room: Room,
  finishedAtValue = new Date().toISOString(),
): Room {
  const state = timerState(room);
  if (state.pausedAtMilliseconds === null) return {};

  const finishedAt = transitionTimestamp(finishedAtValue);
  if (finishedAt.milliseconds < state.pausedAtMilliseconds) {
    throw timerError("The game finish predates the active pause.");
  }
  const pauseSeconds = (finishedAt.milliseconds - state.pausedAtMilliseconds) /
    1_000;
  return {
    game_paused_at: null,
    game_paused_total_seconds: roundedSeconds(
      state.pausedTotalSeconds + pauseSeconds,
    ),
  };
}

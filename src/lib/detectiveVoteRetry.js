import { gameTimerSnapshot } from "./gameRoomSync.js";

export const DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS = 8;
export const DETECTIVE_VOTE_RETRY_BUDGET_MILLISECONDS = 2_000;
const RETRY_INITIAL_DELAY_MILLISECONDS = 250;
const RETRY_DELAY_CAP_MILLISECONDS = 8_000;
const RECOVERY_BUDGET_EXHAUSTED_CODE = "detective_vote_recovery_budget_exhausted";

const defaultSleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const defaultMonotonicNow = () => (
  typeof performance !== "undefined" && typeof performance.now === "function"
    ? performance.now()
    : Date.now()
);

function clean(value) {
  return String(value ?? "").trim();
}

function normalized(value) {
  return clean(value).toLocaleLowerCase();
}

function normalizedStatus(room) {
  return normalized(room?.status || "waiting");
}

function roomPlayers(room) {
  if (!Array.isArray(room?.players)) return [];
  const seen = new Set();
  return room.players.flatMap((player) => {
    const email = normalized(player?.email);
    if (!email || seen.has(email)) return [];
    seen.add(email);
    return [email];
  });
}

function activePlayerEmails(room) {
  const excluded = new Set([
    ...(Array.isArray(room?.spectators) ? room.spectators : []),
    ...(Array.isArray(room?.eliminated_emails) ? room.eliminated_emails : []),
  ].map(normalized).filter(Boolean));
  return roomPlayers(room).filter((email) => !excluded.has(email));
}

function activeVoteRequests(room, activeEmails) {
  const active = new Set(activeEmails);
  const seen = new Set();
  return (Array.isArray(room?.vote_requests) ? room.vote_requests : []).flatMap((value) => {
    const email = normalized(value);
    if (!email || !active.has(email) || seen.has(email)) return [];
    seen.add(email);
    return [email];
  });
}

function detectiveVotes(room) {
  return Array.isArray(room?.detective_votes) ? room.detective_votes : [];
}

function actorVote(room, actorEmail) {
  const actor = normalized(actorEmail);
  let persisted = null;
  for (const vote of detectiveVotes(room)) {
    if (normalized(vote?.voter_email) === actor) persisted = vote;
  }
  return persisted;
}

function votingActive(room, activeEmails = activePlayerEmails(room)) {
  const requests = activeVoteRequests(room, activeEmails);
  const threshold = activeEmails.length > 0 ? Math.ceil(activeEmails.length * 0.51) : 0;
  return threshold > 0 && requests.length >= threshold;
}

function retryDelayMilliseconds(attempt) {
  return Math.min(
    RETRY_DELAY_CAP_MILLISECONDS,
    RETRY_INITIAL_DELAY_MILLISECONDS * (2 ** Math.max(0, attempt)),
  );
}

function recoveryBudgetMilliseconds(value) {
  const requested = Number(value);
  if (!Number.isFinite(requested) || requested <= 0) {
    return DETECTIVE_VOTE_RETRY_BUDGET_MILLISECONDS;
  }
  return Math.min(DETECTIVE_VOTE_RETRY_BUDGET_MILLISECONDS, requested);
}

function recoveryBudgetExhaustedError(cause) {
  return Object.assign(new Error("Detective vote confirmation is still pending"), {
    name: "DetectiveVoteRecoveryBudgetError",
    status: 408,
    code: RECOVERY_BUDGET_EXHAUSTED_CODE,
    retryable: true,
    cause,
  });
}

export function isDetectiveVoteRecoveryBudgetExhausted(error) {
  return normalized(error?.code) === RECOVERY_BUDGET_EXHAUSTED_CODE;
}

export function isRetryableDetectiveVoteCastConflict(action, error) {
  const code = normalized(error?.code);
  return action === "cast_detective_vote"
    && Number(error?.status) === 409
    && error?.retryable === true
    && ["active_lease", "cas_contention"].includes(code);
}

function isInactiveVoteConflict(error) {
  return Number(error?.status) === 409
    && normalized(error?.code) === "detective_vote_inactive";
}

function sameRoomAndMatch(initialRoom, candidateRoom) {
  const roomID = clean(initialRoom?.id);
  const matchID = clean(initialRoom?.match_id);
  return Boolean(roomID && matchID)
    && clean(candidateRoom?.id) === roomID
    && clean(candidateRoom?.match_id) === matchID;
}

function sameCastScope(initialRoom, candidateRoom, actorEmail, targetEmail) {
  const actor = normalized(actorEmail);
  const target = normalized(targetEmail);
  if (!actor || !target || actor === target) return false;
  if (!sameRoomAndMatch(initialRoom, candidateRoom)) return false;
  const initialPlayers = new Set(roomPlayers(initialRoom));
  const candidatePlayers = new Set(roomPlayers(candidateRoom));
  return initialPlayers.has(actor) && initialPlayers.has(target)
    && candidatePlayers.has(actor) && candidatePlayers.has(target);
}

function initialCastIsScoped(room, actorEmail, targetEmail) {
  if (normalizedStatus(room) !== "playing") return false;
  if (!clean(room?.detective_vote_round_id)) return false;
  const active = activePlayerEmails(room);
  const activeSet = new Set(active);
  return sameCastScope(room, room, actorEmail, targetEmail)
    && activeSet.has(normalized(actorEmail))
    && activeSet.has(normalized(targetEmail))
    && votingActive(room, active);
}

function authoritativeResolution(initialRoom, room, actorEmail, targetEmail, nowMilliseconds) {
  if (!sameRoomAndMatch(initialRoom, room)) return "reject";

  const status = normalizedStatus(room);
  if (status === "finished") {
    return ["spy", "detectives"].includes(normalized(room?.winner)) ? "accept" : "reject";
  }
  if (status !== "playing") return "reject";

  const expectedRoundID = clean(initialRoom?.detective_vote_round_id);
  const currentRoundID = clean(room?.detective_vote_round_id);
  // A newer nonblank id is authoritative proof that Round A settled and Round
  // B opened. Adopt it silently; never replay the stale Round A payload.
  if (currentRoundID && currentRoundID !== expectedRoundID) return "accept";
  // A terminal winner was CAS-claimed but the leased finisher has not yet
  // archived/committed it. Replaying the same round-scoped cast is intentional:
  // executeRoomAction reconciles the immutable intent before action dispatch.
  if (room?.terminal_reconciliation_pending === true) return "retry";

  const timer = gameTimerSnapshot(room, nowMilliseconds);
  if (timer.valid && !timer.paused && timer.remainingSeconds === 0) return "accept";

  const candidatePlayers = new Set(roomPlayers(room));
  if (
    !candidatePlayers.has(normalized(actorEmail))
    || !candidatePlayers.has(normalized(targetEmail))
  ) return "accept";

  const persistedVote = actorVote(room, actorEmail);
  if (persistedVote) {
    return currentRoundID === expectedRoundID &&
        normalized(persistedVote.voted_for_email) === normalized(targetEmail)
      ? "accept"
      : "reject";
  }

  const requests = Array.isArray(room?.vote_requests) ? room.vote_requests : [];
  const votes = detectiveVotes(room);
  // Round A has settled once its server identity disappears. Nonempty requests
  // can already belong to the pre-threshold request phase for Round B, so they
  // must be adopted without replaying the stale Round A cast.
  if (expectedRoundID && !currentRoundID && votes.length === 0) return "accept";

  const active = activePlayerEmails(room);
  const activeSet = new Set(active);
  if (
    votingActive(room, active)
    && currentRoundID === expectedRoundID
    && !timer.paused
    && activeSet.has(normalized(actorEmail))
    && activeSet.has(normalized(targetEmail))
  ) {
    return "retry";
  }
  return "wait";
}

/**
 * Recovers one exact immutable detective cast after a typed lifecycle/CAS 409.
 * Every retry is preceded by an authoritative same-room/same-match refresh.
 * Refreshes, waits, and casts share one hard two-second client-side budget.
 */
export async function recoverDetectiveVoteCastConflict({
  action,
  error,
  room,
  actorEmail,
  targetEmail,
  refreshRoom,
  castVote,
  now = () => Date.now(),
  monotonicNow = defaultMonotonicNow,
  sleep = defaultSleep,
  maxAttempts = DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS,
  budgetMilliseconds = DETECTIVE_VOTE_RETRY_BUDGET_MILLISECONDS,
}) {
  if (
    !isRetryableDetectiveVoteCastConflict(action, error)
    || !initialCastIsScoped(room, actorEmail, targetEmail)
  ) {
    throw error;
  }

  const attempts = Math.max(
    1,
    Math.min(
      DETECTIVE_VOTE_RETRY_MAX_ATTEMPTS,
      Number.isFinite(Number(maxAttempts)) ? Math.trunc(Number(maxAttempts)) : 1,
    ),
  );
  const roomID = clean(room.id);
  const expectedVoteRoundID = clean(room.detective_vote_round_id);
  const originalTargetEmail = targetEmail;
  let lastError = error;
  const recoveryDeadline = monotonicNow() + recoveryBudgetMilliseconds(budgetMilliseconds);

  const runWithinBudget = async (operation) => {
    const remainingMilliseconds = recoveryDeadline - monotonicNow();
    if (remainingMilliseconds <= 0) {
      throw recoveryBudgetExhaustedError(lastError);
    }

    let timeoutHandle = null;
    try {
      return await Promise.race([
        Promise.resolve().then(operation),
        new Promise((_, reject) => {
          timeoutHandle = setTimeout(
            () => reject(recoveryBudgetExhaustedError(lastError)),
            Math.max(0, Math.floor(remainingMilliseconds)),
          );
        }),
      ]);
    } finally {
      if (timeoutHandle !== null) clearTimeout(timeoutHandle);
    }
  };

  const sleepWithinBudget = async (requestedMilliseconds) => {
    const remainingMilliseconds = recoveryDeadline - monotonicNow();
    if (remainingMilliseconds <= 0) {
      throw recoveryBudgetExhaustedError(lastError);
    }
    const boundedDelay = Math.min(requestedMilliseconds, remainingMilliseconds);
    await runWithinBudget(() => sleep(boundedDelay));
    if (
      boundedDelay < requestedMilliseconds
      || recoveryDeadline - monotonicNow() <= 0
    ) {
      throw recoveryBudgetExhaustedError(lastError);
    }
  };

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const refreshed = await runWithinBudget(() => refreshRoom(roomID));
    const resolution = authoritativeResolution(
      room,
      refreshed,
      actorEmail,
      targetEmail,
      now(),
    );
    if (resolution === "accept") return refreshed;
    if (resolution === "reject") throw lastError;

    if (resolution === "wait") {
      if (attempt < attempts - 1) {
        await sleepWithinBudget(retryDelayMilliseconds(attempt));
      }
      continue;
    }

    await sleepWithinBudget(retryDelayMilliseconds(attempt));
    let castResult;
    try {
      castResult = await runWithinBudget(() => castVote({
        roomId: roomID,
        targetEmail: originalTargetEmail,
        expectedVoteRoundID,
      }));
    } catch (castError) {
      if (
        isRetryableDetectiveVoteCastConflict(action, castError)
        || isInactiveVoteConflict(castError)
      ) {
        lastError = castError;
        continue;
      }
      throw castError;
    }

    const castResolution = authoritativeResolution(
      room,
      castResult,
      actorEmail,
      targetEmail,
      now(),
    );
    if (castResolution === "accept") return castResult;
    if (castResolution === "reject") throw lastError;
  }

  throw lastError;
}

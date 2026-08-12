export const DETECTIVE_VOTE_CANCELLATION_REASON = "no_viable_candidate";
export const DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS = 4_800;

function clean(value) {
  return String(value ?? "").trim();
}

/**
 * Reads the durable cancellation envelope without trying to infer a
 * cancellation from cleared ballots. Event IDs are the deduplication key;
 * round IDs remain metadata because the active server vote round is cleared
 * as part of the same authoritative update.
 */
export function detectiveVoteCancellationIdentity(room) {
  const id = clean(room?.detective_vote_cancellation_event_id);
  const roundID = clean(room?.detective_vote_cancellation_round_id);
  const reason = clean(room?.detective_vote_cancellation_reason);
  const presentAtISO = clean(room?.detective_vote_cancellation_present_at);
  const presentAtMs = Date.parse(presentAtISO);

  if (
    !id
    || !roundID
    || reason !== DETECTIVE_VOTE_CANCELLATION_REASON
    || !Number.isFinite(presentAtMs)
  ) return null;

  return {
    id,
    roundID,
    reason,
    presentAtISO,
    presentAtMs,
  };
}

export function hasDetectiveVoteCancellationEvent(room) {
  return detectiveVoteCancellationIdentity(room) !== null;
}

/**
 * Returns the shared cinematic window for a valid, non-expired event. Clients
 * that receive the snapshot late enter at the matching elapsed offset instead
 * of replaying the scene from the beginning.
 */
export function detectiveVoteCancellationWindow(room, nowMs = Date.now()) {
  const identity = detectiveVoteCancellationIdentity(room);
  const currentTimeMs = Number(nowMs);
  if (!identity || !Number.isFinite(currentTimeMs)) return null;

  const endsAtMs = identity.presentAtMs + DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS;
  if (currentTimeMs >= endsAtMs) return null;

  return {
    ...identity,
    endsAtMs,
    delayMs: Math.max(identity.presentAtMs - currentTimeMs, 0),
    elapsedMs: Math.max(currentTimeMs - identity.presentAtMs, 0),
    remainingMs: endsAtMs - currentTimeMs,
  };
}

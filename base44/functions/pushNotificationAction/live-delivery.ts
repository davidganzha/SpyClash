import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

const LIVE_DELIVERY_LEASE_MS = 90_000;
export const MAX_LIVE_DELIVERY_ATTEMPTS = 8;

function exact(registration: Entity): Entity {
  return {
    id: registration.id,
    token_hash: registration.token_hash,
    delivery_state: registration.delivery_state,
    delivery_revision: registration.delivery_revision,
  };
}

export function liveDeliveryDue(
  registration: Entity,
  now = new Date(),
): boolean {
  if (registration.retry_requested === true) return true;
  const state = clean(registration.delivery_state);
  if (state === "retry") {
    const next = Date.parse(clean(registration.next_attempt_at));
    return !Number.isFinite(next) || next <= now.getTime();
  }
  if (state === "processing") {
    const lease = Date.parse(clean(registration.delivery_lease_until));
    return !Number.isFinite(lease) || lease <= now.getTime();
  }
  return false;
}

export async function claimLiveDelivery(input: {
  store: any;
  registration: Entity;
  roomID: string;
  matchID: string;
  roomRevision: number;
  forceEnd?: boolean;
  now?: Date;
  randomUUID?: () => string;
}): Promise<Entity | null> {
  const now = input.now || new Date();
  const current = input.registration;
  if (!clean(current.delivery_revision)) return null;
  const lease = Date.parse(clean(current.delivery_lease_until));
  if (
    clean(current.delivery_state) === "processing" &&
    Number.isFinite(lease) && lease > now.getTime()
  ) return null;
  const samePendingMatch =
    clean(current.pending_match_id) === clean(input.matchID);
  const attempt = samePendingMatch
    ? Number(current.delivery_attempt_count || 0) + 1
    : 1;
  const revision = (input.randomUUID || (() => crypto.randomUUID()))();
  const patch = {
    delivery_state: "processing",
    delivery_revision: revision,
    delivery_lease_until: new Date(now.getTime() + LIVE_DELIVERY_LEASE_MS)
      .toISOString(),
    delivery_attempt_count: attempt,
    next_attempt_at: null,
    retry_requested: false,
    pending_room_id: clean(input.roomID),
    pending_match_id: clean(input.matchID),
    pending_room_revision: Math.max(0, Number(input.roomRevision || 0)),
    pending_force_end: input.forceEnd === true ||
      current.pending_force_end === true,
    updated_at: now.toISOString(),
  };
  const result = await input.store.updateMany(exact(current), { $set: patch });
  return Number(result?.updated) === 1 ? { ...current, ...patch } : null;
}

export async function queueLiveRetry(input: {
  store: any;
  registrationID: string;
  roomID: string;
  matchID: string;
  roomRevision: number;
  forceEnd?: boolean;
  now?: Date;
}): Promise<boolean> {
  const now = input.now || new Date();
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const rows = await input.store.filter(
      { id: input.registrationID },
      "created_date",
      2,
      0,
    ) || [];
    const current = rows[0];
    if (!current || clean(current.status) !== "active") return false;
    const currentPendingRevision = Number(current.pending_room_revision || 0);
    const replacePending =
      clean(current.pending_match_id) !== clean(input.matchID) ||
      Number(input.roomRevision || 0) > currentPendingRevision;
    const patch: Entity = {
      retry_requested: true,
      updated_at: now.toISOString(),
      ...(input.forceEnd === true ? { pending_force_end: true } : {}),
    };
    if (clean(current.delivery_state) !== "processing") {
      patch.delivery_state = "retry";
      patch.next_attempt_at = now.toISOString();
    }
    if (replacePending) {
      patch.pending_room_id = clean(input.roomID);
      patch.pending_match_id = clean(input.matchID);
      patch.pending_room_revision = Math.max(
        0,
        Number(input.roomRevision || 0),
      );
    }
    const result = await input.store.updateMany({
      ...exact(current),
      pending_room_revision: current.pending_room_revision,
    }, { $set: patch });
    if (Number(result?.updated) === 1) return true;
  }
  return false;
}

export async function completeLiveDelivery(input: {
  store: any;
  claimed: Entity;
  state: "idle" | "retry" | "failed";
  nextAttemptAt?: string;
  errorCode?: string;
  patch?: Entity;
  now?: Date;
  randomUUID?: () => string;
}): Promise<boolean> {
  const now = input.now || new Date();
  const patch: Entity = {
    delivery_state: input.state,
    delivery_revision: (input.randomUUID || (() => crypto.randomUUID()))(),
    delivery_lease_until: now.toISOString(),
    next_attempt_at: input.nextAttemptAt || null,
    last_error_code: clean(input.errorCode).slice(0, 80),
    updated_at: now.toISOString(),
    ...(input.patch || {}),
  };
  if (input.state === "idle") patch.delivery_attempt_count = 0;
  const completionFilter: Entity = {
    id: input.claimed.id,
    token_hash: input.claimed.token_hash,
    delivery_state: "processing",
    delivery_revision: input.claimed.delivery_revision,
  };
  if (input.state === "idle") completionFilter.retry_requested = false;
  const result = await input.store.updateMany(completionFilter, {
    $set: patch,
  });
  if (Number(result?.updated) === 1) return true;
  if (input.state !== "idle") return false;
  // A newer room mutation can request another send while APNs is in flight.
  // Preserve successful delivery fields, but leave a retry for that newer
  // projection instead of losing it or globally scanning idle registrations.
  const retryPatch: Entity = {
    ...patch,
    delivery_state: "retry",
    next_attempt_at: now.toISOString(),
  };
  delete retryPatch.delivery_attempt_count;
  const queued = await input.store.updateMany({
    id: input.claimed.id,
    token_hash: input.claimed.token_hash,
    delivery_state: "processing",
    delivery_revision: input.claimed.delivery_revision,
    retry_requested: true,
  }, { $set: retryPatch });
  return Number(queued?.updated) === 1;
}

export function liveRetryAt(attemptCount: number, now = new Date()): string {
  const seconds = Math.min(1800, 30 * 2 ** Math.max(0, attemptCount - 1));
  return new Date(now.getTime() + seconds * 1_000).toISOString();
}

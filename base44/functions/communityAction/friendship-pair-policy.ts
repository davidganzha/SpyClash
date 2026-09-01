export type FriendshipPairEntity = Record<string, unknown>;

export type FriendshipPairStatus =
  | "blocked"
  | "accepted"
  | "pending"
  | "declined";

export class FriendshipPairPolicyError extends Error {
  readonly status = 503;
  readonly code = "friendship_pair_unavailable";

  constructor(message: string) {
    super(message);
    this.name = "FriendshipPairPolicyError";
  }
}

export type FriendshipPairResolution = {
  actorID: string;
  counterpartID: string;
  rows: FriendshipPairEntity[];
  representative: FriendshipPairEntity | null;
  effectiveStatus: FriendshipPairStatus | null;
  blockers: FriendshipPairEntity[];
  blockerOwnerIDs: string[];
  unknownBlockerOwnerIDs: string[];
  hasBlock: boolean;
  hasOwnBlock: boolean;
  hasForeignBlock: boolean;
  accepted: FriendshipPairEntity[];
  hasAccepted: boolean;
  pending: FriendshipPairEntity[];
  pendingOutgoing: FriendshipPairEntity[];
  pendingIncoming: FriendshipPairEntity[];
  hasPending: boolean;
  hasPendingOutgoing: boolean;
  hasPendingIncoming: boolean;
  declined: FriendshipPairEntity[];
};

export type FriendshipStateProjection = {
  pairs: FriendshipPairResolution[];
  friends: FriendshipPairResolution[];
  incoming: FriendshipPairResolution[];
  outgoing: FriendshipPairResolution[];
  blocked: FriendshipPairResolution[];
  hidden: FriendshipPairResolution[];
  declined: FriendshipPairResolution[];
};

type RankedFriendship = {
  row: FriendshipPairEntity;
  id: string;
  requesterID: string;
  addresseeID: string;
  status: FriendshipPairStatus;
  blockerOwnerID: string;
  requestEventID: string;
  updatedAt: number;
  createdAt: number;
};

const VALID_STATUSES = new Set<FriendshipPairStatus>([
  "blocked",
  "accepted",
  "pending",
  "declined",
]);

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function unavailable(message: string): never {
  throw new FriendshipPairPolicyError(message);
}

function normalizedStatus(value: unknown): FriendshipPairStatus | null {
  const status = clean(value).toLowerCase() as FriendshipPairStatus;
  return VALID_STATUSES.has(status) ? status : null;
}

function timestamp(value: unknown): number {
  const parsed = Date.parse(clean(value));
  return Number.isFinite(parsed) ? parsed : 0;
}

function exactPair(
  requesterID: string,
  addresseeID: string,
  actorID: string,
  counterpartID: string,
): boolean {
  return (requesterID === actorID && addresseeID === counterpartID) ||
    (requesterID === counterpartID && addresseeID === actorID);
}

function blockerOwnerID(friendship: RankedFriendship): string {
  if (friendship.status !== "blocked") return "";
  return clean(friendship.row.blocked_by_id) || friendship.requesterID;
}

function relevantSignature(friendship: RankedFriendship): string {
  return [
    friendship.requesterID,
    friendship.addresseeID,
    friendship.status,
    blockerOwnerID(friendship),
    friendship.requestEventID,
    clean(friendship.row.updated_at),
    clean(friendship.row.created_at || friendship.row.created_date),
  ].join("\u0000");
}

function priority(friendship: RankedFriendship, actorID: string): number {
  if (friendship.status === "blocked") {
    // A foreign or malformed owner must win the representative so callers that
    // still need one row cannot accidentally overwrite another user's block.
    return blockerOwnerID(friendship) === actorID ? 1 : 0;
  }
  if (friendship.status === "accepted") return 2;
  if (friendship.status === "pending") {
    if (friendship.requesterID === actorID) {
      // A resend-capable outgoing request wins over a corrupt legacy pending
      // row whose notification identity is missing.
      return friendship.requestEventID ? 3 : 4;
    }
    return 5;
  }
  return friendship.requesterID === actorID ? 6 : 7;
}

function compareRanked(
  left: RankedFriendship,
  right: RankedFriendship,
  actorID: string,
): number {
  const priorityDifference = priority(left, actorID) - priority(right, actorID);
  if (priorityDifference !== 0) return priorityDifference;
  if (left.updatedAt !== right.updatedAt) {
    return right.updatedAt - left.updatedAt;
  }
  if (left.createdAt !== right.createdAt) {
    return right.createdAt - left.createdAt;
  }
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

function validateIDs(actorID: unknown, counterpartID: unknown) {
  const actor = clean(actorID);
  const counterpart = clean(counterpartID);
  if (!actor || !counterpart || actor === counterpart) {
    unavailable("Two distinct Friendship pair participants are required.");
  }
  return { actor, counterpart };
}

function rankedExactRows(
  rows: Iterable<FriendshipPairEntity>,
  actorID: string,
  counterpartID: string,
): RankedFriendship[] {
  if (!rows || typeof rows[Symbol.iterator] !== "function") {
    unavailable("Friendship pair rows must be iterable.");
  }

  const byID = new Map<string, RankedFriendship>();
  for (const candidate of rows) {
    if (
      !candidate || typeof candidate !== "object" || Array.isArray(candidate)
    ) {
      unavailable("Friendship pair contains an invalid row.");
    }
    const requesterID = clean(candidate.requester_id);
    const addresseeID = clean(candidate.addressee_id);
    if (!exactPair(requesterID, addresseeID, actorID, counterpartID)) continue;

    const id = clean(candidate.id);
    const status = normalizedStatus(candidate.status);
    if (!id || !status) {
      unavailable("Friendship pair contains an invalid exact-pair row.");
    }
    const ranked: RankedFriendship = {
      row: candidate,
      id,
      requesterID,
      addresseeID,
      status,
      blockerOwnerID: "",
      requestEventID: clean(candidate.request_event_id),
      updatedAt: timestamp(candidate.updated_at),
      createdAt: timestamp(candidate.created_at || candidate.created_date),
    };
    ranked.blockerOwnerID = blockerOwnerID(ranked);

    const existing = byID.get(id);
    if (existing && relevantSignature(existing) !== relevantSignature(ranked)) {
      unavailable(`Friendship pair contains conflicting row id ${id}.`);
    }
    if (!existing) byID.set(id, ranked);
  }

  return [...byID.values()].sort((left, right) =>
    compareRanked(left, right, actorID)
  );
}

/**
 * Resolves every exact Friendship row for one unordered user pair.
 *
 * Security precedence is actor-aware and independent of input order:
 * foreign/unknown block > own block > accepted > outgoing pending with an
 * event id > other outgoing pending > incoming pending > declined.
 */
export function resolveFriendshipPair(
  rows: Iterable<FriendshipPairEntity>,
  actorID: unknown,
  counterpartID: unknown,
): FriendshipPairResolution {
  const { actor, counterpart } = validateIDs(actorID, counterpartID);
  const ranked = rankedExactRows(rows, actor, counterpart);
  const blockers = ranked.filter((friendship) =>
    friendship.status === "blocked"
  );
  const accepted = ranked.filter((friendship) =>
    friendship.status === "accepted"
  );
  const pending = ranked.filter((friendship) =>
    friendship.status === "pending"
  );
  const pendingOutgoing = pending.filter((friendship) =>
    friendship.requesterID === actor
  );
  const pendingIncoming = pending.filter((friendship) =>
    friendship.addresseeID === actor
  );
  const declined = ranked.filter((friendship) =>
    friendship.status === "declined"
  );
  const blockerOwnerIDs = [
    ...new Set(
      blockers.map((friendship) => friendship.blockerOwnerID).filter(Boolean),
    ),
  ].sort();
  const unknownBlockerOwnerIDs = blockerOwnerIDs.filter((ownerID) =>
    ownerID !== actor && ownerID !== counterpart
  );
  const representative = ranked[0] || null;

  return {
    actorID: actor,
    counterpartID: counterpart,
    rows: ranked.map((friendship) => friendship.row),
    representative,
    effectiveStatus: representative
      ? normalizedStatus(representative.status)
      : null,
    blockers: blockers.map((friendship) => friendship.row),
    blockerOwnerIDs,
    unknownBlockerOwnerIDs,
    hasBlock: blockers.length > 0,
    hasOwnBlock: blockerOwnerIDs.includes(actor),
    hasForeignBlock: blockers.some((friendship) =>
      friendship.blockerOwnerID !== actor
    ),
    accepted: accepted.map((friendship) => friendship.row),
    hasAccepted: accepted.length > 0,
    pending: pending.map((friendship) => friendship.row),
    pendingOutgoing: pendingOutgoing.map((friendship) => friendship.row),
    pendingIncoming: pendingIncoming.map((friendship) => friendship.row),
    hasPending: pending.length > 0,
    hasPendingOutgoing: pendingOutgoing.length > 0,
    hasPendingIncoming: pendingIncoming.length > 0,
    declined: declined.map((friendship) => friendship.row),
  };
}

/**
 * Groups an actor's relationship rows into mutually exclusive state buckets.
 * Any block suppresses accepted and pending projections for the same pair.
 */
export function projectFriendshipStateForActor(
  rows: Iterable<FriendshipPairEntity>,
  actorID: unknown,
): FriendshipStateProjection {
  const actor = clean(actorID);
  if (!actor) unavailable("A Friendship state actor is required.");
  if (!rows || typeof rows[Symbol.iterator] !== "function") {
    unavailable("Friendship state rows must be iterable.");
  }

  const groups = new Map<string, FriendshipPairEntity[]>();
  for (const candidate of rows) {
    if (
      !candidate || typeof candidate !== "object" || Array.isArray(candidate)
    ) {
      unavailable("Friendship state contains an invalid row.");
    }
    const requesterID = clean(candidate.requester_id);
    const addresseeID = clean(candidate.addressee_id);
    if (requesterID !== actor && addresseeID !== actor) continue;
    const counterpartID = requesterID === actor ? addresseeID : requesterID;
    if (!counterpartID || counterpartID === actor) {
      unavailable("Friendship state contains an invalid actor pair.");
    }
    const group = groups.get(counterpartID) || [];
    group.push(candidate);
    groups.set(counterpartID, group);
  }

  const pairs = [...groups.keys()].sort().map((counterpartID) =>
    resolveFriendshipPair(groups.get(counterpartID) || [], actor, counterpartID)
  );
  const projection: FriendshipStateProjection = {
    pairs,
    friends: [],
    incoming: [],
    outgoing: [],
    blocked: [],
    hidden: [],
    declined: [],
  };

  for (const pair of pairs) {
    if (pair.hasBlock) {
      (pair.hasForeignBlock ? projection.hidden : projection.blocked).push(
        pair,
      );
    } else if (pair.hasAccepted) {
      projection.friends.push(pair);
    } else if (pair.hasPendingIncoming) {
      // Crossed requests must stay actionable. Each actor sees the other
      // actor's request as incoming instead of both actors being stranded in
      // an outgoing-only state.
      projection.incoming.push(pair);
    } else if (pair.hasPendingOutgoing) {
      projection.outgoing.push(pair);
    } else {
      projection.declined.push(pair);
    }
  }
  return projection;
}

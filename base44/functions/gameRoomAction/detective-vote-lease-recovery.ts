import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";

type Room = Record<string, unknown>;
type RecoveryDelay = (milliseconds: number) => Promise<void>;

const RECOVERY_BACKOFF_MILLISECONDS = [0, 25, 50, 100, 200, 400];

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalized(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function rows(room: Room, key: string): unknown[] {
  const value = room?.[key];
  return Array.isArray(value) ? value : [];
}

function exactVotePersisted(
  room: Room,
  actorEmail: string,
  targetEmail: string,
): boolean {
  const actorKey = normalized(actorEmail);
  const targetKey = normalized(targetEmail);
  return rows(room, "detective_votes").some((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }
    const vote = value as Record<string, unknown>;
    return normalized(vote.voter_email) === actorKey &&
      normalized(vote.voted_for_email) === targetKey;
  });
}

function hasPendingTerminal(room: Room): boolean {
  return normalized(room?.status) !== "finished" &&
    room?.terminal_intent !== null &&
    room?.terminal_intent !== undefined;
}

function isFinishedTerminal(room: Room): boolean {
  return normalized(room?.status) === "finished" &&
    ["spy", "detectives"].includes(normalized(room?.winner));
}

function isAtomicNonTerminalSettlement(room: Room): boolean {
  return normalized(room?.status) === "playing" &&
    rows(room, "vote_requests").length === 0 &&
    rows(room, "detective_votes").length === 0;
}

async function defaultRecoveryDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Read-only reconciliation for a cast that never acquired all participant
 * lifecycle leases. It can acknowledge only an authoritative state produced
 * by the competing writer for the exact same match. A pending terminal intent
 * is never presented as cancellation: the bounded reads wait for the leased
 * finisher and otherwise preserve the original active_lease retry signal.
 */
export async function reconcileDetectiveVoteCastAfterActiveIdentityLease<
  T extends Room,
>(input: {
  action: string;
  error: unknown;
  requestEnteredActiveVote: boolean;
  expectedMatchID: unknown;
  expectedRoundID: unknown;
  actorEmail: unknown;
  targetEmail: unknown;
  refetch: () => Promise<T | null | undefined>;
  assertParticipant: (room: T) => void | Promise<void>;
  delay?: RecoveryDelay;
}): Promise<T> {
  const expectedMatchID = clean(input.expectedMatchID);
  const expectedRoundID = clean(input.expectedRoundID);
  const actorEmail = clean(input.actorEmail);
  const targetEmail = clean(input.targetEmail);
  const canReconcile = input.action === "cast_detective_vote" &&
    input.error instanceof BillingIdentityLifecycleError &&
    input.error.code === "active_lease" &&
    input.requestEnteredActiveVote &&
    Boolean(expectedMatchID && expectedRoundID && actorEmail && targetEmail);
  if (!canReconcile) throw input.error;

  const delay = input.delay ?? defaultRecoveryDelay;
  for (const milliseconds of RECOVERY_BACKOFF_MILLISECONDS) {
    if (milliseconds > 0) await delay(milliseconds);

    let room: T | null | undefined;
    try {
      room = await input.refetch();
    } catch {
      // A later bounded read may observe the competing writer's commit.
      continue;
    }
    if (!room) continue;
    if (clean(room.match_id) !== expectedMatchID) throw input.error;

    await input.assertParticipant(room);

    if (isFinishedTerminal(room)) return room;
    const currentRoundID = clean(room.detective_vote_round_id);
    if (currentRoundID && currentRoundID !== expectedRoundID) {
      throw input.error;
    }
    if (hasPendingTerminal(room)) continue;
    if (normalized(room.status) !== "playing") continue;
    if (
      currentRoundID === expectedRoundID &&
      exactVotePersisted(room, actorEmail, targetEmail)
    ) return room;
    if (!currentRoundID && isAtomicNonTerminalSettlement(room)) return room;
  }

  throw input.error;
}

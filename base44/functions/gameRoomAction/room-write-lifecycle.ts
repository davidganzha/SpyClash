import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  billingIdentitySubjectKey,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";
import { committedGameStartIdentity } from "./committed-game-start-repair.ts";

const ROOM_WRITE_LEASE_ATTEMPTS = 6;
const ROOM_WRITE_LEASE_BACKOFF_MILLISECONDS = [25, 50, 100, 200, 400];
const ROOM_WRITE_LEASE_RELEASE_ATTEMPTS = 3;
const COMPLETE_GAME_START_RECONCILIATION_BACKOFF_MILLISECONDS = [
  0,
  50,
  100,
  200,
  400,
  800,
];

type AcquireRoomWriterLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<BillingIdentityLease>;

type ReleaseRoomWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
) => Promise<void>;

type RoomWriteLeaseDelay = (milliseconds: number) => Promise<void>;
type RoomMembershipRetryAttempt<T> = (
  markActionStarted: () => void,
) => Promise<T>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function uniqueStableUserIDs(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))].sort();
}

export type RoomWriteLeaseContext = {
  lifecycleStore: any;
  userIDs: string[];
  leases: BillingIdentityLease[];
};

function roomMembershipChanged(): Error {
  return Object.assign(
    new Error("Room membership changed while acquiring lifecycle leases."),
    { status: 409, code: "room_membership_changed" },
  );
}

function isRoomMembershipChanged(error: unknown): boolean {
  return clean((error as { code?: unknown })?.code) ===
    "room_membership_changed";
}

export function assertExactRoomLeaseCoverage(
  context: RoomWriteLeaseContext,
  currentUserIDs: readonly unknown[],
): void {
  const current = uniqueStableUserIDs(currentUserIDs);
  if (
    current.length !== context.userIDs.length ||
    current.some((value, index) => value !== context.userIDs[index])
  ) {
    throw roomMembershipChanged();
  }
}

export async function assertRoomWriteLeases(
  context: RoomWriteLeaseContext,
): Promise<void> {
  for (const lease of context.leases) {
    await assertBillingWriterLease(context.lifecycleStore, lease);
  }
}

export async function assertRoomWriterLeaseForUser(
  context: RoomWriteLeaseContext,
  userIDValue: unknown,
): Promise<void> {
  const userID = clean(userIDValue);
  const index = context.userIDs.indexOf(userID);
  if (!userID || index < 0 || !context.leases[index]) {
    throw roomMembershipChanged();
  }
  const expectedSubjectKey = await billingIdentitySubjectKey(userID);
  if (context.leases[index].subjectKey !== expectedSubjectKey) {
    throw roomMembershipChanged();
  }
  await assertBillingWriterLease(
    context.lifecycleStore,
    context.leases[index],
  );
}

function retryableLeaseAcquisitionError(
  error: unknown,
): error is BillingIdentityLifecycleError {
  return error instanceof BillingIdentityLifecycleError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

// Only actions that cannot change room membership may bypass an active writer
// lease. Membership changes must serialize with committed-start reconciliation
// so its identity-bearing outbox and signal recipients remain authoritative.
const ACTIVE_LEASE_RECOVERY_ACTIONS = new Set(["mark_role_card_read"]);

export async function recoverSafeRoomActionAfterActiveIdentityLease<T>(input: {
  action: string;
  error: unknown;
  recover: () => Promise<T>;
}): Promise<T> {
  const canRecover = ACTIVE_LEASE_RECOVERY_ACTIONS.has(input.action) &&
    input.error instanceof BillingIdentityLifecycleError &&
    input.error.code === "active_lease";
  if (!canRecover) throw input.error;
  return await input.recover();
}

export async function reconcileCommittedGameStartAfterActiveIdentityLease<
  T,
  Result,
>(input: {
  action: string;
  error: unknown;
  refetch: () => Promise<T | null | undefined>;
  assertParticipant: (room: T) => void | Promise<void>;
  repair: (room: T) => Promise<Result>;
  delay?: RoomWriteLeaseDelay;
}): Promise<Result> {
  const canReconcile = input.action === "complete_game_start" &&
    input.error instanceof BillingIdentityLifecycleError &&
    input.error.code === "active_lease";
  if (!canReconcile) throw input.error;

  const delay = input.delay ?? defaultRoomWriteLeaseDelay;
  let committedRoom: T | null = null;
  for (
    const milliseconds
      of COMPLETE_GAME_START_RECONCILIATION_BACKOFF_MILLISECONDS
  ) {
    try {
      if (milliseconds > 0) await delay(milliseconds);
      const room: any = await input.refetch();
      if (committedGameStartIdentity(room)) {
        committedRoom = room as T;
        break;
      }
    } catch {
      // A bounded later read may still observe the winner's committed room.
    }
  }

  if (!committedRoom) throw input.error;
  await input.assertParticipant(committedRoom);
  return await input.repair(committedRoom);
}

function boundedAttemptCount(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return ROOM_WRITE_LEASE_ATTEMPTS;
  }
  return Math.min(
    ROOM_WRITE_LEASE_ATTEMPTS,
    Math.max(1, Math.trunc(value)),
  );
}

async function defaultRoomWriteLeaseDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

export async function retryRoomMembershipChangeBeforeAction<T>(input: {
  attempt: RoomMembershipRetryAttempt<T>;
  delay?: RoomWriteLeaseDelay;
  attempts?: number;
}): Promise<T> {
  const delay = input.delay ?? defaultRoomWriteLeaseDelay;
  const attempts = boundedAttemptCount(input.attempts);

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    let actionStarted = false;
    try {
      return await input.attempt(() => {
        actionStarted = true;
      });
    } catch (error) {
      if (
        actionStarted ||
        !isRoomMembershipChanged(error) ||
        attempt === attempts - 1
      ) {
        throw error;
      }
      await delay(ROOM_WRITE_LEASE_BACKOFF_MILLISECONDS[attempt]);
    }
  }

  throw new Error("Room membership retry exhausted unexpectedly.");
}

async function releaseRoomWriteLeases(
  lifecycleStore: any,
  leases: readonly BillingIdentityLease[],
  release: ReleaseRoomWriterLease,
  delay: RoomWriteLeaseDelay,
): Promise<unknown[]> {
  const failures: unknown[] = [];
  for (const lease of [...leases].reverse()) {
    let finalError: unknown;
    for (
      let attempt = 0;
      attempt < ROOM_WRITE_LEASE_RELEASE_ATTEMPTS;
      attempt += 1
    ) {
      try {
        await release(lifecycleStore, lease);
        finalError = undefined;
        break;
      } catch (error) {
        finalError = error;
        if (attempt < ROOM_WRITE_LEASE_RELEASE_ATTEMPTS - 1) {
          await delay(ROOM_WRITE_LEASE_BACKOFF_MILLISECONDS[attempt]);
        }
      }
    }
    if (finalError !== undefined) failures.push(finalError);
  }
  return failures;
}

export async function withRoomWriteLeases<T>(input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  action: (context: RoomWriteLeaseContext) => Promise<T>;
  acquire?: AcquireRoomWriterLease;
  release?: ReleaseRoomWriterLease;
  delay?: RoomWriteLeaseDelay;
  attempts?: number;
}): Promise<T> {
  const userIDs = uniqueStableUserIDs(input.userIDs);
  if (!userIDs.length) {
    throw Object.assign(
      new Error("A stable room writer identity is required."),
      {
        status: 401,
        code: "incomplete_identity",
      },
    );
  }

  const acquire = input.acquire ?? acquireBillingWriterLease;
  const release = input.release ?? releaseBillingWriterLease;
  const delay = input.delay ?? defaultRoomWriteLeaseDelay;
  const attempts = boundedAttemptCount(input.attempts);

  const context: RoomWriteLeaseContext = {
    lifecycleStore: input.lifecycleStore,
    userIDs,
    leases: [],
  };

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    context.leases = [];
    try {
      for (const userID of userIDs) {
        context.leases.push(await acquire(input.lifecycleStore, userID));
      }
      break;
    } catch (error) {
      const releaseFailures = await releaseRoomWriteLeases(
        input.lifecycleStore,
        context.leases,
        release,
        delay,
      );
      context.leases = [];
      if (releaseFailures.length) throw releaseFailures[0];
      if (
        !retryableLeaseAcquisitionError(error) ||
        attempt === attempts - 1
      ) {
        throw error;
      }
      await delay(ROOM_WRITE_LEASE_BACKOFF_MILLISECONDS[attempt]);
    }
  }

  let actionFailed = false;
  try {
    return await input.action(context);
  } catch (error) {
    actionFailed = true;
    throw error;
  } finally {
    const releaseFailures = await releaseRoomWriteLeases(
      input.lifecycleStore,
      context.leases,
      release,
      delay,
    );
    if (releaseFailures.length) {
      console.error(
        actionFailed
          ? "gameRoomAction lease release failed after action error"
          : "gameRoomAction lease release failed after committed action",
        releaseFailures,
      );
    }
  }
}

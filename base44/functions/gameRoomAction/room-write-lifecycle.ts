import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  billingIdentitySubjectKey,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

const ROOM_WRITE_LEASE_ATTEMPTS = 6;
const ROOM_WRITE_LEASE_BACKOFF_MILLISECONDS = [25, 50, 100, 200, 400];

type AcquireRoomWriterLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<BillingIdentityLease>;

type ReleaseRoomWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
) => Promise<void>;

type RoomWriteLeaseDelay = (milliseconds: number) => Promise<void>;

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

async function releaseRoomWriteLeases(
  lifecycleStore: any,
  leases: readonly BillingIdentityLease[],
  release: ReleaseRoomWriterLease,
): Promise<unknown[]> {
  const failures: unknown[] = [];
  for (const lease of [...leases].reverse()) {
    try {
      await release(lifecycleStore, lease);
    } catch (error) {
      failures.push(error);
    }
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
    );
    if (!actionFailed && releaseFailures.length) throw releaseFailures[0];
    if (releaseFailures.length) {
      console.error("gameRoomAction lease release failed", releaseFailures);
    }
  }
}

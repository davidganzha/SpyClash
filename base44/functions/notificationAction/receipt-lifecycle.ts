import { clean, NotificationContractError } from "./contracts.ts";
import { safeNotificationErrorDetails } from "./safe-error.ts";
import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  BillingIdentityLifecycleError,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

type Lease = {
  recordID: string;
  subjectKey: string;
  leaseToken: string;
  leaseUntil: string;
  revision: string;
};

const WRITE_LEASE_ATTEMPTS = 7;
const WRITE_LEASE_BACKOFF_MS = [50, 100, 200, 400, 600, 800];
const WRITE_LEASE_RELEASE_ATTEMPTS = 3;

type AcquireNotificationWriteLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<Lease>;

type ReleaseNotificationWriteLease = (
  lifecycleStore: any,
  lease: Lease,
) => Promise<void>;

type AssertNotificationWriteLease = (
  lifecycleStore: any,
  lease: Lease,
  now: Date,
) => Promise<void>;

type NotificationWriteLeaseDelay = (milliseconds: number) => Promise<void>;

function publicLifecycleError(error: unknown, actionStarted: boolean): unknown {
  if (!(error instanceof BillingIdentityLifecycleError)) return error;
  const conflict = ["active_lease", "cas_contention", "deletion_in_progress"]
    .includes(error.code);
  return Object.assign(new NotificationContractError(
    error.message, conflict ? 409 : 503, error.code,
  ), { retryable: !actionStarted && error.retryable });
}

// Use the same exact-token protocol as all other writers. A lost CAS response
// is reconciled, inactive duplicate initializers are quarantined before removal,
// and an unconfirmed acquisition is safely fenced before returning an error.
async function acquire(
  store: any, userID: string, nowFactory: () => Date, randomUUID: () => string,
): Promise<Lease> {
  try {
    return await acquireBillingWriterLease(store, userID, nowFactory, randomUUID);
  } catch (error) {
    throw publicLifecycleError(error, false);
  }
}

async function assertLease(store: any, lease: Lease, now: Date): Promise<void> {
  await assertBillingWriterLease(store, { ...lease, state: "active" }, now);
}

async function release(
  store: any, lease: Lease, now: Date, randomUUID: () => string,
): Promise<void> {
  await releaseBillingWriterLease(store, { ...lease, state: "active" }, now, randomUUID);
}

function boundedAttemptCount(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return WRITE_LEASE_ATTEMPTS;
  }
  return Math.min(WRITE_LEASE_ATTEMPTS, Math.max(1, Math.trunc(value)));
}

function retryableLeaseAcquisitionError(
  error: unknown,
): error is NotificationContractError {
  return error instanceof NotificationContractError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function releaseWithRetries(input: {
  lifecycleStore: any;
  lease: Lease;
  release: ReleaseNotificationWriteLease;
  delay: NotificationWriteLeaseDelay;
}): Promise<unknown | undefined> {
  let finalError: unknown;
  for (
    let attempt = 0;
    attempt < WRITE_LEASE_RELEASE_ATTEMPTS;
    attempt += 1
  ) {
    try {
      await input.release(input.lifecycleStore, input.lease);
      return undefined;
    } catch (error) {
      finalError = error;
      if (attempt < WRITE_LEASE_RELEASE_ATTEMPTS - 1) {
        try {
          await input.delay(WRITE_LEASE_BACKOFF_MS[attempt]);
        } catch {
          // Cleanup remains best effort. Continue immediately rather than
          // letting a timer implementation replace the committed result.
        }
      }
    }
  }
  return finalError;
}

export async function withNotificationWriteLease<T>(input: {
  lifecycleStore: any;
  userID: string;
  action: (persist: <R>(writer: () => Promise<R>) => Promise<R>) => Promise<T>;
  nowFactory?: () => Date;
  randomUUID?: () => string;
  onReleaseError?: (error: unknown) => void;
  acquire?: AcquireNotificationWriteLease;
  release?: ReleaseNotificationWriteLease;
  assert?: AssertNotificationWriteLease;
  delay?: NotificationWriteLeaseDelay;
  attempts?: number;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const acquireLease = input.acquire ||
    ((lifecycleStore, userID) =>
      acquire(lifecycleStore, userID, nowFactory, randomUUID));
  const releaseLease = input.release ||
    ((lifecycleStore, lease) =>
      release(lifecycleStore, lease, nowFactory(), randomUUID));
  const assertExactLease = input.assert || assertLease;
  const delay = input.delay || defaultDelay;
  const attempts = boundedAttemptCount(input.attempts);
  const userID = clean(input.userID);
  if (!userID) {
    throw new NotificationContractError("Unauthorized", 401, "unauthorized");
  }

  let lease: Lease | undefined;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      lease = await acquireLease(input.lifecycleStore, userID);
      break;
    } catch (error) {
      if (
        !retryableLeaseAcquisitionError(error) || attempt === attempts - 1
      ) {
        throw error;
      }
      await delay(WRITE_LEASE_BACKOFF_MS[attempt]);
    }
  }
  if (!lease) {
    throw new NotificationContractError(
      "Inbox is busy. Retry shortly.",
      409,
      "cas_contention",
    );
  }

  let actionStarted = false;
  try {
    await assertExactLease(input.lifecycleStore, lease, nowFactory());
    actionStarted = true;
    return await input.action(async <R>(writer: () => Promise<R>) => {
      await assertExactLease(input.lifecycleStore, lease, nowFactory());
      return await writer();
    });
  } catch (error) {
    throw publicLifecycleError(error, actionStarted);
  } finally {
    const releaseError = await releaseWithRetries({
      lifecycleStore: input.lifecycleStore,
      lease,
      release: releaseLease,
      delay,
    });
    if (releaseError !== undefined) {
      if (input.onReleaseError) {
        input.onReleaseError(releaseError);
      } else {
        const details = safeNotificationErrorDetails(releaseError);
        console.error(
          "notification lifecycle release failed",
          details.message,
          details.status,
        );
      }
    }
  }
}

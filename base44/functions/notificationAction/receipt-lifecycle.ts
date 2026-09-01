import { clean, NotificationContractError } from "./contracts.ts";
import { safeNotificationErrorDetails } from "./safe-error.ts";

type Lease = {
  recordID: string;
  subjectKey: string;
  leaseToken: string;
  leaseUntil: string;
  revision: string;
};

const MAX_ATTEMPTS = 6;
const LEASE_MS = 10 * 60 * 1_000;
const CLOCK_SKEW_MS = 5_000;
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

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function subjectKey(userID: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-billing-lifecycle:${userID}`),
  );
  return `billing:${hex(digest).slice(0, 40)}`;
}

async function rows(store: any, key: string): Promise<Record<string, any>[]> {
  return await store.filter({ subject_key: key }, "created_date", 100, 0) || [];
}

function activeLease(row: Record<string, any>, now: Date): boolean {
  const leaseUntil = Date.parse(clean(row.lease_until));
  return Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime() + CLOCK_SKEW_MS;
}

async function convergeInactiveInitializers(
  store: any,
  matches: Record<string, any>[],
  now: Date,
): Promise<void> {
  if (
    matches.some((row) =>
      clean(row.state) === "deleting" || activeLease(row, now)
    )
  ) {
    throw new NotificationContractError(
      "Inbox lifecycle rows are ambiguous.",
      503,
      "ambiguous_lifecycle",
    );
  }
  const canonical =
    [...matches].sort((left, right) =>
      clean(left.created_date).localeCompare(clean(right.created_date)) ||
      clean(left.id).localeCompare(clean(right.id))
    )[0];
  for (const duplicate of matches) {
    if (clean(duplicate.id) === clean(canonical.id)) continue;
    await store.delete(duplicate.id);
  }
}

async function acquire(
  store: any,
  userID: string,
  nowFactory: () => Date,
  randomUUID: () => string,
): Promise<Lease> {
  const key = await subjectKey(userID);
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const now = nowFactory();
    const matches = await rows(store, key);
    if (!matches.length) {
      const revision = randomUUID();
      try {
        await store.create({
          subject_key: key,
          state: "active",
          lease_token: `initialized:${revision}`,
          lease_until: now.toISOString(),
          revision,
        });
      } catch {
        // A concurrent initializer may have won. Re-read through the loop.
      }
      continue;
    }
    if (matches.length !== 1) {
      await convergeInactiveInitializers(store, matches, now);
      continue;
    }
    const current = matches[0];
    if (clean(current.state) === "deleting") {
      throw new NotificationContractError(
        "Account deletion is in progress.",
        409,
        "deletion_in_progress",
      );
    }
    if (activeLease(current, now)) {
      throw new NotificationContractError(
        "Inbox is busy. Retry shortly.",
        409,
        "active_lease",
      );
    }
    const token = `notification:${randomUUID()}`;
    const revision = randomUUID();
    const nextLeaseUntil = new Date(now.getTime() + LEASE_MS).toISOString();
    const result = await store.updateMany({
      id: current.id,
      subject_key: key,
      state: current.state,
      lease_token: current.lease_token,
      revision: current.revision,
    }, {
      $set: {
        state: "active",
        lease_token: token,
        lease_until: nextLeaseUntil,
        revision,
      },
    });
    if (Number(result?.updated) === 1) {
      return {
        recordID: clean(current.id),
        subjectKey: key,
        leaseToken: token,
        leaseUntil: nextLeaseUntil,
        revision,
      };
    }
  }
  throw new NotificationContractError(
    "Inbox is busy. Retry shortly.",
    409,
    "cas_contention",
  );
}

async function assertLease(store: any, lease: Lease, now: Date): Promise<void> {
  const matches = await store.filter(
    {
      id: lease.recordID,
      subject_key: lease.subjectKey,
      state: "active",
      lease_token: lease.leaseToken,
      revision: lease.revision,
    },
    "created_date",
    2,
    0,
  ) || [];
  if (
    matches.length !== 1 ||
    Date.parse(clean(matches[0].lease_until)) <= now.getTime() + CLOCK_SKEW_MS
  ) {
    throw new NotificationContractError(
      "Inbox write lease was lost.",
      409,
      "lease_lost",
    );
  }
}

async function release(
  store: any,
  lease: Lease,
  now: Date,
  randomUUID: () => string,
): Promise<void> {
  const result = await store.updateMany({
    id: lease.recordID,
    subject_key: lease.subjectKey,
    state: "active",
    lease_token: lease.leaseToken,
    revision: lease.revision,
  }, {
    $set: {
      lease_token: `released:${randomUUID()}`,
      lease_until: now.toISOString(),
      revision: randomUUID(),
    },
  });
  if (Number(result?.updated) !== 1) {
    throw new NotificationContractError(
      "Inbox write lease release could not be verified.",
      503,
      "lease_release_failed",
    );
  }
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

  try {
    await assertExactLease(input.lifecycleStore, lease, nowFactory());
    return await input.action(async <R>(writer: () => Promise<R>) => {
      await assertExactLease(input.lifecycleStore, lease, nowFactory());
      return await writer();
    });
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

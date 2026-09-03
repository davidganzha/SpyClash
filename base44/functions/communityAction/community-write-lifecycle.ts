import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

const COMMUNITY_WRITE_LEASE_ATTEMPTS = 7;
const COMMUNITY_WRITE_LEASE_BACKOFF_MILLISECONDS = [
  50,
  100,
  200,
  400,
  600,
  800,
];
const COMMUNITY_WRITE_LEASE_RELEASE_ATTEMPTS = 3;

type AcquireCommunityWriterLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<BillingIdentityLease>;

type ReleaseCommunityWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
) => Promise<void>;

type AssertCommunityWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
  now: Date,
) => Promise<void>;

type CommunityWriteLeaseDelay = (milliseconds: number) => Promise<void>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function safeLifecycleLogError(error: unknown) {
  const property = (key: string): unknown => {
    if (
      error === null ||
      (typeof error !== "object" && typeof error !== "function")
    ) return undefined;
    try {
      return Reflect.get(error, key);
    } catch {
      return undefined;
    }
  };
  const scalar = (value: unknown, maximum: number): string =>
    ["string", "number", "bigint", "boolean"].includes(typeof value)
      ? String(value).trim().slice(0, maximum)
      : "";
  return {
    message: scalar(property("message"), 500) ||
      scalar(error, 500) || "Unknown community lifecycle release error",
    status: scalar(property("status"), 3),
    code: scalar(property("code"), 100),
  };
}

function boundedAttemptCount(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return COMMUNITY_WRITE_LEASE_ATTEMPTS;
  }
  return Math.min(
    COMMUNITY_WRITE_LEASE_ATTEMPTS,
    Math.max(1, Math.trunc(value)),
  );
}

function retryableLeaseAcquisitionError(
  error: unknown,
): error is BillingIdentityLifecycleError {
  return error instanceof BillingIdentityLifecycleError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

async function defaultCommunityWriteLeaseDelay(
  milliseconds: number,
): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function releaseCommunityWriteLeases(input: {
  lifecycleStore: any;
  leases: readonly BillingIdentityLease[];
  release: ReleaseCommunityWriterLease;
  delay: CommunityWriteLeaseDelay;
}): Promise<unknown[]> {
  const failures: unknown[] = [];
  for (const lease of [...input.leases].reverse()) {
    let finalError: unknown;
    for (
      let attempt = 0;
      attempt < COMMUNITY_WRITE_LEASE_RELEASE_ATTEMPTS;
      attempt += 1
    ) {
      try {
        await input.release(input.lifecycleStore, lease);
        finalError = undefined;
        break;
      } catch (error) {
        finalError = error;
        if (attempt < COMMUNITY_WRITE_LEASE_RELEASE_ATTEMPTS - 1) {
          await input.delay(
            COMMUNITY_WRITE_LEASE_BACKOFF_MILLISECONDS[attempt],
          );
        }
      }
    }
    if (finalError !== undefined) failures.push(finalError);
  }
  return failures;
}

/**
 * Holds the same per-User writer lease used by retained billing identity.
 * deleteAccount takes the opposing `deleting` marker before relationship
 * cleanup, so a social create/update is either fully before cleanup or rejected.
 */
export async function withCommunityWriteLeases<T>(input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  action: (guard: {
    persist: <R>(writer: () => Promise<R>) => Promise<R>;
  }) => Promise<T>;
  nowFactory?: () => Date;
  randomUUID?: () => string;
  onReleaseError?: (error: unknown) => void;
  acquire?: AcquireCommunityWriterLease;
  release?: ReleaseCommunityWriterLease;
  assert?: AssertCommunityWriterLease;
  delay?: CommunityWriteLeaseDelay;
  attempts?: number;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const acquire = input.acquire ||
    ((lifecycleStore, userID) =>
      acquireBillingWriterLease(
        lifecycleStore,
        userID,
        nowFactory,
        randomUUID,
      ));
  const release = input.release ||
    ((lifecycleStore, lease) =>
      releaseBillingWriterLease(
        lifecycleStore,
        lease,
        nowFactory(),
        randomUUID,
      ));
  const assert = input.assert || assertBillingWriterLease;
  const delay = input.delay || defaultCommunityWriteLeaseDelay;
  const attempts = boundedAttemptCount(input.attempts);
  const userIDs = [...new Set(input.userIDs.map(clean).filter(Boolean))].sort();
  if (!userIDs.length) throw new Error("A social write owner is required.");

  let leases: BillingIdentityLease[] = [];
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    leases = [];
    try {
      for (const userID of userIDs) {
        leases.push(await acquire(input.lifecycleStore, userID));
      }
      break;
    } catch (error) {
      const releaseFailures = await releaseCommunityWriteLeases({
        lifecycleStore: input.lifecycleStore,
        leases,
        release,
        delay,
      });
      leases = [];
      if (releaseFailures.length) throw releaseFailures[0];
      if (
        !retryableLeaseAcquisitionError(error) ||
        attempt === attempts - 1
      ) {
        throw error;
      }
      await delay(COMMUNITY_WRITE_LEASE_BACKOFF_MILLISECONDS[attempt]);
    }
  }

  try {
    const assertLeases = async () => {
      const now = nowFactory();
      for (const lease of leases) {
        await assert(input.lifecycleStore, lease, now);
      }
    };
    await assertLeases();
    return await input.action({
      persist: async <R>(writer: () => Promise<R>) => {
        // This is the persistence boundary. Do not perform provider/entity
        // writes outside this callback.
        await assertLeases();
        return await writer();
      },
    });
  } finally {
    const releaseFailures = await releaseCommunityWriteLeases({
      lifecycleStore: input.lifecycleStore,
      leases,
      release,
      delay,
    });
    for (const error of releaseFailures) {
      if (input.onReleaseError) {
        input.onReleaseError(error);
      } else {
        console.error(
          "Community writer lease release failed",
          safeLifecycleLogError(error),
        );
      }
    }
  }
}

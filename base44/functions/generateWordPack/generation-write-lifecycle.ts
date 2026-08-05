import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

const GENERATION_LEASE_ACQUIRE_DELAYS_MILLISECONDS = [180, 520, 1_300];
const GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS = [50, 150];

type AcquireGenerationWriterLease = (
  lifecycleStore: any,
  userID: unknown,
  nowFactory: () => Date,
  randomUUID: () => string,
) => Promise<BillingIdentityLease>;

type ReleaseGenerationWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
  now: Date,
  randomUUID: () => string,
) => Promise<void>;

type GenerationLeaseDelay = (milliseconds: number) => Promise<void>;

async function defaultGenerationLeaseDelay(
  milliseconds: number,
): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

function canRetryGenerationLeaseAcquisition(error: unknown): boolean {
  return error instanceof BillingIdentityLifecycleError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

async function acquireGenerationWriterLease(input: {
  lifecycleStore: any;
  userID: string;
  nowFactory: () => Date;
  randomUUID: () => string;
  acquire: AcquireGenerationWriterLease;
  delay: GenerationLeaseDelay;
}): Promise<BillingIdentityLease> {
  for (
    let attempt = 0;
    attempt <= GENERATION_LEASE_ACQUIRE_DELAYS_MILLISECONDS.length;
    attempt += 1
  ) {
    try {
      return await input.acquire(
        input.lifecycleStore,
        input.userID,
        input.nowFactory,
        input.randomUUID,
      );
    } catch (error) {
      if (
        !canRetryGenerationLeaseAcquisition(error) ||
        attempt >= GENERATION_LEASE_ACQUIRE_DELAYS_MILLISECONDS.length
      ) {
        throw error;
      }
      await input.delay(
        GENERATION_LEASE_ACQUIRE_DELAYS_MILLISECONDS[attempt],
      );
    }
  }

  throw new Error("Generation writer lease retry loop exhausted unexpectedly.");
}

export type GenerationWriteGuard = {
  /** Reasserts the exact writer lease immediately before a write/provider call. */
  boundary: <T>(operation: () => Promise<T>) => Promise<T>;
};

/**
 * Serializes generation quota/provider side effects against account deletion.
 * The boundary callback is deliberately the only place a caller may perform
 * an entity write or InvokeLLM call.
 */
export async function withGenerationWriterLease<T>(input: {
  lifecycleStore: any;
  userID: string;
  action: (guard: GenerationWriteGuard) => Promise<T>;
  nowFactory?: () => Date;
  randomUUID?: () => string;
  acquire?: AcquireGenerationWriterLease;
  release?: ReleaseGenerationWriterLease;
  delay?: GenerationLeaseDelay;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const acquire = input.acquire || acquireBillingWriterLease;
  const release = input.release || releaseBillingWriterLease;
  const delay = input.delay || defaultGenerationLeaseDelay;
  // Another identity-coordinated writer can overlap the user's first
  // generation request. Only retry transient lease contention, and do it
  // before the action can reserve quota, call the provider, or persist an
  // idempotent result.
  const lease = await acquireGenerationWriterLease({
    lifecycleStore: input.lifecycleStore,
    userID: input.userID,
    nowFactory,
    randomUUID,
    acquire,
    delay,
  });

  let actionFailed = false;
  try {
    return await input.action({
      boundary: async <R>(operation: () => Promise<R>) => {
        await assertBillingWriterLease(
          input.lifecycleStore,
          lease,
          nowFactory(),
        );
        return await operation();
      },
    });
  } catch (error) {
    actionFailed = true;
    throw error;
  } finally {
    let releaseError: unknown;
    for (
      let attempt = 0;
      attempt <= GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS.length;
      attempt += 1
    ) {
      try {
        await release(
          input.lifecycleStore,
          lease,
          nowFactory(),
          randomUUID,
        );
        releaseError = undefined;
        break;
      } catch (error) {
        releaseError = error;
        if (attempt < GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS.length) {
          await delay(
            GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS[attempt],
          );
        }
      }
    }

    // A failed release leaves a bounded, deletion-blocking lease behind. It is
    // safe to report the already committed generation result; converting that
    // success into a 503 only causes duplicate user retries and quota usage.
    if (releaseError !== undefined) {
      console.error(
        actionFailed
          ? "generateWordPack lease release failed after action error"
          : "generateWordPack lease release failed after committed action",
        releaseError,
      );
    }
  }
}

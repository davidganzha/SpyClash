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
  /** Holds the account deletion-opposing lease only around an entity write. */
  boundary: <T>(operation: () => Promise<T>) => Promise<T>;
  /** Refuses new provider work when deletion already owns the account. */
  assertAvailable: () => Promise<void>;
};

export function generationCoordinationUserID(userID: string): string {
  return `ai-generation:${String(userID ?? "").trim()}`;
}

async function releaseGenerationLease(input: {
  lifecycleStore: any;
  lease: BillingIdentityLease;
  nowFactory: () => Date;
  randomUUID: () => string;
  release: ReleaseGenerationWriterLease;
  delay: GenerationLeaseDelay;
}): Promise<unknown | undefined> {
  let releaseError: unknown;
  for (
    let attempt = 0;
    attempt <= GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS.length;
    attempt += 1
  ) {
    try {
      await input.release(
        input.lifecycleStore,
        input.lease,
        input.nowFactory(),
        input.randomUUID,
      );
      return undefined;
    } catch (error) {
      releaseError = error;
      if (attempt < GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS.length) {
        await input.delay(
          GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS[attempt],
        );
      }
    }
  }
  return releaseError;
}

/**
 * Serializes AI work per account without holding the shared account lifecycle
 * lease across provider latency. Every entity write still obtains the root
 * deletion-opposing lease for its own short persistence boundary.
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
  const coordinationLease = await acquireGenerationWriterLease({
    lifecycleStore: input.lifecycleStore,
    userID: generationCoordinationUserID(input.userID),
    nowFactory,
    randomUUID,
    acquire,
    delay,
  });

  const accountBoundary = async <R>(
    operation: () => Promise<R>,
    releaseFailureIsFatal: boolean,
  ): Promise<R> => {
    const accountLease = await acquireGenerationWriterLease({
      lifecycleStore: input.lifecycleStore,
      userID: input.userID,
      nowFactory,
      randomUUID,
      acquire,
      delay,
    });
    let result: R | undefined;
    let operationError: unknown;
    try {
      await assertBillingWriterLease(
        input.lifecycleStore,
        accountLease,
        nowFactory(),
      );
      result = await operation();
    } catch (error) {
      operationError = error;
    }
    const releaseError = await releaseGenerationLease({
      lifecycleStore: input.lifecycleStore,
      lease: accountLease,
      nowFactory,
      randomUUID,
      release,
      delay,
    });
    if (operationError !== undefined) throw operationError;
    if (releaseError !== undefined) {
      if (releaseFailureIsFatal) throw releaseError;
      console.error(
        "generateWordPack account lease release failed after committed write",
        releaseError,
      );
    }
    return result as R;
  };

  let actionError: unknown;
  let result: T | undefined;
  try {
    result = await input.action({
      boundary: <R>(operation: () => Promise<R>) =>
        accountBoundary(operation, false),
      assertAvailable: () => accountBoundary(() => Promise.resolve(), true),
    });
  } catch (error) {
    actionError = error;
  }
  const coordinationReleaseError = await releaseGenerationLease({
    lifecycleStore: input.lifecycleStore,
    lease: coordinationLease,
    nowFactory,
    randomUUID,
    release,
    delay,
  });
  if (actionError !== undefined) throw actionError;
  if (coordinationReleaseError !== undefined) {
    console.error(
      "generateWordPack coordination lease release failed after committed action",
      coordinationReleaseError,
    );
  }
  return result as T;
}

import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

const GENERATION_LEASE_RELEASE_DELAYS_MILLISECONDS = [50, 150];

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
  release?: ReleaseGenerationWriterLease;
  delay?: GenerationLeaseDelay;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const release = input.release || releaseBillingWriterLease;
  const delay = input.delay || defaultGenerationLeaseDelay;
  const lease = await acquireBillingWriterLease(
    input.lifecycleStore,
    input.userID,
    nowFactory,
    randomUUID,
  );

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

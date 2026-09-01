import {
  acquireBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";
import { safeWordPackErrorDetails } from "./safe-error.ts";

const WORD_PACK_WRITE_LEASE_ATTEMPTS = 7;
const WORD_PACK_WRITE_LEASE_BACKOFF_MS = [50, 100, 200, 400, 600, 800];
const WORD_PACK_WRITE_LEASE_RELEASE_ATTEMPTS = 3;

type AcquireWriterLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<BillingIdentityLease>;

type ReleaseWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
) => Promise<void>;

type WordPackWriteLeaseDelay = (milliseconds: number) => Promise<void>;

function boundedAttemptCount(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return WORD_PACK_WRITE_LEASE_ATTEMPTS;
  }
  return Math.min(
    WORD_PACK_WRITE_LEASE_ATTEMPTS,
    Math.max(1, Math.trunc(value)),
  );
}

function retryableLeaseAcquisitionError(
  error: unknown,
): error is BillingIdentityLifecycleError {
  return error instanceof BillingIdentityLifecycleError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function releaseWithRetries(input: {
  lifecycleStore: any;
  lease: BillingIdentityLease;
  release: ReleaseWriterLease;
  delay: WordPackWriteLeaseDelay;
}): Promise<unknown | undefined> {
  let finalError: unknown;
  for (
    let attempt = 0;
    attempt < WORD_PACK_WRITE_LEASE_RELEASE_ATTEMPTS;
    attempt += 1
  ) {
    try {
      await input.release(input.lifecycleStore, input.lease);
      return undefined;
    } catch (error) {
      finalError = error;
      if (attempt < WORD_PACK_WRITE_LEASE_RELEASE_ATTEMPTS - 1) {
        try {
          await input.delay(WORD_PACK_WRITE_LEASE_BACKOFF_MS[attempt]);
        } catch {
          // Cleanup is best effort and must not replace a committed result.
        }
      }
    }
  }
  return finalError;
}

/**
 * Preserves the action result when only best-effort lease cleanup fails.
 * Turning that committed success into an error would invite duplicate writes.
 */
export async function withWordPackWriterLease<T>(input: {
  lifecycleStore: any;
  userID: string;
  action: (lease: BillingIdentityLease) => Promise<T>;
  acquire?: AcquireWriterLease;
  release?: ReleaseWriterLease;
  onReleaseError?: (error: unknown) => void;
  delay?: WordPackWriteLeaseDelay;
  attempts?: number;
}): Promise<T> {
  const acquire = input.acquire || acquireBillingWriterLease;
  const release = input.release || releaseBillingWriterLease;
  const delay = input.delay || defaultDelay;
  const attempts = boundedAttemptCount(input.attempts);

  let lease: BillingIdentityLease | undefined;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      lease = await acquire(input.lifecycleStore, input.userID);
      break;
    } catch (error) {
      if (
        !retryableLeaseAcquisitionError(error) || attempt === attempts - 1
      ) {
        throw error;
      }
      await delay(WORD_PACK_WRITE_LEASE_BACKOFF_MS[attempt]);
    }
  }
  if (!lease) {
    throw new BillingIdentityLifecycleError(
      "cas_contention",
      "Billing lifecycle changed concurrently.",
    );
  }

  let result: T | undefined;
  let actionError: unknown;
  try {
    result = await input.action(lease);
  } catch (error) {
    actionError = error;
  }

  const releaseError = await releaseWithRetries({
    lifecycleStore: input.lifecycleStore,
    lease,
    release,
    delay,
  });
  if (releaseError !== undefined) {
    if (input.onReleaseError) {
      input.onReleaseError(releaseError);
    } else {
      const details = safeWordPackErrorDetails(releaseError);
      console.error(
        "wordPackAction lease release failed",
        details.message,
        details.status,
        details.code,
      );
    }
  }

  if (actionError !== undefined) throw actionError;
  return result as T;
}

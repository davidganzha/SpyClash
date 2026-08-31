import {
  acquireBillingWriterLease,
  type BillingIdentityLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

type AcquireWriterLease = (
  lifecycleStore: any,
  userID: string,
) => Promise<BillingIdentityLease>;

type ReleaseWriterLease = (
  lifecycleStore: any,
  lease: BillingIdentityLease,
) => Promise<void>;

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
}): Promise<T> {
  const acquire = input.acquire || acquireBillingWriterLease;
  const release = input.release || releaseBillingWriterLease;
  const lease = await acquire(input.lifecycleStore, input.userID);

  let result: T | undefined;
  let actionError: unknown;
  try {
    result = await input.action(lease);
  } catch (error) {
    actionError = error;
  }

  try {
    await release(input.lifecycleStore, lease);
  } catch (releaseError) {
    if (input.onReleaseError) {
      input.onReleaseError(releaseError);
    } else {
      console.error("wordPackAction lease release failed", releaseError);
    }
  }

  if (actionError !== undefined) throw actionError;
  return result as T;
}

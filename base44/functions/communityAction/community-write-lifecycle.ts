import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

function clean(value: unknown): string {
  return String(value ?? "").trim();
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
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const userIDs = [...new Set(input.userIDs.map(clean).filter(Boolean))].sort();
  if (!userIDs.length) throw new Error("A social write owner is required.");

  const leases: BillingIdentityLease[] = [];
  try {
    for (const userID of userIDs) {
      leases.push(
        await acquireBillingWriterLease(
          input.lifecycleStore,
          userID,
          nowFactory,
          randomUUID,
        ),
      );
    }
    const assertLeases = async () => {
      const now = nowFactory();
      for (const lease of leases) {
        await assertBillingWriterLease(input.lifecycleStore, lease, now);
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
    for (const lease of [...leases].reverse()) {
      try {
        await releaseBillingWriterLease(
          input.lifecycleStore,
          lease,
          nowFactory(),
          randomUUID,
        );
      } catch (error) {
        if (input.onReleaseError) {
          input.onReleaseError(error);
        } else {
          console.error("Community writer lease release failed", error);
        }
      }
    }
  }
}

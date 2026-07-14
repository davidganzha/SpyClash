import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

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
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const lease = await acquireBillingWriterLease(
    input.lifecycleStore,
    input.userID,
    nowFactory,
    randomUUID,
  );

  let actionError: unknown;
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
    actionError = error;
    throw error;
  } finally {
    try {
      await releaseBillingWriterLease(
        input.lifecycleStore,
        lease,
        nowFactory(),
        randomUUID,
      );
    } catch (error) {
      if (!actionError) throw error;
      console.error("generateWordPack lease release failed", error);
    }
  }
}

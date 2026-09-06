import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import type { PreparedWordPackIdempotency } from "./generation-idempotency.ts";
import type { GenerationWriteGuard } from "./generation-write-lifecycle.ts";

export type GenerationRetryMetadata = {
  retryable: boolean;
  retry_phase?: "before_effects" | "effects_may_have_started";
  effects_started?: boolean;
};

/**
 * This proof belongs to one invocation, not to the lifetime of a request_id.
 * A client may only repeat a proven pre-effect conflict with the same payload;
 * a missing response or a previous ambiguous failure is not permission to retry.
 */
export function createGenerationRetryTracker() {
  let hasValidatedRequestIdentity = false;
  let effectsStarted = false;

  return {
    bindValidatedRequest(identity: PreparedWordPackIdempotency | null): void {
      hasValidatedRequestIdentity = identity !== null;
    },

    trackWrites(guard: GenerationWriteGuard): GenerationWriteGuard {
      return {
        boundary: <T>(operation: () => Promise<T>) =>
          guard.boundary(() => {
            // Acquisition/assertion can fail before this callback runs. Once
            // storage is called, even a failed response can hide a commit.
            effectsStarted = true;
            return operation();
          }),
        assertAvailable: () => guard.assertAvailable(),
      };
    },

    async runProvider<T>(
      guard: GenerationWriteGuard,
      operation: () => Promise<T>,
    ): Promise<T> {
      await guard.assertAvailable();
      effectsStarted = true;
      return await operation();
    },

    errorMetadata(error: unknown, status: number): GenerationRetryMetadata {
      if (effectsStarted) {
        return {
          retryable: false,
          retry_phase: "effects_may_have_started",
          effects_started: true,
        };
      }

      if (error instanceof BillingIdentityLifecycleError) {
        const safeConflict = hasValidatedRequestIdentity && status === 409 &&
          (error.code === "active_lease" || error.code === "cas_contention");
        return safeConflict
          ? {
            retryable: true,
            retry_phase: "before_effects",
            effects_started: false,
          }
          : { retryable: false };
      }

      // Keep other existing error semantics, without issuing the stronger
      // proof required for an automatic generation retry.
      return {
        retryable: (error as { retryable?: unknown })?.retryable === true,
      };
    },
  };
}

export type GenerationRetryTracker = ReturnType<
  typeof createGenerationRetryTracker
>;

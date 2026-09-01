import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";

const BACKOFF_MS = [100, 250, 500, 1_000, 2_000] as const;

function retryable(error: unknown): boolean {
  return error instanceof BillingIdentityLifecycleError &&
    (error.code === "active_lease" || error.code === "cas_contention");
}

export async function withBillingLifecycleContentionRetry<T>(input: {
  deadlineEpochMs: number;
  operation: () => Promise<T>;
  nowEpochMs?: () => number;
  delay?: (milliseconds: number) => Promise<void>;
}): Promise<T> {
  const nowEpochMs = input.nowEpochMs || Date.now;
  const wait = input.delay ||
    ((milliseconds: number) =>
      new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  let retryIndex = 0;

  for (;;) {
    try {
      return await input.operation();
    } catch (error) {
      if (!retryable(error)) throw error;
      const remaining = Math.floor(input.deadlineEpochMs - nowEpochMs());
      if (remaining <= 1) throw error;
      const requested = BACKOFF_MS[
        Math.min(
          retryIndex,
          BACKOFF_MS.length - 1,
        )
      ];
      retryIndex += 1;
      await wait(Math.max(1, Math.min(requested, remaining - 1)));
      if (nowEpochMs() >= input.deadlineEpochMs) throw error;
    }
  }
}

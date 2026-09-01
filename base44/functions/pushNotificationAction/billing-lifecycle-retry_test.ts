import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { withBillingLifecycleContentionRetry } from "./billing-lifecycle-retry.ts";

Deno.test("prompt delivery retries a transient active lease then sends once", async () => {
  let now = 0;
  let attempts = 0;
  let sends = 0;
  const waits: number[] = [];

  const outcome = await withBillingLifecycleContentionRetry({
    deadlineEpochMs: 20_000,
    nowEpochMs: () => now,
    delay: (milliseconds) => {
      waits.push(milliseconds);
      now += milliseconds;
      return Promise.resolve();
    },
    operation: async () => {
      attempts += 1;
      if (attempts === 1) {
        throw new BillingIdentityLifecycleError(
          "active_lease",
          "late signal still owns the user lease",
        );
      }
      sends += 1;
      return "delivered" as const;
    },
  });

  assertEquals(outcome, "delivered");
  assertEquals(attempts, 2);
  assertEquals(sends, 1);
  assertEquals(waits, [100]);
});

Deno.test("prompt retry is bounded by its wall clock deadline", async () => {
  let now = 0;
  let attempts = 0;
  const error = await assertRejects(
    () =>
      withBillingLifecycleContentionRetry({
        deadlineEpochMs: 300,
        nowEpochMs: () => now,
        delay: (milliseconds) => {
          now += milliseconds;
          return Promise.resolve();
        },
        operation: () => {
          attempts += 1;
          return Promise.reject(
            new BillingIdentityLifecycleError(
              "cas_contention",
              "lease revision changed",
            ),
          );
        },
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "cas_contention");
  assertEquals(now, 299);
  assertEquals(attempts, 3);
});

Deno.test("non-lifecycle errors are never replayed", async () => {
  let attempts = 0;
  await assertRejects(
    () =>
      withBillingLifecycleContentionRetry({
        deadlineEpochMs: 20_000,
        operation: () => {
          attempts += 1;
          return Promise.reject(new Error("APNs failed after send"));
        },
      }),
    Error,
    "APNs failed after send",
  );
  assertEquals(attempts, 1);
});

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import { withWordPackWriterLease } from "./word-pack-write-lifecycle.ts";

const lease: BillingIdentityLease = {
  recordID: "lifecycle-1",
  subjectKey: "subject-1",
  state: "active",
  leaseToken: "lease-1",
  leaseUntil: "2030-01-01T00:00:00.000Z",
  revision: "revision-1",
};

Deno.test("committed word-pack write survives lease release failure", async () => {
  const releaseErrors: unknown[] = [];
  const result = await withWordPackWriterLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => Promise.resolve(lease),
    release: () => Promise.reject(new Error("release unavailable")),
    onReleaseError: (error) => releaseErrors.push(error),
    action: () => Promise.resolve("committed"),
  });

  assertEquals(result, "committed");
  assertEquals(releaseErrors.length, 1);
});

Deno.test("word-pack action error wins over cleanup failure", async () => {
  const actionError = new Error("write failed");
  const error = await assertRejects(() =>
    withWordPackWriterLease({
      lifecycleStore: {},
      userID: "user-1",
      acquire: () => Promise.resolve(lease),
      release: () => Promise.reject(new Error("release unavailable")),
      onReleaseError: () => undefined,
      action: () => Promise.reject(actionError),
    })
  );

  assertEquals(error, actionError);
});

Deno.test("word-pack lease acquisition retries before invoking the action once", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];
  const released: string[] = [];

  const result = await withWordPackWriterLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => {
      acquireCalls += 1;
      if (acquireCalls <= 2) {
        throw new BillingIdentityLifecycleError(
          acquireCalls === 1 ? "active_lease" : "cas_contention",
          "brief contention",
        );
      }
      return Promise.resolve({
        ...lease,
        leaseToken: `lease-${acquireCalls}`,
      });
    },
    release: (_store, acquiredLease) => {
      released.push(acquiredLease.leaseToken);
      return Promise.resolve();
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    action: () => {
      actionCalls += 1;
      return Promise.resolve("committed");
    },
  });

  assertEquals(result, "committed");
  assertEquals(acquireCalls, 3);
  assertEquals(actionCalls, 1);
  assertEquals(delays, [50, 100]);
  assertEquals(released, ["lease-3"]);
});

Deno.test("exhausted word-pack lease contention remains a typed 409 source", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withWordPackWriterLease({
        lifecycleStore: {},
        userID: "user-1",
        acquire: () => {
          acquireCalls += 1;
          throw new BillingIdentityLifecycleError(
            "active_lease",
            "still busy",
          );
        },
        release: () => Promise.resolve(),
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(acquireCalls, 7);
  assertEquals(actionCalls, 0);
  assertEquals(delays, [50, 100, 200, 400, 600, 800]);
});

Deno.test("word-pack action contention is never replayed", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const actionError = new BillingIdentityLifecycleError(
    "cas_contention",
    "persistence changed",
  );

  const error = await assertRejects(
    () =>
      withWordPackWriterLease({
        lifecycleStore: {},
        userID: "user-1",
        acquire: () => {
          acquireCalls += 1;
          return Promise.resolve(lease);
        },
        release: () => Promise.resolve(),
        delay: () => Promise.resolve(),
        action: () => {
          actionCalls += 1;
          return Promise.reject(actionError);
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error, actionError);
  assertEquals(acquireCalls, 1);
  assertEquals(actionCalls, 1);
});

Deno.test("word-pack lease cleanup retries before reporting failure", async () => {
  let releaseCalls = 0;
  const delays: number[] = [];
  const releaseErrors: unknown[] = [];

  const result = await withWordPackWriterLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => Promise.resolve(lease),
    release: () => {
      releaseCalls += 1;
      if (releaseCalls < 3) throw new Error("release unavailable");
      return Promise.resolve();
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    onReleaseError: (error) => releaseErrors.push(error),
    action: () => Promise.resolve("committed"),
  });

  assertEquals(result, "committed");
  assertEquals(releaseCalls, 3);
  assertEquals(delays, [50, 100]);
  assertEquals(releaseErrors, []);
});

Deno.test("exhausted word-pack cleanup still preserves committed success", async () => {
  let releaseCalls = 0;
  const releaseErrors: unknown[] = [];

  const result = await withWordPackWriterLease({
    lifecycleStore: {},
    userID: "user-1",
    acquire: () => Promise.resolve(lease),
    release: () => {
      releaseCalls += 1;
      return Promise.reject(new Error("release unavailable"));
    },
    delay: () => Promise.resolve(),
    onReleaseError: (error) => releaseErrors.push(error),
    action: () => Promise.resolve("committed"),
  });

  assertEquals(result, "committed");
  assertEquals(releaseCalls, 3);
  assertEquals(releaseErrors.length, 1);
});

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { BillingIdentityLease } from "./billing-identity-lifecycle.ts";
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

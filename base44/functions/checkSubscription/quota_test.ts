import { quotaKey, totalQuotaUsage } from "./quota.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("membership usage reads the same user and UTC-day quota key", () => {
  assert(
    quotaKey("user-123", new Date("2026-07-13T23:59:59Z")) ===
      "user-123:2026-07-13",
    "checkSubscription quota key drifted from generateWordPack",
  );
});

Deno.test("membership usage sums duplicate quota rows fail-closed", () => {
  assert(
    totalQuotaUsage([
      { generations_used: 4 },
      { generations_used: 6 },
      { generations_used: -2 },
    ]) === 10,
    "checkSubscription under-reported authoritative usage",
  );
});

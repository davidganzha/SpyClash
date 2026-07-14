import {
  applyAdminGenerationGrant,
  canGenerate,
  FREE_BENEFITS,
  generationUsageMetadata,
  LIMITLESS_BENEFITS,
  resolveGenerationMembership,
} from "./membership.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("FREE generation policy is ten successful generations per UTC day", () => {
  assert(canGenerate("free", 9), "FREE user should receive generation ten");
  assert(!canGenerate("free", 10), "FREE user exceeded the daily limit");
  assert(canGenerate("limitless", 10_000), "LIMITLESS user was capped");
});

Deno.test("generation membership trusts only a valid provider entitlement", () => {
  const now = new Date("2026-07-13T12:00:00Z");
  const free = resolveGenerationMembership([
    { provider: "apple", status: "active" },
    {
      provider: "stripe",
      status: "active",
      expires_at: "2026-07-13T11:59:59Z",
    },
    {
      provider: "apple",
      status: "billing_retry",
      expires_at: "2026-07-20T12:00:00Z",
    },
  ], now);
  assert(free.tier === "free", "invalid entitlement unlocked LIMITLESS");
  assert(
    JSON.stringify(free.benefits) === JSON.stringify(FREE_BENEFITS),
    "FREE benefits drifted",
  );

  const limitless = resolveGenerationMembership([
    {
      provider: "apple",
      status: "grace_period",
      expires_at: "2026-07-20T12:00:00Z",
    },
  ], now);
  assert(
    limitless.tier === "limitless",
    "valid grace period did not unlock LIMITLESS",
  );
  assert(
    JSON.stringify(limitless.benefits) === JSON.stringify(LIMITLESS_BENEFITS),
    "LIMITLESS benefits drifted",
  );
});

Deno.test("usage metadata is explicit for FREE and unlimited for LIMITLESS", () => {
  const free = generationUsageMetadata("free", 7);
  assert(free.ai_limit === 10, "legacy FREE ai_limit missing");
  assert(
    free.ai_generations_daily_limit === 10,
    "canonical FREE AI limit missing",
  );
  assert(free.ai_remaining === 3, "FREE remaining count incorrect");

  const limitless = generationUsageMetadata("limitless", 900);
  assert(limitless.ai_limit === null, "LIMITLESS legacy limit must be null");
  assert(
    limitless.ai_generations_daily_limit === null,
    "LIMITLESS canonical limit must be null",
  );
  assert(limitless.ai_remaining === null, "LIMITLESS remaining must be null");
});

Deno.test("newer revocation wins over a duplicate active provider row", () => {
  const membership = resolveGenerationMembership([
    {
      id: "old",
      source_key: "apple:original-123",
      provider: "apple",
      status: "active",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T12:00:00Z",
    },
    {
      id: "new",
      source_key: "apple:original-123",
      provider: "apple",
      status: "revoked",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T13:00:00Z",
    },
  ], new Date("2026-07-13T14:00:00Z"));

  assert(membership.tier === "free", "stale duplicate granted unlimited AI");
});

Deno.test("admin grant receives unlimited generation policy", () => {
  const now = new Date("2026-07-14T12:00:00Z");
  const membership = applyAdminGenerationGrant(
    resolveGenerationMembership([], now),
    [{ active: true }],
    now,
  );
  assert(membership.tier === "limitless", "admin grant stayed FREE");
  assert(membership.providers.includes("admin"), "admin provider missing");
  assert(canGenerate(membership.tier, 1000), "admin grant was quota-capped");
});

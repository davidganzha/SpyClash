import {
  applyAdminGenerationGrant,
  applyCasadaGenerationAccess,
  canGenerate,
  CASADA_BENEFITS,
  CASADA_COMPATIBILITY_EXPIRY,
  generationUsageMetadata,
  LEGACY_FREE_BENEFITS,
  resolveGenerationMembership,
} from "./membership.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("legacy free is capped while CASADA generation is unlimited", () => {
  assert(canGenerate("free", 9), "FREE user should receive generation ten");
  assert(!canGenerate("free", 10), "FREE user exceeded the daily limit");
  assert(canGenerate("limitless", 10_000), "CASADA user was capped");
});

Deno.test("CASADA removes the generator limit without inventing a provider", () => {
  const membership = applyCasadaGenerationAccess(
    resolveGenerationMembership([]),
  );
  assert(membership.active, "CASADA access was not activated");
  assert(
    membership.tier === "limitless",
    "legacy-compatible CASADA tier was not selected",
  );
  assert(membership.protocol === "casada", "CASADA protocol marker missing");
  assert(membership.providers.includes("casada"), "CASADA source missing");
  assert(
    membership.expires_at === CASADA_COMPATIBILITY_EXPIRY,
    "CASADA compatibility expiry drifted",
  );
  assert(
    canGenerate(membership.tier, 100_000),
    "CASADA retained the legacy generation limit",
  );
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
  assert(free.tier === "free", "invalid entitlement unlocked provider access");
  assert(
    JSON.stringify(free.benefits) === JSON.stringify(LEGACY_FREE_BENEFITS),
    "FREE benefits drifted",
  );

  const providerBacked = resolveGenerationMembership([
    {
      provider: "apple",
      status: "grace_period",
      expires_at: "2026-07-20T12:00:00Z",
    },
  ], now);
  assert(
    providerBacked.tier === "limitless",
    "valid grace period did not retain provider-backed access",
  );
  assert(
    JSON.stringify(providerBacked.benefits) === JSON.stringify(CASADA_BENEFITS),
    "CASADA benefits drifted",
  );
});

Deno.test("usage metadata preserves legacy free fields and CASADA is unlimited", () => {
  const free = generationUsageMetadata("free", 7);
  assert(free.ai_limit === 10, "legacy FREE ai_limit missing");
  assert(
    free.ai_generations_daily_limit === 10,
    "canonical FREE AI limit missing",
  );
  assert(free.ai_remaining === 3, "FREE remaining count incorrect");

  const casada = generationUsageMetadata("limitless", 900);
  assert(casada.ai_limit === null, "CASADA legacy limit must be null");
  assert(
    casada.ai_generations_daily_limit === null,
    "CASADA canonical limit must be null",
  );
  assert(casada.ai_remaining === null, "CASADA remaining must be null");
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

  assert(membership.tier === "free", "stale duplicate granted provider access");
});

Deno.test("admin grant receives unlimited generation policy", () => {
  const now = new Date("2026-07-14T12:00:00Z");
  const membership = applyAdminGenerationGrant(
    resolveGenerationMembership([], now),
    [{ active: true }],
    now,
  );
  assert(
    membership.tier === "limitless",
    "admin grant lost legacy tier compatibility",
  );
  assert(membership.providers.includes("admin"), "admin provider missing");
  assert(canGenerate(membership.tier, 1000), "admin grant was quota-capped");
});

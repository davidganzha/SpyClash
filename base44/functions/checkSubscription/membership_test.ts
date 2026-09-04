import {
  activeAdminGrantExpiry,
  applyAdminGrant,
  applyCasadaAccess,
  CASADA_BENEFITS,
  CASADA_COMPATIBILITY_EXPIRY,
  casadaMembershipResponse,
  hasStripePrice,
  isBoundToAnotherUser,
  isEntitlementActive,
  LEGACY_FREE_BENEFITS,
  mergeEntitlements,
  stripeStatusToEntitlementStatus,
  summarizeMembership,
} from "./membership.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("legacy provider summary remains restricted before CASADA overlay", () => {
  const membership = summarizeMembership([], new Date("2026-07-13T12:00:00Z"));
  assert(membership.active === false, "empty entitlement set must be inactive");
  assert(membership.tier === "free", "empty entitlement set must be FREE");
  assert(
    JSON.stringify(membership.benefits) ===
      JSON.stringify(LEGACY_FREE_BENEFITS),
    "legacy free benefits drifted",
  );
  assert(
    membership.benefits.ai_generations_daily_limit === 10,
    "FREE AI limit drifted",
  );
  assert(membership.benefits.history_limit === 5, "FREE history limit drifted");
});

Deno.test("CASADA grants every authenticated user full access without a provider", () => {
  const membership = applyCasadaAccess(summarizeMembership([]));
  assert(membership.active, "CASADA access was not activated");
  assert(
    membership.tier === "limitless",
    "legacy-compatible CASADA tier was not selected",
  );
  assert(membership.protocol === "casada", "CASADA protocol marker missing");
  assert(
    membership.providers.length === 1 && membership.providers[0] === "casada",
    "CASADA access source missing",
  );
  assert(
    membership.expires_at === CASADA_COMPATIBILITY_EXPIRY,
    "CASADA compatibility expiry drifted",
  );
  assert(
    membership.benefits.full_history,
    "CASADA did not unlock full history",
  );
  assert(membership.benefits.premium_avatars, "CASADA did not unlock avatars");
  assert(
    membership.benefits.ai_generations_daily_limit === null,
    "CASADA retained a generator limit",
  );
});

Deno.test("CASADA membership response has no billing or quota dependency", () => {
  const response = casadaMembershipResponse(
    new Date("2026-07-25T08:00:00.000Z"),
  );
  assert(response?.active === true, "CASADA response was not active");
  assert(
    response?.tier === "limitless",
    "CASADA response lost build-7 tier compatibility",
  );
  assert(response?.protocol === "casada", "CASADA response marker drifted");
  assert(
    response?.providers.length === 1 && response.providers[0] === "casada",
    "CASADA response access source drifted",
  );
  assert(response?.ai_remaining === null, "CASADA response retained quota");
  assert(
    response?.expires_at === CASADA_COMPATIBILITY_EXPIRY,
    "CASADA response compatibility expiry drifted",
  );
  assert(response?.checkout_required === false, "checkout was still required");
  assert(
    Object.values(response?.provider_sync || {}).every((value) =>
      value === "not_required"
    ),
    "CASADA response still depends on billing synchronization",
  );
});

Deno.test("verified Apple entitlement remains a legacy provider source", () => {
  const membership = summarizeMembership([
    {
      provider: "apple",
      status: "active",
      expires_at: "2026-07-20T12:00:00Z",
    },
  ], new Date("2026-07-13T12:00:00Z"));

  assert(membership.active, "active Apple entitlement was rejected");
  assert(
    membership.tier === "limitless",
    "active Apple entitlement did not resolve full access",
  );
  assert(membership.providers[0] === "apple", "Apple provider missing");
  assert(
    JSON.stringify(membership.benefits) === JSON.stringify(CASADA_BENEFITS),
    "CASADA benefits drifted",
  );
});

Deno.test("expired and billing-retry records do not grant access", () => {
  const now = new Date("2026-07-13T12:00:00Z");
  assert(
    !isEntitlementActive({ status: "active" }, now),
    "missing expiry granted permanent subscription access",
  );
  assert(
    !isEntitlementActive({
      status: "active",
      expires_at: "2026-07-13T11:59:59Z",
    }, now),
    "expired active record granted access",
  );
  assert(
    !isEntitlementActive({
      status: "billing_retry",
      expires_at: "2026-07-20T12:00:00Z",
    }, now),
    "billing retry granted access without grace period",
  );
  assert(
    isEntitlementActive({
      provider: "apple",
      status: "grace_period",
      expires_at: "2026-07-20T12:00:00Z",
    }, now),
    "grace period should grant access",
  );
});

Deno.test("legacy Stripe verification requires the deployed price id", () => {
  assert(
    hasStripePrice(["price_legacy"], "price_legacy"),
    "current legacy price was rejected",
  );
  assert(
    !hasStripePrice(["price_downgraded"], "price_legacy"),
    "different current price retained provider access",
  );
});

Deno.test("multiple providers expose the furthest verified expiry", () => {
  const membership = summarizeMembership([
    { provider: "apple", status: "active", expires_at: "2026-07-20T12:00:00Z" },
    {
      provider: "stripe",
      status: "active",
      expires_at: "2026-07-27T12:00:00Z",
    },
  ], new Date("2026-07-13T12:00:00Z"));

  assert(
    membership.providers.length === 2,
    "both active providers must be reported",
  );
  assert(
    membership.expires_at === "2026-07-27T12:00:00Z",
    "combined expiry should follow the furthest valid provider",
  );
});

Deno.test("Stripe statuses normalize without treating provider errors as active", () => {
  assert(
    stripeStatusToEntitlementStatus("active") === "active",
    "active mapping failed",
  );
  assert(
    stripeStatusToEntitlementStatus("trialing") === "trialing",
    "trialing mapping failed",
  );
  assert(
    stripeStatusToEntitlementStatus("past_due") === "past_due",
    "past_due mapping failed",
  );
  assert(
    stripeStatusToEntitlementStatus("not-a-status") === "unknown",
    "unknown mapping failed",
  );
});

Deno.test("live Stripe verification replaces a stale stored status", () => {
  const sourceKey = "stripe:sub_123";
  const merged = mergeEntitlements(
    [{
      source_key: sourceKey,
      provider: "stripe",
      status: "active",
      expires_at: "2026-07-20T12:00:00Z",
    }],
    [{
      source_key: sourceKey,
      provider: "stripe",
      status: "canceled",
      expires_at: "2026-07-20T12:00:00Z",
    }],
  );
  const membership = summarizeMembership(
    merged,
    new Date("2026-07-13T12:00:00Z"),
  );
  assert(
    merged.length === 1,
    "verified source should replace, not duplicate, stored source",
  );
  assert(
    membership.tier === "free",
    "stale stored Stripe status still granted provider access",
  );
});

Deno.test("newest stored provider event wins if concurrent writes made duplicates", () => {
  const sourceKey = "apple:original-123";
  const merged = mergeEntitlements([
    {
      id: "old-row",
      source_key: sourceKey,
      provider: "apple",
      status: "active",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T12:00:00Z",
    },
    {
      id: "new-row",
      source_key: sourceKey,
      provider: "apple",
      status: "revoked",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T13:00:00Z",
    },
  ], []);

  assert(merged.length === 1, "duplicate provider source was not collapsed");
  assert(
    merged[0].status === "revoked",
    "older active event overrode revocation",
  );
});

Deno.test("provider source cannot be silently rebound to another SpyClash account", () => {
  assert(
    isBoundToAnotherUser([{ user_id: "user-a" }], "user-b"),
    "cross-account binding conflict was not detected",
  );
  assert(
    !isBoundToAnotherUser([{ user_id: "user-a" }], "user-a"),
    "same-account source was incorrectly rejected",
  );
});

Deno.test("legacy admin grant resolves CASADA benefits without payment records", () => {
  const now = new Date("2026-07-14T12:00:00Z");
  const resolved = applyAdminGrant(
    summarizeMembership([], now),
    [{ active: true }],
    now,
  );

  assert(resolved.adminGrantActive, "admin grant was not authoritative");
  assert(resolved.membership.active, "admin grant did not activate access");
  assert(
    resolved.membership.tier === "limitless",
    "admin grant did not select CASADA",
  );
  assert(
    resolved.membership.providers.includes("admin"),
    "admin provider marker missing",
  );
  assert(
    resolved.membership.expires_at === null,
    "indefinite admin grant received a synthetic payment expiry",
  );
});

Deno.test("expired admin grant falls back to verified provider truth", () => {
  const now = new Date("2026-07-14T12:00:00Z");
  const base = summarizeMembership([], now);
  const grants = [{ active: true, expires_at: "2026-07-14T11:59:59Z" }];

  assert(
    activeAdminGrantExpiry(grants, now) === undefined,
    "expired admin grant remained active",
  );
  const resolved = applyAdminGrant(base, grants, now);
  assert(!resolved.adminGrantActive, "expired grant stayed authoritative");
  assert(resolved.membership.tier === "free", "expired grant unlocked access");
});

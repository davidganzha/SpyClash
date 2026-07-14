import {
  activeAdminGrantExpiry,
  applyAdminGrant,
  FREE_BENEFITS,
  hasStripePrice,
  isBoundToAnotherUser,
  isEntitlementActive,
  LIMITLESS_BENEFITS,
  mergeEntitlements,
  stripeStatusToEntitlementStatus,
  summarizeMembership,
} from "./membership.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("free membership exposes the promised FREE benefits", () => {
  const membership = summarizeMembership([], new Date("2026-07-13T12:00:00Z"));
  assert(membership.active === false, "empty entitlement set must be inactive");
  assert(membership.tier === "free", "empty entitlement set must be FREE");
  assert(
    JSON.stringify(membership.benefits) === JSON.stringify(FREE_BENEFITS),
    "FREE benefits drifted",
  );
  assert(
    membership.benefits.ai_generations_daily_limit === 10,
    "FREE AI limit drifted",
  );
  assert(membership.benefits.history_limit === 5, "FREE history limit drifted");
});

Deno.test("verified Apple entitlement unlocks LIMITLESS", () => {
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
    "active Apple entitlement did not unlock LIMITLESS",
  );
  assert(membership.providers[0] === "apple", "Apple provider missing");
  assert(
    JSON.stringify(membership.benefits) === JSON.stringify(LIMITLESS_BENEFITS),
    "LIMITLESS benefits drifted",
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
      status: "grace_period",
      expires_at: "2026-07-20T12:00:00Z",
    }, now),
    "grace period should grant access",
  );
});

Deno.test("live Stripe verification requires the current LIMITLESS price", () => {
  assert(
    hasStripePrice(["price_limitless"], "price_limitless"),
    "current LIMITLESS price was rejected",
  );
  assert(
    !hasStripePrice(["price_downgraded"], "price_limitless"),
    "different current price retained LIMITLESS",
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
    "stale stored Stripe status still granted LIMITLESS",
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
  assert(merged[0].status === "revoked", "older active event overrode revocation");
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

Deno.test("admin grant unlocks LIMITLESS without exposing payment records", () => {
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
    "admin grant did not select LIMITLESS",
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

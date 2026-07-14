import {
  entitlementStatusFromApple,
  normalizeAppleEntitlement,
  requiresCanonicalSubscriptionStatus,
  shouldApplyProviderEvent,
} from "./apple-entitlement.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("Apple status grants access only for active and grace period", () => {
  const transaction = { expiresDate: Date.parse("2026-07-20T00:00:00Z") };
  assert(entitlementStatusFromApple({ appleStatus: 1, transaction }) === "active", "active mapping failed");
  assert(entitlementStatusFromApple({ appleStatus: 4, transaction }) === "grace_period", "grace mapping failed");
  assert(entitlementStatusFromApple({ appleStatus: 3, transaction }) === "billing_retry", "billing retry mapping failed");
  assert(entitlementStatusFromApple({ appleStatus: 5, transaction }) === "revoked", "revoked mapping failed");
});

Deno.test("refund reversal requires canonical App Store status reconciliation", () => {
  assert(
    requiresCanonicalSubscriptionStatus("REFUND_REVERSED"),
    "refund reversal did not trigger canonical reconciliation",
  );
  assert(
    !requiresCanonicalSubscriptionStatus("REFUND"),
    "ordinary refund incorrectly triggered reversal reconciliation",
  );
});

Deno.test("refund reversal reinstates canonical active access despite historical revocation", () => {
  const transaction = {
    expiresDate: Date.parse("2026-07-20T00:00:00Z"),
    revocationDate: Date.parse("2026-07-14T00:00:00Z"),
  };
  const status = entitlementStatusFromApple({
    appleStatus: 1,
    notificationType: "REFUND_REVERSED",
    transaction,
    now: new Date("2026-07-15T00:00:00Z"),
  });
  assert(status === "active", "refund reversal remained revoked");
});

Deno.test("refund reversal does not revive an expired canonical subscription", () => {
  const status = entitlementStatusFromApple({
    appleStatus: 2,
    notificationType: "REFUND_REVERSED",
    transaction: {
      expiresDate: Date.parse("2026-07-20T00:00:00Z"),
      revocationDate: Date.parse("2026-07-14T00:00:00Z"),
    },
    now: new Date("2026-07-15T00:00:00Z"),
  });
  assert(status === "expired", "canonical expiry was ignored after reversal");
});

Deno.test("Apple entitlement uses grace-period expiry and stable original transaction key", () => {
  const entitlement = normalizeAppleEntitlement({
    userID: "user-1",
    transaction: {
      originalTransactionId: "original-1",
      transactionId: "transaction-2",
      productId: "com.spyclash.app.limitless.weekly",
      appAccountToken: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      originalPurchaseDate: Date.parse("2026-07-01T00:00:00Z"),
      expiresDate: Date.parse("2026-07-14T00:00:00Z"),
      signedDate: Date.parse("2026-07-14T00:01:00Z"),
      environment: "Sandbox",
    },
    renewal: {
      autoRenewStatus: 1,
      gracePeriodExpiresDate: Date.parse("2026-07-18T00:00:00Z"),
    },
    appleStatus: 4,
    now: new Date("2026-07-14T00:02:00Z"),
  });

  assert(entitlement.source_key === "apple:original-1", "source key drifted");
  assert(entitlement.status === "grace_period", "grace access was not retained");
  assert(entitlement.expires_at === "2026-07-18T00:00:00.000Z", "grace expiry was ignored");
  assert(entitlement.app_account_token === "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "token was not canonicalized");
});

Deno.test("older or duplicate provider events cannot overwrite newer state", () => {
  const current = {
    provider_event_at: "2026-07-14T10:00:00Z",
    provider_event_id: "notification-new",
  };
  assert(!shouldApplyProviderEvent(current, {
    provider_event_at: "2026-07-14T09:59:59Z",
    provider_event_id: "notification-old",
  }), "older event was accepted");
  assert(!shouldApplyProviderEvent(current, {
    provider_event_at: "2026-07-14T10:00:01Z",
    provider_event_id: "notification-new",
  }), "duplicate notification was accepted");
});

import {
  applyStoredStripeFinancialLocks,
  CURRENT_BASE44_APP_ID,
  preserveStoredFinancialRevocation,
  resolveExpectedBase44AppID,
  stripeSubscriptionBindingDecision,
} from "./stripe-binding.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("new email-discovered subscription requires exact user and app metadata", () => {
  const base = {
    alreadyBound: false,
    expectedUserID: "user-1",
    expectedAppID: CURRENT_BASE44_APP_ID,
  };
  assert(
    stripeSubscriptionBindingDecision({
      ...base,
      metadataUserID: "user-1",
      metadataAppID: CURRENT_BASE44_APP_ID,
    }) === "accept",
    "exact new binding was rejected",
  );
  assert(
    stripeSubscriptionBindingDecision(base) === "ignore",
    "metadata-free subscription was adopted by email",
  );
  assert(
    stripeSubscriptionBindingDecision({
      ...base,
      metadataUserID: "user-2",
      metadataAppID: CURRENT_BASE44_APP_ID,
    }) === "ignore",
    "foreign user metadata was adopted by email",
  );
});

Deno.test("existing legacy binding permits missing metadata but rejects conflicts", () => {
  const base = {
    alreadyBound: true,
    expectedUserID: "user-1",
    expectedAppID: CURRENT_BASE44_APP_ID,
  };
  assert(
    stripeSubscriptionBindingDecision(base) === "accept",
    "legacy binding without metadata was rejected",
  );
  assert(
    stripeSubscriptionBindingDecision({
      ...base,
      metadataAppID: "69a0e57fa939f578082f8092",
    }) === "conflict",
    "conflicting app metadata was accepted",
  );
  assert(
    stripeSubscriptionBindingDecision({
      ...base,
      metadataUserID: "user-2",
    }) === "conflict",
    "conflicting user metadata was accepted",
  );
});

Deno.test("subscription verifier falls back to the linked Base44 app id", () => {
  assert(
    resolveExpectedBase44AppID("invalid") === CURRENT_BASE44_APP_ID,
    "invalid app id did not use the linked app fallback",
  );
});

Deno.test("live subscription check cannot erase refund or dispute revocation", () => {
  assert(
    preserveStoredFinancialRevocation("refunded", "active") === "refunded",
    "live check restored a refunded subscription",
  );
  assert(
    preserveStoredFinancialRevocation("revoked", "trialing") === "revoked",
    "live check restored a revoked subscription",
  );
  assert(
    preserveStoredFinancialRevocation("past_due", "active") === "active",
    "ordinary canonical recovery was blocked",
  );
});

Deno.test("live subscription sync preserves independent lock fields", () => {
  assert(
    applyStoredStripeFinancialLocks({
      status: "refunded",
      stripe_refund_blocked_charge_ids: ["ch_refund"],
      stripe_dispute_blocked_charge_ids: ["ch_dispute"],
    }, "active") === "refunded",
    "dispute state took precedence over refund",
  );
  assert(
    applyStoredStripeFinancialLocks({
      status: "refunded",
      stripe_refund_blocked_charge_ids: [],
      stripe_dispute_blocked_charge_ids: ["ch_dispute"],
    }, "active") === "revoked",
    "cleared refund lock erased active dispute",
  );
  assert(
    applyStoredStripeFinancialLocks({
      status: "refunded",
      stripe_refund_blocked_charge_ids: [],
      stripe_dispute_blocked_charge_ids: [],
    }, "active") === "active",
    "explicitly cleared locks kept stale legacy status",
  );
});

Deno.test("legacy status remains fail-closed until migrated", () => {
  assert(
    applyStoredStripeFinancialLocks({ status: "refunded" }, "active") ===
      "refunded",
    "legacy refund failed open",
  );
  assert(
    applyStoredStripeFinancialLocks({ status: "revoked" }, "active") ===
      "revoked",
    "legacy dispute failed open",
  );
});

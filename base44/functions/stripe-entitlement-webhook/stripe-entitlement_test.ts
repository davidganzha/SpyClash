import {
  CURRENT_BASE44_APP_ID,
  deletedEntitlementUserID,
  financialEventChargeID,
  hasCanonicalFullSuccessfulRefund,
  isLimitlessSubscription,
  normalizeStripeEntitlement,
  preserveStoredFinancialRevocation,
  reconcileStripeEntitlementState,
  resolveExpectedBase44AppID,
  resolveStripeWebhookBinding,
  shouldApplyStripeCursor,
  shouldApplyStripeEvent,
  stripeFinancialEventAction,
} from "./stripe-entitlement.ts";
import { entitlementRetentionPatch } from "../deleteAccount/account-deletion.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function subscription(overrides: Record<string, unknown> = {}) {
  return {
    id: "sub_123",
    customer: "cus_123",
    status: "active",
    livemode: true,
    created: 1_752_408_000,
    start_date: 1_752_408_000,
    current_period_end: 1_753_012_800,
    cancel_at_period_end: false,
    items: {
      data: [{ price: { id: "price_limitless", product: "prod_limitless" } }],
    },
    ...overrides,
  };
}

Deno.test("Stripe webhook normalization creates a provider-scoped entitlement", () => {
  const record = normalizeStripeEntitlement({
    subscription: subscription(),
    userID: "user-123",
    limitlessPriceID: "price_limitless",
    eventID: "evt_123",
    eventCreated: 1_752_408_100,
    verifiedAt: new Date("2025-07-13T12:05:00Z"),
  });

  assert(record.source_key === "stripe:sub_123", "source key drifted");
  assert(record.status === "active", "active status was not preserved");
  assert(record.provider_event_id === "evt_123", "event id missing");
});

Deno.test("wrong Stripe price revokes an already-bound source", () => {
  const candidate = subscription({
    items: { data: [{ price: { id: "price_other", product: "prod_other" } }] },
  });
  assert(
    !isLimitlessSubscription(candidate, "price_limitless"),
    "wrong price was accepted",
  );
  const record = normalizeStripeEntitlement({
    subscription: candidate,
    userID: "user-123",
    limitlessPriceID: "price_limitless",
    eventID: "evt_124",
    eventCreated: 1_752_408_200,
  });
  assert(record.status === "revoked", "wrong price retained access");
});

Deno.test("delayed or duplicate Stripe events cannot overwrite newer state", () => {
  const current = {
    provider_event_at: "2025-07-13T13:00:00Z",
    provider_event_id: "evt_new",
  };
  assert(
    !shouldApplyStripeEvent(current, {
      provider_event_at: "2025-07-13T12:00:00Z",
      provider_event_id: "evt_old",
    }),
    "older event was accepted",
  );
  assert(
    !shouldApplyStripeEvent(current, {
      provider_event_at: "2025-07-13T14:00:00Z",
      provider_event_id: "evt_new",
    }),
    "duplicate event was accepted",
  );
  assert(
    !shouldApplyStripeEvent(current, {
      provider_event_at: "2025-07-13T13:00:00Z",
      provider_event_id: "evt_aaa",
    }),
    "lower same-second event cursor was accepted",
  );
  assert(
    shouldApplyStripeEvent(current, {
      provider_event_at: "2025-07-13T13:00:00Z",
      provider_event_id: "evt_zzz",
    }),
    "higher same-second event cursor was rejected",
  );
});

Deno.test("new webhook entitlement requires exact app and user metadata", async () => {
  const accepted = await resolveStripeWebhookBinding({
    existingUserIDs: [],
    metadataUserID: "user-1",
    metadataAppID: CURRENT_BASE44_APP_ID,
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  const ignored = await resolveStripeWebhookBinding({
    existingUserIDs: [],
    metadataUserID: "user-1",
    metadataAppID: "",
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  assert(accepted.decision === "accept", "exact new binding was rejected");
  assert(
    ignored.decision === "ignore",
    "metadata-free new binding was accepted",
  );
});

Deno.test("existing webhook entitlement allows missing metadata but rejects conflicts", async () => {
  const legacy = await resolveStripeWebhookBinding({
    existingUserIDs: ["user-1"],
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  const conflict = await resolveStripeWebhookBinding({
    existingUserIDs: ["user-1"],
    metadataUserID: "user-2",
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  assert(legacy.decision === "accept", "legacy existing binding was rejected");
  assert(conflict.decision === "conflict", "owner conflict was accepted");
});

Deno.test("deleted-account tombstone accepts only its original Stripe owner", async () => {
  const tombstone = await deletedEntitlementUserID("raw-user-1");
  const deletionPatch = await entitlementRetentionPatch("raw-user-1");
  assert(
    tombstone === deletionPatch.user_id,
    "webhook tombstone algorithm drifted from account deletion",
  );
  const accepted = await resolveStripeWebhookBinding({
    existingUserIDs: [tombstone],
    metadataUserID: "raw-user-1",
    metadataAppID: CURRENT_BASE44_APP_ID,
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  const conflict = await resolveStripeWebhookBinding({
    existingUserIDs: [tombstone],
    metadataUserID: "another-user",
    metadataAppID: CURRENT_BASE44_APP_ID,
    expectedAppID: CURRENT_BASE44_APP_ID,
  });
  assert(
    accepted.decision === "accept",
    "deleted billing row stopped updating",
  );
  assert(
    accepted.decision === "accept" && accepted.userID === tombstone &&
      accepted.deletedAccount,
    "webhook rebound deleted subscription to raw identity",
  );
  assert(
    conflict.decision === "conflict",
    "new account adopted deleted billing row",
  );
});

Deno.test("refund and dispute events select canonical snapshot reconciliation", () => {
  assert(
    stripeFinancialEventAction("charge.refunded") === "refund_snapshot",
    "refund did not require a canonical snapshot",
  );
  assert(
    stripeFinancialEventAction("refund.failed") === "refund_snapshot",
    "failed refund could not reconcile and remove a pending lock",
  );
  assert(
    stripeFinancialEventAction("charge.dispute.created") === "dispute_snapshot",
    "new dispute did not require canonical reconciliation",
  );
  assert(
    stripeFinancialEventAction("charge.dispute.closed") === "dispute_snapshot",
    "closed dispute trusted the event snapshot",
  );
  assert(
    stripeFinancialEventAction("charge.dispute.funds_reinstated") ===
      "dispute_snapshot",
    "late-win funds event could not reconcile canonical dispute",
  );
});

Deno.test("only a canonical full refund revokes the subscription", () => {
  assert(
    hasCanonicalFullSuccessfulRefund(
      { amount: 1000, amount_captured: 600 },
      [
        { amount: 250, status: "succeeded" },
        { amount: 350, status: "succeeded" },
        { amount: 400, status: "failed" },
      ],
    ),
    "full refund was not detected",
  );
  assert(
    !hasCanonicalFullSuccessfulRefund(
      { amount: 1000, amount_captured: 1000 },
      [
        { amount: 1000, status: "pending" },
        { amount: 1000, status: "failed" },
        { amount: 1000, status: "canceled" },
      ],
    ),
    "unconfirmed refund was treated as successful",
  );
  assert(
    financialEventChargeID("refund.updated", { charge: "ch_1" }) === "ch_1",
    "refund charge id was not resolved",
  );
});

Deno.test("unknown canonical refund status fails closed", () => {
  let threw = false;
  try {
    hasCanonicalFullSuccessfulRefund(
      { amount_captured: 1000 },
      [{ amount: 1000, status: "mystery" }],
    );
  } catch {
    threw = true;
  }
  assert(threw, "unknown refund status silently unlocked access");
});

Deno.test("webhook app id uses the linked app fallback", () => {
  assert(
    resolveExpectedBase44AppID("unknown") === CURRENT_BASE44_APP_ID,
    "invalid app id did not use linked fallback",
  );
});

Deno.test("stored financial revocation survives ordinary subscription reconciliation", () => {
  assert(
    preserveStoredFinancialRevocation("refunded", "active") === "refunded",
    "ordinary reconciliation restored a refunded subscription",
  );
  assert(
    preserveStoredFinancialRevocation("revoked", "active") === "revoked",
    "ordinary reconciliation restored a disputed subscription",
  );
  assert(
    preserveStoredFinancialRevocation("revoked", "active", true) === "active",
    "explicit canonical restoration was blocked",
  );
  assert(
    preserveStoredFinancialRevocation("refunded", "active", true) ===
      "refunded",
    "dispute restoration erased a confirmed refund",
  );
});

function incomingRecord(
  eventID: string,
  eventAt: string,
  status = "active",
) {
  return {
    source_key: "stripe:sub_123",
    user_id: "user-1",
    provider: "stripe",
    product_id: "prod_limitless",
    stripe_subscription_id: "sub_123",
    status,
    environment: "production",
    expires_at: "2027-07-14T00:00:00Z",
    last_verified_at: "2026-07-14T12:00:00Z",
    provider_event_at: eventAt,
    provider_event_id: eventID,
  };
}

Deno.test("refund and dispute locks coexist and dispute win cannot clear refund", () => {
  const current = {
    ...incomingRecord("evt_old", "2026-07-14T12:00:00Z", "refunded"),
    stripe_refund_blocked_charge_ids: ["ch_refund"],
    stripe_dispute_blocked_charge_ids: ["ch_dispute"],
    stripe_refund_event_cursors: {
      ch_refund: "1784030400000|evt_refund",
    },
    stripe_dispute_event_cursors: {
      ch_dispute: "1784030400000|evt_dispute_open",
    },
  };
  const result = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_dispute_won", "2026-07-14T13:00:00Z"),
    update: {
      disputeLock: { chargeID: "ch_dispute", blocked: false },
    },
  });

  assert(result.shouldPersist, "canonical dispute win was not persisted");
  assert(result.record.status === "refunded", "dispute win erased refund lock");
  assert(
    result.record.stripe_refund_blocked_charge_ids?.[0] === "ch_refund",
    "refund charge id was removed",
  );
  assert(
    result.record.stripe_dispute_blocked_charge_ids?.length === 0,
    "won dispute remained locked",
  );
});

Deno.test("failed refund removes only its refund lock while dispute stays revoked", () => {
  const current = {
    ...incomingRecord("evt_old", "2026-07-14T12:00:00Z", "refunded"),
    stripe_refund_blocked_charge_ids: ["ch_refund"],
    stripe_dispute_blocked_charge_ids: ["ch_dispute"],
  };
  const result = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_refund_failed", "2026-07-14T13:00:00Z"),
    update: { refundLock: { chargeID: "ch_refund", blocked: false } },
  });
  assert(result.record.status === "revoked", "active dispute was cleared");
  assert(
    result.record.stripe_refund_blocked_charge_ids?.length === 0,
    "failed refund remained locked",
  );
  assert(
    result.record.stripe_dispute_blocked_charge_ids?.[0] === "ch_dispute",
    "dispute lock was removed by refund event",
  );
});

Deno.test("winning one charge dispute leaves another charge blocked", () => {
  const current = {
    ...incomingRecord("evt_old", "2026-07-14T12:00:00Z", "revoked"),
    stripe_refund_blocked_charge_ids: [],
    stripe_dispute_blocked_charge_ids: ["ch_1", "ch_2"],
  };
  const result = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_ch1_won", "2026-07-14T13:00:00Z"),
    update: { disputeLock: { chargeID: "ch_1", blocked: false } },
  });
  assert(
    result.record.status === "revoked",
    "other disputed charge was unlocked",
  );
  assert(
    result.record.stripe_dispute_blocked_charge_ids?.join(",") === "ch_2",
    "won dispute removed the wrong charge state",
  );
});

Deno.test("financial cursors are per charge and survive global out-of-order delivery", () => {
  const current = {
    ...incomingRecord("evt_global_new", "2026-07-14T14:00:00Z"),
    stripe_refund_blocked_charge_ids: ["ch_existing"],
    stripe_dispute_blocked_charge_ids: [],
    stripe_refund_event_cursors: {
      ch_existing: "1784034000000|evt_existing",
    },
  };
  const olderDifferentCharge = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_refund_old", "2026-07-14T13:00:00Z"),
    update: { refundLock: { chargeID: "ch_delayed", blocked: true } },
  });
  assert(
    olderDifferentCharge.shouldPersist,
    "delayed canonical event for a different charge was discarded",
  );
  assert(
    olderDifferentCharge.record.stripe_refund_blocked_charge_ids?.join(",") ===
      "ch_delayed,ch_existing",
    "per-charge refund locks did not merge",
  );
  assert(
    olderDifferentCharge.record.provider_event_id === "evt_global_new",
    "delayed financial event regressed the global cursor",
  );

  const duplicate = reconcileStripeEntitlementState({
    current: olderDifferentCharge.record,
    incoming: incomingRecord("evt_refund_old", "2026-07-14T13:00:00Z"),
    update: { refundLock: { chargeID: "ch_delayed", blocked: true } },
  });
  assert(!duplicate.shouldPersist, "duplicate per-charge cursor was reapplied");
});

Deno.test("same-second events for different charges merge deterministically", () => {
  const first = reconcileStripeEntitlementState({
    incoming: incomingRecord("evt_z", "2026-07-14T13:00:00Z"),
    update: { refundLock: { chargeID: "ch_1", blocked: true } },
  });
  const second = reconcileStripeEntitlementState({
    current: first.record,
    incoming: incomingRecord("evt_a", "2026-07-14T13:00:00Z"),
    update: { refundLock: { chargeID: "ch_2", blocked: true } },
  });
  assert(
    second.shouldPersist,
    "different-charge same-second event was rejected",
  );
  assert(
    second.record.stripe_refund_blocked_charge_ids?.join(",") === "ch_1,ch_2",
    "same-second locks did not coexist",
  );
  assert(
    second.record.provider_event_id === "evt_z",
    "lower tie-break cursor replaced the global cursor",
  );
});

Deno.test("paid invoice clears refund locks but never dispute locks", () => {
  const current = {
    ...incomingRecord("evt_old", "2026-07-14T12:00:00Z", "refunded"),
    stripe_refund_blocked_charge_ids: ["ch_refund"],
    stripe_dispute_blocked_charge_ids: ["ch_dispute"],
  };
  const result = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_paid", "2026-07-14T15:00:00Z"),
    update: { clearRefundLocks: true },
  });
  assert(
    result.record.status === "revoked",
    "paid invoice cleared dispute lock",
  );
  assert(
    result.record.stripe_refund_blocked_charge_ids?.length === 0,
    "paid invoice failed to clear old refund lock",
  );
  assert(
    result.record.stripe_dispute_blocked_charge_ids?.[0] === "ch_dispute",
    "paid invoice removed dispute charge",
  );

  const delayedRefund = reconcileStripeEntitlementState({
    current: result.record,
    incoming: incomingRecord("evt_delayed_refund", "2026-07-14T14:00:00Z"),
    update: { refundLock: { chargeID: "ch_refund", blocked: true } },
  });
  assert(
    !delayedRefund.shouldPersist,
    "pre-payment delayed refund event recreated a cleared lock",
  );
});

Deno.test("legacy single-status locks migrate without fail-open", () => {
  const result = reconcileStripeEntitlementState({
    current: incomingRecord("evt_old", "2026-07-14T12:00:00Z", "refunded"),
    incoming: incomingRecord("evt_new", "2026-07-14T13:00:00Z"),
  });
  assert(result.record.status === "refunded", "legacy refund was unlocked");
  assert(
    result.record.stripe_refund_blocked_charge_ids?.includes(
      "legacy:refund",
    ) ===
      true,
    "legacy refund was not migrated into an independent lock",
  );
});

Deno.test("ordinary subscription sync preserves lock arrays and per-charge cursors", () => {
  const current = {
    ...incomingRecord("evt_old", "2026-07-14T12:00:00Z", "refunded"),
    stripe_refund_blocked_charge_ids: ["ch_refund"],
    stripe_dispute_blocked_charge_ids: ["ch_dispute"],
    stripe_refund_event_cursors: { ch_refund: "1784030400000|evt_refund" },
    stripe_dispute_event_cursors: {
      ch_dispute: "1784030400000|evt_dispute",
    },
  };
  const result = reconcileStripeEntitlementState({
    current,
    incoming: incomingRecord("evt_subscription", "2026-07-14T14:00:00Z"),
  });
  assert(result.record.status === "refunded", "ordinary sync unlocked refund");
  assert(
    result.record.stripe_refund_blocked_charge_ids?.[0] === "ch_refund" &&
      result.record.stripe_dispute_blocked_charge_ids?.[0] === "ch_dispute",
    "ordinary sync erased a financial lock array",
  );
  assert(
    result.record.stripe_refund_event_cursors?.ch_refund ===
        "1784030400000|evt_refund" &&
      result.record.stripe_dispute_event_cursors?.ch_dispute ===
        "1784030400000|evt_dispute",
    "ordinary sync erased a financial cursor",
  );
});

Deno.test("stored financial cursor rejects older and equal tuple", () => {
  const incoming = incomingRecord("evt_b", "2026-07-14T13:00:00Z");
  assert(
    !shouldApplyStripeCursor("1784034000000|evt_b", incoming),
    "equal cursor was accepted",
  );
  assert(
    !shouldApplyStripeCursor("1784034000000|evt_z", incoming),
    "lower same-second cursor was accepted",
  );
  assert(
    shouldApplyStripeCursor("1784034000000|evt_a", incoming),
    "higher same-second cursor was rejected",
  );
});

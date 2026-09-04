import Stripe from "npm:stripe@14";
import {
  limitlessApplePurchaseEnabled,
  limitlessEnabled,
} from "./limitless-rollout.ts";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  canonicalBase44Request,
  hasTrustedBase44Context,
} from "./base44-context.ts";
import {
  applyAdminGrant,
  applyCasadaAccess,
  casadaMembershipResponse,
  type EntitlementRecord,
  hasStripePrice,
  isoFromUnixSeconds,
  mergeEntitlements,
  publicEntitlementSources,
  stripeStatusToEntitlementStatus,
  summarizeMembership,
} from "./membership.ts";
import { quotaKey, totalQuotaUsage } from "./quota.ts";
import {
  applyStoredStripeFinancialLocks,
  resolveExpectedBase44AppID,
  stripeSubscriptionBindingDecision,
} from "./stripe-binding.ts";
import {
  persistStripeEntitlement,
  StripeEntitlementPersistenceError,
} from "./stripe-entitlement-persistence.ts";

// Retained only to reconcile subscriptions created before CASADA made access
// universal. The environment key and price value are deployed compatibility
// contracts and must not be repurposed.
const LEGACY_STRIPE_PRICE_ID = "price_1TR5wiRFCq3jt6C66NdM8NY4";
const MAX_ENTITLEMENTS_PER_USER = 100;

class EntitlementAccountMismatchError extends Error {
  constructor() {
    super(
      "This Stripe subscription is already attached to another SpyClash account.",
    );
    this.name = "EntitlementAccountMismatchError";
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : String(error || "Unknown error");
}

function stripeObjectId(value: unknown): string | undefined {
  if (typeof value === "string" && value) return value;
  if (value && typeof value === "object" && "id" in value) {
    const id = (value as { id?: unknown }).id;
    return typeof id === "string" && id ? id : undefined;
  }
  return undefined;
}

function stripePriceIds(subscription: any): string[] {
  return (subscription?.items?.data || [])
    .map((item: any) => item?.price?.id)
    .filter((value: unknown): value is string =>
      typeof value === "string" && Boolean(value)
    );
}

function isLegacyStripeSubscription(
  subscription: any,
  legacyPriceID: string,
): boolean {
  return hasStripePrice(stripePriceIds(subscription), legacyPriceID);
}

function normalizeStripeSubscription(
  subscription: any,
  user: { id: string; email: string },
  verifiedAt: string,
): EntitlementRecord {
  const firstItem = subscription?.items?.data?.[0];
  const productId = stripeObjectId(firstItem?.price?.product) ||
    firstItem?.price?.id || "stripe_limitless";
  const priceId = firstItem?.price?.id;

  return {
    source_key: `stripe:${subscription.id}`,
    user_id: user.id,
    user_email: user.email,
    provider: "stripe",
    product_id: productId,
    price_id: priceId,
    stripe_subscription_id: subscription.id,
    provider_customer_id: stripeObjectId(subscription.customer),
    status: stripeStatusToEntitlementStatus(subscription.status),
    purchased_at: isoFromUnixSeconds(
      subscription.start_date || subscription.created,
    ),
    expires_at: isoFromUnixSeconds(subscription.current_period_end),
    environment: subscription.livemode ? "production" : "sandbox",
    cancel_at_period_end: Boolean(subscription.cancel_at_period_end),
    last_verified_at: verifiedAt,
  };
}

function copyStringMap(value: unknown): Record<string, string> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .map(([key, item]) => [key, String(item || "")])
      .filter(([key, item]) => Boolean(key) && Boolean(item)),
  );
}

async function upsertStripeEntitlement(
  store: any,
  lifecycleStore: any,
  userStore: any,
  entitlement: EntitlementRecord,
): Promise<void> {
  const subscriptionId = entitlement.stripe_subscription_id;
  if (!subscriptionId || !entitlement.user_id) return;
  try {
    await persistStripeEntitlement({
      entitlementStore: store,
      lifecycleStore,
      userStore,
      subscriptionID: subscriptionId,
      requestedUserID: entitlement.user_id,
      build: (current, ownerUserID) => {
        const record: EntitlementRecord = {
          ...entitlement,
          user_id: ownerUserID,
        };
        if (Array.isArray(current?.stripe_refund_blocked_charge_ids)) {
          record.stripe_refund_blocked_charge_ids = Array.from(
            new Set(current.stripe_refund_blocked_charge_ids),
          ).sort();
        }
        if (Array.isArray(current?.stripe_dispute_blocked_charge_ids)) {
          record.stripe_dispute_blocked_charge_ids = Array.from(
            new Set(current.stripe_dispute_blocked_charge_ids),
          ).sort();
        }
        record.stripe_refund_event_cursors = copyStringMap(
          current?.stripe_refund_event_cursors,
        );
        record.stripe_dispute_event_cursors = copyStringMap(
          current?.stripe_dispute_event_cursors,
        );
        record.status = applyStoredStripeFinancialLocks(
          current,
          record.status,
        );
        return { record, shouldPersist: true };
      },
    });
  } catch (error) {
    if (
      error instanceof StripeEntitlementPersistenceError &&
      error.code === "owner_conflict"
    ) {
      throw new EntitlementAccountMismatchError();
    }
    throw error;
  }
}

async function discoverStripeSubscriptions(
  stripe: Stripe,
  email: string,
): Promise<any[]> {
  const customers = await stripe.customers.list({ email, limit: 100 });
  const pages = await Promise.all(
    customers.data.map((customer) =>
      stripe.subscriptions.list({
        customer: customer.id,
        status: "all",
        limit: 100,
        expand: ["data.items.data.price.product"],
      })
    ),
  );
  return pages.flatMap((page) => page.data);
}

async function retrieveBoundStripeSubscriptions(
  stripe: Stripe,
  entitlements: EntitlementRecord[],
): Promise<any[]> {
  const ids = Array.from(
    new Set(
      entitlements
        .filter((item) => item.provider === "stripe")
        .map((item) => item.stripe_subscription_id)
        .filter((value): value is string => Boolean(value)),
    ),
  );

  return await Promise.all(ids.map((id) =>
    stripe.subscriptions.retrieve(id, {
      expand: ["items.data.price.product"],
    })
  ));
}

async function syncStripeEntitlements(
  store: any,
  lifecycleStore: any,
  userStore: any,
  user: { id: string; email: string },
  currentEntitlements: EntitlementRecord[],
) {
  const secretKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!secretKey) {
    throw new Error("Stripe verification is temporarily unavailable.");
  }

  const stripe = new Stripe(secretKey);
  const legacyPriceID = Deno.env.get("STRIPE_LIMITLESS_PRICE_ID") ||
    LEGACY_STRIPE_PRICE_ID;
  const expectedAppId = resolveExpectedBase44AppID(
    Deno.env.get("BASE44_APP_ID"),
    Deno.env.get("SPYCLASH_APP_ID"),
  );
  const alreadyBoundSubscriptionIds = new Set(
    currentEntitlements
      .filter((item) => item.provider === "stripe" && item.user_id === user.id)
      .map((item) => item.stripe_subscription_id)
      .filter((value): value is string => Boolean(value)),
  );

  const [bound, discovered] = await Promise.all([
    retrieveBoundStripeSubscriptions(stripe, currentEntitlements),
    discoverStripeSubscriptions(stripe, user.email),
  ]);
  const subscriptionsById = new Map<string, any>();
  for (const subscription of [...bound, ...discovered]) {
    if (subscription?.id) subscriptionsById.set(subscription.id, subscription);
  }

  const verifiedAt = new Date().toISOString();
  const normalized: EntitlementRecord[] = [];
  for (const subscription of subscriptionsById.values()) {
    const subscriptionId = String(subscription?.id || "");
    const alreadyBound = alreadyBoundSubscriptionIds.has(subscriptionId);
    const isLegacyProduct = isLegacyStripeSubscription(
      subscription,
      legacyPriceID,
    );
    if (!isLegacyProduct && !alreadyBound) continue;

    const binding = stripeSubscriptionBindingDecision({
      alreadyBound,
      expectedUserID: user.id,
      expectedAppID: expectedAppId,
      metadataUserID: subscription?.metadata?.base44_user_id,
      metadataAppID: subscription?.metadata?.base44_app_id,
    });
    if (binding === "ignore") continue;
    if (binding === "conflict") {
      throw new EntitlementAccountMismatchError();
    }

    const entitlement = normalizeStripeSubscription(
      subscription,
      user,
      verifiedAt,
    );
    if (!isLegacyProduct) {
      entitlement.status = "revoked";
    } else {
      const stored = currentEntitlements.find((item) =>
        item.provider === "stripe" &&
        item.stripe_subscription_id === subscriptionId &&
        item.user_id === user.id
      );
      if (Array.isArray(stored?.stripe_refund_blocked_charge_ids)) {
        entitlement.stripe_refund_blocked_charge_ids = Array.from(
          new Set(stored.stripe_refund_blocked_charge_ids),
        ).sort();
      }
      if (Array.isArray(stored?.stripe_dispute_blocked_charge_ids)) {
        entitlement.stripe_dispute_blocked_charge_ids = Array.from(
          new Set(stored.stripe_dispute_blocked_charge_ids),
        ).sort();
      }
      entitlement.stripe_refund_event_cursors = copyStringMap(
        stored?.stripe_refund_event_cursors,
      );
      entitlement.stripe_dispute_event_cursors = copyStringMap(
        stored?.stripe_dispute_event_cursors,
      );
      entitlement.status = applyStoredStripeFinancialLocks(
        stored,
        entitlement.status,
      );
    }
    normalized.push(entitlement);
  }

  const persistenceWarnings: string[] = [];
  for (const entitlement of normalized) {
    try {
      await upsertStripeEntitlement(
        store,
        lifecycleStore,
        userStore,
        entitlement,
      );
    } catch (error) {
      if (error instanceof EntitlementAccountMismatchError) throw error;
      console.error(
        "Stripe entitlement persistence error:",
        errorMessage(error),
      );
      persistenceWarnings.push(entitlement.stripe_subscription_id || "unknown");
    }
  }

  return { entitlements: normalized, persistenceWarnings };
}

function unknownMembershipBody(
  status: "unknown" | "unauthenticated" | "account_mismatch",
  message: string,
) {
  return {
    active: false,
    tier: null,
    protocol: null,
    status,
    providers: [],
    benefits: null,
    expires_at: null,
    ai_generations_today: null,
    ai_remaining: null,
    checked_at: new Date().toISOString(),
    error: message,
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405 });
  }
  if (!hasTrustedBase44Context(req)) {
    return Response.json(
      unknownMembershipBody("unauthenticated", "Authentication required."),
      { status: 401 },
    );
  }
  const base44 = createClientFromRequest(canonicalBase44Request(req));
  let user: any;
  try {
    user = await base44.auth.me();
  } catch (error) {
    console.error("Subscription authentication error:", errorMessage(error));
    return Response.json(
      unknownMembershipBody("unauthenticated", "Authentication required."),
      { status: 401 },
    );
  }

  if (
    typeof user?.id !== "string" || !user.id ||
    typeof user?.email !== "string" || !user.email
  ) {
    return Response.json(
      unknownMembershipBody("unauthenticated", "Authentication required."),
      { status: 401 },
    );
  }

  const casadaResponse = casadaMembershipResponse();
  if (casadaResponse) return Response.json(casadaResponse);

  const store = base44.asServiceRole.entities.Entitlement;
  let storedEntitlements: EntitlementRecord[] = [];
  let entityReadError: unknown = null;
  try {
    storedEntitlements = await store.filter(
      { user_id: user.id },
      "-last_verified_at",
      MAX_ENTITLEMENTS_PER_USER,
      0,
    );
  } catch (error) {
    entityReadError = error;
    console.error("Entitlement read error:", errorMessage(error));
  }

  let adminGrants: Array<{ active?: boolean; expires_at?: string }> = [];
  let adminGrantReadError: unknown = null;
  try {
    adminGrants = await base44.asServiceRole.entities.MembershipGrant.filter(
      { user_id: user.id },
      "-created_date",
      100,
      0,
    );
  } catch (error) {
    adminGrantReadError = error;
    console.error("Membership grant read error:", errorMessage(error));
  }

  let verifiedStripeEntitlements: EntitlementRecord[] = [];
  let stripeError: unknown = null;
  let persistenceWarnings: string[] = [];
  // This rollout restores Apple IAP only. Do not depend on the deferred Stripe
  // integration to classify a native FREE account or to restore Apple access.
  // Existing provider records remain readable and retain their verified expiry.
  const verifyStripeLive = !limitlessEnabled();
  if (verifyStripeLive) {
    try {
      const result = await syncStripeEntitlements(
        store,
        base44.asServiceRole.entities.BillingIdentityLifecycle,
        base44.asServiceRole.entities.User,
        { id: user.id, email: user.email },
        storedEntitlements,
      );
      verifiedStripeEntitlements = result.entitlements;
      persistenceWarnings = result.persistenceWarnings;
    } catch (error) {
      stripeError = error;
      console.error(
        "Stripe subscription verification error:",
        errorMessage(error),
      );
    }
  }

  const stripeAccountMismatch = stripeError instanceof
    EntitlementAccountMismatchError;
  const allEntitlements = mergeEntitlements(
    storedEntitlements,
    verifiedStripeEntitlements,
  ).filter((item) => !stripeAccountMismatch || item.provider !== "stripe");
  const membershipResolution = applyAdminGrant(
    summarizeMembership(allEntitlements),
    adminGrants,
  );
  const membership = applyCasadaAccess(membershipResolution.membership);

  let aiGenerationsToday: number | null = null;
  let quotaReadError: unknown = null;
  try {
    const quotaRecords = await base44.asServiceRole.entities.AiGenerationUsage
      .filter(
        { quota_key: quotaKey(user.id) },
        "created_date",
        20,
        0,
      );
    aiGenerationsToday = totalQuotaUsage(quotaRecords);
  } catch (error) {
    quotaReadError = error;
    console.error("AI quota read error:", errorMessage(error));
  }

  if (
    stripeAccountMismatch && !membership.active
  ) {
    return Response.json(
      unknownMembershipBody(
        "account_mismatch",
        stripeError instanceof EntitlementAccountMismatchError
          ? stripeError.message
          : "This subscription belongs to another SpyClash account.",
      ),
      { status: 409 },
    );
  }

  // A verified active source remains usable during a temporary provider or
  // persistence outage. Without one, uncertainty must not be reported as a
  // verified provider-backed state. CASADA itself remains universal.
  if (
    !membership.active &&
    !membershipResolution.adminGrantActive &&
    (entityReadError || stripeError || adminGrantReadError)
  ) {
    return Response.json(
      unknownMembershipBody(
        "unknown",
        "Membership could not be verified. Existing access has not been changed; retry shortly.",
      ),
      { status: 503 },
    );
  }

  return Response.json({
    active: membership.active,
    tier: membership.tier,
    protocol: membership.protocol,
    status: membership.status,
    providers: membership.providers,
    benefits: membership.benefits,
    expires_at: membership.expires_at,
    ai_generations_today: aiGenerationsToday,
    ai_remaining: aiGenerationsToday === null || membership.tier === "limitless"
      ? null
      : Math.max(
        0,
        (membership.benefits.ai_generations_daily_limit ?? 10) -
          aiGenerationsToday,
      ),
    sources: publicEntitlementSources(allEntitlements),
    checked_at: new Date().toISOString(),
    apple_purchase_enabled: !membership.active &&
      limitlessApplePurchaseEnabled(),
    provider_sync: {
      entitlements: entityReadError ? "degraded" : "ok",
      stripe: !verifyStripeLive
        ? "not_required"
        : stripeError
        ? "degraded"
        : "ok",
      persistence: persistenceWarnings.length ? "degraded" : "ok",
      admin_grant: adminGrantReadError ? "degraded" : "ok",
      quota: quotaReadError ? "degraded" : "ok",
    },
  });
});

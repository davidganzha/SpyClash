import Stripe from "npm:stripe@14";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { withCheckoutBillingLease } from "./checkout-lifecycle.ts";
import {
  checkoutIdempotencyKey,
  resolveExpectedBase44AppID,
} from "./checkout-security.ts";

const APP_ORIGIN = "https://spyclash.com";
const DEFAULT_LIMITLESS_PRICE_ID = "price_1TR5wiRFCq3jt6C66NdM8NY4";
const GRANTING_STATUSES = new Set(["active", "trialing", "grace_period"]);

type EntitlementRecord = {
  id?: string;
  source_key?: string;
  status?: string;
  expires_at?: string;
  provider_event_at?: string;
  last_verified_at?: string;
  created_date?: string;
};

class CheckoutError extends Error {
  status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "CheckoutError";
    this.status = status;
  }
}

function errorStatus(error: unknown): number | undefined {
  if (error instanceof CheckoutError) return error.status;
  if (!error || typeof error !== "object" || !("status" in error)) {
    return undefined;
  }
  const status = Number((error as { status?: unknown }).status);
  return Number.isInteger(status) ? status : undefined;
}

function stripePriceIDs(subscription: any): string[] {
  return (subscription?.items?.data || [])
    .map((item: any) => item?.price?.id)
    .filter((value: unknown): value is string =>
      typeof value === "string" && Boolean(value)
    );
}

function hasStripePrice(priceIDs: string[], expectedPriceID: string): boolean {
  return Boolean(expectedPriceID) && priceIDs.includes(expectedPriceID);
}

function isoFromUnixSeconds(value: unknown): string | undefined {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
  return new Date(seconds * 1000).toISOString();
}

function stripeStatusToEntitlementStatus(status: unknown): string {
  switch (String(status || "")) {
    case "active":
      return "active";
    case "trialing":
      return "trialing";
    case "past_due":
      return "past_due";
    case "paused":
      return "paused";
    case "canceled":
      return "canceled";
    case "unpaid":
    case "incomplete_expired":
      return "expired";
    case "incomplete":
      return "pending";
    default:
      return "unknown";
  }
}

function isEntitlementActive(
  record: EntitlementRecord,
  now = new Date(),
): boolean {
  if (!GRANTING_STATUSES.has(String(record.status || ""))) return false;
  const expiry = Date.parse(record.expires_at || "");
  return Number.isFinite(expiry) && expiry > now.getTime();
}

function recordFreshness(record: EntitlementRecord): number {
  for (
    const value of [
      record.provider_event_at,
      record.last_verified_at,
      record.created_date,
    ]
  ) {
    const timestamp = Date.parse(value || "");
    if (Number.isFinite(timestamp)) return timestamp;
  }
  return Number.NEGATIVE_INFINITY;
}

function hasActiveStoredMembership(records: EntitlementRecord[]): boolean {
  const canonical = new Map<string, EntitlementRecord>();
  const unkeyed: EntitlementRecord[] = [];
  for (const record of records) {
    const key = record.source_key || record.id;
    if (!key) {
      unkeyed.push(record);
      continue;
    }
    const current = canonical.get(key);
    if (!current || recordFreshness(record) > recordFreshness(current)) {
      canonical.set(key, record);
    }
  }
  return [...canonical.values(), ...unkeyed].some((record) =>
    isEntitlementActive(record)
  );
}

function hasActiveAdminGrant(records: any[], now = new Date()): boolean {
  return records.some((record) => {
    if (record?.active !== true) return false;
    const rawExpiry = typeof record?.expires_at === "string"
      ? record.expires_at.trim()
      : "";
    if (!rawExpiry) return true;
    const expiry = Date.parse(rawExpiry);
    return Number.isFinite(expiry) && expiry > now.getTime();
  });
}

async function assertNoExistingStripeAccess(
  stripe: Stripe,
  user: { id: string; email: string },
  limitlessPriceID: string,
) {
  const customers = await stripe.customers.list({
    email: user.email,
    limit: 100,
  });
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

  for (const subscription of pages.flatMap((page) => page.data)) {
    if (!hasStripePrice(stripePriceIDs(subscription), limitlessPriceID)) {
      continue;
    }
    const active = isEntitlementActive({
      status: stripeStatusToEntitlementStatus(subscription.status),
      expires_at: isoFromUnixSeconds(subscription.current_period_end),
    });
    if (!active) continue;

    const claimedUserID = String(subscription.metadata?.base44_user_id || "");
    if (claimedUserID && claimedUserID !== user.id) {
      throw new CheckoutError(
        "An existing Stripe subscription belongs to another SpyClash account.",
        409,
      );
    }
    throw new CheckoutError(
      "LIMITLESS is already active on this SpyClash account.",
      409,
    );
  }
}

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();

    if (!user?.id || !user?.email) {
      return Response.json({ error: "Authentication required" }, {
        status: 401,
      });
    }

    let adminGrants: any[];
    try {
      adminGrants = await base44.asServiceRole.entities.MembershipGrant.filter(
        { user_id: user.id },
        "-created_date",
        100,
        0,
      );
    } catch {
      throw new CheckoutError(
        "Existing membership could not be verified. Retry shortly.",
        503,
      );
    }
    if (hasActiveAdminGrant(adminGrants)) {
      throw new CheckoutError(
        "LIMITLESS is already active on this SpyClash account.",
        409,
      );
    }

    const limitlessPriceId = Deno.env.get("STRIPE_LIMITLESS_PRICE_ID") ||
      DEFAULT_LIMITLESS_PRICE_ID;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) {
      return Response.json({ error: "Checkout is temporarily unavailable" }, {
        status: 503,
      });
    }
    const stripe = new Stripe(stripeSecretKey);
    const base44AppId = resolveExpectedBase44AppID(
      Deno.env.get("BASE44_APP_ID"),
      Deno.env.get("SPYCLASH_APP_ID"),
    );

    let storedEntitlements: EntitlementRecord[];
    try {
      storedEntitlements = await base44.asServiceRole.entities.Entitlement
        .filter(
          { user_id: user.id },
          "-last_verified_at",
          100,
          0,
        );
    } catch {
      throw new CheckoutError(
        "Existing membership could not be verified. Retry shortly.",
        503,
      );
    }
    if (hasActiveStoredMembership(storedEntitlements)) {
      throw new CheckoutError(
        "LIMITLESS is already active on this SpyClash account.",
        409,
      );
    }
    await assertNoExistingStripeAccess(
      stripe,
      { id: user.id, email: user.email },
      limitlessPriceId,
    );

    const checkoutParams: Stripe.Checkout.SessionCreateParams = {
      payment_method_types: ["card"],
      mode: "subscription",
      client_reference_id: user.id,
      line_items: [{
        price: limitlessPriceId,
        quantity: 1,
      }],
      customer_email: user.email,
      success_url: `${APP_ORIGIN}/Pricing?success=1`,
      cancel_url: `${APP_ORIGIN}/Pricing`,
      metadata: {
        base44_app_id: base44AppId,
        base44_user_id: user.id,
      },
      subscription_data: {
        metadata: {
          base44_app_id: base44AppId,
          base44_user_id: user.id,
        },
      },
    };
    try {
      const idempotencyKey = await checkoutIdempotencyKey({
        appID: base44AppId,
        userID: user.id,
        priceID: limitlessPriceId,
        email: user.email,
      });
      const session = await withCheckoutBillingLease({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userID: user.id,
        createSession: () =>
          stripe.checkout.sessions.create(checkoutParams, {
            idempotencyKey,
          }),
      });
      return Response.json({ url: session.url });
    } catch (error) {
      if (error instanceof BillingIdentityLifecycleError) {
        throw new CheckoutError(
          "Account billing is being updated. Retry shortly.",
          503,
        );
      }
      throw error;
    }
  } catch (error) {
    console.error("Checkout error:", error);

    const rawStatus = errorStatus(error);
    const allowedStatuses = new Set([401, 403, 409, 503]);
    const status = rawStatus && allowedStatuses.has(rawStatus)
      ? rawStatus
      : 500;
    const message = error instanceof CheckoutError
      ? error.message
      : status === 401 || status === 403
      ? "Authentication required"
      : "Unable to create checkout session";

    return Response.json({ error: message }, { status });
  }
});

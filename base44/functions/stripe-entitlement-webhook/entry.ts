import Stripe from "npm:stripe@14";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  type EntitlementRecord,
  isLegacySubscription,
  LEGACY_STRIPE_PRICE_ID,
  normalizeStripeEntitlement,
  reconcileStripeEntitlementState,
  resolveExpectedBase44AppID,
  resolveStripeWebhookBinding,
} from "./stripe-entitlement.ts";
import { resolveStripeSubscriptionEvent } from "./stripe-event-resolution.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  persistStripeEntitlement,
  StripeEntitlementPersistenceError,
} from "./stripe-entitlement-persistence.ts";

const MAX_WEBHOOK_BYTES = 1_000_000;

class WebhookError extends Error {
  status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "WebhookError";
    this.status = status;
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : String(error || "Unknown error");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed." }, { status: 405 });
  }

  try {
    const declaredLength = Number(req.headers.get("content-length") || 0);
    if (declaredLength > MAX_WEBHOOK_BYTES) {
      throw new WebhookError("Webhook payload is too large.", 413);
    }

    const signature = req.headers.get("stripe-signature");
    if (!signature) throw new WebhookError("Stripe signature is missing.", 400);
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const secretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!webhookSecret || !secretKey) {
      throw new WebhookError("Stripe webhook is not configured.", 503);
    }

    const base44 = createClientFromRequest(req);
    const rawBody = await req.text();
    if (rawBody.length > MAX_WEBHOOK_BYTES) {
      throw new WebhookError("Webhook payload is too large.", 413);
    }

    const stripe = new Stripe(secretKey);
    let event: Stripe.Event;
    try {
      event = await stripe.webhooks.constructEventAsync(
        rawBody,
        signature,
        webhookSecret,
      );
    } catch (error) {
      throw new WebhookError(
        `Invalid Stripe signature: ${errorMessage(error)}`,
        400,
      );
    }

    const resolution = await resolveStripeSubscriptionEvent(stripe, event);
    const subscriptionID = resolution.subscriptionID;
    if (!subscriptionID) {
      return Response.json({
        received: true,
        ignored: true,
        reason: resolution.ignoredReason || "unrelated_event",
      });
    }

    // Never trust lifecycle state embedded in the webhook object. The signed
    // event selects the source, then Stripe's API supplies its current state.
    const subscription = await stripe.subscriptions.retrieve(subscriptionID, {
      expand: ["items.data.price.product"],
    });
    const store = base44.asServiceRole.entities.Entitlement;
    const existing: EntitlementRecord[] = await store.filter(
      { provider: "stripe", stripe_subscription_id: subscriptionID },
      "-last_verified_at",
      20,
      0,
    );

    const expectedAppID = resolveExpectedBase44AppID(
      Deno.env.get("BASE44_APP_ID"),
      Deno.env.get("SPYCLASH_APP_ID"),
    );
    const binding = await resolveStripeWebhookBinding({
      existingUserIDs: existing.map((record) => record.user_id),
      metadataUserID: subscription.metadata?.base44_user_id,
      metadataAppID: subscription.metadata?.base44_app_id,
      expectedAppID,
    });
    if (binding.decision === "ignore") {
      console.error(
        "Ignoring Stripe subscription without exact SpyClash binding:",
        subscriptionID,
      );
      return Response.json({
        received: true,
        ignored: true,
        reason: binding.reason,
      });
    }
    if (binding.decision === "conflict") {
      throw new WebhookError(
        "Stripe subscription metadata conflicts with its existing owner.",
        409,
      );
    }
    const userID = binding.userID;

    const legacyPriceID = Deno.env.get("STRIPE_LIMITLESS_PRICE_ID") ||
      LEGACY_STRIPE_PRICE_ID;
    if (
      !isLegacySubscription(subscription, legacyPriceID) &&
      !existing.length
    ) {
      return Response.json({
        received: true,
        ignored: true,
        reason: "unrelated_price",
      });
    }

    const persistence = await persistStripeEntitlement({
      entitlementStore: store,
      lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
      userStore: base44.asServiceRole.entities.User,
      subscriptionID,
      requestedUserID: userID,
      allowMissingUserTombstone: true,
      build: (current, ownerUserID) => {
        const normalized = normalizeStripeEntitlement({
          subscription,
          userID: ownerUserID,
          userEmail: current?.user_email || existing[0]?.user_email,
          legacyPriceID,
          eventID: event.id,
          eventCreated: event.created,
        });
        return reconcileStripeEntitlementState({
          current,
          incoming: normalized,
          update: {
            refundLock: resolution.refundLock,
            disputeLock: resolution.disputeLock,
            clearRefundLocks: resolution.clearRefundLocks,
          },
        });
      },
    });
    const entitlement = persistence.record;
    if (!persistence.persisted) {
      return Response.json({
        received: true,
        ignored: true,
        reason: "stale_or_duplicate_cursor",
      });
    }
    return Response.json({
      received: true,
      provider: "stripe",
      subscription_id: subscriptionID,
      status: entitlement.status,
      retained_deleted_account: persistence.deletedAccount,
    });
  } catch (error) {
    const status = error instanceof WebhookError
      ? error.status
      : error instanceof StripeEntitlementPersistenceError &&
          error.code === "owner_conflict"
      ? 409
      : error instanceof StripeEntitlementPersistenceError ||
          error instanceof BillingIdentityLifecycleError
      ? 503
      : 500;
    console.error("stripe-entitlement-webhook failed:", errorMessage(error));
    return Response.json(
      {
        error: status >= 500
          ? "Unable to process Stripe webhook."
          : errorMessage(error),
      },
      { status },
    );
  }
});

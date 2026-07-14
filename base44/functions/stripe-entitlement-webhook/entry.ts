import Stripe from "npm:stripe@14";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  DEFAULT_LIMITLESS_PRICE_ID,
  type EntitlementRecord,
  isLimitlessSubscription,
  normalizeStripeEntitlement,
  reconcileStripeEntitlementState,
  resolveExpectedBase44AppID,
  resolveStripeWebhookBinding,
} from "./stripe-entitlement.ts";
import { resolveStripeSubscriptionEvent } from "./stripe-event-resolution.ts";

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

function writable(record: EntitlementRecord) {
  return Object.fromEntries(
    Object.entries(record).filter(([key, value]) =>
      key !== "id" && value !== undefined
    ),
  );
}

async function upsertStripeEntitlement(
  store: any,
  records: EntitlementRecord[],
  incoming: EntitlementRecord,
) {
  const userID = incoming.user_id;
  if (!userID) throw new WebhookError("Stripe user binding is missing.", 422);
  if (records.some((record) => record.user_id && record.user_id !== userID)) {
    throw new WebhookError(
      "Stripe subscription is bound to another SpyClash account.",
      409,
    );
  }

  const current = records.find((record) => record.user_id === userID);
  if (current?.id) {
    await store.update(current.id, writable(incoming));
    return;
  }
  await store.create(writable(incoming));
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

    const limitlessPriceID = Deno.env.get("STRIPE_LIMITLESS_PRICE_ID") ||
      DEFAULT_LIMITLESS_PRICE_ID;
    if (
      !isLimitlessSubscription(subscription, limitlessPriceID) &&
      !existing.length
    ) {
      return Response.json({
        received: true,
        ignored: true,
        reason: "unrelated_price",
      });
    }

    const normalized = normalizeStripeEntitlement({
      subscription,
      userID,
      userEmail: existing[0]?.user_email,
      limitlessPriceID,
      eventID: event.id,
      eventCreated: event.created,
    });
    const current = existing.find((record) => record.user_id === userID);
    const reconciled = reconcileStripeEntitlementState({
      current,
      incoming: normalized,
      update: {
        refundLock: resolution.refundLock,
        disputeLock: resolution.disputeLock,
        clearRefundLocks: resolution.clearRefundLocks,
      },
    });
    const entitlement = reconciled.record;
    if (!reconciled.shouldPersist) {
      return Response.json({
        received: true,
        ignored: true,
        reason: "stale_or_duplicate_cursor",
      });
    }
    await upsertStripeEntitlement(store, existing, entitlement);

    return Response.json({
      received: true,
      provider: "stripe",
      subscription_id: subscriptionID,
      status: entitlement.status,
      retained_deleted_account: binding.deletedAccount,
    });
  } catch (error) {
    const status = error instanceof WebhookError ? error.status : 500;
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

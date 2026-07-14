import {
  financialEventChargeID,
  hasCanonicalFullSuccessfulRefund,
  stripeFinancialEventAction,
} from "./stripe-entitlement.ts";

export type ChargeLockDecision = {
  chargeID: string;
  blocked: boolean;
};

export type SubscriptionEventResolution = {
  subscriptionID?: string;
  refundLock?: ChargeLockDecision;
  disputeLock?: ChargeLockDecision;
  clearRefundLocks?: boolean;
  ignoredReason?: string;
};

type StripeListPage = {
  data?: any[];
  has_more?: boolean;
};

export type StripeEventLookupClient = {
  charges: { retrieve: (id: string) => Promise<any> };
  refunds: {
    list: (params: Record<string, unknown>) => Promise<StripeListPage>;
  };
  disputes: {
    retrieve: (id: string) => Promise<any>;
    list: (params: Record<string, unknown>) => Promise<StripeListPage>;
  };
  invoices: { retrieve: (id: string) => Promise<any> };
};

const BLOCKING_DISPUTE_STATUSES = new Set([
  "warning_needs_response",
  "warning_under_review",
  "needs_response",
  "under_review",
  "lost",
]);
const NON_BLOCKING_DISPUTE_STATUSES = new Set(["warning_closed", "won"]);
const MAX_LIST_PAGES = 100;

function objectID(value: unknown): string | undefined {
  if (typeof value === "string" && value) return value;
  if (value && typeof value === "object" && "id" in value) {
    const id = (value as { id?: unknown }).id;
    return typeof id === "string" && id ? id : undefined;
  }
  return undefined;
}

function directSubscriptionID(event: any): string | undefined {
  const type = String(event?.type || "");
  const object = event?.data?.object;
  if (type.startsWith("customer.subscription.")) return objectID(object);
  if (type.startsWith("checkout.session.")) {
    return objectID(object?.subscription);
  }
  if (
    type.startsWith("invoice.") || type.startsWith("subscription_schedule.")
  ) {
    return objectID(object?.subscription);
  }
  return undefined;
}

async function listAll(
  fetchPage: (startingAfter?: string) => Promise<StripeListPage>,
): Promise<any[]> {
  const result: any[] = [];
  let startingAfter: string | undefined;
  for (let pageIndex = 0; pageIndex < MAX_LIST_PAGES; pageIndex += 1) {
    const page = await fetchPage(startingAfter);
    const data = Array.isArray(page?.data) ? page.data : [];
    result.push(...data);
    if (!page?.has_more) return result;
    const next = objectID(data[data.length - 1]);
    if (!next || next === startingAfter) {
      throw new Error("Stripe list pagination cursor is invalid.");
    }
    startingAfter = next;
  }
  throw new Error("Stripe list exceeded the safe pagination limit.");
}

async function canonicalRefundLock(
  stripe: StripeEventLookupClient,
  charge: any,
  chargeID: string,
): Promise<ChargeLockDecision> {
  const refunds = await listAll((startingAfter) =>
    stripe.refunds.list({
      charge: chargeID,
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
    })
  );
  return {
    chargeID,
    blocked: hasCanonicalFullSuccessfulRefund(charge, refunds),
  };
}

function disputeSnapshotBlocks(disputes: any[]): boolean {
  let blocked = false;
  for (const dispute of disputes) {
    const status = String(dispute?.status || "");
    if (BLOCKING_DISPUTE_STATUSES.has(status)) {
      blocked = true;
      continue;
    }
    if (NON_BLOCKING_DISPUTE_STATUSES.has(status)) continue;
    throw new Error(`Unknown Stripe dispute status: ${status || "missing"}.`);
  }
  return blocked;
}

async function canonicalDisputeLock(
  stripe: StripeEventLookupClient,
  disputeID: string,
): Promise<{ charge: any; decision: ChargeLockDecision }> {
  // The signed event only identifies the dispute. Current Stripe API objects
  // decide whether the charge remains blocked.
  const canonicalDispute = await stripe.disputes.retrieve(disputeID);
  const chargeID = objectID(canonicalDispute?.charge);
  if (!chargeID) throw new Error("Canonical Stripe dispute charge is missing.");
  const charge = await stripe.charges.retrieve(chargeID);
  const disputes = await listAll((startingAfter) =>
    stripe.disputes.list({
      charge: chargeID,
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
    })
  );
  if (!disputes.some((item) => objectID(item) === disputeID)) {
    disputes.push(canonicalDispute);
  }
  return {
    charge,
    decision: { chargeID, blocked: disputeSnapshotBlocks(disputes) },
  };
}

async function subscriptionIDForCharge(
  stripe: StripeEventLookupClient,
  charge: any,
): Promise<string | undefined> {
  const invoiceID = objectID(charge?.invoice);
  if (!invoiceID) return undefined;
  const invoice = await stripe.invoices.retrieve(invoiceID);
  return objectID(invoice?.subscription);
}

export async function resolveStripeSubscriptionEvent(
  stripe: StripeEventLookupClient,
  event: any,
): Promise<SubscriptionEventResolution> {
  const type = String(event?.type || "");
  if (type === "invoice.paid" || type === "invoice.payment_succeeded") {
    const invoiceID = objectID(event?.data?.object);
    if (!invoiceID) return { ignoredReason: "missing_invoice" };
    const invoice = await stripe.invoices.retrieve(invoiceID);
    const paidSubscriptionID = objectID(invoice?.subscription);
    if (!paidSubscriptionID) {
      return { ignoredReason: "non_subscription_invoice" };
    }
    return {
      subscriptionID: paidSubscriptionID,
      clearRefundLocks: invoice?.paid === true || invoice?.status === "paid",
    };
  }

  const subscriptionID = directSubscriptionID(event);
  if (subscriptionID) {
    return { subscriptionID };
  }

  const object = event?.data?.object;
  const action = stripeFinancialEventAction(event?.type);
  if (!action) return { ignoredReason: "unrelated_event" };

  if (action === "refund_snapshot") {
    const chargeID = financialEventChargeID(event?.type, object);
    if (!chargeID) return { ignoredReason: "missing_charge" };
    const charge = await stripe.charges.retrieve(chargeID);
    const resolvedSubscriptionID = await subscriptionIDForCharge(
      stripe,
      charge,
    );
    if (!resolvedSubscriptionID) {
      return { ignoredReason: "non_subscription_charge" };
    }
    return {
      subscriptionID: resolvedSubscriptionID,
      refundLock: await canonicalRefundLock(stripe, charge, chargeID),
    };
  }

  const disputeID = objectID(object);
  if (!disputeID) return { ignoredReason: "missing_dispute" };
  const canonical = await canonicalDisputeLock(stripe, disputeID);
  const resolvedSubscriptionID = await subscriptionIDForCharge(
    stripe,
    canonical.charge,
  );
  if (!resolvedSubscriptionID) {
    return { ignoredReason: "non_subscription_charge" };
  }
  return {
    subscriptionID: resolvedSubscriptionID,
    disputeLock: canonical.decision,
  };
}

import { resolveStripeSubscriptionEvent } from "./stripe-event-resolution.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function lookupClient(input: {
  charges?: Record<string, any>;
  invoices?: Record<string, any>;
  refundsByCharge?: Record<string, any[]>;
  disputesByID?: Record<string, any>;
  disputesByCharge?: Record<string, any[]>;
}) {
  const calls = { charges: 0, invoices: 0, refunds: 0, disputes: 0 };
  return {
    calls,
    client: {
      charges: {
        retrieve: async (id: string) => {
          calls.charges += 1;
          return input.charges?.[id] || {};
        },
      },
      refunds: {
        list: async (params: Record<string, unknown>) => {
          calls.refunds += 1;
          const charge = String(params.charge || "");
          return {
            data: input.refundsByCharge?.[charge] || [],
            has_more: false,
          };
        },
      },
      disputes: {
        retrieve: async (id: string) => {
          calls.disputes += 1;
          return input.disputesByID?.[id] || {};
        },
        list: async (params: Record<string, unknown>) => {
          calls.disputes += 1;
          const charge = String(params.charge || "");
          return {
            data: input.disputesByCharge?.[charge] || [],
            has_more: false,
          };
        },
      },
      invoices: {
        retrieve: async (id: string) => {
          calls.invoices += 1;
          return input.invoices?.[id] || {};
        },
      },
    },
  };
}

Deno.test("full successful refund resolves canonical subscription and locks charge", async () => {
  const stripe = lookupClient({
    charges: {
      ch_1: { id: "ch_1", amount: 1000, amount_captured: 600, invoice: "in_1" },
    },
    refundsByCharge: {
      ch_1: [
        { id: "re_1", amount: 250, status: "succeeded" },
        { id: "re_2", amount: 350, status: "succeeded" },
      ],
    },
    invoices: { in_1: { subscription: "sub_1" } },
  });
  const result = await resolveStripeSubscriptionEvent(stripe.client, {
    type: "charge.refunded",
    data: { object: { id: "ch_1" } },
  });
  assert(result.subscriptionID === "sub_1", "subscription was not resolved");
  assert(result.refundLock?.blocked === true, "full refund did not lock");
  assert(result.refundLock?.chargeID === "ch_1", "refund charge id drifted");
  assert(stripe.calls.refunds === 1, "canonical refunds were not listed");
});

Deno.test("pending, failed, or canceled full refund clears only refund lock", async () => {
  for (const status of ["pending", "failed", "canceled"]) {
    const stripe = lookupClient({
      charges: {
        ch_1: { id: "ch_1", amount_captured: 1000, invoice: "in_1" },
      },
      refundsByCharge: {
        ch_1: [{ id: `re_${status}`, amount: 1000, status }],
      },
      invoices: { in_1: { subscription: "sub_1" } },
    });
    const result = await resolveStripeSubscriptionEvent(stripe.client, {
      type: status === "failed" ? "refund.failed" : "refund.updated",
      data: { object: { charge: "ch_1", status } },
    });
    assert(
      result.refundLock?.blocked === false,
      `${status} refund remained locked`,
    );
  }
});

Deno.test("partial successful refund remains unlocked", async () => {
  const stripe = lookupClient({
    charges: { ch_1: { id: "ch_1", amount_captured: 1000, invoice: "in_1" } },
    refundsByCharge: {
      ch_1: [{ id: "re_1", amount: 400, status: "succeeded" }],
    },
    invoices: { in_1: { subscription: "sub_1" } },
  });
  const result = await resolveStripeSubscriptionEvent(stripe.client, {
    type: "refund.updated",
    data: { object: { charge: "ch_1" } },
  });
  assert(result.refundLock?.blocked === false, "partial refund locked access");
});

Deno.test("dispute event status is ignored in favor of canonical active snapshot", async () => {
  const stripe = lookupClient({
    charges: { ch_1: { id: "ch_1", invoice: "in_1" } },
    invoices: { in_1: { subscription: "sub_1" } },
    disputesByID: {
      dp_1: { id: "dp_1", charge: "ch_1", status: "under_review" },
    },
    disputesByCharge: {
      ch_1: [{ id: "dp_1", charge: "ch_1", status: "under_review" }],
    },
  });
  const result = await resolveStripeSubscriptionEvent(stripe.client, {
    type: "charge.dispute.closed",
    data: { object: { id: "dp_1", charge: "ch_fake", status: "won" } },
  });
  assert(
    result.subscriptionID === "sub_1",
    "canonical charge was not followed",
  );
  assert(
    result.disputeLock?.blocked === true,
    "event snapshot overrode canonical dispute",
  );
  assert(
    result.disputeLock?.chargeID === "ch_1",
    "canonical charge id was ignored",
  );
  assert(stripe.calls.disputes === 2, "dispute retrieve/list was incomplete");
});

Deno.test("canonical won dispute unlocks even when event snapshot says open", async () => {
  const stripe = lookupClient({
    charges: { ch_1: { id: "ch_1", invoice: "in_1" } },
    invoices: { in_1: { subscription: "sub_1" } },
    disputesByID: {
      dp_1: { id: "dp_1", charge: "ch_1", status: "won" },
    },
    disputesByCharge: {
      ch_1: [{ id: "dp_1", charge: "ch_1", status: "won" }],
    },
  });
  const result = await resolveStripeSubscriptionEvent(stripe.client, {
    type: "charge.dispute.created",
    data: { object: { id: "dp_1", status: "needs_response" } },
  });
  assert(result.disputeLock?.blocked === false, "canonical win stayed locked");
});

Deno.test("one won dispute cannot clear another blocking dispute on same charge", async () => {
  const stripe = lookupClient({
    charges: { ch_1: { id: "ch_1", invoice: "in_1" } },
    invoices: { in_1: { subscription: "sub_1" } },
    disputesByID: {
      dp_won: { id: "dp_won", charge: "ch_1", status: "won" },
    },
    disputesByCharge: {
      ch_1: [
        { id: "dp_won", charge: "ch_1", status: "won" },
        { id: "dp_lost", charge: "ch_1", status: "lost" },
      ],
    },
  });
  const result = await resolveStripeSubscriptionEvent(stripe.client, {
    type: "charge.dispute.closed",
    data: { object: { id: "dp_won", status: "won" } },
  });
  assert(result.disputeLock?.blocked === true, "other lost dispute was erased");
});

Deno.test("unknown canonical dispute status fails closed", async () => {
  const stripe = lookupClient({
    charges: { ch_1: { id: "ch_1", invoice: "in_1" } },
    invoices: { in_1: { subscription: "sub_1" } },
    disputesByID: {
      dp_1: { id: "dp_1", charge: "ch_1", status: "future_status" },
    },
    disputesByCharge: {
      ch_1: [{ id: "dp_1", charge: "ch_1", status: "future_status" }],
    },
  });
  let threw = false;
  try {
    await resolveStripeSubscriptionEvent(stripe.client, {
      type: "charge.dispute.updated",
      data: { object: { id: "dp_1" } },
    });
  } catch {
    threw = true;
  }
  assert(threw, "unknown dispute status silently unlocked access");
});

Deno.test("only a canonically paid invoice requests refund-lock clearing", async () => {
  const paid = lookupClient({
    invoices: { in_paid: { id: "in_paid", subscription: "sub_1", paid: true } },
  });
  const unpaid = lookupClient({
    invoices: {
      in_unpaid: { id: "in_unpaid", subscription: "sub_1", paid: false },
    },
  });
  const paidResult = await resolveStripeSubscriptionEvent(paid.client, {
    type: "invoice.paid",
    data: { object: { id: "in_paid", subscription: "sub_fake" } },
  });
  const unpaidResult = await resolveStripeSubscriptionEvent(unpaid.client, {
    type: "invoice.payment_succeeded",
    data: { object: { id: "in_unpaid", paid: true } },
  });
  assert(
    paidResult.subscriptionID === "sub_1",
    "canonical invoice was ignored",
  );
  assert(
    paidResult.clearRefundLocks === true,
    "paid invoice did not clear refunds",
  );
  assert(
    !unpaidResult.clearRefundLocks,
    "unpaid canonical invoice cleared refunds",
  );
});

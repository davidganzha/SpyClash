export const CURRENT_BASE44_APP_ID = "69a0e57fa939f578082f8091";

const BASE44_APP_ID_PATTERN = /^[0-9a-f]{24}$/i;

export type StripeBindingDecision = "accept" | "ignore" | "conflict";

export function resolveExpectedBase44AppID(...candidates: unknown[]): string {
  for (const candidate of candidates) {
    const value = String(candidate || "").trim();
    if (BASE44_APP_ID_PATTERN.test(value)) return value.toLowerCase();
  }
  return CURRENT_BASE44_APP_ID;
}

export function stripeSubscriptionBindingDecision(input: {
  alreadyBound: boolean;
  expectedUserID: string;
  expectedAppID: string;
  metadataUserID?: unknown;
  metadataAppID?: unknown;
}): StripeBindingDecision {
  const metadataUserID = String(input.metadataUserID || "").trim();
  const metadataAppID = String(input.metadataAppID || "").trim().toLowerCase();

  if (!input.alreadyBound) {
    return metadataUserID === input.expectedUserID &&
        metadataAppID === input.expectedAppID
      ? "accept"
      : "ignore";
  }

  if (metadataUserID && metadataUserID !== input.expectedUserID) {
    return "conflict";
  }
  if (metadataAppID && metadataAppID !== input.expectedAppID) {
    return "conflict";
  }
  return "accept";
}

export function preserveStoredFinancialRevocation(
  storedStatus: unknown,
  canonicalStatus: unknown,
): string {
  return applyStoredStripeFinancialLocks(
    { status: String(storedStatus || "") },
    canonicalStatus,
  );
}

export function applyStoredStripeFinancialLocks(
  stored: {
    status?: unknown;
    stripe_refund_blocked_charge_ids?: unknown;
    stripe_dispute_blocked_charge_ids?: unknown;
  } | undefined,
  canonicalStatus: unknown,
): string {
  const canonical = String(canonicalStatus || "unknown");
  const refundValue = stored?.stripe_refund_blocked_charge_ids;
  const disputeValue = stored?.stripe_dispute_blocked_charge_ids;
  const refundFieldPresent = Array.isArray(refundValue);
  const disputeFieldPresent = Array.isArray(disputeValue);
  const refundLocked = refundFieldPresent
    ? refundValue.some((value) => Boolean(String(value || "").trim()))
    : stored?.status === "refunded";
  const disputeLocked = disputeFieldPresent
    ? disputeValue.some((value) => Boolean(String(value || "").trim()))
    : stored?.status === "revoked";
  if (refundLocked) return "refunded";
  if (disputeLocked) return "revoked";
  return canonical;
}

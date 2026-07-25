export type EntitlementRecord = {
  id?: string;
  source_key?: string;
  user_id?: string;
  user_email?: string;
  provider?: string;
  product_id?: string;
  price_id?: string;
  stripe_subscription_id?: string;
  stripe_refund_blocked_charge_ids?: string[];
  stripe_dispute_blocked_charge_ids?: string[];
  stripe_refund_event_cursors?: Record<string, string>;
  stripe_dispute_event_cursors?: Record<string, string>;
  provider_customer_id?: string;
  status?: string;
  purchased_at?: string;
  expires_at?: string;
  environment?: string;
  cancel_at_period_end?: boolean;
  last_verified_at?: string;
  provider_event_at?: string;
  provider_event_id?: string;
};

export const CURRENT_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const LEGACY_STRIPE_PRICE_ID = "price_1TR5wiRFCq3jt6C66NdM8NY4";

const BASE44_APP_ID_PATTERN = /^[0-9a-f]{24}$/i;

export type StripeWebhookBindingResult =
  | { decision: "accept"; userID: string; deletedAccount: boolean }
  | { decision: "ignore"; reason: string }
  | { decision: "conflict"; reason: string };

export type StripeFinancialEventAction =
  | "refund_snapshot"
  | "dispute_snapshot";

export type StripeFinancialLocks = {
  refundChargeIDs: string[];
  disputeChargeIDs: string[];
};

export type StripeFinancialStateUpdate = {
  refundLock?: { chargeID: string; blocked: boolean };
  disputeLock?: { chargeID: string; blocked: boolean };
  clearRefundLocks?: boolean;
};

export const LEGACY_REFUND_LOCK = "legacy:refund";
export const LEGACY_DISPUTE_LOCK = "legacy:dispute";

export function resolveExpectedBase44AppID(...candidates: unknown[]): string {
  for (const candidate of candidates) {
    const value = String(candidate || "").trim();
    if (BASE44_APP_ID_PATTERN.test(value)) return value.toLowerCase();
  }
  return CURRENT_BASE44_APP_ID;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function deletedEntitlementUserID(
  value: unknown,
): Promise<string> {
  const userID = String(value || "").trim();
  if (!userID) throw new Error("A Stripe metadata user id is required.");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-deleted-account:${userID}`),
  );
  return `deleted:${hex(digest).slice(0, 40)}`;
}

function isDeletedEntitlementUserID(value: string): boolean {
  return /^deleted:[0-9a-f]{40}$/.test(value);
}

export async function resolveStripeWebhookBinding(input: {
  existingUserIDs: unknown[];
  metadataUserID?: unknown;
  metadataAppID?: unknown;
  expectedAppID: string;
}): Promise<StripeWebhookBindingResult> {
  const existingUserIDs = Array.from(
    new Set(
      input.existingUserIDs
        .map((value) => String(value || "").trim())
        .filter(Boolean),
    ),
  );
  const metadataUserID = String(input.metadataUserID || "").trim();
  const metadataAppID = String(input.metadataAppID || "").trim().toLowerCase();
  if (existingUserIDs.length > 1) {
    const rawOwners = existingUserIDs.filter((owner) =>
      !isDeletedEntitlementUserID(owner)
    );
    const tombstoneOwners = existingUserIDs.filter(isDeletedEntitlementUserID);
    if (
      rawOwners.length === 1 && tombstoneOwners.length === 1 &&
      await deletedEntitlementUserID(rawOwners[0]) === tombstoneOwners[0]
    ) {
      const metadataMatchesOwner = !metadataUserID ||
        metadataUserID === rawOwners[0] ||
        metadataUserID === tombstoneOwners[0];
      const metadataMatchesApp = !metadataAppID ||
        metadataAppID === input.expectedAppID;
      if (metadataMatchesOwner && metadataMatchesApp) {
        // A raw+tombstone pair can exist only across an interrupted deletion
        // transition. Return the raw owner so persistence can check User: a
        // missing User redacts the raw row one-way, while a live User fails the
        // mixed-owner CAS closed.
        return {
          decision: "accept",
          userID: rawOwners[0],
          deletedAccount: true,
        };
      }
    }
    return { decision: "conflict", reason: "conflicting_existing_owners" };
  }

  const existingUserID = existingUserIDs[0] || "";
  if (existingUserID) {
    const deletedAccount = isDeletedEntitlementUserID(existingUserID);
    const metadataMatchesOwner = !metadataUserID ||
      metadataUserID === existingUserID ||
      (deletedAccount &&
        await deletedEntitlementUserID(metadataUserID) === existingUserID);
    if (!metadataMatchesOwner) {
      return { decision: "conflict", reason: "conflicting_user_metadata" };
    }
    if (metadataAppID && metadataAppID !== input.expectedAppID) {
      return { decision: "conflict", reason: "conflicting_app_metadata" };
    }
    return { decision: "accept", userID: existingUserID, deletedAccount };
  }

  if (metadataUserID && metadataAppID === input.expectedAppID) {
    return {
      decision: "accept",
      userID: metadataUserID,
      deletedAccount: false,
    };
  }
  return { decision: "ignore", reason: "missing_exact_new_binding" };
}

export function stripeFinancialEventAction(
  eventType: unknown,
): StripeFinancialEventAction | null {
  const type = String(eventType || "");
  if (
    type === "charge.refunded" ||
    type === "charge.refund.updated" ||
    type === "refund.created" ||
    type === "refund.updated" ||
    type === "refund.failed"
  ) {
    return "refund_snapshot";
  }
  return type === "charge.dispute.created" ||
      type === "charge.dispute.updated" ||
      type === "charge.dispute.closed" ||
      type === "charge.dispute.funds_reinstated" ||
      type === "charge.dispute.funds_withdrawn"
    ? "dispute_snapshot"
    : null;
}

export function financialEventChargeID(
  eventType: unknown,
  object: any,
): string | undefined {
  const type = String(eventType || "");
  return type === "charge.refunded"
    ? objectID(object)
    : objectID(object?.charge);
}

export function hasCanonicalFullSuccessfulRefund(
  charge: any,
  refunds: any[],
): boolean {
  const amount = Number(charge?.amount_captured ?? charge?.amount);
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new Error("Stripe charge amount is invalid.");
  }

  let successfulAmount = 0;
  for (const refund of refunds) {
    const status = String(refund?.status || "");
    if (
      status !== "succeeded" && status !== "pending" &&
      status !== "requires_action" && status !== "failed" &&
      status !== "canceled"
    ) {
      throw new Error(`Unknown Stripe refund status: ${status || "missing"}.`);
    }
    if (status !== "succeeded") continue;
    const refundAmount = Number(refund?.amount);
    if (!Number.isFinite(refundAmount) || refundAmount <= 0) {
      throw new Error("Stripe refund amount is invalid.");
    }
    successfulAmount += refundAmount;
  }
  return successfulAmount >= amount;
}

export function preserveStoredFinancialRevocation(
  storedStatus: unknown,
  canonicalStatus: unknown,
  allowCanonicalRestoration = false,
): string {
  const stored = String(storedStatus || "");
  const canonical = String(canonicalStatus || "unknown");
  const canonicalGrants = canonical === "active" || canonical === "trialing" ||
    canonical === "grace_period";
  if (stored === "refunded" && canonicalGrants) return stored;
  return stored === "revoked" && canonicalGrants && !allowCanonicalRestoration
    ? stored
    : canonical;
}

function normalizedLockIDs(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return Array.from(
    new Set(
      value.map((item) => String(item || "").trim()).filter(Boolean),
    ),
  ).sort();
}

export function stripeFinancialLocksFromRecord(
  record?: EntitlementRecord,
): StripeFinancialLocks {
  const refundFieldPresent = Array.isArray(
    record?.stripe_refund_blocked_charge_ids,
  );
  const disputeFieldPresent = Array.isArray(
    record?.stripe_dispute_blocked_charge_ids,
  );
  const refundChargeIDs = normalizedLockIDs(
    record?.stripe_refund_blocked_charge_ids,
  );
  const disputeChargeIDs = normalizedLockIDs(
    record?.stripe_dispute_blocked_charge_ids,
  );

  // Preserve pre-migration financial locks until a later successful invoice
  // supplies an explicit reset cursor. New records always persist the arrays.
  if (!refundFieldPresent && record?.status === "refunded") {
    refundChargeIDs.push(LEGACY_REFUND_LOCK);
  }
  if (!disputeFieldPresent && record?.status === "revoked") {
    disputeChargeIDs.push(LEGACY_DISPUTE_LOCK);
  }
  return {
    refundChargeIDs: normalizedLockIDs(refundChargeIDs),
    disputeChargeIDs: normalizedLockIDs(disputeChargeIDs),
  };
}

export function setStripeChargeLock(
  current: string[],
  chargeID: string,
  blocked: boolean,
): string[] {
  const ids = new Set(normalizedLockIDs(current));
  if (blocked) ids.add(chargeID);
  else ids.delete(chargeID);
  return Array.from(ids).sort();
}

export function statusWithStripeFinancialLocks(
  canonicalStatus: string,
  locks: StripeFinancialLocks,
): string {
  if (locks.refundChargeIDs.length > 0) return "refunded";
  if (locks.disputeChargeIDs.length > 0) return "revoked";
  return canonicalStatus;
}

function normalizedCursorMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .map(([key, cursor]) => [key.trim(), String(cursor || "").trim()])
      .filter(([key, cursor]) => Boolean(key) && Boolean(cursor))
      .sort(([left], [right]) => left.localeCompare(right)),
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

function objectID(value: unknown): string | undefined {
  if (typeof value === "string" && value) return value;
  if (value && typeof value === "object" && "id" in value) {
    const id = (value as { id?: unknown }).id;
    return typeof id === "string" && id ? id : undefined;
  }
  return undefined;
}

export function subscriptionPriceIDs(subscription: any): string[] {
  return (subscription?.items?.data || [])
    .map((item: any) => item?.price?.id)
    .filter((value: unknown): value is string =>
      typeof value === "string" && Boolean(value)
    );
}

export function isLegacySubscription(
  subscription: any,
  legacyPriceID: string,
): boolean {
  return hasStripePrice(subscriptionPriceIDs(subscription), legacyPriceID);
}

export function normalizeStripeEntitlement(input: {
  subscription: any;
  userID: string;
  userEmail?: string;
  legacyPriceID: string;
  eventID: string;
  eventCreated: number;
  verifiedAt?: Date;
}): EntitlementRecord {
  const { subscription } = input;
  if (!subscription?.id) throw new Error("Stripe subscription ID is missing.");

  const firstItem = subscription.items?.data?.[0];
  const priceID = firstItem?.price?.id;
  // Existing rows may already carry this fallback value, so retain it as a
  // provider-compatibility identifier rather than presenting it to users.
  const productID = objectID(firstItem?.price?.product) || priceID ||
    "stripe_limitless";
  const expiresAt = isoFromUnixSeconds(
    subscription.current_period_end || subscription.ended_at ||
      subscription.canceled_at || subscription.created,
  );
  if (!expiresAt) throw new Error("Stripe subscription expiry is missing.");

  const status = isLegacySubscription(subscription, input.legacyPriceID)
    ? stripeStatusToEntitlementStatus(subscription.status)
    : "revoked";
  const verifiedAt = input.verifiedAt ?? new Date();

  return {
    source_key: `stripe:${subscription.id}`,
    user_id: input.userID,
    user_email: input.userEmail,
    provider: "stripe",
    product_id: productID,
    price_id: priceID,
    stripe_subscription_id: subscription.id,
    provider_customer_id: objectID(subscription.customer),
    status,
    purchased_at: isoFromUnixSeconds(
      subscription.start_date || subscription.created,
    ),
    expires_at: expiresAt,
    environment: subscription.livemode ? "production" : "sandbox",
    cancel_at_period_end: Boolean(subscription.cancel_at_period_end),
    last_verified_at: verifiedAt.toISOString(),
    provider_event_at: isoFromUnixSeconds(input.eventCreated) ||
      verifiedAt.toISOString(),
    provider_event_id: input.eventID,
  };
}

type ParsedStripeCursor = { timestamp: number; eventID: string };

function parsedCursorFromRecord(
  record: Pick<EntitlementRecord, "provider_event_at" | "provider_event_id">,
): ParsedStripeCursor | undefined {
  const timestamp = Date.parse(record.provider_event_at || "");
  const eventID = String(record.provider_event_id || "");
  return Number.isFinite(timestamp) && eventID
    ? { timestamp, eventID }
    : undefined;
}

function compareStripeCursors(
  left: ParsedStripeCursor,
  right: ParsedStripeCursor,
): number {
  if (left.timestamp !== right.timestamp) {
    return left.timestamp - right.timestamp;
  }
  if (left.eventID === right.eventID) return 0;
  return left.eventID < right.eventID ? -1 : 1;
}

export function stripeEventCursor(
  record: Pick<EntitlementRecord, "provider_event_at" | "provider_event_id">,
): string {
  const cursor = parsedCursorFromRecord(record);
  if (!cursor) throw new Error("Stripe event cursor is missing.");
  return `${cursor.timestamp}|${cursor.eventID}`;
}

function parseStoredStripeCursor(
  value: unknown,
): ParsedStripeCursor | undefined {
  const raw = String(value || "");
  const separator = raw.indexOf("|");
  if (separator <= 0) return undefined;
  const timestamp = Number(raw.slice(0, separator));
  const eventID = raw.slice(separator + 1);
  return Number.isFinite(timestamp) && eventID
    ? { timestamp, eventID }
    : undefined;
}

export function shouldApplyStripeCursor(
  currentCursor: unknown,
  incoming: Pick<EntitlementRecord, "provider_event_at" | "provider_event_id">,
): boolean {
  const incomingCursor = parsedCursorFromRecord(incoming);
  if (!incomingCursor) return false;
  const current = parseStoredStripeCursor(currentCursor);
  if (current?.eventID === incomingCursor.eventID) return false;
  return !current || compareStripeCursors(incomingCursor, current) > 0;
}

export function shouldApplyStripeEvent(
  current: EntitlementRecord,
  incoming: EntitlementRecord,
): boolean {
  const incomingCursor = parsedCursorFromRecord(incoming);
  if (!incomingCursor) return false;
  const currentCursor = parsedCursorFromRecord(current);
  if (currentCursor?.eventID === incomingCursor.eventID) return false;
  return !currentCursor ||
    compareStripeCursors(incomingCursor, currentCursor) > 0;
}

export function reconcileStripeEntitlementState(input: {
  current?: EntitlementRecord;
  incoming: EntitlementRecord;
  update?: StripeFinancialStateUpdate;
}): { record: EntitlementRecord; shouldPersist: boolean } {
  const { current, update = {} } = input;
  const record: EntitlementRecord = { ...input.incoming };
  const locks = stripeFinancialLocksFromRecord(current);
  const refundCursors = normalizedCursorMap(
    current?.stripe_refund_event_cursors,
  );
  const disputeCursors = normalizedCursorMap(
    current?.stripe_dispute_event_cursors,
  );
  const incomingCursor = stripeEventCursor(record);
  const hasFinancialMutation = Boolean(update.refundLock || update.disputeLock);
  let acceptedFinancialMutation = false;

  if (update.refundLock) {
    const chargeID = update.refundLock.chargeID;
    if (shouldApplyStripeCursor(refundCursors[chargeID], record)) {
      locks.refundChargeIDs = setStripeChargeLock(
        locks.refundChargeIDs,
        chargeID,
        update.refundLock.blocked,
      );
      refundCursors[chargeID] = incomingCursor;
      acceptedFinancialMutation = true;
    }
  }
  if (update.disputeLock) {
    const chargeID = update.disputeLock.chargeID;
    if (shouldApplyStripeCursor(disputeCursors[chargeID], record)) {
      locks.disputeChargeIDs = setStripeChargeLock(
        locks.disputeChargeIDs,
        chargeID,
        update.disputeLock.blocked,
      );
      disputeCursors[chargeID] = incomingCursor;
      acceptedFinancialMutation = true;
    }
  }

  if (hasFinancialMutation && !acceptedFinancialMutation) {
    return { record, shouldPersist: false };
  }

  const incomingIsNewerGlobally = !current ||
    shouldApplyStripeEvent(current, record);
  if (!hasFinancialMutation) {
    if (!incomingIsNewerGlobally) return { record, shouldPersist: false };
    if (update.clearRefundLocks) {
      for (const chargeID of locks.refundChargeIDs) {
        if (chargeID !== LEGACY_REFUND_LOCK) {
          refundCursors[chargeID] = incomingCursor;
        }
      }
      locks.refundChargeIDs = [];
    }
  } else if (current && !incomingIsNewerGlobally) {
    // A delayed event for a different financial charge still needs canonical
    // reconciliation, but must not move the entitlement-wide audit cursor back.
    record.provider_event_at = current.provider_event_at;
    record.provider_event_id = current.provider_event_id;
  }

  record.stripe_refund_blocked_charge_ids = locks.refundChargeIDs;
  record.stripe_dispute_blocked_charge_ids = locks.disputeChargeIDs;
  record.stripe_refund_event_cursors = normalizedCursorMap(refundCursors);
  record.stripe_dispute_event_cursors = normalizedCursorMap(disputeCursors);
  record.status = statusWithStripeFinancialLocks(
    record.status || "unknown",
    locks,
  );
  return { record, shouldPersist: true };
}

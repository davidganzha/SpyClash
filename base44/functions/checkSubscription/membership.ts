// `limitless` remains on the wire solely so already-shipped clients can decode
// CASADA access. `protocol` is the canonical product meaning.
export type MembershipTier = "free" | "limitless";
export type AccessProtocol = "casada";
export type EntitlementProvider = "apple" | "stripe" | "admin" | "casada";

export type MembershipBenefits = {
  ai_generations_daily_limit: number | null;
  premium_avatars: boolean;
  full_history: boolean;
  advanced_statistics: boolean;
  history_limit: number | null;
};

export type EntitlementRecord = {
  id?: string;
  source_key?: string;
  user_id?: string;
  user_email?: string;
  provider?: EntitlementProvider | string;
  product_id?: string;
  price_id?: string;
  original_transaction_id?: string;
  transaction_id?: string;
  stripe_subscription_id?: string;
  stripe_refund_blocked_charge_ids?: string[];
  stripe_dispute_blocked_charge_ids?: string[];
  stripe_refund_event_cursors?: Record<string, string>;
  stripe_dispute_event_cursors?: Record<string, string>;
  provider_customer_id?: string;
  app_account_token?: string;
  status?: string;
  purchased_at?: string;
  expires_at?: string;
  environment?: "sandbox" | "production" | string;
  cancel_at_period_end?: boolean;
  last_verified_at?: string;
  provider_event_at?: string;
  provider_event_id?: string;
  created_date?: string;
};

export type AdminGrantRecord = {
  active?: boolean;
  expires_at?: string;
};

export const LEGACY_FREE_BENEFITS: MembershipBenefits = Object.freeze({
  ai_generations_daily_limit: 10,
  premium_avatars: false,
  full_history: false,
  advanced_statistics: false,
  history_limit: 5,
});

export const CASADA_BENEFITS: MembershipBenefits = Object.freeze({
  ai_generations_daily_limit: null,
  premium_avatars: true,
  full_history: true,
  advanced_statistics: true,
  history_limit: null,
});

// CASADA deliberately makes every previously paid capability available to
// every authenticated user. Provider entitlements remain readable only for
// historical billing compatibility and account reconciliation.
export const CASADA_PROTOCOL_ENABLED = true;
export const CASADA_COMPATIBILITY_EXPIRY = "9999-12-31T23:59:59Z";

const ACCESS_GRANTING_STATUSES = new Set([
  "active",
  "trialing",
  "grace_period",
]);

export function isEntitlementActive(
  entitlement: EntitlementRecord,
  now = new Date(),
): boolean {
  if (!ACCESS_GRANTING_STATUSES.has(String(entitlement.status || ""))) {
    return false;
  }

  if (!entitlement.expires_at) return false;
  const expiry = Date.parse(entitlement.expires_at);
  return Number.isFinite(expiry) && expiry > now.getTime();
}

export function summarizeMembership(
  entitlements: EntitlementRecord[],
  now = new Date(),
) {
  const activeEntitlements = entitlements.filter((item) =>
    isEntitlementActive(item, now)
  );
  const providers = Array.from(
    new Set(
      activeEntitlements
        .map((item) => item.provider)
        .filter((provider): provider is EntitlementProvider =>
          provider === "apple" || provider === "stripe"
        ),
    ),
  );

  const expiries = activeEntitlements
    .map((item) => item.expires_at)
    .filter((value): value is string => Boolean(value))
    .map((value) => ({ value, timestamp: Date.parse(value) }))
    .filter((item) => Number.isFinite(item.timestamp));

  const expiresAt = expiries.length === 0
    ? null
    : expiries.reduce((latest, item) =>
      item.timestamp > latest.timestamp ? item : latest
    ).value;
  const active = activeEntitlements.length > 0;

  return {
    active,
    tier: (active ? "limitless" : "free") as MembershipTier,
    status: active ? "active" : "inactive",
    providers,
    benefits: active ? CASADA_BENEFITS : LEGACY_FREE_BENEFITS,
    expires_at: expiresAt,
    activeEntitlements,
  };
}

export function applyCasadaAccess(
  membership: ReturnType<typeof summarizeMembership>,
) {
  if (!CASADA_PROTOCOL_ENABLED) {
    return { ...membership, protocol: null };
  }
  return {
    ...membership,
    active: true,
    tier: "limitless" as const,
    status: "active",
    providers: Array.from(
      new Set<EntitlementProvider>([...membership.providers, "casada"]),
    ),
    benefits: CASADA_BENEFITS,
    // Build 7 recognizes permanent access only through a known provider or a
    // future expiry. CASADA is not a billing provider, so use this documented
    // non-renewing compatibility sentinel rather than inventing Apple/Stripe.
    expires_at: CASADA_COMPATIBILITY_EXPIRY,
    protocol: "casada" as AccessProtocol,
  };
}

export function casadaMembershipResponse(now = new Date()) {
  if (!CASADA_PROTOCOL_ENABLED) return null;
  const membership = applyCasadaAccess(summarizeMembership([], now));
  return {
    active: membership.active,
    tier: membership.tier,
    protocol: membership.protocol,
    status: membership.status,
    providers: membership.providers,
    benefits: membership.benefits,
    expires_at: membership.expires_at,
    ai_generations_today: null,
    ai_remaining: null,
    sources: [],
    checked_at: now.toISOString(),
    checkout_required: false,
    provider_sync: {
      entitlements: "not_required",
      stripe: "not_required",
      persistence: "not_required",
      admin_grant: "not_required",
      quota: "not_required",
    },
  };
}

export function activeAdminGrantExpiry(
  grants: AdminGrantRecord[],
  now = new Date(),
): string | null | undefined {
  let latestExpiry: number | undefined;
  for (const grant of grants) {
    if (grant.active !== true) continue;
    const rawExpiry = typeof grant.expires_at === "string"
      ? grant.expires_at.trim()
      : "";
    if (!rawExpiry) return null;
    const expiry = Date.parse(rawExpiry);
    if (Number.isFinite(expiry) && expiry > now.getTime()) {
      latestExpiry = Math.max(latestExpiry ?? Number.NEGATIVE_INFINITY, expiry);
    }
  }
  return latestExpiry === undefined
    ? undefined
    : new Date(latestExpiry).toISOString();
}

export function applyAdminGrant(
  membership: ReturnType<typeof summarizeMembership>,
  grants: AdminGrantRecord[],
  now = new Date(),
) {
  const adminExpiry = activeAdminGrantExpiry(grants, now);
  if (adminExpiry === undefined) {
    return { membership, adminGrantActive: false };
  }

  const paidExpiry = membership.expires_at
    ? Date.parse(membership.expires_at)
    : Number.NEGATIVE_INFINITY;
  const manualExpiry = adminExpiry ? Date.parse(adminExpiry) : Infinity;
  const expiresAt = manualExpiry === Infinity
    ? null
    : manualExpiry > paidExpiry
    ? adminExpiry
    : membership.expires_at;

  return {
    membership: {
      ...membership,
      active: true,
      tier: "limitless" as const,
      status: "active",
      providers: Array.from(
        new Set<EntitlementProvider>([...membership.providers, "admin"]),
      ),
      benefits: CASADA_BENEFITS,
      expires_at: expiresAt,
    },
    adminGrantActive: true,
  };
}

export function stripeStatusToEntitlementStatus(status: unknown): string {
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

export function isoFromUnixSeconds(value: unknown): string | undefined {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
  return new Date(seconds * 1000).toISOString();
}

export function publicEntitlementSources(entitlements: EntitlementRecord[]) {
  return entitlements.map((item) => ({
    provider: item.provider,
    product_id: item.product_id || null,
    status: item.status || "unknown",
    expires_at: item.expires_at || null,
  }));
}

export function mergeEntitlements(
  stored: EntitlementRecord[],
  verified: EntitlementRecord[],
): EntitlementRecord[] {
  const merged = new Map<string, EntitlementRecord>();
  for (const item of stored) {
    const key = item.source_key || item.id;
    if (!key) continue;
    const current = merged.get(key);
    if (
      !current || entitlementFreshness(item) > entitlementFreshness(current)
    ) {
      merged.set(key, item);
    }
  }
  // Provider responses were fetched live in this request and therefore always
  // replace the canonical stored row for the same source.
  for (const item of verified) {
    const key = item.source_key || item.id;
    if (key) merged.set(key, item);
  }
  return Array.from(merged.values());
}

function entitlementFreshness(item: EntitlementRecord): number {
  for (
    const value of [
      item.provider_event_at,
      item.last_verified_at,
      item.created_date,
    ]
  ) {
    const timestamp = Date.parse(value || "");
    if (Number.isFinite(timestamp)) return timestamp;
  }
  return Number.NEGATIVE_INFINITY;
}

export function isBoundToAnotherUser(
  records: EntitlementRecord[],
  userId: string,
): boolean {
  return records.some((item) =>
    Boolean(item.user_id) && item.user_id !== userId
  );
}

export function hasStripePrice(
  priceIds: string[],
  expectedPriceId: string,
): boolean {
  return Boolean(expectedPriceId) && priceIds.includes(expectedPriceId);
}

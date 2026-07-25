// `limitless` remains on the wire solely so already-shipped clients can decode
// CASADA access. `protocol` is the canonical product meaning.
export type MembershipTier = "free" | "limitless";
export type AccessProtocol = "casada";

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
  provider?: string;
  status?: string;
  expires_at?: string;
  provider_event_at?: string;
  last_verified_at?: string;
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

// CASADA deliberately makes generation and every previously paid capability
// available to every authenticated user. Provider records remain historical
// billing compatibility data, not an access gate.
export const CASADA_PROTOCOL_ENABLED = true;
export const CASADA_COMPATIBILITY_EXPIRY = "9999-12-31T23:59:59Z";

const ACCESS_GRANTING_STATUSES = new Set([
  "active",
  "trialing",
  "grace_period",
]);

export function isActiveEntitlement(
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

export function resolveGenerationMembership(
  entitlements: EntitlementRecord[],
  now = new Date(),
) {
  const activeEntitlements = canonicalEntitlements(entitlements).filter((
    item,
  ) => isActiveEntitlement(item, now));
  const active = activeEntitlements.length > 0;
  const providers = Array.from(
    new Set(
      activeEntitlements
        .map((item) => item.provider)
        .filter((provider): provider is string =>
          provider === "apple" || provider === "stripe"
        ),
    ),
  );

  return {
    active,
    tier: (active ? "limitless" : "free") as MembershipTier,
    providers,
    benefits: active ? CASADA_BENEFITS : LEGACY_FREE_BENEFITS,
    expires_at: null as string | null,
  };
}

export function applyCasadaGenerationAccess(
  membership: ReturnType<typeof resolveGenerationMembership>,
) {
  if (!CASADA_PROTOCOL_ENABLED) {
    return { ...membership, protocol: null };
  }
  return {
    active: true,
    tier: "limitless" as const,
    providers: Array.from(new Set([...membership.providers, "casada"])),
    benefits: CASADA_BENEFITS,
    expires_at: CASADA_COMPATIBILITY_EXPIRY,
    protocol: "casada" as AccessProtocol,
  };
}

export function hasActiveAdminGrant(
  grants: AdminGrantRecord[],
  now = new Date(),
): boolean {
  return grants.some((grant) => {
    if (grant.active !== true) return false;
    const rawExpiry = typeof grant.expires_at === "string"
      ? grant.expires_at.trim()
      : "";
    if (!rawExpiry) return true;
    const expiry = Date.parse(rawExpiry);
    return Number.isFinite(expiry) && expiry > now.getTime();
  });
}

export function applyAdminGenerationGrant(
  membership: ReturnType<typeof resolveGenerationMembership>,
  grants: AdminGrantRecord[],
  now = new Date(),
) {
  if (!hasActiveAdminGrant(grants, now)) return membership;
  return {
    active: true,
    tier: "limitless" as const,
    providers: Array.from(new Set([...membership.providers, "admin"])),
    benefits: CASADA_BENEFITS,
    expires_at: membership.expires_at,
  };
}

export function canonicalEntitlements(
  entitlements: EntitlementRecord[],
): EntitlementRecord[] {
  const canonical = new Map<string, EntitlementRecord>();
  const unkeyed: EntitlementRecord[] = [];

  for (const item of entitlements) {
    const key = item.source_key || item.id;
    if (!key) {
      unkeyed.push(item);
      continue;
    }
    const current = canonical.get(key);
    if (!current || recordFreshness(item) > recordFreshness(current)) {
      canonical.set(key, item);
    }
  }
  return [...canonical.values(), ...unkeyed];
}

function recordFreshness(item: EntitlementRecord): number {
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

export function generationUsageMetadata(
  tier: MembershipTier,
  usedToday: number,
) {
  const limit = tier === "free"
    ? LEGACY_FREE_BENEFITS.ai_generations_daily_limit
    : null;
  return {
    ai_limit: limit,
    ai_generations_daily_limit: limit,
    ai_generations_today: usedToday,
    ai_remaining: limit === null ? null : Math.max(0, limit - usedToday),
  };
}

export function canGenerate(tier: MembershipTier, usedToday: number): boolean {
  return tier === "limitless" || usedToday < 10;
}

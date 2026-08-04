export const PUBLIC_ACCESS_TIER = "public";

export const PUBLIC_ACCESS_BENEFITS = Object.freeze({
  ai_generations_daily_limit: null,
  premium_avatars: true,
  full_history: true,
  advanced_statistics: true,
  history_limit: null,
});

export const PUBLIC_ACCESS_MEMBERSHIP = Object.freeze({
  active: true,
  tier: PUBLIC_ACCESS_TIER,
  status: "active",
  protocol: null,
  providers: Object.freeze([]),
  expires_at: null,
  ai_generations_today: null,
  ai_remaining: null,
  benefits: PUBLIC_ACCESS_BENEFITS,
});

const finiteNonNegativeNumber = (value, fallback) => {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
};

/**
 * Every capability is public and does not depend on a billing entitlement.
 * Ignore retired tier, protocol, and provider markers so internal compatibility
 * names never enter the browser state or the production client bundle.
 */
export function normalizeMembership(response) {
  const payload = response?.data ?? response ?? {};
  const hasKnownAiUsage = payload.ai_generations_today !== null
    && payload.ai_generations_today !== undefined
    && Number.isFinite(Number(payload.ai_generations_today));

  return {
    ...PUBLIC_ACCESS_MEMBERSHIP,
    ai_generations_today: hasKnownAiUsage
      ? finiteNonNegativeNumber(payload.ai_generations_today, 0)
      : null,
    benefits: PUBLIC_ACCESS_BENEFITS,
  };
}

export function getTodayAiUsage(user, now = new Date()) {
  if (!user) return 0;
  const today = now.toISOString().slice(0, 10);
  const lastGenerationDate = String(user.last_ai_generation_date || "").slice(0, 10);
  if (lastGenerationDate !== today) return 0;
  return finiteNonNegativeNumber(user.ai_generations_today, 0);
}

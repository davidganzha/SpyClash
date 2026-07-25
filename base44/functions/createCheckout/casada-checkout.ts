export const CASADA_PROTOCOL_ENABLED = true;
export const CASADA_COMPATIBILITY_EXPIRY = "9999-12-31T23:59:59Z";

export const CASADA_BENEFITS = Object.freeze({
  ai_generations_daily_limit: null,
  premium_avatars: true,
  full_history: true,
  advanced_statistics: true,
  history_limit: null,
});

export function casadaCheckoutRetirement() {
  if (!CASADA_PROTOCOL_ENABLED) return null;
  return {
    status: 409,
    body: {
      error: "Full access is already included. Checkout is not required.",
      code: "casada_checkout_retired",
      active: true,
      tier: "limitless",
      protocol: "casada",
      providers: ["casada"],
      expires_at: CASADA_COMPATIBILITY_EXPIRY,
      benefits: CASADA_BENEFITS,
      checkout_required: false,
    },
  } as const;
}

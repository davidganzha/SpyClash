// Fixed server-owned products. Rollout gates apply to new checkout only; signed
// existing weekly/monthly chains remain verifiable when a gate is disabled.
export const WEEKLY_PRODUCT = 'com.spyclash.ios.limitless.weekly';
export const MONTHLY_PRODUCT = 'com.spyclash.ios.limitless.monthly';
export const APPLE_SUBSCRIPTION_PRODUCTS = [WEEKLY_PRODUCT, MONTHLY_PRODUCT] as const;

export function isAppleSubscriptionProduct(value: unknown): value is typeof APPLE_SUBSCRIPTION_PRODUCTS[number] {
  return APPLE_SUBSCRIPTION_PRODUCTS.some(product => product === value);
}

export function monthlyAppleCheckoutEnabled(config: Record<string,string|undefined>) {
  return config.SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED === 'true';
}

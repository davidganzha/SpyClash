// Keep byte-identical copies in every independently deployed function bundle.
// Defaults preserve today's universal access. Deployment is NOT rollout approval.
export function rolloutEnabled(value: string | undefined): boolean {
  return value === "true";
}

function setting(name: string): string | undefined {
  try {
    return Deno.env.get(name);
  } catch {
    return undefined;
  }
}

export function limitlessEnabled(): boolean {
  return rolloutEnabled(setting("SPYCLASH_LIMITLESS_ENABLED"));
}

// Billing stays closed while client/server rollout is being validated.
export function limitlessApplePurchaseEnabled(): boolean {
  return limitlessEnabled() &&
    rolloutEnabled(setting("SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED"));
}

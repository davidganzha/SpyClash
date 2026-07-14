export const CURRENT_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const CHECKOUT_IDEMPOTENCY_WINDOW_MS = 5 * 60 * 1000;

const BASE44_APP_ID_PATTERN = /^[0-9a-f]{24}$/i;

export function resolveExpectedBase44AppID(...candidates: unknown[]): string {
  for (const candidate of candidates) {
    const value = String(candidate || "").trim();
    if (BASE44_APP_ID_PATTERN.test(value)) return value.toLowerCase();
  }
  return CURRENT_BASE44_APP_ID;
}

export async function checkoutIdempotencyKey(input: {
  appID: string;
  userID: string;
  priceID: string;
  email: string;
  now?: Date;
}): Promise<string> {
  const now = input.now ?? new Date();
  const nowMs = now.getTime();
  if (!Number.isFinite(nowMs)) {
    throw new Error("Checkout timestamp is invalid.");
  }

  const window = Math.floor(nowMs / CHECKOUT_IDEMPOTENCY_WINDOW_MS);
  const material = [
    input.appID.trim().toLowerCase(),
    input.userID.trim(),
    input.priceID.trim(),
    input.email.trim().toLowerCase(),
    String(window),
  ].join(":");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(material),
  );
  const hash = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `spyclash-limitless-checkout-${hash}`;
}

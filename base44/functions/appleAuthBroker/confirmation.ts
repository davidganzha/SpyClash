export type GoogleTransactionChannel = "primary" | "fallback";

export function googleTransactionChannelFromClaim(
  raw: unknown,
): GoogleTransactionChannel | null {
  return raw === "primary" || raw === "fallback" ? raw : null;
}

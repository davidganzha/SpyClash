export const REDACTED_ENTITLEMENT_EMAIL = "deleted-account@redacted.invalid";

function normalizedUserID(value: unknown): string {
  const userID = String(value ?? "").trim();
  if (!userID) {
    throw new Error("A user id is required to redact retained entitlements");
  }
  return userID;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Replaces direct SpyClash account identity while leaving the provider/source
 * and transaction fields untouched by the partial entity update.
 *
 * The stable one-way tombstone lets retained records for the same deleted
 * account be correlated for fraud and legal investigations without retaining
 * the Base44 user id or email address.
 */
export async function entitlementRetentionPatch(
  userIDValue: unknown,
): Promise<{ user_id: string; user_email: string }> {
  const userID = normalizedUserID(userIDValue);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-deleted-account:${userID}`),
  );

  return {
    user_id: `deleted:${hex(digest).slice(0, 40)}`,
    user_email: REDACTED_ENTITLEMENT_EMAIL,
  };
}

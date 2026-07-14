export const REDACTED_ENTITLEMENT_EMAIL = "deleted-account@redacted.invalid";

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function deletedAccountTombstone(value: unknown): Promise<string> {
  const userID = String(value ?? "").trim();
  if (!userID) throw new Error("A stable user id is required.");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-deleted-account:${userID}`),
  );
  return `deleted:${hex(digest).slice(0, 40)}`;
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
  return {
    user_id: await deletedAccountTombstone(userIDValue),
    user_email: REDACTED_ENTITLEMENT_EMAIL,
  };
}

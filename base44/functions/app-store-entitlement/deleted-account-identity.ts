function normalizedUserID(value: unknown): string {
  const userID = String(value ?? "").trim();
  if (!userID) {
    throw new Error("A user id is required to derive a deletion tombstone");
  }
  return userID;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** Stable one-way identity shared by deleteAccount and Apple prepare. */
export async function deletedAccountTombstone(
  userIDValue: unknown,
): Promise<string> {
  const userID = normalizedUserID(userIDValue);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-deleted-account:${userID}`),
  );
  return `deleted:${hex(digest).slice(0, 40)}`;
}

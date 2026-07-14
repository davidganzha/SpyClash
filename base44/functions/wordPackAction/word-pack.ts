import { validateSharedWordPackContent } from "./content-safety.ts";

export type WordPackRecord = Record<string, unknown>;

export function cleanWordPackValue(value: unknown): string {
  return String(value ?? "").trim();
}

export function normalizedOwnerEmail(value: unknown): string {
  return cleanWordPackValue(value).toLocaleLowerCase();
}

export function ownsWordPack(
  record: WordPackRecord | null | undefined,
  user: WordPackRecord,
): boolean {
  if (!record) return false;
  const ownerUserID = cleanWordPackValue(record.owner_user_id);
  const userID = cleanWordPackValue(user.id);
  if (ownerUserID) return Boolean(userID) && ownerUserID === userID;

  const ownerEmail = normalizedOwnerEmail(record.owner_email);
  const userEmail = normalizedOwnerEmail(user.email);
  return Boolean(ownerEmail) && ownerEmail === userEmail;
}

export function wordPackWritePayload(
  body: WordPackRecord,
  user: WordPackRecord,
) {
  const validated = validateSharedWordPackContent({
    name: body.name,
    category: body.category,
    words: Array.isArray(body.words) ? body.words : [],
  });
  const ownerUserID = cleanWordPackValue(user.id);
  const ownerEmail = cleanWordPackValue(user.email);
  if (!ownerUserID || !ownerEmail) {
    throw Object.assign(
      new Error("Authenticated owner identity is incomplete."),
      {
        status: 401,
        code: "incomplete_identity",
      },
    );
  }
  return {
    ...validated,
    owner_user_id: ownerUserID,
    owner_email: ownerEmail,
    is_public: false,
  };
}

export function wordPackForClient(record: WordPackRecord) {
  return {
    id: cleanWordPackValue(record.id),
    name: cleanWordPackValue(record.name),
    category: cleanWordPackValue(record.category),
    words: Array.isArray(record.words)
      ? record.words.map(cleanWordPackValue).filter(Boolean)
      : [],
    owner_email: cleanWordPackValue(record.owner_email),
    is_public: false,
    created_date: cleanWordPackValue(record.created_date),
    updated_date: cleanWordPackValue(record.updated_date),
  };
}

export function uniqueWordPacks(records: WordPackRecord[]) {
  const seen = new Set<string>();
  return records.filter((record) => {
    const id = cleanWordPackValue(record.id);
    if (!id || seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

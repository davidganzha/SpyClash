export type AiGenerationQuotaRecord = {
  id?: string;
  quota_key?: string;
  user_id?: string;
  usage_date?: string;
  generations_used?: number;
  last_generated_at?: string;
  created_date?: string;
};

export function utcUsageDate(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

export function quotaKey(userId: string, now = new Date()): string {
  return `${userId}:${utcUsageDate(now)}`;
}

export function normalizedQuotaCount(value: unknown): number {
  const count = Number(value);
  return Number.isFinite(count) && count > 0 ? Math.floor(count) : 0;
}

export function totalQuotaUsage(records: AiGenerationQuotaRecord[]): number {
  // Summing duplicate buckets is fail-closed. Base44 schemas do not currently
  // expose a unique-index declaration, so a first-write race must never make
  // excess records reset or reduce a user's authoritative usage.
  return records.reduce(
    (total, record) => total + normalizedQuotaCount(record.generations_used),
    0,
  );
}

export function canonicalQuotaRecord(
  records: AiGenerationQuotaRecord[],
): AiGenerationQuotaRecord | undefined {
  return [...records].sort((left, right) => {
    const dateOrder = String(left.created_date || "").localeCompare(
      String(right.created_date || ""),
    );
    if (dateOrder !== 0) return dateOrder;
    return String(left.id || "").localeCompare(String(right.id || ""));
  })[0];
}

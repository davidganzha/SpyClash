export type AiGenerationQuotaRecord = {
  generations_used?: number;
};

export function quotaKey(userId: string, now = new Date()): string {
  return `${userId}:${now.toISOString().slice(0, 10)}`;
}

export function totalQuotaUsage(records: AiGenerationQuotaRecord[]): number {
  return records.reduce((total, record) => {
    const count = Number(record.generations_used);
    return total +
      (Number.isFinite(count) && count > 0 ? Math.floor(count) : 0);
  }, 0);
}

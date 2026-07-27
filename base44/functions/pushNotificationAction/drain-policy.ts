export const PUSH_DRAIN_DEFAULT_BATCH = 64;
export const PUSH_DRAIN_MAX_BATCH = 96;
export const PUSH_DRAIN_CONCURRENCY = 12;

export function normalizePushDrainLimit(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return PUSH_DRAIN_DEFAULT_BATCH;
  return Math.min(PUSH_DRAIN_MAX_BATCH, Math.max(1, Math.floor(parsed)));
}

export function pushDrainQueryLimit(batch: number): number {
  return Math.min(200, Math.max(128, normalizePushDrainLimit(batch) * 2));
}

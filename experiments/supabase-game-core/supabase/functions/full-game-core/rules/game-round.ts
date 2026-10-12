export function nextRoundNumber(value: unknown): number {
  const current = Number(value);
  return (Number.isFinite(current) && current >= 1 ? Math.floor(current) : 1) +
    1;
}

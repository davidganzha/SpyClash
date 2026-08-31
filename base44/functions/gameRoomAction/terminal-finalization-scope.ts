type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

/**
 * New clients bind finalization to the immutable match generation they read.
 * Empty expectations remain accepted during the rolling client upgrade.
 */
export function assertExpectedTimerFinalizationScope(
  room: Entity,
  body: Entity,
): void {
  const expectedMatchID = clean(body?.expected_match_id);
  const expectedGameStartedAt = clean(body?.expected_game_started_at);
  if (!expectedMatchID && !expectedGameStartedAt) return;

  const actualMatchID = clean(room?.match_id);
  const actualGameStartedAt = clean(room?.game_started_at);
  const matches = expectedMatchID
    ? actualMatchID === expectedMatchID &&
      (!expectedGameStartedAt || actualGameStartedAt === expectedGameStartedAt)
    : !actualMatchID && actualGameStartedAt === expectedGameStartedAt;
  if (!matches) {
    throw Object.assign(
      new Error("The expired match was replaced before finalization."),
      { status: 409, code: "finalization_scope_changed", retryable: false },
    );
  }
}

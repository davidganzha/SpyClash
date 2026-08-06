function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function shouldSynchronizeLiveActivity(
  actionValue: unknown,
  room: Record<string, unknown> | null | undefined,
): boolean {
  const action = clean(actionValue);
  const status = clean(room?.status).toLowerCase();
  const matchID = clean(room?.match_id);

  if (!matchID) return false;

  // Foreground clients already render every room signal locally. Keep APNs
  // synchronization off the response path for rapid in-game transitions;
  // the push drain's idle-activity reconciliation repairs those snapshots.
  return (action === "complete_game_start" && status === "playing") ||
    status === "finished";
}

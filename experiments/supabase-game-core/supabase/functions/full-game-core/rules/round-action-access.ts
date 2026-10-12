type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function key(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

export function assertRoundActionMode(
  room: Entity,
  expectedMode: "questions" | "associations",
): void {
  if (key(room?.game_mode) === expectedMode) return;
  throw Object.assign(
    new Error(`The ${expectedMode} round is not active`),
    { status: 409, code: "round_mode_mismatch" },
  );
}

export function assertActiveRoundActor(
  activePlayers: Entity[],
  actorEmail: unknown,
): void {
  const actorKey = key(actorEmail);
  if (
    actorKey && activePlayers.some((player) => key(player?.email) === actorKey)
  ) return;
  throw Object.assign(
    new Error("Only an active operative can change the round"),
    { status: 403, code: "round_actor_inactive" },
  );
}

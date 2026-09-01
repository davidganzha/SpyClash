type Room = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function key(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

/**
 * A finished host is a participant, not an owner-delete command. If another
 * participant remains, the ordinary membership CAS removes the host and
 * transfers authority. Empty finished rooms and explicit lobby closes retain
 * the existing deletion behavior.
 */
export function hostDepartureUsesMembershipTransition(
  room: Room,
  leavingEmailValue: unknown,
): boolean {
  const leavingKey = key(leavingEmailValue);
  if (!leavingKey || key(room?.host_email) !== leavingKey) return true;

  const status = key(room?.status || "waiting");
  const preTimer = ["roulette", "playing"].includes(status) &&
    !clean(room?.game_started_at);
  const activeGame = status === "playing" &&
    Boolean(clean(room?.game_started_at));
  if (preTimer || activeGame) return true;

  if (status !== "finished") return false;
  const players = Array.isArray(room?.players) ? room.players : [];
  return players.some((player) => key(player?.email) !== leavingKey);
}

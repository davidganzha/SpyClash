/** Server-owned FAN surprise. Settings are public; the sampled scenario stays secret until ejection. */
export const FAN_MODE_CAPABILITY = "fan_mode_v2";
export const FAN_ALL_SPIES_TARGET = "__fan_all_spies__";
export const FAN_NO_SPIES_TARGET = "__fan_no_spies__";
export type FanScenario = "standard" | "all_spies" | "no_spies";
type Room = Record<string, any>;
export type FanSettings = {
  fan_mode_enabled: boolean;
  fan_all_spies_chance: number;
  fan_no_spies_chance: number;
};
const clean = (value: unknown): string =>
  String(value ?? "").trim().toLowerCase();
function failure(message: string, code: string, status = 409): never {
  throw Object.assign(new Error(message), { code, status });
}
export function fanSettings(value: Room): FanSettings {
  if (
    value.fan_mode_enabled !== undefined &&
    typeof value.fan_mode_enabled !== "boolean"
  ) {
    failure(
      "FAN mode must be enabled or disabled",
      "fan_settings_invalid",
      400,
    );
  }
  const all = value.fan_all_spies_chance ?? 15;
  const none = value.fan_no_spies_chance ?? 15;
  if (
    ![all, none].every((n) => Number.isInteger(n) && n >= 0 && n <= 99) ||
    all + none > 100
  ) {
    failure(
      "FAN chances must be 0–99 percent and total at most 100",
      "fan_settings_invalid",
      400,
    );
  }
  return {
    fan_mode_enabled: value.fan_mode_enabled === true,
    fan_all_spies_chance: all,
    fan_no_spies_chance: none,
  };
}
export function isFanMode(room: Room): boolean {
  return room.fan_mode_enabled === true;
}
export function fanScenario(room: Room): FanScenario | null {
  return isFanMode(room) &&
      ["standard", "all_spies", "no_spies"].includes(room.fan_scenario)
    ? room.fan_scenario
    : null;
}
export function isFanAnomaly(room: Room): boolean {
  const scenario = fanScenario(room);
  return scenario === "all_spies" || scenario === "no_spies";
}
export function assertFanCapablePlayer(room: Room, player: Room): void {
  if (
    isFanMode(room) &&
    (!Array.isArray(player?.client_capabilities) ||
      !player.client_capabilities.includes(FAN_MODE_CAPABILITY))
  ) {
    failure(
      "Every operative must update SpyClash to play FAN mode",
      "client_update_required",
      426,
    );
  }
}
export function assertFanCapableRoster(room: Room): void {
  for (const player of room.players || []) assertFanCapablePlayer(room, player);
}
export function sampleFanScenario(
  room: Room,
  randomIndex: (upper: number) => number,
): FanScenario {
  const settings = fanSettings(room);
  const roll = randomIndex(100);
  if (!Number.isInteger(roll) || roll < 0 || roll >= 100) {
    failure("Invalid FAN entropy", "invalid_server_random", 500);
  }
  return roll < settings.fan_all_spies_chance
    ? "all_spies"
    : roll < settings.fan_all_spies_chance + settings.fan_no_spies_chance
    ? "no_spies"
    : "standard";
}
export function fanAssignmentCount(
  room: Room,
  scenario: FanScenario,
  playerCount: number,
): number {
  return scenario === "all_spies"
    ? playerCount
    : scenario === "no_spies"
    ? 0
    : 1;
}
/** All FAN ballots use the same visible threshold, so the secret cannot leak from counts. */
export function fanVoteTransition(
  room: Room,
  voterValue: unknown,
  targetValue: unknown,
  event: Room,
): Room {
  const active = (room.players || []).map((p: Room) => clean(p.email))
    .filter((email: string) =>
      email && !(room.spectators || []).map(clean).includes(email)
    );
  const voter = clean(voterValue), target = clean(targetValue);
  if (!active.includes(voter)) {
    failure(
      "Only active operatives may vote",
      "detective_vote_actor_inactive",
      403,
    );
  }
  if (
    !active.includes(target) || voter === target
  ) failure("Invalid accusation", "detective_vote_target_invalid", 400);
  // Drop stale/legacy concept votes and duplicate voters when resuming a room.
  const seen = new Set<string>();
  const votes = (room.detective_votes || []).filter((vote: Room) => {
    const voter = clean(vote.voter_email), target = clean(vote.voted_for_email);
    if (!active.includes(voter) || !active.includes(target) || voter === target || seen.has(voter)) return false;
    seen.add(voter);
    return true;
  });
  const previous = votes.find((vote: Room) =>
    clean(vote.voter_email) === voter
  );
  if (previous && clean(previous.voted_for_email) !== target) {
    failure("A submitted vote cannot change", "detective_vote_already_cast");
  }
  if (!previous) votes.push({ voter_email: voter, voted_for_email: target });
  const tally = (candidate: string) =>
    votes.filter((vote: Room) => clean(vote.voted_for_email) === candidate)
      .length;
  const threshold = Math.max(1, active.length - 1);
  const closed = {
    detective_votes: votes,
    vote_requests: [],
    detective_vote_round_id: "",
  };
  const accused = active.find((email: string) => tally(email) >= threshold);
  if (accused) {
    const patch = {
      ...closed,
      spectators: [...new Set([...(room.spectators || []), accused])],
      eliminated_emails: [...new Set([...(room.eliminated_emails || []), accused])],
    };
    if (isFanAnomaly(room)) {
      return {
        patch,
        terminal_winner: "draw",
        terminal_patch: {
          detective_votes: votes,
          fan_result_reason: "player_ejected",
        },
        decision: { outcome: "eject", ejected_email: accused },
      };
    }
    const spy = clean(room.spy_email);
    const winner = accused === spy
      ? "detectives"
      : active.length - 1 <= 2
      ? "spy"
      : null;
    return {
      patch,
      terminal_winner: winner,
      terminal_patch: { detective_votes: votes },
      decision: { outcome: "eject", ejected_email: accused },
    };
  }
  const uncast = active.filter((email: string) =>
    !votes.some((vote: Room) => clean(vote.voter_email) === email)
  );
  if (uncast.length === 0) {
    return {
      patch: {
        detective_votes: [],
        vote_requests: [],
        detective_vote_round_id: "",
        detective_vote_cancellation_event_id: event.eventID,
        detective_vote_cancellation_round_id: event.roundID,
        detective_vote_cancellation_present_at: event.presentAt,
        detective_vote_cancellation_reason: "no_viable_candidate",
      },
      terminal_winner: null,
      decision: { outcome: "cancel" },
    };
  }
  return {
    patch: { detective_votes: votes },
    terminal_winner: null,
    decision: { outcome: "continue" },
  };
}

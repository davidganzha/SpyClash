export const MULTI_SPY_CAPABILITY = "multi_spy_v1";
export const MIN_GAME_PLAYERS = 3;
export const MAX_GAME_PLAYERS = 12;
export const MAX_SPY_COUNT = 3;

type Room = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizedEmail(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function uniqueEmails(values: readonly unknown[]): string[] {
  const result = new Map<string, string>();
  for (const value of values) {
    const email = clean(value);
    const key = normalizedEmail(email);
    if (key && !result.has(key)) result.set(key, email);
  }
  return [...result.values()];
}

function policyError(message: string, code: string, status = 409): Error {
  return Object.assign(new Error(message), { status, code });
}

export function canonicalClientCapabilities(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(
      value.map(clean).filter((capability) =>
        /^[a-z0-9][a-z0-9_.:-]{0,63}$/i.test(capability)
      ),
    ),
  ].slice(0, 32);
}

export function playerSupportsMultiSpy(player: unknown): boolean {
  if (!player || typeof player !== "object" || Array.isArray(player)) {
    return false;
  }
  return canonicalClientCapabilities(
    (player as Record<string, unknown>).client_capabilities,
  ).includes(MULTI_SPY_CAPABILITY);
}

export function roomClientRequiresMultiSpyUpdate(
  room: Room,
  actorEmailValue: unknown,
): boolean {
  const actorKey = normalizedEmail(actorEmailValue);
  if (!actorKey) return false;
  const tombstoned = uniqueEmails(
    Array.isArray(room?.incompatible_player_emails)
      ? room.incompatible_player_emails
      : [],
  ).some((email) => normalizedEmail(email) === actorKey);
  if (tombstoned) return true;
  if (lobbySpyCount(room) <= 1) return false;
  const participant = (Array.isArray(room?.players) ? room.players : [])
    .find((player) => normalizedEmail(player?.email) === actorKey);
  return Boolean(participant) && !playerSupportsMultiSpy(participant);
}

export function departedPlayerEmails(room: Room): string[] {
  return uniqueEmails(
    Array.isArray(room?.departed_player_emails)
      ? room.departed_player_emails
      : [],
  );
}

export function roomHasDepartedPlayer(
  room: Room,
  actorEmailValue: unknown,
): boolean {
  const actorKey = normalizedEmail(actorEmailValue);
  return Boolean(actorKey) &&
    departedPlayerEmails(room).some((email) =>
      normalizedEmail(email) === actorKey
    );
}

export function refreshedPlayerCapabilities(
  playersValue: unknown,
  actorEmailValue: unknown,
  capabilitiesValue: unknown,
): { players: Record<string, unknown>[]; changed: boolean } {
  const roomPlayers = Array.isArray(playersValue)
    ? playersValue.filter((player) =>
      player && typeof player === "object" && !Array.isArray(player)
    ) as Record<string, unknown>[]
    : [];
  const actorKey = normalizedEmail(actorEmailValue);
  const capabilities = canonicalClientCapabilities(capabilitiesValue);
  let changed = false;
  const players = roomPlayers.map((player) => {
    if (normalizedEmail(player.email) !== actorKey) return player;
    const existing = canonicalClientCapabilities(player.client_capabilities);
    if (JSON.stringify(existing) === JSON.stringify(capabilities)) {
      return player;
    }
    changed = true;
    return { ...player, client_capabilities: capabilities };
  });
  return { players, changed };
}

export function playerCapabilityRefreshNeeded(
  playersValue: unknown,
  actorEmailValue: unknown,
  capabilitiesValue: unknown,
): boolean {
  return refreshedPlayerCapabilities(
    playersValue,
    actorEmailValue,
    capabilitiesValue,
  ).changed;
}

export function maximumSpyCount(playerCountValue: unknown): number {
  const playerCount = Number(playerCountValue);
  if (!Number.isSafeInteger(playerCount) || playerCount < MIN_GAME_PLAYERS) {
    return 1;
  }
  return Math.max(
    1,
    Math.min(MAX_SPY_COUNT, Math.floor(playerCount / 3)),
  );
}

export function validatedLobbySpyCount(
  value: unknown,
  playerCountValue: unknown,
): number {
  const count = Number(value);
  const maximum = maximumSpyCount(playerCountValue);
  if (!Number.isSafeInteger(count) || count < 1 || count > maximum) {
    throw policyError(
      `Spy count must be between 1 and ${maximum} for this room`,
      "spy_count_invalid_for_player_count",
      400,
    );
  }
  return count;
}

export function lobbySpyCount(room: Room): number {
  const persisted = Number(room?.lobby_spy_count);
  if (
    Number.isSafeInteger(persisted) && persisted >= 1 &&
    persisted <= MAX_SPY_COUNT
  ) return persisted;
  const assigned = canonicalSpyEmails(room).length;
  return assigned > 0 ? assigned : 1;
}

export function clampedLobbySpyCount(
  value: unknown,
  playerCountValue: unknown,
): number {
  const count = Number(value);
  const canonical = Number.isSafeInteger(count)
    ? Math.max(1, Math.min(MAX_SPY_COUNT, count))
    : 1;
  return Math.min(canonical, maximumSpyCount(playerCountValue));
}

export function spiesKnowEachOther(room: Room): boolean {
  return room?.spies_know_each_other === true;
}

export function canonicalSpyEmails(room: Room): string[] {
  const playerEmailByKey = new Map<string, string>();
  for (const player of Array.isArray(room?.players) ? room.players : []) {
    const email = clean(player?.email);
    const key = normalizedEmail(email);
    if (key && !playerEmailByKey.has(key)) playerEmailByKey.set(key, email);
  }
  const raw = Array.isArray(room?.spy_emails) && room.spy_emails.length
    ? room.spy_emails
    : [room?.spy_email];
  return uniqueEmails(raw).slice(0, MAX_SPY_COUNT).map((email) =>
    playerEmailByKey.get(normalizedEmail(email)) || email
  );
}

export function activePlayerEmails(room: Room): string[] {
  const spectatorKeys = new Set(
    uniqueEmails(Array.isArray(room?.spectators) ? room.spectators : [])
      .map(normalizedEmail),
  );
  return uniqueEmails(
    (Array.isArray(room?.players) ? room.players : []).map((player) =>
      player?.email
    ),
  ).filter((email) => !spectatorKeys.has(normalizedEmail(email)));
}

export function activeSpyEmails(room: Room): string[] {
  const active = new Set(activePlayerEmails(room).map(normalizedEmail));
  return canonicalSpyEmails(room).filter((email) =>
    active.has(normalizedEmail(email))
  );
}

export function spyTeamCounts(room: Room): {
  activePlayers: number;
  activeSpies: number;
  activeDetectives: number;
} {
  const activePlayers = activePlayerEmails(room).length;
  const activeSpies = activeSpyEmails(room).length;
  return {
    activePlayers,
    activeSpies,
    activeDetectives: Math.max(0, activePlayers - activeSpies),
  };
}

export function spyTeamTerminalWinner(
  room: Room,
): "spy" | "detectives" | null {
  if (!canonicalSpyEmails(room).length) return null;
  const counts = spyTeamCounts(room);
  if (counts.activeSpies === 0) return "detectives";
  if (counts.activeSpies >= counts.activeDetectives) return "spy";
  return null;
}

export function assertActiveSpyGuesser(room: Room, emailValue: unknown): void {
  const emailKey = normalizedEmail(emailValue);
  const assigned = canonicalSpyEmails(room).some((email) =>
    normalizedEmail(email) === emailKey
  );
  if (!assigned) {
    throw policyError(
      "Only a spy can guess the word",
      "spy_access_required",
      403,
    );
  }
  if (
    !activeSpyEmails(room).some((email) => normalizedEmail(email) === emailKey)
  ) {
    throw policyError(
      "An eliminated spy cannot guess the word",
      "eliminated_spy_cannot_guess",
    );
  }
}

export function spyGuessWinner(
  secretWordValue: unknown,
  guessValue: unknown,
): "spy" | "detectives" {
  return clean(guessValue).localeCompare(clean(secretWordValue), undefined, {
      sensitivity: "accent",
    }) === 0
    ? "spy"
    : "detectives";
}

export function exclusionVoteThreshold(room: Room): number {
  const activeCount = activePlayerEmails(room).length;
  const status = clean(room?.status || "waiting").toLocaleLowerCase();
  const activeSpies = ["roulette", "playing", "finished"].includes(status)
    ? activeSpyEmails(room).length
    : Math.min(lobbySpyCount(room), activeCount);
  return activeCount > 0 ? Math.max(1, activeCount - activeSpies) : 0;
}

function secureRandomIndex(exclusiveUpperBound: number): number {
  if (!Number.isSafeInteger(exclusiveUpperBound) || exclusiveUpperBound <= 0) {
    throw new RangeError("Random upper bound must be a positive integer");
  }
  const range = 0x1_0000_0000;
  const limit = Math.floor(range / exclusiveUpperBound) * exclusiveUpperBound;
  const word = new Uint32Array(1);
  do crypto.getRandomValues(word); while (word[0] >= limit);
  return word[0] % exclusiveUpperBound;
}

export function sampleUniqueSpyEmails(
  emailValues: readonly unknown[],
  countValue: unknown,
  randomIndex: (exclusiveUpperBound: number) => number = secureRandomIndex,
): string[] {
  const emails = uniqueEmails(emailValues);
  const count = Number(countValue);
  if (!Number.isSafeInteger(count) || count < 1 || count > emails.length) {
    throw policyError(
      "Cannot assign the requested spy team",
      "spy_assignment_invalid",
      400,
    );
  }
  const shuffled = [...emails];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swapIndex = randomIndex(index + 1);
    if (
      !Number.isSafeInteger(swapIndex) || swapIndex < 0 || swapIndex > index
    ) {
      throw new RangeError("Random index is outside the requested range");
    }
    [shuffled[index], shuffled[swapIndex]] = [
      shuffled[swapIndex],
      shuffled[index],
    ];
  }
  return shuffled.slice(0, count);
}

/**
 * Returns the frozen role assignment for an atomic start write. If that write
 * committed and its response was lost, a retry observes the existing list and
 * never rerolls identities.
 */
export function serverSpyAssignment(
  room: Room,
  randomIndex?: (exclusiveUpperBound: number) => number,
): { spy_emails: string[]; spy_email: string } {
  const participantEmails = uniqueEmails(
    (Array.isArray(room?.players) ? room.players : []).map((player) =>
      player?.email
    ),
  );
  const participantKeys = new Set(participantEmails.map(normalizedEmail));
  const count = validatedLobbySpyCount(
    lobbySpyCount(room),
    participantEmails.length,
  );
  const hasFrozenAssignment =
    (Array.isArray(room?.spy_emails) && room.spy_emails.length > 0) ||
    Boolean(clean(room?.spy_email));
  const existing = canonicalSpyEmails(room);
  if (hasFrozenAssignment) {
    const primaryKey = normalizedEmail(room?.spy_email);
    const assignmentIsValid = existing.length === count &&
      existing.every((email) => participantKeys.has(normalizedEmail(email))) &&
      primaryKey === normalizedEmail(existing[0]);
    if (!assignmentIsValid) {
      throw policyError(
        "The frozen spy assignment is incomplete or invalid",
        "spy_assignment_invalid",
      );
    }
    return { spy_emails: existing, spy_email: existing[0] };
  }
  const assigned = sampleUniqueSpyEmails(
    participantEmails,
    count,
    randomIndex,
  );
  return { spy_emails: assigned, spy_email: assigned[0] };
}

export function assertMultiSpyCapableRoster(room: Room): void {
  if (lobbySpyCount(room) <= 1) return;
  const incompatible = (Array.isArray(room?.players) ? room.players : [])
    .filter((player) => !playerSupportsMultiSpy(player));
  if (incompatible.length) {
    throw policyError(
      "Every remaining operative must update SpyClash before this mission can start",
      "client_update_required",
      426,
    );
  }
}

export function compatibleRosterForSpyCount(
  room: Room,
  requestedCountValue: unknown,
): {
  players: Record<string, unknown>[];
  removedEmails: string[];
  effectiveSpyCount: number;
} {
  const roomPlayers = Array.isArray(room?.players) ? room.players : [];
  // Tombstones preserve the roster boundary of an already-committed host
  // mutation. An exact response-loss retry can therefore re-derive the same
  // effective count after incompatible players have already been removed.
  const activeKeys = new Set(
    roomPlayers.map((player) => normalizedEmail(player?.email)),
  );
  const removedByPriorMutation = uniqueEmails(
    Array.isArray(room?.incompatible_player_emails)
      ? room.incompatible_player_emails
      : [],
  ).filter((email) => !activeKeys.has(normalizedEmail(email)));
  const requestedCount = validatedLobbySpyCount(
    requestedCountValue,
    roomPlayers.length + removedByPriorMutation.length,
  );
  if (requestedCount === 1) {
    return {
      players: roomPlayers,
      removedEmails: [],
      effectiveSpyCount: 1,
    };
  }

  const hostKey = normalizedEmail(room?.host_email);
  const host = roomPlayers.find((player) =>
    normalizedEmail(player?.email) === hostKey
  );
  if (!host || !playerSupportsMultiSpy(host)) {
    throw policyError(
      "Update SpyClash before selecting multiple spies",
      "client_update_required",
      426,
    );
  }
  const compatible = roomPlayers.filter(playerSupportsMultiSpy);
  const removedEmails = roomPlayers.filter((player) =>
    !playerSupportsMultiSpy(player)
  ).map((player) => clean(player?.email)).filter(Boolean);
  return {
    players: compatible,
    removedEmails,
    effectiveSpyCount: clampedLobbySpyCount(
      requestedCount,
      compatible.length,
    ),
  };
}

export function lobbyMembershipClampPatch(
  room: Room,
  remainingPlayerCountValue: unknown,
): Room {
  const nextCount = clampedLobbySpyCount(
    lobbySpyCount(room),
    remainingPlayerCountValue,
  );
  const patch: Room = {};
  if (clean(room?.status).toLocaleLowerCase() === "ready_voting") {
    patch.status = "waiting";
    patch.ready_players = [];
  }
  if (nextCount !== lobbySpyCount(room)) {
    patch.lobby_spy_count = nextCount;
    patch.lobby_schema_version = 2;
    patch.lobby_revision = Math.max(
      0,
      Math.floor(Number(room?.lobby_revision) || 0),
    ) + 1;
    patch.lobby_last_mutation_id = "";
    patch.lobby_last_mutation_fingerprint = "";
  }
  return patch;
}

export function activeDepartureTransition(
  room: Room,
  leavingEmailValue: unknown,
): {
  patch: Room;
  terminalWinner: "spy" | "detectives" | null;
} {
  const leavingKey = normalizedEmail(leavingEmailValue);
  const rosterEmail = uniqueEmails(
    (Array.isArray(room?.players) ? room.players : []).map((player) =>
      player?.email
    ),
  ).find((email) => normalizedEmail(email) === leavingKey);
  const active = activePlayerEmails(room);
  if (!leavingKey || !rosterEmail) {
    return { patch: {}, terminalWinner: spyTeamTerminalWinner(room) };
  }
  if (!active.some((email) => normalizedEmail(email) === leavingKey)) {
    if (roomHasDepartedPlayer(room, rosterEmail)) {
      return { patch: {}, terminalWinner: spyTeamTerminalWinner(room) };
    }
    // An expelled player remains a match spectator for history and reveal.
    // Their later explicit leave still needs a durable tombstone so restore and
    // active-room lookup cannot resurrect the mission on another device.
    return {
      patch: {
        departed_player_emails: uniqueEmails([
          ...departedPlayerEmails(room),
          rosterEmail,
        ]).slice(-MAX_GAME_PLAYERS),
      },
      terminalWinner: spyTeamTerminalWinner(room),
    };
  }
  const leavingEmail = active.find((email) =>
    normalizedEmail(email) === leavingKey
  )!;
  const spectators = uniqueEmails([
    ...(Array.isArray(room?.spectators) ? room.spectators : []),
    leavingEmail,
  ]);
  const eliminated = uniqueEmails([
    ...(Array.isArray(room?.eliminated_emails) ? room.eliminated_emails : []),
    leavingEmail,
  ]);
  const departed = uniqueEmails([
    ...departedPlayerEmails(room),
    leavingEmail,
  ]).slice(-MAX_GAME_PLAYERS);
  const remainingActive = active.filter((email) =>
    normalizedEmail(email) !== leavingKey
  );
  const nextHost = normalizedEmail(room?.host_email) === leavingKey
    ? remainingActive[0] || ""
    : clean(room?.host_email);
  const remainingByKey = new Map(
    remainingActive.map((email) => [normalizedEmail(email), email]),
  );
  const currentAsker = remainingByKey.get(
    normalizedEmail(room?.current_asker_email),
  ) || "";
  const currentAnswerer = remainingByKey.get(
    normalizedEmail(room?.current_answerer_email),
  ) || "";
  const nextAsker = currentAsker || currentAnswerer || remainingActive[0] || "";
  const nextAnswerer = currentAnswerer &&
      normalizedEmail(currentAnswerer) !== normalizedEmail(nextAsker)
    ? currentAnswerer
    : remainingActive.find((email) =>
      normalizedEmail(email) !== normalizedEmail(nextAsker)
    ) || "";
  const questionVectorChanged =
    normalizedEmail(nextAsker) !== normalizedEmail(room?.current_asker_email) ||
    normalizedEmail(nextAnswerer) !==
      normalizedEmail(room?.current_answerer_email);
  const rouletteTarget = remainingByKey.get(
    normalizedEmail(room?.roulette_target_email),
  ) || remainingActive[0] || "";
  const rouletteTargetChanged = normalizedEmail(rouletteTarget) !==
    normalizedEmail(room?.roulette_target_email);
  const patch: Room = {
    spectators,
    eliminated_emails: eliminated,
    departed_player_emails: departed,
    ready_players:
      (Array.isArray(room?.ready_players) ? room.ready_players : []).filter((
        email: unknown,
      ) => normalizedEmail(email) !== leavingKey),
    ...(nextHost !== clean(room?.host_email) ? { host_email: nextHost } : {}),
    ...(rouletteTargetChanged ? { roulette_target_email: rouletteTarget } : {}),
    ...(questionVectorChanged
      ? {
        current_asker_email: nextAsker,
        current_answerer_email: nextAnswerer,
        question_phase: "asking",
        current_answer: clean(room?.game_mode) === "associations"
          ? JSON.stringify({ spoken: [], spinning: true })
          : "",
        current_answer_feedback: null,
        countdown_started_at: null,
      }
      : {}),
  };
  return {
    patch,
    terminalWinner: spyTeamTerminalWinner({ ...room, ...patch }),
  };
}

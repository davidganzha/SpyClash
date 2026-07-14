const POST_GAME_GUESS_SECONDS = 30;

type Room = Record<string, any>;

export type RankedMatchIdentity = {
  id: string;
  legacy: boolean;
};

export type TerminalIntent = {
  match_id: string;
  winner: "spy" | "detectives";
  decided_at: string;
  spy_guess?: string;
  detective_votes?: unknown[];
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function status(room: Room): string {
  return clean(room?.status || "waiting").toLocaleLowerCase();
}

function invalidTerminal(message: string, statusCode = 409): Error {
  return Object.assign(new Error(message), {
    status: statusCode,
    code: "invalid_ranked_terminal",
  });
}

function normalizedWinner(value: unknown): "spy" | "detectives" {
  const winner = clean(value).toLocaleLowerCase();
  if (winner !== "spy" && winner !== "detectives") {
    throw invalidTerminal("The ranked winner is invalid.", 400);
  }
  return winner;
}

function rankedParticipants(room: Room) {
  const raw = Array.isArray(room?.players) ? room.players : [];
  return raw.map((player) => ({
    userID: clean(player?.user_id),
    email: clean(player?.email).toLocaleLowerCase(),
  }));
}

function assertStartedRankedRoom(room: Room): {
  startedAt: number;
  durationSeconds: number;
} {
  if (status(room) !== "playing") {
    throw invalidTerminal("Only a playing room can reach a ranked terminal.");
  }

  const participants = rankedParticipants(room);
  const userIDs = new Set(participants.map((player) => player.userID));
  const emails = new Set(participants.map((player) => player.email));
  if (
    participants.length < 3 ||
    participants.some((player) => !player.userID || !player.email) ||
    userIDs.size !== participants.length ||
    emails.size !== participants.length
  ) {
    throw invalidTerminal(
      "A ranked game requires at least three distinct authenticated participants.",
    );
  }

  const mirroredIDs = new Set(
    (Array.isArray(room?.participant_user_ids) ? room.participant_user_ids : [])
      .map(clean).filter(Boolean),
  );
  if (
    mirroredIDs.size !== userIDs.size ||
    [...userIDs].some((userID) => !mirroredIDs.has(userID))
  ) {
    throw invalidTerminal("Ranked participant identity is inconsistent.");
  }

  const spyEmail = clean(room?.spy_email).toLocaleLowerCase();
  if (!spyEmail || !emails.has(spyEmail)) {
    throw invalidTerminal("The ranked room has no authenticated spy.");
  }
  if (!clean(room?.word || room?.secret_word)) {
    throw invalidTerminal("The ranked room has no server-approved word.");
  }

  const startedAt = Date.parse(clean(room?.game_started_at));
  const durationSeconds = Number(room?.game_duration_seconds);
  if (
    !Number.isFinite(startedAt) ||
    !Number.isInteger(durationSeconds) ||
    durationSeconds < 60 ||
    durationSeconds > 900
  ) {
    throw invalidTerminal("The ranked room has no valid server start time.");
  }
  return { startedAt, durationSeconds };
}

export function assertServerRankedFinishSource(room: Room): void {
  assertStartedRankedRoom(room);
}

export function assertRankedTerminalRoom(
  room: Room,
  winnerValue: unknown,
): void {
  const winner = normalizedWinner(winnerValue);
  if (status(room) !== "finished") {
    throw invalidTerminal("Only a finished room can be archived.");
  }
  assertStartedRankedRoom({ ...room, status: "playing" });
}

/**
 * New matches always carry a random UUID created by the server. The fallback
 * exists only so an already-playing room created by the pre-migration backend
 * can still finish after deployment without sharing history with another
 * legacy room.
 */
export function rankedMatchIdentity(room: Room): RankedMatchIdentity {
  const explicit = clean(room?.match_id);
  if (explicit) return { id: explicit, legacy: false };

  const roomID = clean(room?.id);
  const startedAt = clean(room?.game_started_at);
  if (!roomID || !startedAt || !Number.isFinite(Date.parse(startedAt))) {
    throw invalidTerminal("The ranked match has no stable identity.");
  }
  return { id: `legacy:${roomID}:${startedAt}`, legacy: true };
}

export function historyRecordsForMatch(
  records: readonly Room[],
  room: Room,
): Room[] {
  const identity = rankedMatchIdentity(room);
  return records.filter((record) => clean(record?.match_id) === identity.id);
}

export function buildTerminalIntent(
  room: Room,
  winnerValue: unknown,
  terminalPatch: Room = {},
  decidedAt = new Date().toISOString(),
): TerminalIntent {
  const winner = normalizedWinner(winnerValue);
  const timestamp = clean(decidedAt);
  if (!timestamp || !Number.isFinite(Date.parse(timestamp))) {
    throw invalidTerminal("The terminal decision timestamp is invalid.", 400);
  }

  const intent: TerminalIntent = {
    match_id: rankedMatchIdentity(room).id,
    winner,
    decided_at: timestamp,
  };
  if (Object.prototype.hasOwnProperty.call(terminalPatch, "spy_guess")) {
    intent.spy_guess = clean(terminalPatch.spy_guess);
  }
  if (Object.prototype.hasOwnProperty.call(terminalPatch, "detective_votes")) {
    intent.detective_votes = Array.isArray(terminalPatch.detective_votes)
      ? structuredClone(terminalPatch.detective_votes)
      : [];
  }
  return intent;
}

export function terminalIntentFromRoom(room: Room): TerminalIntent | null {
  const value = room?.terminal_intent;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const winner = normalizedWinner(value.winner);
  const matchID = clean(value.match_id);
  const decidedAt = clean(value.decided_at);
  if (
    !matchID || !decidedAt || !Number.isFinite(Date.parse(decidedAt)) ||
    matchID !== rankedMatchIdentity(room).id
  ) {
    throw invalidTerminal("The persisted terminal intent is inconsistent.");
  }
  const intent: TerminalIntent = {
    match_id: matchID,
    winner,
    decided_at: decidedAt,
  };
  if (Object.prototype.hasOwnProperty.call(value, "spy_guess")) {
    intent.spy_guess = clean(value.spy_guess);
  }
  if (Object.prototype.hasOwnProperty.call(value, "detective_votes")) {
    intent.detective_votes = Array.isArray(value.detective_votes)
      ? structuredClone(value.detective_votes)
      : [];
  }
  return intent;
}

export function terminalPatchFromIntent(intent: TerminalIntent): Room {
  const patch: Room = {};
  if (Object.prototype.hasOwnProperty.call(intent, "spy_guess")) {
    patch.spy_guess = intent.spy_guess ?? "";
  }
  if (Object.prototype.hasOwnProperty.call(intent, "detective_votes")) {
    patch.detective_votes = structuredClone(intent.detective_votes ?? []);
  }
  return patch;
}

/**
 * Produces the single mutation for a role-card acknowledgement. Once the
 * caller is present in cards_read the transition is a no-op, so the timer can
 * only be set by the one transition that completes the set.
 */
export function roleCardReadTransitionPatch(
  room: Room,
  userEmailValue: unknown,
  startedAt = new Date().toISOString(),
): Room {
  if (status(room) !== "playing") {
    throw Object.assign(new Error("Role cards are not active."), {
      status: 409,
      code: "role_cards_inactive",
    });
  }

  const userEmail = clean(userEmailValue).toLocaleLowerCase();
  const participantEmails = rankedParticipants(room).map((player) =>
    player.email
  );
  if (!userEmail || !participantEmails.includes(userEmail)) {
    throw Object.assign(new Error("Not a player in this room"), {
      status: 403,
    });
  }

  const existing = (Array.isArray(room?.cards_read) ? room.cards_read : [])
    .map((value) => clean(value).toLocaleLowerCase()).filter(Boolean);
  if (existing.includes(userEmail)) return {};

  const next = [...new Set([...existing, userEmail])];
  const patch: Room = { cards_read: next };
  if (
    participantEmails.length > 0 &&
    participantEmails.every((email) => next.includes(email))
  ) {
    const timestamp = clean(startedAt);
    if (!timestamp || !Number.isFinite(Date.parse(timestamp))) {
      throw Object.assign(new Error("The game start timestamp is invalid."), {
        status: 400,
      });
    }
    patch.ready_players = [];
    patch.game_started_at = timestamp;
    patch.game_duration_seconds = Number(room?.game_duration_seconds || 900);
  }
  return patch;
}

/**
 * Legacy clients still send `finish_room` after the synchronized game timer.
 * The server ignores their claimed winner and derives the only permitted
 * timeout result from server-owned room timestamps.
 */
export function deriveExpiredGameWinner(
  room: Room,
  nowMilliseconds = Date.now(),
): "detectives" {
  const { startedAt, durationSeconds } = assertStartedRankedRoom(room);
  const deadline = startedAt +
    (durationSeconds + POST_GAME_GUESS_SECONDS) * 1_000;
  if (!Number.isFinite(nowMilliseconds) || nowMilliseconds < deadline) {
    throw invalidTerminal("The server game deadline has not elapsed.");
  }
  return "detectives";
}

export function rejectRetiredResultRecording(): never {
  throw Object.assign(
    new Error(
      "Client-triggered result recording is retired; terminal results are archived by the server.",
    ),
    { status: 410, code: "result_recording_retired" },
  );
}

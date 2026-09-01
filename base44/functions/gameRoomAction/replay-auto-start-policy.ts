import { requireSafeCommunityText } from "./content-safety.ts";
import {
  hasAuthoritativeLobbyState,
  lobbyStateFromRoom,
  selectedAuthoritativeLobbyWordPool,
} from "./lobby-state-policy.ts";
import {
  assertMultiSpyCapableRoster,
  lobbyMembershipClampPatch,
  serverSpyAssignment,
} from "./multi-spy-policy.ts";
import {
  replayResetMembershipPatch,
  replayVoteState,
} from "./replay-policy.ts";
import { serverIntroStartPatch } from "./room-result-policy.ts";
import {
  encodeQuestionTurnOrderState,
  questionTurnOrderState,
} from "./question-turn-order.ts";

type Room = Record<string, any>;

export type ReplayAutoStartOptions = {
  expectedSourceMatchID?: unknown;
  randomIndex?: (exclusiveUpperBound: number) => number;
  startedAt?: string;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizedStatus(room: Room): string {
  return clean(room?.status || "waiting").toLocaleLowerCase();
}

function policyError(message: string, status: number, code: string): Error {
  return Object.assign(new Error(message), { status, code });
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

function shuffled<T>(
  values: readonly T[],
  randomIndex: (exclusiveUpperBound: number) => number,
): T[] {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const swapIndex = randomIndex(index + 1);
    if (
      !Number.isSafeInteger(swapIndex) || swapIndex < 0 || swapIndex > index
    ) {
      throw new RangeError("Random index is outside the requested range");
    }
    [result[index], result[swapIndex]] = [
      result[swapIndex],
      result[index],
    ];
  }
  return result;
}

export function replaySourceMatchID(room: Room): string {
  return clean(room?.match_id) || clean(room?.terminal_intent?.match_id);
}

export function replayAutoStartAlreadyComplete(
  room: Room,
  expectedSourceMatchIDValue: unknown,
): boolean {
  const expectedSourceMatchID = clean(expectedSourceMatchIDValue);
  return Boolean(expectedSourceMatchID) &&
    ["roulette", "playing"].includes(normalizedStatus(room)) &&
    clean(room?.replay_source_match_id) === expectedSourceMatchID;
}

export function assertExpectedReplaySourceMatch(
  room: Room,
  expectedSourceMatchIDValue: unknown,
): string {
  const currentSourceMatchID = replaySourceMatchID(room);
  const expectedSourceMatchID = clean(expectedSourceMatchIDValue) ||
    currentSourceMatchID;
  if (!currentSourceMatchID) {
    throw policyError(
      "The finished match identity is missing.",
      409,
      "replay_source_missing",
    );
  }
  if (expectedSourceMatchID !== currentSourceMatchID) {
    throw policyError(
      "This replay vote belongs to an older match.",
      409,
      "replay_source_changed",
    );
  }
  return currentSourceMatchID;
}

function canonicalReplayPool(
  room: Room,
): Array<{ word: string; enabled: true }> {
  const rawPool = hasAuthoritativeLobbyState(room)
    ? selectedAuthoritativeLobbyWordPool(room)
    : (Array.isArray(room?.word_pool) ? room.word_pool : [])
      .filter((entry) => entry?.enabled !== false);
  const seen = new Set<string>();
  const pool: Array<{ word: string; enabled: true }> = [];
  for (const entry of rawPool) {
    const word = requireSafeCommunityText(clean(entry?.word), "Word pack item");
    const key = word.normalize("NFKC").toLocaleLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    pool.push({ word, enabled: true });
  }
  if (pool.length < 2) {
    throw policyError(
      "The saved replay word source is unavailable.",
      409,
      "replay_word_pool_unavailable",
    );
  }
  return pool;
}

/**
 * Builds the single CAS patch committed by the final replay vote. The patch
 * removes departed players, preserves the canonical lobby settings, freezes a
 * new role/word/question plan, and enters roulette without a host request.
 */
export function replayAutoStartPatch(
  room: Room,
  options: ReplayAutoStartOptions = {},
): Room {
  if (normalizedStatus(room) !== "finished") {
    throw policyError(
      "Replay auto-start requires a finished room.",
      409,
      "replay_vote_inactive",
    );
  }
  if (!replayVoteState(room).unanimous) {
    throw policyError(
      "Every remaining operative must vote before replay.",
      409,
      "replay_votes_incomplete",
    );
  }

  const sourceMatchID = assertExpectedReplaySourceMatch(
    room,
    options.expectedSourceMatchID,
  );
  const membership = replayResetMembershipPatch(room);
  const replayPlayers = membership.players as Room[];
  if (replayPlayers.length < 3) {
    throw policyError(
      "Need at least 3 operatives for a replay.",
      409,
      "replay_not_enough_players",
    );
  }
  const membershipClamp = lobbyMembershipClampPatch(
    room,
    replayPlayers.length,
  );
  const replayRoom: Room = {
    ...room,
    ...membership,
    ...membershipClamp,
    // A replay preserves settings, never the previous match's identities.
    spy_email: "",
    spy_emails: [],
  };
  assertMultiSpyCapableRoster(replayRoom);

  const randomIndex = options.randomIndex ?? secureRandomIndex;
  const order = shuffled(replayPlayers, randomIndex);
  const askerEmail = clean(order[0]?.email);
  const answererEmail = clean(order[1]?.email);
  const pool = canonicalReplayPool(replayRoom);
  const secretWord = pool[randomIndex(pool.length)].word;
  const assignment = serverSpyAssignment(replayRoom, randomIndex);
  const lobbyState = hasAuthoritativeLobbyState(replayRoom)
    ? lobbyStateFromRoom(replayRoom)
    : null;
  const gameMode = clean(lobbyState?.game_mode || replayRoom.game_mode);
  const durationSeconds = Number(
    lobbyState?.game_duration_seconds || replayRoom.game_duration_seconds,
  );
  if (!["questions", "associations"].includes(gameMode)) {
    throw policyError(
      "Invalid replay game mode.",
      409,
      "replay_settings_invalid",
    );
  }
  if (
    !Number.isInteger(durationSeconds) || durationSeconds < 60 ||
    durationSeconds > 900
  ) {
    throw policyError(
      "Invalid replay game duration.",
      409,
      "replay_settings_invalid",
    );
  }
  const category = requireSafeCommunityText(
    clean(
      lobbyState?.lobby_category || lobbyState?.lobby_source_name ||
        replayRoom.category || "CLASSIC",
    ),
    "Word pack category",
  );

  return {
    ...membership,
    ...membershipClamp,
    status: "roulette",
    replay_source_match_id: sourceMatchID,
    spy_email: assignment.spy_email,
    spy_emails: assignment.spy_emails,
    secret_word: secretWord,
    word: secretWord,
    category,
    spy_guess: "",
    detective_votes: [],
    detective_vote_round_id: "",
    detective_vote_cancellation_event_id: "",
    detective_vote_cancellation_round_id: "",
    detective_vote_cancellation_present_at: "",
    detective_vote_cancellation_reason: "",
    winner: "",
    cards_read: [],
    vote_requests: [],
    spectators: [],
    eliminated_emails: [],
    ready_players: [],
    question_phase: "asking",
    questions_in_round: 0,
    round_number: 1,
    current_answer: gameMode === "questions"
      ? encodeQuestionTurnOrderState(
        questionTurnOrderState(order.map((player) => player?.email)),
      )
      : "",
    current_answer_feedback: null,
    current_asker_email: askerEmail,
    current_answerer_email: answererEmail,
    roulette_target_email: askerEmail,
    player_feedback: replayPlayers.map((player) => ({
      email: clean(player.email),
      likes: 0,
      dislikes: 0,
    })),
    word_pool: pool,
    game_mode: gameMode,
    game_duration_seconds: durationSeconds,
    match_id: "",
    terminal_intent: null,
    ...serverIntroStartPatch(options.startedAt),
    game_started_at: null,
    game_paused_at: null,
    game_paused_total_seconds: 0,
    game_started_event_id: "",
    game_finished_event_id: "",
    countdown_started_at: null,
  };
}

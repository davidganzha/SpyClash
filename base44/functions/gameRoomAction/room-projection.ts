import {
  classifyObjectionableMaterial,
  safeCommunityAvatar,
  safeCommunityDisplayName,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";
import {
  canonicalizeLobbyState,
  LOBBY_SCHEMA_VERSION,
  lobbyRevision,
  type LobbyWordPoolEntry,
} from "./lobby-state-policy.ts";
import { terminalIntentFromRoom } from "./room-result-policy.ts";
import { replayEligiblePlayerEmails } from "./replay-policy.ts";
import { activeGameLobbyEligiblePlayerEmails } from "./active-game-lobby-return-policy.ts";
import { isDetectiveVotingActive } from "./detective-vote-policy.ts";
import {
  canonicalClientCapabilities,
  canonicalSpyEmails,
  exclusionVoteThreshold,
  lobbySpyCount,
  spiesKnowEachOther,
} from "./multi-spy-policy.ts";

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizedEmail(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function safeEmailList(value: unknown): string[] {
  return Array.isArray(value)
    ? [...new Set(value.map(clean).filter(Boolean))]
    : [];
}

function safeObjectList(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.filter((item) => item && typeof item === "object")
    : [];
}

function terminalReconciliationPending(room: Record<string, any>): boolean {
  if (clean(room?.status || "waiting").toLocaleLowerCase() === "finished") {
    return false;
  }
  try {
    return Boolean(terminalIntentFromRoom(room));
  } catch {
    return false;
  }
}

type ProjectedLobbyState = {
  lobby_schema_version: number;
  lobby_revision: number;
  lobby_spy_count: number;
  spies_know_each_other: boolean;
  lobby_word_source: string;
  lobby_source_pack_id: string;
  lobby_source_name: string;
  lobby_theme: string;
  lobby_category: string;
  lobby_word_count: number;
  lobby_word_count_mode: string;
  lobby_word_pool: LobbyWordPoolEntry[];
};

function projectedLobbyState(
  room: Record<string, any>,
  viewer: Record<string, any>,
): ProjectedLobbyState {
  const status = clean(room?.status || "waiting").toLowerCase();
  const lobbyVisible = status === "waiting" || status === "ready_voting";
  const viewerIsHost = Boolean(normalizedEmail(viewer?.email)) &&
    normalizedEmail(viewer?.email) === normalizedEmail(room?.host_email);
  const common = {
    lobby_schema_version: Math.max(
      LOBBY_SCHEMA_VERSION,
      Math.floor(Number(room?.lobby_schema_version) || 0),
    ),
    lobby_revision: lobbyRevision(room),
    lobby_spy_count: lobbySpyCount(room),
    spies_know_each_other: spiesKnowEachOther(room),
  };
  if (!lobbyVisible) {
    return {
      ...common,
      lobby_word_source: "none",
      lobby_source_pack_id: "",
      lobby_source_name: "",
      lobby_theme: "",
      lobby_category: "",
      lobby_word_count: 0,
      lobby_word_count_mode: "recommended",
      lobby_word_pool: [],
    };
  }

  try {
    const state = canonicalizeLobbyState({
      game_mode: room?.game_mode || "questions",
      game_duration_seconds: room?.game_duration_seconds || 900,
      lobby_spy_count: room?.lobby_spy_count ?? 1,
      spies_know_each_other: room?.spies_know_each_other ?? false,
      lobby_word_source: room?.lobby_word_source || "none",
      lobby_source_pack_id: room?.lobby_source_pack_id || "",
      lobby_source_name: room?.lobby_source_name || "",
      lobby_theme: room?.lobby_theme || "",
      lobby_category: room?.lobby_category || "",
      lobby_word_count: room?.lobby_word_count ?? 0,
      lobby_word_count_mode: room?.lobby_word_count_mode || "recommended",
      lobby_word_pool: Array.isArray(room?.lobby_word_pool)
        ? room.lobby_word_pool
        : [],
    });
    return {
      ...common,
      lobby_word_source: state.lobby_word_source,
      lobby_source_pack_id: viewerIsHost ? state.lobby_source_pack_id : "",
      lobby_source_name: state.lobby_source_name,
      lobby_theme: state.lobby_theme,
      lobby_category: state.lobby_category,
      lobby_word_count: state.lobby_word_count,
      lobby_word_count_mode: state.lobby_word_count_mode,
      lobby_word_pool: state.lobby_word_pool,
    };
  } catch {
    // A malformed legacy row must fail closed instead of leaking unmediated
    // text. Mode/duration and polling still work while the host resubmits it.
    return {
      ...common,
      lobby_word_source: "none",
      lobby_source_pack_id: "",
      lobby_source_name: "",
      lobby_theme: "",
      lobby_category: "",
      lobby_word_count: 0,
      lobby_word_count_mode: "recommended",
      lobby_word_pool: [],
    };
  }
}

export function shouldRedactRoomSecret(
  room: Record<string, any>,
  viewer: Record<string, any>,
): boolean {
  const viewerKey = normalizedEmail(viewer?.email);
  const spyKeys = new Set(canonicalSpyEmails(room).map(normalizedEmail));
  return Boolean(viewerKey) && spyKeys.has(viewerKey) &&
    clean(room?.status || "waiting").toLowerCase() !== "finished";
}

function maySeeSpyIdentity(
  room: Record<string, any>,
  viewer: Record<string, any>,
): boolean {
  if (clean(room?.status || "waiting").toLowerCase() === "finished") {
    return true;
  }
  const viewerKey = normalizedEmail(viewer?.email);
  return Boolean(viewerKey) &&
    canonicalSpyEmails(room).some((email) =>
      normalizedEmail(email) === viewerKey
    );
}

function projectedSpyEmails(
  room: Record<string, any>,
  viewer: Record<string, any>,
): string[] {
  const spies = canonicalSpyEmails(room);
  if (clean(room?.status || "waiting").toLowerCase() === "finished") {
    return spies;
  }
  const viewerKey = normalizedEmail(viewer?.email);
  const viewerSpy = spies.find((email) => normalizedEmail(email) === viewerKey);
  if (!viewerSpy) return [];
  return spiesKnowEachOther(room) ? spies : [viewerSpy];
}

export function projectRoomForClient(
  room: Record<string, any> | null | undefined,
  viewer: Record<string, any>,
) {
  if (!room) return room;
  const redacted = shouldRedactRoomSecret(room, viewer);
  const revealSpyIdentity = maySeeSpyIdentity(room, viewer);
  const visibleSpyEmails = projectedSpyEmails(room, viewer);
  const viewerSpyEmail =
    canonicalSpyEmails(room).find((email) =>
      normalizedEmail(email) === normalizedEmail(viewer?.email)
    ) || "";
  const legacySpyEmail = clean(room?.status || "waiting").toLowerCase() ===
      "finished"
    ? canonicalSpyEmails(room)[0] || clean(room.spy_email)
    : viewerSpyEmail;
  const safeWord = safeCommunityTextForDisplay(
    room.word || room.secret_word,
    "CLASSIFIED",
  );
  const isAssociationState = clean(room.game_mode) === "associations";
  const wordPool = safeObjectList(room.word_pool)
    .filter((entry) => !classifyObjectionableMaterial(entry.word))
    .map((entry) => ({
      word: clean(entry.word),
      enabled: entry.enabled !== false,
    }))
    .filter((entry) => entry.word);
  const lobbyState = projectedLobbyState(room, viewer);
  const projectedSpectators = safeEmailList(room.spectators);
  const spectatorKeys = new Set(projectedSpectators.map(normalizedEmail));
  const activeEmails = safeObjectList(room.players)
    .map((player) => clean(player.email))
    .filter((email) => email && !spectatorKeys.has(normalizedEmail(email)));
  const persistedVoteRequests = safeEmailList(room.vote_requests);
  const legacyUnscopedActiveVote = !clean(room.detective_vote_round_id) &&
    isDetectiveVotingActive(activeEmails, persistedVoteRequests);
  const roomStatus = clean(room.status || "waiting").toLowerCase();
  const replayEligibleEmails = roomStatus === "finished"
    ? replayEligiblePlayerEmails(room)
    : [];
  const viewerMaySeeReplayEligibility = replayEligibleEmails.some((email) =>
    normalizedEmail(email) === normalizedEmail(viewer?.email)
  );
  const returnToLobbyEligibleEmails = roomStatus === "playing"
    ? activeGameLobbyEligiblePlayerEmails(room)
    : [];
  const viewerIsRetainedRoomPlayer = safeObjectList(room.players).some(
    (player) =>
      normalizedEmail(player?.email) === normalizedEmail(viewer?.email),
  );
  const viewerMaySeeReturnToLobbyEligibility = roomStatus === "playing" &&
    viewerIsRetainedRoomPlayer;
  const viewerReturnToLobbyEligibleEmails = returnToLobbyEligibleEmails.some(
      (email) => normalizedEmail(email) === normalizedEmail(viewer?.email),
    )
    ? returnToLobbyEligibleEmails
    : [];
  const viewerMayAddressLobbyPlayers =
    ["waiting", "ready_voting"].includes(roomStatus) &&
    normalizedEmail(viewer?.email) === normalizedEmail(room?.host_email);

  return {
    id: clean(room.id),
    match_id: clean(room.match_id),
    replay_source_match_id: clean(room.replay_source_match_id),
    code: clean(room.code),
    host_email: clean(room.host_email),
    status: clean(room.status || "waiting"),
    ...(viewerMaySeeReplayEligibility
      ? { replay_eligible_player_emails: replayEligibleEmails }
      : {}),
    ...(viewerMaySeeReturnToLobbyEligibility
      ? {
        return_to_lobby_eligible_player_emails:
          viewerReturnToLobbyEligibleEmails,
      }
      : {}),
    players: safeObjectList(room.players).map((player) => ({
      ...(viewerMayAddressLobbyPlayers && clean(player.user_id)
        ? { user_id: clean(player.user_id) }
        : {}),
      email: clean(player.email),
      name: safeCommunityDisplayName(player.name),
      avatar: safeCommunityAvatar(player.avatar),
      client_capabilities: canonicalClientCapabilities(
        player.client_capabilities,
      ),
    })).filter((player) => player.email),
    spectators: projectedSpectators,
    ready_players: safeEmailList(room.ready_players),
    cards_read: safeEmailList(room.cards_read),
    // Keep the singular legacy field personalized so any spy still recognizes
    // their own role while new clients consume the canonical list.
    spy_email: revealSpyIdentity ? legacySpyEmail : "",
    spy_emails: visibleSpyEmails,
    revealed_spy_emails:
      clean(room?.status || "waiting").toLowerCase() === "finished"
        ? canonicalSpyEmails(room)
        : canonicalSpyEmails(room).filter((email) =>
          safeEmailList(room.eliminated_emails).some((eliminated) =>
            normalizedEmail(eliminated) === normalizedEmail(email)
          )
        ),
    exclusion_vote_threshold: exclusionVoteThreshold(room),
    word: redacted ? "CLASSIFIED" : safeWord,
    secret_word: redacted ? "CLASSIFIED" : safeWord,
    category: safeCommunityTextForDisplay(room.category, "CLASSIC"),
    spy_guess: safeCommunityTextForDisplay(room.spy_guess, ""),
    detective_votes: legacyUnscopedActiveVote
      ? []
      : safeObjectList(room.detective_votes),
    vote_requests: legacyUnscopedActiveVote ? [] : persistedVoteRequests,
    detective_vote_round_id: clean(room.detective_vote_round_id),
    detective_vote_cancellation_event_id: clean(
      room.detective_vote_cancellation_event_id,
    ),
    detective_vote_cancellation_round_id: clean(
      room.detective_vote_cancellation_round_id,
    ),
    detective_vote_cancellation_present_at: clean(
      room.detective_vote_cancellation_present_at,
    ),
    detective_vote_cancellation_reason:
      clean(room.detective_vote_cancellation_reason) === "no_viable_candidate"
        ? "no_viable_candidate"
        : "",
    terminal_reconciliation_pending: terminalReconciliationPending(room),
    winner: clean(room.winner),
    round_number: Number(room.round_number || 1),
    current_asker_email: clean(room.current_asker_email),
    current_answerer_email: clean(room.current_answerer_email),
    current_answer: isAssociationState
      ? clean(room.current_answer)
      : safeCommunityTextForDisplay(room.current_answer, ""),
    current_answer_feedback: room.current_answer_feedback ?? null,
    player_feedback: safeObjectList(room.player_feedback),
    questions_in_round: Number(room.questions_in_round || 0),
    question_phase: clean(room.question_phase || "asking"),
    eliminated_emails: safeEmailList(room.eliminated_emails),
    // The candidate pool is gameplay data, not the exact role secret. The spy
    // needs it for a legitimate early guess while their exact word stays
    // CLASSIFIED until the match finishes.
    word_pool: wordPool,
    intro_started_at: clean(room.intro_started_at),
    game_started_at: clean(room.game_started_at),
    game_duration_seconds: Number(room.game_duration_seconds || 900),
    game_paused_at: clean(room.game_paused_at),
    game_paused_total_seconds: Math.max(
      0,
      Math.floor(Number(room.game_paused_total_seconds) || 0),
    ),
    countdown_started_at: clean(room.countdown_started_at),
    roulette_target_email: clean(room.roulette_target_email),
    game_mode: clean(room.game_mode || "questions"),
    room_revision: Math.max(
      0,
      Math.floor(Number(room.room_revision) || 0),
    ),
    ...lobbyState,
    created_date: clean(room.created_date),
    updated_date: clean(room.updated_date),
  };
}

import {
  classifyObjectionableMaterial,
  safeCommunityAvatar,
  safeCommunityDisplayName,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";

function clean(value: unknown): string {
  return String(value ?? "").trim();
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

export function shouldRedactRoomSecret(
  room: Record<string, any>,
  viewer: Record<string, any>,
): boolean {
  return clean(viewer?.email) === clean(room?.spy_email) &&
    clean(room?.status || "waiting").toLowerCase() !== "finished";
}

export function projectRoomForClient(
  room: Record<string, any> | null | undefined,
  viewer: Record<string, any>,
) {
  if (!room) return room;
  const redacted = shouldRedactRoomSecret(room, viewer);
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

  return {
    id: clean(room.id),
    match_id: clean(room.match_id),
    code: clean(room.code),
    host_email: clean(room.host_email),
    status: clean(room.status || "waiting"),
    players: safeObjectList(room.players).map((player) => ({
      email: clean(player.email),
      name: safeCommunityDisplayName(player.name),
      avatar: safeCommunityAvatar(player.avatar),
    })).filter((player) => player.email),
    spectators: safeEmailList(room.spectators),
    ready_players: safeEmailList(room.ready_players),
    cards_read: safeEmailList(room.cards_read),
    spy_email: clean(room.spy_email),
    word: redacted ? "CLASSIFIED" : safeWord,
    secret_word: redacted ? "CLASSIFIED" : safeWord,
    category: safeCommunityTextForDisplay(room.category, "CLASSIC"),
    spy_guess: safeCommunityTextForDisplay(room.spy_guess, ""),
    detective_votes: safeObjectList(room.detective_votes),
    vote_requests: safeEmailList(room.vote_requests),
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
    word_pool: redacted ? [] : wordPool,
    game_started_at: clean(room.game_started_at),
    game_duration_seconds: Number(room.game_duration_seconds || 900),
    countdown_started_at: clean(room.countdown_started_at),
    roulette_target_email: clean(room.roulette_target_email),
    game_mode: clean(room.game_mode || "questions"),
    created_date: clean(room.created_date),
    updated_date: clean(room.updated_date),
  };
}

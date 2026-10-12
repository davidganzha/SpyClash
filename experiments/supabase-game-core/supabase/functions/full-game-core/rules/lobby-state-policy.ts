import { requireSafeCommunityText } from "./content-safety.ts";

export const LOBBY_SCHEMA_VERSION = 2;
export const MAX_LOBBY_WORDS = 200;

export type LobbyGameMode = "questions" | "associations";
export type LobbyWordSource = "none" | "saved" | "ai" | "manual";
export type LobbyWordCountMode = "recommended" | "custom";

export type LobbyWordPoolEntry = {
  id: string;
  word: string;
  enabled: boolean;
};

export type CanonicalLobbyState = {
  game_mode: LobbyGameMode;
  game_duration_seconds: number;
  lobby_spy_count: number;
  spies_know_each_other: boolean;
  lobby_word_source: LobbyWordSource;
  lobby_source_pack_id: string;
  lobby_source_name: string;
  lobby_theme: string;
  lobby_category: string;
  lobby_word_count: number;
  lobby_word_count_mode: LobbyWordCountMode;
  lobby_word_pool: LobbyWordPoolEntry[];
};

export type ValidatedLobbyMutation = {
  mutationID: string;
  expectedRevision: number;
  fingerprint: string;
  state: CanonicalLobbyState;
};

function policyError(
  message: string,
  status: number,
  code: string,
  details: Record<string, unknown> = {},
): Error {
  return Object.assign(new Error(message), { status, code, ...details });
}

function clean(value: unknown): string {
  return String(value ?? "").normalize("NFKC").trim();
}

function boundedSafeText(
  value: unknown,
  field: string,
  maximumLength: number,
  required = false,
): string {
  const text = requireSafeCommunityText(clean(value), field);
  if (required && !text) {
    throw policyError(`${field} is required`, 400, "lobby_state_invalid");
  }
  if (text.length > maximumLength) {
    throw policyError(
      `${field} must be at most ${maximumLength} characters`,
      400,
      "lobby_state_invalid",
    );
  }
  return text;
}

function validatedOpaqueID(
  value: unknown,
  field: string,
  required = false,
): string {
  const id = clean(value);
  if (!id && !required) return "";
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(id)) {
    throw policyError(
      `${field} must be a printable opaque identifier`,
      400,
      "lobby_state_invalid",
    );
  }
  return id;
}

function normalizedWordKey(value: unknown): string {
  return clean(value).replace(/\s+/g, " ").toLocaleLowerCase();
}

function stableWordID(wordKey: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < wordKey.length; index += 1) {
    hash ^= wordKey.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return `lw_${(hash >>> 0).toString(16).padStart(8, "0")}`;
}

function canonicalWordPool(value: unknown): LobbyWordPoolEntry[] {
  if (!Array.isArray(value)) {
    throw policyError(
      "Lobby word pool must be an array",
      400,
      "lobby_word_pool_invalid",
    );
  }
  if (value.length > MAX_LOBBY_WORDS) {
    throw policyError(
      `Lobby word pool cannot contain more than ${MAX_LOBBY_WORDS} entries`,
      400,
      "lobby_word_pool_invalid",
    );
  }

  const seenWords = new Set<string>();
  const seenIDs = new Set<string>();
  const result: LobbyWordPoolEntry[] = [];
  for (const candidate of value) {
    if (
      !candidate || typeof candidate !== "object" || Array.isArray(candidate)
    ) {
      throw policyError(
        "Every lobby word pool entry must be an object",
        400,
        "lobby_word_pool_invalid",
      );
    }
    const entry = candidate as Record<string, unknown>;
    const word = boundedSafeText(entry.word, "Word pack item", 120, true)
      .replace(/\s+/g, " ");
    const wordKey = normalizedWordKey(word);
    if (seenWords.has(wordKey)) continue;

    if (entry.enabled !== undefined && typeof entry.enabled !== "boolean") {
      throw policyError(
        "Lobby word enabled state must be boolean",
        400,
        "lobby_word_pool_invalid",
      );
    }

    const suppliedID = clean(entry.id);
    let id = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(suppliedID)
      ? suppliedID
      : stableWordID(wordKey);
    if (seenIDs.has(id)) {
      const baseID = stableWordID(wordKey);
      id = baseID;
      let suffix = 2;
      while (seenIDs.has(id)) id = `${baseID}_${suffix++}`;
    }

    seenWords.add(wordKey);
    seenIDs.add(id);
    result.push({ id, word, enabled: entry.enabled !== false });
  }
  return result;
}

function validatedGameMode(value: unknown): LobbyGameMode {
  const mode = clean(value);
  if (mode !== "questions" && mode !== "associations") {
    throw policyError("Invalid game mode", 400, "lobby_state_invalid");
  }
  return mode;
}

function validatedGameDuration(value: unknown): number {
  const duration = Number(value);
  if (!Number.isInteger(duration) || duration < 60 || duration > 900) {
    throw policyError(
      "Duration must be between 1 and 15 minutes",
      400,
      "lobby_state_invalid",
    );
  }
  return duration;
}

function validatedSpyCount(value: unknown): number {
  const count = Number(value ?? 1);
  if (!Number.isSafeInteger(count) || count < 1 || count > 3) {
    throw policyError(
      "Spy count must be between 1 and 3",
      400,
      "lobby_spy_count_invalid",
    );
  }
  return count;
}

function validatedBoolean(value: unknown, fallback: boolean): boolean {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "boolean") {
    throw policyError(
      "Spy teammate knowledge must be boolean",
      400,
      "lobby_state_invalid",
    );
  }
  return value;
}

function validatedWordSource(value: unknown): LobbyWordSource {
  const source = clean(value);
  if (
    !(["none", "saved", "ai", "manual"] as const).includes(
      source as LobbyWordSource,
    )
  ) {
    throw policyError("Invalid lobby word source", 400, "lobby_state_invalid");
  }
  return source as LobbyWordSource;
}

function validatedWordCountMode(value: unknown): LobbyWordCountMode {
  const mode = clean(value);
  if (mode !== "recommended" && mode !== "custom") {
    throw policyError(
      "Invalid lobby word count mode",
      400,
      "lobby_state_invalid",
    );
  }
  return mode;
}

function validatedWordCount(value: unknown): number {
  const count = Number(value);
  if (!Number.isInteger(count) || count < 0 || count > MAX_LOBBY_WORDS) {
    throw policyError(
      `Lobby word count must be between 0 and ${MAX_LOBBY_WORDS}`,
      400,
      "lobby_state_invalid",
    );
  }
  return count;
}

export function canonicalizeLobbyState(
  value: unknown,
): CanonicalLobbyState {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw policyError(
      "Lobby state must be an object",
      400,
      "lobby_state_invalid",
    );
  }
  const state = value as Record<string, unknown>;
  return {
    game_mode: validatedGameMode(state.game_mode),
    game_duration_seconds: validatedGameDuration(
      state.game_duration_seconds,
    ),
    lobby_spy_count: validatedSpyCount(state.lobby_spy_count),
    spies_know_each_other: validatedBoolean(
      state.spies_know_each_other,
      false,
    ),
    lobby_word_source: validatedWordSource(state.lobby_word_source),
    lobby_source_pack_id: validatedOpaqueID(
      state.lobby_source_pack_id,
      "Lobby source pack id",
    ),
    lobby_source_name: boundedSafeText(
      state.lobby_source_name,
      "Lobby source name",
      120,
    ),
    lobby_theme: boundedSafeText(state.lobby_theme, "Lobby theme", 120),
    lobby_category: boundedSafeText(
      state.lobby_category,
      "Lobby category",
      120,
    ),
    lobby_word_count: validatedWordCount(state.lobby_word_count),
    lobby_word_count_mode: validatedWordCountMode(
      state.lobby_word_count_mode,
    ),
    lobby_word_pool: canonicalWordPool(state.lobby_word_pool),
  };
}

export function lobbyRevision(room: Record<string, unknown>): number {
  const revision = Number(room?.lobby_revision);
  return Number.isInteger(revision) && revision >= 0 ? revision : 0;
}

export function hasAuthoritativeLobbyState(
  room: Record<string, unknown>,
): boolean {
  return lobbyRevision(room) > 0;
}

export function lobbyStateFromRoom(
  room: Record<string, unknown>,
): CanonicalLobbyState {
  return canonicalizeLobbyState({
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
}

function fingerprintHash(value: string): string {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  const bytes = new TextEncoder().encode(value);
  for (const byte of bytes) {
    hash ^= BigInt(byte);
    hash = (hash * prime) & mask;
  }
  return hash.toString(16).padStart(16, "0");
}

export function lobbyStateFingerprint(state: CanonicalLobbyState): string {
  return `lsf1_${fingerprintHash(JSON.stringify(state))}`;
}

export function validateLobbyMutation(input: {
  mutation_id?: unknown;
  expected_revision?: unknown;
  state?: unknown;
}): ValidatedLobbyMutation {
  const mutationID = validatedOpaqueID(
    input.mutation_id,
    "Lobby mutation id",
    true,
  );
  const expectedRevision = Number(input.expected_revision);
  if (!Number.isInteger(expectedRevision) || expectedRevision < 0) {
    throw policyError(
      "Expected lobby revision must be a non-negative integer",
      400,
      "lobby_revision_invalid",
    );
  }
  const state = canonicalizeLobbyState(input.state);
  return {
    mutationID,
    expectedRevision,
    fingerprint: lobbyStateFingerprint(state),
    state,
  };
}

export function lobbyMutationPatch(
  room: Record<string, unknown>,
  mutation: ValidatedLobbyMutation,
): Record<string, unknown> {
  const lastMutationID = clean(room?.lobby_last_mutation_id);
  const lastFingerprint = clean(room?.lobby_last_mutation_fingerprint);
  if (lastMutationID === mutation.mutationID) {
    if (lastFingerprint === mutation.fingerprint) return {};
    throw policyError(
      "Lobby mutation id was already used for a different snapshot",
      409,
      "lobby_mutation_id_reused",
    );
  }

  const currentRevision = lobbyRevision(room);
  if (currentRevision !== mutation.expectedRevision) {
    throw policyError(
      "Lobby state changed; refresh and retry the latest intent",
      409,
      "lobby_revision_conflict",
      { current_revision: currentRevision },
    );
  }

  return {
    lobby_schema_version: LOBBY_SCHEMA_VERSION,
    lobby_revision: currentRevision + 1,
    game_mode: mutation.state.game_mode,
    game_duration_seconds: mutation.state.game_duration_seconds,
    lobby_spy_count: mutation.state.lobby_spy_count,
    spies_know_each_other: mutation.state.spies_know_each_other,
    lobby_word_source: mutation.state.lobby_word_source,
    lobby_source_pack_id: mutation.state.lobby_source_pack_id,
    lobby_source_name: mutation.state.lobby_source_name,
    lobby_theme: mutation.state.lobby_theme,
    lobby_category: mutation.state.lobby_category,
    lobby_word_count: mutation.state.lobby_word_count,
    lobby_word_count_mode: mutation.state.lobby_word_count_mode,
    lobby_word_pool: mutation.state.lobby_word_pool,
    lobby_last_mutation_id: mutation.mutationID,
    lobby_last_mutation_fingerprint: mutation.fingerprint,
  };
}

export function roomHasLobbyMutation(
  room: Record<string, unknown>,
  mutation: ValidatedLobbyMutation,
): boolean {
  if (
    clean(room?.lobby_last_mutation_id) !== mutation.mutationID ||
    clean(room?.lobby_last_mutation_fingerprint) !== mutation.fingerprint ||
    lobbyRevision(room) < mutation.expectedRevision + 1
  ) return false;
  try {
    return lobbyStateFingerprint(lobbyStateFromRoom(room)) ===
      mutation.fingerprint;
  } catch {
    return false;
  }
}

export function selectedAuthoritativeLobbyWordPool(
  room: Record<string, unknown>,
): LobbyWordPoolEntry[] {
  const state = lobbyStateFromRoom(room);
  return state.lobby_word_pool.filter((entry) => entry.enabled).slice(
    0,
    state.lobby_word_count,
  );
}

export function assertAuthoritativeLobbyReady(
  room: Record<string, unknown>,
): void {
  if (!hasAuthoritativeLobbyState(room)) return;
  if (selectedAuthoritativeLobbyWordPool(room).length < 2) {
    throw policyError(
      "Select at least two enabled lobby words before starting",
      409,
      "lobby_word_pool_incomplete",
    );
  }
}

export function authoritativeStartPayload(
  room: Record<string, unknown>,
  clientPayload: Record<string, unknown>,
  expectedRevisionValue: unknown,
): Record<string, unknown> {
  if (!hasAuthoritativeLobbyState(room)) return clientPayload;

  const expectedRevision = Number(expectedRevisionValue);
  const currentRevision = lobbyRevision(room);
  if (!Number.isInteger(expectedRevision) || expectedRevision < 0) {
    throw policyError(
      "Expected lobby revision is required to start this mission",
      409,
      "lobby_revision_required",
      { current_revision: currentRevision },
    );
  }
  if (expectedRevision !== currentRevision) {
    throw policyError(
      "Lobby state changed before mission start; refresh and retry",
      409,
      "lobby_revision_conflict",
      { current_revision: currentRevision },
    );
  }

  const state = lobbyStateFromRoom(room);
  const selectedPool = selectedAuthoritativeLobbyWordPool(room);
  if (selectedPool.length < 2) {
    throw policyError(
      "Select at least two enabled lobby words before starting",
      409,
      "lobby_word_pool_incomplete",
    );
  }
  const requestedSecretKey = normalizedWordKey(
    clientPayload.word || clientPayload.secret_word,
  );
  const secretWord =
    selectedPool.find((entry) =>
      normalizedWordKey(entry.word) === requestedSecretKey
    )?.word || selectedPool[0].word;

  return {
    ...clientPayload,
    secret_word: secretWord,
    word: secretWord,
    game_mode: state.game_mode,
    game_duration_seconds: state.game_duration_seconds,
    category: state.lobby_category || state.lobby_source_name || "CLASSIC",
    word_pool: selectedPool.map((entry) => ({
      word: entry.word,
      enabled: true,
    })),
  };
}

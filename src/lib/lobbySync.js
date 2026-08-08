const LOBBY_WORD_SOURCES = new Set(["none", "saved", "ai", "manual"]);
const LOBBY_WORD_COUNT_MODES = new Set(["recommended", "custom"]);
const LOBBY_GAME_MODES = new Set(["questions", "associations"]);
const MAX_LOBBY_WORDS = 200;
const DEFAULT_RETRY_DELAYS_MILLISECONDS = [180, 450];

/** @typedef {Record<string, any>} LobbyRoom */
/** @typedef {ReturnType<typeof normalizeLobbyState>} LobbyState */
/** @typedef {{mutationID: string, sequence: number, retryCount: number, state: LobbyState}} LobbyIntent */
/** @typedef {{intent: LobbyIntent, expectedRevision: number}} LobbyRequest */

function clean(value) {
  return String(value ?? "").normalize("NFKC").trim();
}

function normalizedWordKey(value) {
  return clean(value).replace(/\s+/g, " ").toLocaleLowerCase();
}

function boundedInteger(value, fallback, minimum, maximum) {
  const candidate = Number(value);
  if (!Number.isInteger(candidate)) return fallback;
  return Math.max(minimum, Math.min(candidate, maximum));
}

function normalizedLobbyPool(value) {
  if (!Array.isArray(value)) return [];

  const words = new Set();
  const result = [];
  for (const candidate of value.slice(0, MAX_LOBBY_WORDS)) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) continue;
    const word = clean(candidate.word).replace(/\s+/g, " ");
    const key = normalizedWordKey(word);
    if (!word || words.has(key)) continue;
    words.add(key);

    const entry = {
      word,
      enabled: candidate.enabled !== false,
    };
    const id = clean(candidate.id);
    if (/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(id)) entry.id = id;
    result.push(entry);
  }
  return result;
}

export function lobbyRevision(room) {
  return boundedInteger(room?.lobby_revision, 0, 0, Number.MAX_SAFE_INTEGER);
}

export function normalizeLobbyState(value = {}) {
  const gameMode = clean(value.game_mode);
  const wordSource = clean(value.lobby_word_source);
  const countMode = clean(value.lobby_word_count_mode);

  return {
    game_mode: LOBBY_GAME_MODES.has(gameMode) ? gameMode : "questions",
    game_duration_seconds: boundedInteger(value.game_duration_seconds, 900, 60, 900),
    lobby_word_source: LOBBY_WORD_SOURCES.has(wordSource) ? wordSource : "none",
    lobby_source_pack_id: clean(value.lobby_source_pack_id),
    lobby_source_name: clean(value.lobby_source_name),
    lobby_theme: clean(value.lobby_theme),
    lobby_category: clean(value.lobby_category),
    lobby_word_count: boundedInteger(value.lobby_word_count, 0, 0, MAX_LOBBY_WORDS),
    lobby_word_count_mode: LOBBY_WORD_COUNT_MODES.has(countMode)
      ? countMode
      : "recommended",
    lobby_word_pool: normalizedLobbyPool(value.lobby_word_pool),
  };
}

export function lobbyStateFromRoom(room = {}) {
  return normalizeLobbyState({
    game_mode: room.game_mode || "questions",
    game_duration_seconds: room.game_duration_seconds || 900,
    lobby_word_source: room.lobby_word_source || "none",
    lobby_source_pack_id: room.lobby_source_pack_id || "",
    lobby_source_name: room.lobby_source_name || "",
    lobby_theme: room.lobby_theme || "",
    lobby_category: room.lobby_category || "",
    lobby_word_count: room.lobby_word_count ?? 0,
    lobby_word_count_mode: room.lobby_word_count_mode || "recommended",
    lobby_word_pool: room.lobby_word_pool || [],
  });
}

function semanticLobbyState(value) {
  const state = normalizeLobbyState(value);
  return {
    ...state,
    lobby_word_pool: state.lobby_word_pool.map(({ word, enabled }) => ({
      word: normalizedWordKey(word),
      enabled,
    })),
  };
}

export function lobbyStatesEquivalent(left, right) {
  return JSON.stringify(semanticLobbyState(left)) === JSON.stringify(semanticLobbyState(right));
}

export function normalizeLobbyThemeInput(value) {
  return clean(value);
}

export function lobbyThemeInputAfterHydration(currentInput, authoritativeTheme, isEditing) {
  return isEditing
    ? String(currentInput ?? "")
    : normalizeLobbyThemeInput(authoritativeTheme);
}

export function roomScopeMatches(scope, current) {
  return Boolean(scope?.roomID) &&
    scope.generation === current?.generation &&
    scope.roomID === current?.requestedRoomID &&
    scope.roomID === current?.roomID;
}

export function materializePlayableLobbyState(state, fallback = {}) {
  const normalized = normalizeLobbyState(state);
  const pool = normalizedLobbyPool(fallback.pool);
  const enabledCount = pool.filter((entry) => entry.enabled).length;
  if (enabledCount < 2) {
    throw new RangeError("A playable fallback lobby needs at least two enabled words");
  }
  const category = clean(fallback.category) || "CLASSIC";
  return normalizeLobbyState({
    ...normalized,
    lobby_word_source: "manual",
    lobby_source_pack_id: "",
    lobby_source_name: category,
    lobby_theme: "",
    lobby_category: category,
    lobby_word_count: enabledCount,
    lobby_word_count_mode: "recommended",
    lobby_word_pool: pool,
  });
}

export function lobbyControlsFromRoom(room = {}) {
  const state = lobbyStateFromRoom(room);
  const pool = state.lobby_word_pool.map((entry) => ({ ...entry }));
  const source = state.lobby_word_source;
  const count = state.lobby_word_count;

  return {
    state,
    gameMode: state.game_mode,
    gameDuration: Math.max(1, Math.min(15, Math.round(state.game_duration_seconds / 60))),
    wordSource: source,
    selectedPackId: source === "saved" ? state.lobby_source_pack_id || null : null,
    customTheme: source === "saved" ? "" : state.lobby_theme,
    generatedCategory: state.lobby_category || state.lobby_source_name || state.lobby_theme,
    wordPool: pool,
    wordCount: count > 0 ? count : pool.filter((entry) => entry.enabled).length,
    wordCountMode: state.lobby_word_count_mode,
    customWordCount: count > 0 ? Math.max(5, Math.min(count, 80)) : 25,
    themeMaxWords: Math.max(10, pool.length),
    themeAnalyzed: pool.length > 0 && (source === "ai" || source === "manual"),
  };
}

export function createLobbyMutationID(randomUUID = () => globalThis.crypto.randomUUID()) {
  return `web-${randomUUID()}`.toLocaleLowerCase();
}

export function isLobbyRevisionConflict(error) {
  return Number(error?.status) === 409 && clean(error?.code).toLocaleLowerCase() ===
    "lobby_revision_conflict";
}

export function isRetryableLobbySyncError(error) {
  if (isLobbyRevisionConflict(error) || error?.retryable === true) return true;
  const status = Number(error?.status);
  return [408, 425, 429].includes(status) || (status >= 500 && status <= 599);
}

function cloneLobbyState(value) {
  const state = normalizeLobbyState(value);
  return {
    ...state,
    lobby_word_pool: state.lobby_word_pool.map((entry) => ({ ...entry })),
  };
}

function defaultSleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * One room-scoped, serialized latest-wins writer. A mutation id belongs to one
 * semantic intent and is retained across retries; newer local edits replace
 * only the pending intent, never the request already in flight.
 *
 * @param {{
 *   updateLobbyState: (request: {roomID: string, mutationID: string, expectedRevision: number, state: LobbyState}) => Promise<LobbyRoom>,
 *   refreshRoom: (roomID: string) => Promise<LobbyRoom | null>,
 *   onConfirmedRoom?: (room: LobbyRoom, mutationID: string) => void,
 *   onRollback?: (room: LobbyRoom, error: any) => void,
 *   onPhaseChange?: (snapshot: any) => void,
 *   makeMutationID?: () => string,
 *   sleep?: (milliseconds: number) => Promise<any>,
 *   retryDelaysMilliseconds?: number[],
 *   debounceMilliseconds?: number,
 * }} options
 */
export function createLobbySyncController({
  updateLobbyState,
  refreshRoom,
  onConfirmedRoom = () => {},
  onRollback = () => {},
  onPhaseChange = () => {},
  makeMutationID = () => createLobbyMutationID(),
  sleep = defaultSleep,
  retryDelaysMilliseconds = DEFAULT_RETRY_DELAYS_MILLISECONDS,
  debounceMilliseconds = 140,
}) {
  if (typeof updateLobbyState !== "function" || typeof refreshRoom !== "function") {
    throw new TypeError("Lobby sync requires updateLobbyState and refreshRoom transports");
  }

  let roomID = null;
  /** @type {LobbyRoom | null} */
  let confirmedRoom = null;
  let confirmedRevision = 0;
  /** @type {LobbyIntent | null} */
  let pendingIntent = null;
  /** @type {LobbyRequest | null} */
  let inFlightRequest = null;
  /** @type {number | null} */
  let runningGeneration = null;
  let generation = 0;
  let sequence = 0;
  /** @type {ReturnType<typeof setTimeout> | null} */
  let timer = null;
  let lastError = null;
  let disposed = false;
  /** @type {Set<(snapshot: any) => void>} */
  const idleResolvers = new Set();

  const hasOptimisticChanges = () => Boolean(pendingIntent || inFlightRequest);

  const snapshot = () => ({
    roomID,
    confirmedRevision,
    pending: Boolean(pendingIntent),
    inFlight: Boolean(inFlightRequest),
    optimistic: hasOptimisticChanges(),
    running: runningGeneration !== null,
    disposed,
    error: lastError,
  });

  const settleIdleResolvers = () => {
    if (timer || runningGeneration !== null || hasOptimisticChanges()) return;
    for (const resolve of idleResolvers) resolve(snapshot());
    idleResolvers.clear();
  };

  const publishPhase = () => {
    onPhaseChange(snapshot());
    settleIdleResolvers();
  };

  const adoptConfirmedRoom = (room) => {
    if (!room || clean(room.id) !== roomID) return false;
    const revision = lobbyRevision(room);
    if (revision < confirmedRevision) return false;
    confirmedRevision = revision;
    confirmedRoom = room;
    return true;
  };

  const refreshedRoomAfterFailure = async (requestGeneration) => {
    try {
      const refreshed = await refreshRoom(roomID);
      if (generation !== requestGeneration || disposed) return null;
      if (refreshed) adoptConfirmedRoom(refreshed);
      return refreshed || null;
    } catch {
      return null;
    }
  };

  const queueIntentForRetry = (intent) => {
    if (pendingIntent && pendingIntent.sequence > intent.sequence) return false;
    pendingIntent = {
      ...intent,
      retryCount: intent.retryCount + 1,
    };
    return true;
  };

  const run = async (requestGeneration) => {
    if (runningGeneration !== requestGeneration || generation !== requestGeneration) return;

    while (
      !disposed && generation === requestGeneration && roomID && pendingIntent
    ) {
      const intent = pendingIntent;
      pendingIntent = null;
      const request = {
        intent,
        expectedRevision: confirmedRevision,
      };
      inFlightRequest = request;
      lastError = null;
      publishPhase();

      try {
        const updatedRoom = await updateLobbyState({
          roomID,
          mutationID: intent.mutationID,
          expectedRevision: request.expectedRevision,
          state: cloneLobbyState(intent.state),
        });
        if (disposed || generation !== requestGeneration || inFlightRequest !== request) return;

        const updatedRevision = lobbyRevision(updatedRoom);
        const validConfirmation = clean(updatedRoom?.id) === roomID &&
          updatedRevision > request.expectedRevision &&
          lobbyStatesEquivalent(lobbyStateFromRoom(updatedRoom), intent.state);
        if (!validConfirmation) {
          throw Object.assign(new Error("Lobby update was not confirmed"), {
            status: 502,
            retryable: true,
          });
        }

        inFlightRequest = null;
        if (updatedRevision < confirmedRevision) {
          if (!lobbyStatesEquivalent(lobbyStateFromRoom(confirmedRoom), intent.state)) {
            queueIntentForRetry(intent);
          } else if (!pendingIntent) {
            onConfirmedRoom(confirmedRoom, intent.mutationID);
          }
          publishPhase();
          continue;
        }

        adoptConfirmedRoom(updatedRoom);
        const superseded = pendingIntent && pendingIntent.sequence > intent.sequence;
        if (!superseded) onConfirmedRoom(updatedRoom, intent.mutationID);
        publishPhase();
      } catch (error) {
        if (disposed || generation !== requestGeneration || inFlightRequest !== request) return;

        const refreshed = await refreshedRoomAfterFailure(requestGeneration);
        if (disposed || generation !== requestGeneration || inFlightRequest !== request) return;

        const refreshedRevision = lobbyRevision(refreshed);
        const recovered = refreshed &&
          refreshedRevision >= confirmedRevision &&
          refreshedRevision > request.expectedRevision &&
          lobbyStatesEquivalent(lobbyStateFromRoom(refreshed), intent.state);
        inFlightRequest = null;
        if (recovered) {
          const superseded = pendingIntent && pendingIntent.sequence > intent.sequence;
          if (!superseded) onConfirmedRoom(refreshed, intent.mutationID);
          lastError = null;
          publishPhase();
          continue;
        }

        if (pendingIntent && pendingIntent.sequence > intent.sequence) {
          publishPhase();
          continue;
        }

        const retryable = isRetryableLobbySyncError(error);
        const canRetry = retryable && intent.retryCount < retryDelaysMilliseconds.length;
        if (canRetry) {
          queueIntentForRetry(intent);
          publishPhase();
          await sleep(retryDelaysMilliseconds[intent.retryCount]);
          continue;
        }

        pendingIntent = null;
        lastError = error;
        const rollbackRoom = refreshed && refreshedRevision >= confirmedRevision
          ? refreshed
          : confirmedRoom;
        if (rollbackRoom) onRollback(rollbackRoom, error);
        publishPhase();
      }
    }
  };

  const startWorker = () => {
    timer = null;
    if (disposed || !roomID || !pendingIntent || runningGeneration !== null) {
      settleIdleResolvers();
      return;
    }
    const requestGeneration = generation;
    runningGeneration = requestGeneration;
    void run(requestGeneration).finally(() => {
      if (runningGeneration !== requestGeneration) return;
      runningGeneration = null;
      if (!disposed && generation === requestGeneration && pendingIntent) {
        startWorker();
      } else {
        publishPhase();
      }
    });
  };

  const schedule = (delay) => {
    if (runningGeneration !== null) return;
    if (timer) clearTimeout(timer);
    if (delay <= 0) {
      const scheduledGeneration = generation;
      queueMicrotask(() => {
        if (generation === scheduledGeneration) startWorker();
      });
      return;
    }
    timer = setTimeout(startWorker, delay);
  };

  return {
    reset(room) {
      disposed = false;
      generation += 1;
      if (timer) clearTimeout(timer);
      timer = null;
      runningGeneration = null;
      pendingIntent = null;
      inFlightRequest = null;
      lastError = null;
      roomID = clean(room?.id) || null;
      confirmedRoom = room || null;
      confirmedRevision = lobbyRevision(room);
      publishPhase();
    },

    reconcile(room) {
      if (disposed || clean(room?.id) !== roomID) return false;
      const accepted = adoptConfirmedRoom(room);
      const idle = !hasOptimisticChanges();
      if (accepted && idle) lastError = null;
      publishPhase();
      return accepted && idle;
    },

    enqueue(state, options = {}) {
      if (disposed || !roomID) return null;
      const normalized = cloneLobbyState(state);

      if (pendingIntent && lobbyStatesEquivalent(pendingIntent.state, normalized)) {
        return pendingIntent.mutationID;
      }
      if (inFlightRequest && lobbyStatesEquivalent(inFlightRequest.intent.state, normalized)) {
        pendingIntent = null;
        publishPhase();
        return inFlightRequest.intent.mutationID;
      }
      if (!inFlightRequest && confirmedRoom &&
        lobbyStatesEquivalent(lobbyStateFromRoom(confirmedRoom), normalized)) {
        pendingIntent = null;
        publishPhase();
        return null;
      }

      sequence += 1;
      pendingIntent = {
        mutationID: makeMutationID(),
        sequence,
        retryCount: 0,
        state: normalized,
      };
      lastError = null;
      publishPhase();
      schedule(options.debounceMilliseconds ?? debounceMilliseconds);
      return pendingIntent.mutationID;
    },

    flush() {
      if (timer) clearTimeout(timer);
      timer = null;
      startWorker();
    },

    hasOptimisticChanges,
    snapshot,

    waitForIdle() {
      if (!timer && runningGeneration === null && !hasOptimisticChanges()) {
        return Promise.resolve(snapshot());
      }
      return new Promise((resolve) => idleResolvers.add(resolve));
    },

    dispose() {
      disposed = true;
      generation += 1;
      if (timer) clearTimeout(timer);
      timer = null;
      runningGeneration = null;
      pendingIntent = null;
      inFlightRequest = null;
      settleIdleResolvers();
    },
  };
}

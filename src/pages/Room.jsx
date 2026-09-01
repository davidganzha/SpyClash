import { useState, useEffect, useRef, useMemo } from "react";
import { generateWordPool } from "@/utils/wordPoolAI";
import { useGlobalQuota } from "@/hooks/useGlobalQuota";
import { Check, Copy, QrCode } from "lucide-react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import GlitchText from "../components/ui/GlitchText";
import WordPoolManager from "../components/WordPoolManager";
import RouletteSpinner from "../components/RouletteSpinner";
import GameToastContainer, { gameToast } from "../components/GameToast";
import { useGameSounds } from "../components/useGameSounds";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";
import QRInvite from "../components/QRInvite";
import WordPackSelector from "../components/WordPackSelector";
import SaveAsWordPackDialog from "../components/SaveAsWordPackDialog";
import { useMembership } from "@/lib/MembershipContext";
import { accountAvatarForDisplay } from "@/lib/avatars";
import { listWordPacks } from "@/lib/wordPackActions";
import {
  closeGameRoom,
  getGameRoom,
  joinGameRoom,
  leaveGameRoom,
  runGameRoomAction,
  subscribeGameRoom,
} from "@/lib/gameRoomActions";
import {
  completeGameStartAfterIntro,
  gameDurationMinutes,
  gameDurationSeconds,
} from "@/lib/gameRoomSync";
import {
  createLobbySyncController,
  lobbyControlsFromRoom,
  lobbyRevision,
  lobbyStateFromRoom,
  lobbyStatesEquivalent,
  lobbyThemeInputAfterHydration,
  materializePlayableLobbyState,
  normalizeLobbyThemeInput,
  normalizeLobbyState,
  roomScopeMatches,
} from "@/lib/lobbySync";
import { shouldAcceptOnlineRoomSnapshot } from "@/lib/onlineGamePresentation";
import { createQuestionTurnOrder, questionPairForStep } from "@/lib/questionTurnOrder";
import { exitRoomImmediately } from "@/lib/roomExit";
import {
  GAME_ROOM_CLOSE_ACTION,
  gameRoomExitAction,
} from "@/lib/gameRoomExit";
import {
  isClientUpdateRequiredError,
  isAllowedSpyCount,
  maxSpyCountForPlayerCount,
  normalizeSpyCount,
} from "@/lib/multiSpyRules";


function SyncStatusBanner({ state, t }) {
  if (state === "connected") return null;
  return (
    <div role="status" aria-live="polite" style={{
      marginBottom: 14,
      padding: "10px 14px",
      border: "1px solid rgba(229,53,53,0.45)",
      background: "rgba(229,53,53,0.08)",
      color: "#e53535",
      fontFamily: "monospace",
      fontSize: 10,
      letterSpacing: 2,
      textAlign: "center",
    }}>
      ↻ {t('room_sync_reconnecting')}
    </div>
  );
}


function pickFromBuiltIn(locale) {
  const cats = Object.keys(locale.builtInCategories);
  const cat = cats[Math.floor(Math.random() * cats.length)];
  const words = locale.builtInCategories[cat];
  const word = words[Math.floor(Math.random() * words.length)];
  const pool = words.map((w) => ({ word: w, enabled: true }));
  return { word, category: cat, pool };
}

function buildAuthoritativeGameData(room) {
  if (lobbyRevision(room) === 0) return null;

  const requestedCount = Number(room?.lobby_word_count);
  const selectedPool = (Array.isArray(room?.lobby_word_pool) ? room.lobby_word_pool : [])
    .filter((entry) => entry?.enabled === true && String(entry?.word || "").trim())
    .slice(0, Number.isInteger(requestedCount) && requestedCount >= 0 ? requestedCount : 0)
    .map((entry) => ({ word: entry.word, enabled: true }));
  const durationSeconds = Number(room?.game_duration_seconds);
  const mode = room?.game_mode;

  if (
    selectedPool.length < 2 ||
    !Number.isInteger(durationSeconds) ||
    durationSeconds <= 0 ||
    (mode !== "questions" && mode !== "associations")
  ) {
    return null;
  }

  return {
    word: selectedPool[Math.floor(Math.random() * selectedPool.length)].word,
    category: room.lobby_category || room.lobby_source_name || "CLASSIC",
    finalPool: selectedPool,
    gameMode: mode,
    durationSeconds,
  };
}



export default function Room() {
  const { t, locale, lang } = useLanguage();
  const { hasResolvedMembership } = useMembership();
  const [room, setRoom] = useState(null);
  const [user, setUser] = useState(null);
  const [starting, setStarting] = useState(false);
  const [syncState, setSyncState] = useState("connected");
  const [copied, setCopied] = useState(false);
  const [customTheme, setCustomTheme] = useState("");
  const [themeInput, setThemeInput] = useState("");
  const [themeError, setThemeError] = useState("");
  const [validating, setValidating] = useState(false);
  const [wordPool, setWordPool] = useState([]);
  const generatedPoolRef = useRef([]);
  const [generatedCategory, setGeneratedCategory] = useState("");
  const [wordCount, setWordCount] = useState(25);
  const [gameDuration, setGameDuration] = useState(10);
  const [selectedSpyCount, setSelectedSpyCount] = useState(1);
  const [spiesKnowEachOther, setSpiesKnowEachOther] = useState(false);
  const [selectedGameMode, setSelectedGameMode] = useState("questions");
  const [wordSource, setWordSource] = useState("none");
  const [rouletteTarget, setRouletteTarget] = useState(null);
  const [selectedPackId, setSelectedPackId] = useState(null);
  const [userPacks, setUserPacks] = useState([]);
  const [showSavePackDialog, setShowSavePackDialog] = useState(false);
  const [themeAnalyzed, setThemeAnalyzed] = useState(false);
  const [themeMaxWords, setThemeMaxWords] = useState(100);
  const [wordCountMode, setWordCountMode] = useState("recommended"); // "recommended" | "custom"
  const [customWordCount, setCustomWordCount] = useState(25);
  const [codeSpoiled, setCodeSpoiled] = useState(false);
  const [qrFlipped, setQrFlipped] = useState(true);
  const [roomAccessPage, setRoomAccessPage] = useState(0);
  const [lobbySyncPhase, setLobbySyncPhase] = useState("idle");
  const [lobbySyncError, setLobbySyncError] = useState("");
  const scrollReturnRef = useRef(null);
  const lockTimerRef = useRef(null);
  const rouletteCompletionKeyRef = useRef(null);
  const leavingRef = useRef(false);
  const roomRef = useRef(null);
  const userRef = useRef(null);
  const roomScopeGenerationRef = useRef(0);
  const themeInputEditingRef = useRef({ active: false, dirty: false });
  const lobbyDraftRef = useRef(null);
  const lobbyDraftVersionRef = useRef(0);
  const lobbySyncControllerRef = useRef(null);
  const applyRoomSnapshotRef = useRef(
    /** @type {(...args: any[]) => boolean} */ (() => false)
  );
  const fallbackBuiltInRef = useRef(null);
  const spoilerDots = useMemo(() => Array.from({ length: 70 }).map((_, i) => ({
    id: i,
    left: Math.random() * 100,
    top: Math.random() * 100,
    duration: 1.5 + Math.random() * 2.5,
    delay: Math.random() * 2,
    dx: (Math.random() - 0.5) * 60,
    dy: (Math.random() - 0.5) * 30
  })), []);
  const navigate = useNavigate();
  const location = useLocation();
  const unsubRef = useRef(null);
  const prevPlayersRef = useRef([]);
  const sounds = useGameSounds();
  const quota = useGlobalQuota();
  const { increment } = quota;

  const syncedGameMode = selectedGameMode;

  if (!lobbySyncControllerRef.current) {
    lobbySyncControllerRef.current = createLobbySyncController({
      updateLobbyState: ({ roomID, mutationID, expectedRevision, state }) =>
        runGameRoomAction("update_lobby_state", roomID, {
          mutation_id: mutationID,
          expected_revision: expectedRevision,
          state,
        }),
      refreshRoom: getGameRoom,
      onConfirmedRoom: (confirmedRoom) => {
        applyRoomSnapshotRef.current(confirmedRoom, {
          forceLobbyHydration: true,
          skipLobbyReconcile: true,
        });
      },
      onRollback: (authoritativeRoom, error) => {
        const applied = applyRoomSnapshotRef.current(authoritativeRoom, {
          forceLobbyHydration: true,
          skipLobbyReconcile: true,
        });
        if (!applied) return;
        const message = error?.message || localize(lang, "Lobby settings were reloaded", "Настройки лобби загружены заново", "Налаштування лобі завантажено повторно");
        setThemeError(message);
        gameToast(message, "warning", "⚠️");
      },
      onPhaseChange: (phase) => {
        setLobbySyncPhase(phase.optimistic ? "syncing" : phase.error ? "error" : "synced");
        setLobbySyncError(phase.error?.message || "");
      },
    });
  }

  const getRoomId = () => new URLSearchParams(window.location.search).get("id");
  const requestedRoomID = new URLSearchParams(location.search).get("id");

  const captureRoomScope = () => ({
    generation: roomScopeGenerationRef.current,
    roomID: roomRef.current?.id || null,
  });

  const isRoomScopeCurrent = (scope) => roomScopeMatches(scope, {
    generation: roomScopeGenerationRef.current,
    requestedRoomID: getRoomId(),
    roomID: roomRef.current?.id,
  });

  const acceptsRoomSnapshot = (nextRoom) => {
    if (!nextRoom?.id || nextRoom.id !== getRoomId()) return false;
    const currentRoom = roomRef.current;
    if (currentRoom?.id && nextRoom?.id !== currentRoom.id) {
      return nextRoom?.id === getRoomId();
    }
    if (!shouldAcceptOnlineRoomSnapshot(currentRoom, nextRoom)) return false;
    if (!currentRoom || currentRoom.id !== nextRoom.id) return true;
    return lobbyRevision(nextRoom) >= lobbyRevision(currentRoom);
  };

  const applyLobbyControls = (controls) => {
    if (!lobbyDraftRef.current || !lobbyStatesEquivalent(lobbyDraftRef.current, controls.state)) {
      lobbyDraftVersionRef.current += 1;
    }
    lobbyDraftRef.current = controls.state;
    setSelectedGameMode(controls.gameMode);
    setGameDuration(controls.gameDuration);
    setSelectedSpyCount(controls.spyCount);
    setSpiesKnowEachOther(controls.spiesKnowEachOther);
    setWordSource(controls.wordSource);
    setSelectedPackId(controls.selectedPackId);
    setCustomTheme(controls.customTheme);
    setThemeInput((currentInput) => lobbyThemeInputAfterHydration(
      currentInput,
      controls.customTheme,
      themeInputEditingRef.current.active,
    ));
    setGeneratedCategory(controls.generatedCategory);
    setWordPool(controls.wordPool);
    generatedPoolRef.current = controls.wordPool;
    setWordCount(controls.wordCount);
    setWordCountMode(controls.wordCountMode);
    setCustomWordCount(controls.customWordCount);
    setThemeMaxWords(controls.themeMaxWords);
    setThemeAnalyzed(controls.themeAnalyzed);
  };

  const hydrateLobbyControls = (nextRoom) => {
    applyLobbyControls(lobbyControlsFromRoom(nextRoom));
  };

  const applyRoomSnapshot = (nextRoom, options = {}) => {
    if (!acceptsRoomSnapshot(nextRoom)) return false;
    const controller = lobbySyncControllerRef.current;
    const controllerState = controller.snapshot();
    const isWritableLobby = nextRoom.status === "waiting" &&
      nextRoom.host_email === userRef.current?.email;
    let scopeReset = false;
    if (isWritableLobby &&
      (controllerState.disposed || controllerState.roomID !== nextRoom.id)) {
      controller.reset(nextRoom);
      scopeReset = true;
    } else if (!isWritableLobby &&
      (!controllerState.disposed || controllerState.roomID ||
        controllerState.optimistic || controllerState.error)) {
      controller.reset(null);
      scopeReset = true;
    }
    if (!isWritableLobby) {
      themeInputEditingRef.current = { active: false, dirty: false };
    }
    roomRef.current = nextRoom;
    setRoom(nextRoom);
    const reconciled = isWritableLobby && !scopeReset && !options.skipLobbyReconcile
      ? controller.reconcile(nextRoom)
      : false;
    const shouldHydrate = options.forceLobbyHydration || scopeReset ||
      !isWritableLobby || reconciled;
    if (shouldHydrate) hydrateLobbyControls(nextRoom);
    return true;
  };
  applyRoomSnapshotRef.current = applyRoomSnapshot;

  const currentLobbyDraft = () => lobbyDraftRef.current || lobbyStateFromRoom(roomRef.current || {});

  const enqueueLobbySnapshot = (state, debounceMilliseconds = 140) => {
    const currentRoom = roomRef.current;
    const controller = lobbySyncControllerRef.current;
    const controllerState = controller.snapshot();
    if (!currentRoom || currentRoom.status !== "waiting" ||
      currentRoom.host_email !== userRef.current?.email) {
      return false;
    }
    if (controllerState.disposed || controllerState.roomID !== currentRoom.id) return false;
    const normalized = normalizeLobbyState(state);
    applyLobbyControls(lobbyControlsFromRoom({
      ...currentRoom,
      ...normalized,
    }));
    controller.enqueue(normalized, { debounceMilliseconds });
    return true;
  };

  const builtInLobbyState = (baseState = currentLobbyDraft()) => {
    if (!fallbackBuiltInRef.current) fallbackBuiltInRef.current = pickFromBuiltIn(locale);
    const selection = fallbackBuiltInRef.current;
    const pool = selection.pool.slice(0, 200);
    return materializePlayableLobbyState(baseState, {
      category: selection.category,
      pool,
    });
  };

  const playableLobbyState = (state) => {
    const normalized = normalizeLobbyState(state);
    const enabled = normalized.lobby_word_pool.filter((entry) => entry.enabled).length;
    if (enabled >= 2 || normalized.lobby_theme || normalized.lobby_word_source !== "none") {
      return normalized;
    }
    return builtInLobbyState(normalized);
  };

  useEffect(() => {
    if (!hasResolvedMembership) return;
    const id = requestedRoomID;
    const scopeGeneration = roomScopeGenerationRef.current + 1;
    roomScopeGenerationRef.current = scopeGeneration;
    let mounted = true;
    const isCurrent = () => mounted &&
      roomScopeGenerationRef.current === scopeGeneration &&
      getRoomId() === id;

    unsubRef.current?.();
    unsubRef.current = null;
    lobbySyncControllerRef.current.reset(null);
    roomRef.current = null;
    userRef.current = null;
    lobbyDraftRef.current = null;
    fallbackBuiltInRef.current = null;
    generatedPoolRef.current = [];
    prevPlayersRef.current = [];
    lobbyDraftVersionRef.current += 1;
    themeInputEditingRef.current = { active: false, dirty: false };
    rouletteCompletionKeyRef.current = null;
    leavingRef.current = false;
    setRoom(null);
    setUser(null);
    setStarting(false);
    setValidating(false);
    setThemeError("");
    setLobbySyncError("");
    setLobbySyncPhase("idle");
    setSyncState("connected");
    setRouletteTarget(null);
    setShowSavePackDialog(false);
    setThemeInput("");
    setCustomTheme("");
    if (id) localStorage.setItem("spy_active_room_id", id);

    base44.auth.me().then((u) => {
      if (!isCurrent()) return;
      if (!u) {base44.auth.redirectToLogin(window.location.href);return;}
      userRef.current = u;
      setUser(u);
      void loadRoom(u, id, isCurrent).catch((error) => {
        if (!isCurrent()) return;
        console.error("Failed to load room", error);
        if (isClientUpdateRequiredError(error)) {
          alert(t("room_update_required"));
          navigate(createPageUrl("Home"));
          return;
        }
        gameToast(error?.message || t('room_sync_reconnecting'), "warning", "⚠️");
        navigate(createPageUrl("Home"));
      });
      // Load user's word packs for selector
      listWordPacks().then((packs) => {
        if (isCurrent()) setUserPacks(packs);
      }).catch(() => {});
    }).catch(() => {
      if (isCurrent()) navigate(createPageUrl("Home"));
    });
    return () => {
      mounted = false;
      if (roomScopeGenerationRef.current === scopeGeneration) {
        roomScopeGenerationRef.current += 1;
      }
      unsubRef.current?.();
      unsubRef.current = null;
      lobbySyncControllerRef.current?.dispose();
      roomRef.current = null;
      userRef.current = null;
      lobbyDraftRef.current = null;
      fallbackBuiltInRef.current = null;
    };
  }, [hasResolvedMembership, requestedRoomID]);

  const loadRoom = async (u, id, isCurrent) => {
    if (!id) {
      if (isCurrent()) navigate(createPageUrl("Home"));
      return;
    }
    let room = await getGameRoom(id);
    if (!isCurrent()) return;
    if (!room) {navigate(createPageUrl("Home"));return;}

    if (room.status === "waiting") {
      const displayName = u.display_name || u.full_name || u.email.split("@")[0];
      const avatar = accountAvatarForDisplay(u.avatar);
      room = await joinGameRoom({ roomId: id, player: { name: displayName, avatar } });
      if (!isCurrent()) return;
    }
    const finalRoom = room;
    prevPlayersRef.current = finalRoom.players || [];
    fallbackBuiltInRef.current = null;
    const applied = applyRoomSnapshot(finalRoom, {
      forceLobbyHydration: true,
      skipLobbyReconcile: true,
    });
    if (!applied || !isCurrent()) return;
    if (["playing", "finished"].includes(finalRoom.status)) {
      navigate(createPageUrl("Game") + `?id=${id}`);
      return;
    }

    unsubRef.current = subscribeGameRoom(id, async (evt) => {
      if (!isCurrent()) return;
      if (evt.id !== id) return;
      if (evt.type === "sync") {
        setSyncState(evt.state);
        return;
      }
      if (evt.type === "delete") {navigate(createPageUrl("Home"));return;}
      let newRoom = evt.data;
      if (!newRoom) newRoom = await getGameRoom(id);
      if (!isCurrent()) return;
      if (!newRoom) return;
      if (!acceptsRoomSnapshot(newRoom)) return;

      const prevPlayers = prevPlayersRef.current;
      const newPlayers = newRoom.players || [];
      newPlayers.forEach((p) => {
        if (!prevPlayers.find((pp) => pp.email === p.email)) {
          gameToast(`${p.name} ${t('room_toast_joined')}`, "join", p.avatar || "👤");
          sounds.playerJoined();
        }
      });
      prevPlayers.forEach((p) => {
        if (!newPlayers.find((np) => np.email === p.email)) {
          gameToast(`${p.name} ${t('toast_left')}`, "leave", "👋");
        }
      });
      prevPlayersRef.current = newPlayers;

      applyRoomSnapshot(newRoom);
      setSyncState("connected");
      if (newRoom.status === "playing") {
        gameToast(t('room_toast_game_starting'), "round", "🎯");
        sounds.roundStart();
        navigate(createPageUrl("Game") + `?id=${id}`);
      }
    }, {
      userId: u.id,
      currentRoomRevision: () => roomRef.current?.room_revision,
    });

  };

  const handleToggleReady = async () => {
    const scope = captureRoomScope();
    const sourceRoom = roomRef.current;
    if (!sourceRoom || !userRef.current || !isRoomScopeCurrent(scope)) return;
    const updated = await runGameRoomAction("toggle_ready", sourceRoom.id);
    if (!isRoomScopeCurrent(scope)) return;
    applyRoomSnapshot(updated);
  };

  const generatedLobbyState = ({ pool, category, count }) => normalizeLobbyState({
    ...currentLobbyDraft(),
    lobby_word_source: "ai",
    lobby_source_pack_id: "",
    lobby_source_name: category,
    lobby_theme: customTheme.trim(),
    lobby_category: category,
    lobby_word_count: count,
    lobby_word_count_mode: wordCountMode,
    lobby_word_pool: pool,
  });

  const handleThemeChange = (value) => {
    setThemeError("");
    fallbackBuiltInRef.current = null;
    const theme = normalizeLobbyThemeInput(value);
    if (!theme) {
      enqueueLobbySnapshot(builtInLobbyState({
        ...currentLobbyDraft(),
        lobby_word_source: "none",
        lobby_source_pack_id: "",
        lobby_source_name: "",
        lobby_theme: "",
        lobby_category: "",
        lobby_word_count: 0,
        lobby_word_pool: [],
      }), 180);
      return;
    }

    enqueueLobbySnapshot({
      ...currentLobbyDraft(),
      lobby_word_source: "none",
      lobby_source_pack_id: "",
      lobby_source_name: "",
      lobby_theme: theme,
      lobby_category: theme,
      lobby_word_count: wordCountMode === "custom" ? customWordCount : 0,
      lobby_word_count_mode: wordCountMode,
      lobby_word_pool: [],
    }, 180);
  };

  const handleThemeInputChange = (value) => {
    themeInputEditingRef.current = { active: true, dirty: true };
    setThemeInput(value);
    handleThemeChange(value);
  };

  const handleThemeInputFocus = (element) => {
    themeInputEditingRef.current = { active: true, dirty: false };
    centerInViewport(element.closest('.theme-block'));
  };

  const handleThemeInputBlur = () => {
    const wasDirty = themeInputEditingRef.current.dirty;
    themeInputEditingRef.current = { active: false, dirty: false };
    if (wasDirty) {
      const normalized = normalizeLobbyThemeInput(themeInput);
      setThemeInput(normalized);
      handleThemeChange(normalized);
    } else {
      const controls = lobbyControlsFromRoom({
        ...roomRef.current,
        ...currentLobbyDraft(),
      });
      setThemeInput(controls.customTheme);
    }
    restoreScroll();
  };

  const handleWordCountModeChange = (mode) => {
    const draft = currentLobbyDraft();
    const enabledCount = draft.lobby_word_pool.filter((entry) => entry.enabled).length;
    enqueueLobbySnapshot({
      ...draft,
      lobby_word_count_mode: mode,
      lobby_word_count: mode === "custom" ? customWordCount : enabledCount,
    }, 100);
  };

  const handleCustomWordCountChange = (value) => {
    const count = Math.max(5, Math.min(Number(value) || 5, 80));
    enqueueLobbySnapshot({
      ...currentLobbyDraft(),
      lobby_word_count_mode: "custom",
      lobby_word_count: count,
    }, 120);
  };

  const handleSelectedWordCountChange = (value) => {
    const draft = currentLobbyDraft();
    const enabledCount = draft.lobby_word_pool.filter((entry) => entry.enabled).length;
    enqueueLobbySnapshot({
      ...draft,
      lobby_word_count: Math.max(
        0,
        Math.min(Number(value) || 0, enabledCount, 200),
      ),
    }, 100);
  };

  // Single-step: generate words directly, derive real max from actual result
  const handleAnalyze = async () => {
    if (!customTheme.trim()) return;
    const scope = captureRoomScope();
    if (!isRoomScopeCurrent(scope)) return;
    const requestVersion = lobbyDraftVersionRef.current;
    setValidating(true);
    setThemeError("");
    // Target depends on mode: recommended = 100 (model picks real count), custom = user-chosen exact count
    const target = wordCountMode === "custom" ? customWordCount : 100;
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), target);
    } catch (error) {
      console.error("AI theme analysis failed", error);
      if (!isRoomScopeCurrent(scope)) return;
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(localize(
          lang,
          "AI generation is temporarily unavailable.",
          "AI-генерация временно недоступна.",
          "Генерація за допомогою ШІ тимчасово недоступна.",
        ));
      }
      setValidating(false);
      return;
    }
    if (!isRoomScopeCurrent(scope)) return;
    setValidating(false);
    if (!result?.words?.length || result.words.length < 5) {
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(localize(lang, "Couldn't recognize this theme. Try another.", "Не удалось распознать тему. Попробуй другую.", "Не вдалося розпізнати тему. Спробуйте іншу."));
      }
      return;
    }
    const realMax = result.words.length;
    const pool = result.words.map((w) => ({ word: w, enabled: true }));
    increment(result);
    if (!isRoomScopeCurrent(scope) || requestVersion !== lobbyDraftVersionRef.current) return;
    const category = result.display_category || customTheme.trim();
    const selectedCount = wordCountMode === "custom"
      ? Math.min(customWordCount, realMax)
      : realMax;
    enqueueLobbySnapshot(generatedLobbyState({
      pool,
      category,
      count: selectedCount,
    }), 80);
  };

  const generateTheme = async () => {
    if (!customTheme.trim()) return;
    const scope = captureRoomScope();
    if (!isRoomScopeCurrent(scope)) return;
    const requestVersion = lobbyDraftVersionRef.current;
    setValidating(true);
    setThemeError("");
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), wordCount);
    } catch (error) {
      console.error("AI theme generation failed", error);
      if (!isRoomScopeCurrent(scope)) return;
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(localize(
          lang,
          "AI generation is temporarily unavailable.",
          "AI-генерация временно недоступна.",
          "Генерація за допомогою ШІ тимчасово недоступна.",
        ));
      }
      setValidating(false);
      return;
    }
    if (!isRoomScopeCurrent(scope)) return;
    setValidating(false);
    if (!result?.words?.length) {
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(t('room_theme_error_empty'));
      }
      return;
    }
    const pool = result.words.slice(0, wordCount).map((w) => ({ word: w, enabled: true }));
    increment(result);
    if (!isRoomScopeCurrent(scope) || requestVersion !== lobbyDraftVersionRef.current) return;
    enqueueLobbySnapshot(generatedLobbyState({
      pool,
      category: result.display_category || customTheme.trim(),
      count: Math.min(wordCount, pool.length),
    }), 80);
  };

  // Squeeze more words beyond current max
  const pushMax = async () => {
    if (!customTheme.trim() || validating) return;
    const scope = captureRoomScope();
    if (!isRoomScopeCurrent(scope)) return;
    const requestVersion = lobbyDraftVersionRef.current;
    setValidating(true);
    setThemeError("");
    const currentPool = wordPool.length ? wordPool : generatedPoolRef.current;
    const currentWords = currentPool.map((w) => w.word);
    const additionalCount = Math.min(50, Math.max(0, 200 - currentWords.length));
    if (additionalCount === 0) {
      setValidating(false);
      return;
    }
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), additionalCount, currentWords);
    } catch (error) {
      console.error("AI theme expansion failed", error);
      if (!isRoomScopeCurrent(scope)) return;
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(localize(
          lang,
          "AI generation is temporarily unavailable.",
          "AI-генерация временно недоступна.",
          "Генерація за допомогою ШІ тимчасово недоступна.",
        ));
      }
      setValidating(false);
      return;
    }
    if (!isRoomScopeCurrent(scope)) return;
    setValidating(false);
    if (!result?.words?.length) return;
    const existingLower = new Set(currentWords.map((w) => w.toLowerCase()));
    const additions = result.words.filter((w) => !existingLower.has(w.toLowerCase()));
    if (additions.length === 0) {
      if (requestVersion === lobbyDraftVersionRef.current) {
        setThemeError(localize(lang, "Couldn't find more unique words.", "Больше уникальных слов найти не удалось.", "Не вдалося знайти більше унікальних слів."));
      }
      return;
    }
    const newPool = [...currentPool, ...additions.map((w) => ({ word: w, enabled: true }))].slice(0, 200);
    increment(result);
    if (!isRoomScopeCurrent(scope) || requestVersion !== lobbyDraftVersionRef.current) return;
    enqueueLobbySnapshot(generatedLobbyState({
      pool: newPool,
      category: generatedCategory || customTheme.trim(),
      count: newPool.length,
    }), 80);
  };

  const handlePoolUpdate = (updated) => {
    const draft = currentLobbyDraft();
    const previousPool = draft.lobby_word_pool;
    const sameWords = previousPool.length === updated.length && previousPool.every((entry, index) =>
      entry.word.normalize("NFKC").trim().toLocaleLowerCase() ===
        String(updated[index]?.word || "").normalize("NFKC").trim().toLocaleLowerCase()
    );
    const previousEnabledCount = previousPool.filter((entry) => entry.enabled).length;
    const enabledCount = updated.filter((entry) => entry?.enabled !== false).length;
    const selectedAll = draft.lobby_word_count >= previousEnabledCount;
    const source = sameWords && draft.lobby_word_source !== "none"
      ? draft.lobby_word_source
      : "manual";
    enqueueLobbySnapshot({
      ...draft,
      lobby_word_source: source,
      lobby_source_pack_id: source === "saved" ? draft.lobby_source_pack_id : "",
      lobby_word_count: selectedAll
        ? enabledCount
        : Math.min(draft.lobby_word_count, enabledCount),
      lobby_word_pool: updated,
    }, 100);
  };

  const handleWordPackSelect = (packID, selectedPack = null) => {
    setThemeError("");
    if (!packID) {
      fallbackBuiltInRef.current = pickFromBuiltIn(locale);
      enqueueLobbySnapshot(builtInLobbyState(), 80);
      return;
    }

    const pack = selectedPack || userPacks.find((candidate) => candidate.id === packID);
    if (!pack) {
      setThemeError(localize(
        lang,
        "Could not load this WordPack. Try again.",
        "Не удалось загрузить WordPack. Попробуй снова.",
        "Не вдалося завантажити набір слів. Спробуйте ще раз.",
      ));
      return;
    }
    const pool = (pack.words || []).map((entry) => ({
      word: typeof entry === "string" ? entry : entry?.word,
      enabled: typeof entry === "object" ? entry?.enabled !== false : true,
    })).filter((entry) => String(entry.word || "").trim());
    const category = pack.category || pack.name || "WORDPACK";
    enqueueLobbySnapshot({
      ...currentLobbyDraft(),
      lobby_word_source: "saved",
      lobby_source_pack_id: pack.id,
      lobby_source_name: pack.name || category,
      lobby_theme: "",
      lobby_category: category,
      lobby_word_count: pool.filter((entry) => entry.enabled).length,
      lobby_word_count_mode: "recommended",
      lobby_word_pool: pool,
    }, 80);
  };

  const buildGameData = (sourceRoom = roomRef.current) => {
    if (lobbyRevision(sourceRoom) > 0) {
      return buildAuthoritativeGameData(sourceRoom);
    }

    let word, category, finalPool;

    // Priority 1: custom AI-generated theme pool
    if (customTheme.trim() && wordPool.length > 0) {
      const enabledWords = wordPool.filter((w) => w.enabled);
      if (enabledWords.length === 0) return null;
      word = enabledWords[Math.floor(Math.random() * enabledWords.length)].word;
      category = generatedCategory || customTheme.trim();
      finalPool = wordPool;
    }
    // Priority 2: selected user pack
    else if (selectedPackId) {
      const pack = userPacks.find((p) => p.id === selectedPackId);
      if (pack && pack.words?.length >= 2) {
        word = pack.words[Math.floor(Math.random() * pack.words.length)];
        category = pack.category || pack.name;
        finalPool = pack.words.map((w) => ({ word: w, enabled: true }));
      } else {
        const picked = pickFromBuiltIn(locale);
        word = picked.word;category = picked.category;finalPool = picked.pool;
      }
    }
    // Priority 3: random built-in
    else {
      const picked = pickFromBuiltIn(locale);
      word = picked.word;
      category = picked.category;
      finalPool = picked.pool;
    }
    return { word, category, finalPool };
  };

  const waitForConfirmedLobbyRoom = async (scope) => {
    if (!isRoomScopeCurrent(scope)) return null;
    const controller = lobbySyncControllerRef.current;
    const controllerState = controller.snapshot();
    if (controllerState.disposed || controllerState.roomID !== scope.roomID) return null;
    const initialRoom = roomRef.current;
    const mustMaterializeDefault = initialRoom?.status === "waiting" &&
      lobbyRevision(initialRoom) === 0 &&
      !controller.hasOptimisticChanges();
    if (mustMaterializeDefault) {
      enqueueLobbySnapshot(playableLobbyState(currentLobbyDraft()), 0);
    }
    controller.flush();
    const sync = await controller.waitForIdle();
    if (!isRoomScopeCurrent(scope)) return null;
    const confirmedRoom = roomRef.current;
    if (
      sync.error ||
      controller.hasOptimisticChanges() ||
      !confirmedRoom ||
      confirmedRoom.id !== scope.roomID ||
      confirmedRoom.status !== "waiting" ||
      confirmedRoom.host_email !== userRef.current?.email ||
      (mustMaterializeDefault && lobbyRevision(confirmedRoom) === 0)
    ) {
      const message = sync.error?.message || localize(
        lang,
        "Lobby settings are not synchronized yet.",
        "Настройки лобби ещё не синхронизированы.",
        "Налаштування лобі ще не синхронізовано.",
      );
      setThemeError(message);
      return null;
    }
    return confirmedRoom;
  };

  const handleStartRoulette = async () => {
    const scope = captureRoomScope();
    const sourceRoom = roomRef.current;
    if (!sourceRoom || !["waiting", "ready_voting"].includes(sourceRoom.status) ||
      sourceRoom.host_email !== userRef.current?.email || !isRoomScopeCurrent(scope)) return;
    setStarting(true);
    const confirmedRoom = sourceRoom.status === "waiting"
      ? await waitForConfirmedLobbyRoom(scope)
      : sourceRoom;
    if (!isRoomScopeCurrent(scope)) return;
    if (!confirmedRoom) {setStarting(false);return;}
    if (lobbyRevision(confirmedRoom) === 0) {
      const message = localize(
        lang,
        "Return to the lobby to synchronize the game settings.",
        "Вернись в лобби, чтобы синхронизировать параметры игры.",
        "Поверніться до лобі, щоб синхронізувати налаштування гри.",
      );
      setThemeError(message);
      gameToast(message, "warning", "⚠️");
      setStarting(false);
      return;
    }
    const data = buildGameData(confirmedRoom);
    if (!data) {setThemeError(t('room_theme_error_empty'));setStarting(false);return;}
    const players = confirmedRoom.players || [];
    if (players.length < 3) {setThemeError(t('room_theme_error_min'));setStarting(false);return;}
    if (!isAllowedSpyCount(players.length, confirmedRoom.lobby_spy_count ?? 1)) {
      setThemeError(t("room_spy_count_invalid"));
      setStarting(false);
      return;
    }
    const questionTurnOrder = createQuestionTurnOrder(players.length);
    const firstQuestionPair = questionPairForStep(questionTurnOrder, 0);
    const firstAskerIdx = firstQuestionPair.askerIndex;
    const firstAnswererIdx = firstQuestionPair.answererIndex;
    const playerFeedback = players.map((p) => ({ email: p.email, likes: 0, dislikes: 0 }));
    const updateData = {
      status: "playing",
      word: data.word, category: data.category, spy_guess: "", detective_votes: [], winner: "",
      current_asker_email: players[firstAskerIdx].email,
      current_answerer_email: players[firstAnswererIdx].email,
      questions_in_round: 0, round_number: 1,
      ready_players: [], current_answer: "",
      question_phase: "asking", player_feedback: playerFeedback,
      word_pool: data.finalPool, vote_requests: [], eliminated_emails: [],
      game_duration_seconds: data.durationSeconds || gameDurationSeconds(gameDuration),
      game_mode: data.gameMode || syncedGameMode
    };
    try {
      const armedRoom = await runGameRoomAction("arm_roulette", confirmedRoom.id, {
        roulette_target_email: players[firstAskerIdx].email,
        expected_lobby_revision: lobbyRevision(confirmedRoom),
        plan: updateData,
      });
      if (!isRoomScopeCurrent(scope)) return;
      if (!applyRoomSnapshot(armedRoom)) {
        setStarting(false);
        return;
      }
      rouletteCompletionKeyRef.current = null;
      setRouletteTarget({ email: players[firstAskerIdx].email });
    } catch (error) {
      console.error("Failed to arm synchronized roulette", error);
      if (!isRoomScopeCurrent(scope)) return;
      setThemeError(error?.message || t('room_start_failed'));
      setStarting(false);
    }
  };

  const handleRouletteDone = async () => {
    const scope = captureRoomScope();
    const sourceRoom = roomRef.current;
    const currentUser = userRef.current;
    if (!sourceRoom || !currentUser || sourceRoom.status !== "roulette" ||
      !isRoomScopeCurrent(scope)) return;
    if (!(sourceRoom.players || []).some((player) => player.email === currentUser.email)) return;

    const completionKey = `${sourceRoom.id}:${sourceRoom.intro_started_at || sourceRoom.roulette_target_email || "intro"}`;
    if (rouletteCompletionKeyRef.current === completionKey) return;
    rouletteCompletionKeyRef.current = completionKey;
    setStarting(true);

    try {
      const completedRoom = await completeGameStartAfterIntro({
        room: sourceRoom,
        refreshRoom: getGameRoom,
        completeStart: (currentRoom) => runGameRoomAction("complete_game_start", currentRoom.id),
      });
      if (!isRoomScopeCurrent(scope)) return;
      if (!applyRoomSnapshot(completedRoom)) return;
      if (completedRoom?.status === "playing") {
        navigate(createPageUrl("Game") + `?id=${completedRoom.id}`);
      } else if (completedRoom?.status === "roulette") {
        rouletteCompletionKeyRef.current = null;
      }
    } catch (error) {
      if (!isRoomScopeCurrent(scope)) return;
      rouletteCompletionKeyRef.current = null;
      console.error("Failed to complete synchronized roulette", error);
      gameToast(error?.message || t('room_start_failed'), "warning", "⚠️");
    } finally {
      if (isRoomScopeCurrent(scope)) setStarting(false);
    }
  };

  const isHost = gameRoomExitAction({
    hostEmail: room?.host_email,
    userEmail: user?.email,
    closeForHost: true,
  }) === GAME_ROOM_CLOSE_ACTION;

  const handleLeave = () => {
    const sourceRoom = roomRef.current;
    const currentUser = userRef.current;
    if (!sourceRoom || !currentUser || leavingRef.current) return;
    const exitAction = gameRoomExitAction({
      hostEmail: sourceRoom.host_email,
      userEmail: currentUser.email,
      closeForHost: isHost,
    });
    const performExit = exitAction === GAME_ROOM_CLOSE_ACTION
      ? closeGameRoom
      : leaveGameRoom;
    leavingRef.current = true;
    roomScopeGenerationRef.current += 1;
    try {
      unsubRef.current?.();
    } catch {
      // Local navigation must not depend on realtime cleanup.
    }
    unsubRef.current = null;
    lobbySyncControllerRef.current?.dispose();
    void exitRoomImmediately({
      roomId: sourceRoom.id,
      action: exitAction,
      leaveRoom: performExit,
      navigateHome: () => {
        try {
          localStorage.setItem("spy_return_to_online", "1");
        } catch {
          // Navigation remains available when storage is unavailable.
        }
        navigate(createPageUrl("Home"), { replace: true });
      },
    });
  };

  const copyCode = () => {
    navigator.clipboard.writeText(room.code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const updateGameMode = (newMode) => {
    enqueueLobbySnapshot(playableLobbyState({
      ...currentLobbyDraft(),
      game_mode: newMode,
    }), 90);
  };

  const updateGameDuration = (minutes) => {
    const normalizedMinutes = gameDurationMinutes({
      game_duration_seconds: gameDurationSeconds(minutes),
    });
    enqueueLobbySnapshot(playableLobbyState({
      ...currentLobbyDraft(),
      game_duration_seconds: gameDurationSeconds(normalizedMinutes),
    }), 140);
  };

  const updateSpyCount = (value) => {
    const playerCount = (roomRef.current?.players || []).length;
    enqueueLobbySnapshot({
      ...currentLobbyDraft(),
      lobby_spy_count: normalizeSpyCount(value, playerCount),
    }, 90);
  };

  const updateSpiesKnowEachOther = (value) => {
    enqueueLobbySnapshot({
      ...currentLobbyDraft(),
      spies_know_each_other: value === true,
    }, 90);
  };

  const handleReturnToWaiting = async () => {
    const scope = captureRoomScope();
    const sourceRoom = roomRef.current;
    if (!sourceRoom || sourceRoom.host_email !== userRef.current?.email ||
      !isRoomScopeCurrent(scope)) return;
    try {
      const updated = await runGameRoomAction("return_to_waiting", sourceRoom.id);
      if (!isRoomScopeCurrent(scope)) return;
      applyRoomSnapshot(updated);
    } catch (error) {
      if (!isRoomScopeCurrent(scope)) return;
      console.error("Failed to return room to waiting", error);
      gameToast(error?.message || t('room_return_waiting_failed'), "warning", "⚠️");
    }
  };

  const handleBeginReadyCheck = async () => {
    const scope = captureRoomScope();
    if (!roomRef.current || roomRef.current.host_email !== userRef.current?.email ||
      !isRoomScopeCurrent(scope)) return;
    setStarting(true);
    try {
      const confirmedRoom = await waitForConfirmedLobbyRoom(scope);
      if (!isRoomScopeCurrent(scope)) return;
      if (!confirmedRoom) return;
      if (lobbyRevision(confirmedRoom) > 0 && !buildAuthoritativeGameData(confirmedRoom)) {
        setThemeError(t('room_theme_error_empty'));
        return;
      }
      const updated = await runGameRoomAction("begin_ready_check", confirmedRoom.id);
      if (!isRoomScopeCurrent(scope)) return;
      applyRoomSnapshot(updated);
    } catch (error) {
      if (!isRoomScopeCurrent(scope)) return;
      console.error("Failed to begin ready check", error);
      gameToast(error?.message || t('room_start_failed'), "warning", "⚠️");
    } finally {
      if (isRoomScopeCurrent(scope)) setStarting(false);
    }
  };

  if (!room || !user) return (
    <>
      <GameToastContainer />
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)" }}>
        <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }} style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}>
          {t('loading')}
        </motion.div>
      </div>
    </>);

  const authoritativeLobby = lobbyRevision(room) > 0;
  const players = room.players || [];
  const maxSpyCount = maxSpyCountForPlayerCount(players.length);
  const spyCountIsValid = isAllowedSpyCount(players.length, selectedSpyCount);
  const readyPlayers = room.ready_players || [];
  const allReady = players.length >= 3 && readyPlayers.length === players.length;
  const userReady = readyPlayers.includes(user?.email);
  const nonHostWordPool = lobbyRevision(room) > 0
    ? (Array.isArray(room.lobby_word_pool) ? room.lobby_word_pool : [])
    : (Array.isArray(room.lobby_word_pool) && room.lobby_word_pool.length > 0
      ? room.lobby_word_pool
      : (room.word_pool || []));
  const authoritativeLobbyReady = !authoritativeLobby || Boolean(buildAuthoritativeGameData(room));
  const lobbySyncBusy = lobbySyncPhase === "syncing" ||
    lobbySyncControllerRef.current.hasOptimisticChanges();
  const lobbySyncFailed = lobbySyncPhase === "error";
  const canPrepareMission = players.length >= 3 && spyCountIsValid && authoritativeLobbyReady &&
    !lobbySyncBusy && !lobbySyncFailed;

  const centerInViewport = (el) => {
    if (!el) return;
    if (scrollReturnRef.current === null) {
      scrollReturnRef.current = window.scrollY;
    }
    const doScroll = () => {
      const rect = el.getBoundingClientRect();
      const vv = window.visualViewport;
      const vh = vv?.height || window.innerHeight;
      const vOffset = vv?.offsetTop || 0;
      const targetY = window.scrollY + rect.top - vOffset - (vh - rect.height) / 2;
      window.scrollTo({ top: Math.max(0, targetY), behavior: "smooth" });
    };
    setTimeout(doScroll, 300);
    setTimeout(doScroll, 750);
    if (lockTimerRef.current) clearTimeout(lockTimerRef.current);
    lockTimerRef.current = setTimeout(() => {
      document.body.classList.add("room-scroll-locked");
      lockTimerRef.current = null;
    }, 900);
  };
  const restoreScroll = () => {
    if (lockTimerRef.current) {
      clearTimeout(lockTimerRef.current);
      lockTimerRef.current = null;
    }
    document.body.classList.remove("room-scroll-locked");
    const target = scrollReturnRef.current;
    if (target === null) return;
    scrollReturnRef.current = null;
    setTimeout(() => {
      window.scrollTo({ top: target, behavior: "smooth" });
    }, 400);
  };

  const glassStyle = {
    background: "linear-gradient(145deg, rgba(229,53,53,0.045), #0a0a0a 36%, #070707)",
    border: "1px solid #262626",
    borderRadius: 0,
    clipPath: "polygon(0 0, calc(100% - 10px) 0, 100% 10px, 100% 100%, 10px 100%, 0 calc(100% - 10px))",
    boxShadow: "0 10px 28px rgba(0,0,0,0.42), inset 0 1px 0 rgba(255,255,255,0.035)"
  };
  const sectionLabel = {
    fontSize: 11, letterSpacing: 3, color: "#aaa", marginBottom: 14,
    fontFamily: "monospace", display: "flex", alignItems: "center", gap: 8
  };

  if (room.status === "roulette") {
    const targetEmail = rouletteTarget?.email || room.roulette_target_email;
    return (
      <>
      <GameToastContainer />
      <div style={{ maxWidth: 480, margin: "0 auto", padding: "60px 20px" }}>
        <SyncStatusBanner state={syncState} t={t} />
        <div style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e" }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          <RouletteSpinner
            players={players}
            targetEmail={targetEmail}
            startedAt={room.intro_started_at}
            language={lang}
            onDone={handleRouletteDone}
          />
        </div>
      </div>
      </>);

  }

  if (room.status === "ready_voting") {
    return (
      <>
      <GameToastContainer />
      <div style={{ maxWidth: 580, margin: "0 auto", padding: "50px 20px" }}>
        <SyncStatusBanner state={syncState} t={t} />
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 32, fontFamily: "monospace", display: "flex", alignItems: "center", gap: 8 }}>
          <Link to={createPageUrl("Home")} style={{ color: "#e53535", textDecoration: "none" }}>{t('room_breadcrumb_home')}</Link>
          <span style={{ color: "#333" }}>//</span>
          <span>{t('room_breadcrumb_lobby')}</span>
          <span style={{ color: "#333" }}>//</span>
          <span>{room.code}</span>
        </motion.div>

        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}
          style={{ position: "relative", textAlign: "center", marginBottom: 36, padding: "32px 24px", background: "#0a0a0a", border: "1px solid #1e1e1e" }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#e53535", marginBottom: 16 }}>{t('ready_checking')}</div>
          <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 20, fontWeight: 700, letterSpacing: 2, marginBottom: 20 }}>{t('ready_are_you')}</div>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
            className={userReady ? "btn-red" : "btn-outline"}
            onClick={handleToggleReady}
            style={{ fontSize: 12, padding: "14px 0", width: "100%" }}>
            {userReady ? t('ready_yes') : t('ready_no')}
          </motion.button>
          <div style={{ marginTop: 20, fontSize: 11, color: "#444", letterSpacing: 2 }}>
            {readyPlayers.length} / {players.length} {t('ready_count')}
          </div>
        </motion.div>

        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
          style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 24, marginBottom: 16 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
          <div style={{ fontSize: 10, letterSpacing: 3, color: "#555", marginBottom: 16 }}>{t('ready_agents_status')}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {players.map((p, i) =>
              <motion.div key={p.email}
              initial={{ opacity: 0, x: -20 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: i * 0.06 }}
              style={{ display: "flex", alignItems: "center", gap: 12, padding: "10px 14px", background: "#080808", border: `1px solid ${readyPlayers.includes(p.email) ? "#e53535" : "#161616"}` }}>
                <span style={{ fontSize: 22 }}>{p.avatar || "🕵️"}</span>
                <span style={{ fontFamily: "monospace", fontSize: 12, letterSpacing: 1, flex: 1, color: "#ccc" }}>{p.name.toUpperCase()}</span>
                <span style={{ fontSize: 10, color: readyPlayers.includes(p.email) ? "#4ade80" : "#333", letterSpacing: 2 }}>
                  {readyPlayers.includes(p.email) ? t('ready_yes') : t('ready_waiting')}
                </span>
              </motion.div>
              )}
          </div>
        </motion.div>

        {isHost && allReady &&
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
          className="btn-red" style={{ width: "100%", fontSize: 12, padding: "15px 0" }}
          onClick={handleStartRoulette}
          disabled={starting || !authoritativeLobbyReady || lobbySyncBusy || lobbySyncFailed}>
            {starting ? t('room_starting') : t('room_start_btn')}
          </motion.button>
          }
        {isHost && (
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
            className="btn-ghost" style={{ width: "100%", fontSize: 11, padding: "13px 0", marginTop: 10 }}
            onClick={handleReturnToWaiting} disabled={starting}>
            ← {t('ready_back_to_lobby')}
          </motion.button>
        )}
      </div>
      </>);

  }

  return (
    <>
    <GameToastContainer />
    <style>{`
      .room-setup .dim-on-theme-focus{transition:opacity 0.35s ease,transform 0.35s ease,filter 0.35s ease;transform-origin:center}
      .room-setup:has(.theme-input:focus:not(:placeholder-shown)) .dim-on-theme-focus:not(.theme-block){opacity:0.2;transform:scale(0.94);filter:blur(2px);pointer-events:none}
      body.room-scroll-locked{overflow:hidden!important;touch-action:none!important;overscroll-behavior:none!important}
    `}</style>
    <div className="room-setup" style={{ maxWidth: 480, margin: "0 auto", padding: "40px 20px 80px" }}>
      <SyncStatusBanner state={syncState} t={t} />

      {/* Telegram-style spoiler dots animation */}
      <style>{`
        @keyframes spoiler-drift {
          0%   { transform: translate(0,0); opacity: 0.5; }
          50%  { opacity: 1; }
          100% { transform: translate(var(--dx), var(--dy)); opacity: 0.5; }
        }
        .spoiler-dot { position: absolute; width: 4px; height: 4px; background: #fff; border-radius: 50%; animation: spoiler-drift linear infinite; box-shadow: 0 0 4px rgba(255,255,255,0.7); }
      `}</style>

      {/* iOS room-access deck: code and QR share one compact mission card. */}
      <motion.section
        className="dim-on-theme-focus"
        initial={{ opacity: 0, y: 16 }}
        animate={{ opacity: 1, y: 0 }}
        aria-label={localize(lang, "Room access", "Доступ в комнату", "Доступ до кімнати")}
        style={{
          position: "relative",
          minHeight: 270,
          marginBottom: 14,
          overflow: "hidden",
          background: "linear-gradient(145deg, rgba(229,53,53,0.075), #0a0a0a 38%, #060606)",
          border: "1px solid #282828",
          clipPath: "polygon(0 0, calc(100% - 12px) 0, 100% 12px, 100% 100%, 12px 100%, 0 calc(100% - 12px))",
          boxShadow: "0 12px 30px rgba(0,0,0,0.42), 0 0 20px rgba(229,53,53,0.06)",
        }}>
        <div style={{ position: "absolute", top: 0, left: 18, width: 58, height: 2, background: "#e53535", zIndex: 4 }} />

        <div style={{ height: 42, padding: "0 18px", display: "flex", alignItems: "center", gap: 8, borderBottom: "1px solid #1d1d1d", fontFamily: "monospace", fontSize: 9, fontWeight: 700, letterSpacing: 1.4 }}>
          <span style={{ color: "#e53535" }}>//</span>
          <span style={{ color: "rgba(255,255,255,0.58)" }}>{localize(lang, "ROOM ACCESS", "ДОСТУП В КОМНАТУ", "ДОСТУП ДО КІМНАТИ")}</span>
          <span style={{ marginLeft: "auto", width: 6, height: 6, borderRadius: "50%", background: "#e53535", boxShadow: "0 0 6px rgba(229,53,53,.7)" }} />
          <span style={{ color: "rgba(255,255,255,0.42)" }}>{String(players.length).padStart(2, "0")}</span>
        </div>

        <AnimatePresence mode="wait" initial={false}>
          {roomAccessPage === 0 ? (
            <motion.div key="room-code" initial={{ opacity: 0, x: -16 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: 16 }} transition={{ duration: 0.22 }}
              style={{ height: 194, padding: "14px 18px 28px", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", textAlign: "center" }}>
              <div style={{ fontSize: 9, letterSpacing: 2.2, color: "#666", fontFamily: "monospace", marginBottom: 4 }}>{t('room_code_label')}</div>
              <button
                type="button"
                onClick={() => setCodeSpoiled(v => !v)}
                aria-label={codeSpoiled
                  ? localize(lang, `Room code ${room.code}. Hide`, `Код комнаты ${room.code}. Скрыть`, `Код кімнати ${room.code}. Сховати`)
                  : localize(lang, "Reveal room code", "Показать код комнаты", "Показати код кімнати")}
                style={{ position: "relative", width: "100%", minHeight: 74, border: 0, background: "transparent", cursor: "pointer", padding: "4px 12px", color: "inherit" }}>
                <motion.div animate={{ opacity: codeSpoiled ? 1 : 0, scale: codeSpoiled ? 1 : 0.9 }} transition={{ duration: 0.45, ease: [0.4, 0, 0.2, 1] }}>
                  <GlitchText key={codeSpoiled ? 'shown' : 'hidden'} text={room.code} style={{ fontSize: 42, fontWeight: 700, letterSpacing: 8, color: "#e53535", display: "block" }} speed={30} />
                </motion.div>
                <AnimatePresence>
                  {!codeSpoiled && (
                    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, scale: 1.35, filter: "blur(4px)" }}
                      style={{ position: "absolute", inset: "5px 12%", overflow: "hidden", pointerEvents: "none" }}>
                      {spoilerDots.map((dot) => {
                        /** @type {import("react").CSSProperties & Record<`--${string}`, string | number>} */
                        const dotStyle = { left: `${dot.left}%`, top: `${dot.top}%`, animationDuration: `${dot.duration}s`, animationDelay: `${dot.delay}s`, '--dx': `${dot.dx}px`, '--dy': `${dot.dy}px` };
                        return <span key={dot.id} className="spoiler-dot" style={dotStyle} />;
                      })}
                    </motion.div>
                  )}
                </AnimatePresence>
              </button>
              <div style={{ fontSize: 8.5, letterSpacing: 1.4, color: "#666", fontFamily: "monospace", marginBottom: 10 }}>
                {codeSpoiled
                  ? localize(lang, "TAP TO HIDE", "ТАП ЧТОБЫ СКРЫТЬ", "НАТИСНІТЬ, ЩОБ СХОВАТИ")
                  : localize(lang, "TAP TO REVEAL", "ТАП ЧТОБЫ ПОКАЗАТЬ", "НАТИСНІТЬ, ЩОБ ПОКАЗАТИ")}
              </div>
              <motion.button type="button" whileTap={{ scale: 0.96 }} onClick={copyCode}
                style={{ minWidth: 184, height: 34, display: "flex", alignItems: "center", justifyContent: "center", gap: 8, background: copied ? "rgba(229,53,53,.11)" : "rgba(255,255,255,.035)", border: `1px solid ${copied ? "rgba(229,53,53,.72)" : "#292929"}`, color: copied ? "#e53535" : "#aaa", cursor: "pointer", fontSize: 9, letterSpacing: 1.8, fontFamily: "monospace", fontWeight: 700 }}>
                {copied ? <Check size={12} /> : <Copy size={12} />}
                {copied ? t('room_copied') : t('room_copy')}
              </motion.button>
            </motion.div>
          ) : (
            <motion.div key="room-qr" initial={{ opacity: 0, x: 16 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -16 }} transition={{ duration: 0.22 }}
              style={{ height: 194, padding: "4px 14px 28px", perspective: 1200 }}>
              <motion.button
                type="button"
                onClick={() => setQrFlipped(v => !v)}
                animate={{ rotateY: qrFlipped ? 180 : 0 }}
                transition={{ duration: 0.58, ease: [0.4, 0, 0.2, 1] }}
                aria-label={qrFlipped
                  ? localize(lang, "Reveal room QR", "Показать QR комнаты", "Показати QR-код кімнати")
                  : localize(lang, "Hide room QR", "Скрыть QR комнаты", "Сховати QR-код кімнати")}
                style={{ position: "relative", width: "100%", height: "100%", padding: 0, border: 0, background: "transparent", color: "inherit", cursor: "pointer", transformStyle: "preserve-3d" }}>
                <div style={{ position: "absolute", inset: 0, backfaceVisibility: "hidden", WebkitBackfaceVisibility: "hidden", display: "flex", alignItems: "center", justifyContent: "center" }}>
                  <QRInvite roomId={room.id} roomCode={room.code} embedded />
                </div>
                <div style={{ position: "absolute", inset: 0, backfaceVisibility: "hidden", WebkitBackfaceVisibility: "hidden", transform: "rotateY(180deg)", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 8 }}>
                  <QrCode size={38} style={{ color: "#fff", opacity: 0.74 }} />
                  <div style={{ fontSize: 13, letterSpacing: 3, color: "#aaa", fontFamily: "'Rajdhani', sans-serif", fontWeight: 700 }}>{localize(lang, "QR HIDDEN", "QR СКРЫТ", "QR-КОД СХОВАНО")}</div>
                  <div style={{ fontSize: 9, letterSpacing: 1.8, color: "#555", fontFamily: "monospace" }}>{localize(lang, "TAP TO FLIP", "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ", "НАТИСНІТЬ, ЩОБ ПЕРЕГОРНУТИ")}</div>
                </div>
              </motion.button>
            </motion.div>
          )}
        </AnimatePresence>

        <div style={{ position: "absolute", left: 0, right: 0, bottom: 9, display: "flex", alignItems: "center", justifyContent: "center", gap: 9, zIndex: 5 }}>
          {[0, 1].map((page) => (
            <button key={page} type="button" onClick={() => setRoomAccessPage(page)} aria-label={page === 0
              ? localize(lang, "Code page", "Страница кода", "Сторінка коду")
              : localize(lang, "QR page", "Страница QR", "Сторінка QR")}
              style={{ width: roomAccessPage === page ? 18 : 6, height: 6, padding: 0, border: 0, borderRadius: 99, background: roomAccessPage === page ? "#e53535" : "#3a3a3a", cursor: "pointer", transition: "all .2s ease" }} />
          ))}
        </div>
      </motion.section>

      {/* Game Mode */}
      {isHost &&
        <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.04 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={sectionLabel}>
            <span>⚙️</span> {localize(lang, "GAME MODE", "РЕЖИМ ИГРЫ", "РЕЖИМ ГРИ")}
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            {[
            { mode: "questions", label: localize(lang, "QUESTIONS", "ВОПРОСЫ", "ЗАПИТАННЯ"), icon: "?" },
            { mode: "associations", label: localize(lang, "ASSOCIATIONS", "АССОЦИАЦИИ", "АСОЦІАЦІЇ"), icon: "💭" }].
            map(({ mode, label, icon }) => {
              const active = syncedGameMode === mode;
              return (
                <motion.button key={mode} whileHover={starting ? {} : { scale: 1.02 }} whileTap={starting ? {} : { scale: 0.98 }}
                onClick={() => updateGameMode(mode)}
                disabled={starting}
                style={{
                  padding: "14px 0", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6,
                  background: active ? "#e53535" : "transparent",
                  border: `1px solid ${active ? "#e53535" : "#333"}`,
                  borderRadius: 8, cursor: starting ? "default" : "pointer", transition: "all 0.2s",
                  color: active ? "#fff" : "#666", opacity: starting ? 0.72 : 1
                }}>
                  <span style={{ fontSize: 20, color: active ? "rgba(255,255,255,0.7)" : "#555" }}>{icon}</span>
                  <span style={{ fontSize: 11, letterSpacing: 2, fontFamily: "monospace", fontWeight: 700 }}>{label}</span>
                </motion.button>);

            })}
          </div>
        </motion.div>
        }

      {/* Game Mode Display for Players */}
      {!isHost &&
        <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.04 }}
        style={{ ...glassStyle, padding: "18px 24px", marginBottom: 14, textAlign: "center" }}>
          <div style={{ ...sectionLabel, justifyContent: "center", marginBottom: 10 }}>
            <span>⚙️</span> {localize(lang, "MODE", "РЕЖИМ", "РЕЖИМ")}
          </div>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
            <span style={{ fontSize: 20 }}>{syncedGameMode === "questions" ? "❓" : "💭"}</span>
            <span style={{ fontSize: 16, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, letterSpacing: 2, color: "#e53535" }}>
              {syncedGameMode === "questions"
                ? localize(lang, "QUESTIONS", "ВОПРОСЫ", "ЗАПИТАННЯ")
                : localize(lang, "ASSOCIATIONS", "АССОЦИАЦИИ", "АСОЦІАЦІЇ")}
            </span>
          </div>
        </motion.div>
        }

      {/* Public multi-spy setup. Host writes; every other client renders the authoritative value. */}
      <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
        <div style={{ ...sectionLabel, marginBottom: 8 }}>
          <span>🕵️</span> {t("room_spy_count_label")}
          {!isHost && <span style={{ marginLeft: "auto", color: "#555", fontSize: 9 }}>{t("room_host_controls")}</span>}
        </div>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 12 }}>
          <span style={{ color: "#666", fontSize: 10, letterSpacing: 1 }}>{t("room_spy_count_hint")}</span>
          <strong style={{ color: "#e53535", fontFamily: "'Rajdhani', sans-serif", fontSize: 26 }}>{selectedSpyCount}</strong>
        </div>
        <div style={{ position: "relative", paddingBottom: 4 }}>
          <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
          <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${maxSpyCount > 1 ? ((Math.min(selectedSpyCount, maxSpyCount) - 1) / (maxSpyCount - 1)) * 100 : 0}%`, pointerEvents: "none" }} />
          <input
            type="range"
            min={1}
            max={maxSpyCount}
            step={1}
            value={Math.min(selectedSpyCount, maxSpyCount)}
            onChange={(event) => updateSpyCount(Number(event.target.value))}
            disabled={!isHost || starting || maxSpyCount === 1}
            aria-label={t("room_spy_count_label")}
            className="spy-slider"
            style={{ position: "relative", zIndex: 1, opacity: !isHost || maxSpyCount === 1 ? 0.45 : 1 }}
          />
        </div>
        <div style={{ display: "flex", justifyContent: "space-between", color: "#444", fontFamily: "monospace", fontSize: 9, marginTop: 6 }}>
          <span>1</span><span>{maxSpyCount}</span>
        </div>
        {!spyCountIsValid && (
          <div role="alert" style={{ color: "#fbbf24", fontSize: 10, marginTop: 10 }}>{t("room_spy_count_invalid")}</div>
        )}
        <button
          type="button"
          role="switch"
          aria-checked={spiesKnowEachOther}
          onClick={() => updateSpiesKnowEachOther(!spiesKnowEachOther)}
          disabled={!isHost || starting}
          style={{
            width: "100%", marginTop: 16, padding: "12px 14px", display: "flex", alignItems: "center", gap: 12,
            border: `1px solid ${spiesKnowEachOther ? "rgba(229,53,53,0.65)" : "#242424"}`,
            background: spiesKnowEachOther ? "rgba(229,53,53,0.08)" : "#080808",
            color: isHost ? "#aaa" : "#666", cursor: isHost ? "pointer" : "default", textAlign: "left",
          }}>
          <span aria-hidden="true" style={{ color: spiesKnowEachOther ? "#e53535" : "#555", fontSize: 18 }}>
            {spiesKnowEachOther ? "●" : "○"}
          </span>
          <span style={{ display: "grid", gap: 3 }}>
            <strong style={{ color: spiesKnowEachOther ? "#fff" : "#888", fontSize: 10, letterSpacing: 1.5 }}>{t("room_spies_know_label")}</strong>
            <span style={{ fontSize: 9, lineHeight: 1.4 }}>{t(spiesKnowEachOther ? "room_spies_know_on" : "room_spies_know_off")}</span>
          </span>
        </button>
      </motion.div>

      {/* Players */}
      <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
        <div style={sectionLabel}>
          <span>👥</span> {localize(lang, "PLAYERS", "ИГРОКИ", "ГРАВЦІ")} ({players.length} / 3+)
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {players.map((p, i) =>
            <motion.div key={p.email}
            initial={{ opacity: 0, x: -20 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: i * 0.05 }}
            style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 14px", background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.06)", borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: "#444", fontFamily: "monospace", minWidth: 16, textAlign: "center" }}>{i + 1}</div>
              <span style={{ fontSize: 24 }}>{p.avatar || "🕵️"}</span>
              <span style={{ fontFamily: "monospace", fontSize: 13, letterSpacing: 1, flex: 1, color: "#eee" }}>{p.name.toUpperCase()}</span>
              {p.email === room.host_email &&
              <span style={{ fontSize: 9, fontWeight: 700, color: "#e53535", background: "rgba(229,53,53,0.1)", border: "1px solid rgba(229,53,53,0.3)", padding: "3px 10px", letterSpacing: 2, borderRadius: 4 }}>{t('room_host')}</span>
              }
              {p.email === user.email && p.email !== room.host_email &&
              <span style={{ fontSize: 9, color: "#555", letterSpacing: 2 }}>{t('room_you')}</span>
              }
            </motion.div>
            )}
        </div>
        {players.length < 3 &&
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
          style={{ marginTop: 14, padding: "10px 14px", background: "rgba(229,53,53,0.05)", border: "1px solid rgba(229,53,53,0.2)", borderRadius: 8, fontSize: 12, color: "#e53535", letterSpacing: 0.5 }}>
            {t('room_need_more')} {3 - players.length} {3 - players.length > 1 ? t('room_more_players') : t('room_more_player')}
          </motion.div>
          }
      </motion.div>

      {/* Host controls — Theme card (glass) */}
      {isHost && authoritativeLobby &&
        <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.08 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={{
            ...sectionLabel,
            color: lobbySyncFailed ? "#e53535" : lobbySyncBusy ? "#fbbf24" : "#4ade80",
          }}>
            <span>{lobbySyncFailed ? "!" : lobbySyncBusy ? "↻" : "✓"}</span>{" "}
            {lobbySyncFailed
              ? localize(lang, "LOBBY SYNC FAILED", "ОШИБКА СИНХРОНИЗАЦИИ", "ПОМИЛКА СИНХРОНІЗАЦІЇ")
              : lobbySyncBusy
                ? localize(lang, "SYNCING LOBBY...", "СИНХРОНИЗАЦИЯ...", "СИНХРОНІЗАЦІЯ ЛОБІ...")
                : localize(lang, "LOBBY SETTINGS SYNCED", "ПАРАМЕТРЫ СИНХРОНИЗИРОВАНЫ", "НАЛАШТУВАННЯ СИНХРОНІЗОВАНО")}
          </div>
          <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 18, fontWeight: 700, letterSpacing: 1.5, color: "#eee", marginBottom: 6 }}>
            {(room.lobby_category || room.lobby_source_name || room.lobby_theme || "CLASSIC").toUpperCase()}
          </div>
          <div style={{ color: "#666", fontSize: 10, lineHeight: 1.6, letterSpacing: 1 }}>
            {wordSource.toUpperCase()} · REV {lobbyRevision(room)}
          </div>
          {lobbySyncError && <div style={{ color: "#e53535", fontSize: 10, marginTop: 8 }}>{lobbySyncError}</div>}
        </motion.div>
        }

      {isHost &&
        <motion.div className="dim-on-theme-focus theme-block" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={{ display: "flex", alignItems: "center", marginBottom: 10 }}>
            <div style={{ fontSize: 11, letterSpacing: 3, color: "#aaa", display: "flex", alignItems: "center", gap: 8 }}>🎨 {t('room_theme_label')}</div>
          </div>
          <input
            className="theme-input"
            placeholder={t('room_theme_placeholder')}
            value={themeInput}
            onChange={(e) => handleThemeInputChange(e.target.value)}
            disabled={starting}
            onFocus={(e) => handleThemeInputFocus(e.target)}
            onBlur={handleThemeInputBlur}
            style={{ marginBottom: 10, fontSize: 14 }} />

          {/* Word count mode selector — visible when typing theme */}
          {customTheme.trim() && !themeAnalyzed &&
          <div style={{ marginBottom: 10 }}>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: wordCountMode === "custom" ? 10 : 0 }}>
              {[
                { mode: "recommended", label: localize(lang, "RECOMMENDED", "РЕКОМЕНДОВАНО", "РЕКОМЕНДОВАНО"), hint: localize(lang, "Auto", "Авто", "Авто") },
                { mode: "custom", label: localize(lang, "CUSTOM", "СВОЙ ВЫБОР", "ВЛАСНИЙ ВИБІР"), hint: `${customWordCount}` }
              ].map(({ mode, label, hint }) => {
                const active = wordCountMode === mode;
                return (
                  <button key={mode} onClick={() => handleWordCountModeChange(mode)} disabled={starting}
                    style={{
                      padding: "10px 0", display: "flex", flexDirection: "column", alignItems: "center", gap: 3,
                      background: active ? "rgba(229,53,53,0.1)" : "transparent",
                      border: `1px solid ${active ? "#e53535" : "#222"}`,
                      borderRadius: 8, cursor: "pointer", transition: "all 0.15s",
                      color: active ? "#e53535" : "#666", fontFamily: "monospace"
                    }}>
                    <span style={{ fontSize: 10, letterSpacing: 2, fontWeight: 700 }}>{label}</span>
                    <span style={{ fontSize: 9, color: active ? "#e53535" : "#444", letterSpacing: 1 }}>{hint}</span>
                  </button>
                );
              })}
            </div>

            {wordCountMode === "custom" &&
            <div style={{ background: "rgba(0,0,0,0.25)", border: "1px solid rgba(255,255,255,0.06)", borderRadius: 10, padding: "10px 14px" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                <span style={{ fontSize: 10, letterSpacing: 2, color: "#888", fontFamily: "monospace" }}>// {localize(lang, "COUNT", "КОЛИЧЕСТВО", "КІЛЬКІСТЬ")}</span>
                <span style={{ fontSize: 15, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: "#e53535" }}>{customWordCount}<span style={{ color: "#444", fontSize: 10 }}> / 80</span></span>
              </div>
              <div style={{ position: "relative", paddingBottom: 4 }}>
                <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
                <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${(customWordCount - 5) / 75 * 100}%`, pointerEvents: "none" }} />
                <input type="range" min={5} max={80} step={1} value={customWordCount}
                  onChange={(e) => handleCustomWordCountChange(Number(e.target.value))}
                  disabled={starting}
                  className="spy-slider" style={{ position: "relative", zIndex: 1 }} />
              </div>
            </div>
            }
          </div>
          }

          {
          <motion.button whileHover={customTheme.trim() ? { scale: 1.01 } : {}} whileTap={customTheme.trim() ? { scale: 0.99 } : {}}
          className="btn-outline"
          onClick={themeAnalyzed ? wordCount > themeMaxWords ? pushMax : generateTheme : handleAnalyze}
          disabled={starting || validating || !customTheme.trim()}
          style={{
            fontSize: 11, width: "100%", opacity: customTheme.trim() ? 1 : 0.4, marginBottom: 10, borderRadius: 10, clipPath: "none",
            ...(wordCount > themeMaxWords ? { color: "#fbbf24", borderColor: "#fbbf24", background: "rgba(251,191,36,0.05)" } : {})
          }}>
              {validating ? localize(lang, "ANALYZING...", "АНАЛИЗ...", "АНАЛІЗ...") :
            wordCount > themeMaxWords ? localize(lang, "⚡ SQUEEZE MORE", "⚡ ВЫЖАТЬ БОЛЬШЕ", "⚡ ЗНАЙТИ БІЛЬШЕ") :
            wordPool.length > 0 ? t('room_regenerate') :
            themeAnalyzed ? localize(lang, "✨ GENERATE", "✨ ГЕНЕРИРОВАТЬ", "✨ ЗГЕНЕРУВАТИ") :
            localize(lang, "🔍 ANALYZE", "🔍 АНАЛИЗ", "🔍 АНАЛІЗУВАТИ")}
            </motion.button>
          }
          {themeError &&
          <div style={{ marginBottom: 10, fontSize: 13, color: "#e53535", letterSpacing: 0.5 }}>{themeError}</div>
          }
          {/* Word pack selector */}
          {!customTheme.trim() &&
          <div style={{ marginBottom: 12 }}>
              <WordPackSelector
              selectedPackId={selectedPackId}
              disabled={starting}
              onSelect={handleWordPackSelect} />
            
            </div>
          }

          {/* Sliders */}
          <style>{`
            .spy-slider { appearance: none; -webkit-appearance: none; width: 100%; height: 2px; outline: none; cursor: pointer; border: none !important; padding: 0 !important; background: transparent !important; }
            .spy-slider::-webkit-slider-runnable-track { height: 2px; border-radius: 0; }
            .spy-slider::-webkit-slider-thumb { appearance: none; -webkit-appearance: none; width: 14px; height: 14px; background: #e53535; border: 2px solid #e53535; border-radius: 0; cursor: pointer; margin-top: -6px; box-shadow: 0 0 8px rgba(229,53,53,0.5); transition: box-shadow 0.15s, background 0.15s, border-color 0.15s; }
            .spy-slider::-webkit-slider-thumb:hover { box-shadow: 0 0 14px rgba(229,53,53,0.8); }
            .spy-slider::-moz-range-thumb { width: 14px; height: 14px; background: #e53535; border: 2px solid #e53535; border-radius: 0; cursor: pointer; box-shadow: 0 0 8px rgba(229,53,53,0.5); transition: background 0.15s, border-color 0.15s; }
            .spy-slider.max-zone::-webkit-slider-thumb { background: #fbbf24; border-color: #fbbf24; box-shadow: 0 0 12px rgba(251,191,36,0.7); }
            .spy-slider.max-zone::-moz-range-thumb { background: #fbbf24; border-color: #fbbf24; box-shadow: 0 0 12px rgba(251,191,36,0.7); }
          `}</style>
          {/* Words slider — only after theme is analyzed */}
          {customTheme.trim() && themeAnalyzed &&
          <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}
          style={{ marginTop: 14, padding: "14px 16px", background: "#060606", border: "1px solid #1a1a1a" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                <span style={{ fontSize: 10, letterSpacing: 3, color: "#555", fontFamily: "monospace" }}>{t('room_words_label')}</span>
                <span style={{ fontSize: 16, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: wordCount > themeMaxWords ? "#fbbf24" : "#e53535" }}>
                  {wordCount > themeMaxWords ? "+MAX" : wordCount}<span style={{ color: "#444", fontSize: 11 }}> / {themeMaxWords}</span>
                </span>
              </div>
              <div style={{ fontSize: 9, color: "#666", fontFamily: "monospace", letterSpacing: 1, marginBottom: 10 }}>
                {localize(lang, `theme: ${generatedCategory} · max ${themeMaxWords}`, `тема: ${generatedCategory} · макс ${themeMaxWords}`, `тема: ${generatedCategory} · макс. ${themeMaxWords}`)}
              </div>
              {(() => {
              const sliderMax = themeMaxWords + 1;
              const totalRange = sliderMax - 10;
              const fillPct = totalRange > 0 ? (wordCount - 10) / totalRange * 100 : 0;
              const maxZonePct = totalRange > 0 ? (themeMaxWords - 10) / totalRange * 100 : 100;
              const inMaxZone = wordCount > themeMaxWords;
              return (
                <div style={{ position: "relative", paddingBottom: 4 }}>
                    <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
                    <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: inMaxZone ? "#fbbf24" : "#e53535", width: `${fillPct}%`, pointerEvents: "none", transition: "width 0.1s, background 0.15s" }} />
                    <div style={{
                    position: "absolute", top: "50%", left: `${maxZonePct}%`,
                    transform: "translate(4px, -50%)",
                    fontSize: 8, letterSpacing: 1, fontFamily: "monospace", fontWeight: 700,
                    color: inMaxZone ? "#fbbf24" : "#555",
                    pointerEvents: "none", transition: "color 0.15s", lineHeight: 1, whiteSpace: "nowrap"
                  }}>+MAX</div>
                    <input type="range" min={10} max={sliderMax} step={1} value={wordCount}
                  onChange={(e) => handleSelectedWordCountChange(Number(e.target.value))}
                  disabled={starting}
                  className={`spy-slider${inMaxZone ? " max-zone" : ""}`} style={{ position: "relative", zIndex: 1 }} />
                  </div>);

            })()}
            </motion.div>
          }

          {!customTheme.trim() && !selectedPackId &&
          <div style={{ fontSize: 12, color: "#888", letterSpacing: 0.5, marginTop: 10 }} className="hidden">{t('room_empty_theme')}</div>
          }
          {wordPool.length > 0 &&
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
          style={{ marginTop: 14, padding: 16, background: "#060606", border: "1px solid #1a1a1a" }}>
              <WordPoolManager pool={wordPool} isHost={isHost && !starting} onUpdate={handlePoolUpdate} />
            </motion.div>
          }

          {/* Save as WordPack — when host generated/edited a pool with a custom theme */}
          {wordPool.length >= 2 && customTheme.trim() &&
          <motion.button
            initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
            whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
            onClick={() => setShowSavePackDialog(true)}
            style={{
              marginTop: 10, width: "100%", padding: "12px 0",
              background: "transparent", border: "1px dashed rgba(74,222,128,0.3)",
              borderRadius: 8, cursor: "pointer",
              color: "#4ade80", fontSize: 11, letterSpacing: 2, fontFamily: "monospace", fontWeight: 700,
              transition: "all 0.15s"
            }}
            onMouseEnter={(e) => {e.currentTarget.style.borderColor = "rgba(74,222,128,0.6)";e.currentTarget.style.background = "rgba(74,222,128,0.05)";}}
            onMouseLeave={(e) => {e.currentTarget.style.borderColor = "rgba(74,222,128,0.3)";e.currentTarget.style.background = "transparent";}}>
              💾 {localize(lang, "SAVE AS WORD PACK", "СОХРАНИТЬ КАК WORDPACK", "ЗБЕРЕГТИ ЯК НАБІР СЛІВ")}
            </motion.button>
          }
        </motion.div>
        }

      {/* Duration — separate glass card */}
      {isHost &&
        <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.15 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 24 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
            <span style={{ fontSize: 11, letterSpacing: 3, color: "#aaa", fontFamily: "monospace", display: "flex", alignItems: "center", gap: 8 }}>
              ⏱ {t('room_duration_label')}
            </span>
            <span style={{ fontSize: 22, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: "#e53535" }}>
              {gameDuration} min
            </span>
          </div>
          <div style={{ position: "relative", paddingBottom: 4 }}>
            <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "rgba(255,255,255,0.08)", pointerEvents: "none" }} />
            <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${(gameDuration - 1) / (15 - 1) * 100}%`, pointerEvents: "none", boxShadow: "0 0 8px rgba(229,53,53,0.6)" }} />
            <input type="range" min={1} max={15} step={1} value={gameDuration}
            onChange={(e) => updateGameDuration(Number(e.target.value))}
            disabled={starting}
            className="spy-slider" style={{ position: "relative", zIndex: 1 }} />
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 10, color: "#2a2a2a", fontFamily: "monospace", marginTop: 6 }}>
            <span>1 min</span><span>15 min</span>
          </div>
        </motion.div>
        }

      <SaveAsWordPackDialog
          open={showSavePackDialog}
          onClose={() => setShowSavePackDialog(false)}
          defaultName={generatedCategory || customTheme.trim()}
          words={wordPool.filter((w) => w.enabled !== false).map((w) => w.word)}
          category={generatedCategory || customTheme.trim()}
          lang={locale.language}
          onSaved={() => {
            if (user) listWordPacks().then(setUserPacks).catch(() => {});
          }} />
        
      

      {!isHost && nonHostWordPool.length > 0 &&
         <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.15 }}
         style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <WordPoolManager pool={nonHostWordPool} isHost={false} onUpdate={() => {}} />
        </motion.div>
        }

      {/* Actions */}
      <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
        style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {isHost ?
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <motion.button whileHover={canPrepareMission ? { scale: 1.01 } : {}} whileTap={canPrepareMission ? { scale: 0.99 } : {}}
            className="btn-outline"
            style={{ fontSize: 11, padding: "16px 0", opacity: canPrepareMission ? 1 : 0.35, cursor: canPrepareMission ? "pointer" : "not-allowed", borderRadius: 10, clipPath: "none", letterSpacing: 3 }}
            onClick={handleBeginReadyCheck}
            disabled={!canPrepareMission || starting}>
              {t('room_ready_vote_btn')}
            </motion.button>
            <motion.button whileHover={canPrepareMission ? { scale: 1.01, boxShadow: "0 0 30px rgba(229,53,53,0.5)" } : {}} whileTap={canPrepareMission ? { scale: 0.99 } : {}}
            className="btn-red"
            style={{ fontSize: 11, padding: "16px 0", opacity: canPrepareMission ? 1 : 0.35, cursor: canPrepareMission ? "pointer" : "not-allowed", borderRadius: 10, clipPath: "none", letterSpacing: 3, boxShadow: canPrepareMission ? "0 0 20px rgba(229,53,53,0.3)" : "none" }}
            onClick={handleStartRoulette}
            disabled={!canPrepareMission || starting || validating}>
              {starting ? t('room_starting') : `🎯 ${t('room_start_btn')}`}
            </motion.button>
          </div> :

          <div style={{ ...glassStyle, padding: "16px", textAlign: "center", fontSize: 12, color: "#888", letterSpacing: 1, fontFamily: "monospace" }}>
            <motion.span animate={{ opacity: [1, 0.4, 1] }} transition={{ duration: 2, repeat: Infinity }}>
              ⏳ {t('room_waiting_host')}
            </motion.span>
          </div>
          }
        <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-ghost" onClick={handleLeave} style={{ fontSize: 11, padding: "14px 0" }}>
          ← {isHost ? t('room_close') : t('room_leave')}
        </motion.button>
      </motion.div>
    </div>
    </>);

}

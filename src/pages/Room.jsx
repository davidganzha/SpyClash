import { useState, useEffect, useRef, useMemo } from "react";
import { generateWordPool } from "@/utils/wordPoolAI";
import { useGlobalQuota } from "@/hooks/useGlobalQuota";
import { Check, Copy, QrCode } from "lucide-react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { Link, useNavigate } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import GlitchText from "../components/ui/GlitchText";
import WordPoolManager from "../components/WordPoolManager";
import RouletteSpinner from "../components/RouletteSpinner";
import GameToastContainer, { gameToast } from "../components/GameToast";
import { useGameSounds } from "../components/useGameSounds";
import { useLanguage } from "@/components/LanguageContext";
import QRInvite from "../components/QRInvite";
import WordPackSelector from "../components/WordPackSelector";
import SaveAsWordPackDialog from "../components/SaveAsWordPackDialog";
import { useMembership } from "@/lib/MembershipContext";
import { accountAvatarForDisplay } from "@/lib/avatars";
import { listWordPacks } from "@/lib/wordPackActions";
import {
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



export default function Room() {
  const { t, locale } = useLanguage();
  const { hasResolvedMembership } = useMembership();
  const [room, setRoom] = useState(null);
  const [user, setUser] = useState(null);
  const [starting, setStarting] = useState(false);
  const [syncState, setSyncState] = useState("connected");
  const [copied, setCopied] = useState(false);
  const [customTheme, setCustomTheme] = useState("");
  const [themeError, setThemeError] = useState("");
  const [validating, setValidating] = useState(false);
  const [wordPool, setWordPool] = useState([]);
  const generatedPoolRef = useRef([]);
  const [generatedCategory, setGeneratedCategory] = useState("");
  const [wordCount, setWordCount] = useState(25);
  const [gameDuration, setGameDuration] = useState(10);
  const [showRoulette, setShowRoulette] = useState(false);
  const [rouletteTarget, setRouletteTarget] = useState(null);
  const [selectedPackId, setSelectedPackId] = useState(null);
  const [userPacks, setUserPacks] = useState([]);
  const [gameMode, setGameMode] = useState("questions"); // "questions" | "associations"
  const [showSavePackDialog, setShowSavePackDialog] = useState(false);
  const [themeAnalyzed, setThemeAnalyzed] = useState(false);
  const [themeMaxWords, setThemeMaxWords] = useState(100);
  const [wordCountMode, setWordCountMode] = useState("recommended"); // "recommended" | "custom"
  const [customWordCount, setCustomWordCount] = useState(25);
  const [codeSpoiled, setCodeSpoiled] = useState(false);
  const [qrFlipped, setQrFlipped] = useState(true);
  const [roomAccessPage, setRoomAccessPage] = useState(0);
  const scrollReturnRef = useRef(null);
  const lockTimerRef = useRef(null);
  const rouletteCompletionKeyRef = useRef(null);
  const durationUpdateTimerRef = useRef(null);
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
  const unsubRef = useRef(null);
  const prevPlayersRef = useRef([]);
  const sounds = useGameSounds();
  const quota = useGlobalQuota();
  const { increment } = quota;

  // Sync gameMode from room
  const syncedGameMode = room?.game_mode || "questions";

  const getRoomId = () => new URLSearchParams(window.location.search).get("id");
  const id = getRoomId();

  useEffect(() => {
    if (!hasResolvedMembership) return;
    const id = new URLSearchParams(window.location.search).get("id");
    if (id) localStorage.setItem("spy_active_room_id", id);

    let mounted = true;
    base44.auth.me().then((u) => {
      if (!mounted) return;
      if (!u) {base44.auth.redirectToLogin(window.location.href);return;}
      setUser(u);
      loadRoom(u);
      // Load user's word packs for selector
      listWordPacks().then(setUserPacks).catch(() => {});
    }).catch(() => navigate(createPageUrl("Home")));
    return () => {
      mounted = false;
      unsubRef.current?.();
      if (durationUpdateTimerRef.current) clearTimeout(durationUpdateTimerRef.current);
    };
  }, [hasResolvedMembership]);

  const loadRoom = async (u) => {
    const id = getRoomId();
    if (!id) {navigate(createPageUrl("Home"));return;}
    let room = await getGameRoom(id);
    if (!room) {navigate(createPageUrl("Home"));return;}

    // Auto-restore finished room to waiting if players still there
    if (room.status === "finished" && room.host_email === u.email && (room.players || []).length > 0) {
      room = await runGameRoomAction("reset_room_for_replay", id);
    }

    const alreadyIn = (room.players || []).some((p) => p.email === u.email);
    if (room.status === "waiting") {
      const displayName = u.display_name || u.full_name || u.email.split("@")[0];
      const avatar = accountAvatarForDisplay(u.avatar);
      room = await joinGameRoom({ roomId: id, player: { name: displayName, avatar } });
    }
    // Initialize game_mode if not set
    if (!room.game_mode) {
      room = await runGameRoomAction("update_game_mode", id, { mode: "questions" });
    }
    const finalRoom = room;
    prevPlayersRef.current = finalRoom.players || [];
    setRoom(finalRoom);
    if (finalRoom.status === "playing") {navigate(createPageUrl("Game") + `?id=${id}`);return;}

    unsubRef.current = subscribeGameRoom(id, async (evt) => {
      if (evt.id !== id) return;
      if (evt.type === "sync") {
        setSyncState(evt.state);
        return;
      }
      if (evt.type === "delete") {navigate(createPageUrl("Home"));return;}
      let newRoom = evt.data;
      if (!newRoom) newRoom = await getGameRoom(id);
      if (!newRoom) return;

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

      setRoom(newRoom);
      setSyncState("connected");
      console.log('Room updated via realtime channel, game_mode:', newRoom.game_mode);
      if (newRoom.status === "playing") {
        gameToast(t('room_toast_game_starting'), "round", "🎯");
        sounds.roundStart();
        navigate(createPageUrl("Game") + `?id=${id}`);
      }
    });

  };

  useEffect(() => {
    if (!room?.game_duration_seconds) return;
    setGameDuration(gameDurationMinutes(room));
  }, [room?.game_duration_seconds]);

  const handleToggleReady = async () => {
    if (!room || !user) return;
    await runGameRoomAction("toggle_ready", room.id);
  };

  // Single-step: generate words directly, derive real max from actual result
  const handleAnalyze = async () => {
    if (!customTheme.trim()) return;
    setValidating(true);
    setThemeError("");
    // Target depends on mode: recommended = 100 (model picks real count), custom = user-chosen exact count
    const target = wordCountMode === "custom" ? customWordCount : 100;
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), target);
    } catch (error) {
      console.error("AI theme analysis failed", error);
      setThemeError(locale.language === 'ru'
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length || result.words.length < 5) {
      setThemeError(locale.language === 'ru' ? "Не удалось распознать тему. Попробуй другую." : "Couldn't recognize this theme. Try another.");
      return;
    }
    const realMax = result.words.length;
    const pool = result.words.map((w) => ({ word: w, enabled: true }));
    generatedPoolRef.current = pool;
    setThemeMaxWords(realMax);
    setWordCount(realMax);
    setWordPool(pool);
    setGeneratedCategory(result.display_category || customTheme.trim());
    setThemeAnalyzed(true);
    increment(result);
  };

  const generateTheme = async () => {
    if (!customTheme.trim()) return;
    setValidating(true);
    setThemeError("");
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), wordCount);
    } catch (error) {
      console.error("AI theme generation failed", error);
      setThemeError(locale.language === 'ru'
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length) {
      setThemeError(t('room_theme_error_empty'));
      return;
    }
    const pool = result.words.slice(0, wordCount).map((w) => ({ word: w, enabled: true }));
    generatedPoolRef.current = pool;
    setWordPool(pool);
    setGeneratedCategory(result.display_category || customTheme.trim());
    if (pool.length < themeMaxWords) {
      setThemeMaxWords(Math.max(10, pool.length));
      setWordCount(pool.length);
    }
    increment(result);
  };

  // Squeeze more words beyond current max
  const pushMax = async () => {
    if (!customTheme.trim() || validating) return;
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
      setThemeError(locale.language === 'ru'
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length) return;
    const existingLower = new Set(currentWords.map((w) => w.toLowerCase()));
    const additions = result.words.filter((w) => !existingLower.has(w.toLowerCase()));
    if (additions.length === 0) {
      setThemeError(locale.language === 'ru' ? "Больше уникальных слов найти не удалось." : "Couldn't find more unique words.");
      return;
    }
    const newPool = [...currentPool, ...additions.map((w) => ({ word: w, enabled: true }))].slice(0, 200);
    generatedPoolRef.current = newPool;
    setWordPool(newPool);
    setThemeMaxWords(newPool.length);
    setWordCount(newPool.length);
    increment(result);
  };

  const handlePoolUpdate = (updated) => {
    setWordPool(updated);
    if (customTheme.trim()) generatedPoolRef.current = updated;
  };

  const buildGameData = () => {
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

  const handleStartRoulette = async () => {
    if (!room) return;
    setStarting(true);
    const data = buildGameData();
    if (!data) {setThemeError(t('room_theme_error_empty'));setStarting(false);return;}
    const players = room.players || [];
    if (players.length < 3) {setThemeError(t('room_theme_error_min'));setStarting(false);return;}
    const spyIdx = Math.floor(Math.random() * players.length);
    const spyEmail = players[spyIdx].email;
    const firstAskerIdx = Math.floor(Math.random() * players.length);
    let firstAnswererIdx = (firstAskerIdx + 1) % players.length;
    const playerFeedback = players.map((p) => ({ email: p.email, likes: 0, dislikes: 0 }));
    const updateData = {
      status: "playing", spy_email: spyEmail,
      word: data.word, category: data.category, spy_guess: "", detective_votes: [], winner: "",
      current_asker_email: players[firstAskerIdx].email,
      current_answerer_email: players[firstAnswererIdx].email,
      questions_in_round: 0, round_number: 1,
      ready_players: [], current_answer: "",
      question_phase: "asking", player_feedback: playerFeedback,
      word_pool: data.finalPool, vote_requests: [], eliminated_emails: [],
      game_duration_seconds: gameDurationSeconds(gameDuration),
      game_mode: syncedGameMode
    };
    try {
      const armedRoom = await runGameRoomAction("arm_roulette", room.id, {
        roulette_target_email: players[firstAskerIdx].email,
        plan: updateData,
      });
      rouletteCompletionKeyRef.current = null;
      setRouletteTarget({ email: players[firstAskerIdx].email });
      setRoom(armedRoom);
    } catch (error) {
      console.error("Failed to arm synchronized roulette", error);
      setThemeError(error?.message || t('room_start_failed'));
      setStarting(false);
    }
  };

  const handleRouletteDone = async () => {
    if (!room || !user || room.status !== "roulette") return;
    if (!(room.players || []).some((player) => player.email === user.email)) return;

    const completionKey = `${room.id}:${room.intro_started_at || room.roulette_target_email || "intro"}`;
    if (rouletteCompletionKeyRef.current === completionKey) return;
    rouletteCompletionKeyRef.current = completionKey;
    setStarting(true);

    try {
      const completedRoom = await completeGameStartAfterIntro({
        room,
        refreshRoom: getGameRoom,
        completeStart: (currentRoom) => runGameRoomAction("complete_game_start", currentRoom.id),
      });
      setRoom(completedRoom);
      if (completedRoom?.status === "playing") {
        navigate(createPageUrl("Game") + `?id=${completedRoom.id}`);
      }
    } catch (error) {
      rouletteCompletionKeyRef.current = null;
      console.error("Failed to complete synchronized roulette", error);
      gameToast(error?.message || t('room_start_failed'), "warning", "⚠️");
    } finally {
      setStarting(false);
    }
  };

  const handleLeave = async () => {
    if (!room || !user) return;
    await leaveGameRoom(room.id);
    localStorage.removeItem("spy_active_room_id");
    localStorage.setItem("spy_return_to_online", "1");
    navigate(createPageUrl("Home"));
  };

  const copyCode = () => {
    navigator.clipboard.writeText(room.code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const updateGameMode = async (newMode) => {
    if (!room) return;
    try {
      const updated = await runGameRoomAction("update_game_mode", room.id, { mode: newMode });
      setRoom(updated);
    } catch (err) {
      console.error('Failed to update game mode:', err);
    }
  };

  const updateGameDuration = (minutes) => {
    if (!room) return;
    const normalizedMinutes = gameDurationMinutes({
      game_duration_seconds: gameDurationSeconds(minutes),
    });
    setGameDuration(normalizedMinutes);
    if (durationUpdateTimerRef.current) clearTimeout(durationUpdateTimerRef.current);

    durationUpdateTimerRef.current = setTimeout(async () => {
      try {
        const updated = await runGameRoomAction("update_game_duration", room.id, {
          game_duration_seconds: gameDurationSeconds(normalizedMinutes),
        });
        setRoom(updated);
      } catch (error) {
        console.error("Failed to synchronize game duration", error);
        setGameDuration(gameDurationMinutes(room));
        gameToast(t('room_duration_sync_failed'), "warning", "⚠️");
      }
    }, 250);
  };

  const handleReturnToWaiting = async () => {
    if (!room || room.host_email !== user?.email) return;
    try {
      const updated = await runGameRoomAction("return_to_waiting", room.id);
      setRoom(updated);
    } catch (error) {
      console.error("Failed to return room to waiting", error);
      gameToast(error?.message || t('room_return_waiting_failed'), "warning", "⚠️");
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


  const isHost = room.host_email === user.email;
  const players = room.players || [];
  const readyPlayers = room.ready_players || [];
  const allReady = players.length >= 3 && readyPlayers.length === players.length;
  const userReady = readyPlayers.includes(user?.email);

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
          <RouletteSpinner players={players} targetEmail={targetEmail} onDone={handleRouletteDone} />
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
          onClick={handleStartRoulette} disabled={starting}>
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
        aria-label={locale.language === 'ru' ? "Доступ в комнату" : "Room access"}
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
          <span style={{ color: "rgba(255,255,255,0.58)" }}>{locale.language === 'ru' ? "ДОСТУП В КОМНАТУ" : "ROOM ACCESS"}</span>
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
                aria-label={locale.language === 'ru' ? (codeSpoiled ? `Код комнаты ${room.code}. Скрыть` : "Показать код комнаты") : (codeSpoiled ? `Room code ${room.code}. Hide` : "Reveal room code")}
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
                {codeSpoiled ? (locale.language === 'ru' ? "ТАП ЧТОБЫ СКРЫТЬ" : "TAP TO HIDE") : (locale.language === 'ru' ? "ТАП ЧТОБЫ ПОКАЗАТЬ" : "TAP TO REVEAL")}
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
                aria-label={locale.language === 'ru' ? (qrFlipped ? "Показать QR комнаты" : "Скрыть QR комнаты") : (qrFlipped ? "Reveal room QR" : "Hide room QR")}
                style={{ position: "relative", width: "100%", height: "100%", padding: 0, border: 0, background: "transparent", color: "inherit", cursor: "pointer", transformStyle: "preserve-3d" }}>
                <div style={{ position: "absolute", inset: 0, backfaceVisibility: "hidden", WebkitBackfaceVisibility: "hidden", display: "flex", alignItems: "center", justifyContent: "center" }}>
                  <QRInvite roomId={room.id} roomCode={room.code} embedded />
                </div>
                <div style={{ position: "absolute", inset: 0, backfaceVisibility: "hidden", WebkitBackfaceVisibility: "hidden", transform: "rotateY(180deg)", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 8 }}>
                  <QrCode size={38} style={{ color: "#fff", opacity: 0.74 }} />
                  <div style={{ fontSize: 13, letterSpacing: 3, color: "#aaa", fontFamily: "'Rajdhani', sans-serif", fontWeight: 700 }}>{locale.language === 'ru' ? "QR СКРЫТ" : "QR HIDDEN"}</div>
                  <div style={{ fontSize: 9, letterSpacing: 1.8, color: "#555", fontFamily: "monospace" }}>{locale.language === 'ru' ? "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ" : "TAP TO FLIP"}</div>
                </div>
              </motion.button>
            </motion.div>
          )}
        </AnimatePresence>

        <div style={{ position: "absolute", left: 0, right: 0, bottom: 9, display: "flex", alignItems: "center", justifyContent: "center", gap: 9, zIndex: 5 }}>
          {[0, 1].map((page) => (
            <button key={page} type="button" onClick={() => setRoomAccessPage(page)} aria-label={page === 0 ? (locale.language === 'ru' ? "Страница кода" : "Code page") : (locale.language === 'ru' ? "Страница QR" : "QR page")}
              style={{ width: roomAccessPage === page ? 18 : 6, height: 6, padding: 0, border: 0, borderRadius: 99, background: roomAccessPage === page ? "#e53535" : "#3a3a3a", cursor: "pointer", transition: "all .2s ease" }} />
          ))}
        </div>
      </motion.section>

      {/* Game Mode */}
      {isHost &&
        <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.04 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={sectionLabel}>
            <span>⚙️</span> {locale.language === 'ru' ? "РЕЖИМ ИГРЫ" : "GAME MODE"}
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            {[
            { mode: "questions", label: locale.language === 'ru' ? "ВОПРОСЫ" : "QUESTIONS", icon: "?" },
            { mode: "associations", label: locale.language === 'ru' ? "АССОЦИАЦИИ" : "ASSOCIATIONS", icon: "💭" }].
            map(({ mode, label, icon }) => {
              const active = syncedGameMode === mode;
              return (
                <motion.button key={mode} whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
                onClick={() => updateGameMode(mode)}
                style={{
                  padding: "14px 0", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6,
                  background: active ? "#e53535" : "transparent",
                  border: `1px solid ${active ? "#e53535" : "#333"}`,
                  borderRadius: 8, cursor: "pointer", transition: "all 0.2s",
                  color: active ? "#fff" : "#666"
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
            <span>⚙️</span> {locale.language === 'ru' ? "РЕЖИМ" : "MODE"}
          </div>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
            <span style={{ fontSize: 20 }}>{syncedGameMode === "questions" ? "❓" : "💭"}</span>
            <span style={{ fontSize: 16, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, letterSpacing: 2, color: "#e53535" }}>
              {syncedGameMode === "questions" ? locale.language === 'ru' ? "ВОПРОСЫ" : "QUESTIONS" : locale.language === 'ru' ? "АССОЦИАЦИИ" : "ASSOCIATIONS"}
            </span>
          </div>
        </motion.div>
        }

      {/* Players */}
      <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
        <div style={sectionLabel}>
          <span>👥</span> {locale.language === 'ru' ? "ИГРОКИ" : "PLAYERS"} ({players.length} / 3+)
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
      {isHost &&
        <motion.div className="dim-on-theme-focus theme-block" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
        style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={{ display: "flex", alignItems: "center", marginBottom: 10 }}>
            <div style={{ fontSize: 11, letterSpacing: 3, color: "#aaa", display: "flex", alignItems: "center", gap: 8 }}>🎨 {t('room_theme_label')}</div>
          </div>
          <input
            className="theme-input"
            placeholder={t('room_theme_placeholder')}
            value={customTheme}
            onChange={(e) => {setCustomTheme(e.target.value);setWordPool([]);generatedPoolRef.current = [];setThemeError("");setThemeAnalyzed(false);setThemeMaxWords(100);}}
            onFocus={(e) => centerInViewport(e.target.closest('.theme-block'))}
            onBlur={restoreScroll}
            style={{ marginBottom: 10, fontSize: 14 }} />

          {/* Word count mode selector — visible when typing theme */}
          {customTheme.trim() && !themeAnalyzed &&
          <div style={{ marginBottom: 10 }}>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: wordCountMode === "custom" ? 10 : 0 }}>
              {[
                { mode: "recommended", label: locale.language === 'ru' ? "РЕКОМЕНДОВАНО" : "RECOMMENDED", hint: locale.language === 'ru' ? "Авто" : "Auto" },
                { mode: "custom", label: locale.language === 'ru' ? "СВОЙ ВЫБОР" : "CUSTOM", hint: `${customWordCount}` }
              ].map(({ mode, label, hint }) => {
                const active = wordCountMode === mode;
                return (
                  <button key={mode} onClick={() => setWordCountMode(mode)}
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
                <span style={{ fontSize: 10, letterSpacing: 2, color: "#888", fontFamily: "monospace" }}>// {locale.language === 'ru' ? "КОЛИЧЕСТВО" : "COUNT"}</span>
                <span style={{ fontSize: 15, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: "#e53535" }}>{customWordCount}<span style={{ color: "#444", fontSize: 10 }}> / 80</span></span>
              </div>
              <div style={{ position: "relative", paddingBottom: 4 }}>
                <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
                <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${(customWordCount - 5) / 75 * 100}%`, pointerEvents: "none" }} />
                <input type="range" min={5} max={80} step={1} value={customWordCount}
                  onChange={(e) => setCustomWordCount(Number(e.target.value))}
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
          disabled={validating || !customTheme.trim()}
          style={{
            fontSize: 11, width: "100%", opacity: customTheme.trim() ? 1 : 0.4, marginBottom: 10, borderRadius: 10, clipPath: "none",
            ...(wordCount > themeMaxWords ? { color: "#fbbf24", borderColor: "#fbbf24", background: "rgba(251,191,36,0.05)" } : {})
          }}>
              {validating ? locale.language === 'ru' ? "АНАЛИЗ..." : "ANALYZING..." :
            wordCount > themeMaxWords ? locale.language === 'ru' ? "⚡ ВЫЖАТЬ БОЛЬШЕ" : "⚡ SQUEEZE MORE" :
            wordPool.length > 0 ? t('room_regenerate') :
            themeAnalyzed ? locale.language === 'ru' ? "✨ ГЕНЕРИРОВАТЬ" : "✨ GENERATE" :
            locale.language === 'ru' ? "🔍 АНАЛИЗ" : "🔍 ANALYZE"}
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
              onSelect={(id) => setSelectedPackId(id)} />
            
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
                {locale.language === 'ru' ? `тема: ${generatedCategory} · макс ${themeMaxWords}` : `theme: ${generatedCategory} · max ${themeMaxWords}`}
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
                  onChange={(e) => {setWordCount(Number(e.target.value));setWordPool([]);}}
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
              <WordPoolManager pool={wordPool} isHost={isHost} onUpdate={handlePoolUpdate} />
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
              💾 {locale.language === 'ru' ? "СОХРАНИТЬ КАК WORDPACK" : "SAVE AS WORDPACK"}
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
        
      

      {!isHost && room.word_pool && room.word_pool.length > 0 &&
         <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.15 }}
         style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <WordPoolManager pool={room.word_pool} isHost={false} onUpdate={() => {}} />
        </motion.div>
        }

      {/* Actions */}
      <motion.div className="dim-on-theme-focus" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
        style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {isHost ?
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <motion.button whileHover={players.length >= 3 ? { scale: 1.01 } : {}} whileTap={players.length >= 3 ? { scale: 0.99 } : {}}
            className="btn-outline"
            style={{ fontSize: 11, padding: "16px 0", opacity: players.length >= 3 ? 1 : 0.35, cursor: players.length >= 3 ? "pointer" : "not-allowed", borderRadius: 10, clipPath: "none", letterSpacing: 3 }}
            onClick={() => runGameRoomAction("begin_ready_check", room.id)}
            disabled={players.length < 3 || starting}>
              {t('room_ready_vote_btn')}
            </motion.button>
            <motion.button whileHover={players.length >= 3 ? { scale: 1.01, boxShadow: "0 0 30px rgba(229,53,53,0.5)" } : {}} whileTap={players.length >= 3 ? { scale: 0.99 } : {}}
            className="btn-red"
            style={{ fontSize: 11, padding: "16px 0", opacity: players.length >= 3 ? 1 : 0.35, cursor: players.length >= 3 ? "pointer" : "not-allowed", borderRadius: 10, clipPath: "none", letterSpacing: 3, boxShadow: players.length >= 3 ? "0 0 20px rgba(229,53,53,0.3)" : "none" }}
            onClick={handleStartRoulette}
            disabled={players.length < 3 || starting || validating}>
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

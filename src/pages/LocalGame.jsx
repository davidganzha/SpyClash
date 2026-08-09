import { useState, useEffect, useRef } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import { base44 } from "@/api/base44Client";
import { useLanguage } from "@/components/LanguageContext";
import SpyGuessModal from "@/components/SpyGuessModal";
import GlitchText from "@/components/ui/GlitchText";
import { useGameSounds } from "@/components/useGameSounds";
import WordPackSelector from "@/components/WordPackSelector";
import RevealPoolCard from "@/components/RevealPoolCard";
import RouletteSpinner from "@/components/RouletteSpinner";
import SaveAsWordPackDialog from "@/components/SaveAsWordPackDialog";
import { useGlobalQuota } from "@/hooks/useGlobalQuota";
import { generateWordPool } from "@/utils/wordPoolAI";
import { ACCOUNT_AVATARS } from "@/lib/avatars";
import { localGameTimeoutOutcome, pickLocalSpyIndices } from "@/lib/localGameRules";
import {
  isAllowedSpyCount,
  maxSpyCountForPlayerCount,
  normalizeSpyCount,
} from "@/lib/multiSpyRules";
import { listWordPacks } from "@/lib/wordPackActions";

const MAX_LOCAL_PLAYERS = 10;

function initialLocalRoster(savedSettings) {
  const names = Array.isArray(savedSettings?.playerNames)
    ? savedSettings.playerNames.slice(0, MAX_LOCAL_PLAYERS).map((name) => String(name ?? ""))
    : [];
  const avatars = Array.isArray(savedSettings?.playerAvatars)
    ? savedSettings.playerAvatars.slice(0, MAX_LOCAL_PLAYERS)
    : [];
  while (names.length < 3) names.push("");
  return {
    names,
    avatars: names.map((_, index) => avatars[index] || ACCOUNT_AVATARS[index % ACCOUNT_AVATARS.length]),
  };
}

function pickWord(locale) {
  const cats = Object.keys(locale.builtInCategories);
  const cat = cats[Math.floor(Math.random() * cats.length)];
  const words = locale.builtInCategories[cat];
  const word = words[Math.floor(Math.random() * words.length)];
  const pool = words.map((w) => ({ word: w, enabled: true }));
  return { word, category: cat, pool };
}

// ─── PHASES ─────────────────────────────────────────────────────────────────
// setup → cards → playing → finished

export default function LocalGame() {
  const { t, locale, lang } = useLanguage();
  const navigate = useNavigate();
  const sounds = useGameSounds();
  const quotaState = useGlobalQuota();
  const { increment } = quotaState;
  const availableAvatars = ACCOUNT_AVATARS;

  // setup state
  const [phase, setPhase] = useState("setup"); // setup | cards | playing | finished

  // Load saved settings from localStorage
  const savedSettings = (() => {
    try {return JSON.parse(localStorage.getItem("spy_local_settings") || "{}");} catch {return {};}
  })();
  const initialRoster = initialLocalRoster(savedSettings);

  const [playerNames, setPlayerNames] = useState(initialRoster.names);
  const [playerAvatars, setPlayerAvatars] = useState(initialRoster.avatars);
  const [gameDuration, setGameDuration] = useState(savedSettings.gameDuration || 10);
  const [spyCount, setSpyCount] = useState(() => normalizeSpyCount(
    savedSettings.spyCount ?? 1,
    initialRoster.names.length,
  ));
  const [spiesKnowEachOther, setSpiesKnowEachOther] = useState(
    savedSettings.spiesKnowEachOther === true,
  );

  // word pool state (mirrors Room.jsx)
  const [customTheme, setCustomTheme] = useState(savedSettings.customTheme || "");
  const [wordPool, setWordPool] = useState([]);
  const generatedPoolRef = useRef([]);
  const [wordCount, setWordCount] = useState(savedSettings.wordCount || 25);
  const [generatedCategory, setGeneratedCategory] = useState("");
  const [themeError, setThemeError] = useState("");
  const [validating, setValidating] = useState(false);
  const [themeAnalyzed, setThemeAnalyzed] = useState(false);
  const [themeMaxWords, setThemeMaxWords] = useState(100);
  const [selectedPackId, setSelectedPackId] = useState(savedSettings.selectedPackId || null);
  const [gameMode, setGameMode] = useState(savedSettings.gameMode || "questions"); // "questions" | "associations"
  const [wordCountMode, setWordCountMode] = useState(savedSettings.wordCountMode || "recommended"); // "recommended" | "custom"
  const [customWordCount, setCustomWordCount] = useState(savedSettings.customWordCount || 25);

  // Persist settings to localStorage whenever they change
  useEffect(() => {
    localStorage.setItem("spy_local_settings", JSON.stringify({ playerNames, playerAvatars, gameDuration, spyCount, spiesKnowEachOther, customTheme, selectedPackId, wordCount, gameMode, wordCountMode, customWordCount }));
  }, [playerNames, playerAvatars, gameDuration, spyCount, spiesKnowEachOther, customTheme, selectedPackId, wordCount, gameMode, wordCountMode, customWordCount]);

  useEffect(() => {
    const clamped = normalizeSpyCount(spyCount, playerNames.length);
    if (clamped !== spyCount) setSpyCount(clamped);
  }, [playerNames.length, spyCount]);
  const [userPacks, setUserPacks] = useState([]);

  useEffect(() => {
    base44.auth.me().then((u) => {
      if (u) listWordPacks().then(setUserPacks).catch(() => {});
    }).catch(() => {});
  }, []);

  // When a WordPack is selected (without a custom theme), populate the pool so the reveal card renders
  useEffect(() => {
    if (selectedPackId && !customTheme.trim()) {
      const pack = userPacks.find((p) => p.id === selectedPackId);
      if (pack?.words?.length) {
        setWordPool(pack.words.map((w) => ({ word: w, enabled: true })));
      }
    } else if (!selectedPackId && !customTheme.trim()) {
      // Clearing pack selection — clear pool
      setWordPool([]);
    }
  }, [selectedPackId, userPacks, customTheme]);

  // game state
  const [gameData, setGameData] = useState(null); // { word, category, pool, spyIndices, players }
  const [cardPhaseIdx, setCardPhaseIdx] = useState(0); // which player is currently looking at card
  const [revealed, setRevealed] = useState(false);
  const [cardsReadCount, setCardsReadCount] = useState(0);

  // playing state
  const [timeLeft, setTimeLeft] = useState(null);
  const [timeExpired, setTimeExpired] = useState(false);
  const [timerRef, setTimerRef] = useState(null);
  const [showSpyGuess, setShowSpyGuess] = useState(false);
  const [winner, setWinner] = useState(null); // "spy" | "detectives"
  const [spyGuess, setSpyGuess] = useState(null);
  const [showRoulette, setShowRoulette] = useState(false);
  const [rouletteTarget, setRouletteTarget] = useState(null);
  const [currentAskerIdx, setCurrentAskerIdx] = useState(0);
  const [currentAnswererIdx, setCurrentAnswererIdx] = useState(1);
  const [showSavePackDialog, setShowSavePackDialog] = useState(false);
  const [associationIdx, setAssociationIdx] = useState(0); // current speaker idx in associations mode
  const [associationRouletteDone, setAssociationRouletteDone] = useState(false);
  const [associationOrder, setAssociationOrder] = useState([]); // shuffled order of player indices
  const [associationStep, setAssociationStep] = useState(0); // current position within order


  // ── SETUP ──────────────────────────────────────────────────────────────────
  const maxPlayers = MAX_LOCAL_PLAYERS;
  const addPlayer = () => {
    if (playerNames.length >= maxPlayers) return;
    setPlayerNames((n) => [...n, ""]);
    setPlayerAvatars((a) => [...a, availableAvatars[a.length % availableAvatars.length]]);
  };
  const removePlayer = (i) => {
    if (playerNames.length <= 3) return;
    setPlayerNames((n) => n.filter((_, idx) => idx !== i));
    setPlayerAvatars((a) => a.filter((_, idx) => idx !== i));
  };
  const updateName = (i, v) => setPlayerNames((n) => n.map((x, idx) => idx === i ? v : x));
  const updateAvatar = (i) => setPlayerAvatars((a) => a.map((x, idx) => idx === i
    ? availableAvatars[(availableAvatars.indexOf(x) + 1) % availableAvatars.length]
    : x));
  const dragState = useRef(null);

  const handleDragStart = (e, index) => {
    dragState.current = { fromIndex: index };
    e.currentTarget.style.opacity = "0.5";
  };

  const handleDragOver = (e, index) => {
    e.preventDefault();
    if (!dragState.current || dragState.current.fromIndex === index) return;
    const from = dragState.current.fromIndex;
    const reorder = (arr) => {const a = [...arr];const [item] = a.splice(from, 1);a.splice(index, 0, item);return a;};
    setPlayerNames(reorder);
    setPlayerAvatars(reorder);
    dragState.current.fromIndex = index;
  };

  const handleDragEnd = (e) => {
    e.currentTarget.style.opacity = "1";
    dragState.current = null;
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
      setThemeError(lang === "ru"
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length || result.words.length < 5) {
      setThemeError(lang === "ru" ? "Не удалось распознать тему. Попробуй другую." : "Couldn't recognize this theme. Try another.");
      return;
    }
    const realMax = result.words.length; // actual count returned by the model
    const pool = result.words.map((w) => ({ word: w, enabled: true }));
    generatedPoolRef.current = pool;
    setThemeMaxWords(realMax);
    setWordCount(realMax);
    setWordPool(pool);
    setGeneratedCategory(result.display_category || customTheme.trim());
    setThemeAnalyzed(true);
    increment(result);
  };

  // Try to squeeze more words beyond current max — calls LLM with a higher target and existing pool as "avoid"
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
      setThemeError(lang === "ru"
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length) return;
    // Merge: keep existing pool order + states, append new unique items
    const existingLower = new Set(currentWords.map((w) => w.toLowerCase()));
    const additions = result.words.filter((w) => !existingLower.has(w.toLowerCase()));
    if (additions.length === 0) {
      setThemeError(lang === "ru" ? "Больше уникальных слов найти не удалось." : "Couldn't find more unique words.");
      return;
    }
    const newPool = [...currentPool, ...additions.map((w) => ({ word: w, enabled: true }))].slice(0, 200);
    generatedPoolRef.current = newPool;
    setWordPool(newPool);
    setThemeMaxWords(newPool.length);
    setWordCount(newPool.length);
    increment(result);
  };

  const generateTheme = async () => {
    // Regenerate uses the current wordCount as target
    if (!customTheme.trim()) return;
    setValidating(true);
    setThemeError("");
    let result;
    try {
      result = await generateWordPool(customTheme.trim(), wordCount);
    } catch (error) {
      console.error("AI theme generation failed", error);
      setThemeError(lang === "ru"
        ? "AI-генерация временно недоступна."
        : "AI generation is temporarily unavailable.");
      setValidating(false);
      return;
    }
    setValidating(false);
    if (!result?.words?.length) {setThemeError(t('room_theme_error_empty'));return;}
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

  const buildWordData = () => {
    if (customTheme.trim() && wordPool.length > 0) {
      const enabled = wordPool.filter((w) => w.enabled);
      if (!enabled.length) return null;
      return { word: enabled[Math.floor(Math.random() * enabled.length)].word, category: generatedCategory || customTheme.trim(), pool: wordPool };
    }
    if (selectedPackId) {
      const pack = userPacks.find((p) => p.id === selectedPackId);
      if (pack && pack.words?.length >= 2) {
        const word = pack.words[Math.floor(Math.random() * pack.words.length)];
        return { word, category: pack.category || pack.name, pool: pack.words.map((w) => ({ word: w, enabled: true })) };
      }
    }
    return pickWord(locale);
  };

  const startGame = () => {
    const names = playerNames.map((n, i) => n.trim() || `Player ${i + 1}`);
    const data = buildWordData();
    if (!data) {setThemeError(t('room_theme_error_empty'));return;}

    // If using random built-in (no custom theme or pack), show the pool first
    const isRandom = !customTheme.trim() && !selectedPackId;
    if (isRandom && wordPool.length === 0) {
      // Show the randomly picked pool so players can see it before starting
      setWordPool(data.pool);
      setGeneratedCategory(data.category);
      return; // User needs to press again to confirm
    }

    if (!isAllowedSpyCount(names.length, spyCount)) {
      setThemeError(t("room_spy_count_invalid"));
      return;
    }
    const spyIndices = pickLocalSpyIndices(names.length, spyCount);
    const spyIndexSet = new Set(spyIndices);
    const players = names.map((name, i) => ({ name, avatar: playerAvatars[i], isSpy: spyIndexSet.has(i) }));
    const dealOrder = [...Array(names.length).keys()];
    setGameData({ word: data.word, category: data.category, pool: data.pool, spyIndices, players, dealOrder, gameMode, spiesKnowEachOther });
    setCardPhaseIdx(0);
    setRevealed(false);
    setCardsReadCount(0);
    setPhase("cards");
    sounds.roundStart();
  };

  // ── CARD PHASE ─────────────────────────────────────────────────────────────
  const handleCardRead = () => {
    const next = cardPhaseIdx + 1;
    // First flip the card back, then advance after animation completes
    setRevealed(false);
    setTimeout(() => {
      if (next >= gameData.players.length) {
        // All cards read — start playing directly
        const durationSecs = gameDuration * 60;
        setTimeLeft(durationSecs);
        setTimeExpired(false);
        setWinner(null);
        setSpyGuess(null);
        // For associations mode — shuffle order and show roulette for first
        if (gameMode === "associations") {
          const shuffled = [...Array(gameData.players.length).keys()].sort(() => Math.random() - 0.5);
          setAssociationOrder(shuffled);
          setAssociationStep(0);
          setAssociationIdx(shuffled[0]);
          setAssociationRouletteDone(false);
        }
        setPhase("playing");
        sounds.roundStart();
        // Start timer
        let remaining = durationSecs;
        const ref = setInterval(() => {
          remaining -= 1;
          setTimeLeft(remaining);
          if (remaining <= 0) {
            clearInterval(ref);
            setTimerRef(null);
            const outcome = localGameTimeoutOutcome();
            setTimeLeft(outcome.timeLeft);
            setTimeExpired(outcome.timeExpired);
            setShowSpyGuess(outcome.showSpyGuess);
            setWinner(outcome.winner);
            setPhase(outcome.phase);
            sounds.win();
          }
        }, 1000);
        setTimerRef(ref);
      } else {
        setCardPhaseIdx(next);
        setCardsReadCount((c) => c + 1);
      }
    }, 700); // wait for flip-back animation (0.65s)
  };

  // ── SPY GUESS ──────────────────────────────────────────────────────────────
  const handleSpyGuess = (guessedWord) => {
    if (phase !== "playing" || winner) return;
    if (timerRef) clearInterval(timerRef);
    const correct = guessedWord === gameData.word;
    const w = correct ? "spy" : "detectives";
    setSpyGuess(guessedWord);
    setWinner(w);
    sounds[correct ? "win" : "lose"]();
    setShowSpyGuess(false);
    setPhase("finished");
  };

  // ── PLAY AGAIN ─────────────────────────────────────────────────────────────
  const playAgain = () => {
    if (timerRef) clearInterval(timerRef);
    setPhase("setup");
    setTimeLeft(null);
    setTimeExpired(false);
    setWinner(null);
  };

  const formatTime = (s) => {
    if (!s && s !== 0) return "0:00";
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return `${m}:${sec < 10 ? "0" : ""}${sec}`;
  };

  // Remember scroll position from before the user focused an input, so we can restore it on blur.
  const scrollReturnRef = useRef(null);
  // Pending timer that locks page scroll after centering finishes — cancellable on early blur.
  const lockTimerRef = useRef(null);

  // Smooth-center a block in the viewport. Accounts for the mobile keyboard via visualViewport
  // and re-corrects after the keyboard finishes opening so the block ends up perfectly centered.
  // After centering completes, locks page scroll so the user can't move past the focused block.
  const centerInViewport = (el) => {
    if (!el) return;
    // save the pre-focus scroll position once per focus session
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
    // first pass — runs as the keyboard begins to open
    setTimeout(doScroll, 300);
    // second pass — corrects after keyboard fully opened (iOS ~500–700ms)
    setTimeout(doScroll, 750);
    // lock page scroll once centering has settled
    if (lockTimerRef.current) clearTimeout(lockTimerRef.current);
    lockTimerRef.current = setTimeout(() => {
      document.body.classList.add("lspy-scroll-locked");
      lockTimerRef.current = null;
    }, 900);
  };

  // Restore the scroll position saved when the user first focused an input.
  // Unlocks page scroll, then waits for the dim-overlay transition (0.35s) before scrolling back.
  const restoreScroll = () => {
    if (lockTimerRef.current) {
      clearTimeout(lockTimerRef.current);
      lockTimerRef.current = null;
    }
    document.body.classList.remove("lspy-scroll-locked");
    const target = scrollReturnRef.current;
    if (target === null) return;
    scrollReturnRef.current = null;
    setTimeout(() => {
      window.scrollTo({ top: target, behavior: "smooth" });
    }, 400);
  };

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER: SETUP
  // ════════════════════════════════════════════════════════════════════════════
  if (phase === "setup") {
    const themeNeedsGenerate = customTheme.trim() && wordPool.length === 0;
    const maxLocalSpies = maxSpyCountForPlayerCount(playerNames.length);
    const spyCountIsValid = isAllowedSpyCount(playerNames.length, spyCount);
    const canStart = playerNames.length >= 3 && spyCountIsValid && !themeNeedsGenerate;
    const glassStyle = {
      background: "rgba(255,255,255,0.04)",
      border: "1px solid rgba(255,255,255,0.10)",
      backdropFilter: "blur(12px)",
      WebkitBackdropFilter: "blur(12px)",
      borderRadius: 12,
      boxShadow: "0 4px 32px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.06)"
    };
    const sectionLabel = {
      fontSize: 11, letterSpacing: 3, color: "#aaa", marginBottom: 14,
      fontFamily: "monospace", display: "flex", alignItems: "center", gap: 8
    };
    return (
      <div className="lspy-setup" style={{ maxWidth: 480, margin: "0 auto", padding: "40px 20px 80px" }}>
        <style>{`
          .lspy-slider{appearance:none;-webkit-appearance:none;width:100%;height:2px;outline:none;cursor:pointer;border:none!important;padding:0!important;background:transparent!important}
          .lspy-slider::-webkit-slider-runnable-track{height:2px;border-radius:0}
          .lspy-slider::-webkit-slider-thumb{appearance:none;-webkit-appearance:none;width:14px;height:14px;background:#e53535;border:2px solid #e53535;border-radius:0;cursor:pointer;margin-top:-6px;box-shadow:0 0 8px rgba(229,53,53,0.5)}
          .lspy-slider::-moz-range-thumb{width:14px;height:14px;background:#e53535;border:2px solid #e53535;border-radius:0;cursor:pointer}
          .lspy-slider.max-zone::-webkit-slider-thumb{background:#fbbf24;border-color:#fbbf24;box-shadow:0 0 8px rgba(251,191,36,0.6)}
          .lspy-slider.max-zone::-moz-range-thumb{background:#fbbf24;border-color:#fbbf24}
          .lspy-setup .dim-on-theme-focus{transition:opacity 0.35s ease,transform 0.35s ease,filter 0.35s ease;transform-origin:center}
          .lspy-setup:has(.theme-input:focus:not(:placeholder-shown)) .dim-on-theme-focus:not(.theme-block){opacity:0.2;transform:scale(0.94);filter:blur(2px);pointer-events:none}
          .lspy-setup:has(.player-input:focus:not(:placeholder-shown)) .dim-on-theme-focus:not(.players-block){opacity:0.2;transform:scale(0.94);filter:blur(2px);pointer-events:none}
          body.lspy-scroll-locked{overflow:hidden!important;touch-action:none!important;overscroll-behavior:none!important}
        `}</style>

        {/* Header block */}
        <div className="dim-on-theme-focus" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={{ fontSize: 11, letterSpacing: 4, color: "#888", marginBottom: 8, fontFamily: "monospace" }}>
            🎮 HOME // <span style={{ color: "#fff", fontWeight: 700 }}>LOCAL GAME</span>
          </div>
          <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 26, fontWeight: 700, letterSpacing: 3, color: "#fff", marginBottom: 6 }}>
            {lang === "ru" ? "ИГРА НА ОДНОМ ТЕЛЕФОНЕ" : "LOCAL GAME"}
          </div>
          <div style={{ color: "#666", fontSize: 12, letterSpacing: 0.5, lineHeight: 1.7 }}>
            {lang === "ru" ?
            "Все играют на одном устройстве. Телефон передаётся каждому игроку чтобы тайно прочитать карточку роли." :
            "Everyone plays on one device. Pass the phone to each player to secretly read their role card."}
          </div>
        </div>

        {/* Game Mode */}
        <div className="dim-on-theme-focus" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={sectionLabel}>
            <span>⚙️</span> {lang === "ru" ? "РЕЖИМ ИГРЫ" : "GAME MODE"}
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            {[
            { mode: "questions", label: lang === "ru" ? "ВОПРОСЫ" : "QUESTIONS", icon: "?" },
            { mode: "associations", label: lang === "ru" ? "АССОЦИАЦИИ" : "ASSOCIATIONS", icon: "💭" }].
            map(({ mode, label, icon }) => {
              const active = gameMode === mode;
              return (
                <motion.button key={mode} whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
                onClick={() => setGameMode(mode)}
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
        </div>

        {/* Players */}
        <div className="dim-on-theme-focus players-block" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={sectionLabel}>
            <span>👥</span> {lang === "ru" ? "ИГРОКИ" : "PLAYERS"} ({playerNames.length})
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {playerNames.map((name, i) =>
            <div key={i}
            draggable
            onDragStart={(e) => handleDragStart(e, i)}
            onDragOver={(e) => handleDragOver(e, i)}
            onDragEnd={handleDragEnd}
            style={{ display: "flex", alignItems: "center", gap: 8, borderRadius: 8, transition: "opacity 0.15s" }}>
                {/* Drag handle */}
                <div style={{ color: "#555", fontSize: 16, cursor: "grab", padding: "4px 2px", userSelect: "none", flexShrink: 0, touchAction: "none" }}>
                  ⋮⋮
                </div>
                <div style={{ fontSize: 11, color: "#444", fontFamily: "monospace", minWidth: 16, textAlign: "center" }}>{i + 1}</div>
                <button onClick={() => updateAvatar(i)} className="btn-ghost"
              style={{ fontSize: 24, padding: "4px 8px", minWidth: 48, textAlign: "center" }}>
                  {playerAvatars[i]}
                </button>
                <input
                className="player-input"
                value={name}
                onChange={(e) => updateName(i, e.target.value)}
                onFocus={(e) => centerInViewport(e.target.closest('.players-block'))}
                onBlur={restoreScroll}
                placeholder={lang === "ru" ? `Игрок ${i + 1}` : `Player ${i + 1}`}
                style={{ flex: 1, fontSize: 14, background: "rgba(255,255,255,0.05) !important", border: "1px solid rgba(255,255,255,0.10) !important", borderRadius: 8 }} />
              
                {playerNames.length > 3 &&
              <button onClick={() => removePlayer(i)} className="btn-outline"
              style={{ padding: "6px 10px", fontSize: 12 }}>
                    ✕
                  </button>
              }
              </div>
            )}
          </div>
          {playerNames.length < maxPlayers ?
          <button onClick={addPlayer} className="btn-ghost"
          style={{ marginTop: 12, width: "100%", fontSize: 11, letterSpacing: 2, padding: "10px 0" }}>
              + {lang === "ru" ? "ДОБАВИТЬ ИГРОКА" : "ADD PLAYER"}
            </button> :
          null}
        </div>

        {/* Local multi-spy setup uses the same approved count bands as Online. */}
        <div className="dim-on-theme-focus" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
          <div style={sectionLabel}>
            <span>🕵️</span> {t("room_spy_count_label")}
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 12 }}>
            <span style={{ color: "#666", fontSize: 10, letterSpacing: 1 }}>{t("room_spy_count_hint")}</span>
            <strong style={{ color: "#e53535", fontFamily: "'Rajdhani', sans-serif", fontSize: 26 }}>{spyCount}</strong>
          </div>
          <div style={{ position: "relative", paddingBottom: 4 }}>
            <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
            <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${maxLocalSpies > 1 ? ((spyCount - 1) / (maxLocalSpies - 1)) * 100 : 0}%`, pointerEvents: "none" }} />
            <input
              type="range"
              min={1}
              max={maxLocalSpies}
              step={1}
              value={Math.min(spyCount, maxLocalSpies)}
              onChange={(event) => setSpyCount(normalizeSpyCount(Number(event.target.value), playerNames.length))}
              disabled={maxLocalSpies === 1}
              aria-label={t("room_spy_count_label")}
              className="lspy-slider"
              style={{ position: "relative", zIndex: 1, opacity: maxLocalSpies === 1 ? 0.45 : 1 }}
            />
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", color: "#444", fontFamily: "monospace", fontSize: 9, marginTop: 6 }}>
            <span>1</span><span>{maxLocalSpies}</span>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={spiesKnowEachOther}
            onClick={() => setSpiesKnowEachOther((value) => !value)}
            style={{
              width: "100%", marginTop: 16, padding: "12px 14px", display: "flex", alignItems: "center", gap: 12,
              border: `1px solid ${spiesKnowEachOther ? "rgba(229,53,53,0.65)" : "#242424"}`,
              background: spiesKnowEachOther ? "rgba(229,53,53,0.08)" : "#080808",
              color: "#aaa", cursor: "pointer", textAlign: "left",
            }}>
            <span aria-hidden="true" style={{ color: spiesKnowEachOther ? "#e53535" : "#555", fontSize: 18 }}>
              {spiesKnowEachOther ? "●" : "○"}
            </span>
            <span style={{ display: "grid", gap: 3 }}>
              <strong style={{ color: spiesKnowEachOther ? "#fff" : "#888", fontSize: 10, letterSpacing: 1.5 }}>{t("room_spies_know_label")}</strong>
              <span style={{ fontSize: 9, lineHeight: 1.4 }}>{t(spiesKnowEachOther ? "room_spies_know_on" : "room_spies_know_off")}</span>
            </span>
          </button>
        </div>

        {/* Theme / Word Pack */}
        <div className="dim-on-theme-focus theme-block" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 14 }}>
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
          {customTheme.trim() &&
          <div style={{ marginBottom: 10 }}>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: wordCountMode === "custom" ? 10 : 0 }}>
              {[
                { mode: "recommended", label: lang === "ru" ? "РЕКОМЕНДОВАНО" : "RECOMMENDED", hint: lang === "ru" ? "Авто" : "Auto" },
                { mode: "custom", label: lang === "ru" ? "СВОЙ ВЫБОР" : "CUSTOM", hint: `${customWordCount}` }
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
                <span style={{ fontSize: 10, letterSpacing: 2, color: "#888", fontFamily: "monospace" }}>// {lang === "ru" ? "КОЛИЧЕСТВО" : "COUNT"}</span>
                <span style={{ fontSize: 15, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: "#e53535" }}>{customWordCount}<span style={{ color: "#444", fontSize: 10 }}> / 80</span></span>
              </div>
              <div style={{ position: "relative", paddingBottom: 4 }}>
                <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
                <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${(customWordCount - 5) / 75 * 100}%`, pointerEvents: "none" }} />
                <input type="range" min={5} max={80} step={1} value={customWordCount}
                  onChange={(e) => setCustomWordCount(Number(e.target.value))}
                  className="lspy-slider" style={{ position: "relative", zIndex: 1 }} />
              </div>
            </div>
            }
          </div>
          }
          
          <motion.button whileHover={customTheme.trim() ? { scale: 1.01 } : {}} whileTap={customTheme.trim() ? { scale: 0.99 } : {}}
          className="btn-outline"
          onClick={themeAnalyzed ? wordCount > themeMaxWords ? pushMax : generateTheme : handleAnalyze}
          disabled={validating || !customTheme.trim()}
          style={{
            fontSize: 11, width: "100%", opacity: customTheme.trim() ? 1 : 0.4, marginBottom: 10, borderRadius: 10, clipPath: "none",
            ...(wordCount > themeMaxWords ? { color: "#fbbf24", borderColor: "#fbbf24", background: "rgba(251,191,36,0.05)" } : {})
          }}>
            {validating ? lang === "ru" ? "ГЕНЕРАЦИЯ..." : "GENERATING..." :
            wordCount > themeMaxWords ? lang === "ru" ? "⚡ ВЫЖАТЬ БОЛЬШЕ" : "⚡ SQUEEZE MORE" :
            wordPool.length > 0 ? t('room_regenerate') :
            themeAnalyzed ? lang === "ru" ? "✨ ГЕНЕРИРОВАТЬ" : "✨ GENERATE" :
            lang === "ru" ? "✨ ГЕНЕРАЦИЯ" : "✨ GENERATE"}
          </motion.button>
          {themeError && <div style={{ marginBottom: 10, fontSize: 12, color: "#e53535" }}>{themeError}</div>}
          {wordPool.length > 0 && customTheme.trim() && <div style={{ fontSize: 9, color: "#444", letterSpacing: 0.5, marginBottom: 10, fontFamily: "monospace", lineHeight: 1.6 }}>
           ⚠️ {lang === "ru" ? "AI может ошибаться. Проверь слова перед игрой." : "AI may make mistakes. Double-check words before playing."}
          </div>}

          {!customTheme.trim() &&
          <div style={{ marginBottom: 10 }}>
              <WordPackSelector selectedPackId={selectedPackId} onSelect={(id) => setSelectedPackId(id)} />
            </div>
          }

          {/* Words count slider (only if AI theme + analyzed) */}
          {customTheme.trim() && themeAnalyzed &&
          <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}
          style={{
            background: "rgba(0,0,0,0.25)",
            border: "1px solid rgba(255,255,255,0.06)",
            borderRadius: 10,
            padding: "10px 14px",
            marginBottom: 10
          }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
                <span style={{ fontSize: 10, letterSpacing: 2, color: "#888", fontFamily: "monospace" }}>
                  // {t('room_words_label')}
                </span>
                <span style={{ fontSize: 15, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: wordCount > themeMaxWords ? "#fbbf24" : "#e53535" }}>
                  {wordCount > themeMaxWords ? "+MAX" : wordCount}<span style={{ color: "#444", fontSize: 10 }}> / {themeMaxWords}</span>
                </span>
              </div>
              <div style={{ fontSize: 9, color: "#555", fontFamily: "monospace", letterSpacing: 0.5, marginBottom: 8 }}>
                {lang === "ru" ? `тема: ${generatedCategory} · макс ${themeMaxWords}` : `theme: ${generatedCategory} · max ${themeMaxWords}`}
              </div>
              {/* Slider with +MAX as final position (themeMaxWords + 1) */}
              {(() => {
              const sliderMax = themeMaxWords + 1; // last step = "+MAX" zone
              const totalRange = sliderMax - 10;
              const fillPct = totalRange > 0 ? (wordCount - 10) / totalRange * 100 : 0;
              const maxZonePct = totalRange > 0 ? (themeMaxWords - 10) / totalRange * 100 : 100;
              const inMaxZone = wordCount > themeMaxWords;
              return (
                <div style={{ position: "relative", paddingBottom: 4 }}>
                    {/* Track background */}
                    <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
                    {/* Filled portion */}
                    <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: inMaxZone ? "#fbbf24" : "#e53535", width: `${fillPct}%`, pointerEvents: "none", transition: "width 0.1s, background 0.15s" }} />
                    {/* +MAX label sitting on the track at its position */}
                    <div style={{
                    position: "absolute",
                    top: "50%",
                    left: `${maxZonePct}%`,
                    transform: "translate(4px, -50%)",
                    fontSize: 8, letterSpacing: 1, fontFamily: "monospace", fontWeight: 700,
                    color: inMaxZone ? "#fbbf24" : "#555",
                    pointerEvents: "none",
                    transition: "color 0.15s",
                    lineHeight: 1,
                    whiteSpace: "nowrap"
                  }}>
                      +MAX
                    </div>
                    <input type="range" min={10} max={sliderMax} step={1} value={wordCount}
                  onChange={(e) => {setWordCount(Number(e.target.value));setWordPool([]);}}
                  className={`lspy-slider${inMaxZone ? " max-zone" : ""}`} style={{ position: "relative", zIndex: 1 }} />
                  </div>);

            })()}
            </motion.div>
          }

          {wordPool.length > 0 && !customTheme.trim() && !selectedPackId &&
          <RevealPoolCard
            pool={wordPool}
            onUpdate={(updated) => {setWordPool(updated);if (customTheme.trim()) generatedPoolRef.current = updated;}}
            category={generatedCategory}
            icon="🎲"
            label={lang === "ru" ? "СЛУЧАЙНАЯ ТЕМА" : "RANDOM THEME"}
            actionLabel={`↺ ${lang === "ru" ? "ДРУГАЯ" : "REROLL"}`}
            onAction={() => {
              const data = pickWord(locale);
              setWordPool(data.pool);
              if (customTheme.trim()) generatedPoolRef.current = data.pool;
              setGeneratedCategory(data.category);
            }} />

          }

          {wordPool.length > 0 && customTheme.trim() &&
          <RevealPoolCard
            pool={wordPool}
            onUpdate={(updated) => {setWordPool(updated);if (customTheme.trim()) generatedPoolRef.current = updated;}}
            category={generatedCategory || customTheme.trim()}
            icon="✨"
            label={lang === "ru" ? "СГЕНЕРИРОВАНО" : "GENERATED"} />

          }

          {wordPool.length > 0 && !customTheme.trim() && selectedPackId && (() => {
            const pack = userPacks.find((p) => p.id === selectedPackId);
            return (
              <RevealPoolCard
                pool={wordPool}
                onUpdate={(updated) => {setWordPool(updated);if (customTheme.trim()) generatedPoolRef.current = updated;}}
                category={pack?.category || pack?.name}
                icon="📦"
                label={lang === "ru" ? "WORDPACK" : "WORDPACK"}
                fast />);


          })()}

          {/* Save as WordPack — when user generated/edited a pool with a custom theme */}
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
              💾 {lang === "ru" ? "СОХРАНИТЬ КАК WORDPACK" : "SAVE AS WORDPACK"}
            </motion.button>
          }

          {!customTheme.trim() && !selectedPackId && wordPool.length === 0 &&
          <div style={{ fontSize: 11, color: "#555", letterSpacing: 0.5, marginTop: 6 }} className="hidden">
              {lang === "ru" ? "Нажми «Раздать карточки» — случайная тема будет выбрана и показана" : "Press 'Deal Cards' — a random theme will be picked and shown"}
            </div>
          }
        </div>



        {/* Duration */}
         <div className="dim-on-theme-focus" style={{ ...glassStyle, padding: "20px 24px", marginBottom: 24 }}>
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
            onChange={(e) => {setGameDuration(Number(e.target.value));}}
            className="lspy-slider" style={{ position: "relative", zIndex: 1 }} />
          </div>
        </div>

        <motion.button
          animate={{ opacity: canStart ? 1 : 0.4 }}
          whileHover={canStart ? { scale: 1.01, boxShadow: "0 0 30px rgba(229,53,53,0.5)" } : {}}
          whileTap={canStart ? { scale: 0.98 } : {}}
          className="btn-red dim-on-theme-focus"
          onClick={canStart ? startGame : undefined}
          disabled={!canStart}
          style={{ width: "100%", fontSize: 14, padding: "18px 0", marginBottom: 10, borderRadius: 10, letterSpacing: 4, clipPath: "none", boxShadow: canStart ? "0 0 20px rgba(229,53,53,0.3)" : "none", cursor: canStart ? "pointer" : "not-allowed" }}>
          🃏 {themeNeedsGenerate ?
          lang === "ru" ? "СНАЧАЛА СГЕНЕРИРУЙ ТЕМУ" : "GENERATE THEME FIRST" :
          !customTheme.trim() && !selectedPackId && wordPool.length === 0 ?
          lang === "ru" ? "СЛУЧАЙНАЯ ТЕМА" : "RANDOM & DEAL" :
          lang === "ru" ? "РАЗДАТЬ КАРТОЧКИ" : "DEAL CARDS"}
        </motion.button>

        <button onClick={() => {localStorage.setItem("spy_return_to_play_mode", "1");navigate(createPageUrl("Home"));}} className="btn-ghost dim-on-theme-focus"
        style={{ width: "100%", fontSize: 11, padding: "14px 0" }}>
          ← {lang === "ru" ? "НАЗАД" : "BACK"}
        </button>

        <SaveAsWordPackDialog
          open={showSavePackDialog}
          onClose={() => setShowSavePackDialog(false)}
          defaultName={generatedCategory || customTheme.trim()}
          words={wordPool.filter((w) => w.enabled !== false).map((w) => w.word)}
          category={generatedCategory || customTheme.trim()}
          lang={lang}
          onSaved={() => {
            // refresh user's packs list
            base44.auth.me().then((u) => {
              if (u) listWordPacks().then(setUserPacks).catch(() => {});
            }).catch(() => {});
          }} />
        
      </div>);

  }

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER: CARDS PHASE
  // ════════════════════════════════════════════════════════════════════════════
  if (phase === "cards") {
    const dealOrder = gameData.dealOrder || gameData.players.map((_, i) => i);
    const currentPlayerIdx = dealOrder[cardPhaseIdx];
    const currentPlayer = gameData.players[currentPlayerIdx];
    const isSpy = currentPlayer.isSpy;
    const spyTeammates = isSpy && gameData.spiesKnowEachOther
      ? gameData.players.filter((player, index) => player.isSpy && index !== currentPlayerIdx)
      : [];
    const total = gameData.players.length;

    return (
      <>
      <style>{`
        nav, footer, [data-nav], [data-footer] { display: none !important; }
        body { overflow: hidden; }
        .card-flip-scene { perspective: 1000px; }
        .card-flip-inner {
          transition: transform 0.65s cubic-bezier(0.4, 0, 0.2, 1);
          transform-style: preserve-3d;
          position: relative;
        }
        .card-flip-inner.flipped { transform: rotateY(180deg); }
        .card-face {
          backface-visibility: hidden;
          -webkit-backface-visibility: hidden;
          position: absolute; inset: 0;
          display: flex; flex-direction: column; align-items: center; justify-content: center;
          border-radius: 16px;
          overflow: hidden;
          isolation: isolate;
        }
        .card-face-back { transform: rotateY(180deg); }
        .card-front-pattern {
          position: absolute; inset: 10px;
          border: 1px solid rgba(255,255,255,0.15);
          border-radius: 10px;
          background-image: repeating-linear-gradient(
            45deg,
            rgba(255,255,255,0.04) 0px,
            rgba(255,255,255,0.04) 2px,
            transparent 2px,
            transparent 10px
          ),
          repeating-linear-gradient(
            -45deg,
            rgba(255,255,255,0.04) 0px,
            rgba(255,255,255,0.04) 2px,
            transparent 2px,
            transparent 10px
          );
          pointer-events: none;
        }
      `}</style>
      <div style={{ position: "fixed", inset: 0, background: "#000", zIndex: 200, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: 24, overflow: "hidden" }}>

        {/* Player indicator */}
        <motion.div key={cardPhaseIdx} initial={{ opacity: 0, y: -16 }} animate={{ opacity: 1, y: 0 }}
          style={{ textAlign: "center", marginBottom: 32 }}>
          <div style={{ fontSize: 11, letterSpacing: 4, color: "#555", marginBottom: 12, fontFamily: "monospace" }}>
            {cardPhaseIdx + 1} / {total}
          </div>
          <div style={{ fontSize: 48, marginBottom: 8 }}>{currentPlayer.avatar}</div>
          <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 26, fontWeight: 700, letterSpacing: 3, color: "#fff" }}>
            {currentPlayer.name.toUpperCase()}
          </div>
          {!revealed &&
            <div style={{ fontSize: 11, color: "#555", letterSpacing: 2, marginTop: 6, fontFamily: "monospace" }}>
              {lang === "ru" ? "👆 Передай телефон этому игроку" : "👆 Pass phone to this player"}
            </div>
            }
        </motion.div>

        {/* Flip card */}
        <div className="card-flip-scene" style={{ width: "100%", maxWidth: 300, aspectRatio: "3/4" }}
          onClick={!revealed ? () => {sounds.click();setRevealed(true);} : undefined}>
          <div className={`card-flip-inner${revealed ? " flipped" : ""}`} style={{ width: "100%", height: "100%" }}>

            {/* Front — card back (рубашка) */}
            <div className="card-face" style={{
                cursor: "pointer",
                background: "#0a0a0a",
                border: "2px solid #2a2a2a",
                boxShadow: "0 12px 48px rgba(0,0,0,0.9)",
                userSelect: "none"
              }}>
              {/* Corner pip top-left */}
              <div style={{ position: "absolute", top: 14, left: 14, color: "#e53535", fontFamily: "monospace", fontSize: 12, fontWeight: 700, lineHeight: 1 }}>
                <div>S</div><div style={{ fontSize: 10 }}>♦</div>
              </div>
              {/* Corner pip bottom-right rotated */}
              <div style={{ position: "absolute", bottom: 14, right: 14, color: "#e53535", fontFamily: "monospace", fontSize: 12, fontWeight: 700, lineHeight: 1, transform: "rotate(180deg)" }}>
                <div>S</div><div style={{ fontSize: 10 }}>♦</div>
              </div>
              {/* Red corner accents */}
              <div style={{ position: "absolute", top: 0, left: 0, width: 18, height: 18, borderTop: "2px solid #e53535", borderLeft: "2px solid #e53535" }} />
              <div style={{ position: "absolute", top: 0, right: 0, width: 18, height: 18, borderTop: "2px solid #e53535", borderRight: "2px solid #e53535" }} />
              <div style={{ position: "absolute", bottom: 0, left: 0, width: 18, height: 18, borderBottom: "2px solid #e53535", borderLeft: "2px solid #e53535" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 18, height: 18, borderBottom: "2px solid #e53535", borderRight: "2px solid #e53535" }} />
              {/* Diamond pattern */}
              <div className="card-front-pattern" />
              {/* Center emblem */}
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, zIndex: 1 }}>
                <motion.div animate={{ opacity: [0.5, 1, 0.5] }} transition={{ duration: 2.5, repeat: Infinity }}
                  style={{ fontSize: 44, filter: "drop-shadow(0 0 10px rgba(229,53,53,0.6))" }}>🂠</motion.div>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 13, letterSpacing: 5, color: "#666", textAlign: "center" }}>SPYCLASH</div>
                <div style={{ width: 40, height: 1, background: "linear-gradient(90deg, transparent, #e53535, transparent)" }} />
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 14, letterSpacing: 3, color: "#fff", textAlign: "center" }}>{t('game_tap_to_reveal')}</div>
                <div style={{ fontSize: 10, letterSpacing: 3, color: "#444", fontFamily: "monospace", textAlign: "center" }}>{t('game_dont_show')}</div>
              </div>
            </div>

            {/* Back — role reveal (лицевая) */}
            <div className="card-face card-face-back" style={{
                background: isSpy ? "#0d0000" : "#050508",
                border: `2px solid ${isSpy ? "#e53535" : "#2a2a2a"}`,
                boxShadow: isSpy ? "0 0 40px rgba(229,53,53,0.25)" : "0 0 40px rgba(0,0,0,0.8)",
                textAlign: "center", flexDirection: "column", gap: 0, padding: "28px 24px"
              }}>
              {/* Corner accents */}
              <div style={{ position: "absolute", top: 0, left: 0, width: 18, height: 18, borderTop: `2px solid ${isSpy ? "#e53535" : "#333"}`, borderLeft: `2px solid ${isSpy ? "#e53535" : "#333"}` }} />
              <div style={{ position: "absolute", top: 0, right: 0, width: 18, height: 18, borderTop: `2px solid ${isSpy ? "#e53535" : "#333"}`, borderRight: `2px solid ${isSpy ? "#e53535" : "#333"}` }} />
              <div style={{ position: "absolute", bottom: 0, left: 0, width: 18, height: 18, borderBottom: `2px solid ${isSpy ? "#e53535" : "#333"}`, borderLeft: `2px solid ${isSpy ? "#e53535" : "#333"}` }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 18, height: 18, borderBottom: `2px solid ${isSpy ? "#e53535" : "#333"}`, borderRight: `2px solid ${isSpy ? "#e53535" : "#333"}` }} />
              {/* Top accent line */}
              <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 2, background: isSpy ? "linear-gradient(90deg, transparent, #e53535, transparent)" : "linear-gradient(90deg, transparent, #333, transparent)" }} />

              <div style={{ fontSize: 56, marginBottom: 10 }}>{isSpy ? "🕵️" : "🔍"}</div>
              <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 22, fontWeight: 700, letterSpacing: 4, color: isSpy ? "#e53535" : "#fff", marginBottom: 14, lineHeight: 1.2 }}>
                {isSpy ? t('game_you_are_spy') : t('game_you_are_detective')}
              </div>
              <div style={{ width: "60%", height: 1, background: isSpy ? "rgba(229,53,53,0.4)" : "#1e1e1e", margin: "0 auto 14px" }} />
              {!isSpy &&
                <>
                  <div style={{ color: "#555", fontSize: 10, letterSpacing: 4, fontFamily: "monospace", marginBottom: 8 }}>{t('game_secret_word_label')}</div>
                  <div translate="no" lang="zxx" style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 36, fontWeight: 700, color: "#e53535", letterSpacing: 2, lineHeight: 1.1 }}>{gameData.word}</div>
                  <div style={{ color: "#444", fontSize: 10, letterSpacing: 3, marginTop: 10, fontFamily: "monospace" }}>{t('game_category_label')} <span translate="no" lang="zxx">{gameData.category?.toUpperCase()}</span></div>
                </>
                }
              {isSpy &&
                <>
                  {!customTheme.trim() && gameData.category &&
                    <div style={{ marginBottom: 14 }}>
                      <div style={{ color: "#555", fontSize: 10, letterSpacing: 4, fontFamily: "monospace", marginBottom: 6 }}>{t('game_category_label')}</div>
                      <div translate="no" lang="zxx" style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 22, fontWeight: 700, color: "#e53535", letterSpacing: 2, lineHeight: 1.1 }}>{gameData.category?.toUpperCase()}</div>
                    </div>
                  }
                  <div style={{ color: "#888", fontSize: 12, letterSpacing: 0.5, lineHeight: 1.9 }}>
                    {t('game_spy_hint').split('\n').map((l, i) => <span key={i}>{l}{i === 0 && <br />}</span>)}
                  </div>
                  {spyTeammates.length > 0 && (
                    <div style={{ marginTop: 12, color: "#777", fontSize: 9, lineHeight: 1.6, letterSpacing: 1 }}>
                      <strong style={{ display: "block", marginBottom: 4, color: "#e53535", letterSpacing: 1.5 }}>{t("game_spy_teammates")}</strong>
                      {spyTeammates.map((player) => (
                        <span key={player.name} style={{ display: "block" }}>{player.avatar || "•"} {player.name.toUpperCase()}</span>
                      ))}
                    </div>
                  )}
                </>
                }
            </div>
          </div>
        </div>

        {/* Next button — appears after flip */}
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: revealed ? 1 : 0 }} transition={{ delay: revealed ? 0.5 : 0 }}
          style={{ marginTop: 28, width: "100%", maxWidth: 300, pointerEvents: revealed ? "auto" : "none" }}>
          <button className="btn-red" onClick={handleCardRead}
            style={{ width: "100%", fontSize: 12, padding: "16px 0", borderRadius: 10, clipPath: "none", letterSpacing: 3 }}>
            {cardPhaseIdx + 1 < total ? lang === "ru" ? `✓ ПРОЧИТАЛ — ДАЛЬШЕ` : `✓ READ — NEXT` : t('game_ready_btn')}
          </button>
        </motion.div>

        {/* Progress dots */}
        <div style={{ display: "flex", gap: 8, marginTop: 20 }}>
          {gameData.players.map((_, i) =>
            <div key={i} style={{ width: 8, height: 8, borderRadius: "50%", background: i < cardPhaseIdx ? "#4ade80" : i === cardPhaseIdx ? "#e53535" : "rgba(255,255,255,0.15)", transition: "background 0.3s" }} />
            )}
        </div>
      </div>
      </>);

  }

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER: FINISHED
  // ════════════════════════════════════════════════════════════════════════════
  if (phase === "finished") {
    const spyPlayers = (gameData.spyIndices || [])
      .map((index) => gameData.players[index])
      .filter(Boolean);
    const pluralSpies = spyPlayers.length > 1;
    return (
      <>
        {showSpyGuess &&
        <SpyGuessModal
          wordPool={gameData.pool}
          onGuess={handleSpyGuess}
          onClose={() => setShowSpyGuess(false)} />

        }
        <div style={{ maxWidth: 480, margin: "0 auto", padding: "40px 20px 80px", textAlign: "center" }}>
          <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ type: "spring", stiffness: 200 }}
          style={{ fontSize: 72, marginBottom: 20 }}>{winner === "spy" ? "🕵️" : "🔍"}</motion.div>

          <motion.h1 initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
          style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 44, fontWeight: 700, letterSpacing: 4, marginBottom: 8, color: "#e53535" }}>
            {winner === "spy" ? t(pluralSpies ? 'game_spies_won' : 'game_spy_won') : t('game_detectives_won')}
          </motion.h1>

          <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3 }}
          style={{ position: "relative", padding: "24px 40px", background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 20, display: "inline-block" }}>
            <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
            <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
            <div style={{ fontSize: 10, color: "#333", letterSpacing: 4, marginBottom: 8 }}>{t('game_spy_reveal_label')}</div>
            <span translate="no" lang="zxx"><GlitchText text={gameData.word} style={{ fontSize: 34, fontWeight: 700, color: "#e53535", letterSpacing: 6 }} speed={25} /></span>
            <div translate="no" lang="zxx" style={{ color: "#333", fontSize: 10, letterSpacing: 3, marginTop: 6 }}>{gameData.category?.toUpperCase()}</div>
            {spyGuess &&
            <div style={{ marginTop: 12, fontSize: 11, color: "#555" }}>
                {t(pluralSpies ? 'game_spy_team_guessed' : 'game_spy_guessed')} <strong style={{ color: spyGuess === gameData.word ? "#4ade80" : "#e53535" }}>{spyGuess}</strong>
              </div>
            }
          </motion.div>

          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.4 }}
          style={{ color: "#444", fontSize: 12, letterSpacing: 2, marginBottom: 28 }}>
            {t(pluralSpies ? 'game_spies_were' : 'game_spy_was')}{" "}
            <strong style={{ color: "#888" }}>
              {spyPlayers.map((player) => `${player.avatar || "•"} ${player.name.toUpperCase()}`).join(" · ")}
            </strong>
          </motion.div>

          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
            className="btn-red" onClick={playAgain} style={{ fontSize: 12 }}>
              🔁 {lang === "ru" ? "СЫГРАТЬ ЕЩЁ" : "PLAY AGAIN"}
            </motion.button>
            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
            className="btn-ghost" onClick={() => navigate(createPageUrl("Home"))} style={{ fontSize: 11 }}>
              ← {lang === "ru" ? "НА ГЛАВНУЮ" : "HOME"}
            </motion.button>
          </div>
        </div>
      </>);

  }

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER: PLAYING
  // ════════════════════════════════════════════════════════════════════════════
  if (showSpyGuess) {
    return (
      <AnimatePresence>
        <SpyGuessModal
          wordPool={gameData.pool}
          onGuess={handleSpyGuess}
          onClose={() => setShowSpyGuess(false)} />
        
      </AnimatePresence>);

  }

  // Main playing view
  return (
    <div style={{ maxWidth: 480, margin: "0 auto", padding: "12px 16px 16px", display: "flex", flexDirection: "column", gap: 10, height: "calc(100dvh - 80px)", boxSizing: "border-box" }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexShrink: 0 }}>
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#555", fontFamily: "monospace" }}>
          // {lang === "ru" ? "ИГРА" : "PLAYING"}
        </div>
        <button className="btn-ghost" onClick={() => {if (timerRef) clearInterval(timerRef);setPhase("setup");}}
        style={{ fontSize: 10, padding: "6px 12px" }}>
          ✕ {lang === "ru" ? "СТОП" : "STOP"}
        </button>
      </div>

      {/* Timer */}
      {timeLeft !== null && !timeExpired &&
      <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
      style={{ padding: "8px 12px", background: "#080808", border: "1px solid #1e1e1e", textAlign: "center", display: "flex", alignItems: "center", justifyContent: "center", gap: 12, flexShrink: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 2, color: "#555" }}>{t('game_time_left')}</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: timeLeft <= 60 ? "#e53535" : "#4ade80", fontFamily: "monospace", letterSpacing: 2 }}>
            {formatTime(timeLeft)}
          </div>
        </motion.div>
      }

      {/* Players */}
      <div style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: "10px 12px", flexShrink: 0 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #2a2a2a", borderLeft: "1px solid #2a2a2a" }} />
        <div style={{ fontSize: 10, letterSpacing: 2, color: "#555", marginBottom: 8 }}>{t('game_agents_label')} ({gameData.players.length})</div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
          {gameData.players.map((p, i) =>
          <div key={i} style={{ display: "flex", alignItems: "center", gap: 5, padding: "4px 8px", background: "#080808", border: "1px solid #141414" }}>
              <span style={{ fontSize: 16 }}>{p.avatar}</span>
              <span style={{ fontSize: 10, color: "#aaa", fontFamily: "monospace" }}>{p.name.length > 7 ? p.name.substring(0, 6) + "…" : p.name}</span>
            </div>
          )}
        </div>
      </div>

      {/* Active Pair (Questions Mode) */}
      {gameMode === "questions" &&
      <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
      style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: "16px 14px", flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", minHeight: 0 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 10, height: 10, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

          <div style={{ fontSize: 9, letterSpacing: 3, color: "#555", marginBottom: 14, textAlign: "center" }}>{lang === "ru" ? "АКТИВНАЯ ПАРА" : "ACTIVE PAIR"}</div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr auto 1fr", gap: 12, alignItems: "center" }}>
            {/* Asker */}
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: 40, marginBottom: 6 }}>{gameData.players[currentAskerIdx].avatar}</div>
              <div style={{ fontSize: 9, color: "#555", letterSpacing: 2, marginBottom: 4 }}>{lang === "ru" ? "СПРАШИВАЕТ" : "ASKS"}</div>
              <div style={{ fontSize: 12, color: "#e53535", fontWeight: 700 }}>{gameData.players[currentAskerIdx].name.substring(0, 8)}</div>
            </div>

            {/* Arrow */}
            <motion.div animate={{ x: [0, 2, 0] }} transition={{ duration: 1.5, repeat: Infinity }}
          style={{ fontSize: 22, color: "#e53535" }}>→</motion.div>

            {/* Answerer */}
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: 40, marginBottom: 6 }}>{gameData.players[currentAnswererIdx].avatar}</div>
              <div style={{ fontSize: 9, color: "#555", letterSpacing: 2, marginBottom: 4 }}>{lang === "ru" ? "ОТВЕЧАЕТ" : "ANSWERS"}</div>
              <div style={{ fontSize: 12, color: "#fff", fontWeight: 700 }}>{gameData.players[currentAnswererIdx].name.substring(0, 8)}</div>
            </div>
          </div>

          {/* Skip button */}
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
        className="btn-outline"
        onClick={() => {
          let nextAsker = (currentAskerIdx + 1) % gameData.players.length;
          let nextAnswerer = (currentAnswererIdx + 1) % gameData.players.length;
          if (nextAsker === nextAnswerer) {
            nextAnswerer = (nextAnswerer + 1) % gameData.players.length;
          }
          setCurrentAskerIdx(nextAsker);
          setCurrentAnswererIdx(nextAnswerer);
          sounds.click();
        }}
        style={{ width: "100%", fontSize: 10, padding: "10px 0", marginTop: 14, borderRadius: 6, clipPath: "none" }}>
            {lang === "ru" ? "↻ СЛЕДУЮЩАЯ ПАРА" : "↻ NEXT PAIR"}
          </motion.button>
        </motion.div>
      }

      {/* Associations Mode */}
      {gameMode === "associations" &&
      <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
      style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: "14px 14px", flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", minHeight: 0 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 10, height: 10, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

          {!associationRouletteDone ?
        <RouletteSpinner
          players={gameData.players.map((p, i) => ({ ...p, email: String(i) }))}
          targetEmail={String(associationIdx)}
          onDone={() => {setAssociationRouletteDone(true);sounds.roundStart?.();}} /> :


        <>
              <div style={{ fontSize: 9, letterSpacing: 3, color: "#555", marginBottom: 10, textAlign: "center" }}>
                {lang === "ru" ? "ГОВОРИТ АССОЦИАЦИЮ" : "SAYS ASSOCIATION"}
              </div>
              <div style={{ textAlign: "center", marginBottom: 12 }}>
                <motion.div key={associationIdx} initial={{ scale: 0.85, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
            style={{ fontSize: 56, marginBottom: 6, lineHeight: 1 }}>
                  {gameData.players[associationIdx].avatar}
                </motion.div>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 20, fontWeight: 700, letterSpacing: 3, color: "#e53535" }}>
                  {gameData.players[associationIdx].name.toUpperCase()}
                </div>
              </div>

              <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
          className="btn-outline"
          onClick={() => {
            const nextStep = associationStep + 1;
            if (nextStep >= associationOrder.length) {
              // New round — reshuffle (avoid same first as last)
              const last = associationOrder[associationOrder.length - 1];
              let shuffled = [...Array(gameData.players.length).keys()].sort(() => Math.random() - 0.5);
              if (shuffled[0] === last && shuffled.length > 1) {
                [shuffled[0], shuffled[1]] = [shuffled[1], shuffled[0]];
              }
              setAssociationOrder(shuffled);
              setAssociationStep(0);
              setAssociationIdx(shuffled[0]);
              setAssociationRouletteDone(false);
            } else {
              setAssociationStep(nextStep);
              setAssociationIdx(associationOrder[nextStep]);
            }
            sounds.click();
          }}
          style={{ width: "100%", fontSize: 10, padding: "10px 0", borderRadius: 6, clipPath: "none" }}>
                {associationStep + 1 >= associationOrder.length ?
            lang === "ru" ? "🎲 НОВЫЙ РАУНД" : "🎲 NEW ROUND" :
            lang === "ru" ? "↻ СЛЕДУЮЩИЙ ИГРОК" : "↻ NEXT PLAYER"}
              </motion.button>

              {/* Progress indicator */}
              <div style={{ display: "flex", justifyContent: "center", gap: 4, marginTop: 10 }}>
                {associationOrder.map((_, i) =>
            <div key={i} style={{
              width: 6, height: 6, borderRadius: "50%",
              background: i < associationStep ? "#4ade80" : i === associationStep ? "#e53535" : "#1e1e1e",
              transition: "background 0.2s"
            }} />
            )}
              </div>
            </>
        }
        </motion.div>
      }

    </div>);

}

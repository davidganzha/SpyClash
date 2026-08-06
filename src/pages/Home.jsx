import { useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { useNavigate, useLocation } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import BlurText from "../components/ui/BlurText";
import HeroTitle from "../components/ui/HeroTitle";
import { useLanguage } from "@/components/LanguageContext";
import { CircleHelp, QrCode } from "lucide-react";
import PageChrome from "@/components/PageChrome";
import {
  createGameRoom,
  getActiveGameRoom,
  getGameRoom,
  joinGameRoom,
  leaveGameRoom,
} from "@/lib/gameRoomActions";
import { normalizeRoomCode } from "@/lib/roomLinks";
import { useMembership } from "@/lib/MembershipContext";
import { accountAvatarForDisplay } from "@/lib/avatars";
import {
  clearPendingRoomExit,
  markRoomExitPending,
  pendingRoomExitId,
  roomExitIsPending,
} from "@/lib/roomExit";


export default function Home() {
  const { t, locale, lang, setLang } = useLanguage();
  const { hasResolvedMembership } = useMembership();
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [view, setView] = useState("main");
  const [joinCode, setJoinCode] = useState("");
  const [joinError, setJoinError] = useState("");
  const [joining, setJoining] = useState(false);
  const [creating, setCreating] = useState(false);
  const [roomActionError, setRoomActionError] = useState("");
  const [activeRoom, setActiveRoom] = useState(null);
  const [showTutorial, setShowTutorial] = useState(false);
  const [tutorialStep, setTutorialStep] = useState(0);
  const [tutorialMode, setTutorialMode] = useState(null); // null | "questions" | "associations"
  const navigate = useNavigate();
  const location = useLocation();

  const STEPS = locale.steps;
  const TUTORIAL_STEPS = locale.tutorial;

  useEffect(() => {
    const handler = () => { setShowTutorial(true); setTutorialStep(0); };
    window.addEventListener("show-tutorial", handler);
    return () => window.removeEventListener("show-tutorial", handler);
  }, []);

  // When user clicks SPYCLASH logo — animated fade to main view
  const [resetFading, setResetFading] = useState(false);
  useEffect(() => {
    if (location.state?.resetHome) {
      setResetFading(true);
      // wait for overlay to fully cover, then swap view under it, then fade overlay away
      const t1 = setTimeout(() => {
        setView("main");
        setShowTutorial(false);
        setTutorialMode(null);
        setJoinCode("");
        setJoinError("");
      }, 380);
      const t2 = setTimeout(() => setResetFading(false), 420);
      return () => { clearTimeout(t1); clearTimeout(t2); };
    }
  }, [location.state?.resetHome]);

  useEffect(() => {
    const hash = window.location.hash;
    const hashQuery = hash.includes("?") ? hash.slice(hash.indexOf("?") + 1) : "";
    if (new URLSearchParams(hashQuery).get("tutorial") === "1") {
      setShowTutorial(true);
      setTutorialStep(0);
    }
  }, []);

  useEffect(() => {
    if (!hasResolvedMembership) return;
    // Extract join code from hash URL: "#/Home?join=ABC123"
    // window.location.hash = "#/Home?join=ABC123", so we parse after "?"
    const hash = window.location.hash;
    const hashQuery = hash.includes("?") ? hash.slice(hash.indexOf("?") + 1) : "";
    const joinParam = new URLSearchParams(hashQuery).get("join");
    if (joinParam) {
      localStorage.setItem("spy_pending_join", joinParam.toUpperCase());
    }

    base44.auth.me().then(async u => {
      setUser(u);
      // Handle QR invite join code (from URL or saved in localStorage)
      if (u) {
        const pendingJoin = localStorage.getItem("spy_pending_join");
        if (pendingJoin) {
          localStorage.removeItem("spy_pending_join");
          try {
            const displayName = u.display_name || u.full_name || u.email.split("@")[0];
            const avatar = accountAvatarForDisplay(u.avatar);
            const room = await joinGameRoom({
              roomCode: pendingJoin,
              player: { name: displayName, avatar },
            });
            clearPendingRoomExit(room.id);
            localStorage.setItem("spy_active_room_id", room.id);
            navigate(createPageUrl("Room") + `?id=${room.id}`);
            return;
          } catch (error) {
            setJoinCode(pendingJoin);
            setJoinError(error?.status === 404 ? t('home_room_not_found') : (error?.message || t('home_room_not_found')));
            setView("join");
          }
        }
      }
      if (u) {
        const savedRoomId = localStorage.getItem("spy_active_room_id");
        const dismissedRoomId = pendingRoomExitId();
        if (dismissedRoomId) {
          void leaveGameRoom(dismissedRoomId)
            .then(() => clearPendingRoomExit(dismissedRoomId))
            .catch(() => {});
        }
        const checkRoom = async () => {
          let found = null;
          if (savedRoomId) {
            found = await getGameRoom(savedRoomId).catch(() => null);
          }
          if (!found) found = await getActiveGameRoom();
          if (found && (found.id === dismissedRoomId || roomExitIsPending(found.id))) {
            found = null;
          }
          if (found) localStorage.setItem("spy_active_room_id", found.id);
          else localStorage.removeItem("spy_active_room_id");
          setActiveRoom(found || null);
        };
        checkRoom().catch(() => {});
        
        // Check if returning from closed room — go to online_mode
        if (localStorage.getItem("spy_return_to_online")) {
          localStorage.removeItem("spy_return_to_online");
          setView("online_mode");
        }
        
        // Check if returning from LocalGame — go to play_mode
        if (localStorage.getItem("spy_return_to_play_mode")) {
          localStorage.removeItem("spy_return_to_play_mode");
          setView("play_mode");
        }
      }
    }).catch(() => setUser(null)).finally(() => setLoading(false));
  }, [hasResolvedMembership]);

  const handleLeaveActiveRoom = () => {
    if (!activeRoom || !user) { setActiveRoom(null); localStorage.removeItem("spy_active_room_id"); return; }
    const roomId = activeRoom.id;
    markRoomExitPending(roomId);
    setActiveRoom(null);
    void leaveGameRoom(roomId)
      .then(() => clearPendingRoomExit(roomId))
      .catch(() => {});
  };

  const handleCreate = async () => {
    if (!user) { base44.auth.redirectToLogin(createPageUrl("Home")); return; }
    if (creating) return;
    setCreating(true);
    setRoomActionError("");
    try {
      const displayName = user.display_name || user.full_name || user.email.split("@")[0];
      const avatar = accountAvatarForDisplay(user.avatar);
      const room = await createGameRoom({
        player: { name: displayName, avatar },
      });
      localStorage.setItem("spy_active_room_id", room.id);
      navigate(createPageUrl("Room") + `?id=${room.id}`);
    } catch (error) {
      if (error?.status === 401) {
        base44.auth.redirectToLogin(createPageUrl("Home"));
        return;
      }
      setRoomActionError(error?.message || (lang === "ru" ? "Не удалось создать комнату" : "Unable to create room"));
    } finally {
      setCreating(false);
    }
  };

  const handleJoin = async (code = null) => {
    if (!user) { base44.auth.redirectToLogin(createPageUrl("Home")); return; }
    const codeToUse = normalizeRoomCode(code || joinCode);
    if (!codeToUse) { setJoinError(t('home_room_not_found')); return; }
    setJoining(true); setJoinError("");
    try {
      const displayName = user.display_name || user.full_name || user.email.split("@")[0];
      const avatar = accountAvatarForDisplay(user.avatar);
      const room = await joinGameRoom({
        roomCode: codeToUse,
        player: { name: displayName, avatar },
      });
      clearPendingRoomExit(room.id);
      localStorage.setItem("spy_active_room_id", room.id);
      navigate(createPageUrl("Room") + `?id=${room.id}`);
    } catch (error) {
      if (error?.status === 401) {
        localStorage.setItem("spy_pending_join", codeToUse);
        base44.auth.redirectToLogin(createPageUrl("Home"));
        return;
      }
      setJoinError(error?.status === 404 ? t('home_room_not_found') : (error?.message || t('home_room_already_started')));
    } finally {
      setJoining(false);
    }
  };

  const homeStatus = activeRoom?.status
    ? String(activeRoom.status).replaceAll("_", " ").toUpperCase()
    : "ONLINE";
  const homeEyebrow = lang === "ru"
    ? "СТАТУС:"
    : lang === "es"
      ? "ESTADO:"
      : "STATUS:";


  if (loading) return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)" }}>
      <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }} style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}>
        {t('loading')}
      </motion.div>
    </div>
  );

  if (showTutorial) {
    // Mode selection screen
    if (!tutorialMode) {
      return (
        <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)", padding: 20 }}>
          <motion.div initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }}
            style={{ maxWidth: 400, width: "100%", position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 36, textAlign: "center" }}>
            <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
            <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
            <div style={{ fontSize: 10, letterSpacing: 4, color: "#444", marginBottom: 24 }}>{t('tut_header')}</div>
            <div style={{ fontSize: 14, color: "#666", marginBottom: 28, letterSpacing: 0.5 }}>
              {lang === "ru" ? "Какой режим игры хочешь узнать?" : "Which game mode do you want to learn?"}
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 12, marginBottom: 20 }}>
              <motion.button whileHover={{ scale: 1.02, boxShadow: "0 0 24px rgba(229,53,53,0.18)" }} whileTap={{ scale: 0.98 }}
                onClick={() => { setTutorialMode("questions"); setTutorialStep(0); }}
                style={{ padding: "20px 24px", background: "rgba(229,53,53,0.06)", border: "1px solid rgba(229,53,53,0.4)", cursor: "pointer", textAlign: "left", position: "relative",
                  clipPath: "polygon(0 0, calc(100% - 12px) 0, 100% 12px, 100% 100%, 12px 100%, 0 calc(100% - 12px))" }}>
                <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
                <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                  <span style={{ fontSize: 32 }}>❓</span>
                  <div>
                    <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 18, letterSpacing: 3, color: "#fff" }}>
                      {lang === "ru" ? "ВОПРОСЫ И ОТВЕТЫ" : "QUESTIONS MODE"}
                    </div>
                    <div style={{ fontSize: 11, color: "#666", letterSpacing: 1, marginTop: 3 }}>
                      {lang === "ru" ? "Классический режим" : "Classic mode"}
                    </div>
                  </div>
                  <span style={{ marginLeft: "auto", color: "#e53535", fontSize: 18 }}>›</span>
                </div>
              </motion.button>
              <motion.button whileHover={{ scale: 1.02, boxShadow: "0 0 24px rgba(100,100,200,0.18)" }} whileTap={{ scale: 0.98 }}
                onClick={() => { setTutorialMode("associations"); setTutorialStep(0); }}
                style={{ padding: "20px 24px", background: "rgba(100,100,200,0.06)", border: "1px solid rgba(100,100,200,0.4)", cursor: "pointer", textAlign: "left", position: "relative",
                  clipPath: "polygon(0 0, calc(100% - 12px) 0, 100% 12px, 100% 100%, 12px 100%, 0 calc(100% - 12px))" }}>
                <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #6464c8", borderLeft: "1px solid #6464c8" }} />
                <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                  <span style={{ fontSize: 32 }}>🎰</span>
                  <div>
                    <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 18, letterSpacing: 3, color: "#fff" }}>
                      {lang === "ru" ? "АССОЦИАЦИИ" : "ASSOCIATIONS MODE"}
                    </div>
                    <div style={{ fontSize: 11, color: "#666", letterSpacing: 1, marginTop: 3 }}>
                      {lang === "ru" ? "Барабан + одно слово" : "Drum + one word"}
                    </div>
                  </div>
                  <span style={{ marginLeft: "auto", color: "#6464c8", fontSize: 18 }}>›</span>
                </div>
              </motion.button>
            </div>
            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-ghost"
              onClick={() => { setShowTutorial(false); setTutorialMode(null); }}
              style={{ width: "100%", fontSize: 11 }}>
              {t('tut_close')}
            </motion.button>
          </motion.div>
        </div>
      );
    }

    const steps = tutorialMode === "associations" ? locale.tutorial_assoc : TUTORIAL_STEPS;
    const step = steps[tutorialStep];
    return (
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)", padding: 20 }}>
        <motion.div initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }}
          style={{ maxWidth: 440, width: "100%", position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 36, textAlign: "center" }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#444", marginBottom: 20 }}>
            {t('tut_header')} — {tutorialStep + 1}/{steps.length}
          </div>
          <AnimatePresence mode="wait">
            <motion.div key={tutorialStep} initial={{ opacity: 0, x: 30 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -30 }}>
              <div style={{ fontSize: 56, marginBottom: 20 }}>{step.icon}</div>
              <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 3, marginBottom: 16, color: "#e53535" }}>
                {step.title.toUpperCase()}
              </div>
              <div style={{ fontSize: 14, color: "#888", letterSpacing: 0.5, lineHeight: 1.8 }}>{step.text}</div>
            </motion.div>
          </AnimatePresence>
          <div style={{ display: "flex", justifyContent: "center", gap: 6, margin: "28px 0 24px" }}>
            {steps.map((_, i) => (
              <div key={i} style={{ width: 6, height: 6, borderRadius: "50%", background: i === tutorialStep ? "#e53535" : "#222", transition: "background 0.3s" }} />
            ))}
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-ghost"
              onClick={() => { if (tutorialStep === 0) { setTutorialMode(null); } else setTutorialStep(p => p - 1); }}
              style={{ fontSize: 11 }}>
              {tutorialStep === 0 ? t('tut_back') : t('tut_back')}
            </motion.button>
            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-red"
              onClick={() => { if (tutorialStep >= steps.length - 1) { setShowTutorial(false); setTutorialMode(null); } else setTutorialStep(p => p + 1); }}
              style={{ fontSize: 11 }}>
              {tutorialStep >= steps.length - 1 ? t('tut_done') : t('tut_next')}
            </motion.button>
          </div>
        </motion.div>
      </div>
    );
  }

  return (
    <PageChrome eyebrow={homeEyebrow} status={homeStatus}>
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", padding: "min(6vh, 60px) 20px 40px", position: "relative", contain: "layout style" }}>

      {/* Fade overlay when SPYCLASH logo is clicked from within a subview */}
      <AnimatePresence>
        {resetFading && (
          <motion.div
            key="reset-fade"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.38, ease: [0.4, 0, 0.2, 1] }}
            style={{ position: "fixed", inset: 0, background: "#000", zIndex: 90, pointerEvents: "auto" }}
          />
        )}
      </AnimatePresence>

      <div style={{ textAlign: "center", marginBottom: 20 }}>
        {view === "main" && (
          <BlurText text={t('home_tagline')} delay={60} animateBy="letters" direction="top"
            style={{ fontSize: 11, letterSpacing: 4, color: "#555", display: "block", marginBottom: 8, fontFamily: "monospace" }} />
        )}
        <HeroTitle view={view} />
        {view === "main" && (
          <BlurText text={t('home_subtitle')} delay={30} animateBy="words" direction="top"
            className="home-subtitle"
            style={{ color: "#444", fontSize: 11, maxWidth: 340, display: "block", margin: "6px auto 0", lineHeight: 1.5, letterSpacing: 0.5 }} />
        )}
      </div>

      <AnimatePresence mode="wait">
        {view === "main" && (
          <motion.div key="main" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.22 }}
            style={{ width: "100%", maxWidth: 340, display: "flex", flexDirection: "column", gap: 10 }}>
            {user ? (
              <>
                {activeRoom ? (
                  <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
                    <div style={{ position: "relative", padding: "16px 20px", background: "#0f0f0f", border: "1px solid #2a2a2a", marginBottom: 10 }}>
                      <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
                      <div style={{ position: "absolute", bottom: 0, right: 0, width: 10, height: 10, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
                      <div style={{ fontSize: 10, letterSpacing: 3, color: "#e53535", marginBottom: 4 }}>
                        {activeRoom.status === "playing" ? t('home_active_playing') : t('home_active_lobby')}
                      </div>
                      <div style={{ color: "#666", fontSize: 12, letterSpacing: 2 }}>{t('home_room')}: <strong style={{ color: "#fff" }}>{activeRoom.code}</strong></div>
                    </div>
                    <div style={{ display: "flex", gap: 10 }}>
                      <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-red" style={{ flex: 1, fontSize: 12, padding: "14px 0" }}
                        onClick={() => navigate(["playing", "finished"].includes(activeRoom.status) ? createPageUrl("Game") + `?id=${activeRoom.id}` : createPageUrl("Room") + `?id=${activeRoom.id}`)}>
                        {t('home_return')}
                      </motion.button>
                      <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-ghost" style={{ fontSize: 12, padding: "14px 16px" }}
                        onClick={handleLeaveActiveRoom}>
                        {lang === "ru" ? "ВЫЙТИ" : "LEAVE"}
                      </motion.button>
                    </div>
                  </motion.div>
                ) : (
                  <>
                    {view === "main" && (
                      <>
                        <motion.button
                          initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }}
                          transition={{ delay: 0.55, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
                          whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-red" style={{ width: "100%", fontSize: 14, padding: "18px 0", letterSpacing: 4 }} onClick={() => setView("play_mode")}>
                          ▶ {lang === "ru" ? "ИГРАТЬ" : "PLAY"}
                        </motion.button>
                        <motion.button
                          initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }}
                          transition={{ delay: 0.7, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
                          whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-ghost" style={{ width: "100%", fontSize: 12, padding: "13px 0", display: "flex", alignItems: "center", gap: 8 }}
                          onClick={() => { setShowTutorial(true); setTutorialStep(0); }}>
                          <CircleHelp size={14} />
                          {String(t('home_how_to_play')).replace(/^📖\s*/u, "")}
                        </motion.button>
                      </>
                    )}
                  </>
                )}
              </>
            ) : (
              <div style={{ position: "relative", padding: "28px 24px", background: "#0a0a0a", border: "1px solid #1e1e1e", textAlign: "center" }}>
                <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
                <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
                <div style={{ fontSize: 32, marginBottom: 12 }}>🔒</div>
                <p style={{ color: "#555", fontSize: 12, letterSpacing: 1, marginBottom: 20, lineHeight: 1.6 }}>{t('home_login_text')}</p>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-red" style={{ width: "100%", fontSize: 12, marginBottom: 10 }}
                  onClick={() => base44.auth.redirectToLogin(createPageUrl("Home"))}>
                  {t('home_login_btn')}
                </motion.button>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-ghost" style={{ width: "100%", fontSize: 12 }}
                  onClick={() => { setShowTutorial(true); setTutorialStep(0); }}>
                  {t('home_how_to_play')}
                </motion.button>
              </div>
            )}
          </motion.div>
        )}

        {view === "play_mode" && (
          <motion.div key="play_mode" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.22 }}
            style={{ width: "100%", maxWidth: 360, display: "flex", flexDirection: "column", gap: 14 }}>

            {/* Local */}
            <motion.button
              whileHover={{ scale: 1.02, borderColor: "#666", filter: "drop-shadow(0 0 24px rgba(255,255,255,0.06))" }}
              whileTap={{ scale: 0.98 }}
              onClick={() => navigate(createPageUrl("LocalGame"))}
              style={{
                width: "100%", background: "#0d0d0d", border: "1px solid #333",
                cursor: "pointer", padding: "28px 28px", textAlign: "left",
                position: "relative", transition: "border-color 0.2s, filter 0.2s",
                clipPath: "polygon(0 0, calc(100% - 14px) 0, 100% 14px, 100% 100%, 14px 100%, 0 calc(100% - 14px))"
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #888", borderLeft: "1px solid #888" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #888", borderRight: "1px solid #888" }} />
              <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
                <div style={{ fontSize: 44, flexShrink: 0 }}>📱</div>
                <div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 4, color: "#fff", marginBottom: 6 }}>
                    {lang === "ru" ? "ЛОКАЛЬНО" : "LOCAL"}
                  </div>
                  <div style={{ fontSize: 12, color: "#666", letterSpacing: 1, lineHeight: 1.6 }}>
                    {lang === "ru" ? "Один телефон, передаёте по кругу" : "One device · pass & play"}
                  </div>
                </div>
                <div style={{ marginLeft: "auto", color: "#444", fontSize: 20, flexShrink: 0 }}>›</div>
              </div>
            </motion.button>

            {/* Online */}
            <motion.button
              whileHover={{ scale: 1.02, filter: "drop-shadow(0 0 32px rgba(229,53,53,0.18))" }}
              whileTap={{ scale: 0.98 }}
              onClick={() => setView("online_mode")}
              style={{
                width: "100%", background: "rgba(229,53,53,0.06)", border: "1px solid rgba(229,53,53,0.5)",
                cursor: "pointer", padding: "28px 28px", textAlign: "left",
                position: "relative", transition: "filter 0.2s"
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
              <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
                <div style={{ fontSize: 44, flexShrink: 0 }}>📡</div>
                <div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 4, color: "#fff", marginBottom: 6 }}>
                    {lang === "ru" ? "ОНЛАЙН" : "ONLINE"}
                  </div>
                  <div style={{ fontSize: 12, color: "#666", letterSpacing: 1, lineHeight: 1.6 }}>
                    {lang === "ru" ? "Каждый на своём телефоне" : "Each player on their own device"}
                  </div>
                </div>
                <div style={{ marginLeft: "auto", color: "#e53535", fontSize: 20, flexShrink: 0 }}>›</div>
              </div>
            </motion.button>

            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-ghost" style={{ width: "100%", fontSize: 12 }}
              onClick={() => setView("main")}>
              {t('home_cancel')}
            </motion.button>
          </motion.div>
        )}

        {view === "online_mode" && (
          <motion.div key="online_mode" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.22 }}
            style={{ width: "100%", maxWidth: 360, display: "flex", flexDirection: "column", gap: 14 }}>
            <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", textAlign: "center", marginBottom: 0, fontFamily: "monospace" }}>
              {lang === "ru" ? "РАЗНЫЕ УСТРОЙСТВА" : "ONLINE MODE"}
            </div>

            {roomActionError && (
              <motion.div
                role="alert"
                initial={{ opacity: 0, y: -6 }}
                animate={{ opacity: 1, y: 0 }}
                style={{ padding: "10px 14px", border: "1px solid rgba(229,53,53,.42)", background: "rgba(229,53,53,.08)", color: "#e53535", fontSize: 10, letterSpacing: 1.2, fontFamily: "monospace", lineHeight: 1.5 }}>
                ⚠ {roomActionError}
              </motion.div>
            )}

            {/* Create Room */}
            <motion.button
              whileHover={{ scale: 1.02, filter: "drop-shadow(0 0 32px rgba(229,53,53,0.18))" }}
              whileTap={{ scale: 0.98 }}
              onClick={handleCreate}
              disabled={creating}
              aria-busy={creating}
              style={{
                width: "100%", background: "rgba(229,53,53,0.06)", border: "1px solid rgba(229,53,53,0.5)",
                cursor: creating ? "wait" : "pointer", padding: "22px 28px", textAlign: "left",
                position: "relative", transition: "filter 0.2s",
                clipPath: "polygon(0 0, calc(100% - 14px) 0, 100% 14px, 100% 100%, 14px 100%, 0 calc(100% - 14px))"
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
              <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
                <div style={{ fontSize: 36, flexShrink: 0 }}>{creating ? "⏳" : "➕"}</div>
                <div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 20, letterSpacing: 4, color: "#fff", marginBottom: 4 }}>
                    {creating
                      ? (lang === "ru" ? "СОЗДАЁМ КОМНАТУ" : "CREATING ROOM")
                      : (lang === "ru" ? "СОЗДАТЬ КОМНАТУ" : "CREATE ROOM")}
                  </div>
                  <div style={{ fontSize: 12, color: "#666", letterSpacing: 1 }}>
                    {lang === "ru" ? "Новая игровая сессия" : "Start a new game session"}
                  </div>
                </div>
                <div style={{ marginLeft: "auto", color: "#e53535", fontSize: 20, flexShrink: 0 }}>›</div>
              </div>
            </motion.button>

            {/* Enter Room */}
            <motion.button
              whileHover={{ scale: 1.02, borderColor: "#666", filter: "drop-shadow(0 0 24px rgba(255,255,255,0.06))" }}
              whileTap={{ scale: 0.98 }}
              onClick={() => setView("join")}
              style={{
                width: "100%", background: "#0d0d0d", border: "1px solid #333",
                cursor: "pointer", padding: "22px 28px", textAlign: "left",
                position: "relative", transition: "border-color 0.2s, filter 0.2s",
                clipPath: "polygon(0 0, calc(100% - 14px) 0, 100% 14px, 100% 100%, 14px 100%, 0 calc(100% - 14px))"
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #888", borderLeft: "1px solid #888" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #888", borderRight: "1px solid #888" }} />
              <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
                <div style={{ fontSize: 36, flexShrink: 0 }}>🚪</div>
                <div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 20, letterSpacing: 4, color: "#fff", marginBottom: 4 }}>
                    {lang === "ru" ? "ВОЙТИ В КОМНАТУ" : "ENTER ROOM"}
                  </div>
                  <div style={{ fontSize: 12, color: "#666", letterSpacing: 1 }}>
                    {lang === "ru" ? "Ввести код или сканировать QR" : "Enter code or scan QR"}
                  </div>
                </div>
                <div style={{ marginLeft: "auto", color: "#444", fontSize: 20, flexShrink: 0 }}>›</div>
              </div>
            </motion.button>

            <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-ghost" style={{ width: "100%", fontSize: 12 }}
              onClick={() => setView("play_mode")}>
              {t('home_cancel')}
            </motion.button>
          </motion.div>
        )}

        {view === "join" && (
          <motion.div key="join" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.22 }}
            style={{ width: "100%", maxWidth: 360, position: "relative", padding: 28, background: "#0a0a0a", border: "1px solid #1e1e1e" }}>
            <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
            <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
            <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 16 }}>{t('home_join_header')}</div>
            <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 3, marginBottom: 24 }}>{t('home_join_title')}</div>
            <input placeholder="ABC123" value={joinCode} onChange={e => setJoinCode(e.target.value.toUpperCase())}
              style={{ marginBottom: 12, textAlign: "center", fontSize: 28, letterSpacing: 8, fontWeight: 700 }}
              maxLength={6} onKeyDown={e => e.key === "Enter" && handleJoin()} autoFocus />
            {joinError && (
              <motion.p initial={{ opacity: 0 }} animate={{ opacity: 1 }} style={{ color: "#e53535", fontSize: 11, letterSpacing: 2, marginBottom: 12 }}>
                ⚠ {joinError}
              </motion.p>
            )}
            <div style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 8 }}>
              <div style={{ display: "flex", gap: 10 }}>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-red" style={{ flex: 1, fontSize: 12 }} onClick={() => handleJoin()} disabled={joining}>
                  {joining ? t('home_joining') : t('home_join_btn')}
                </motion.button>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-outline" style={{ flex: 1, fontSize: 12, display: "flex", alignItems: "center", justifyContent: "center", gap: 6 }} onClick={() => navigate(createPageUrl("QRScan"))}>
                  <QrCode size={16} /> {t('home_scan_btn')}
                </motion.button>
              </div>
              <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }} className="btn-ghost" style={{ width: "100%", fontSize: 12 }} onClick={() => { setView("online_mode"); setJoinError(""); setJoinCode(""); }}>
                {t('home_cancel')}
              </motion.button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

    </div>
    </PageChrome>
  );
}

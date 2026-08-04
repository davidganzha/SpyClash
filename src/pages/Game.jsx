import { useState, useEffect, useRef, useMemo } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { Link, useNavigate } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import { useGameSounds } from "../components/useGameSounds";
import GlitchText from "../components/ui/GlitchText";
import QuestionRound from "../components/QuestionRound";
import AssociationRound from "../components/AssociationRound";
import RoundResults from "../components/RoundResults";
import SpyGuessModal from "../components/SpyGuessModal";
import GameToastContainer, { gameToast } from "../components/GameToast";
import { useLanguage } from "@/components/LanguageContext";
import {
  getGameRoom,
  leaveGameRoom,
  runGameRoomAction,
  subscribeGameRoom,
} from "@/lib/gameRoomActions";
import { gameTimerSnapshot } from "@/lib/gameRoomSync";

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

export default function Game() {
  const { t } = useLanguage();
  const [room, setRoom] = useState(null);
  const [user, setUser] = useState(null);
  const [revealed, setRevealed] = useState(false);
  const [submittingVote, setSubmittingVote] = useState(false);
  const [showSpyGuess, setShowSpyGuess] = useState(false);
  const [requestingVote, setRequestingVote] = useState(false);
  const [syncState, setSyncState] = useState("connected");
  const [togglingPause, setTogglingPause] = useState(false);
  // playAgainVotes synced via room.ready_players
  const [timeLeft, setTimeLeft] = useState(null);
  const [timeExpired, setTimeExpired] = useState(false);
  const [guessTimeLeft, setGuessTimeLeft] = useState(null);
  const guessTimerRef = useRef(null);
  const navigate = useNavigate();
  const sounds = useGameSounds();
  const unsubRef = useRef(null);
  const roomRef = useRef(null);
  const prevRoomRef = useRef(null);
  const timerRef = useRef(null);

  const getRoomId = () => new URLSearchParams(window.location.search).get("id");

  useEffect(() => {
    base44.auth.me().then(u => {
      if (!u) { base44.auth.redirectToLogin(undefined); return; }
      setUser(u);
      loadRoom(u);
    }).catch(() => navigate(createPageUrl("Home")));
    return () => {
      unsubRef.current?.();
      if (timerRef.current) clearInterval(timerRef.current);
      if (guessTimerRef.current) clearInterval(guessTimerRef.current);
    };
  }, []);

  const loadRoom = async (u) => {
    const id = getRoomId();
    if (!id) { navigate(createPageUrl("Home")); return; }
    const r = await getGameRoom(id);
    if (!r) { navigate(createPageUrl("Home")); return; }
    roomRef.current = r;
    prevRoomRef.current = r;
    setRoom(r);

    unsubRef.current = subscribeGameRoom(id, async (evt) => {
      if (evt.id !== id) return;
      if (evt.type === "sync") {
        setSyncState(evt.state);
        return;
      }
      if (evt.type === "delete") { navigate(createPageUrl("Home")); return; }
      let fresh = evt.data;
      if (!fresh) fresh = await getGameRoom(id);
      if (!fresh) return;

      const prev = prevRoomRef.current;
      if (prev) {
        // New player joined
        const prevPlayers = prev.players || [];
        (fresh.players || []).forEach(p => {
          if (!prevPlayers.find(pp => pp.email === p.email)) {
            gameToast(`${p.name} ${t('toast_joined')}`, "join", p.avatar || "👤");
            sounds.playerJoined();
          }
        });
        prevPlayers.forEach(p => {
          if (!(fresh.players || []).find(fp => fp.email === p.email)) {
            gameToast(`${p.name} ${t('toast_left')}`, "leave", "👋");
          }
        });

        // New round started
        if (prev.round_number !== fresh.round_number) {
          gameToast(`${t('game_round_label')} ${fresh.round_number} ${t('toast_round_started')}`, "round", "🎯");
          sounds.roundStart();
        }

        // Vote request from another player
        const prevVoteReqs = prev.vote_requests || [];
        const newVoteReqs = fresh.vote_requests || [];
        newVoteReqs.forEach(email => {
          if (!prevVoteReqs.includes(email)) {
            const player = (fresh.players || []).find(p => p.email === email);
            if (player && email !== u?.email) {
              gameToast(`${player.name} ${t('toast_wants_vote')}`, "vote", "🗳️");
              sounds.alert();
            }
          }
        });

        // Voting started (>51% threshold)
        const freshSpectators = fresh.spectators || [];
        const freshActive = (fresh.players || []).filter(p => !freshSpectators.includes(p.email));
        const freshThreshold = Math.ceil(freshActive.length * 0.51);
        const freshVoteReqs = (fresh.vote_requests || []).filter(e => !freshSpectators.includes(e));
        const prevSpectators = prev.spectators || [];
        const prevActive = (prev.players || []).filter(p => !prevSpectators.includes(p.email));
        const prevThreshold = Math.ceil(prevActive.length * 0.51);
        const prevVoteReqsFiltered = (prev.vote_requests || []).filter(e => !prevSpectators.includes(e));
        const wasVoting2 = prevVoteReqsFiltered.length >= prevThreshold && prevThreshold > 0;
        const isVoting2 = freshVoteReqs.length >= freshThreshold && freshThreshold > 0;
        if (!wasVoting2 && isVoting2) {
          gameToast(t('toast_voting_started'), "warning", "🗳️");
          sounds.alert();
        }
      }

      // If host reset the room for a new game, redirect everyone to lobby
      if (fresh.status === "waiting" && (prevRoomRef.current?.status === "finished" || prevRoomRef.current?.status === "playing")) {
        navigate(createPageUrl("Room") + `?id=${id}`);
        return;
      }

      // Use the same active-time clock as iOS/backend, including pauses.
      const timerSnapshot = gameTimerSnapshot(fresh);
      if (timerSnapshot.valid) {
        setTimeExpired(timerSnapshot.remainingSeconds === 0);
      }

      prevRoomRef.current = fresh;
      roomRef.current = fresh;
      setRoom(fresh);
      setSyncState("connected");
    });
  };

  const handleLeave = async () => {
    if (!room || !user) return;
    await leaveGameRoom(room.id);
    localStorage.removeItem("spy_active_room_id");
    navigate(createPageUrl("Home"));
  };

  const derived = useMemo(() => {
    if (!room || !user) return {};
    const players = room.players || [];
    const spectators = room.spectators || [];
    const cardsRead = room.cards_read || [];
    const votes = room.detective_votes || [];
    const voteRequests = room.vote_requests || [];
    const activePlayers = players.filter(p => !spectators.includes(p.email));
    const voteThreshold = Math.ceil(activePlayers.length * 0.51);
    const activeVoteRequests = voteRequests.filter(e => !spectators.includes(e));
    return {
      isSpy: !!room.spy_email && room.spy_email === user.email,
      isDetective: !!room.spy_email && room.spy_email !== user.email,
      players,
      spectators,
      isSpectator: spectators.includes(user.email),
      activePlayers,
      cardsRead,
      allCardsRead: players.length > 0 && players.every(p => cardsRead.includes(p.email)),
      iHaveReadCard: cardsRead.includes(user.email),
      spyPlayer: players.find(p => p.email === room.spy_email),
      votes,
      myVote: votes.find(v => v.voter_email === user.email),
      voteRequests,
      voteThreshold,
      activeVoteRequests,
      votingActive: activeVoteRequests.length >= voteThreshold && voteThreshold > 0,
    };
  }, [room, user]);
  const {
    isSpy = false, isDetective = false, players = [], spectators = [],
    isSpectator = false, activePlayers = [], cardsRead = [], allCardsRead = false,
    iHaveReadCard = false, spyPlayer, votes = [], myVote, voteRequests = [],
    voteThreshold = 0, activeVoteRequests = [], votingActive = false
  } = derived;
  const isGamePaused = Boolean(String(room?.game_paused_at ?? "").trim());
  const isHost = Boolean(room && user && room.host_email === user.email);
  const formatTime = (seconds) => {
    if (seconds === null) return "0:00";
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs < 10 ? "0" : ""}${secs}`;
  };

  // Sync timer from server-stored game_started_at — placed after allCardsRead is defined
  useEffect(() => {
    if (!allCardsRead || timeExpired || room?.status !== "playing") return;
    if (!room?.game_started_at || !room?.game_duration_seconds) return;

    const tick = () => {
      const snapshot = gameTimerSnapshot(room);
      if (!snapshot.valid) return;
      setTimeLeft(snapshot.remainingSeconds);
      if (snapshot.remainingSeconds === 0) {
        setTimeExpired(true);
        clearInterval(timerRef.current);
        sounds.alert();
        gameToast(t('toast_time_up'), "warning", "⏰");
      }
    };

    tick();
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(tick, 1000);

    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [
    allCardsRead,
    timeExpired,
    room?.status,
    room?.game_started_at,
    room?.game_duration_seconds,
    room?.game_paused_at,
    room?.game_paused_total_seconds,
  ]);

  // 30-second guess timer — synced from server timestamp to stay in sync across all clients
  useEffect(() => {
    if (!timeExpired || room?.status === "finished") return;
    if (!room?.game_started_at || !room?.game_duration_seconds) return;

    const tick = async () => {
      const snapshot = gameTimerSnapshot(room);
      if (!snapshot.valid) return;
      setGuessTimeLeft(snapshot.guessRemainingSeconds);

      if (snapshot.guessRemainingSeconds === 0) {
        clearInterval(guessTimerRef.current);
        // Only the host writes game over to avoid duplicate writes
        const currentRoom = roomRef.current;
        if (currentRoom && currentRoom.status !== "finished" && currentRoom.host_email === user?.email) {
          await runGameRoomAction("finalize_expired_room", currentRoom.id);
        }
      }
    };

    tick();
    if (guessTimerRef.current) clearInterval(guessTimerRef.current);
    guessTimerRef.current = setInterval(tick, 500);
    return () => { if (guessTimerRef.current) clearInterval(guessTimerRef.current); };
  }, [
    timeExpired,
    room?.status,
    room?.game_started_at,
    room?.game_duration_seconds,
    room?.game_paused_at,
    room?.game_paused_total_seconds,
  ]);

  const handleRoundComplete = async () => {
    const currentRoom = roomRef.current || room;
    if (currentRoom?.game_paused_at) return;
    const updated = await runGameRoomAction("advance_question", currentRoom.id);
    roomRef.current = updated;
    setRoom(updated);
  };

  const handleRequestVote = async () => {
    const currentRoom = roomRef.current || room;
    const curSpectators = currentRoom.spectators || [];
    if (currentRoom?.game_paused_at) return;
    if (requestingVote || (currentRoom.vote_requests || []).includes(user.email)) return;
    if (curSpectators.includes(user.email)) return; // spectators can't request vote
    setRequestingVote(true);
    sounds.alert();
    const updated = await runGameRoomAction("request_vote", currentRoom.id);
    roomRef.current = updated;
    setRoom(updated);
    setRequestingVote(false);
  };

  const handleVoteForPlayer = async (targetEmail) => {
    const currentRoom = roomRef.current || room;
    if (currentRoom?.game_paused_at) return;
    if (myVote || submittingVote) return;
    sounds.vote();
    setSubmittingVote(true);

    const updated = await runGameRoomAction("cast_detective_vote", currentRoom.id, {
      target_email: targetEmail,
    });
    roomRef.current = updated;
    setRoom(updated);
    setSubmittingVote(false);
  };

  const handleCardRead = async () => {
    const currentRoom = roomRef.current || room;
    if (iHaveReadCard) return;
    const updated = await runGameRoomAction("mark_role_card_read", currentRoom.id);
    roomRef.current = updated;
    setRoom(updated);
  };

  const handlePlayAgain = async () => {
    const currentRoom = roomRef.current || room;
    await runGameRoomAction("reset_room_for_replay", currentRoom.id);
    navigate(createPageUrl("Room") + `?id=${currentRoom.id}`);
  };

  const handleSpyGuess = async (guessedWord) => {
    const currentRoom = roomRef.current || room;
    if (currentRoom?.game_paused_at) return;
    const result = await runGameRoomAction("submit_spy_guess", currentRoom.id, {
      guess: guessedWord,
    });
    sounds[result?.winner === "spy" ? "win" : "lose"]();
    roomRef.current = result;
    setRoom(result);
    setShowSpyGuess(false);
  };

  const handleTogglePause = async () => {
    const currentRoom = roomRef.current || room;
    if (!currentRoom || currentRoom.host_email !== user?.email || !currentRoom.game_started_at || togglingPause) return;
    setTogglingPause(true);
    try {
      const updated = await runGameRoomAction(
        currentRoom.game_paused_at ? "resume_game" : "pause_game",
        currentRoom.id,
      );
      roomRef.current = updated;
      setRoom(updated);
      setTimeExpired(gameTimerSnapshot(updated).remainingSeconds === 0);
    } catch (error) {
      console.error("Failed to synchronize game pause", error);
      gameToast(error?.message || t('game_pause_failed'), "warning", "⚠️");
    } finally {
      setTogglingPause(false);
    }
  };

  useEffect(() => {
    if (isGamePaused) setShowSpyGuess(false);
  }, [isGamePaused]);

  if (!room || !user) return (
    <>
      <GameToastContainer />
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)" }}>
        <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }}
          style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}>
          {t('loading')}
        </motion.div>
      </div>
    </>
  );

  const pausePanel = room.status === "playing" && room.game_started_at ? (
    <div role="status" aria-live="polite" style={{
      position: "relative",
      padding: 14,
      marginBottom: 16,
      background: isGamePaused ? "rgba(229,53,53,0.09)" : "#080808",
      border: `1px solid ${isGamePaused ? "rgba(229,53,53,0.5)" : "#1e1e1e"}`,
      textAlign: "center",
    }}>
      {isGamePaused && (
        <div style={{ color: "#e53535", fontFamily: "monospace", fontSize: 11, letterSpacing: 3, marginBottom: isHost ? 10 : 0 }}>
          ⏸ {t('game_paused')}
        </div>
      )}
      {isHost && (
        <motion.button whileTap={{ scale: 0.98 }} className={isGamePaused ? "btn-red" : "btn-outline"}
          onClick={handleTogglePause} disabled={togglingPause}
          style={{ width: "100%", fontSize: 11, padding: "11px 0" }}>
          {togglingPause ? "..." : isGamePaused ? `▶ ${t('game_resume_btn')}` : `⏸ ${t('game_pause_btn')}`}
        </motion.button>
      )}
    </div>
  ) : null;

  // Card reading phase — shown before game starts
  if (!allCardsRead) {
    return (
      <>
      <GameToastContainer />
      <div style={{ maxWidth: 480, margin: "0 auto", padding: "60px 20px", display: "flex", flexDirection: "column", alignItems: "center" }}>
        <div style={{ width: "100%" }}><SyncStatusBanner state={syncState} t={t} /></div>
        <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 32, fontFamily: "monospace" }}>
          {t('game_card_phase')}
        </div>

        {/* Role card */}
        <div style={{ width: "100%", marginBottom: 24 }}>
          <AnimatePresence mode="wait">
            {!revealed ? (
              <motion.div key="hidden" initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, scale: 0.95 }}>
                <motion.div
                  whileHover={{ borderColor: "#e53535", boxShadow: "0 0 30px rgba(229,53,53,0.1)" }}
                  onClick={() => { sounds.click(); setRevealed(true); }}
                  style={{
                    cursor: "pointer", padding: "48px 32px", background: "#0a0a0a",
                    border: "1px solid #1e1e1e", textAlign: "center",
                    position: "relative", transition: "all 0.3s", userSelect: "none"
                  }}>
                  <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
                  <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
                  <motion.div animate={{ opacity: [1, 0.5, 1] }} transition={{ duration: 2.5, repeat: Infinity }} style={{ fontSize: 60, marginBottom: 16 }}>🂠</motion.div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 18, letterSpacing: 3, marginBottom: 8 }}>{t('game_tap_to_reveal')}</div>
                  <div style={{ color: "#333", fontSize: 10, letterSpacing: 3 }}>{t('game_dont_show')}</div>
                </motion.div>
              </motion.div>
            ) : (
              <motion.div key="revealed" initial={{ opacity: 0, scale: 0.95, y: 10 }} animate={{ opacity: 1, scale: 1, y: 0 }} transition={{ type: "spring", stiffness: 200 }}>
                <div style={{
                  padding: "28px 24px", textAlign: "center", position: "relative",
                  background: isSpy ? "rgba(229,53,53,0.05)" : "rgba(255,255,255,0.02)",
                  border: `1px solid ${isSpy ? "rgba(229,53,53,0.35)" : "#1e1e1e"}`,
                }}>
                  <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: `1px solid ${isSpy ? "#e53535" : "#333"}`, borderLeft: `1px solid ${isSpy ? "#e53535" : "#333"}` }} />
                  <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: `1px solid ${isSpy ? "#e53535" : "#333"}`, borderRight: `1px solid ${isSpy ? "#e53535" : "#333"}` }} />
                  <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ type: "spring", stiffness: 300 }} style={{ fontSize: 52, marginBottom: 12 }}>
                    {isSpy ? "🕵️" : "🔍"}
                  </motion.div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 24, fontWeight: 700, letterSpacing: 4, marginBottom: 10, color: isSpy ? "#e53535" : "#fff" }}>
                    {isSpy ? t('game_you_are_spy') : t('game_you_are_detective')}
                  </div>
                  {!isSpy && (
                    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3 }}>
                      <div style={{ color: "#444", fontSize: 10, letterSpacing: 4, marginBottom: 10 }}>{t('game_secret_word_label')}</div>
                      <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 40, fontWeight: 700, color: "#e53535", letterSpacing: 4 }}>{room.word}</div>
                      <div style={{ color: "#333", fontSize: 10, letterSpacing: 3, marginTop: 6 }}>{t('game_category_label')} {room.category?.toUpperCase()}</div>
                    </motion.div>
                  )}
                  {isSpy && (
                    <div style={{ color: "#555", fontSize: 13, letterSpacing: 0.5, lineHeight: 1.8 }}>
                      {t('game_spy_hint').split('\n').map((l, i) => <span key={i}>{l}{i === 0 && <br />}</span>)}
                    </div>
                  )}
                </div>

                {/* Confirm read button */}
                {!iHaveReadCard && (
                  <motion.button initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.4 }}
                    whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
                    className="btn-red"
                    onClick={handleCardRead}
                    style={{ width: "100%", marginTop: 14, fontSize: 12 }}>
                    {t('game_ready_btn')}
                  </motion.button>
                )}
                {iHaveReadCard && (
                  <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
                    style={{ textAlign: "center", color: "#4ade80", fontSize: 11, letterSpacing: 2, fontFamily: "monospace", marginTop: 14 }}>
                    {t('game_waiting_others')}
                  </motion.div>
                )}
              </motion.div>
            )}
          </AnimatePresence>
        </div>

        {/* Progress: who has read */}
        <div style={{ width: "100%", position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 20 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #2a2a2a", borderLeft: "1px solid #2a2a2a" }} />
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#555", marginBottom: 14 }}>
            {t('game_cards_read')} {cardsRead.length}/{players.length}
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            {players.map(p => {
              const hasRead = cardsRead.includes(p.email);
              return (
                <div key={p.email} style={{
                  display: "flex", alignItems: "center", gap: 6, padding: "6px 10px",
                  background: hasRead ? "rgba(74,222,128,0.06)" : "#080808",
                  border: `1px solid ${hasRead ? "rgba(74,222,128,0.25)" : "#1a1a1a"}`,
                  fontFamily: "monospace", fontSize: 11, letterSpacing: 1,
                  color: hasRead ? "#4ade80" : "#444"
                }}>
                  <span>{p.avatar || "🕵️"}</span>
                  <span>{p.name}</span>
                  {hasRead && <span>✓</span>}
                </div>
              );
            })}
          </div>
        </div>
      </div>
      </>
    );
  }

  // Results screen
  if (room.question_phase === "results") {
    return (
      <>
        <GameToastContainer />
        <div style={{ maxWidth: 540, margin: "30px auto 0", padding: "0 20px" }}>
          <SyncStatusBanner state={syncState} t={t} />
          {pausePanel}
        </div>
        <RoundResults room={room} user={user} onContinue={() => {}} disabled={isGamePaused} />
      </>
    );
  }

  // Winner screen
  if (room.status === "finished" && room.winner) {
    const playAgainVotes = room.ready_players || [];
    const iWon = (isSpy && room.winner === "spy") || (isDetective && room.winner === "detectives");

    return (
      <>
      <GameToastContainer />
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", minHeight: "calc(100vh - 56px)", padding: 20, textAlign: "center" }}>
        <div style={{ width: "100%", maxWidth: 540 }}><SyncStatusBanner state={syncState} t={t} /></div>
        <motion.div initial={{ scale: 0, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} transition={{ type: "spring", stiffness: 200, delay: 0.1 }}
          style={{ fontSize: 72, marginBottom: 24 }}>{iWon ? "🏆" : "💀"}</motion.div>

        <motion.h1 initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
          style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 48, fontWeight: 700, letterSpacing: 4, marginBottom: 8 }}>
          {room.winner === "spy"
            ? <span style={{ color: "#e53535" }}>{t('game_spy_won')}</span>
            : <span style={{ color: "#e53535" }}>{t('game_detectives_won')}</span>}
        </motion.h1>

        <motion.p initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.3 }}
          style={{ color: "#555", fontSize: 12, letterSpacing: 3, marginBottom: 32 }}>
          {iWon ? t('game_mission_success') : t('game_mission_fail')}
        </motion.p>

        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.4 }}
          style={{ position: "relative", padding: "28px 48px", background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 28 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          <div style={{ fontSize: 10, color: "#333", letterSpacing: 4, marginBottom: 8 }}>{t('game_spy_reveal_label')}</div>
          <GlitchText text={room.word || ""} style={{ fontSize: 36, fontWeight: 700, color: "#e53535", letterSpacing: 6 }} speed={25} />
          <div style={{ color: "#333", fontSize: 10, letterSpacing: 3, marginTop: 8 }}>{room.category?.toUpperCase()}</div>
          {room.spy_guess && room.spy_guess !== "REVEALED" && (
            <div style={{ marginTop: 14, fontSize: 11, color: "#555", letterSpacing: 1 }}>
              {t('game_spy_guessed')} <strong style={{ color: room.spy_guess === room.word ? "#4ade80" : "#e53535" }}>{room.spy_guess}</strong>
            </div>
          )}
        </motion.div>

        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.5 }}
          style={{ color: "#444", fontSize: 11, letterSpacing: 2, marginBottom: 28 }}>
          {t('game_spy_was')} <strong style={{ color: "#888" }}>{spyPlayer?.avatar} {spyPlayer?.name?.toUpperCase() || "UNKNOWN"}</strong>
        </motion.div>

        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.6 }}
          style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 20, marginTop: 24, marginBottom: 16 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#555", marginBottom: 12 }}>// {t('game_play_again_vote')}</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 14 }}>
            {(room.players || []).map(p => {
              const hasVoted = playAgainVotes.includes(p.email);
              return (
                <div key={p.email} style={{ fontSize: 10, padding: "4px 8px", background: hasVoted ? "rgba(74,222,128,0.08)" : "#080808",
                  border: `1px solid ${hasVoted ? "rgba(74,222,128,0.3)" : "#1a1a1a"}`,
                  color: hasVoted ? "#4ade80" : "#333", fontFamily: "monospace", letterSpacing: 1 }}>
                  {hasVoted ? "✓" : "·"} {p.name}
                </div>
              );
            })}
          </div>
          <div style={{ fontSize: 12, color: "#666", letterSpacing: 0.5, marginBottom: 14, textAlign: "center" }}>
            {playAgainVotes.length} / {room.players?.length} {t('game_votes_needed')}
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {!playAgainVotes.includes(user?.email) ? (
              <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
                className="btn-red"
                onClick={async () => {
                  const currentRoom = roomRef.current || room;
                  const updatedRoom = await runGameRoomAction("vote_play_again", currentRoom.id);
                  const newVotes = updatedRoom.ready_players || [];
                  // If all voted and current user is host — start new game
                  if (newVotes.length >= (currentRoom.players || []).length && currentRoom.host_email === user.email) {
                    setTimeout(() => handlePlayAgain(), 300);
                  }
                }}
                style={{ fontSize: 11 }}>
                {t('game_play_again_vote')}
                </motion.button>
                ) : (
                <div style={{ textAlign: "center", color: "#4ade80", fontSize: 11, letterSpacing: 2, fontFamily: "monospace", padding: "10px 0" }}>
                {t('game_play_again_voted')}
                </div>
                )}
                </div>
                </motion.div>

                <div style={{ display: "flex", flexDirection: "column", gap: 10, width: "100%" }}>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
                className="btn-outline" onClick={() => navigate(createPageUrl("Room") + `?id=${room.id}`)} style={{ fontSize: 12, padding: "12px 36px" }}>
                {t('game_back_to_lobby')}
                </motion.button>
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
                className="btn-ghost" onClick={() => navigate(createPageUrl("Home"))} style={{ fontSize: 12, padding: "12px 36px" }}>
                {t('game_leave_room')}
                </motion.button>
                </div>
                </div>
                </>
                );
                }

  // Time expired - reveal spy and wait for guess
  if (timeExpired && !showSpyGuess) {
    const canGuess = isSpy;
    const isWaiting = !isSpy;
    
    return (
      <>
        <GameToastContainer />
        <div style={{ maxWidth: 540, margin: "0 auto", padding: "40px 20px 80px", textAlign: "center" }}>
          <SyncStatusBanner state={syncState} t={t} />
          <motion.div initial={{ scale: 0, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} transition={{ type: "spring", stiffness: 200 }}
            style={{ fontSize: 60, marginBottom: 24 }}>⏰</motion.div>

          <motion.h2 initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
            style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 36, fontWeight: 700, letterSpacing: 3, marginBottom: 16, color: "#e53535" }}>
            {t('game_time_up')}
          </motion.h2>

          {/* 30-second guess countdown */}
          {guessTimeLeft !== null && (
            <motion.div initial={{ opacity: 0, y: -10 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3 }}
              style={{ marginBottom: 24, width: "100%" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                <div style={{ fontSize: 10, letterSpacing: 3, color: "#666" }}>{t('game_spy_has') || "SPY HAS"}</div>
                <motion.div
                  animate={{ scale: guessTimeLeft <= 10 ? [1, 1.15, 1] : 1 }}
                  transition={{ duration: 0.4, repeat: Infinity }}
                  style={{ fontSize: 22, fontWeight: 700, fontFamily: "monospace", color: guessTimeLeft <= 10 ? "#e53535" : "#eee", letterSpacing: 1 }}>
                  {guessTimeLeft}s
                </motion.div>
              </div>
              {/* Progress bar */}
              <div style={{ width: "100%", height: 6, background: "#1a1a1a", borderRadius: 0, overflow: "hidden", position: "relative" }}>
                <motion.div
                  initial={{ width: "100%" }}
                  animate={{ width: `${(guessTimeLeft / 30) * 100}%` }}
                  transition={{ duration: 0.5, ease: "linear" }}
                  style={{
                    height: "100%",
                    background: guessTimeLeft <= 10 ? "#e53535" : guessTimeLeft <= 20 ? "#f59e0b" : "#4ade80",
                    boxShadow: guessTimeLeft <= 10 ? "0 0 8px rgba(229,53,53,0.7)" : "none",
                    transition: "background 0.3s"
                  }}
                />
              </div>
              <div style={{ fontSize: 10, letterSpacing: 2, color: "#444", marginTop: 6, textAlign: "right" }}>{t('game_to_guess') || "TO GUESS"}</div>
            </motion.div>
          )}

          <motion.div initial={{ opacity: 0, scale: 0.95 }} animate={{ opacity: 1, scale: 1 }} transition={{ delay: 0.3 }}
            style={{ position: "relative", padding: "32px 28px", background: "rgba(229,53,53,0.05)", border: "1px solid rgba(229,53,53,0.3)", marginBottom: 28 }}>
            <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
            <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
            <div style={{ fontSize: 11, letterSpacing: 2, color: "#e53535", marginBottom: 12 }}>{t('game_spy_reveal_label')}</div>
            <GlitchText text={room.word || ""} style={{ fontSize: 40, fontWeight: 700, color: "#e53535", letterSpacing: 6, marginBottom: 12 }} speed={25} />
            <div style={{ color: "#666", fontSize: 11, letterSpacing: 2 }}>{room.category?.toUpperCase()}</div>
          </motion.div>

          <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.4 }}
            style={{ position: "relative", padding: 20, background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 28 }}>
            <div style={{ fontSize: 11, letterSpacing: 2, color: "#555", marginBottom: 12 }}>{t('game_time_spy_must_guess')}</div>
            <div style={{ fontSize: 28, marginBottom: 8 }}>{spyPlayer?.avatar}</div>
            <div style={{ fontSize: 16, color: "#eee", letterSpacing: 1 }}>{spyPlayer?.name?.toUpperCase()}</div>
          </motion.div>

          {canGuess && (
            <motion.button whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
              className="btn-red"
              onClick={() => setShowSpyGuess(true)}
              style={{ width: "100%", fontSize: 14, padding: "16px 0", marginBottom: 16 }}>
              {t('game_guess_btn')}
            </motion.button>
          )}

          {isWaiting && (
            <motion.div animate={{ opacity: [1, 0.3, 1] }} transition={{ duration: 1.5, repeat: Infinity }}
              style={{ fontSize: 13, color: "#666", letterSpacing: 1, fontFamily: "monospace", padding: "16px 0" }}>
              {t('game_waiting_spy')}
            </motion.div>
          )}
        </div>
      </>
    );
  }

  // Spy word-guess modal
  if (showSpyGuess && !isGamePaused) {
    return (
      <AnimatePresence>
        <SpyGuessModal
          wordPool={room.word_pool || []}
          onGuess={handleSpyGuess}
          onClose={() => setShowSpyGuess(false)}
        />
      </AnimatePresence>
    );
  }

  return (
    <>
    <GameToastContainer />
    <div style={{ maxWidth: 540, margin: "0 auto", padding: "40px 20px 80px" }}>
      <SyncStatusBanner state={syncState} t={t} />
      {pausePanel}
      {/* Breadcrumb */}
      <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 20, fontFamily: "monospace", display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
         <div className="hidden sm:flex" style={{ alignItems: "center", gap: 8 }}>
            <Link to={createPageUrl("Home")} style={{ color: "#e53535", textDecoration: "none" }}>{t('game_home_link')}</Link>
            <span style={{ color: "#333" }}>//</span>
            <span>{t('game_round_label')} {room.round_number || 1}</span>
            <span style={{ color: "#333" }}>//</span>
            <span style={{ color: "#555" }}>{t('game_question_label')} {(room.questions_in_round || 0) + 1}/8</span>
         </div>
         <motion.button whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
            className="btn-ghost" onClick={handleLeave}
            style={{ fontSize: 10, padding: "6px 12px", marginLeft: "auto" }}>
            ✕ {t('game_home_btn')}
         </motion.button>
      </motion.div>

      {/* Timer */}
      {allCardsRead && !timeExpired && timeLeft !== null && (
        <motion.div initial={{ opacity: 0, y: -10 }} animate={{ opacity: 1, y: 0 }}
          style={{ position: "relative", padding: 16, background: "#080808", border: "1px solid #1e1e1e", marginBottom: 20, textAlign: "center" }}>
          <div style={{ fontSize: 11, letterSpacing: 2, color: isGamePaused ? "#e53535" : "#555", marginBottom: 8 }}>
            {isGamePaused ? t('game_paused') : t('game_time_left')}
          </div>
          <motion.div animate={{ scale: timeLeft <= 60 ? [1, 1.05, 1] : 1 }} transition={{ duration: 0.6, repeat: Infinity }}
            style={{ fontSize: 32, fontWeight: 700, color: timeLeft <= 60 ? "#e53535" : "#4ade80", fontFamily: "monospace", letterSpacing: 2 }}>
            {formatTime(timeLeft)}
          </motion.div>
        </motion.div>
      )}

      {/* Round based on game mode */}
      {room?.game_mode === "associations" ? (
        <AssociationRound room={room} user={user} disabled={isGamePaused} />
      ) : (
        <QuestionRound room={room} user={user} onRoundComplete={handleRoundComplete} disabled={timeExpired || isGamePaused} />
      )}

      {/* Role card */}
      <AnimatePresence mode="wait">
        {!revealed ? (
          <motion.div key="hidden" initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, scale: 0.95 }} style={{ marginBottom: 20 }}>
            <motion.div whileHover={{ borderColor: "#e53535", boxShadow: "0 0 30px rgba(229,53,53,0.1)" }}
              onClick={() => { sounds.click(); setRevealed(true); }}
              style={{
                cursor: "pointer", padding: "40px 32px", background: "#0a0a0a",
                border: "1px solid #1e1e1e", textAlign: "center",
                position: "relative", transition: "all 0.3s", userSelect: "none"
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
              <motion.div animate={{ opacity: [1, 0.5, 1] }} transition={{ duration: 2.5, repeat: Infinity }} style={{ fontSize: 52, marginBottom: 16 }}>🂠</motion.div>
              <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 16, letterSpacing: 3, marginBottom: 8 }}>{t('game_tap_to_reveal')}</div>
              <div style={{ color: "#333", fontSize: 10, letterSpacing: 3 }}>{t('game_dont_show')}</div>
            </motion.div>
          </motion.div>
        ) : (
          <motion.div key="revealed" initial={{ opacity: 0, scale: 0.95, y: 10 }} animate={{ opacity: 1, scale: 1, y: 0 }} transition={{ type: "spring", stiffness: 200 }} style={{ marginBottom: 20 }}>
            <div style={{
              padding: "28px 24px", textAlign: "center", position: "relative",
              background: isSpy ? "rgba(229,53,53,0.05)" : "rgba(255,255,255,0.02)",
              border: `1px solid ${isSpy ? "rgba(229,53,53,0.35)" : "#1e1e1e"}`,
            }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: `1px solid ${isSpy ? "#e53535" : "#333"}`, borderLeft: `1px solid ${isSpy ? "#e53535" : "#333"}` }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: `1px solid ${isSpy ? "#e53535" : "#333"}`, borderRight: `1px solid ${isSpy ? "#e53535" : "#333"}` }} />
              <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ type: "spring", stiffness: 300 }} style={{ fontSize: 48, marginBottom: 12 }}>
                {isSpy ? "🕵️" : "🔍"}
              </motion.div>
              <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 22, fontWeight: 700, letterSpacing: 4, marginBottom: 10, color: isSpy ? "#e53535" : "#fff" }}>
                {isSpy ? t('game_you_are_spy') : t('game_you_are_detective')}
              </div>
              {!isSpy && (
                <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3 }}>
                  <div style={{ color: "#444", fontSize: 10, letterSpacing: 4, marginBottom: 10 }}>{t('game_secret_word_label')}</div>
                  <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 38, fontWeight: 700, color: "#e53535", letterSpacing: 4 }}>{room.word}</div>
                  <div style={{ color: "#333", fontSize: 10, letterSpacing: 3, marginTop: 6 }}>{t('game_category_label')} {room.category?.toUpperCase()}</div>
                </motion.div>
              )}
              {isSpy && (
                <div style={{ color: "#555", fontSize: 12, letterSpacing: 1, lineHeight: 1.8 }}>
                  {t('game_spy_hint').split('\n').map((l, i) => <span key={i}>{l}{i === 0 && <br />}</span>)}
                </div>
              )}
              </div>

              {/* Hide card button */}
              <motion.button initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.5 }}
              className="btn-ghost" onClick={() => setRevealed(false)}
              style={{ width: "100%", marginTop: 12, fontSize: 11 }}>
              {t('game_hide_card_btn') || 'HIDE CARD'}
              </motion.button>
              </motion.div>
              )}
              </AnimatePresence>

      {/* Spy: early guess button */}
      {isSpy && revealed && !isSpectator && !isGamePaused && (
        <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
          style={{ position: "relative", background: "rgba(229,53,53,0.04)", border: "1px solid rgba(229,53,53,0.2)", padding: 20, marginBottom: 16 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#e53535", marginBottom: 12 }}>{t('game_early_guess_title')}</div>
          <p style={{ color: "#666", fontSize: 13, letterSpacing: 0.5, lineHeight: 1.8, marginBottom: 16 }}>
            {t('game_early_guess_desc')}
          </p>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
            className="btn-red" onClick={() => setShowSpyGuess(true)} style={{ width: "100%", fontSize: 11 }}>
            {t('game_early_guess_btn')}
          </motion.button>
        </motion.div>
      )}

      {/* Vote request section */}
      {!timeExpired && !isSpectator && !isGamePaused && (
        <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
          style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 20, marginBottom: 16 }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#555", marginBottom: 12 }}>{t('game_vote_title')}</div>

          {!votingActive ? (
            <>
              <div style={{ fontSize: 13, color: "#666", letterSpacing: 0.5, lineHeight: 1.7, marginBottom: 14 }}>
                {t('game_vote_desc')} {activeVoteRequests.length}/{voteThreshold} {t('game_vote_agree')}
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 14 }}>
                {activePlayers.map(p => (
                  <div key={p.email} style={{ fontSize: 10, padding: "4px 8px", background: voteRequests.includes(p.email) ? "rgba(74,222,128,0.08)" : "#080808",
                    border: `1px solid ${voteRequests.includes(p.email) ? "rgba(74,222,128,0.3)" : "#1a1a1a"}`,
                    color: voteRequests.includes(p.email) ? "#4ade80" : "#333", fontFamily: "monospace", letterSpacing: 1 }}>
                    {voteRequests.includes(p.email) ? "✓" : "·"} {p.name}
                  </div>
                ))}
              </div>
              {!voteRequests.includes(user.email) ? (
                <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
                  className="btn-outline" onClick={handleRequestVote} disabled={requestingVote}
                  style={{ width: "100%", fontSize: 11 }}>
                  {requestingVote ? "..." : t('game_vote_request_btn')}
                </motion.button>
              ) : (
                <div style={{ textAlign: "center", color: "#4ade80", fontSize: 11, letterSpacing: 2, fontFamily: "monospace" }}>
                  {t('game_vote_requested')}
                </div>
              )}
            </>
          ) : !myVote ? (
            <>
              <div style={{ fontSize: 14, color: "#eee", letterSpacing: 0.5, marginBottom: 16 }}>
                {t('game_vote_started')}
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {activePlayers.filter(p => p.email !== user.email).map(p => (
                  <motion.button key={p.email} whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
                    onClick={() => handleVoteForPlayer(p.email)} disabled={submittingVote}
                    style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 14px",
                      background: "#080808", border: "1px solid #1e1e1e", cursor: "pointer",
                      textAlign: "left", transition: "all 0.15s" }}
                    onMouseEnter={e => { e.currentTarget.style.border = "1px solid rgba(229,53,53,0.4)"; e.currentTarget.style.background = "rgba(229,53,53,0.05)"; }}
                    onMouseLeave={e => { e.currentTarget.style.border = "1px solid #1e1e1e"; e.currentTarget.style.background = "#080808"; }}>
                    <span style={{ fontSize: 22 }}>{p.avatar || "🕵️"}</span>
                    <span style={{ fontFamily: "monospace", fontSize: 14, letterSpacing: 1, color: "#eee", flex: 1 }}>{p.name.toUpperCase()}</span>
                    <span style={{ fontSize: 11, color: "#666", letterSpacing: 1 }}>{t('game_vote_spy_q')}</span>
                  </motion.button>
                ))}
              </div>
            </>
          ) : (
            <div style={{ textAlign: "center" }}>
              <motion.div animate={{ opacity: [1, 0.3, 1] }} transition={{ duration: 2, repeat: Infinity }}
                style={{ color: "#777", fontSize: 13, letterSpacing: 1, fontFamily: "monospace" }}>
                {t('game_vote_accepted')} ({votes.length}/{activePlayers.length})
              </motion.div>
            </div>
          )}
        </motion.div>
      )}

      {/* Spectator: show voting as observer */}
      {!timeExpired && !isGamePaused && isSpectator && votingActive && (
        <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}
          style={{ position: "relative", background: "#0a0a0a", border: "1px solid #222", padding: 20, marginBottom: 16 }}>
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#444", marginBottom: 12 }}>{t('game_voting_in_progress')}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {activePlayers.map(p => {
              const votesForP = votes.filter(v => v.voted_for_email === p.email).length;
              return (
                <div key={p.email} style={{ display: "flex", alignItems: "center", gap: 12, padding: "10px 14px", background: "#080808", border: "1px solid #1a1a1a" }}>
                  <span style={{ fontSize: 20 }}>{p.avatar || "🕵️"}</span>
                  <span style={{ fontFamily: "monospace", fontSize: 13, color: "#888", flex: 1 }}>{p.name.toUpperCase()}</span>
                  {votesForP > 0 && <span style={{ fontSize: 11, color: "#e53535", letterSpacing: 1 }}>▲ {votesForP}</span>}
                </div>
              );
            })}
          </div>
        </motion.div>
      )}

      {/* Players list */}
      <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
        style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 20, marginBottom: 16 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #2a2a2a", borderLeft: "1px solid #2a2a2a" }} />
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 14 }}>
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#555" }}>{t('game_agents_label')} ({activePlayers.length})</div>
          {spectators.length > 0 && (
            <div style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, color: "#444", fontFamily: "monospace", letterSpacing: 1 }}>
              <span>👁</span>
              <span>{spectators.length}</span>
            </div>
          )}
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          {players.map((p, i) => {
            const pIsSpectator = spectators.includes(p.email);
            const isCurrentAnswerer = p.email === room.current_answerer_email;
            const isCurrentAsker = p.email === room.current_asker_email;
            const isSpy_ = p.email === room.spy_email;
            return (
              <motion.div key={p.email} initial={{ opacity: 0, scale: 0.8 }} animate={{ opacity: 1, scale: 1 }} transition={{ delay: i * 0.06 }}
                style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4, padding: "8px 10px",
                  background: pIsSpectator ? "#050505" : "#080808",
                  border: `1px solid ${pIsSpectator ? "#111" : isCurrentAnswerer ? "rgba(229,53,53,0.4)" : isCurrentAsker ? "rgba(100,100,200,0.4)" : "#141414"}`,
                  textAlign: "center", minWidth: 64, opacity: pIsSpectator ? 0.5 : 1 }}>
                <div style={{ position: "relative" }}>
                  <span style={{ fontSize: 22 }}>{pIsSpectator ? "👁" : (p.avatar || "🕵️")}</span>
                  {/* Show spy marker to spectators */}
                  {isSpectator && isSpy_ && (
                    <span style={{ position: "absolute", top: -4, right: -6, fontSize: 10, background: "#e53535", color: "#fff", borderRadius: 2, padding: "0 3px", fontWeight: 700 }}>{t('game_spy_badge')}</span>
                  )}
                </div>
                <span style={{ fontSize: 11, letterSpacing: 0.5, color: pIsSpectator ? "#333" : "#aaa", fontFamily: "monospace" }}>
                  {p.name.length > 8 ? p.name.substring(0, 7) + "…" : p.name}
                  {p.email === user.email ? ` (${t('room_you')})` : ""}
                </span>
              </motion.div>
            );
          })}
        </div>
      </motion.div>

      {/* Spectator banner */}
      {isSpectator && (
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
          style={{ position: "relative", padding: 16, background: "rgba(255,255,255,0.02)", border: "1px solid #1a1a1a", marginBottom: 16, textAlign: "center" }}>
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#444", marginBottom: 6 }}>{t('game_spectator_mode')}</div>
           <div style={{ fontSize: 13, color: "#666", letterSpacing: 0.5 }}>
             {t('game_spy_label')} <strong style={{ color: "#e53535" }}>{spyPlayer?.avatar} {spyPlayer?.name}</strong>
           </div>
           <div style={{ fontSize: 10, color: "#333", letterSpacing: 1, marginTop: 6 }}>{t('game_secret_word_short')} <strong style={{ color: "#555" }}>{room.word}</strong></div>
        </motion.div>
      )}
    </div>
    </>
  );
}

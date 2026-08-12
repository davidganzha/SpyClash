import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";
import GameToastContainer, { gameToast } from "../components/GameToast";
import {
  OnlineActiveGameScene,
  OnlineRoleRevealScene,
} from "../components/online/OnlineGameExperience";
import SpyGuessModal from "../components/SpyGuessModal";
import GlitchText from "../components/ui/GlitchText";
import { useGameSounds } from "../components/useGameSounds";
import {
  getGameRoom,
  leaveGameRoom,
  performGameRoomAction,
  runGameRoomAction,
  subscribeGameRoom,
} from "@/lib/gameRoomActions";
import {
  isRetryableDetectiveVoteCastConflict,
  recoverDetectiveVoteCastConflict,
} from "@/lib/detectiveVoteRetry";
import {
  gameTimerSnapshot,
  isAuthoritativeDetectiveVoteRefreshConflict,
} from "@/lib/gameRoomSync";
import {
  deriveOnlineGamePresentation,
  onlineVotingTransition,
  shouldAcceptOnlineRoomSnapshot,
} from "@/lib/onlineGamePresentation";
import {
  isRankedSpyRoom,
  isSpyEmailForRoom,
  publicSpyCount,
  resultSpyPlayers,
} from "@/lib/multiSpyRules";
import { exitRoomImmediately } from "@/lib/roomExit";
import { createPageUrl } from "@/utils";

const ROUND_ACTIONS = new Set([
  "mark_answer_heard",
  "continue_round",
  "start_association",
  "advance_association",
]);

const normalizedEmail = (value) => String(value ?? "").trim().toLocaleLowerCase();

function SyncStatusBanner({ state, t }) {
  if (state === "connected") return null;
  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        marginBottom: 14,
        padding: "10px 14px",
        border: "1px solid rgba(229,53,53,0.45)",
        background: "rgba(229,53,53,0.08)",
        color: "#e53535",
        fontFamily: "monospace",
        fontSize: 10,
        letterSpacing: 2,
        textAlign: "center",
      }}
    >
      ↻ {t("room_sync_reconnecting")}
    </div>
  );
}

function LoadingScreen({ t }) {
  return (
    <>
      <GameToastContainer />
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "100dvh" }}>
        <motion.div
          animate={{ opacity: [0.3, 1, 0.3] }}
          transition={{ duration: 1.5, repeat: Infinity }}
          style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}
        >
          {t("loading")}
        </motion.div>
      </div>
    </>
  );
}

function WinnerScreen({
  room,
  user,
  isSpy,
  isDetective,
  spyPlayers,
  syncState,
  busyAction,
  onVoteReplay,
  onResetReplay,
  onLeave,
  t,
}) {
  const replayVotes = room.ready_players || [];
  const hasVoted = replayVotes.includes(user.email);
  const allVoted = (room.players || []).length > 0
    && (room.players || []).every((player) => replayVotes.includes(player.email));
  const isHost = room.host_email === user.email;
  const iWon = (isSpy && room.winner === "spy")
    || (isDetective && room.winner === "detectives");
  const spyCount = publicSpyCount(room);
  const pluralSpies = spyCount > 1;

  return (
    <>
      <GameToastContainer />
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", minHeight: "100dvh", padding: "40px 20px", textAlign: "center" }}>
        <div style={{ width: "100%", maxWidth: 540 }}>
          <SyncStatusBanner state={syncState} t={t} />
        </div>
        <motion.div
          initial={{ scale: 0, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ type: "spring", stiffness: 200, delay: 0.1 }}
          style={{ fontSize: 72, marginBottom: 24 }}
        >
          {iWon ? "🏆" : "💀"}
        </motion.div>
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
          style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: "clamp(34px, 9vw, 48px)", fontWeight: 700, letterSpacing: 4, marginBottom: 8, color: "#e53535" }}
        >
          {room.winner === "spy"
            ? t(pluralSpies ? "game_spies_won" : "game_spy_won")
            : t("game_detectives_won")}
        </motion.h1>
        <motion.p
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.3 }}
          style={{ color: "#555", fontSize: 12, letterSpacing: 3, marginBottom: 32 }}
        >
          {iWon ? t("game_mission_success") : t("game_mission_fail")}
        </motion.p>

        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.4 }}
          style={{ width: "min(100%, 440px)", padding: "28px 24px", background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 24 }}
        >
          <div style={{ fontSize: 10, color: "#555", letterSpacing: 4, marginBottom: 8 }}>{t("game_spy_reveal_label")}</div>
          <GlitchText text={room.word || room.secret_word || ""} style={{ fontSize: 36, fontWeight: 700, color: "#e53535", letterSpacing: 6 }} speed={25} />
          <div style={{ color: "#555", fontSize: 10, letterSpacing: 3, marginTop: 8 }}>{room.category?.toUpperCase()}</div>
          {room.spy_guess && room.spy_guess !== "REVEALED" && (
            <div style={{ marginTop: 14, fontSize: 11, color: "#777", letterSpacing: 1 }}>
              {t(pluralSpies ? "game_spy_team_guessed" : "game_spy_guessed")} <strong style={{ color: room.spy_guess === (room.word || room.secret_word) ? "#4ade80" : "#e53535" }}>{room.spy_guess}</strong>
            </div>
          )}
        </motion.div>

        <div style={{ color: "#666", fontSize: 11, letterSpacing: 2, marginBottom: 24 }}>
          {t(pluralSpies ? "game_spies_were" : "game_spy_was")}{" "}
          <strong style={{ color: "#aaa" }}>
            {(spyPlayers || []).length > 0
              ? spyPlayers.map((player) => `${player.avatar || "•"} ${String(player.name || t("game_unknown")).toUpperCase()}`).join(" · ")
              : t("game_unknown")}
          </strong>
        </div>

        {!isRankedSpyRoom(room) && (
          <div style={{ color: "#fbbf24", fontSize: 10, letterSpacing: 2, marginBottom: 18 }}>
            // {t("game_unranked_match")}
          </div>
        )}

        <div style={{ width: "min(100%, 440px)", padding: 20, background: "#0a0a0a", border: "1px solid #1e1e1e" }}>
          <div style={{ fontSize: 11, letterSpacing: 2, color: "#666", marginBottom: 12 }}>
            // {t("game_play_again_vote")} · {replayVotes.length}/{(room.players || []).length}
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6, justifyContent: "center", marginBottom: 16 }}>
            {(room.players || []).map((player) => {
              const accepted = replayVotes.includes(player.email);
              return (
                <span
                  key={player.email}
                  style={{ padding: "5px 8px", border: `1px solid ${accepted ? "rgba(74,222,128,0.3)" : "#1a1a1a"}`, color: accepted ? "#4ade80" : "#444", fontFamily: "monospace", fontSize: 10 }}
                >
                  {accepted ? "✓" : "·"} {player.name}
                </span>
              );
            })}
          </div>
          {!hasVoted ? (
            <button type="button" className="btn-red" onClick={onVoteReplay} disabled={Boolean(busyAction)} style={{ width: "100%", marginBottom: 10 }}>
              {busyAction === "vote_play_again" ? "…" : t("game_play_again_vote")}
            </button>
          ) : (
            <div style={{ color: "#4ade80", fontFamily: "monospace", fontSize: 11, letterSpacing: 2, padding: 10 }}>
              {t("game_play_again_voted")}
            </div>
          )}
          {isHost && (
            <button type="button" className={allVoted ? "btn-red" : "btn-outline"} onClick={onResetReplay} disabled={Boolean(busyAction)} style={{ width: "100%", marginBottom: 10 }}>
              {busyAction === "reset_room_for_replay" ? "…" : allVoted ? t("game_play_again_vote") : t("game_back_to_lobby")}
            </button>
          )}
          {!isHost && allVoted && (
            <div style={{ color: "#666", fontFamily: "monospace", fontSize: 10, letterSpacing: 1, padding: 10 }}>
              {t("game_waiting_others")}
            </div>
          )}
          <button type="button" className="btn-ghost" onClick={onLeave} style={{ width: "100%" }}>
            {t("game_leave_room")}
          </button>
        </div>
      </div>
    </>
  );
}

export default function Game() {
  const { lang, t } = useLanguage();
  const navigate = useNavigate();
  const sounds = useGameSounds();
  const soundsRef = useRef(sounds);
  soundsRef.current = sounds;

  const [room, setRoom] = useState(null);
  const [user, setUser] = useState(null);
  const [revealed, setRevealed] = useState(false);
  const [showSpyGuess, setShowSpyGuess] = useState(false);
  const [syncState, setSyncState] = useState("connected");
  const [busyAction, setBusyAction] = useState(null);
  const [timeLeft, setTimeLeft] = useState(null);
  const [timeExpired, setTimeExpired] = useState(false);

  const roomRef = useRef(null);
  const prevRoomRef = useRef(null);
  const unsubRef = useRef(null);
  const timerRef = useRef(null);
  const expirationRetryTimerRef = useRef(null);
  const actionInFlightRef = useRef(null);
  const leavingRef = useRef(false);
  const finalizingExpiredRef = useRef(false);

  const getRoomId = () => new URLSearchParams(window.location.search).get("id");

  const applyRoom = useCallback((updated) => {
    if (!shouldAcceptOnlineRoomSnapshot(roomRef.current, updated)) return false;
    roomRef.current = updated;
    prevRoomRef.current = updated;
    setRoom(updated);
    const snapshot = gameTimerSnapshot(updated);
    if (snapshot.valid) {
      setTimeLeft(snapshot.remainingSeconds);
      setTimeExpired(snapshot.remainingSeconds === 0);
    }
    return true;
  }, []);

  const runSynchronizedAction = useCallback(async (action, fields = {}) => {
    const currentRoom = roomRef.current;
    if (!currentRoom || actionInFlightRef.current) return null;
    actionInFlightRef.current = action;
    setBusyAction(action);
    const adoptAuthoritativeVoteRefresh = async (label) => {
      try {
        const refreshed = await getGameRoom(currentRoom.id);
        if (
          refreshed?.id === currentRoom.id
          && String(refreshed.match_id || "") === String(currentRoom.match_id || "")
        ) {
          const latestRoom = roomRef.current;
          if (
            latestRoom?.id === currentRoom.id
            && !shouldAcceptOnlineRoomSnapshot(latestRoom, refreshed)
          ) return latestRoom;

          const votingTransition = onlineVotingTransition(
            latestRoom || currentRoom,
            refreshed,
            user?.email,
          );
          if (applyRoom(refreshed)) {
            if (votingTransition === "cancelled") {
              gameToast(t("toast_voting_cancelled"), "warning", "✕");
            }
            return refreshed;
          }
        }
      } catch (refreshError) {
        console.error(`Failed to reconcile ${label}`, refreshError);
      }
      // These typed conflicts describe an expected stale race. Realtime/polling
      // remains authoritative if this bounded refresh itself is unavailable;
      // do not replace that with a generic yellow action error.
      return roomRef.current?.id === currentRoom.id ? roomRef.current : null;
    };
    try {
      const updated = await runGameRoomAction(action, currentRoom.id, fields);
      if (updated?.id) {
        const latestRoom = roomRef.current || currentRoom;
        const votingTransition = onlineVotingTransition(
          latestRoom,
          updated,
          user?.email,
        );
        if (!applyRoom(updated)) return null;
        if (votingTransition === "cancelled") {
          gameToast(t("toast_voting_cancelled"), "warning", "✕");
        }
      }
      return updated;
    } catch (error) {
      let visibleError = error;
      if (isAuthoritativeDetectiveVoteRefreshConflict(action, error)) {
        return await adoptAuthoritativeVoteRefresh("detective vote state");
      }
      if (isRetryableDetectiveVoteCastConflict(action, error)) {
        try {
          const recovered = await recoverDetectiveVoteCastConflict({
            action,
            error,
            room: currentRoom,
            actorEmail: user?.email,
            targetEmail: fields?.target_email,
            refreshRoom: getGameRoom,
            castVote: ({ roomId, targetEmail, expectedVoteRoundID }) =>
              performGameRoomAction({
                action: "cast_detective_vote",
                room_id: roomId,
                target_email: targetEmail,
                expected_vote_round_id: expectedVoteRoundID,
              }),
          });
          const latestRoom = roomRef.current;
          if (
            latestRoom?.id === currentRoom.id
            && !shouldAcceptOnlineRoomSnapshot(latestRoom, recovered)
          ) return latestRoom;
          const votingTransition = onlineVotingTransition(
            latestRoom || currentRoom,
            recovered,
            user?.email,
          );
          if (applyRoom(recovered)) {
            if (votingTransition === "cancelled") {
              gameToast(t("toast_voting_cancelled"), "warning", "✕");
            }
            return recovered;
          }
        } catch (recoveryError) {
          visibleError = recoveryError;
        }
      }
      if (isAuthoritativeDetectiveVoteRefreshConflict(action, visibleError)) {
        return await adoptAuthoritativeVoteRefresh("detective vote retry state");
      }
      console.error(`Failed room action: ${action}`, visibleError);
      gameToast(visibleError?.message || localize(lang, "Room action failed", "Не удалось выполнить действие в комнате", "Не вдалося виконати дію в кімнаті"), "warning", "⚠️");
      return null;
    } finally {
      actionInFlightRef.current = null;
      setBusyAction(null);
    }
  }, [applyRoom, lang, t, user?.email]);

  const loadRoom = async (currentUser) => {
    const id = getRoomId();
    if (!id) {
      navigate(createPageUrl("Home"));
      return;
    }
    const initialRoom = await getGameRoom(id);
    if (!initialRoom) {
      navigate(createPageUrl("Home"));
      return;
    }
    applyRoom(initialRoom);

    unsubRef.current = subscribeGameRoom(id, async (event) => {
      if (event.id !== id) return;
      if (event.type === "sync") {
        setSyncState(event.state);
        return;
      }
      if (event.type === "delete") {
        navigate(createPageUrl("Home"));
        return;
      }

      let fresh = event.data;
      if (!fresh) fresh = await getGameRoom(id);
      if (!fresh) return;
      if (!shouldAcceptOnlineRoomSnapshot(roomRef.current, fresh)) return;
      const previous = prevRoomRef.current;

      if (previous) {
        const previousPlayers = previous.players || [];
        (fresh.players || []).forEach((player) => {
          if (!previousPlayers.some((candidate) => candidate.email === player.email)) {
            gameToast(`${player.name} ${t("toast_joined")}`, "join", player.avatar || "👤");
            soundsRef.current.playerJoined();
          }
        });
        previousPlayers.forEach((player) => {
          if (!(fresh.players || []).some((candidate) => candidate.email === player.email)) {
            gameToast(`${player.name} ${t("toast_left")}`, "leave", "👋");
          }
        });

        if (previous.round_number !== fresh.round_number) {
          gameToast(`${t("game_round_label")} ${fresh.round_number} ${t("toast_round_started")}`, "round", "🎯");
          soundsRef.current.roundStart();
        }

        const votingTransition = onlineVotingTransition(previous, fresh, currentUser.email);
        if (votingTransition === "started") {
          gameToast(t("toast_voting_started"), "warning", "🗳️");
          soundsRef.current.alert();
        } else if (votingTransition === "cancelled") {
          gameToast(t("toast_voting_cancelled"), "warning", "✕");
        }
      }

      if (fresh.status === "waiting" && ["finished", "playing"].includes(previous?.status)) {
        applyRoom(fresh);
        navigate(createPageUrl("Room") + `?id=${id}`);
        return;
      }

      applyRoom(fresh);
      setSyncState("connected");
    }, {
      userId: currentUser.id,
      currentRoomRevision: () => roomRef.current?.room_revision,
    });
  };

  useEffect(() => {
    let disposed = false;
    base44.auth.me().then((currentUser) => {
      if (disposed) return;
      if (!currentUser) {
        base44.auth.redirectToLogin(undefined);
        return;
      }
      setUser(currentUser);
      void loadRoom(currentUser).catch(() => {
        if (!disposed) navigate(createPageUrl("Home"));
      });
    }).catch(() => {
      if (!disposed) navigate(createPageUrl("Home"));
    });

    return () => {
      disposed = true;
      unsubRef.current?.();
      if (timerRef.current) clearInterval(timerRef.current);
      if (expirationRetryTimerRef.current) clearInterval(expirationRetryTimerRef.current);
    };
  }, []);

  const presentation = useMemo(() => {
    if (!room || !user) return {};
    const players = room.players || [];
    const spectatorEmails = new Set((room.spectators || []).map(normalizedEmail));
    const cardReaderEmails = new Set((room.cards_read || []).map(normalizedEmail));
    const userEmail = normalizedEmail(user.email);
    const online = deriveOnlineGamePresentation(room, user.email);
    return {
      allCardsRead: players.length > 0
        && players.every((player) => cardReaderEmails.has(normalizedEmail(player.email))),
      isSpy: online.viewerRole === "spy",
      isDetective: online.viewerRole === "detective",
      isSpectator: spectatorEmails.has(userEmail),
      spyPlayers: resultSpyPlayers(room),
    };
  }, [room, user]);

  const {
    allCardsRead = false,
    isSpy = false,
    isDetective = false,
    spyPlayers = [],
  } = presentation;
  const isGamePaused = Boolean(String(room?.game_paused_at ?? "").trim());

  useEffect(() => {
    if (!allCardsRead || timeExpired || room?.status !== "playing") return undefined;
    if (!room?.game_started_at || !room?.game_duration_seconds) return undefined;

    const tick = () => {
      const snapshot = gameTimerSnapshot(roomRef.current || room);
      if (!snapshot.valid) return;
      setTimeLeft(snapshot.remainingSeconds);
      if (snapshot.remainingSeconds === 0) {
        setTimeExpired(true);
        clearInterval(timerRef.current);
        soundsRef.current.alert();
        gameToast(t("toast_time_up"), "warning", "⏰");
      }
    };

    tick();
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(tick, 1000);
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [
    allCardsRead,
    timeExpired,
    room?.status,
    room?.game_started_at,
    room?.game_duration_seconds,
    room?.game_paused_at,
    room?.game_paused_total_seconds,
  ]);

  useEffect(() => {
    if (!timeExpired || room?.status === "finished") return undefined;
    if (!room?.game_started_at || !room?.game_duration_seconds) return undefined;

    const finalize = async () => {
      const currentRoom = roomRef.current || room;
      if (
        currentRoom.status !== "finished"
        && (currentRoom.players || []).some(
          (player) => normalizedEmail(player.email) === normalizedEmail(user?.email),
        )
        && !finalizingExpiredRef.current
      ) {
        finalizingExpiredRef.current = true;
        try {
          const updated = await runGameRoomAction("finalize_expired_room", currentRoom.id);
          if (updated?.id) applyRoom(updated);
        } catch (error) {
          console.error("Failed to finalize expired room", error);
        } finally {
          finalizingExpiredRef.current = false;
        }
      }
    };

    void finalize();
    if (expirationRetryTimerRef.current) clearInterval(expirationRetryTimerRef.current);
    expirationRetryTimerRef.current = setInterval(() => void finalize(), 500);
    return () => {
      if (expirationRetryTimerRef.current) clearInterval(expirationRetryTimerRef.current);
    };
  }, [
    applyRoom,
    timeExpired,
    room?.status,
    room?.game_started_at,
    room?.game_duration_seconds,
    room?.game_paused_at,
    room?.game_paused_total_seconds,
    user?.email,
  ]);

  useEffect(() => {
    if (isGamePaused || timeExpired) setShowSpyGuess(false);
  }, [isGamePaused, timeExpired]);

  useEffect(() => {
    if (!room) return;
    const isCompleteResult = room.status === "finished" && Boolean(room.winner);
    if (room.status === "playing" || isCompleteResult) return;
    navigate(createPageUrl("Room") + `?id=${room.id}`, { replace: true });
  }, [navigate, room?.id, room?.status, room?.winner]);

  const handleLeave = useCallback(() => {
    const currentRoom = roomRef.current;
    if (!currentRoom || leavingRef.current) return;
    leavingRef.current = true;
    try {
      unsubRef.current?.();
    } catch {
      // Leaving locally must not depend on realtime cleanup.
    }
    unsubRef.current = null;
    void exitRoomImmediately({
      roomId: currentRoom.id,
      leaveRoom: leaveGameRoom,
      navigateHome: () => navigate(createPageUrl("Home"), { replace: true }),
    });
  }, [navigate]);

  const handleCardRead = useCallback(async () => {
    const currentRoom = roomRef.current;
    const userEmail = normalizedEmail(user?.email);
    if (
      !currentRoom
      || (currentRoom.cards_read || []).some((email) => normalizedEmail(email) === userEmail)
    ) return;
    const updated = await runSynchronizedAction("mark_role_card_read");
    if (updated) setRevealed(false);
  }, [runSynchronizedAction, user?.email]);

  const handleRoundAction = useCallback(async (action) => {
    if (!ROUND_ACTIONS.has(action)) return;
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.status !== "playing" || currentRoom.game_paused_at || timeExpired) return;
    return await runSynchronizedAction(action);
  }, [runSynchronizedAction, timeExpired]);

  const handleAdvanceQuestion = useCallback(async () => {
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.status !== "playing" || currentRoom.game_paused_at || timeExpired) return null;
    return await runSynchronizedAction("advance_question");
  }, [runSynchronizedAction, timeExpired]);

  const handleStopAssociationSpin = useCallback(async () => {
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.status !== "playing" || currentRoom.game_paused_at || timeExpired) return null;
    return await runSynchronizedAction("stop_association_spin");
  }, [runSynchronizedAction, timeExpired]);

  const handleRequestVote = useCallback(async () => {
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.status !== "playing" || currentRoom.game_paused_at || timeExpired) return;
    const viewerEmail = normalizedEmail(user?.email);
    if ((currentRoom.spectators || []).map(normalizedEmail).includes(viewerEmail)) return;
    if ((currentRoom.vote_requests || []).map(normalizedEmail).includes(viewerEmail)) return;
    soundsRef.current.alert();
    await runSynchronizedAction("request_vote");
  }, [runSynchronizedAction, timeExpired, user?.email]);

  const handleCastVote = useCallback(async (targetEmail) => {
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.status !== "playing" || currentRoom.game_paused_at || timeExpired) return;

    const viewerEmail = normalizedEmail(user?.email);
    const target = normalizedEmail(targetEmail);
    const spectators = new Set((currentRoom.spectators || []).map(normalizedEmail));
    const eliminated = new Set((currentRoom.eliminated_emails || []).map(normalizedEmail));
    if (!viewerEmail || spectators.has(viewerEmail) || !target || target === viewerEmail) return;

    const activeEmails = new Set(
      (currentRoom.players || [])
        .map((player) => normalizedEmail(player.email))
        .filter((email) => email && !spectators.has(email) && !eliminated.has(email)),
    );
    if (!activeEmails.has(viewerEmail) || !activeEmails.has(target)) return;

    const activeRequests = new Set(
      (currentRoom.vote_requests || [])
        .map(normalizedEmail)
        .filter((email) => activeEmails.has(email)),
    );
    if (activeRequests.size < Math.ceil(activeEmails.size * 0.51)) return;

    const alreadyVoted = (currentRoom.detective_votes || []).some(
      (vote) => normalizedEmail(vote.voter_email) === viewerEmail,
    );
    if (alreadyVoted) return;
    soundsRef.current.vote();
    const voteRoundID = String(currentRoom.detective_vote_round_id || "").trim();
    if (!voteRoundID) return;
    await runSynchronizedAction("cast_detective_vote", {
      target_email: targetEmail,
      expected_vote_round_id: voteRoundID,
    });
  }, [runSynchronizedAction, timeExpired, user?.email]);

  const handleTogglePause = useCallback(async () => {
    const currentRoom = roomRef.current;
    if (!currentRoom || currentRoom.host_email !== user?.email || !currentRoom.game_started_at) return;
    const action = currentRoom.game_paused_at ? "resume_game" : "pause_game";
    await runSynchronizedAction(action);
  }, [runSynchronizedAction, user?.email]);

  const handleSpyGuess = useCallback(async (guessedWord) => {
    const currentRoom = roomRef.current;
    const viewerEmail = normalizedEmail(user?.email);
    if (
      !currentRoom
      || currentRoom.status !== "playing"
      || currentRoom.game_paused_at
      || timeExpired
      || !isSpyEmailForRoom(currentRoom, viewerEmail)
      || (currentRoom.spectators || []).map(normalizedEmail).includes(viewerEmail)
      || (currentRoom.eliminated_emails || []).map(normalizedEmail).includes(viewerEmail)
    ) return;
    const updated = await runSynchronizedAction("submit_spy_guess", { guess: guessedWord });
    if (!updated) return;
    soundsRef.current[updated.winner === "spy" ? "win" : "lose"]();
    setShowSpyGuess(false);
  }, [runSynchronizedAction, timeExpired, user?.email]);

  const handleVoteReplay = useCallback(async () => {
    await runSynchronizedAction("vote_play_again");
  }, [runSynchronizedAction]);

  const handleResetReplay = useCallback(async () => {
    const updated = await runSynchronizedAction("reset_room_for_replay");
    if (updated?.id) navigate(createPageUrl("Room") + `?id=${updated.id}`);
  }, [navigate, runSynchronizedAction]);

  if (!room || !user) return <LoadingScreen t={t} />;

  if (room.status === "finished" && room.winner) {
    return (
      <WinnerScreen
        room={room}
        user={user}
        isSpy={isSpy}
        isDetective={isDetective}
        spyPlayers={spyPlayers}
        syncState={syncState}
        busyAction={busyAction}
        onVoteReplay={handleVoteReplay}
        onResetReplay={handleResetReplay}
        onLeave={handleLeave}
        t={t}
      />
    );
  }

  if (room.status !== "playing") return <LoadingScreen t={t} />;

  if (room.status === "playing" && (!allCardsRead || !room.game_started_at)) {
    return (
      <>
        <GameToastContainer />
        <OnlineRoleRevealScene
          room={room}
          user={user}
          revealed={revealed}
          confirming={busyAction === "mark_role_card_read"}
          syncState={syncState}
          onReveal={() => {
            soundsRef.current.cardFlip();
            setRevealed((value) => !value);
          }}
          onConfirm={handleCardRead}
          onLeave={handleLeave}
          t={t}
          lang={lang}
        />
      </>
    );
  }

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
      <OnlineActiveGameScene
        room={room}
        user={user}
        revealed={revealed}
        timeLeft={timeLeft ?? gameTimerSnapshot(room).remainingSeconds}
        timeExpired={timeExpired}
        syncState={syncState}
        busyAction={busyAction}
        onToggleRole={() => {
          soundsRef.current.cardFlip();
          setRevealed((value) => !value);
        }}
        onTogglePause={handleTogglePause}
        onLeave={handleLeave}
        onRoundAction={handleRoundAction}
        onAdvanceQuestion={handleAdvanceQuestion}
        onStopAssociationSpin={handleStopAssociationSpin}
        onRequestVote={handleRequestVote}
        onCastVote={handleCastVote}
        onSpyGuess={() => setShowSpyGuess(true)}
        t={t}
        lang={lang}
      />
    </>
  );
}

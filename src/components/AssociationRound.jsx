import { useState, useEffect, useRef } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { runGameRoomAction } from "@/lib/gameRoomActions";
import { isSpyEmailForRoom } from "@/lib/multiSpyRules";

// current_answer is reused to store JSON: { spoken: ["email1", "email2", ...], spinning: bool }
function parseAssocState(room) {
  try {
    if (room?.current_answer && room.current_answer.startsWith("{")) {
      return JSON.parse(room.current_answer);
    }
  } catch {}
  return { spoken: [], spinning: false };
}

export default function AssociationRound({ room, user, disabled = false }) {
  const { lang } = useLanguage();
  const [submitting, setSubmitting] = useState(false);
  const [localSpinning, setLocalSpinning] = useState(false);
  const [displayIndex, setDisplayIndex] = useState(0);
  const spinTimerRef = useRef(null);
  const prevCurrentAsker = useRef(room?.current_asker_email);

  const players = (room?.players || []).filter(p => !(room?.spectators || []).includes(p.email));
  const assocState = parseAssocState(room);
  const spokenEmails = assocState.spoken || [];
  const isSpinning = assocState.spinning || false;

  const currentPlayer = players.find(p => p.email === room?.current_asker_email);
  const isCurrentPlayer = room?.current_asker_email === user?.email;
  const isSpy = isSpyEmailForRoom(room, user?.email);
  const roundNumber = room?.round_number || 1;
  const isHost = room?.host_email === user?.email;

  // Animate the roulette drum locally when spinning
  useEffect(() => {
    if (!disabled && isSpinning && players.length > 0) {
      setLocalSpinning(true);
      let speed = 80;
      let count = 0;
      const maxSpins = 20 + Math.floor(Math.random() * 10);

      const spin = () => {
        setDisplayIndex(i => (i + 1) % players.length);
        count++;
        if (count < maxSpins) {
          speed = Math.min(speed + 8, 320);
          spinTimerRef.current = setTimeout(spin, speed);
        } else {
          // Land on the current_asker
          const targetIdx = players.findIndex(p => p.email === room?.current_asker_email);
          setDisplayIndex(targetIdx >= 0 ? targetIdx : 0);
          setLocalSpinning(false);
        }
      };
      spinTimerRef.current = setTimeout(spin, speed);
      return () => clearTimeout(spinTimerRef.current);
    }
  }, [disabled, isSpinning, room?.current_asker_email]);

  // Detect when asker changes (spin stopped) — show result
  useEffect(() => {
    if (prevCurrentAsker.current !== room?.current_asker_email) {
      prevCurrentAsker.current = room?.current_asker_email;
    }
  }, [room?.current_asker_email]);

  const handleAssociationGiven = async () => {
    if (submitting || disabled) return;
    setSubmitting(true);

    await runGameRoomAction("advance_association", room.id);

    setSubmitting(false);
  };

  const handleStartSpin = async () => {
    if (submitting || disabled) return;
    setSubmitting(true);
    await runGameRoomAction("start_association", room.id);
    setSubmitting(false);
  };

  // Stop spinning: mark spinning = false once we land
  useEffect(() => {
    if (disabled || !isSpinning) return;
    if (!localSpinning) {
      // We finished the local animation, stop spinning flag in DB
      // Only the host (or current asker) clears spinning to avoid race
      const timer = setTimeout(async () => {
        try {
          const fresh = parseAssocState(room);
          if (fresh.spinning) {
            await runGameRoomAction("stop_association_spin", room.id);
          }
        } catch {}
      }, 400);
      return () => clearTimeout(timer);
    }
  }, [disabled, localSpinning, isSpinning]);

  const displayPlayer = localSpinning
    ? players[displayIndex]
    : currentPlayer;

  // No current asker yet — show "start" button (host)
  if (!room?.current_asker_email && !isSpinning) {
    return (
      <div style={{ position: "relative", padding: 28, background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 20, textAlign: "center" }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#555", marginBottom: 20 }}>
          {lang === "ru" ? "РЕЖИМ АССОЦИАЦИЙ" : "ASSOCIATION MODE"}
        </div>
        {!isSpy && (
          <div style={{ padding: "10px 16px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.2)", marginBottom: 20, fontSize: 22, fontWeight: 700, color: "#e53535", fontFamily: "monospace", letterSpacing: 4 }}>
            {room?.word}
          </div>
        )}
        {isHost ? (
          <motion.button whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}
            onClick={handleStartSpin} disabled={submitting || disabled}
            className="btn-red"
            style={{ width: "100%", fontSize: 12, padding: "14px 0" }}>
            {submitting ? "..." : (lang === "ru" ? "▶ ЗАПУСТИТЬ БАРАБАН" : "▶ SPIN THE DRUM")}
          </motion.button>
        ) : (
          <div style={{ color: "#444", fontSize: 12, letterSpacing: 2, fontFamily: "monospace" }}>
            {lang === "ru" ? "ЖДЁМ ХОСТА..." : "WAITING FOR HOST..."}
          </div>
        )}
      </div>
    );
  }

  return (
    <div style={{ marginBottom: 20 }}>
      {/* Round indicator */}
      <div style={{ textAlign: "center", marginBottom: 16 }}>
        <span style={{ fontSize: 10, letterSpacing: 4, color: "#555", fontFamily: "monospace" }}>
          {lang === "ru" ? `РАУНД ${roundNumber}` : `ROUND ${roundNumber}`}
        </span>
        {spokenEmails.length > 0 && (
          <span style={{ fontSize: 10, letterSpacing: 2, color: "#333", fontFamily: "monospace", marginLeft: 12 }}>
            {spokenEmails.length}/{players.length}
          </span>
        )}
      </div>

      {/* Roulette drum */}
      <div style={{ position: "relative", padding: "28px 24px", background: "#0a0a0a", border: `1px solid ${localSpinning ? "#333" : "rgba(229,53,53,0.4)"}`, marginBottom: 20, textAlign: "center", transition: "border-color 0.4s", overflow: "hidden" }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

        <div style={{ fontSize: 10, letterSpacing: 3, color: localSpinning ? "#555" : "#e53535", marginBottom: 16, transition: "color 0.3s" }}>
          {localSpinning
            ? (lang === "ru" ? "КРУТИМ..." : "SPINNING...")
            : (lang === "ru" ? "ТВОЙ ХОД" : "YOUR TURN")}
        </div>

        <AnimatePresence mode="wait">
          <motion.div key={displayPlayer?.email || "empty"}
            initial={{ opacity: 0, y: localSpinning ? -10 : 0, scale: localSpinning ? 0.9 : 1 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: localSpinning ? 10 : 0 }}
            transition={{ duration: localSpinning ? 0.05 : 0.3 }}
            style={{ marginBottom: 12 }}>
            <div style={{ fontSize: 56, marginBottom: 8 }}>{displayPlayer?.avatar || "🕵️"}</div>
            <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 4, color: "#fff" }}>
              {displayPlayer?.name?.toUpperCase() || "—"}
              {displayPlayer?.email === user?.email && !localSpinning && (
                <span style={{ fontSize: 12, color: "#e53535", marginLeft: 8, letterSpacing: 2 }}>
                  {lang === "ru" ? "(ТЫ)" : "(YOU)"}
                </span>
              )}
            </div>
          </motion.div>
        </AnimatePresence>

        {/* Progress dots */}
        {players.length > 0 && (
          <div style={{ display: "flex", justifyContent: "center", gap: 6, marginTop: 12 }}>
            {players.map(p => {
              const hasSpoken = spokenEmails.includes(p.email);
              const isCurrent = p.email === room?.current_asker_email;
              return (
                <div key={p.email} title={p.name} style={{
                  width: 8, height: 8, borderRadius: "50%",
                  background: hasSpoken ? "#4ade80" : isCurrent && !localSpinning ? "#e53535" : "#222",
                  transition: "background 0.3s",
                  border: isCurrent && !localSpinning ? "1px solid rgba(229,53,53,0.6)" : "1px solid #1a1a1a"
                }} />
              );
            })}
          </div>
        )}
      </div>

      {/* Secret word (for non-spies) */}
      {!isSpy && !localSpinning && (
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
          style={{ padding: "10px 16px", background: "rgba(229,53,53,0.06)", border: "1px solid rgba(229,53,53,0.15)", marginBottom: 16, fontSize: 20, fontWeight: 700, color: "#e53535", textAlign: "center", fontFamily: "monospace", letterSpacing: 4 }}>
          {room?.word}
        </motion.div>
      )}

      {/* Action button — only for current player */}
      {isCurrentPlayer && !localSpinning && (
        <motion.button
          initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
          whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}
          onClick={handleAssociationGiven} disabled={submitting || disabled}
          className="btn-red"
          style={{ width: "100%", fontSize: 13, padding: "16px 0", letterSpacing: 3 }}>
          {submitting ? "..." : (lang === "ru" ? "✓ ОТВЕТИЛ" : "✓ ANSWERED")}
        </motion.button>
      )}

      {/* Waiting message for others */}
      {!isCurrentPlayer && !localSpinning && (
        <motion.div animate={{ opacity: [1, 0.4, 1] }} transition={{ duration: 2, repeat: Infinity }}
          style={{ textAlign: "center", color: "#444", fontSize: 11, letterSpacing: 2, fontFamily: "monospace", padding: "12px 0" }}>
          {lang === "ru" ? `ЖДЁМ ${currentPlayer?.name?.toUpperCase() || ""}...` : `WAITING FOR ${currentPlayer?.name?.toUpperCase() || ""}...`}
        </motion.div>
      )}
    </div>
  );
}

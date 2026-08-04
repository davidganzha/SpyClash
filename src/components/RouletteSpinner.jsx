import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";

export default function RouletteSpinner({ players, targetEmail, onDone }) {
  const [currentIdx, setCurrentIdx] = useState(0);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (!players.length) { onDone?.(); return; }
    const targetIdx = Math.max(0, players.findIndex(p => p.email === targetEmail));
    const spins = players.length * 3 + targetIdx;
    let count = 0;
    let delay = 80;

    const tick = () => {
      count++;
      setCurrentIdx(prev => (prev + 1) % players.length);
      if (count >= spins) {
        setCurrentIdx(targetIdx);
        setDone(true);
        setTimeout(() => onDone?.(), 1800);
        return;
      }
      // Slow down at the end
      if (count > spins - players.length) delay = Math.min(delay + 30, 350);
      setTimeout(tick, delay);
    };

    setTimeout(tick, delay);
  }, []);

  const current = players[currentIdx];

  return (
    <div style={{ textAlign: "center", padding: "32px 20px" }}>
      <div style={{ fontSize: 10, letterSpacing: 4, color: "#e53535", marginBottom: 24 }}>// РУЛЕТКА ПЕРВОГО ХОДА</div>

      <motion.div
        key={currentIdx}
        initial={{ scale: 0.7, opacity: 0.4 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.08 }}
        style={{ fontSize: 64, marginBottom: 16 }}>
        {current?.avatar || "🕵️"}
      </motion.div>

      <motion.div
        key={`name-${currentIdx}`}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        style={{
          fontFamily: "'Rajdhani', sans-serif", fontWeight: 700,
          fontSize: 18, letterSpacing: 3,
          color: done ? "#e53535" : "#555",
          marginBottom: 12, transition: "color 0.3s"
        }}>
        {current?.name?.toUpperCase()}
      </motion.div>

      <AnimatePresence>
        {done && (
          <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
            style={{ fontSize: 11, color: "#4ade80", letterSpacing: 3, fontFamily: "monospace" }}>
            ✓ НАЧИНАЕТ ПЕРВЫМ
          </motion.div>
        )}
      </AnimatePresence>

      {!done && (
        <div style={{ display: "flex", justifyContent: "center", gap: 4, marginTop: 8 }}>
          {players.map((_, i) => (
            <div key={i} style={{
              width: 6, height: 6,
              background: i === currentIdx ? "#e53535" : "#1e1e1e",
              borderRadius: "50%",
              transition: "background 0.1s"
            }} />
          ))}
        </div>
      )}
    </div>
  );
}
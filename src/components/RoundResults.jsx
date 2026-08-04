import { useState } from "react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { runGameRoomAction } from "@/lib/gameRoomActions";

export default function RoundResults({ room, user, onContinue, disabled = false }) {
  const { t } = useLanguage();
  const [confirming, setConfirming] = useState(false);
  const eliminated_emails = room?.eliminated_emails || [];
  const players = room?.players || [];

  const scores = players
    .filter(p => !eliminated_emails.includes(p.email))
    .map(p => {
      const feedback = (room?.player_feedback || []).find(f => f.email === p.email);
      const likes = feedback?.likes || 0;
      const dislikes = feedback?.dislikes || 0;
      const score = likes - dislikes;
      return { ...p, likes, dislikes, score };
    })
    .sort((a, b) => b.score - a.score);

  const handleContinue = async () => {
    if (confirming || disabled) return;
    setConfirming(true);
    await runGameRoomAction("continue_round", room.id);
    setConfirming(false);
    onContinue?.();
  };

  return (
    <div style={{ maxWidth: 540, margin: "0 auto", padding: "50px 20px" }}>
      <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 32, fontFamily: "monospace" }}>
        {t('rr_breadcrumb')} {room?.round_number || 1}
      </motion.div>

      <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 32, letterSpacing: 4, marginBottom: 28 }}>
        {t('rr_title')}
      </motion.div>

      <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
        style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 24, marginBottom: 24 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
        <div style={{ fontSize: 10, letterSpacing: 4, color: "#444", marginBottom: 20 }}>{t('rr_scores')}</div>

        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {scores.map((p, i) => (
            <motion.div key={p.email}
              initial={{ opacity: 0, x: -20 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: i * 0.1 }}
              style={{
                display: "grid", gridTemplateColumns: "40px 1fr 60px", gap: 16, alignItems: "center",
                padding: "14px 16px",
                background: i === 0 ? "rgba(229,53,53,0.1)" : "#080808",
                border: i === 0 ? "1px solid rgba(229,53,53,0.3)" : "1px solid #141414"
              }}>
              <div style={{ textAlign: "center", fontSize: 24 }}>{p.avatar}</div>
              <div>
                <div style={{ fontSize: 11, fontFamily: "monospace", color: "#ccc", letterSpacing: 1, marginBottom: 4 }}>
                  {p.name.toUpperCase()}
                </div>
                <div style={{ fontSize: 9, color: "#555", letterSpacing: 1 }}>
                  👍 {p.likes} · 👎 {p.dislikes}
                </div>
              </div>
              <div style={{
                textAlign: "right", fontSize: 18, fontWeight: 700,
                fontFamily: "'Rajdhani', sans-serif",
                color: i === 0 ? "#e53535" : (p.score > 0 ? "#4ade80" : "#aaa"),
                letterSpacing: 2
              }}>
                {p.score > 0 ? "+" : ""}{p.score}
              </div>
            </motion.div>
          ))}
        </div>

        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
      </motion.div>

      <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
        className="btn-red" onClick={handleContinue} disabled={confirming || disabled} style={{ width: "100%", fontSize: 12, padding: "14px 0" }}>
        {confirming ? t('rr_preparing') : t('rr_continue')}
      </motion.button>
    </div>
  );
}

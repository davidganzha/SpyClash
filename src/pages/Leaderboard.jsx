import { useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { useNavigate, Link } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import PageChrome from "@/components/PageChrome";
import AnimatedTitle from "@/components/AnimatedTitle";
import { getLeaderboard } from "@/lib/gameRoomActions";

export default function Leaderboard() {
  const { t } = useLanguage();
  const [leaderboard, setLeaderboard] = useState([]);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    base44.auth.me().then(u => {
      if (!u) { base44.auth.redirectToLogin(createPageUrl("Leaderboard")); return; }
      loadLeaderboard();
    }).catch(() => navigate(createPageUrl("Home")));
  }, []);

  const loadLeaderboard = async () => {
    try {
      setLeaderboard(await getLeaderboard());
    } finally {
      setLoading(false);
    }
  };

  return (
    <PageChrome eyebrow="// LEADERBOARD" status="RANKED">
    <div style={{ maxWidth: 680, margin: "0 auto", padding: "40px 20px" }}>
      <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.4, ease: [0.22, 0.61, 0.36, 1] }} style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 32, fontFamily: "monospace" }}>
        <Link to={createPageUrl("Home")} style={{ textDecoration: "none", color: "#555" }}>{t('lb_breadcrumb_home')}</Link> // {t('lb_title')}
      </motion.div>

      <div style={{ marginBottom: 32 }}>
        <AnimatedTitle text={String(t('lb_title')).toUpperCase()} delay={0.2} />
      </div>

      {loading ? (
        <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }}
          style={{ color: "#333", textAlign: "center", padding: 32, fontFamily: "monospace", fontSize: 11, letterSpacing: 3 }}>
          {t('lb_loading')}
        </motion.div>
      ) : leaderboard.length === 0 ? (
        <div style={{ color: "#333", textAlign: "center", padding: 32, fontFamily: "monospace", fontSize: 11, letterSpacing: 2 }}>
          {t('lb_empty')}
        </div>
      ) : (
        <motion.div initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.25, duration: 0.55, ease: [0.22, 0.61, 0.36, 1] }}
          style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", overflow: "hidden" }}>
          <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
          
          <div style={{ display: "grid", gridTemplateColumns: "60px 1fr 120px 100px 100px", gap: 0, padding: "16px 20px", background: "#080808", borderBottom: "1px solid #1e1e1e", fontSize: 9, color: "#555", letterSpacing: 3, fontWeight: 700, textTransform: "uppercase" }}>
            <div>{t('lb_rank')}</div>
            <div>{t('lb_player')}</div>
            <div style={{ textAlign: "right" }}>{t('lb_rating')}</div>
            <div style={{ textAlign: "center" }}>{t('lb_games')}</div>
            <div style={{ textAlign: "center" }}>{t('lb_wins')}</div>
          </div>

          <div>
            <AnimatePresence>
              {leaderboard.map((player, idx) => (
                <motion.div key={player.id}
                  initial={{ opacity: 0, x: -20 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 0.35 + idx * 0.05, duration: 0.4, ease: [0.22, 0.61, 0.36, 1] }}
                  style={{
                    display: "grid", gridTemplateColumns: "60px 1fr 120px 100px 100px",
                    gap: 0, padding: "14px 20px",
                    borderBottom: idx < leaderboard.length - 1 ? "1px solid #141414" : "none",
                    alignItems: "center",
                    background: idx < 3 ? "rgba(229,53,53,0.03)" : "transparent"
                  }}>
                  <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ delay: idx * 0.04 + 0.2, type: "spring", stiffness: 200 }}
                    style={{ fontSize: 18, fontWeight: 800, fontFamily: "'Rajdhani', sans-serif", color: idx === 0 ? "#ffd700" : idx === 1 ? "#c0c0c0" : idx === 2 ? "#cd7f32" : "#444", letterSpacing: 2 }}>
                    {idx === 0 ? "🥇" : idx === 1 ? "🥈" : idx === 2 ? "🥉" : `#${idx + 1}`}
                  </motion.div>
                  <div style={{ fontFamily: "monospace", fontSize: 11, letterSpacing: 1, color: "#ccc" }}>{player.display_name}</div>
                  <div style={{ textAlign: "right", fontSize: 14, fontWeight: 700, fontFamily: "'Rajdhani', sans-serif", color: player.rating >= 0 ? "#4ade80" : "#e53535", letterSpacing: 2 }}>
                    {player.rating >= 0 ? "+" : ""}{player.rating}
                  </div>
                  <div style={{ textAlign: "center", fontSize: 11, color: "#aaa", letterSpacing: 1 }}>{player.games}</div>
                  <div style={{ textAlign: "center", fontSize: 11, color: "#4ade80", letterSpacing: 1 }}>{player.wins}</div>
                </motion.div>
              ))}
            </AnimatePresence>
          </div>

          <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
        </motion.div>
      )}

      <motion.div initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.5, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
        style={{ marginTop: 24 }}>
        <Link to={createPageUrl("Home")}>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-outline" style={{ width: "100%", fontSize: 11, padding: "13px 0" }}>
            {t('lb_back')}
          </motion.button>
        </Link>
      </motion.div>
    </div>
    </PageChrome>
  );
}

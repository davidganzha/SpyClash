import { useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { useNavigate, Link } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import Reveal from "@/components/Reveal";
import PageChrome from "@/components/PageChrome";
import AnimatedTitle from "@/components/AnimatedTitle";
import { loadPlayerGameHistory } from "@/lib/gameHistory";

export default function History() {
  const { t } = useLanguage();
  const [user, setUser] = useState(null);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    base44.auth.me().then(u => {
      if (cancelled) return;
      if (!u) { base44.auth.redirectToLogin(createPageUrl("History")); return; }
      setUser(u);
      loadPlayerGameHistory(u.email, { userId: u.id }).then(h => {
        if (!cancelled) setHistory(h);
      }).catch(() => {
        if (!cancelled) setHistory([]);
      }).finally(() => {
        if (!cancelled) setLoading(false);
      });
    }).catch(() => navigate(createPageUrl("Home")));
    return () => { cancelled = true; };
  }, [navigate]);

  if (!user) return null;
  const visibleHistory = history;

  return (
    <PageChrome eyebrow="// HISTORY" status="ARCHIVE">
    <div style={{ maxWidth: 740, margin: "0 auto", padding: "40px 20px" }}>
      <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.4, ease: [0.22, 0.61, 0.36, 1] }} style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 32, fontFamily: "monospace" }}>
        <Link to={createPageUrl("Profile")} style={{ textDecoration: "none", color: "#555" }}>{t('history_breadcrumb_profile')}</Link> // {t('history_title')}
      </motion.div>

      <div style={{ marginBottom: 32 }}>
        <AnimatedTitle text={String(t('history_title')).toUpperCase()} delay={0.2} />
      </div>

      {loading ? (
        <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }}
          style={{ color: "#333", textAlign: "center", padding: 40, fontFamily: "monospace", fontSize: 11, letterSpacing: 3 }}>
          {t('history_loading')}
        </motion.div>
      ) : history.length === 0 ? (
        <div style={{ color: "#333", textAlign: "center", padding: 40, fontFamily: "monospace", fontSize: 11, letterSpacing: 2 }}>
          {t('history_empty')}
        </div>
      ) : (
        <motion.div initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.25, duration: 0.55, ease: [0.22, 0.61, 0.36, 1] }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <AnimatePresence>
              {visibleHistory.map((h, i) => (
                <Reveal key={h.id} delay={i * 40}>
                  <div style={{
                    position: "relative",
                    display: "grid",
                    gridTemplateColumns: "60px 1fr 140px",
                    gap: 16,
                    alignItems: "center",
                    padding: "18px 20px",
                    background: "#0a0a0a",
                    border: `1px solid ${h.won ? "rgba(74,222,128,0.2)" : "rgba(229,53,53,0.2)"}`,
                    boxShadow: h.won ? "inset 0 0 16px rgba(74,222,128,0.05)" : "inset 0 0 16px rgba(229,53,53,0.05)"
                  }}>
                  <div style={{ textAlign: "center" }}>
                    <div style={{ fontSize: 24, marginBottom: 4 }}>
                      {h.role === "spy" ? "🕵️" : "🔍"}
                    </div>
                    <div style={{ fontSize: 9, color: "#555", letterSpacing: 2, textTransform: "uppercase" }}>
                      {h.role}
                    </div>
                  </div>

                  <div>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
                      <span style={{ fontSize: 14, fontWeight: 700, fontFamily: "'Rajdhani', sans-serif", color: "#e53535", letterSpacing: 2 }}>
                        {h.word || "?"}
                      </span>
                      <span style={{ fontSize: 9, color: "#555", letterSpacing: 1, textTransform: "uppercase" }}>
                        {h.category}
                      </span>
                    </div>
                    <div style={{ fontSize: 10, color: "#333", letterSpacing: 1 }}>
                      {h.player_count} {t('history_players')} <span style={{ fontFamily: "monospace", color: "#555" }}>{h.room_code}</span>
                    </div>
                    {(h.ranked === false || Number(h.spy_count) > 1) && (
                      <div style={{ marginTop: 6, color: "#fbbf24", fontSize: 9, letterSpacing: 1.4 }}>
                        {t("history_unranked")} · {Math.max(2, Number(h.spy_count) || 2)} {t("history_spies")}
                      </div>
                    )}
                  </div>

                  <div style={{ textAlign: "right" }}>
                    <div style={{
                      display: "inline-block",
                      padding: "8px 16px",
                      fontSize: 11, fontWeight: 700, letterSpacing: 2, fontFamily: "monospace",
                      background: h.won ? "rgba(74,222,128,0.12)" : "rgba(229,53,53,0.12)",
                      border: `1px solid ${h.won ? "rgba(74,222,128,0.35)" : "rgba(229,53,53,0.35)"}`,
                      color: h.won ? "#4ade80" : "#e53535",
                      borderRadius: 2
                    }}>
                      {h.won ? t('history_win') : t('history_loss')}
                    </div>
                  </div>
                  </div>
                </Reveal>
              ))}
            </AnimatePresence>
          </div>
        </motion.div>
      )}

      <motion.div initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.5, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
        style={{ marginTop: 32 }}>
        <Link to={createPageUrl("Profile")}>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }} className="btn-outline" style={{ width: "100%", fontSize: 11, padding: "13px 0" }}>
            {t('history_back')}
          </motion.button>
        </Link>
      </motion.div>
    </div>
    </PageChrome>
  );
}

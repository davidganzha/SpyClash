import { useState } from "react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";

export default function SpyGuessModal({ wordPool, onGuess, onClose }) {
  const { t } = useLanguage();
  const [selected, setSelected] = useState(null);
  const [confirming, setConfirming] = useState(false);
  const enabledWords = (wordPool || []).filter(w => w.enabled);

  const handleConfirm = async () => {
    if (!selected || confirming) return;
    setConfirming(true);
    await onGuess(selected);
    setConfirming(false);
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      style={{
        position: "fixed", inset: 0, background: "rgba(0,0,0,0.92)",
        zIndex: 1000, display: "flex", alignItems: "center", justifyContent: "center", padding: 20
      }}
    >
      <motion.div
        initial={{ scale: 0.9, y: 20 }}
        animate={{ scale: 1, y: 0 }}
        style={{
          position: "relative", background: "#0a0a0a", border: "1px solid rgba(229,53,53,0.4)",
          padding: 28, maxWidth: 480, width: "100%", maxHeight: "80vh", display: "flex", flexDirection: "column"
        }}
      >
        <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

        <div style={{ fontSize: 10, letterSpacing: 4, color: "#e53535", marginBottom: 8 }}>{t('sgm_title')}</div>
        <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 20, letterSpacing: 3, marginBottom: 6 }}>
          {t('sgm_header')}
        </div>
        <div style={{ fontSize: 11, color: "#555", letterSpacing: 1, lineHeight: 1.6, marginBottom: 20 }}>
          {t('sgm_desc')}
        </div>

        <div style={{ overflowY: "auto", overflowX: "hidden", flex: 1, marginBottom: 16 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(130px, 1fr))", gap: 8 }}>
            {enabledWords.map((item, i) => (
              <motion.button
                key={i}
                whileHover={{ scale: 1.02 }}
                whileTap={{ scale: 0.98 }}
                onClick={() => setSelected(item.word)}
                style={{
                  padding: "10px 8px",
                  background: selected === item.word ? "rgba(229,53,53,0.2)" : "#080808",
                  border: `1px solid ${selected === item.word ? "#e53535" : "#222"}`,
                  color: selected === item.word ? "#fff" : "#888",
                  cursor: "pointer", fontFamily: "monospace", fontSize: 12, letterSpacing: 1,
                  textAlign: "center", transition: "all 0.15s",
                  boxShadow: selected === item.word ? "0 0 12px rgba(229,53,53,0.3)" : "none"
                }}
              >
                {item.word}
              </motion.button>
            ))}
          </div>
          {enabledWords.length === 0 && (
            <div style={{ textAlign: "center", color: "#333", fontSize: 12, letterSpacing: 2, padding: 24 }}>
              {t('sgm_no_words')}
            </div>
          )}
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
            className="btn-ghost" onClick={onClose} style={{ fontSize: 11 }}>
            {t('sgm_cancel')}
          </motion.button>
          <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}
            className="btn-red" onClick={handleConfirm} disabled={!selected || confirming} style={{ fontSize: 11 }}>
            {confirming ? "..." : selected ? `▶ ${selected.toUpperCase()}` : t('sgm_choose')}
          </motion.button>
        </div>
      </motion.div>
    </motion.div>
  );
}

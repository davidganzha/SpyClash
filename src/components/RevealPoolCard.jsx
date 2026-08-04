import { useState, useRef } from "react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { useWaveScroll } from "@/hooks/useWaveScroll";

/**
 * Stylish word-pool card with header (icon + label + category badge + optional action),
 * stats line, animated reveal grid (tap to cross out), and an "Add word" row.
 * Used for both the random preset pool and AI/pack-generated pools.
 */
export default function RevealPoolCard({
  pool,
  onUpdate,
  category,
  icon = "🎲",
  label,
  actionLabel = null,
  onAction = null,
  fast = false,
}) {
  const { lang } = useLanguage();
  const [newWordInput, setNewWordInput] = useState("");
  const gridRef = useRef(null);
  const stepDelay = fast ? 0.04 : 0.08;
  const itemDuration = fast ? 0.18 : 0.35;
  useWaveScroll(pool.length, { delayPerItem: stepDelay, containerRef: gridRef });

  const enabled = pool.filter(w => w.enabled !== false).length;
  const defaultLabel = lang === "ru" ? "ТЕМА" : "THEME";

  const handleAdd = () => {
    const val = newWordInput.trim();
    if (val && !pool.find(w => w.word.toLowerCase() === val.toLowerCase())) {
      onUpdate([...pool, { word: val, enabled: true }]);
    }
    setNewWordInput("");
  };

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      style={{ marginTop: 10, borderRadius: 10, overflow: "hidden", border: "1px solid rgba(229,53,53,0.25)", background: "rgba(229,53,53,0.04)" }}>
      {/* Header */}
      <div style={{ padding: "12px 16px", borderBottom: "1px solid rgba(229,53,53,0.15)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          <span style={{ fontSize: 16 }}>{icon}</span>
          <span style={{ fontSize: 10, letterSpacing: 3, color: "#888", fontFamily: "monospace" }}>
            {label || defaultLabel}
          </span>
          {category && (
            <span translate="no" lang="zxx" style={{ fontSize: 11, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, letterSpacing: 2, color: "#e53535", background: "rgba(229,53,53,0.12)", padding: "2px 8px", borderRadius: 4 }}>
              {String(category).toUpperCase()}
            </span>
          )}
        </div>
        {onAction && actionLabel && (
          <button onClick={onAction} className="btn-ghost"
            style={{ fontSize: 10, padding: "4px 10px", letterSpacing: 1, opacity: 0.7, flexShrink: 0 }}>
            {actionLabel}
          </button>
        )}
      </div>

      {/* Stats */}
      <div style={{ padding: "8px 16px 0", fontSize: 10, color: "#555", fontFamily: "monospace", letterSpacing: 1 }}>
        {enabled}/{pool.length} {lang === "ru" ? "активных" : "active"} · {lang === "ru" ? "нажми чтобы вычеркнуть" : "tap to cross out"}
      </div>

      {/* Words grid */}
      <div translate="no" lang="zxx" ref={gridRef}
        style={{ padding: "10px 16px", display: "flex", flexWrap: "wrap", gap: 8, overflow: "hidden", overflowAnchor: "none" }}>
        {pool.map((w, i) => {
          const isEnabled = w.enabled !== false;
          return (
            <motion.button
              key={w.word}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: itemDuration, delay: i * stepDelay, ease: "easeOut" }}
              whileHover={{ scale: 1.05, y: -2, transition: { duration: 0.15 } }}
              whileTap={{ scale: 0.94 }}
              onClick={() => onUpdate(pool.map((x, j) => j === i ? { ...x, enabled: !isEnabled } : x))}
              style={{
                fontSize: 13, padding: "8px 14px", borderRadius: 6, cursor: "pointer",
                minHeight: 38, touchAction: "manipulation",
                background: isEnabled ? "rgba(255,255,255,0.07)" : "rgba(0,0,0,0.2)",
                border: `1px solid ${isEnabled ? "rgba(255,255,255,0.18)" : "rgba(255,255,255,0.05)"}`,
                color: isEnabled ? "#ddd" : "#3a3a3a",
                fontFamily: "monospace",
                textDecoration: isEnabled ? "none" : "line-through",
                WebkitTapHighlightColor: "transparent",
                display: "inline-flex", alignItems: "center", gap: 6,
              }}>
              <span>{w.word}</span>
              <span
                onClick={(e) => { e.stopPropagation(); onUpdate(pool.filter((_, j) => j !== i)); }}
                style={{ color: "#555", fontSize: 11, lineHeight: 1, marginLeft: 2 }}>✕</span>
            </motion.button>
          );
        })}
      </div>

      {/* Add word */}
      <div style={{ padding: "6px 16px 14px", display: "flex", gap: 8, alignItems: "stretch" }}>
        <input
          value={newWordInput}
          onChange={e => setNewWordInput(e.target.value)}
          placeholder={lang === "ru" ? "Добавить слово..." : "Add word..."}
          onKeyDown={e => { if (e.key === "Enter") handleAdd(); }}
          style={{ flex: 1, fontSize: 14, padding: "10px 14px", borderRadius: 8, minHeight: 44 }}
        />
        <button className="btn-outline"
          style={{ fontSize: 12, padding: "10px 16px", borderRadius: 8, clipPath: "none", flexShrink: 0, minHeight: 44, minWidth: 72, touchAction: "manipulation" }}
          onClick={handleAdd}>
          + ADD
        </button>
      </div>
    </motion.div>
  );
}

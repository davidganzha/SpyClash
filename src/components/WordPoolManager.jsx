import { useState, useRef } from "react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { useWaveScroll } from "@/hooks/useWaveScroll";

export default function WordPoolManager({ pool, isHost, onUpdate }) {
  const { t } = useLanguage();
  const [newWord, setNewWord] = useState("");
  const gridRef = useRef(null);
  useWaveScroll(pool.length, { delayPerItem: 0.08, containerRef: gridRef });

  const toggle = (word) => {
    if (!isHost) return;
    const updated = pool.map((w) => w.word === word ? { ...w, enabled: !w.enabled } : w);
    onUpdate(updated);
  };

  const removeWord = (word) => {
    if (!isHost) return;
    const updated = pool.filter((w) => w.word !== word);
    onUpdate(updated);
  };

  const addWord = () => {
    if (!newWord.trim() || !isHost) return;
    if (pool.some((w) => w.word.toLowerCase() === newWord.trim().toLowerCase())) return;
    const updated = [...pool, { word: newWord.trim(), enabled: true }];
    onUpdate(updated);
    setNewWord("");
  };

  const enabled = pool.filter((w) => w.enabled).length;

  return (
    <div>
      <div style={{ fontSize: 11, letterSpacing: 2, color: "#888", marginBottom: 14, fontFamily: "monospace" }}>
        // {enabled}/{pool.length} {t('wp_active')}
      </div>
      

      
      {isHost &&
      <div style={{ fontSize: 12, color: "#e5b535", background: "rgba(229,181,53,0.07)", border: "1px solid rgba(229,181,53,0.2)", padding: "8px 12px", marginBottom: 14, lineHeight: 1.6 }} className="hidden">
          {t('wp_ai_warning')}
        </div>
      }

      <div translate="no" lang="zxx" ref={gridRef}
        style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: isHost ? 14 : 0, overflow: "hidden", overflowAnchor: "none" }}>
          {pool.map((item, i) =>
            <motion.div
              key={item.word}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.35, delay: i * 0.08, ease: "easeOut" }}
              whileHover={isHost ? { scale: 1.06, y: -2, transition: { duration: 0.15 } } : {}}
              whileTap={isHost ? { scale: 0.94 } : {}}
              onClick={() => toggle(item.word)}
              style={{
                display: "flex", alignItems: "center", gap: 4,
                padding: "5px 10px",
                background: item.enabled ? "rgba(229,53,53,0.08)" : "#080808",
                border: `1px solid ${item.enabled ? "rgba(229,53,53,0.3)" : "#1a1a1a"}`,
                opacity: item.enabled ? 1 : 0.4,
                cursor: isHost ? "pointer" : "default",
                borderRadius: 4,
              }}>
              <span translate="no" style={{ fontSize: 11, fontFamily: "monospace", color: item.enabled ? "#ccc" : "#444", letterSpacing: 1 }}>
                {item.word}
              </span>
              {isHost &&
                <button onClick={(e) => { e.stopPropagation(); removeWord(item.word); }}
                  style={{ background: "none", border: "none", color: "#333", cursor: "pointer", padding: 0, fontSize: 10, marginLeft: 2, lineHeight: 1 }}>
                  ✕
                </button>
              }
            </motion.div>
          )}
        {pool.length === 0 &&
          <div style={{ color: "#333", fontSize: 11, letterSpacing: 2, fontFamily: "monospace" }}>
            {t('wp_empty')}
          </div>
        }
      </div>

      {isHost &&
      <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
          <input
          placeholder={t('wp_add_placeholder')}
          value={newWord}
          onChange={(e) => setNewWord(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && addWord()}
          style={{ flex: 1, marginBottom: 0, fontSize: 11 }} />
        
          <button onClick={addWord} style={{
          background: "transparent", border: "1px solid #333", color: "#666",
          padding: "0 12px", cursor: "pointer", fontFamily: "monospace", fontSize: 11, letterSpacing: 1, whiteSpace: "nowrap"
        }}>
            {t('wp_add_btn')}
          </button>
        </div>
      }
    </div>);

}
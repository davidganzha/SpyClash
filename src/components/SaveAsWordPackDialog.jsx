import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { base44 } from "@/api/base44Client";
import { createWordPack } from "@/lib/wordPackActions";

export default function SaveAsWordPackDialog({ open, onClose, defaultName, words, category, lang, onSaved }) {
  const [name, setName] = useState(defaultName || "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);

  const handleSave = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      setError(lang === "ru" ? "Введите название" : "Enter a name");
      return;
    }
    if (!words || words.length < 2) {
      setError(lang === "ru" ? "Нужно минимум 2 слова" : "Need at least 2 words");
      return;
    }
    setSaving(true);
    setError("");
    const user = await base44.auth.me().catch(() => null);
    if (!user) {
      setSaving(false);
      setError(lang === "ru" ? "Нужно войти в аккаунт" : "Sign in required");
      return;
    }
    await createWordPack({
      name: trimmed,
      category: category || trimmed,
      words: words,
    });
    setSaving(false);
    setSaved(true);
    if (onSaved) onSaved();
    setTimeout(() => { onClose(); setSaved(false); }, 1200);
  };

  if (!open) return null;

  return (
    <AnimatePresence>
      <motion.div
        initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
        onClick={onClose}
        style={{
          position: "fixed", inset: 0, background: "rgba(0,0,0,0.75)",
          backdropFilter: "blur(8px)", WebkitBackdropFilter: "blur(8px)",
          zIndex: 300, display: "flex", alignItems: "center", justifyContent: "center", padding: 20,
        }}
      >
        <motion.div
          initial={{ scale: 0.92, opacity: 0, y: 16 }}
          animate={{ scale: 1, opacity: 1, y: 0 }}
          exit={{ scale: 0.92, opacity: 0, y: 16 }}
          onClick={e => e.stopPropagation()}
          style={{
            position: "relative", width: "100%", maxWidth: 380,
            background: "#0a0a0a", border: "1px solid #2a2a2a", borderRadius: 12,
            padding: "24px 22px", boxShadow: "0 20px 80px rgba(0,0,0,0.8)",
          }}
        >
          {/* corner accents */}
          <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

          <div style={{ fontSize: 11, letterSpacing: 3, color: "#888", fontFamily: "monospace", marginBottom: 6 }}>
            💾 {lang === "ru" ? "СОХРАНИТЬ КАК WORDPACK" : "SAVE AS WORDPACK"}
          </div>
          <div style={{ fontSize: 11, color: "#555", marginBottom: 16, lineHeight: 1.5 }}>
            {lang === "ru"
              ? `${words?.length || 0} слов будут сохранены в твою коллекцию`
              : `${words?.length || 0} words will be saved to your collection`}
          </div>

          <label style={{ fontSize: 10, letterSpacing: 2, color: "#666", fontFamily: "monospace", display: "block", marginBottom: 6 }}>
            {lang === "ru" ? "НАЗВАНИЕ" : "NAME"}
          </label>
          <input
            autoFocus
            value={name}
            onChange={e => { setName(e.target.value); setError(""); }}
            placeholder={lang === "ru" ? "Моя коллекция..." : "My collection..."}
            onKeyDown={e => { if (e.key === "Enter") handleSave(); }}
            style={{ marginBottom: 4, fontSize: 14 }}
          />
          {error && <div style={{ fontSize: 11, color: "#e53535", marginTop: 8 }}>{error}</div>}

          <div style={{ display: "flex", gap: 8, marginTop: 20 }}>
            <button onClick={onClose} className="btn-ghost"
              style={{ flex: 1, fontSize: 11, padding: "12px 0" }}>
              {lang === "ru" ? "ОТМЕНА" : "CANCEL"}
            </button>
            <button onClick={handleSave} disabled={saving || saved} className="btn-red"
              style={{ flex: 1, fontSize: 11, padding: "12px 0", clipPath: "none", borderRadius: 6 }}>
              {saved ? (lang === "ru" ? "✓ СОХРАНЕНО" : "✓ SAVED") :
                saving ? "..." :
                (lang === "ru" ? "СОХРАНИТЬ" : "SAVE")}
            </button>
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>
  );
}

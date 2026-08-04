import { useState, useEffect, useRef } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { Link, useNavigate } from "react-router-dom";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import PageChrome from "@/components/PageChrome";
import AnimatedTitle from "@/components/AnimatedTitle";
import { useGlobalQuota } from "@/hooks/useGlobalQuota";
import { generateWordPool } from "@/utils/wordPoolAI";
import {
  createWordPack,
  deleteWordPack,
  listWordPacks,
  updateWordPack,
} from "@/lib/wordPackActions";

const fadeUp = (delay = 0) => ({
  initial: { opacity: 0, y: 16 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.4, delay, ease: [0.16, 1, 0.3, 1] }
});

const fadeIn = (delay = 0) => ({
  initial: { opacity: 0 },
  animate: { opacity: 1 },
  transition: { duration: 0.35, delay }
});

// Вынесено за пределы WordPacks чтобы избежать ремаунта при каждом ре-рендере
function FormPanel({ editing, t, aiTheme, setAiTheme, aiWordCount, setAiWordCount, generating, generationError, generateFromAI, newName, setNewName, newCategory, setNewCategory, editWords, removeWord, newWord, setNewWord, addWord, handleSaveEdit, handleCreate, onCancel }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: -16, scale: 0.98 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: -12, scale: 0.98 }}
      transition={{ duration: 0.35, ease: [0.16, 1, 0.3, 1] }}
      style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 24, marginBottom: 20 }}>
      <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
      <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />

      <motion.div {...fadeIn(0.05)} style={{ fontSize: 11, letterSpacing: 3, color: "#e53535", marginBottom: 20 }}>
        {editing ? t('wp_form_edit') : t('wp_form_new')}
      </motion.div>

      {/* AI generate */}
      <motion.div {...fadeUp(0.08)} style={{ marginBottom: 20, padding: 16, background: "#060606", border: "1px solid #1a1a1a" }}>
        <div style={{ display: "flex", alignItems: "center", marginBottom: 10 }}>
          <div style={{ fontSize: 10, letterSpacing: 2, color: "#555" }}>{t('wp_form_ai_label')}</div>
        </div>
        <style>{`.wp-slider{appearance:none;-webkit-appearance:none;width:100%;height:2px;outline:none;cursor:pointer;border:none!important;padding:0!important;background:transparent!important}.wp-slider::-webkit-slider-thumb{appearance:none;-webkit-appearance:none;width:12px;height:12px;background:#e53535;border:2px solid #e53535;border-radius:0;cursor:pointer;margin-top:-5px}.wp-slider::-moz-range-thumb{width:12px;height:12px;background:#e53535;border:2px solid #e53535;border-radius:0;cursor:pointer}`}</style>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <input
            placeholder={t('wp_form_ai_placeholder')}
            value={aiTheme}
            onChange={e => setAiTheme(e.target.value)}
            onKeyDown={(e) => {
              if (e.key !== "Enter") return;
              e.preventDefault();
              generateFromAI();
            }}
            style={{ fontSize: 13, width: "100%" }}
          />
          {/* Word count slider */}
          <div style={{ padding: "10px 12px", background: "#080808", border: "1px solid #151515" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
              <span style={{ fontSize: 10, letterSpacing: 2, color: "#555", fontFamily: "monospace" }}>WORDS TO GENERATE</span>
              <span style={{ fontSize: 16, fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, color: "#e53535" }}>{aiWordCount}</span>
            </div>
            <div style={{ position: "relative", paddingBottom: 2 }}>
              <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 2, transform: "translateY(-50%)", background: "#1a1a1a", pointerEvents: "none" }} />
              <div style={{ position: "absolute", top: "50%", left: 0, height: 2, transform: "translateY(-50%)", background: "#e53535", width: `${((aiWordCount - 5) / (100 - 5)) * 100}%`, pointerEvents: "none", transition: "width 0.1s" }} />
              <input type="range" min={5} max={100} step={1} value={aiWordCount}
                onChange={e => setAiWordCount(Number(e.target.value))}
                className="wp-slider" style={{ position: "relative", zIndex: 1 }} />
            </div>
          </div>
          <motion.button
            whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
            className="btn-outline" onClick={generateFromAI} disabled={generating || !aiTheme.trim()}
            style={{ fontSize: 11, padding: "10px 16px", whiteSpace: "nowrap", width: "100%" }}>
            {generating ? (
              <motion.span animate={{ opacity: [0.4, 1, 0.4] }} transition={{ duration: 1, repeat: Infinity }}>...</motion.span>
            ) : t('wp_form_ai_btn')}
          </motion.button>
        </div>
        <div
          role={generationError ? "alert" : undefined}
          style={{ fontSize: 10, color: generationError ? "#e53535" : "#333", letterSpacing: 1, marginTop: 8 }}>
          {generationError || t('wp_form_ai_hint')}
        </div>
      </motion.div>

      <motion.div {...fadeUp(0.12)} style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 12, marginBottom: 14 }}>
        <div>
          <div style={{ fontSize: 10, letterSpacing: 2, color: "#555", marginBottom: 6 }}>{t('wp_form_name_label')}</div>
          <input placeholder={t('wp_form_name_placeholder')} value={newName} onChange={e => setNewName(e.target.value)} style={{ fontSize: 13 }} />
        </div>
        <div>
          <div style={{ fontSize: 10, letterSpacing: 2, color: "#555", marginBottom: 6 }}>{t('wp_form_category_label')}</div>
          <input placeholder={t('wp_form_category_placeholder')} value={newCategory} onChange={e => setNewCategory(e.target.value)} style={{ fontSize: 13 }} />
        </div>
      </motion.div>

      {/* Word list */}
      <motion.div {...fadeUp(0.16)} style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 10, letterSpacing: 2, color: "#555", marginBottom: 10 }}>
          {t('wp_form_words_label')} ({editWords.length}) {t('wp_form_words_min')}
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 10, minHeight: 36 }}>
          <AnimatePresence>
            {editWords.map(w => (
              <motion.div key={w}
                initial={{ opacity: 0, scale: 0.8 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.7 }}
                transition={{ duration: 0.18 }}
                style={{ display: "flex", alignItems: "center", gap: 6, padding: "4px 8px 4px 10px",
                  background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.25)", fontSize: 12 }}>
                <span>{w}</span>
                <button onClick={() => removeWord(w)}
                  style={{ background: "none", border: "none", color: "#e53535", cursor: "pointer", fontSize: 14, lineHeight: 1, padding: 0 }}>×</button>
              </motion.div>
            ))}
          </AnimatePresence>
          {editWords.length === 0 && (
            <motion.span {...fadeIn(0)} style={{ fontSize: 11, color: "#333", fontFamily: "monospace" }}>{t('wp_form_words_empty')}</motion.span>
          )}
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <input
            placeholder={t('wp_add_placeholder')}
            value={newWord}
            onChange={e => setNewWord(e.target.value)}
            onKeyDown={e => e.key === "Enter" && addWord()}
            style={{ flex: 1, fontSize: 13 }}
          />
          <motion.button whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.97 }}
            className="btn-ghost" onClick={addWord} disabled={!newWord.trim()}
            style={{ fontSize: 11, padding: "10px 16px" }}>{t('wp_add_btn')}</motion.button>
        </div>
      </motion.div>

      <motion.div {...fadeUp(0.2)} style={{ display: "flex", gap: 10 }}>
        <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
          className="btn-red" onClick={editing ? handleSaveEdit : handleCreate}
          disabled={!newName.trim() || editWords.length < 2}
          style={{ flex: 1, fontSize: 11, padding: "13px 0" }}>
          {editing ? t('wp_form_save') : t('wp_form_create')}
        </motion.button>
        <motion.button whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.98 }}
          className="btn-ghost" onClick={onCancel}
          style={{ fontSize: 11, padding: "13px 20px" }}>{t('wp_form_cancel')}</motion.button>
      </motion.div>
    </motion.div>
  );
}

export default function WordPacks() {
  const { t } = useLanguage();
  const [user, setUser] = useState(null);
  const [packs, setPacks] = useState([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState(null);
  const [newName, setNewName] = useState("");
  const [newCategory, setNewCategory] = useState("");
  const [newWord, setNewWord] = useState("");
  const [editWords, setEditWords] = useState([]);
  const [generating, setGenerating] = useState(false);
  const [aiGenerationError, setAiGenerationError] = useState("");
  const [aiTheme, setAiTheme] = useState("");
  const [aiWordCount, setAiWordCount] = useState(12);
  const [expandedPacks, setExpandedPacks] = useState({});
  const aiGenerationInFlightRef = useRef(false);
  const aiGenerationTokenRef = useRef(0);
  const quota = useGlobalQuota();
  const navigate = useNavigate();

  useEffect(() => {
    base44.auth.me().then(u => {
      if (!u) { base44.auth.redirectToLogin(undefined); return; }
      setUser(u);
      loadPacks();
    }).catch(() => navigate(createPageUrl("Home")));
  }, []);

  const loadPacks = async () => {
    setLoading(true);
    const all = await listWordPacks();
    setPacks(all);
    setLoading(false);
  };

  const handleCreate = async () => {
    if (!newName.trim() || editWords.length < 2) return;
    await createWordPack({
      name: newName.trim(),
      category: newCategory.trim() || newName.trim(),
      words: editWords,
    });
    setCreating(false);
    setNewName(""); setNewCategory(""); setEditWords([]);
    loadPacks();
  };

  const handleDelete = async (id) => {
    await deleteWordPack(id);
    setPacks(p => p.filter(x => x.id !== id));
  };

  const startEdit = (pack) => {
    setEditing(pack.id);
    setNewName(pack.name);
    setNewCategory(pack.category || "");
    setEditWords([...(pack.words || [])]);
  };

  const handleSaveEdit = async () => {
    if (!newName.trim() || editWords.length < 2) return;
    await updateWordPack(editing, {
      name: newName.trim(),
      category: newCategory.trim() || newName.trim(),
      words: editWords
    });
    setEditing(null);
    loadPacks();
  };

  const addWord = () => {
    const w = newWord.trim();
    if (!w || editWords.includes(w)) return;
    setEditWords(prev => [...prev, w]);
    setNewWord("");
  };

  const removeWord = (w) => setEditWords(prev => prev.filter(x => x !== w));

  const updateAITheme = (value) => {
    aiGenerationTokenRef.current += 1;
    setAiGenerationError("");
    setAiTheme(value);
  };

  const updateAIWordCount = (value) => {
    aiGenerationTokenRef.current += 1;
    setAiGenerationError("");
    setAiWordCount(value);
  };

  const generateFromAI = async () => {
    const theme = aiTheme.trim();
    if (!theme || aiGenerationInFlightRef.current) return;

    aiGenerationInFlightRef.current = true;
    const requestToken = ++aiGenerationTokenRef.current;
    setGenerating(true);
    setAiGenerationError("");
    try {
      const result = await generateWordPool(theme, aiWordCount);
      if (aiGenerationTokenRef.current !== requestToken) return;

      if (result?.words?.length) {
        setEditWords(result.words);
        setNewCategory(current => current.trim() ? current : (result.display_category || theme));
        setNewName(current => current.trim() ? current : theme);
        quota.increment(result);
      } else {
        setAiGenerationError(t('wp_ai_generation_failed'));
      }
    } catch (e) {
      const status = e?.status ?? e?.response?.status;
      if (aiGenerationTokenRef.current === requestToken) {
        console.error("AI word pack generation failed", e);
        setAiGenerationError(status === 429 || status === 503
          ? t('wp_ai_service_unavailable')
          : t('wp_ai_generation_failed'));
      }
    } finally {
      aiGenerationInFlightRef.current = false;
      setGenerating(false);
    }
  };

  const cancelForm = () => {
    aiGenerationTokenRef.current += 1;
    setAiGenerationError("");
    setCreating(false);
    setEditing(null);
    setNewName(""); setNewCategory(""); setEditWords([]); setAiTheme(""); setAiWordCount(12);
  };

  const isFormOpen = creating || !!editing;

  return (
    <PageChrome eyebrow="// WORD PACKS" status="ARMORY">
    <div style={{ maxWidth: 580, margin: "0 auto", padding: "clamp(20px, 4vw, 40px) 16px" }}>
      {/* Breadcrumb */}
      <motion.div {...fadeIn(0)}
        style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 24, fontFamily: "monospace", display: "flex", alignItems: "center", gap: 8 }}>
        <Link to={createPageUrl("Home")} style={{ color: "#e53535", textDecoration: "none" }}>{t('wp_page_breadcrumb_home')}</Link>
        <span style={{ color: "#333" }}>//</span>
        <span>{t('wp_page_title')}</span>
      </motion.div>

      {/* Header */}
      <motion.div {...fadeUp(0.15)}
        style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, marginBottom: 24, flexWrap: "wrap" }}>
        <div style={{ minWidth: 0 }}>
          <AnimatedTitle text={String(t('wp_page_title')).toUpperCase()} delay={0.2} size={28} letterSpacing={3} />
          <div style={{ fontSize: 11, color: "#555", letterSpacing: 1, marginTop: 6 }}>{t('wp_page_subtitle')}</div>
        </div>
        <AnimatePresence>
          {!isFormOpen && (
            <motion.button
              key="create-btn"
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.9 }}
              whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}
              className="btn-red"
              onClick={() => { setCreating(true); setNewName(""); setNewCategory(""); setEditWords([]); setAiTheme(""); }}
              style={{ fontSize: 11, padding: "12px 20px", flexShrink: 0 }}>
              {t('wp_page_create_btn')}
            </motion.button>
          )}
        </AnimatePresence>
      </motion.div>

      <AnimatePresence>
        {isFormOpen && (
          <FormPanel
            key="form"
            editing={editing}
            t={t}
            aiTheme={aiTheme} setAiTheme={updateAITheme}
            aiWordCount={aiWordCount} setAiWordCount={updateAIWordCount}
            generating={generating} generationError={aiGenerationError} generateFromAI={generateFromAI}
            newName={newName} setNewName={setNewName}
            newCategory={newCategory} setNewCategory={setNewCategory}
            editWords={editWords} removeWord={removeWord}
            newWord={newWord} setNewWord={setNewWord} addWord={addWord}
            handleSaveEdit={handleSaveEdit} handleCreate={handleCreate}
            onCancel={cancelForm}
          />
        )}
      </AnimatePresence>

      {/* Content */}
      <AnimatePresence mode="wait">
        {loading ? (
          <motion.div key="loading"
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            style={{ textAlign: "center", paddingTop: 40 }}>
            <motion.div
              animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }}
              style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}>
              {t('loading')}
            </motion.div>
          </motion.div>
        ) : packs.length === 0 && !isFormOpen ? (
          <motion.div key="empty"
            initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
            transition={{ duration: 0.4 }}
            style={{ textAlign: "center", padding: "60px 20px", color: "#333", fontFamily: "monospace", fontSize: 13, letterSpacing: 2 }}>
            {t('wp_page_empty')}<br /><br />
            <motion.button whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
              className="btn-outline" onClick={() => setCreating(true)} style={{ fontSize: 11, padding: "12px 24px" }}>
              {t('wp_page_create_first')}
            </motion.button>
          </motion.div>
        ) : (
          <motion.div key="list"
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            transition={{ delay: 0.25, duration: 0.4 }}
            style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            {packs.map((pack, i) => (
              <motion.div key={pack.id}
                initial={{ opacity: 0, y: 18 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, x: -20 }}
                transition={{ delay: 0.3 + i * 0.07, duration: 0.45, ease: [0.16, 1, 0.3, 1] }}
                whileHover={{ borderColor: "#2a2a2a" }}
                style={{ position: "relative", background: "#0a0a0a", border: "1px solid #1e1e1e", padding: 20, transition: "border-color 0.2s" }}>
                <div style={{ position: "absolute", top: 0, left: 0, width: 10, height: 10, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />

                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 12 }}>
                  <div>
                    <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 18, letterSpacing: 2 }}>{pack.name}</div>
                    {pack.category && pack.category !== pack.name && (
                      <div style={{ fontSize: 10, color: "#555", letterSpacing: 2, marginTop: 2 }}>{pack.category}</div>
                    )}
                  </div>
                  <div style={{ display: "flex", gap: 8 }}>
                    <motion.button whileHover={{ scale: 1.05, borderColor: "#444", color: "#aaa" }} whileTap={{ scale: 0.95 }}
                      onClick={() => setExpandedPacks(s => ({ ...s, [pack.id]: !s[pack.id] }))}
                      style={{ background: "none", border: "1px solid #2a2a2a", color: expandedPacks[pack.id] ? "#aaa" : "#666", padding: "6px 12px", cursor: "pointer", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", transition: "all 0.2s" }}>
                      {expandedPacks[pack.id] ? "▴" : "▾"}
                    </motion.button>
                    <motion.button whileHover={{ scale: 1.05, borderColor: "#444", color: "#aaa" }} whileTap={{ scale: 0.95 }}
                      onClick={() => startEdit(pack)}
                      style={{ background: "none", border: "1px solid #2a2a2a", color: "#666", padding: "6px 12px", cursor: "pointer", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", transition: "all 0.2s" }}>
                      {t('wp_edit_btn')}
                    </motion.button>
                    <motion.button whileHover={{ scale: 1.05, background: "rgba(229,53,53,0.1)" }} whileTap={{ scale: 0.95 }}
                      onClick={() => handleDelete(pack.id)}
                      style={{ background: "none", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", padding: "6px 12px", cursor: "pointer", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", transition: "all 0.2s" }}>
                      ✕
                    </motion.button>
                  </div>
                </div>

                <AnimatePresence initial={false}>
                  {expandedPacks[pack.id] && (
                    <motion.div
                      key="words"
                      initial={{ opacity: 0, height: 0 }}
                      animate={{ opacity: 1, height: "auto" }}
                      exit={{ opacity: 0, height: 0 }}
                      transition={{ duration: 0.25, ease: [0.16, 1, 0.3, 1] }}
                      style={{ overflow: "hidden" }}>
                      <div style={{ display: "flex", flexWrap: "wrap", gap: 5, paddingTop: 2 }}>
                        {(pack.words || []).map((w, wi) => (
                          <motion.span key={w}
                            initial={{ opacity: 0, scale: 0.85 }}
                            animate={{ opacity: 1, scale: 1 }}
                            transition={{ delay: wi * 0.015 }}
                            style={{ fontSize: 11, padding: "3px 8px", background: "#080808", border: "1px solid #1a1a1a", color: "#777", fontFamily: "monospace" }}>
                            {w}
                          </motion.span>
                        ))}
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>

                <div style={{ marginTop: 10, fontSize: 10, color: "#333", letterSpacing: 1 }}>
                  {(pack.words || []).length} {t('wp_page_words_count')}
                </div>
              </motion.div>
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
    </PageChrome>
  );
}

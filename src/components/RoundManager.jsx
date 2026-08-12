import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

export default function RoundManager({ room, user, onAnswerHeard }) {
  const { lang } = useLanguage();
  if (!room) return null;

  const currentAsker = room.players?.find(p => p.email === room.current_asker_email);
  const currentAnswerer = room.players?.find(p => p.email === room.current_answerer_email);
  const isAsking = user?.email === room.current_asker_email;
  const isAnswering = user?.email === room.current_answerer_email;
  const questionsLeft = 4 - (room.questions_in_round || 0);

  return (
    <AnimatePresence mode="wait">
      {isAnswering && (
        <motion.div
          key="answering"
          initial={{ opacity: 0, scale: 0.95, y: 20 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95, y: -20 }}
          style={{
            position: "fixed",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "rgba(0,0,0,0.8)",
            backdropFilter: "blur(10px)",
            zIndex: 1000,
          }}
        >
          <div style={{ textAlign: "center" }}>
            <motion.div
              animate={{ scale: [1, 1.1, 1] }}
              transition={{ duration: 2, repeat: Infinity }}
              style={{ fontSize: 80, marginBottom: 28 }}
            >
              {currentAsker?.avatar || "🕵️"}
            </motion.div>
            <div
              style={{
                fontFamily: "'Rajdhani', sans-serif",
                fontSize: 48,
                fontWeight: 700,
                letterSpacing: 3,
                marginBottom: 14,
              }}
            >
              {currentAsker?.name?.toUpperCase()}
            </div>
            <div
              style={{
                fontSize: 18,
                color: "#555",
                letterSpacing: 2,
                marginBottom: 32,
              }}
            >
              {localize(lang, "IS ASKING YOU A QUESTION...", "ЗАДАЁТ ВАМ ВОПРОС...", "СТАВИТЬ ВАМ ЗАПИТАННЯ...")}
            </div>
          </div>
        </motion.div>
      )}

      {isAsking && (
        <motion.div
          key="asking"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -20 }}
          style={{
            position: "relative",
            padding: "24px 20px",
            background: "rgba(229,53,53,0.08)",
            border: "1px solid rgba(229,53,53,0.25)",
            marginBottom: 20,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <div>
              <div style={{ fontSize: 10, color: "#e53535", letterSpacing: 3, marginBottom: 8 }}>
                // {localize(lang, "YOU ARE ASKING", "ВЫ ЗАДАЁТЕ ВОПРОС", "ВИ СТАВИТЕ ЗАПИТАННЯ")}
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <span style={{ fontSize: 32 }}>{currentAnswerer?.avatar || "🕵️"}</span>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontSize: 16, fontWeight: 700, letterSpacing: 2 }}>
                  {currentAnswerer?.name?.toUpperCase()}
                </div>
              </div>
            </div>
            <motion.button
              whileHover={{ scale: 1.02 }}
              whileTap={{ scale: 0.98 }}
              className="btn-red"
              onClick={onAnswerHeard}
              style={{ fontSize: 12, padding: "12px 24px", whiteSpace: "nowrap" }}
            >
              {localize(lang, "ANSWER RECEIVED", "ОТВЕТ ПОЛУЧЕН", "ВІДПОВІДЬ ОТРИМАНО")}
            </motion.button>
          </div>
          <div
            style={{
              marginTop: 12,
              fontSize: 10,
              color: "#555",
              letterSpacing: 2,
            }}
          >
            {localize(lang, "QUESTIONS THIS ROUND", "ВОПРОСОВ В РАУНДЕ", "ЗАПИТАНЬ У РАУНДІ")}: {room.questions_in_round || 0}/4
          </div>
        </motion.div>
      )}

      {!isAsking && !isAnswering && currentAsker && currentAnswerer && (
        <motion.div
          key="watching"
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -10 }}
          style={{
            position: "relative",
            padding: "18px 20px",
            background: "#080808",
            border: "1px solid #141414",
            marginBottom: 16,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 16, fontSize: 13 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <span>{currentAsker.avatar}</span>
              <span style={{ fontWeight: 700 }}>{currentAsker.name}</span>
            </div>
            <span style={{ color: "#555" }}>→</span>
            <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <span>{currentAnswerer.avatar}</span>
              <span style={{ fontWeight: 700 }}>{currentAnswerer.name}</span>
            </div>
            <span style={{ marginLeft: "auto", color: "#333", fontSize: 10, letterSpacing: 2 }}>
              {room.questions_in_round || 0}/4
            </span>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

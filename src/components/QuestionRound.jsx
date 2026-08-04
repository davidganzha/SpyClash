import { useState, useEffect } from "react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { runGameRoomAction } from "@/lib/gameRoomActions";

export default function QuestionRound({ room, user, onRoundComplete, disabled = false }) {
  const { t } = useLanguage();
  const [submitting, setSubmitting] = useState(false);
  const [countdown, setCountdown] = useState(0);

  const isAsker = room?.current_asker_email === user?.email;
  const isAnswerer = room?.current_answerer_email === user?.email;
  const asker = (room?.players || []).find(p => p.email === room?.current_asker_email);
  const answerer = (room?.players || []).find(p => p.email === room?.current_answerer_email);
  const isAssociations = room?.game_mode === "associations";

  useEffect(() => {
    if (disabled || room?.question_phase !== "countdown") return;

    // Sync countdown from server timestamp so all clients show the same number
    const startedAt = room?.countdown_started_at ? new Date(room.countdown_started_at).getTime() : Date.now();
    const DURATION = 5;
    let timer = null;
    let finished = false;

    const tick = () => {
      const elapsed = Math.floor((Date.now() - startedAt) / 1000);
      const remaining = Math.max(0, DURATION - elapsed);
      setCountdown(remaining);
      if (remaining === 0) {
        finished = true;
        if (timer) clearInterval(timer);
        // Only the asker triggers round advance to avoid duplicate writes
        if (isAsker) onRoundComplete?.();
      }
    };

    tick();
    if (!finished) timer = setInterval(tick, 500);
    return () => clearInterval(timer);
  }, [disabled, room?.question_phase, room?.countdown_started_at]);

  const handleAnswerHeardAsker = async () => {
    if (submitting || disabled) return;
    setSubmitting(true);
    await runGameRoomAction("mark_answer_heard", room.id);
    setSubmitting(false);
  };

  if (room?.question_phase === "countdown") {
    return (
      <div style={{ position: "relative", padding: "20px 28px", background: "#0a0a0a", border: "1px solid #1e1e1e", textAlign: "center", marginBottom: 20 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #333", borderRight: "1px solid #333" }} />
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#555", marginBottom: 12 }}>{t('qr_next_question')}</div>
        <motion.div initial={{ opacity: 0, scale: 0.8 }} animate={{ opacity: 1, scale: 1 }}
          style={{ fontSize: 60, fontWeight: 700, color: "#e53535" }}>
          {countdown}
        </motion.div>
      </div>
    );
  }

  if (isAnswerer && room?.question_phase === "asking") {
    return (
      <div style={{ position: "relative", padding: 24, background: "rgba(229,53,53,0.05)", border: "1px solid rgba(229,53,53,0.2)", marginBottom: 20, textAlign: "center" }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#e53535", marginBottom: 14 }}>{t('qr_being_asked')}</div>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, marginBottom: 14 }}>
          <span style={{ fontSize: 28 }}>{asker?.avatar || "🕵️"}</span>
          <span style={{ fontSize: 20, color: "#555" }}>→</span>
          <span style={{ fontSize: 28 }}>{answerer?.avatar || "🕵️"}</span>
        </div>
        <div style={{ fontSize: 13, color: "#ddd", letterSpacing: 1, marginBottom: 16 }}>
          <strong>{asker?.name?.toUpperCase()}</strong> {isAssociations ? (t('qr_gives_word') || 'gives you a word') : t('qr_asks_you')}
        </div>
        {isAssociations && room?.current_answer && (
          <div style={{ padding: 16, background: "rgba(255,255,255,0.05)", border: "1px solid rgba(229,53,53,0.3)", marginBottom: 14, fontSize: 28, fontWeight: 700, color: "#e53535", fontFamily: "monospace" }}>
            {room.current_answer}
          </div>
        )}
        <motion.div animate={{ opacity: [1, 0.3, 1] }} transition={{ duration: 2, repeat: Infinity }}
          style={{ color: "#555", fontSize: 11, letterSpacing: 2 }}>
          {isAssociations ? (t('qr_say_association') || 'Say your association') : t('qr_listen')}
        </motion.div>
      </div>
    );
  }

  if (isAsker && room?.question_phase === "asking") {
    return (
      <div style={{ position: "relative", padding: 24, background: "#0a0a0a", border: "1px solid #1e1e1e", marginBottom: 20 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#e53535", marginBottom: 14 }}>{t('qr_your_turn')}</div>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 16 }}>
          <span style={{ fontSize: 24 }}>{answerer?.avatar || "🕵️"}</span>
          <div>
            <div style={{ fontSize: 10, color: "#555", letterSpacing: 2, marginBottom: 2 }}>
              {isAssociations ? t('qr_give_word') || 'Give association to' : t('qr_ask_agent')}
            </div>
            <div style={{ fontFamily: "monospace", fontSize: 13, letterSpacing: 1, color: "#ccc" }}>{answerer?.name?.toUpperCase()}</div>
          </div>
        </div>
        {isAssociations && room?.current_answer && (
          <div style={{ padding: 12, background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.2)", marginBottom: 14, fontSize: 14, fontWeight: 700, color: "#e53535", textAlign: "center", fontFamily: "monospace" }}>
            {room.current_answer}
          </div>
        )}
        <motion.button whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}
          onClick={handleAnswerHeardAsker} disabled={submitting || disabled}
          className="btn-red"
          style={{ width: "100%", fontSize: 12, padding: "14px 0" }}>
          {isAssociations ? (t('qr_word_given_btn') || 'Word received') : t('qr_answer_received_btn')}
        </motion.button>
      </div>
    );
  }

  if (room?.question_phase === "asking") {
    return (
      <div style={{ position: "relative", padding: 20, background: "#080808", border: "1px solid #141414", marginBottom: 20 }}>
        <div style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 14, textAlign: "center" }}>{t('qr_question_num')} {room?.questions_in_round || 0}/8</div>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-around", marginBottom: 16 }}>
          <div style={{ textAlign: "center" }}>
            <div style={{ fontSize: 28, marginBottom: 6 }}>{asker?.avatar || "🕵️"}</div>
            <div style={{ fontSize: 9, color: "#555", letterSpacing: 2 }}>{t('qr_asks')}</div>
            <div style={{ fontSize: 11, fontFamily: "monospace", color: "#aaa", marginTop: 2 }}>{asker?.name}</div>
          </div>
          <div style={{ fontSize: 24, color: "#2a2a2a" }}>→</div>
          <div style={{ textAlign: "center" }}>
            <div style={{ fontSize: 28, marginBottom: 6 }}>{answerer?.avatar || "🕵️"}</div>
            <div style={{ fontSize: 9, color: "#555", letterSpacing: 2 }}>{t('qr_answers')}</div>
            <div style={{ fontSize: 11, fontFamily: "monospace", color: "#aaa", marginTop: 2 }}>{answerer?.name}</div>
          </div>
        </div>
        <div style={{ fontSize: 10, color: "#333", letterSpacing: 2, textAlign: "center" }}>{t('qr_listening')}</div>
      </div>
    );
  }

  return (
    <div style={{ position: "relative", padding: 20, background: "#080808", border: "1px solid #141414", marginBottom: 20, textAlign: "center" }}>
      <div style={{ fontSize: 10, letterSpacing: 3, color: "#333", marginBottom: 12 }}>{t('qr_awaiting')}</div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-around", marginBottom: 14 }}>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 24 }}>{asker?.avatar || "🕵️"}</div>
          <div style={{ fontSize: 9, color: "#555", letterSpacing: 1, marginTop: 4 }}>{asker?.name}</div>
        </div>
        <div style={{ fontSize: 20, color: "#2a2a2a" }}>→</div>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 24 }}>{answerer?.avatar || "🕵️"}</div>
          <div style={{ fontSize: 9, color: "#555", letterSpacing: 1, marginTop: 4 }}>{answerer?.name}</div>
        </div>
      </div>
      <div style={{ fontSize: 11, color: "#444", letterSpacing: 1, marginBottom: 14 }}>{t('qr_waiting_feedback')}</div>
    </div>
  );
}

import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { base44 } from "@/api/base44Client";
import { useLanguage } from "@/components/LanguageContext";

export default function DeleteAccountSection() {
  const { lang } = useLanguage();
  const [open, setOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");

  const confirm = async () => {
    setDeleting(true); setError("");
    try {
      await base44.functions.invoke("deleteAccount", {});
      base44.auth.logout("/");
    } catch (e) {
      console.error(e);
      setError(lang === "ru" ? "Не удалось удалить аккаунт" : "Failed to delete account");
      setDeleting(false);
    }
  };

  return (
    <>
      <motion.div initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.7, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
        style={{ position: "relative", background: "#0a0a0a", border: "1px solid rgba(229,53,53,0.3)", padding: 24, marginTop: 16, marginBottom: 24 }}>
        <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
        <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
        <div style={{ fontSize: 10, letterSpacing: 4, color: "#e53535", marginBottom: 10, fontFamily: "'Share Tech Mono', monospace" }}>
          {lang === "ru" ? "// ОПАСНАЯ ЗОНА" : "// DANGER ZONE"}
        </div>
        <div style={{ color: "#888", fontSize: 12, letterSpacing: 0.5, marginBottom: 18, lineHeight: 1.6 }}>
          {lang === "ru"
            ? "Удаление аккаунта необратимо. Профиль, история, паки и социальные данные будут удалены. Если у тебя остался старый платёжный договор с провайдером, его нужно отменить отдельно."
            : "Deleting your account is permanent. Your profile, history, packs, and social data are removed. If you still have a legacy provider billing agreement, cancel it separately with that provider."}
        </div>
        <button className="btn-red" onClick={() => setOpen(true)} style={{ fontSize: 11 }}>
          {lang === "ru" ? "УДАЛИТЬ АККАУНТ" : "DELETE ACCOUNT"}
        </button>
      </motion.div>

      <AnimatePresence>
        {open && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            onClick={() => !deleting && setOpen(false)}
            style={{
              position: "fixed", inset: 0, background: "rgba(0,0,0,0.85)", backdropFilter: "blur(4px)",
              zIndex: 200, display: "flex", alignItems: "center", justifyContent: "center", padding: 20,
            }}>
            <motion.div
              initial={{ scale: 0.9, opacity: 0, y: 10 }}
              animate={{ scale: 1, opacity: 1, y: 0 }}
              exit={{ scale: 0.92, opacity: 0 }}
              transition={{ duration: 0.25, ease: [0.22, 0.61, 0.36, 1] }}
              onClick={(e) => e.stopPropagation()}
              style={{
                position: "relative", maxWidth: 400, width: "100%",
                background: "#0a0a0a", border: "1px solid #e53535", padding: 28,
              }}>
              <div style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
              <div style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
              <div style={{ fontSize: 10, letterSpacing: 4, color: "#e53535", marginBottom: 14, fontFamily: "'Share Tech Mono', monospace" }}>
                {lang === "ru" ? "ПОДТВЕРДИ УДАЛЕНИЕ" : "CONFIRM DELETION"}
              </div>
              <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 24, letterSpacing: 2, marginBottom: 14, color: "#fff" }}>
                {lang === "ru" ? "Удалить аккаунт?" : "Delete account?"}
              </div>
              <div style={{ color: "#888", fontSize: 12, lineHeight: 1.6, marginBottom: 20 }}>
                {lang === "ru"
                  ? "Профиль и игровые данные будут удалены навсегда. Старым платёжным договором нужно управлять отдельно у его провайдера; ограниченные записи о прошлых транзакциях могут храниться для предотвращения мошенничества и выполнения юридических обязательств."
                  : "Your profile and game data will be permanently removed. Manage any legacy billing agreement separately with its provider; limited past-transaction records may be retained for fraud prevention and legal obligations."}
              </div>
              {error && (
                <div style={{ color: "#e53535", fontSize: 11, marginBottom: 12, letterSpacing: 1, fontFamily: "monospace" }}>⚠ {error}</div>
              )}
              <div style={{ display: "flex", gap: 10 }}>
                <button className="btn-ghost" onClick={() => setOpen(false)} disabled={deleting} style={{ flex: 1, fontSize: 11 }}>
                  {lang === "ru" ? "ОТМЕНА" : "CANCEL"}
                </button>
                <button className="btn-red" onClick={confirm} disabled={deleting} style={{ flex: 1, fontSize: 11 }}>
                  {deleting
                    ? (lang === "ru" ? "УДАЛЕНИЕ..." : "DELETING...")
                    : (lang === "ru" ? "УДАЛИТЬ" : "DELETE")}
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}

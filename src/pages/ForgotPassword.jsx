import React, { useState } from "react";
import { Link } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { Mail, ArrowLeft, Loader2 } from "lucide-react";
import AuthLayout from "@/components/AuthLayout";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

export default function ForgotPassword() {
  const { lang } = useLanguage();
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    try {
      await base44.auth.resetPasswordRequest(email);
    } catch {
      // Always show success regardless
    } finally {
      setLoading(false);
      setSent(true);
    }
  };

  return (
    <AuthLayout
      icon={Mail}
      eyebrow={localize(lang, "RECOVERY PROTOCOL", "ПРОТОКОЛ ВОССТАНОВЛЕНИЯ", "ПРОТОКОЛ ВІДНОВЛЕННЯ")}
      title={localize(lang, "Reset Passphrase", "Сбросить пароль", "Скинути пароль")}
      subtitle={localize(lang, "Request a secure reset link", "Запросите безопасную ссылку для сброса", "Запросіть безпечне посилання для скидання")}
      footer={
        <Link to="/login" className="auth-link" style={{ fontWeight: 700 }}>
          <ArrowLeft className="w-3 h-3 inline mr-1" /> {localize(lang, "BACK TO LOGIN", "НАЗАД К ВХОДУ", "НАЗАД ДО ВХОДУ")}
        </Link>
      }
    >
      {sent ? (
        <div style={{ textAlign: "center", padding: "8px 0" }}>
          <div style={{ fontSize: 32, marginBottom: 12, color: "#e53535" }}>✓</div>
          <p style={{ fontSize: 13, color: "#ccc", letterSpacing: 1, fontFamily: "monospace", lineHeight: 1.6 }}>
            {localize(lang, "If credentials exist for that email,", "Если для этой почты есть учётная запись,", "Якщо для цієї адреси існує обліковий запис,")}<br />
            {localize(lang, "a recovery link is en route.", "ссылка для восстановления уже отправлена.", "посилання для відновлення вже надіслано.")}
          </p>
          <p style={{ fontSize: 10, color: "#444", letterSpacing: 2, fontFamily: "monospace", marginTop: 14 }}>
            // {localize(lang, "CHECK YOUR INBOX", "ПРОВЕРЬТЕ ПОЧТУ", "ПЕРЕВІРТЕ ПОШТУ")}
          </p>
        </div>
      ) : (
        <form onSubmit={handleSubmit} style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <div>
            <label htmlFor="email" className="auth-label">// {localize(lang, "EMAIL ADDRESS", "ЭЛЕКТРОННАЯ ПОЧТА", "ЕЛЕКТРОННА ПОШТА")}</label>
            <div style={{ position: "relative" }}>
              <Mail style={{ position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)", width: 16, height: 16, color: "#444" }} aria-hidden="true" />
              <input
                id="email"
                type="email"
                autoComplete="email"
                autoFocus
                placeholder="operative@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="auth-input"
                required
              />
            </div>
          </div>
          <button type="submit" className="auth-btn-red" disabled={loading} style={{ marginTop: 8 }}>
            {loading
              ? <><Loader2 className="w-4 h-4 animate-spin" /> {localize(lang, "DISPATCHING...", "ОТПРАВКА...", "НАДСИЛАННЯ...")}</>
              : localize(lang, "DISPATCH RESET LINK", "ОТПРАВИТЬ ССЫЛКУ", "НАДІСЛАТИ ПОСИЛАННЯ")}
          </button>
        </form>
      )}
    </AuthLayout>
  );
}

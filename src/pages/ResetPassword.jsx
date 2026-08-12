import React, { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { Lock, Loader2, AlertTriangle } from "lucide-react";
import AuthLayout from "@/components/AuthLayout";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

export default function ResetPassword() {
  const { lang } = useLanguage();
  const [searchParams] = useSearchParams();
  const resetToken = searchParams.get("token");

  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    if (newPassword !== confirmPassword) {
      setError(localize(lang, "Passphrases do not match", "Пароли не совпадают", "Паролі не збігаються"));
      return;
    }
    setLoading(true);
    try {
      await base44.auth.resetPassword({ resetToken, newPassword });
      window.location.href = "/login";
    } catch (err) {
      setError(err.message || localize(lang, "Failed to reset password", "Не удалось сбросить пароль", "Не вдалося скинути пароль"));
    } finally {
      setLoading(false);
    }
  };

  if (!resetToken) {
    return (
      <AuthLayout
        icon={AlertTriangle}
        eyebrow={localize(lang, "INVALID TOKEN", "НЕВЕРНЫЙ ТОКЕН", "НЕПРАВИЛЬНИЙ ТОКЕН")}
        title={localize(lang, "Link Compromised", "Ссылка недействительна", "Посилання недійсне")}
        subtitle={localize(lang, "This recovery link is missing or invalid", "Ссылка для восстановления отсутствует или недействительна", "Посилання для відновлення відсутнє або недійсне")}
        footer={
          <Link to="/forgot-password" className="auth-link" style={{ fontWeight: 700 }}>
            {localize(lang, "REQUEST NEW LINK →", "ЗАПРОСИТЬ НОВУЮ ССЫЛКУ →", "ЗАПРОСИТИ НОВЕ ПОСИЛАННЯ →")}
          </Link>
        }
      >
        <p style={{ fontSize: 13, color: "#ccc", letterSpacing: 1, fontFamily: "monospace", textAlign: "center", lineHeight: 1.6 }}>
          {localize(lang, "The recovery link you used is incomplete.", "Ссылка для восстановления неполная.", "Посилання для відновлення неповне.")}<br />
          {localize(lang, "Please request a new transmission.", "Запросите новую ссылку.", "Запросіть нове посилання.")}
        </p>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout
      icon={Lock}
      eyebrow={localize(lang, "SET NEW PASSPHRASE", "ЗАДАЙТЕ НОВЫЙ ПАРОЛЬ", "СТВОРІТЬ НОВИЙ ПАРОЛЬ")}
      title={localize(lang, "New Credentials", "Новые данные для входа", "Нові дані для входу")}
      subtitle={localize(lang, "Choose a strong new passphrase", "Выберите надёжный новый пароль", "Оберіть надійний новий пароль")}
    >
      {error && (
        <div style={{ marginBottom: 16, padding: "10px 14px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", fontSize: 12, letterSpacing: 1, fontFamily: "monospace" }}>
          ⚠ {error}
        </div>
      )}
      <form onSubmit={handleSubmit} style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <div>
          <label htmlFor="password" className="auth-label">// {localize(lang, "NEW PASSPHRASE", "НОВЫЙ ПАРОЛЬ", "НОВИЙ ПАРОЛЬ")}</label>
          <div style={{ position: "relative" }}>
            <Lock style={{ position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)", width: 16, height: 16, color: "#444" }} aria-hidden="true" />
            <input
              id="password"
              type="password"
              autoComplete="new-password"
              autoFocus
              placeholder="••••••••"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              className="auth-input"
              required
            />
          </div>
        </div>
        <div>
          <label htmlFor="confirm" className="auth-label">// {localize(lang, "CONFIRM PASSPHRASE", "ПОВТОРИТЕ ПАРОЛЬ", "ПОВТОРІТЬ ПАРОЛЬ")}</label>
          <div style={{ position: "relative" }}>
            <Lock style={{ position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)", width: 16, height: 16, color: "#444" }} aria-hidden="true" />
            <input
              id="confirm"
              type="password"
              autoComplete="new-password"
              placeholder="••••••••"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              className="auth-input"
              required
            />
          </div>
        </div>
        <button type="submit" className="auth-btn-red" disabled={loading} style={{ marginTop: 8 }}>
          {loading
            ? <><Loader2 className="w-4 h-4 animate-spin" /> {localize(lang, "RESETTING...", "СБРОС...", "СКИДАННЯ...")}</>
            : localize(lang, "CONFIRM NEW KEY", "ПОДТВЕРДИТЬ НОВЫЙ КЛЮЧ", "ПІДТВЕРДИТИ НОВИЙ КЛЮЧ")}
        </button>
      </form>
    </AuthLayout>
  );
}

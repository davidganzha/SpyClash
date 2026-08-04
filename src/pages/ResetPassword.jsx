import React, { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { Lock, Loader2, AlertTriangle } from "lucide-react";
import AuthLayout from "@/components/AuthLayout";

export default function ResetPassword() {
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
      setError("Passphrases do not match");
      return;
    }
    setLoading(true);
    try {
      await base44.auth.resetPassword({ resetToken, newPassword });
      window.location.href = "/login";
    } catch (err) {
      setError(err.message || "Failed to reset password");
    } finally {
      setLoading(false);
    }
  };

  if (!resetToken) {
    return (
      <AuthLayout
        icon={AlertTriangle}
        eyebrow="INVALID TOKEN"
        title="Link Compromised"
        subtitle="This recovery link is missing or invalid"
        footer={
          <Link to="/forgot-password" className="auth-link" style={{ fontWeight: 700 }}>
            REQUEST NEW LINK →
          </Link>
        }
      >
        <p style={{ fontSize: 13, color: "#ccc", letterSpacing: 1, fontFamily: "monospace", textAlign: "center", lineHeight: 1.6 }}>
          The recovery link you used is incomplete.<br />
          Please request a new transmission.
        </p>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout
      icon={Lock}
      eyebrow="SET NEW PASSPHRASE"
      title="New Credentials"
      subtitle="Choose a strong new passphrase"
    >
      {error && (
        <div style={{ marginBottom: 16, padding: "10px 14px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", fontSize: 12, letterSpacing: 1, fontFamily: "monospace" }}>
          ⚠ {error}
        </div>
      )}
      <form onSubmit={handleSubmit} style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <div>
          <label htmlFor="password" className="auth-label">// NEW PASSPHRASE</label>
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
          <label htmlFor="confirm" className="auth-label">// CONFIRM PASSPHRASE</label>
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
          {loading ? <><Loader2 className="w-4 h-4 animate-spin" /> RESETTING...</> : "CONFIRM NEW KEY"}
        </button>
      </form>
    </AuthLayout>
  );
}
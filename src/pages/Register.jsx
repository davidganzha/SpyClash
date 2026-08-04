import React, { useState } from "react";
import { Link } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { UserPlus, Mail, Lock, Loader2, ArrowRight, ArrowLeft, Pencil } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import { InputOTP, InputOTPGroup, InputOTPSlot } from "@/components/ui/input-otp";
import AuthLayout from "@/components/AuthLayout";
import GoogleIcon from "@/components/GoogleIcon";
import AppleIcon from "@/components/AppleIcon";
import { appParams } from "@/lib/app-params";
import { buildSocialLoginUrl } from "@/lib/socialAuth";
import { toast } from "@/components/ui/use-toast";

export default function Register() {
  const [step, setStep] = useState("email"); // "email" | "password" | "otp"
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [otpCode, setOtpCode] = useState("");

  const handleEmailContinue = (e) => {
    e.preventDefault();
    setError("");
    if (!email) return;
    setStep("password");
  };

  const handleRegister = async (e) => {
    e.preventDefault();
    setError("");
    if (password !== confirmPassword) {
      setError("Passphrases do not match");
      return;
    }
    setLoading(true);
    try {
      await base44.auth.register({ email, password });
      setStep("otp");
    } catch (err) {
      setError(err.message || "Registration failed");
    } finally {
      setLoading(false);
    }
  };

  const handleVerify = async () => {
    setError("");
    setLoading(true);
    try {
      // Verify the OTP — this confirms the email
      const result = await base44.auth.verifyOtp({ email, otpCode });
      const token = result?.access_token || result?.data?.access_token;
      if (token) {
        base44.auth.setToken(token);
        window.location.replace("/home");
        return;
      }
      // No token returned — send user to login page (email is now verified)
      window.location.href = `/login?email=${encodeURIComponent(email)}`;
    } catch (err) {
      setError(err.message || "Invalid verification code");
      setLoading(false);
    }
  };

  const handleResend = async () => {
    setError("");
    try {
      await base44.auth.resendOtp(email);
      toast({ title: "Code sent", description: "Check your email for the new code." });
    } catch (err) {
      setError(err.message || "Failed to resend code");
    }
  };

  const handleSocialLogin = (provider) => {
    const loginUrl = buildSocialLoginUrl({
      provider,
      appId: appParams.appId,
      origin: window.location.origin,
    });
    window.location.assign(loginUrl);
  };
  const backToEmail = () => { setStep("email"); setPassword(""); setConfirmPassword(""); setError(""); };

  const stepVariants = {
    enter: (dir) => ({ x: dir > 0 ? 40 : -40, opacity: 0 }),
    center: { x: 0, opacity: 1 },
    exit: (dir) => ({ x: dir > 0 ? -40 : 40, opacity: 0 }),
  };
  const stepOrder = { email: 0, password: 1, otp: 2 };
  const direction = stepOrder[step];

  const eyebrowMap = { email: "NEW OPERATIVE", password: "SET PASSPHRASE", otp: "VERIFICATION REQUIRED" };
  const titleMap = { email: "Join the Network", password: "Create Passphrase", otp: "Confirm Identity" };
  const subtitleMap = {
    email: "Create credentials to enter the game",
    password: "Choose a secure key",
    otp: `Transmission sent to ${email}`,
  };
  const iconMap = { email: UserPlus, password: Lock, otp: Mail };

  const EmailChip = ({ onClick }) => (
    <button
      type="button"
      onClick={onClick}
      style={{
        width: "100%", display: "flex", alignItems: "center", gap: 10,
        padding: "10px 14px", marginBottom: 18,
        background: "rgba(229,53,53,0.06)", border: "1px solid rgba(229,53,53,0.25)",
        color: "#ccc", fontFamily: "'Share Tech Mono', monospace",
        fontSize: 12, letterSpacing: 1, cursor: "pointer", borderRadius: 2, transition: "all 0.2s",
      }}
      onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(229,53,53,0.12)"; e.currentTarget.style.borderColor = "#e53535"; }}
      onMouseLeave={(e) => { e.currentTarget.style.background = "rgba(229,53,53,0.06)"; e.currentTarget.style.borderColor = "rgba(229,53,53,0.25)"; }}
    >
      <ArrowLeft style={{ width: 14, height: 14, color: "#e53535" }} />
      <Mail style={{ width: 14, height: 14, color: "#666" }} />
      <span style={{ flex: 1, textAlign: "left", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{email}</span>
      <Pencil style={{ width: 12, height: 12, color: "#666" }} />
    </button>
  );

  return (
    <AuthLayout
      icon={iconMap[step]}
      eyebrow={eyebrowMap[step]}
      title={titleMap[step]}
      subtitle={subtitleMap[step]}
      footer={
        step === "email" ? (
          <>
            Already cleared?{" "}
            <Link to="/login" className="auth-link" style={{ fontWeight: 700 }}>
              LOG IN →
            </Link>
          </>
        ) : null
      }
    >
      <div style={{ position: "relative", overflow: "hidden" }}>
        <AnimatePresence mode="wait" custom={direction} initial={false}>
          {step === "email" && (
            <motion.div
              key="email"
              custom={direction}
              variants={stepVariants}
              initial="enter"
              animate="center"
              exit="exit"
              transition={{ duration: 0.32, ease: [0.22, 0.61, 0.36, 1] }}
            >
              <div className="auth-social-wrap" style={{ marginBottom: 22, display: "grid", gap: 10 }}>
                <button type="button" className="auth-btn-outline auth-btn-apple" style={{ width: "100%", height: 50 }} onClick={() => handleSocialLogin("apple")}>
                  <AppleIcon className="w-5 h-5" /> Continue with Apple
                </button>
                <button type="button" className="auth-btn-outline" style={{ width: "100%", height: 50 }} onClick={() => handleSocialLogin("google")}>
                  <GoogleIcon className="w-5 h-5" /> Continue with Google
                </button>
              </div>

              <div className="auth-divider" style={{ position: "relative", marginBottom: 20, textAlign: "center" }}>
                <div style={{ position: "absolute", top: "50%", left: 0, right: 0, height: 1, background: "#1e1e1e" }} />
                <span style={{ position: "relative", background: "rgba(10,10,10,1)", padding: "0 14px", fontSize: 10, letterSpacing: 3, color: "#444", fontFamily: "monospace" }}>
                  OR WITH EMAIL
                </span>
              </div>

              <form onSubmit={handleEmailContinue} className="auth-form" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                <div>
                  <label htmlFor="email" className="auth-label">// EMAIL</label>
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
                <button type="submit" className="auth-btn-red" disabled={!email} style={{ marginTop: 8 }}>
                  CONTINUE <ArrowRight className="w-4 h-4" />
                </button>
              </form>
            </motion.div>
          )}

          {step === "password" && (
            <motion.div
              key="password"
              custom={direction}
              variants={stepVariants}
              initial="enter"
              animate="center"
              exit="exit"
              transition={{ duration: 0.32, ease: [0.22, 0.61, 0.36, 1] }}
            >
              <EmailChip onClick={backToEmail} />

              {error && (
                <div style={{ marginBottom: 16, padding: "10px 14px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", fontSize: 12, letterSpacing: 1, fontFamily: "monospace" }}>
                  ⚠ {error}
                </div>
              )}

              <form onSubmit={handleRegister} className="auth-form" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                <div>
                  <label htmlFor="password" className="auth-label">// PASSPHRASE</label>
                  <div style={{ position: "relative" }}>
                    <Lock style={{ position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)", width: 16, height: 16, color: "#444" }} aria-hidden="true" />
                    <input
                      id="password"
                      type="password"
                      autoComplete="new-password"
                      autoFocus
                      placeholder="••••••••"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
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
                <button type="submit" className="auth-btn-red" disabled={loading || !password || !confirmPassword} style={{ marginTop: 8 }}>
                  {loading ? <><Loader2 className="w-4 h-4 animate-spin" /> RECRUITING...</> : <>JOIN THE NETWORK <ArrowRight className="w-4 h-4" /></>}
                </button>
              </form>
            </motion.div>
          )}

          {step === "otp" && (
            <motion.div
              key="otp"
              custom={direction}
              variants={stepVariants}
              initial="enter"
              animate="center"
              exit="exit"
              transition={{ duration: 0.32, ease: [0.22, 0.61, 0.36, 1] }}
            >
              {error && (
                <div style={{ marginBottom: 16, padding: "10px 14px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", fontSize: 12, letterSpacing: 1, fontFamily: "monospace" }}>
                  ⚠ {error}
                </div>
              )}
              <div style={{ textAlign: "center", marginBottom: 8 }}>
                <span className="auth-label">// 6-DIGIT KEY</span>
              </div>
              <div style={{ display: "flex", justifyContent: "center", marginBottom: 24 }}>
                <InputOTP maxLength={6} value={otpCode} onChange={setOtpCode} autoFocus autoComplete="one-time-code">
                  <InputOTPGroup>
                    <InputOTPSlot index={0} />
                    <InputOTPSlot index={1} />
                    <InputOTPSlot index={2} />
                    <InputOTPSlot index={3} />
                    <InputOTPSlot index={4} />
                    <InputOTPSlot index={5} />
                  </InputOTPGroup>
                </InputOTP>
              </div>
              <button type="button" className="auth-btn-red" onClick={handleVerify} disabled={loading || otpCode.length < 6}>
                {loading ? <><Loader2 className="w-4 h-4 animate-spin" /> VERIFYING...</> : "VERIFY & ENTER"}
              </button>
              <p style={{ textAlign: "center", fontSize: 11, color: "#555", marginTop: 18, fontFamily: "monospace", letterSpacing: 1 }}>
                No transmission?{" "}
                <button type="button" onClick={handleResend} className="auth-link" style={{ background: "none", border: "none", cursor: "pointer", padding: 0, fontWeight: 700, fontSize: 11 }}>
                  RESEND
                </button>
              </p>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </AuthLayout>
  );
}

import React, { useState } from "react";
import { Link } from "react-router-dom";
import { base44 } from "@/api/base44Client";
import { LogIn, Mail, Lock, Loader2, ArrowRight, ArrowLeft, Pencil } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import AuthLayout from "@/components/AuthLayout";
import GoogleIcon from "@/components/GoogleIcon";
import AppleIcon from "@/components/AppleIcon";
import { appParams } from "@/lib/app-params";
import { buildSocialLoginUrl } from "@/lib/socialAuth";

export default function Login() {
  const prefilledEmail = React.useMemo(() => {
    try {
      return new URLSearchParams(window.location.search).get("email") || "";
    } catch { return ""; }
  }, []);
  const [step, setStep] = useState(prefilledEmail ? "password" : "email");
  const [email, setEmail] = useState(prefilledEmail);
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleEmailContinue = (e) => {
    e.preventDefault();
    setError("");
    if (!email) return;
    setStep("password");
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    setLoading(true);
    try {
      await base44.auth.loginViaEmailPassword(email, password);
      window.location.replace("/home");
    } catch (err) {
      setError(err.message || "Invalid email or password");
      setLoading(false);
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
  const goBack = () => {
    setStep("email");
    setPassword("");
    setError("");
  };

  const stepVariants = {
    enter: (dir) => ({ x: dir > 0 ? 40 : -40, opacity: 0 }),
    center: { x: 0, opacity: 1 },
    exit: (dir) => ({ x: dir > 0 ? -40 : 40, opacity: 0 }),
  };
  const direction = step === "email" ? -1 : 1;

  return (
    <AuthLayout
      icon={LogIn}
      eyebrow={step === "email" ? "ACCESS TERMINAL" : "PASSPHRASE REQUIRED"}
      title="Welcome Back"
      subtitle={step === "email" ? "Authenticate to continue the mission" : "One final step"}
      footer={
        <>
          No clearance yet?{" "}
          <Link to="/register" className="auth-link" style={{ fontWeight: 700 }}>
            REQUEST ACCESS →
          </Link>
        </>
      }
    >
      <div style={{ position: "relative", overflow: "hidden" }}>
        <AnimatePresence mode="wait" custom={direction} initial={false}>
          {step === "email" ? (
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
          ) : (
            <motion.div
              key="password"
              custom={direction}
              variants={stepVariants}
              initial="enter"
              animate="center"
              exit="exit"
              transition={{ duration: 0.32, ease: [0.22, 0.61, 0.36, 1] }}
            >
              {/* Email chip */}
              <button
                type="button"
                onClick={goBack}
                style={{
                  width: "100%",
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  padding: "10px 14px",
                  marginBottom: 18,
                  background: "rgba(229,53,53,0.06)",
                  border: "1px solid rgba(229,53,53,0.25)",
                  color: "#ccc",
                  fontFamily: "'Share Tech Mono', monospace",
                  fontSize: 12,
                  letterSpacing: 1,
                  cursor: "pointer",
                  borderRadius: 2,
                  transition: "all 0.2s",
                }}
                onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(229,53,53,0.12)"; e.currentTarget.style.borderColor = "#e53535"; }}
                onMouseLeave={(e) => { e.currentTarget.style.background = "rgba(229,53,53,0.06)"; e.currentTarget.style.borderColor = "rgba(229,53,53,0.25)"; }}
              >
                <ArrowLeft style={{ width: 14, height: 14, color: "#e53535" }} />
                <Mail style={{ width: 14, height: 14, color: "#666" }} />
                <span style={{ flex: 1, textAlign: "left", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{email}</span>
                <Pencil style={{ width: 12, height: 12, color: "#666" }} />
              </button>

              {error && (
                <div style={{ marginBottom: 16, padding: "10px 14px", background: "rgba(229,53,53,0.08)", border: "1px solid rgba(229,53,53,0.3)", color: "#e53535", fontSize: 12, letterSpacing: 1, fontFamily: "monospace" }}>
                  ⚠ {error}
                </div>
              )}

              <form onSubmit={handleSubmit} className="auth-form" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                <div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <label htmlFor="password" className="auth-label">// PASSPHRASE</label>
                    <Link to="/forgot-password" className="auth-link" style={{ fontSize: 10, letterSpacing: 2, marginBottom: 8 }}>
                      FORGOT?
                    </Link>
                  </div>
                  <div style={{ position: "relative" }}>
                    <Lock style={{ position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)", width: 16, height: 16, color: "#444" }} aria-hidden="true" />
                    <input
                      id="password"
                      type="password"
                      autoComplete="current-password"
                      autoFocus
                      placeholder="••••••••"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      className="auth-input"
                      required
                    />
                  </div>
                </div>
                <button type="submit" className="auth-btn-red" disabled={loading || !password} style={{ marginTop: 8 }}>
                  {loading ? <><Loader2 className="w-4 h-4 animate-spin" /> AUTHENTICATING...</> : <>INITIATE ENTRY <ArrowRight className="w-4 h-4" /></>}
                </button>
              </form>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </AuthLayout>
  );
}

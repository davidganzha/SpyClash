import React from "react";
import LanguageSwitcher from "@/components/LanguageSwitcher";

export default function AuthLayout({ icon: Icon, title, subtitle, footer = null, children, eyebrow = null }) {
  return (
    <div className="auth-wrapper" style={{
      minHeight: "100vh",
      background: "#000",
      color: "#fff",
      fontFamily: "'Share Tech Mono', 'Courier New', monospace",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      position: "relative",
      overflow: "hidden",
    }}>
      <LanguageSwitcher style={{ position: "absolute", top: 16, right: 16, zIndex: 3 }} />
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Rajdhani:wght@500;600;700&display=swap');

        .auth-wrapper { padding: 32px 16px; }
        .auth-eyebrow { text-align: center; margin-bottom: 14px; font-size: 10px; letter-spacing: 4px; color: #555; font-family: monospace; }
        .auth-header { text-align: center; margin-bottom: 28px; }
        .auth-icon-wrap {
          display: inline-flex; align-items: center; justify-content: center;
          width: 56px; height: 56px; background: #e53535; margin-bottom: 18px;
          clip-path: polygon(0 0, calc(100% - 10px) 0, 100% 10px, 100% 100%, 10px 100%, 0 calc(100% - 10px));
          box-shadow: 0 0 24px rgba(229,53,53,0.35);
        }
        .auth-icon-wrap svg { width: 28px; height: 28px; color: #fff; }
        .auth-title-text {
          font-family: 'Rajdhani', sans-serif; font-weight: 700; font-size: 32px; letter-spacing: 4px;
          color: #fff; text-transform: uppercase; line-height: 1.1; margin: 0;
        }
        .auth-subtitle-text { margin-top: 10px; font-size: 12px; letter-spacing: 1.5px; color: #888; font-family: monospace; }
        .auth-card {
          position: relative;
          background: rgba(10,10,10,0.85);
          border: 1px solid #1e1e1e;
          padding: 32px 28px;
          backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
        }
        .auth-footer-text { text-align: center; margin-top: 24px; font-size: 11px; letter-spacing: 1.5px; color: #666; font-family: monospace; }

        .auth-input {
          background: #0a0a0a !important;
          border: 1px solid #2a2a2a !important;
          color: #fff !important;
          border-radius: 2px;
          padding: 14px 14px 14px 42px;
          font-size: 14px;
          font-family: 'Share Tech Mono', monospace;
          letter-spacing: 1px;
          outline: none;
          width: 100%;
          height: 50px;
          transition: border-color 0.2s, box-shadow 0.2s;
        }
        .auth-input:focus {
          border-color: #e53535 !important;
          box-shadow: 0 0 0 1px rgba(229,53,53,0.25);
        }
        .auth-input::placeholder { color: #3a3a3a; }

        .auth-btn-red {
          background: #e53535;
          color: #fff;
          border: none;
          padding: 14px 24px;
          font-weight: 700;
          cursor: pointer;
          font-size: 12px;
          letter-spacing: 3px;
          font-family: 'Share Tech Mono', monospace;
          text-transform: uppercase;
          transition: all 0.2s;
          clip-path: polygon(0 0, calc(100% - 8px) 0, 100% 8px, 100% 100%, 8px 100%, 0 calc(100% - 8px));
          width: 100%;
          height: 50px;
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 8px;
        }
        .auth-btn-red:hover:not(:disabled) {
          background: #cc2020;
          box-shadow: 0 0 24px rgba(229,53,53,0.45);
        }
        .auth-btn-red:disabled { opacity: 0.4; cursor: not-allowed; }

        .auth-btn-outline {
          background: transparent;
          color: #ccc;
          border: 1px solid #2a2a2a;
          padding: 14px 24px;
          font-weight: 600;
          cursor: pointer;
          font-size: 12px;
          letter-spacing: 2px;
          font-family: 'Share Tech Mono', monospace;
          text-transform: uppercase;
          transition: all 0.2s;
          width: 100%;
          height: 50px;
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 10px;
          border-radius: 2px;
        }
        .auth-btn-outline:hover:not(:disabled) {
          border-color: #e53535;
          color: #fff;
          background: rgba(229,53,53,0.05);
        }
        .auth-btn-outline:disabled { opacity: 0.4; cursor: not-allowed; }

        .auth-btn-apple {
          background: #fff;
          border-color: #fff;
          border-radius: 6px;
          color: #000;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          font-size: 15px;
          font-weight: 600;
          letter-spacing: 0;
          text-transform: none;
        }
        .auth-btn-apple:hover:not(:disabled) {
          animation: none;
          background: #f2f2f2;
          border-color: #fff;
          color: #000;
        }

        .auth-label {
          font-size: 10px;
          letter-spacing: 3px;
          color: #666;
          text-transform: uppercase;
          font-family: 'Share Tech Mono', monospace;
          margin-bottom: 8px;
          display: block;
          font-weight: 700;
        }

        .auth-link {
          color: #e53535;
          text-decoration: none;
          letter-spacing: 1px;
          font-family: 'Share Tech Mono', monospace;
          transition: opacity 0.2s;
        }
        .auth-link:hover { opacity: 0.75; text-shadow: 0 0 8px rgba(229,53,53,0.5); }

        @keyframes auth-pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }

        /* Staggered entrance animations */
        @keyframes auth-fade-up {
          from { opacity: 0; transform: translateY(8px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes auth-icon-pop {
          from { opacity: 0; transform: scale(0.7); }
          to { opacity: 1; transform: scale(1); }
        }
        .auth-anim { opacity: 0; animation: auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards; }
        .auth-anim-1 { animation-delay: 0.05s; }
        .auth-anim-2 { animation-delay: 0.10s; }
        .auth-anim-3 { animation-delay: 0.15s; }
        .auth-anim-4 { animation-delay: 0.20s; }
        .auth-anim-5 { animation-delay: 0.25s; }
        .auth-anim-6 { animation-delay: 0.30s; }
        .auth-anim-7 { animation-delay: 0.35s; }
        .auth-anim-8 { animation-delay: 0.40s; }
        .auth-anim-9 { animation-delay: 0.45s; }
        .auth-anim-10 { animation-delay: 0.50s; }
        .auth-anim-11 { animation-delay: 0.55s; }
        .auth-anim-12 { animation-delay: 0.60s; }
        .auth-anim-13 { animation-delay: 0.65s; }
        .auth-anim-14 { animation-delay: 0.70s; }
        .auth-anim-15 { animation-delay: 0.75s; }
        .auth-anim-16 { animation-delay: 0.80s; }
        .auth-icon-wrap {
          opacity: 0;
          animation:
            auth-icon-pop 0.5s cubic-bezier(0.34, 1.56, 0.64, 1) 0.10s forwards,
            auth-rock 4s ease-in-out 1s infinite;
        }
        .auth-social-grid > .auth-social-btn { opacity: 0; animation: auth-fade-up 0.4s cubic-bezier(0.22, 0.61, 0.36, 1) forwards; }
        .auth-social-grid > .auth-social-btn:nth-child(1) { animation-delay: 0.30s; }
        .auth-social-grid > .auth-social-btn:nth-child(2) { animation-delay: 0.36s; }
        .auth-social-grid > .auth-social-btn:nth-child(3) { animation-delay: 0.42s; }
        .auth-social-grid > .auth-social-btn:nth-child(4) { animation-delay: 0.48s; }

        /* Idle cyclic animations */
        @keyframes auth-rock {
          0%   { transform: rotate(0deg); }
          25%  { transform: rotate(-4deg); }
          75%  { transform: rotate(4deg); }
          100% { transform: rotate(0deg); }
        }
        @keyframes auth-corner-blink {
          0%, 100% { opacity: 1; }
          50%      { opacity: 0.25; }
        }
        @keyframes auth-drift {
          0%, 100% { transform: translateX(0); }
          50%      { transform: translateX(3px); }
        }
        @keyframes auth-title-glow {
          0%, 100% { text-shadow: 0 0 0 rgba(229,53,53,0); }
          50%      { text-shadow: 0 0 22px rgba(229,53,53,0.45); }
        }
        @keyframes auth-float {
          0%, 100% { transform: translateY(0); }
          50%      { transform: translateY(-3px); }
        }
        @keyframes auth-link-pulse {
          0%, 100% { opacity: 1; text-shadow: 0 0 0 rgba(229,53,53,0); }
          50%      { opacity: 0.85; text-shadow: 0 0 12px rgba(229,53,53,0.55); }
        }

        .auth-eyebrow.auth-anim {
          animation:
            auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards,
            auth-drift 6s ease-in-out infinite;
          animation-delay: 0.05s, 1.2s;
        }
        .auth-title-text.auth-anim {
          animation:
            auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards,
            auth-title-glow 4s ease-in-out infinite;
          animation-delay: 0.15s, 1.5s;
        }
        .auth-subtitle-text.auth-anim {
          animation:
            auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards,
            auth-float 5s ease-in-out infinite;
          animation-delay: 0.20s, 1.4s;
        }
        .auth-footer-text.auth-anim {
          animation:
            auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards,
            auth-drift 7s ease-in-out infinite;
          animation-delay: 0.80s, 2s;
        }
        .auth-link { animation: auth-link-pulse 3s ease-in-out infinite; }

        .auth-corner { animation: auth-corner-blink 3s ease-in-out infinite; }
        .auth-corner-tl { animation-delay: 0s; }
        .auth-corner-tr { animation-delay: 0.75s; }
        .auth-corner-br { animation-delay: 1.5s; }
        .auth-corner-bl { animation-delay: 2.25s; }

        /* Glow pulse effects */
        @keyframes auth-btn-glow {
          0%, 100% { box-shadow: 0 0 20px rgba(229,53,53,0.3), inset 0 0 20px rgba(229,53,53,0.1); }
          50% { box-shadow: 0 0 40px rgba(229,53,53,0.6), inset 0 0 30px rgba(229,53,53,0.2); }
        }
        @keyframes auth-input-glow {
          0%, 100% { box-shadow: 0 0 0 1px rgba(229,53,53,0.2); }
          50% { box-shadow: 0 0 12px rgba(229,53,53,0.35), 0 0 0 1px rgba(229,53,53,0.4); }
        }
        @keyframes auth-social-glow {
          0%, 100% { box-shadow: 0 0 0 1px rgba(229,53,53,0), 0 0 0 rgba(229,53,53,0); }
          50% { box-shadow: 0 0 15px rgba(229,53,53,0.35), 0 0 0 1px rgba(229,53,53,0.3); }
        }

        .auth-btn-red {
          animation: auth-btn-glow 3s ease-in-out infinite;
        }
        .auth-btn-red.auth-anim {
          animation:
            auth-fade-up 0.45s cubic-bezier(0.22, 0.61, 0.36, 1) forwards,
            auth-btn-glow 3s ease-in-out infinite;
          animation-delay: 0.75s, 1.5s;
        }
        .auth-input:focus {
          animation: auth-input-glow 2.5s ease-in-out infinite;
        }
        .auth-btn-outline:hover {
          animation: auth-social-glow 2s ease-in-out infinite;
        }

        /* 2x2 social grid */
        .auth-social-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
        .auth-social-wrap { margin-bottom: 22px; }
        .auth-social-btn { padding: 10px 8px !important; font-size: 11px !important; letter-spacing: 1.5px !important; gap: 8px !important; height: 46px !important; }

        /* Hide page scrollbar on auth pages */
        html, body { scrollbar-width: none !important; -ms-overflow-style: none !important; }
        html::-webkit-scrollbar, body::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }

        /* ===== Mobile compact ===== */
        @media (max-width: 640px) {
          .auth-wrapper { padding: 12px 10px; align-items: flex-start; }
          .auth-eyebrow { margin-bottom: 6px; font-size: 9px; letter-spacing: 3px; }
          .auth-header { margin-bottom: 12px; }
          .auth-icon-wrap { width: 38px; height: 38px; margin-bottom: 8px; }
          .auth-icon-wrap svg { width: 18px; height: 18px; }
          .auth-title-text { font-size: 20px; letter-spacing: 3px; }
          .auth-subtitle-text { font-size: 10px; margin-top: 4px; }
          .auth-card { padding: 14px 12px; }
          .auth-footer-text { margin-top: 12px; font-size: 10px; }
          .auth-input { height: 42px; padding: 10px 10px 10px 36px; font-size: 13px; }
          .auth-btn-red, .auth-btn-outline { height: 44px; font-size: 11px; padding: 10px 16px; letter-spacing: 2px; }
          .auth-label { margin-bottom: 4px; font-size: 9px; letter-spacing: 2px; }
          .auth-social-grid { gap: 8px; }
          .auth-social-btn { height: 40px !important; font-size: 10px !important; padding: 8px 6px !important; gap: 6px !important; letter-spacing: 1px !important; }
          .auth-social-wrap { margin-bottom: 14px; }
          .auth-divider { margin-bottom: 12px !important; }
          .auth-form { gap: 10px !important; }
        }
      `}</style>

      {/* Background ambience */}
      <div style={{
        position: "absolute", inset: 0, zIndex: 0, pointerEvents: "none",
        background: "radial-gradient(ellipse at 20% 30%, rgba(229,53,53,0.07) 0%, transparent 55%), radial-gradient(ellipse at 80% 70%, rgba(100,100,200,0.04) 0%, transparent 55%)"
      }} />
      <div style={{
        position: "absolute", inset: 0, zIndex: 0, pointerEvents: "none",
        backgroundImage: "linear-gradient(rgba(229,53,53,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(229,53,53,0.04) 1px, transparent 1px)",
        backgroundSize: "40px 40px",
        maskImage: "radial-gradient(ellipse at center, black 30%, transparent 80%)",
        WebkitMaskImage: "radial-gradient(ellipse at center, black 30%, transparent 80%)",
      }} />

      <div style={{ width: "100%", maxWidth: 440, position: "relative", zIndex: 1 }}>
        {eyebrow && (
          <div className="auth-eyebrow auth-anim auth-anim-1">
            <span style={{ color: "#e53535" }}>//</span> {eyebrow}
          </div>
        )}

        <div className="auth-header">
          {Icon && (
            <div className="auth-icon-wrap">
              <Icon aria-hidden="true" />
            </div>
          )}
          <h1 className="auth-title-text auth-anim auth-anim-3">{title}</h1>
          {subtitle && <p className="auth-subtitle-text auth-anim auth-anim-4">{subtitle}</p>}
        </div>

        <div className="auth-card auth-anim auth-anim-5">
          <div className="auth-corner auth-corner-tl" style={{ position: "absolute", top: 0, left: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div className="auth-corner auth-corner-tr" style={{ position: "absolute", top: 0, right: 0, width: 14, height: 14, borderTop: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          <div className="auth-corner auth-corner-bl" style={{ position: "absolute", bottom: 0, left: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
          <div className="auth-corner auth-corner-br" style={{ position: "absolute", bottom: 0, right: 0, width: 14, height: 14, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
          {children}
        </div>

        {footer && <p className="auth-footer-text auth-anim auth-anim-16">{footer}</p>}
      </div>
    </div>
  );
}

import React from "react";
import { Link } from "react-router-dom";
import { motion } from "framer-motion";
import { LogIn, UserPlus } from "lucide-react";
import LanguageSwitcher from "@/components/LanguageSwitcher";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

const SPY_LETTERS = ["S", "P", "Y"];
const CLASH_LETTERS = ["C", "L", "A", "S", "H"];

export default function Welcome() {
  const { lang } = useLanguage();
  const tagline = localize(lang, "DECEPTION · DEDUCTION · DOMINATION", "ОБМАН · ДЕДУКЦИЯ · ДОМИНИРОВАНИЕ", "ОБМАН · ДЕДУКЦІЯ · ПЕРЕВАГА");

  return (
    <div style={{
      minHeight: "100vh",
      background: "#000",
      color: "#fff",
      fontFamily: "'Share Tech Mono', 'Courier New', monospace",
      display: "flex",
      flexDirection: "column",
      position: "relative",
      overflow: "hidden",
    }}>
      <LanguageSwitcher style={{ position: "absolute", top: 16, right: 16, zIndex: 4 }} />
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Rajdhani:wght@500;600;700&display=swap');

        @keyframes welcome-pulse { 0%,100%{opacity:1} 50%{opacity:0.2} }
        @keyframes welcome-scan { 0%{transform:translateY(-100%)} 100%{transform:translateY(100vh)} }
        @keyframes welcome-scan-h { 0%{transform:translateX(-100%)} 100%{transform:translateX(100vw)} }
        @keyframes welcome-grid-pulse { 0%,100%{opacity:0.55} 50%{opacity:0.95} }
        @keyframes welcome-ambient-drift {
          0%,100%{transform:translate(0,0) scale(1)}
          33%{transform:translate(2%,-1%) scale(1.05)}
          66%{transform:translate(-1.5%,2%) scale(0.97)}
        }
        @keyframes welcome-letter-jitter {
          0%,100%{transform:translateY(0) rotate(0)}
          50%{transform:translateY(-2px) rotate(-0.5deg)}
        }
        @keyframes welcome-letter-jitter-alt {
          0%,100%{transform:translateY(0) rotate(0)}
          50%{transform:translateY(2px) rotate(0.5deg)}
        }
        @keyframes welcome-glitch {
          0%,93%,100%{transform:translate(0,0);filter:none;opacity:1}
          94%{transform:translate(-2px,1px);filter:hue-rotate(20deg)}
          95%{transform:translate(2px,-1px);filter:hue-rotate(-20deg)}
          96%{transform:translate(-1px,2px);filter:none;opacity:0.8}
          97%{transform:translate(0,0)}
        }
        @keyframes welcome-glow-spy {
          0%,100%{text-shadow:0 0 0 rgba(229,53,53,0),0 0 14px rgba(229,53,53,0.4)}
          50%{text-shadow:0 0 22px rgba(229,53,53,0.85),0 0 40px rgba(229,53,53,0.35)}
        }
        @keyframes welcome-glow-white {
          0%,100%{text-shadow:0 0 0 rgba(255,255,255,0),0 0 8px rgba(255,255,255,0.15)}
          50%{text-shadow:0 0 14px rgba(255,255,255,0.6),0 0 28px rgba(255,255,255,0.2)}
        }
        @keyframes welcome-tagline-drift {
          0%,100%{letter-spacing:8px}
          50%{letter-spacing:10px}
        }
        @keyframes welcome-corner-blink { 0%,100%{opacity:1} 50%{opacity:0.35} }
        @keyframes welcome-status-flicker {
          0%,100%{opacity:1}
          92%{opacity:1}
          93%{opacity:0.3}
          94%{opacity:1}
          96%{opacity:0.5}
          97%{opacity:1}
        }
        @keyframes welcome-btn-shimmer {
          0%{transform:translateX(-100%)}
          60%,100%{transform:translateX(200%)}
        }
        @keyframes welcome-btn-glow {
          0%,100%{box-shadow:0 0 20px rgba(229,53,53,0.3)}
          50%{box-shadow:0 0 40px rgba(229,53,53,0.65),0 0 60px rgba(229,53,53,0.25)}
        }
        @keyframes welcome-btn-outline-glow {
          0%,100%{box-shadow:0 0 0 rgba(229,53,53,0)}
          50%{box-shadow:0 0 18px rgba(229,53,53,0.3),inset 0 0 12px rgba(229,53,53,0.08)}
        }
        @keyframes welcome-float {
          0%,100%{transform:translateY(0)}
          50%{transform:translateY(-4px)}
        }
        @keyframes welcome-dot-orb {
          0%,100%{box-shadow:0 0 12px rgba(229,53,53,0.8),0 0 0 rgba(229,53,53,0)}
          50%{box-shadow:0 0 22px rgba(229,53,53,1),0 0 40px rgba(229,53,53,0.5)}
        }
        @keyframes welcome-footer-link-drift {
          0%,100%{opacity:0.6}
          50%{opacity:1}
        }

        /* Mobile compact */
        @media (max-width: 640px) {
          .welcome-status { padding: 14px 42px !important; font-size: 9px !important; letter-spacing: 2px !important; gap: 10px !important; }
          .welcome-logo { gap: 4px !important; margin-bottom: 12px !important; }
          .welcome-spy, .welcome-clash { font-size: 52px !important; letter-spacing: 3px !important; }
          .welcome-dot { width: 9px !important; height: 9px !important; margin-left: 4px !important; }
          .welcome-tagline { font-size: 10px !important; letter-spacing: 3px !important; margin-bottom: 32px !important; }
          .welcome-hero { padding: 24px 16px !important; }
          .welcome-footer { padding: 16px 42px !important; gap: 18px !important; font-size: 9px !important; }
        }
        @media (max-width: 380px) {
          .welcome-spy, .welcome-clash { font-size: 42px !important; letter-spacing: 2px !important; }
          .welcome-tagline { font-size: 9px !important; letter-spacing: 2px !important; }
        }

        .welcome-btn-red {
          position:relative;overflow:hidden;
          background:#e53535;color:#fff;border:none;padding:18px 32px;font-weight:700;cursor:pointer;
          font-size:13px;letter-spacing:4px;font-family:'Share Tech Mono',monospace;text-transform:uppercase;
          transition:all 0.2s;clip-path:polygon(0 0,calc(100% - 10px) 0,100% 10px,100% 100%,10px 100%,0 calc(100% - 10px));
          display:flex;align-items:center;justify-content:center;gap:10px;text-decoration:none;
          animation:welcome-btn-glow 3s ease-in-out infinite;
        }
        .welcome-btn-red::after {
          content:'';position:absolute;top:0;left:0;width:40%;height:100%;
          background:linear-gradient(90deg,transparent,rgba(255,255,255,0.35),transparent);
          transform:translateX(-100%);
          animation:welcome-btn-shimmer 3.5s ease-in-out infinite;
          pointer-events:none;
        }
        .welcome-btn-red:hover { background:#cc2020; transform:translateY(-2px); }

        .welcome-btn-outline {
          position:relative;overflow:hidden;
          background:transparent;color:#e53535;border:1px solid #e53535;padding:18px 32px;font-weight:700;cursor:pointer;
          font-size:13px;letter-spacing:4px;font-family:'Share Tech Mono',monospace;text-transform:uppercase;
          transition:all 0.2s;display:flex;align-items:center;justify-content:center;gap:10px;text-decoration:none;
          animation:welcome-btn-outline-glow 3s ease-in-out infinite 0.5s;
        }
        .welcome-btn-outline::after {
          content:'';position:absolute;top:0;left:0;width:40%;height:100%;
          background:linear-gradient(90deg,transparent,rgba(229,53,53,0.2),transparent);
          transform:translateX(-100%);
          animation:welcome-btn-shimmer 3.5s ease-in-out infinite 0.7s;
          pointer-events:none;
        }
        .welcome-btn-outline:hover { background:rgba(229,53,53,0.1); }

        .welcome-letter { display:inline-block; will-change: transform, opacity; }
        .welcome-spy .welcome-letter { animation: welcome-letter-jitter 4s ease-in-out infinite; }
        .welcome-clash .welcome-letter { animation: welcome-letter-jitter-alt 4.5s ease-in-out infinite; }
        .welcome-spy { animation: welcome-glow-spy 3.5s ease-in-out infinite, welcome-glitch 7s steps(1) infinite; }
        .welcome-clash { animation: welcome-glow-white 4s ease-in-out infinite 0.5s; }

        .welcome-tagline { animation: welcome-tagline-drift 5s ease-in-out infinite, welcome-float 6s ease-in-out infinite; }
        .welcome-dot { animation: welcome-pulse 2s infinite, welcome-dot-orb 2.4s ease-in-out infinite; }

        .welcome-corner { animation: welcome-corner-blink 3s ease-in-out infinite; }
        .welcome-corner-1 { animation-delay: 0s; }
        .welcome-corner-2 { animation-delay: 0.6s; }
        .welcome-corner-3 { animation-delay: 1.2s; }
        .welcome-corner-4 { animation-delay: 1.8s; }

        .welcome-status-text { animation: welcome-status-flicker 7s ease-in-out infinite; }
        .welcome-grid { animation: welcome-grid-pulse 6s ease-in-out infinite; }
        .welcome-ambient { animation: welcome-ambient-drift 18s ease-in-out infinite; }
        .welcome-footer-link { animation: welcome-footer-link-drift 4s ease-in-out infinite; }
      `}</style>

      {/* Background ambience — slowly drifting */}
      <div className="welcome-ambient" style={{
        position: "absolute", inset: 0, zIndex: 0, pointerEvents: "none",
        background: "radial-gradient(ellipse at 30% 40%, rgba(229,53,53,0.09) 0%, transparent 55%), radial-gradient(ellipse at 70% 60%, rgba(100,100,200,0.05) 0%, transparent 55%)"
      }} />

      {/* Grid — pulsing */}
      <div className="welcome-grid" style={{
        position: "absolute", inset: 0, zIndex: 0, pointerEvents: "none",
        backgroundImage: "linear-gradient(rgba(229,53,53,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(229,53,53,0.05) 1px, transparent 1px)",
        backgroundSize: "50px 50px",
        maskImage: "radial-gradient(ellipse at center, black 20%, transparent 75%)",
        WebkitMaskImage: "radial-gradient(ellipse at center, black 20%, transparent 75%)",
      }} />

      {/* Scanlines */}
      <div style={{ position: "absolute", inset: 0, zIndex: 0, pointerEvents: "none", overflow: "hidden" }}>
        <div style={{
          position: "absolute", left: 0, right: 0, height: 2,
          background: "linear-gradient(90deg, transparent, rgba(229,53,53,0.4), transparent)",
          animation: "welcome-scan 6s linear infinite",
        }} />
        <div style={{
          position: "absolute", top: 0, bottom: 0, width: 2,
          background: "linear-gradient(180deg, transparent, rgba(229,53,53,0.25), transparent)",
          animation: "welcome-scan-h 9s linear infinite 2s",
        }} />
      </div>

      {/* Corner brackets — animated draw-in + idle blink */}
      {[
        { pos: { top: 16, left: 16 }, borders: { borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }, cls: "welcome-corner-1", init: { scale: 0, x: -10, y: -10 } },
        { pos: { top: 16, right: 16 }, borders: { borderTop: "1px solid #e53535", borderRight: "1px solid #e53535" }, cls: "welcome-corner-2", init: { scale: 0, x: 10, y: -10 } },
        { pos: { bottom: 16, left: 16 }, borders: { borderBottom: "1px solid #e53535", borderLeft: "1px solid #e53535" }, cls: "welcome-corner-3", init: { scale: 0, x: -10, y: 10 } },
        { pos: { bottom: 16, right: 16 }, borders: { borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }, cls: "welcome-corner-4", init: { scale: 0, x: 10, y: 10 } },
      ].map((c, i) => (
        <motion.div
          key={i}
          initial={{ opacity: 0, ...c.init }}
          animate={{ opacity: 1, scale: 1, x: 0, y: 0 }}
          exit={{ opacity: 0, ...c.init, transition: { delay: i * 0.04, duration: 0.3, ease: [0.55, 0, 0.45, 1] } }}
          transition={{ delay: 0.15 + i * 0.12, duration: 0.55, ease: [0.34, 1.56, 0.64, 1] }}
          className={`welcome-corner ${c.cls}`}
          style={{ position: "absolute", width: 20, height: 20, zIndex: 2, ...c.pos, ...c.borders }}
        />
      ))}

      {/* Main hero */}
      <div className="welcome-hero" style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "40px 24px", position: "relative", zIndex: 1, textAlign: "center" }}>

        {/* Logo — letter by letter */}
        <motion.div
          className="welcome-logo"
          initial="hidden"
          animate="show"
          exit="exit"
          variants={{
            hidden: {},
            show: { transition: { staggerChildren: 0.08, delayChildren: 0.55 } },
            exit: { transition: { staggerChildren: 0.04, staggerDirection: -1 } },
          }}
          style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 16 }}
        >
          <span className="welcome-spy" style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 72, letterSpacing: 6, color: "#e53535", lineHeight: 1, display: "inline-flex" }}>
            {SPY_LETTERS.map((ch, i) => (
              <motion.span
                key={`spy-${i}`}
                className="welcome-letter"
                variants={{
                  hidden: { opacity: 0, y: -30, rotateX: -90 },
                  show: { opacity: 1, y: 0, rotateX: 0, transition: { duration: 0.5, ease: [0.34, 1.56, 0.64, 1] } },
                  exit: { opacity: 0, y: -30, rotateX: -90, transition: { duration: 0.3, ease: [0.55, 0, 0.45, 1] } },
                }}
                style={{ animationDelay: `${i * 0.2}s` }}
              >
                {ch}
              </motion.span>
            ))}
          </span>
          <span className="welcome-clash" style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 72, letterSpacing: 6, color: "#fff", lineHeight: 1, display: "inline-flex" }}>
            {CLASH_LETTERS.map((ch, i) => (
              <motion.span
                key={`clash-${i}`}
                className="welcome-letter"
                variants={{
                  hidden: { opacity: 0, y: 30, rotateX: 90 },
                  show: { opacity: 1, y: 0, rotateX: 0, transition: { duration: 0.5, ease: [0.34, 1.56, 0.64, 1] } },
                  exit: { opacity: 0, y: 30, rotateX: 90, transition: { duration: 0.3, ease: [0.55, 0, 0.45, 1] } },
                }}
                style={{ animationDelay: `${i * 0.18}s` }}
              >
                {ch}
              </motion.span>
            ))}
          </span>
          <motion.span
            className="welcome-dot"
            initial={{ opacity: 0, scale: 0 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0, transition: { duration: 0.25, ease: "easeIn" } }}
            transition={{ delay: 1.3, duration: 0.45, ease: [0.34, 1.56, 0.64, 1] }}
            style={{ width: 12, height: 12, background: "#e53535", marginLeft: 6, display: "inline-block" }}
          />
        </motion.div>

        {/* Tagline — staggered chars */}
        <motion.div
          className="welcome-tagline"
          initial="hidden"
          animate="show"
          exit="exit"
          variants={{
            hidden: {},
            show: { transition: { staggerChildren: 0.02, delayChildren: 1.5 } },
            exit: { transition: { staggerChildren: 0.008, staggerDirection: -1 } },
          }}
          style={{ fontSize: 12, letterSpacing: 8, color: "#888", fontFamily: "monospace", marginBottom: 48, display: "flex", flexWrap: "wrap", justifyContent: "center" }}
        >
          {tagline.split("").map((ch, i) => (
            <motion.span
              key={i}
              variants={{
                hidden: { opacity: 0, y: 6 },
                show: { opacity: 1, y: 0, transition: { duration: 0.3 } },
                exit: { opacity: 0, y: -6, transition: { duration: 0.2 } },
              }}
              style={{ whiteSpace: "pre" }}
            >
              {ch}
            </motion.span>
          ))}
        </motion.div>

        {/* Buttons */}
        <motion.div
          initial="hidden"
          animate="show"
          exit="exit"
          variants={{
            hidden: {},
            show: { transition: { staggerChildren: 0.15, delayChildren: 2.3 } },
            exit: { transition: { staggerChildren: 0.06, staggerDirection: -1 } },
          }}
          style={{ display: "flex", flexDirection: "column", gap: 12, width: "100%", maxWidth: 360 }}
        >
          <motion.div
            variants={{
              hidden: { opacity: 0, x: -40 },
              show: { opacity: 1, x: 0, transition: { duration: 0.5, ease: [0.22, 0.61, 0.36, 1] } },
              exit: { opacity: 0, x: -40, transition: { duration: 0.3, ease: "easeIn" } },
            }}
            whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
          >
            <Link to="/login" className="welcome-btn-red">
              <LogIn size={16} /> {localize(lang, "ENTER THE GAME", "ВОЙТИ В ИГРУ", "УВІЙТИ ДО ГРИ")}
            </Link>
          </motion.div>
          <motion.div
            variants={{
              hidden: { opacity: 0, x: 40 },
              show: { opacity: 1, x: 0, transition: { duration: 0.5, ease: [0.22, 0.61, 0.36, 1] } },
              exit: { opacity: 0, x: 40, transition: { duration: 0.3, ease: "easeIn" } },
            }}
            whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}
          >
            <Link to="/register" className="welcome-btn-outline">
              <UserPlus size={16} /> {localize(lang, "CREATE ACCOUNT", "СОЗДАТЬ АККАУНТ", "СТВОРИТИ ОБЛІКОВИЙ ЗАПИС")}
            </Link>
          </motion.div>
        </motion.div>
      </div>

      {/* Footer */}
      <motion.div
        className="welcome-footer"
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: 12, transition: { duration: 0.25, ease: "easeIn" } }}
        transition={{ delay: 2.7, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
        style={{ position: "relative", zIndex: 1, padding: "20px 48px", display: "flex", justifyContent: "center", gap: 28, fontSize: 10, letterSpacing: 2, color: "#333", fontFamily: "monospace" }}
      >
        <Link to="/support" className="welcome-footer-link" style={{ color: "#444", textDecoration: "none", transition: "color 0.2s" }}
          onMouseEnter={e => e.currentTarget.style.color = "#e53535"}
          onMouseLeave={e => e.currentTarget.style.color = "#444"}>
          {localize(lang, "SUPPORT", "ПОДДЕРЖКА", "ПІДТРИМКА")}
        </Link>
        <span style={{ color: "#222" }}>//</span>
        <Link to="/privacypolicy" className="welcome-footer-link" style={{ color: "#444", textDecoration: "none", transition: "color 0.2s" }}
          onMouseEnter={e => e.currentTarget.style.color = "#e53535"}
          onMouseLeave={e => e.currentTarget.style.color = "#444"}>
          {localize(lang, "PRIVACY", "КОНФИДЕНЦИАЛЬНОСТЬ", "КОНФІДЕНЦІЙНІСТЬ")}
        </Link>
        <span style={{ color: "#222" }}>//</span>
        <Link to="/termsofservice" className="welcome-footer-link" style={{ color: "#444", textDecoration: "none", transition: "color 0.2s", animationDelay: "1s" }}
          onMouseEnter={e => e.currentTarget.style.color = "#e53535"}
          onMouseLeave={e => e.currentTarget.style.color = "#444"}>
          {localize(lang, "TERMS", "УСЛОВИЯ", "УМОВИ")}
        </Link>
      </motion.div>
    </div>
  );
}

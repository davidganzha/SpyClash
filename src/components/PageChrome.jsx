import React from "react";
import { motion } from "framer-motion";

/**
 * Shared visual chrome for all main pages — ambient glow, grid, scanlines,
 * corner brackets, and an optional top status bar. Wrap a page's content with
 * <PageChrome eyebrow="// PROFILE" status="ACTIVE">...</PageChrome>.
 */
export default function PageChrome({ children, eyebrow = null, status = null }) {
  return (
    <div style={{ position: "relative", minHeight: "calc(100vh - 140px)" }}>
      <style>{`
        @keyframes pc-pulse { 0%,100%{opacity:1} 50%{opacity:0.2} }
        @keyframes pc-scan { 0%{transform:translateY(-100%)} 100%{transform:translateY(100vh)} }
        @keyframes pc-scan-h { 0%{transform:translateX(-100%)} 100%{transform:translateX(100vw)} }
        @keyframes pc-grid-pulse { 0%,100%{opacity:0.5} 50%{opacity:0.9} }
        @keyframes pc-ambient-drift {
          0%,100%{transform:translate(0,0) scale(1)}
          33%{transform:translate(2%,-1%) scale(1.05)}
          66%{transform:translate(-1.5%,2%) scale(0.97)}
        }
        @keyframes pc-corner-blink { 0%,100%{opacity:1} 50%{opacity:0.4} }
        @keyframes pc-status-flicker {
          0%,100%{opacity:1} 92%{opacity:1} 93%{opacity:0.3} 94%{opacity:1} 96%{opacity:0.5} 97%{opacity:1}
        }
        .pc-grid { animation: pc-grid-pulse 6s ease-in-out infinite; }
        .pc-ambient { animation: pc-ambient-drift 18s ease-in-out infinite; }
        .pc-corner { animation: pc-corner-blink 3s ease-in-out infinite; }
        .pc-corner-1 { animation-delay: 0s; }
        .pc-corner-2 { animation-delay: 0.6s; }
        .pc-corner-3 { animation-delay: 1.2s; }
        .pc-corner-4 { animation-delay: 1.8s; }
        .pc-status-text { animation: pc-status-flicker 7s ease-in-out infinite; }
      `}</style>

      {/* All background effects clipped to this layer so they never affect page layout / scrolling */}
      <div style={{ position: "absolute", inset: 0, overflow: "hidden", pointerEvents: "none", zIndex: 0 }}>
        {/* Ambient glow — slow drift */}
        <div className="pc-ambient" style={{
          position: "absolute", inset: 0,
          background: "radial-gradient(ellipse at 30% 40%, rgba(229,53,53,0.07) 0%, transparent 55%), radial-gradient(ellipse at 70% 60%, rgba(100,100,200,0.04) 0%, transparent 55%)"
        }} />

        {/* Pulsing grid */}
        <div className="pc-grid" style={{
          position: "absolute", inset: 0,
          backgroundImage: "linear-gradient(rgba(229,53,53,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(229,53,53,0.04) 1px, transparent 1px)",
          backgroundSize: "50px 50px",
          maskImage: "radial-gradient(ellipse at center, black 20%, transparent 75%)",
          WebkitMaskImage: "radial-gradient(ellipse at center, black 20%, transparent 75%)",
        }} />

        {/* Scanlines */}
        <div style={{
          position: "absolute", left: 0, right: 0, height: 2,
          background: "linear-gradient(90deg, transparent, rgba(229,53,53,0.3), transparent)",
          animation: "pc-scan 8s linear infinite",
        }} />
        <div style={{
          position: "absolute", top: 0, bottom: 0, width: 2,
          background: "linear-gradient(180deg, transparent, rgba(229,53,53,0.18), transparent)",
          animation: "pc-scan-h 11s linear infinite 2s",
        }} />

        {/* Corner brackets */}
        {[
          { pos: { top: 12, left: 12 }, borders: { borderTop: "1px solid #e53535", borderLeft: "1px solid #e53535" }, cls: "pc-corner-1", init: { x: -10, y: -10 } },
          { pos: { top: 12, right: 12 }, borders: { borderTop: "1px solid #e53535", borderRight: "1px solid #e53535" }, cls: "pc-corner-2", init: { x: 10, y: -10 } },
          { pos: { bottom: 12, left: 12 }, borders: { borderBottom: "1px solid #e53535", borderLeft: "1px solid #e53535" }, cls: "pc-corner-3", init: { x: -10, y: 10 } },
          { pos: { bottom: 12, right: 12 }, borders: { borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }, cls: "pc-corner-4", init: { x: 10, y: 10 } },
        ].map((c, i) => (
          <motion.div
            key={i}
            initial={{ opacity: 0, scale: 0, ...c.init }}
            animate={{ opacity: 1, scale: 1, x: 0, y: 0 }}
            transition={{ delay: 0.15 + i * 0.1, duration: 0.5, ease: [0.34, 1.56, 0.64, 1] }}
            className={`pc-corner ${c.cls}`}
            style={{ position: "absolute", width: 18, height: 18, ...c.pos, ...c.borders }}
          />
        ))}
      </div>

      {/* Status bar */}
      {eyebrow && (
        <motion.div
          initial={{ opacity: 0, y: -10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.05, duration: 0.45, ease: [0.22, 0.61, 0.36, 1] }}
          style={{
            position: "relative", zIndex: 2, padding: "14px 24px 0",
            display: "flex", justifyContent: "center", alignItems: "center",
            fontSize: 9, letterSpacing: 3, color: "#444",
            fontFamily: "'Share Tech Mono', monospace", gap: 12
          }}
        >
          <span className="pc-status-text" style={{ display: "flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
            {eyebrow}
            {status !== null && (
              <span style={{ color: "#e53535", animation: "pc-pulse 2s infinite" }}>
                ●{status ? ` ${status}` : ""}
              </span>
            )}
          </span>
        </motion.div>
      )}

      {/* Content */}
      <div style={{ position: "relative", zIndex: 1 }}>
        {children}
      </div>
    </div>
  );
}

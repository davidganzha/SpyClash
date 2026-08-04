import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";

// Global toast queue
let _addToast = null;
const listeners = new Set();

export function gameToast(message, type = "info", icon = null) {
  const toast = { id: Date.now() + Math.random(), message, type, icon };
  listeners.forEach(fn => fn(toast));
}

const TYPE_STYLES = {
  info:    { border: "#2a2a2a", accent: "#555",    iconDefault: "ℹ" },
  success: { border: "#1a3a1a", accent: "#4ade80", iconDefault: "✓" },
  warning: { border: "#3a2a0a", accent: "#fbbf24", iconDefault: "⚠" },
  error:   { border: "#3a0a0a", accent: "#e53535", iconDefault: "✕" },
  spy:     { border: "rgba(229,53,53,0.4)", accent: "#e53535", iconDefault: "🕵️" },
  join:    { border: "#1a2a1a", accent: "#4ade80", iconDefault: "👤" },
  leave:   { border: "rgba(229,53,53,0.35)", accent: "#e53535", iconDefault: "👋" },
  vote:    { border: "#1a1a3a", accent: "#818cf8", iconDefault: "🗳️" },
  round:   { border: "rgba(229,53,53,0.35)", accent: "#e53535", iconDefault: "🎯" },
};

export default function GameToastContainer() {
  const [toasts, setToasts] = useState([]);

  useEffect(() => {
    const handler = (toast) => {
      setToasts(prev => [...prev.slice(-4), toast]); // max 5
      setTimeout(() => {
        setToasts(prev => prev.filter(t => t.id !== toast.id));
      }, 4000);
    };
    listeners.add(handler);
    return () => {
      listeners.delete(handler);
    };
  }, []);

  const dismiss = (id) => setToasts(prev => prev.filter(t => t.id !== id));

  return (
    <div style={{
      position: "fixed", bottom: 24, right: 20, zIndex: 9000,
      display: "flex", flexDirection: "column", gap: 8,
      pointerEvents: "none", maxWidth: 320, width: "calc(100vw - 40px)"
    }}>
      <AnimatePresence>
        {toasts.map(toast => {
          const style = TYPE_STYLES[toast.type] || TYPE_STYLES.info;
          const icon = toast.icon || style.iconDefault;
          return (
            <motion.div
              key={toast.id}
              initial={{ opacity: 0, x: 60, scale: 0.9 }}
              animate={{ opacity: 1, x: 0, scale: 1 }}
              exit={{ opacity: 0, x: 60, scale: 0.9 }}
              transition={{ type: "spring", stiffness: 300, damping: 28 }}
              onClick={() => dismiss(toast.id)}
              style={{
                pointerEvents: "all",
                display: "flex", alignItems: "flex-start", gap: 10,
                padding: "12px 14px",
                background: "#0d0d0d",
                border: `1px solid ${style.border}`,
                cursor: "pointer",
                position: "relative",
                overflow: "hidden",
              }}
            >
              {/* Left accent bar */}
              <div style={{
                position: "absolute", left: 0, top: 0, bottom: 0, width: 3,
                background: style.accent
              }} />

              <span style={{ fontSize: 16, flexShrink: 0, marginLeft: 4 }}>{icon}</span>
              <span style={{
                fontFamily: "'Share Tech Mono', monospace",
                fontSize: 11, letterSpacing: 0.5, color: style.type === 'leave' ? '#e53535' : "#aaa",
                lineHeight: 1.5, flex: 1
              }}>
                {toast.message}
              </span>
            </motion.div>
          );
        })}
      </AnimatePresence>
    </div>
  );
}

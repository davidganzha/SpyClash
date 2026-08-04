import { useEffect, useRef, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#@!%&";
const WORD = "SPY";
const WORD2 = "CLASH";

function GlitchLetter({ char, delay, finalColor = "#fff" }) {
  const [displayed, setDisplayed] = useState(" ");
  const [done, setDone] = useState(false);
  const frameRef = useRef(null);

  useEffect(() => {
    let frame = 0;
    const total = 14;
    const timeout = setTimeout(() => {
      const run = () => {
        frame++;
        if (frame >= total) {
          setDisplayed(char);
          setDone(true);
          return;
        }
        setDisplayed(CHARS[Math.floor(Math.random() * CHARS.length)]);
        frameRef.current = requestAnimationFrame(run);
      };
      frameRef.current = requestAnimationFrame(run);
    }, delay);
    return () => {
      clearTimeout(timeout);
      if (frameRef.current) cancelAnimationFrame(frameRef.current);
    };
  }, [char, delay]);

  return (
    <span style={{
      color: done ? finalColor : "#e53535",
      transition: "color 0.15s",
      fontFamily: "'Rajdhani', sans-serif",
      fontWeight: 700,
      letterSpacing: "0.1em"
    }}>
      {displayed}
    </span>
  );
}

const IMG_URL = "https://qtrypzzcjebvfcihiynt.supabase.co/storage/v1/object/public/base44-prod/public/69a0e57fa939f578082f8091/44f7c6582_3.png";
const SIZE = 160;

export default function AppLoader({ onDone }) {
  const [visible, setVisible] = useState(true);

  // After fill animation completes, fade out
  useEffect(() => {
    const t = setTimeout(() => {
      setVisible(false);
      setTimeout(onDone, 300);
    }, 1500);
    return () => clearTimeout(t);
  }, []);

  return (
    <AnimatePresence>
      {visible && (
        <motion.div
          key="loader"
          initial={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.5 }}
          style={{
            position: "fixed", inset: 0, zIndex: 9999,
            background: "#000",
            display: "flex", flexDirection: "column",
            alignItems: "center", justifyContent: "center",
          }}
        >
          {/* Logo with fill effect */}
          <motion.div
            initial={{ opacity: 0, scale: 0.85 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
            style={{ marginBottom: 36, position: "relative", width: SIZE, height: SIZE }}
          >
            {/* Base: original black/white image */}
            <img
              src={IMG_URL}
              alt="SpyClash"
              style={{
                width: SIZE, height: SIZE,
                borderRadius: "50%",
                display: "block",
                position: "absolute", top: 0, left: 0
              }}
            />

            {/* Red overlay revealed from bottom to top, blends with white parts only */}
            <motion.div
              initial={{ clipPath: `inset(${SIZE}px 0 0 0 round 50%)` }}
              animate={{ clipPath: `inset(0px 0 0 0 round 50%)` }}
              transition={{ duration: 1.8, delay: 0.4, ease: "easeInOut" }}
              style={{
                position: "absolute", top: 0, left: 0,
                width: SIZE, height: SIZE,
                borderRadius: "50%",
                background: "#e53535",
                mixBlendMode: "multiply",
              }}
            />

            {/* Glow that appears as fill completes */}
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: [0, 0, 0.6, 0.3] }}
              transition={{ duration: 2.2, delay: 0.4, ease: "easeInOut" }}
              style={{
                position: "absolute", inset: -10,
                borderRadius: "50%",
                boxShadow: "0 0 40px 12px rgba(229,53,53,0.5)",
                pointerEvents: "none"
              }}
            />
          </motion.div>

          {/* Title */}
          <motion.div
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.3, duration: 0.5 }}
            style={{ fontSize: 42, letterSpacing: 10, marginBottom: 8, display: "flex" }}
          >
            {WORD.split("").map((c, i) => (
              <GlitchLetter key={i} char={c} delay={300 + i * 80} />
            ))}
            {WORD2.split("").map((c, i) => (
              <GlitchLetter key={"c" + i} char={c} delay={300 + (WORD.length + i) * 80} finalColor="#e53535" />
            ))}
          </motion.div>

          {/* Subtitle */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 1.2 }}
            style={{ fontSize: 10, letterSpacing: 5, color: "#333", fontFamily: "monospace" }}
          >
            INITIALIZING SECURE CHANNEL
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
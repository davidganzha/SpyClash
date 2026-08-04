import Lottie from "lottie-react";
import { motion, useTransform } from "framer-motion";
import arrowDownAnimation from "@/assets/arrow-down.json";

// progress: MotionValue<number> (0 = closed, 1 = fully open) — обновления идут мимо React
function LineFill({ progress, threshold }) {
  const width = useTransform(progress, p => `${Math.min(1, Math.max(0, (p - threshold) / 0.34)) * 100}%`);
  return (
    <div style={{
      width: "100%",
      height: 2,
      background: "#2a2a2a",
      borderRadius: 1,
      position: "relative",
      overflow: "hidden",
    }}>
      <motion.div style={{
        position: "absolute",
        left: 0,
        top: 0,
        height: "100%",
        width,
        background: "#e53535",
        borderRadius: 1,
        willChange: "width",
      }} />
    </div>
  );
}

export default function MenuToggleButton({ isOpen, progress, onClick, onMouseDown }) {
  const arrowOpacity = useTransform(progress, p => (p < 0.1 ? 1 - p / 0.1 : 0));
  const linesOpacity = useTransform(progress, p => (p > 0.05 ? Math.min(1, (p - 0.05) / 0.05) : 0));

  return (
    <div
      style={{
        border: "none",
        borderRadius: 2,
        cursor: "default",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        width: 44,
        height: 40,
        background: "transparent",
        position: "relative",
        padding: 0,
        pointerEvents: "none",
      }}
    >
      {/* Lottie arrow — pull down hint */}
      <motion.div style={{
        width: 28, height: 28, pointerEvents: "none",
        opacity: arrowOpacity,
        position: "absolute",
        willChange: "opacity",
      }}>
        <Lottie animationData={arrowDownAnimation} loop={true} />
      </motion.div>

      {/* Линии */}
      <motion.div style={{
        display: "flex", flexDirection: "column", gap: 5, width: 20, pointerEvents: "none",
        opacity: linesOpacity,
        willChange: "opacity",
      }}>
        {[0, 0.33, 0.66].map((threshold, i) => (
          <LineFill key={i} progress={progress} threshold={threshold} />
        ))}
      </motion.div>
    </div>
  );
}
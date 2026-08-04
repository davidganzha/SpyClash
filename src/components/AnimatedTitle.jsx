import React from "react";
import { motion } from "framer-motion";

/**
 * Letter-by-letter staggered title, identical motion to the Welcome page hero.
 */
export default function AnimatedTitle({
  text,
  delay = 0.2,
  color = "#fff",
  size = 36,
  letterSpacing = 4,
  style = {},
}) {
  return (
    <motion.div
      initial="hidden"
      animate="show"
      variants={{
        hidden: {},
        show: { transition: { staggerChildren: 0.04, delayChildren: delay } },
      }}
      style={{
        fontFamily: "'Rajdhani', sans-serif",
        fontWeight: 700,
        fontSize: size,
        letterSpacing,
        color,
        display: "inline-flex",
        flexWrap: "wrap",
        lineHeight: 1.05,
        ...style,
      }}
    >
      {text.split("").map((ch, i) => (
        <motion.span
          key={i}
          variants={{
            hidden: { opacity: 0, y: 20, rotateX: 90 },
            show: { opacity: 1, y: 0, rotateX: 0, transition: { duration: 0.45, ease: [0.34, 1.56, 0.64, 1] } },
          }}
          style={{ display: "inline-block", whiteSpace: "pre" }}
        >
          {ch}
        </motion.span>
      ))}
    </motion.div>
  );
}
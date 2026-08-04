import { useEffect, useRef } from "react";
import { gsap } from "gsap";
import { motion } from "framer-motion";

const LINES_DEFAULT = [
  { words: ["CAN", "YOU"], color: "#fff" },
  { words: ["FIND", "THE"], color: "#fff" },
  { words: ["SPY?"], color: "#e53535" },
];

const LINES_SELECT = [
  { words: ["SELECT"], color: "#fff" },
  { words: ["YOUR"], color: "#fff" },
  { words: ["MODE"], color: "#e53535" },
];

export default function HeroTitle({ view = "main" }) {
  const containerRef = useRef(null);
  const lines = (view === "play_mode" || view === "online_mode") ? LINES_SELECT : LINES_DEFAULT;

  useEffect(() => {
    if (!containerRef.current) return;
    const spans = containerRef.current.querySelectorAll(".hero-letter");

    gsap.fromTo(
      spans,
      {
        opacity: 0,
        filter: "blur(18px)",
        y: -16,
      },
      {
        opacity: 1,
        filter: "blur(0px)",
        y: 0,
        duration: 0.9,
        ease: "power3.out",
        stagger: 0.12, // ~3.5s total for ~30 chars
      }
    );
  }, []);

  return (
    <h1
      ref={containerRef}
      style={{
        fontFamily: "'Rajdhani', sans-serif",
        fontWeight: 700,
        fontSize: "clamp(52px, 9vw, 96px)",
        lineHeight: 0.95,
        letterSpacing: 4,
        marginBottom: 28,
      }}
    >
      {lines.map((line, li) => (
        <span key={li} style={{ display: "block" }}>
          {line.words.map((word, wi) => (
            <span key={wi} style={{ display: "inline-block" }}>
              {word.split("").map((char, ci) => (
                <span
                  key={ci}
                  className="hero-letter"
                  style={{
                    display: "inline-block",
                    color: line.color,
                    willChange: "filter, opacity, transform",
                  }}
                >
                  {char}
                </span>
              ))}
              {wi < line.words.length - 1 && (
                <span
                  className="hero-letter"
                  style={{ display: "inline-block", willChange: "filter, opacity, transform" }}
                >
                  &nbsp;
                </span>
              )}
            </span>
          ))}
          {li < lines.length - 1 && " "}
        </span>
      ))}
    </h1>
  );
}
import { useEffect, useRef } from "react";
import { motion, useReducedMotion } from "framer-motion";

import { DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS } from "@/lib/detectiveVoteCancellation";

const clampElapsed = (value) => Math.min(
  Math.max(Number(value) || 0, 0),
  DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS - 1,
);

export default function DetectiveVoteCancellationScene({ event, t }) {
  const overlayRef = useRef(null);
  const mountedAtRef = useRef(Date.now());
  const reduceMotion = useReducedMotion();
  const elapsedSeconds = clampElapsed(Math.max(
    Number(event?.elapsedMs) || 0,
    mountedAtRef.current - (Number(event?.presentAtMs) || mountedAtRef.current),
  )) / 1_000;
  const durationSeconds = DETECTIVE_VOTE_CANCELLATION_SCENE_DURATION_MS / 1_000;
  const sharedTransition = {
    duration: durationSeconds,
    delay: -elapsedSeconds,
    ease: "easeInOut",
  };

  useEffect(() => {
    overlayRef.current?.focus({ preventScroll: true });
  }, [event.id]);

  return (
    <motion.div
      ref={overlayRef}
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="detective-vote-cancellation-title"
      aria-describedby="detective-vote-cancellation-description"
      tabIndex={-1}
      initial={reduceMotion
        ? { opacity: 0 }
        : { opacity: 0, backdropFilter: "blur(0px)" }}
      animate={reduceMotion
        ? { opacity: [0, 1, 1, 0] }
        : {
            opacity: [0, 1, 1, 1, 0],
            backdropFilter: [
              "blur(0px)",
              "blur(5px)",
              "blur(5px)",
              "blur(7px)",
              "blur(0px)",
            ],
          }}
      transition={{
        ...sharedTransition,
        times: reduceMotion ? [0, 0.1, 0.82, 1] : [0, 0.11, 0.72, 0.84, 1],
      }}
      onKeyDown={(event) => {
        event.preventDefault();
        event.stopPropagation();
      }}
      onPointerDown={(event) => {
        event.preventDefault();
        event.stopPropagation();
      }}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 100000,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        minHeight: "100dvh",
        overflow: "hidden",
        padding: "clamp(24px, 6vw, 72px)",
        background: "radial-gradient(circle at 50% 44%, rgba(35, 8, 12, 0.96) 0%, rgba(5, 5, 7, 0.985) 48%, rgba(0, 0, 0, 0.995) 100%)",
        color: "#f5f1ed",
        cursor: "wait",
        touchAction: "none",
        isolation: "isolate",
      }}
    >
      <motion.div
        aria-hidden="true"
        initial={reduceMotion
          ? { opacity: 0 }
          : { opacity: 0, scale: 0.78 }}
        animate={reduceMotion
          ? { opacity: [0, 0.14, 0.14, 0] }
          : {
              opacity: [0, 0.2, 0.1, 0],
              scale: [0.78, 1, 1.08, 1.16],
            }}
        transition={{
          ...sharedTransition,
          times: [0, 0.2, 0.72, 1],
        }}
        style={{
          position: "absolute",
          width: "min(76vw, 760px)",
          aspectRatio: "1",
          borderRadius: "50%",
          border: "1px solid rgba(229, 53, 53, 0.28)",
          boxShadow: "0 0 140px rgba(229, 53, 53, 0.14), inset 0 0 110px rgba(229, 53, 53, 0.08)",
        }}
      />

      <motion.div
        initial={reduceMotion
          ? { opacity: 0 }
          : {
              opacity: 0,
              scale: 0.94,
              y: 14,
              filter: "blur(10px)",
            }}
        animate={reduceMotion
          ? { opacity: [0, 1, 1, 0] }
          : {
              opacity: [0, 0, 1, 1, 0],
              scale: [0.94, 0.94, 1, 1.008, 1.04],
              y: [14, 14, 0, 0, -10],
              filter: [
                "blur(10px)",
                "blur(10px)",
                "blur(0px)",
                "blur(0px)",
                "blur(11px)",
              ],
            }}
        transition={{
          ...sharedTransition,
          times: reduceMotion ? [0, 0.22, 0.74, 1] : [0, 0.08, 0.22, 0.74, 1],
        }}
        style={{
          position: "relative",
          width: "min(100%, 760px)",
          textAlign: "center",
        }}
      >
        <motion.div
          aria-hidden="true"
          initial={reduceMotion
            ? { opacity: 0 }
            : { opacity: 0, scaleX: 0.08 }}
          animate={reduceMotion
            ? { opacity: [0, 0.75, 0.75, 0] }
            : {
                opacity: [0, 0.82, 0.82, 0],
                scaleX: [0.08, 1, 1, 0.16],
              }}
          transition={{
            ...sharedTransition,
            times: [0, 0.25, 0.74, 1],
          }}
          style={{
            height: 1,
            margin: "0 auto clamp(25px, 5vw, 40px)",
            background: "linear-gradient(90deg, transparent, rgba(229, 53, 53, 0.92), transparent)",
            transformOrigin: "center",
          }}
        />

        <h1
          id="detective-vote-cancellation-title"
          style={{
            margin: 0,
            color: "#f6f1ed",
            fontFamily: "'Rajdhani', sans-serif",
            fontSize: "clamp(32px, 8vw, 68px)",
            fontWeight: 700,
            lineHeight: 0.98,
            letterSpacing: "clamp(2px, 0.8vw, 8px)",
            textWrap: "balance",
            textShadow: "0 0 40px rgba(229, 53, 53, 0.22)",
          }}
        >
          {t("game_vote_cancel_scene_title")}
        </h1>

        <p
          id="detective-vote-cancellation-description"
          style={{
            width: "min(100%, 620px)",
            margin: "clamp(20px, 4vw, 30px) auto 0",
            color: "rgba(245, 241, 237, 0.72)",
            fontFamily: "'Rajdhani', sans-serif",
            fontSize: "clamp(17px, 3.5vw, 23px)",
            fontWeight: 500,
            lineHeight: 1.42,
            letterSpacing: "0.02em",
            textWrap: "balance",
          }}
        >
          {t("game_vote_cancel_scene_body")}
        </p>

        <motion.p
          initial={reduceMotion
            ? { opacity: 0 }
            : { opacity: 0, y: 7 }}
          animate={reduceMotion
            ? { opacity: [0, 0, 0.72, 0.72, 0] }
            : {
                opacity: [0, 0, 0.76, 0.76, 0],
                y: [7, 7, 0, 0, -3],
              }}
          transition={{
            ...sharedTransition,
            times: [0, 0.26, 0.36, 0.74, 1],
          }}
          style={{
            margin: "clamp(28px, 6vw, 48px) 0 0",
            color: "#e53535",
            fontFamily: "monospace",
            fontSize: "clamp(9px, 2.3vw, 12px)",
            fontWeight: 700,
            lineHeight: 1.5,
            letterSpacing: "clamp(1.5px, 0.6vw, 4px)",
          }}
        >
          {t("game_vote_cancel_scene_footer")}
        </motion.p>
      </motion.div>
    </motion.div>
  );
}

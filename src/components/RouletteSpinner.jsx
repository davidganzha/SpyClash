import { useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ONLINE_GAME_INTRO_MILLISECONDS } from "@/lib/gameRoomSync";

const RED = "#e53535";
const GREEN = "#4ade80";

const COPY = {
  en: {
    gameStarting: "// THE GAME BEGINS",
    spy: "SPY",
    amongYou: "AMONG YOU",
    accessibility: "The game begins. Cards are dealt. The spy is among you.",
  },
  es: {
    gameStarting: "// EL JUEGO EMPIEZA",
    spy: "ESPÍA",
    amongYou: "ENTRE USTEDES",
    accessibility: "El juego comienza. Las cartas están repartidas. El espía está entre ustedes.",
  },
  ru: {
    gameStarting: "// ИГРА НАЧИНАЕТСЯ",
    spy: "ШПИОН",
    amongYou: "СРЕДИ ВАС",
    accessibility: "Игра начинается. Карты розданы. Шпион среди вас.",
  },
};

const clamp = (value, minimum = 0, maximum = 1) => Math.min(maximum, Math.max(minimum, value));
const segment = (progress, start, end) => clamp((progress - start) / Math.max(end - start, 0.001));
const easeOut = (value) => 1 - ((1 - clamp(value)) ** 3);
const spring = (value) => clamp(1 - Math.exp(-7 * clamp(value)) * Math.cos(9 * clamp(value)));
const mix = (from, to, progress) => from + (to - from) * progress;

function pulse(progress, center, width) {
  return clamp(1 - Math.abs(progress - center) / Math.max(width, 0.001));
}

function arcPoint(from, to, progress, lift) {
  return {
    x: mix(from.x, to.x, progress),
    y: mix(from.y, to.y, progress) - Math.sin(progress * Math.PI) * lift,
  };
}

function parsedStartedAt(value, fallback) {
  const parsed = Date.parse(String(value ?? "").trim());
  return Number.isFinite(parsed) ? parsed : fallback;
}

function playerColumnCount(count, width, height) {
  const shortLandscape = height < 480 && width > height;
  if (shortLandscape) {
    return Math.min(count, Math.max(3, Math.floor((width - 24) / 92)));
  }
  return Math.min(count, width < 360 ? 3 : 4);
}

function playerPosition(index, count, width, height) {
  if (count <= 0) return { x: width / 2, y: height * 0.26 };

  const shortLandscape = height < 480 && width > height;
  const columns = playerColumnCount(count, width, height);
  const row = Math.floor(index / columns);
  const rows = Math.ceil(count / columns);
  const column = index % columns;
  const rowCount = row === rows - 1 ? count - row * columns : columns;
  const horizontalInset = Math.min(50, Math.max(28, width * 0.09));
  const usableWidth = Math.max(width - horizontalInset * 2, 0);

  return {
    x: rowCount === 1 ? width / 2 : horizontalInset + usableWidth * column / (rowCount - 1),
    y: shortLandscape
      ? height * 0.32 + row * Math.min(82, height * 0.24)
      : height * 0.22 + row * Math.min(104, height * 0.135),
  };
}

function RoleCardBack({ deck = false }) {
  return (
    <div className={`online-intro-card${deck ? " online-intro-card--deck" : ""}`} aria-hidden="true">
      <div className="online-intro-card-grid" />
      <div className="online-intro-card-sigil">
        <span className="online-intro-card-eye">◆</span>
        <span className="online-intro-card-rule" />
        <span className="online-intro-card-name">SPYCLASH</span>
      </div>
      <span className="online-intro-card-corner online-intro-card-corner--top">01</span>
      <span className="online-intro-card-corner online-intro-card-corner--bottom">SC</span>
    </div>
  );
}

function LegacyRouletteSpinner({ players, targetEmail, onDone }) {
  const [currentIndex, setCurrentIndex] = useState(0);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (!players.length) {
      onDone?.();
      return undefined;
    }

    const targetIndex = Math.max(0, players.findIndex((player) => player.email === targetEmail));
    const spins = players.length * 3 + targetIndex;
    const timeouts = [];
    let count = 0;
    let delay = 80;

    const tick = () => {
      count += 1;
      setCurrentIndex((previous) => (previous + 1) % players.length);
      if (count >= spins) {
        setCurrentIndex(targetIndex);
        setDone(true);
        timeouts.push(window.setTimeout(() => onDone?.(), 1800));
        return;
      }
      if (count > spins - players.length) delay = Math.min(delay + 30, 350);
      timeouts.push(window.setTimeout(tick, delay));
    };

    timeouts.push(window.setTimeout(tick, delay));
    return () => timeouts.forEach((timeout) => window.clearTimeout(timeout));
  }, []);

  const current = players[currentIndex];

  return (
    <div style={{ textAlign: "center", padding: "32px 20px" }}>
      <div style={{ fontSize: 10, letterSpacing: 4, color: RED, marginBottom: 24 }}>// РУЛЕТКА ПЕРВОГО ХОДА</div>

      <motion.div
        key={currentIndex}
        initial={{ scale: 0.7, opacity: 0.4 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.08 }}
        style={{ fontSize: 64, marginBottom: 16 }}
      >
        {current?.avatar || "🕵️"}
      </motion.div>

      <motion.div
        key={`name-${currentIndex}`}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        style={{
          fontFamily: "'Rajdhani', sans-serif",
          fontWeight: 700,
          fontSize: 18,
          letterSpacing: 3,
          color: done ? RED : "#555",
          marginBottom: 12,
          transition: "color 0.3s",
        }}
      >
        {current?.name?.toUpperCase()}
      </motion.div>

      <AnimatePresence>
        {done && (
          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            style={{ fontSize: 11, color: GREEN, letterSpacing: 3, fontFamily: "monospace" }}
          >
            ✓ НАЧИНАЕТ ПЕРВЫМ
          </motion.div>
        )}
      </AnimatePresence>

      {!done && (
        <div style={{ display: "flex", justifyContent: "center", gap: 4, marginTop: 8 }}>
          {players.map((player, index) => (
            <div
              key={player.id || player.email || index}
              style={{
                width: 6,
                height: 6,
                background: index === currentIndex ? RED : "#1e1e1e",
                borderRadius: "50%",
                transition: "background 0.1s",
              }}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function OnlineGameIntroScene({ players, startedAt, language, onDone }) {
  const fallbackStartedAtRef = useRef(Date.now());
  const onDoneRef = useRef(onDone);
  const completionRef = useRef(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  const [progress, setProgress] = useState(0);
  const [viewport, setViewport] = useState(() => ({
    width: typeof window === "undefined" ? 390 : window.innerWidth,
    height: typeof window === "undefined" ? 844 : window.innerHeight,
  }));

  const startedAtMilliseconds = useMemo(
    () => parsedStartedAt(startedAt, fallbackStartedAtRef.current),
    [startedAt],
  );
  const copy = COPY[language] || COPY.en;

  useEffect(() => {
    onDoneRef.current = onDone;
  }, [onDone]);

  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updatePreference = () => setReduceMotion(query.matches);
    updatePreference();
    query.addEventListener?.("change", updatePreference);
    return () => query.removeEventListener?.("change", updatePreference);
  }, []);

  useEffect(() => {
    const updateViewport = () => {
      const visualViewport = window.visualViewport;
      setViewport({
        width: Math.max(1, visualViewport?.width || window.innerWidth || 1),
        height: Math.max(1, visualViewport?.height || window.innerHeight || 1),
      });
    };

    updateViewport();
    window.addEventListener("resize", updateViewport);
    window.visualViewport?.addEventListener("resize", updateViewport);
    return () => {
      window.removeEventListener("resize", updateViewport);
      window.visualViewport?.removeEventListener("resize", updateViewport);
    };
  }, []);

  useEffect(() => {
    if (reduceMotion) {
      setProgress(0.82);
      return undefined;
    }

    let frame = 0;
    const updateProgress = () => {
      const nextProgress = clamp(
        (Date.now() - startedAtMilliseconds) / ONLINE_GAME_INTRO_MILLISECONDS,
      );
      setProgress(nextProgress);
      if (nextProgress < 1) frame = window.requestAnimationFrame(updateProgress);
    };

    updateProgress();
    return () => window.cancelAnimationFrame(frame);
  }, [reduceMotion, startedAtMilliseconds]);

  useEffect(() => {
    completionRef.current = false;
    let retryInterval = null;
    const remaining = Math.max(
      0,
      startedAtMilliseconds + ONLINE_GAME_INTRO_MILLISECONDS - Date.now(),
    );
    const timeout = window.setTimeout(() => {
      if (completionRef.current) return;
      completionRef.current = true;
      onDoneRef.current?.();
      // This scene remains mounted only while the room is in `roulette`.
      // Repeating completion lets a participant recover from a transient
      // complete_game_start failure without replaying or freezing the intro.
      retryInterval = window.setInterval(() => onDoneRef.current?.(), 2000);
    }, remaining);

    return () => {
      window.clearTimeout(timeout);
      if (retryInterval) window.clearInterval(retryInterval);
    };
  }, [startedAtMilliseconds]);

  const warningProgress = segment(progress, 0.72, 0.84);
  const warningExit = segment(progress, 0.90, 0.96);
  const warningOpacity = warningProgress * (1 - warningExit);
  const dimmedOpacity = 1 - warningProgress * 0.88;
  const outro = segment(progress, 0.94, 1);
  const deckReveal = spring(segment(progress, 0.16, 0.34));
  const playerCount = players.length;
  const shortLandscape = viewport.height < 480 && viewport.width > viewport.height;
  const playerRows = Math.ceil(
    playerCount / Math.max(playerColumnCount(playerCount, viewport.width, viewport.height), 1),
  );
  const deckPoint = {
    x: viewport.width / 2,
    y: viewport.height * (shortLandscape ? (playerRows > 1 ? 0.86 : 0.72) : 0.65),
  };
  const intervals = Math.max(playerCount - 1, 1);
  const dealSpacing = Math.min(0.058, 0.22 / intervals);
  const compact = viewport.width < 370 || viewport.height < 650;

  return (
    <section
      className="online-intro-scene"
      role="img"
      aria-label={copy.accessibility}
      data-reduce-motion={reduceMotion ? "true" : "false"}
    >
      <style>{`
        .online-intro-scene {
          position: fixed;
          inset: 0;
          z-index: 1000;
          width: 100vw;
          height: 100dvh;
          overflow: hidden;
          isolation: isolate;
          background: #000;
          color: #fff;
          font-family: 'Share Tech Mono', 'Courier New', monospace;
          touch-action: none;
        }
        .online-intro-backdrop {
          position: absolute;
          inset: -10%;
          background:
            radial-gradient(circle at 50% 48%, rgba(229,53,53,.15), transparent 29%),
            radial-gradient(circle at 12% 22%, rgba(229,53,53,.08), transparent 20%),
            linear-gradient(180deg, #050505 0%, #000 50%, #050000 100%);
          transform: scale(1.04);
        }
        .online-intro-grid {
          position: absolute;
          inset: 0;
          opacity: .22;
          background-image:
            linear-gradient(rgba(229,53,53,.09) 1px, transparent 1px),
            linear-gradient(90deg, rgba(229,53,53,.09) 1px, transparent 1px);
          background-size: 42px 42px;
          mask-image: radial-gradient(circle at 50% 46%, #000 5%, transparent 72%);
        }
        .online-intro-scanline {
          position: absolute;
          inset: -40% 0 auto;
          height: 42%;
          opacity: .2;
          background: linear-gradient(180deg, transparent, rgba(229,53,53,.25), transparent);
          animation: online-intro-scan 3.2s linear infinite;
        }
        .online-intro-vignette {
          position: absolute;
          inset: 0;
          box-shadow: inset 0 0 110px 35px #000;
          pointer-events: none;
        }
        .online-intro-corner {
          position: absolute;
          width: 28px;
          height: 28px;
          border-color: rgba(229,53,53,.38);
          border-style: solid;
          pointer-events: none;
        }
        .online-intro-corner--tl { top: max(18px, env(safe-area-inset-top)); left: 18px; border-width: 1px 0 0 1px; }
        .online-intro-corner--tr { top: max(18px, env(safe-area-inset-top)); right: 18px; border-width: 1px 1px 0 0; }
        .online-intro-corner--bl { bottom: max(18px, env(safe-area-inset-bottom)); left: 18px; border-width: 0 0 1px 1px; }
        .online-intro-corner--br { bottom: max(18px, env(safe-area-inset-bottom)); right: 18px; border-width: 0 1px 1px 0; }
        .online-intro-wordmark {
          position: absolute;
          left: 50%;
          top: max(50px, calc(7.5% + env(safe-area-inset-top)));
          transform: translateX(-50%);
          text-align: center;
          white-space: nowrap;
        }
        .online-intro-brand {
          font: 700 clamp(20px, 5.7vw, 28px)/.9 'Rajdhani', sans-serif;
          letter-spacing: clamp(3px, 1.2vw, 6px);
        }
        .online-intro-brand span:first-child { color: ${RED}; }
        .online-intro-copy {
          margin-top: 9px;
          color: #555;
          font-size: clamp(8px, 2.2vw, 10px);
          font-weight: 700;
          letter-spacing: clamp(1.8px, .7vw, 3px);
        }
        .online-intro-operative {
          position: absolute;
          width: 92px;
          margin: -34px 0 0 -46px;
          text-align: center;
          pointer-events: none;
        }
        .online-intro-avatar-shell {
          position: relative;
          width: 52px;
          height: 52px;
          margin: 0 auto 7px;
          display: grid;
          place-items: center;
          background: #101010;
          border: 1px solid rgba(229,53,53,.46);
          clip-path: polygon(0 0, calc(100% - 9px) 0, 100% 9px, 100% 100%, 9px 100%, 0 calc(100% - 9px));
          font-size: 25px;
        }
        .online-intro-ready {
          position: absolute;
          right: -4px;
          bottom: -4px;
          width: 15px;
          height: 15px;
          display: grid;
          place-items: center;
          color: #000;
          background: ${GREEN};
          clip-path: polygon(0 0, calc(100% - 4px) 0, 100% 4px, 100% 100%, 4px 100%, 0 calc(100% - 4px));
          font-size: 8px;
          font-weight: 900;
        }
        .online-intro-operative-name {
          overflow: hidden;
          color: #fff;
          font: 700 11px/1 'Rajdhani', sans-serif;
          letter-spacing: .8px;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .online-intro-operative-rule {
          width: 10px;
          height: 1px;
          margin: 8px auto 0;
          background: rgba(229,53,53,.4);
        }
        .online-intro-card {
          position: relative;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: linear-gradient(145deg, #171717, #090909 52%, #130707);
          border: 1px solid rgba(229,53,53,.64);
          clip-path: polygon(0 0, calc(100% - 7px) 0, 100% 7px, 100% 100%, 7px 100%, 0 calc(100% - 7px));
          box-shadow: inset 0 0 18px rgba(229,53,53,.08);
        }
        .online-intro-card-grid {
          position: absolute;
          inset: 0;
          opacity: .4;
          background-image:
            repeating-linear-gradient(135deg, transparent 0 7px, rgba(229,53,53,.13) 7px 8px),
            radial-gradient(circle at center, rgba(229,53,53,.16), transparent 45%);
        }
        .online-intro-card-sigil {
          position: absolute;
          inset: 0;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
        }
        .online-intro-card-eye { color: ${RED}; font-size: 13px; text-shadow: 0 0 10px rgba(229,53,53,.8); }
        .online-intro-card-rule { width: 20px; height: 1px; margin: 5px 0; background: rgba(229,53,53,.55); }
        .online-intro-card-name { color: #777; font: 700 5px/1 'Rajdhani', sans-serif; letter-spacing: 1px; }
        .online-intro-card-corner { position: absolute; color: rgba(229,53,53,.54); font-size: 4px; letter-spacing: .5px; }
        .online-intro-card-corner--top { top: 5px; left: 6px; }
        .online-intro-card-corner--bottom { right: 6px; bottom: 5px; transform: rotate(180deg); }
        .online-intro-deck {
          position: absolute;
          width: 76px;
          height: 101px;
          margin: -50px 0 0 -38px;
          transform-origin: center bottom;
          pointer-events: none;
        }
        .online-intro-deck-card { position: absolute; inset: 0; }
        .online-intro-deal-card {
          position: absolute;
          width: clamp(34px, 10.8vw, 42px);
          aspect-ratio: .75;
          margin: -28px 0 0 -20px;
          pointer-events: none;
          will-change: transform, opacity;
        }
        .online-intro-pulse {
          position: absolute;
          width: 66px;
          height: 66px;
          margin: -33px 0 0 -33px;
          border: 1px solid rgba(229,53,53,.62);
          clip-path: polygon(0 0, calc(100% - 10px) 0, 100% 10px, 100% 100%, 10px 100%, 0 calc(100% - 10px));
          pointer-events: none;
        }
        .online-intro-warning-ring {
          position: absolute;
          left: 50%;
          top: 49%;
          width: 120px;
          height: 120px;
          margin: -60px 0 0 -60px;
          border: 1px solid ${RED};
          border-radius: 50%;
          box-shadow: 0 0 30px rgba(229,53,53,.26);
          pointer-events: none;
        }
        .online-intro-warning {
          position: absolute;
          left: 50%;
          top: 49%;
          width: min(90vw, 580px);
          transform: translate(-50%, -50%);
          text-align: center;
          font: 700 clamp(42px, 12.5vw, 76px)/.82 'Rajdhani', sans-serif;
          letter-spacing: clamp(2px, .8vw, 5px);
          text-shadow: 0 0 30px rgba(229,53,53,.32);
          pointer-events: none;
        }
        .online-intro-warning strong { display: block; color: ${RED}; font: inherit; }
        .online-intro-warning span { display: block; color: #fff; }
        .online-intro-outro { position: absolute; inset: 0; background: #000; pointer-events: none; }
        @keyframes online-intro-scan {
          from { transform: translateY(0); }
          to { transform: translateY(330%); }
        }
        @media (max-height: 620px) {
          .online-intro-wordmark { top: max(28px, calc(4% + env(safe-area-inset-top))); }
          .online-intro-copy { margin-top: 5px; }
          .online-intro-avatar-shell { width: 44px; height: 44px; font-size: 21px; }
          .online-intro-operative { margin-top: -29px; }
        }
        @media (max-height: 479px) and (orientation: landscape) {
          .online-intro-wordmark { top: max(12px, env(safe-area-inset-top)); }
          .online-intro-copy { display: none; }
          .online-intro-avatar-shell { width: 38px; height: 38px; font-size: 18px; }
          .online-intro-operative { width: 84px; margin: -24px 0 0 -42px; }
          .online-intro-operative-name { font-size: 10px; }
          .online-intro-operative-rule { margin-top: 6px; }
          .online-intro-deck { width: 60px; height: 80px; margin: -40px 0 0 -30px; }
          .online-intro-deal-card { width: 30px; margin: -20px 0 0 -15px; }
          .online-intro-warning { font-size: clamp(32px, 10vw, 56px); }
        }
        @media (prefers-reduced-motion: reduce) {
          .online-intro-scanline { animation: none; opacity: .08; }
          .online-intro-scene * { transition: none !important; }
        }
      `}</style>

      <div className="online-intro-backdrop" style={{ opacity: 0.72 + warningProgress * 0.28 }} />
      <div className="online-intro-grid" style={{ opacity: 0.22 * dimmedOpacity }} />
      <div className="online-intro-scanline" />
      <div className="online-intro-vignette" />
      <span className="online-intro-corner online-intro-corner--tl" />
      <span className="online-intro-corner online-intro-corner--tr" />
      <span className="online-intro-corner online-intro-corner--bl" />
      <span className="online-intro-corner online-intro-corner--br" />

      <div
        className="online-intro-wordmark"
        style={{
          opacity: segment(progress, 0, 0.14) * dimmedOpacity,
          filter: `blur(${warningProgress * 5}px)`,
          transform: `translate(-50%, ${-warningProgress * 10}px)`,
        }}
      >
        <div className="online-intro-brand"><span>SPY</span><span>CLASH</span></div>
        <div className="online-intro-copy">{copy.gameStarting}</div>
      </div>

      {players.map((player, index) => {
        const target = playerPosition(index, playerCount, viewport.width, viewport.height);
        const appearance = reduceMotion
          ? 1
          : easeOut(segment(progress, 0.11 + index * 0.018, 0.29 + index * 0.018));
        const dealStart = 0.29 + index * dealSpacing;
        const rawDeal = reduceMotion ? 1 : segment(progress, dealStart, dealStart + 0.24);
        const deal = reduceMotion ? 1 : spring(rawDeal);
        const cardTarget = { x: target.x, y: target.y + (compact ? 52 : 62) };
        const cardPoint = arcPoint(
          deckPoint,
          cardTarget,
          deal,
          56 + Math.abs(target.x - deckPoint.x) * 0.18,
        );
        const landingPulse = reduceMotion ? 0 : pulse(rawDeal, 0.88, 0.18);
        const ready = rawDeal > 0.82;
        const playerKey = player.id || player.email || `${player.name || "operative"}-${index}`;

        return (
          <div key={playerKey} aria-hidden="true">
            <div
              className="online-intro-operative"
              style={{
                left: target.x,
                top: target.y,
                opacity: appearance * dimmedOpacity,
                filter: `blur(${warningProgress * 3}px)`,
                transform: `scale(${0.82 + 0.18 * appearance + landingPulse * 0.035})`,
              }}
            >
              <div
                className="online-intro-avatar-shell"
                style={{
                  borderColor: ready ? "rgba(74,222,128,.74)" : "rgba(229,53,53,.46)",
                  filter: `saturate(${0.24 + deal * 0.76})`,
                  opacity: 0.46 + deal * 0.54,
                }}
              >
                {player.avatar || String(player.name || "?").slice(0, 1).toUpperCase()}
                {ready && <span className="online-intro-ready">✓</span>}
              </div>
              <div className="online-intro-operative-name">{String(player.name || "OPERATIVE").toUpperCase()}</div>
              <div
                className="online-intro-operative-rule"
                style={{ width: ready ? 24 : 10, background: ready ? "rgba(74,222,128,.72)" : "rgba(229,53,53,.24)" }}
              />
            </div>

            <div
              className="online-intro-pulse"
              style={{
                left: target.x,
                top: target.y + 12,
                opacity: landingPulse * dimmedOpacity,
                transform: `scale(${1 + landingPulse * 0.36})`,
              }}
            />

            <div
              className="online-intro-deal-card"
              style={{
                left: cardPoint.x,
                top: cardPoint.y,
                opacity: (rawDeal > 0 ? 1 : 0) * dimmedOpacity,
                transform: `rotate(${(index % 3 - 1) * 10 * (1 - rawDeal) + Math.sin(rawDeal * Math.PI) * 7}deg) scale(${0.78 + deal * 0.22})`,
                filter: `drop-shadow(0 12px ${10 + Math.sin(rawDeal * Math.PI) * 10}px rgba(229,53,53,.24))`,
              }}
            >
              <RoleCardBack />
            </div>
          </div>
        );
      })}

      <div
        className="online-intro-deck"
        aria-hidden="true"
        style={{
          left: deckPoint.x,
          top: deckPoint.y,
          opacity: deckReveal * (1 - segment(progress, 0.68, 0.78)) * dimmedOpacity,
          transform: `scale(${0.72 + 0.28 * deckReveal}) rotateX(${(1 - deckReveal) * 26}deg)`,
          filter: "drop-shadow(0 18px 22px rgba(229,53,53,.22))",
        }}
      >
        {[0, 1, 2, 3].map((index) => (
          <div
            className="online-intro-deck-card"
            key={index}
            style={{
              transform: `translate(${index * 2.4 - 4}px, ${index * -2.8 + 5}px) rotate(${index * 1.55 - 2.3}deg)`,
            }}
          >
            <RoleCardBack deck />
          </div>
        ))}
      </div>

      <div
        className="online-intro-warning-ring"
        style={{
          opacity: (1 - warningProgress) * warningProgress * 2.2,
          transform: `scale(${0.35 + warningProgress * 2.8})`,
        }}
      />
      <div
        className="online-intro-warning"
        style={{
          opacity: warningOpacity,
          filter: `blur(${(1 - warningProgress) * 14 + warningExit * 6}px)`,
          transform: `translate(-50%, -50%) scale(${0.72 + 0.28 * spring(warningProgress)})`,
        }}
      >
        <strong>{copy.spy}</strong>
        <span>{copy.amongYou}</span>
      </div>

      <div className="online-intro-outro" style={{ opacity: outro }} />
    </section>
  );
}

export default function RouletteSpinner({
  players = [],
  targetEmail = null,
  startedAt = null,
  language = "en",
  onDone,
}) {
  const hasSynchronizedStart = Number.isFinite(Date.parse(String(startedAt ?? "").trim()));

  if (!hasSynchronizedStart) {
    return <LegacyRouletteSpinner players={players} targetEmail={targetEmail} onDone={onDone} />;
  }

  return (
    <OnlineGameIntroScene
      players={players}
      startedAt={startedAt}
      language={language}
      onDone={onDone}
    />
  );
}

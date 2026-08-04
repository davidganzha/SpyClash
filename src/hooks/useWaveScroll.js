import { useEffect, useRef } from "react";

/**
 * Smoothly scrolls the page to follow the wave of revealing items.
 * Triggers only when the item count changes from 0 to >0 (i.e. fresh appearance).
 *
 * @param {number} count - number of items in the wave
 * @param {object} options - { delayPerItem (s), startDelay (s), containerRef }
 */
export function useWaveScroll(count, { delayPerItem = 0.08, startDelay = 0, containerRef } = {}) {
  const prevCount = useRef(0);

  useEffect(() => {
    const wasEmpty = prevCount.current === 0;
    prevCount.current = count;
    // Only trigger when going from empty → populated (fresh reveal)
    if (wasEmpty && count > 0 && containerRef?.current) {
      const el = containerRef.current;
      const totalMs = (startDelay + count * delayPerItem) * 1000;
      const startTime = performance.now();
      let rafId = null;
      let cancelled = false;

      const cancel = () => { cancelled = true; if (rafId) cancelAnimationFrame(rafId); };
      // Cancel on any user interaction
      window.addEventListener("wheel", cancel, { once: true, passive: true });
      window.addEventListener("touchstart", cancel, { once: true, passive: true });
      window.addEventListener("keydown", cancel, { once: true });

      // Capture starting scroll position once
      const initialScroll = window.scrollY;

      const tick = (now) => {
        if (cancelled) return;
        const elapsed = now - startTime;
        const progress = Math.min(1, elapsed / totalMs);

        const rect = el.getBoundingClientRect();
        const elBottom = rect.top + window.scrollY + rect.height;
        const viewportH = window.innerHeight;
        // Final target: bottom of grid ~120px above viewport bottom
        const finalTarget = Math.max(initialScroll, elBottom - viewportH + 120);
        const totalDistance = finalTarget - initialScroll;

        // Sync scroll exactly with the reveal wave (no lead) so it never overtakes the words
        const desiredScroll = initialScroll + totalDistance * progress;
        if (desiredScroll > window.scrollY) {
          window.scrollTo(0, desiredScroll);
        }

        if (progress < 1) {
          rafId = requestAnimationFrame(tick);
        }
      };

      rafId = requestAnimationFrame(tick);

      return () => {
        cancelled = true;
        if (rafId) cancelAnimationFrame(rafId);
        window.removeEventListener("wheel", cancel);
        window.removeEventListener("touchstart", cancel);
        window.removeEventListener("keydown", cancel);
      };
    }
  }, [count, delayPerItem, startDelay, containerRef]);
}
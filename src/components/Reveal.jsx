import useScrollReveal from "@/hooks/useScrollReveal";

/**
 * Wrap any block with <Reveal> to get a fade-up animation on scroll.
 * Props:
 *   delay  — CSS transition-delay in ms (default 0)
 *   y      — starting Y offset in px (default 24)
 *   className / style — forwarded to the wrapper div
 */
export default function Reveal({ children, delay = 0, y = 24, className = "", style = {} }) {
  const [ref, visible] = useScrollReveal();

  return (
    <div
      ref={ref}
      className={className}
      style={{
        transition: `opacity 0.55s ease ${delay}ms, transform 0.55s ease ${delay}ms`,
        opacity: visible ? 1 : 0,
        transform: visible ? "translateY(0)" : `translateY(${y}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  );
}
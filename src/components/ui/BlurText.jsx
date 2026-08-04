import { useEffect, useRef } from "react";
import { gsap } from "gsap";

export default function BlurText({ text = "", delay = 200, animateBy = "words", direction = "top", stepDuration = 0.55, style = {}, className = "", onAnimationComplete = undefined }) {
  const containerRef = useRef(null);

  const items = animateBy === "words" ? text.split(" ") : text.split("");

  useEffect(() => {
    if (!containerRef.current) return;
    const spans = containerRef.current.querySelectorAll(".blur-item");

    gsap.fromTo(
      spans,
      {
        opacity: 0,
        filter: "blur(12px)",
        y: direction === "top" ? -20 : 20,
      },
      {
        opacity: 1,
        filter: "blur(0px)",
        y: 0,
        duration: stepDuration,
        ease: "power3.out",
        stagger: delay / 1000,
        onComplete: onAnimationComplete,
      }
    );
  }, [text, delay, direction, stepDuration]);

  return (
    <span ref={containerRef} style={{ display: "inline", ...style }} className={className}>
      {items.map((item, i) => (
        <span
          key={i}
          className="blur-item"
          style={{ display: "inline-block", willChange: "filter, opacity, transform" }}
        >
          {item}
          {animateBy === "words" && i < items.length - 1 ? "\u00A0" : ""}
        </span>
      ))}
    </span>
  );
}

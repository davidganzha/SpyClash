import { useEffect, useRef, useState } from "react";

export default function useScrollReveal(options = {}) {
  const ref = useRef(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) { setVisible(true); observer.disconnect(); } },
      { threshold: options.threshold || 0.12, rootMargin: options.rootMargin || "0px" }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return /** @type {const} */ ([ref, visible]);
}

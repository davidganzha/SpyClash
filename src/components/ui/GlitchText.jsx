import { useState, useEffect } from "react";

const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%";

export default function GlitchText({ text, className = "", style = {}, speed = 40 }) {
  const [displayed, setDisplayed] = useState("");
  const [done, setDone] = useState(false);

  useEffect(() => {
    setDisplayed("");
    setDone(false);
    let i = 0;
    let scramble = 0;
    const interval = setInterval(() => {
      scramble++;
      if (scramble % 2 === 0) i = Math.min(i + 1, text.length);
      const revealed = text.slice(0, i);
      const scrambled = text.slice(i).split("").map(() => CHARS[Math.floor(Math.random() * CHARS.length)]).join("");
      setDisplayed(revealed + scrambled);
      if (i >= text.length) {
        clearInterval(interval);
        setDisplayed(text);
        setDone(true);
      }
    }, speed);
    return () => clearInterval(interval);
  }, [text]);

  return <span className={className} style={{ fontFamily: "monospace", ...style }}>{displayed || "\u00a0"}</span>;
}
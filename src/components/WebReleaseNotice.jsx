import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import {
  checkForWebRelease,
  reloadForWebRelease,
  WEB_RELEASE_CHECK_INTERVAL_MILLISECONDS,
} from "@/lib/webRelease";

function preferredLanguage() {
  try {
    return localStorage.getItem("spy_lang") === "ru" ? "ru" : "en";
  } catch {
    return "en";
  }
}

export default function WebReleaseNotice() {
  const [updateAvailable, setUpdateAvailable] = useState(false);

  useEffect(() => {
    let disposed = false;

    const check = async () => {
      if (disposed || document.visibilityState === "hidden") return;
      const changed = await checkForWebRelease();
      if (!disposed && changed) setUpdateAvailable(true);
    };
    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") void check();
    };

    void check();
    const interval = window.setInterval(
      () => void check(),
      WEB_RELEASE_CHECK_INTERVAL_MILLISECONDS,
    );
    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      disposed = true;
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, []);

  if (!updateAvailable) return null;

  const russian = preferredLanguage() === "ru";
  return (
    <div
      role="status"
      aria-live="assertive"
      data-testid="webRelease.updateNotice"
      style={{
        position: "fixed",
        zIndex: 2000,
        top: "calc(10px + env(safe-area-inset-top, 0px))",
        left: "50%",
        display: "flex",
        width: "min(calc(100% - 24px), 430px)",
        minHeight: 48,
        alignItems: "center",
        justifyContent: "space-between",
        gap: 12,
        padding: "8px 8px 8px 14px",
        transform: "translateX(-50%)",
        border: "1px solid rgba(229,53,53,0.78)",
        background: "#0a0a0a",
        boxShadow: "0 12px 36px rgba(0,0,0,0.72)",
        color: "#fff",
        fontFamily: "'Share Tech Mono', monospace",
      }}
    >
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.2 }}>
        {russian ? "// ДОСТУПНО ОБНОВЛЕНИЕ" : "// UPDATE AVAILABLE"}
      </span>
      <button
        type="button"
        onClick={() => reloadForWebRelease()}
        data-testid="webRelease.reload"
        style={{
          display: "inline-flex",
          minHeight: 32,
          flex: "0 0 auto",
          alignItems: "center",
          justifyContent: "center",
          gap: 7,
          padding: "7px 10px",
          border: 0,
          background: "#e53535",
          color: "#fff",
          cursor: "pointer",
          fontFamily: "inherit",
          fontSize: 9,
          fontWeight: 700,
          letterSpacing: 0.8,
        }}
      >
        <RefreshCw size={14} aria-hidden="true" />
        {russian ? "ОБНОВИТЬ" : "RELOAD"}
      </button>
    </div>
  );
}

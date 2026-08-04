import { useEffect, useRef, useState, useCallback } from "react";
import { CheckCircle, ArrowLeft } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import { base44 } from "@/api/base44Client";
import { joinGameRoom } from "@/lib/gameRoomActions";
import { roomCodeFromPayload } from "@/lib/roomLinks";
import { decodeQRCodeFrame, drawVideoCenterCrop } from "@/lib/qrFrameDecoder";
import { accountAvatarForDisplay } from "@/lib/avatars";

export default function QRScan() {
  const { t } = useLanguage();
  const navigate = useNavigate();
  const hasScannedRef = useRef(false);
  const scannerRef = useRef(null);
  const [detected, setDetected] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [cameraReady, setCameraReady] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    base44.auth.me().then(u => {
      setUser(u);
      setLoading(false);
    }).catch(() => {
      setUser(null);
      setLoading(false);
    });
  }, []);

  const processRoomCode = useCallback(async (roomCode) => {
    if (hasScannedRef.current) return;

    hasScannedRef.current = true;
    setDetected(true);
    setScanning(true);

    // Success beep
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain); gain.connect(ctx.destination);
      osc.frequency.value = 880; osc.type = "sine";
      gain.gain.setValueAtTime(0.3, ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + 0.25);
      osc.start(); osc.stop(ctx.currentTime + 0.25);
    } catch (_) {}

    const currentUser = await base44.auth.me().catch(() => null);
    if (!currentUser) {
      localStorage.setItem("spy_pending_join", roomCode);
      base44.auth.redirectToLogin(createPageUrl("Home"));
      return;
    }

    try {
      const displayName = currentUser.display_name || currentUser.full_name || currentUser.email.split("@")[0];
      const avatar = accountAvatarForDisplay(currentUser.avatar);
      const room = await joinGameRoom({
        roomCode,
        player: { name: displayName, avatar },
      });

      localStorage.setItem("spy_active_room_id", room.id);
      setTimeout(() => navigate(createPageUrl("Room") + `?id=${room.id}`), 700);
    } catch (joinError) {
      if (joinError?.status === 401) {
        localStorage.setItem("spy_pending_join", roomCode);
        base44.auth.redirectToLogin(createPageUrl("Home"));
        return;
      }
      alert(joinError?.status === 404 ? t('qr_scan_room_not_found') : (joinError?.message || t('qr_scan_room_not_found')));
      navigate(createPageUrl("Home"));
    }
  }, [navigate, t]);

  useEffect(() => {
    if (loading) return;
    if (scannerRef.current) return;

    let stopped = false;
    let stream = null;
    let rafId = null;
    let scanInFlight = false;
    let lastScanAt = 0;

    const startCamera = async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: "environment", width: { ideal: 1280 }, height: { ideal: 720 } }
        });
        const video = document.createElement("video");
        video.srcObject = stream;
        video.setAttribute("playsinline", "true");
        video.muted = true;
        await video.play();

        // Mount video into qr-reader div
        const container = document.getElementById("qr-reader");
        container.innerHTML = "";
        video.style.cssText = "position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;object-position:center;display:block;";
        container.appendChild(video);
        scannerRef.current = {
          stop: () => {
            stopped = true;
            try { stream.getTracks().forEach(t => t.stop()); } catch (_) {}
            try { cancelAnimationFrame(rafId); } catch (_) {}
            try { if (video.parentNode) video.parentNode.removeChild(video); } catch (_) {}
          }
        };

        const frameCanvas = document.createElement("canvas");
        let detector = null;
        if (typeof window.BarcodeDetector !== "undefined") {
          try {
            detector = new window.BarcodeDetector({ formats: ["qr_code"] });
          } catch (_) {}
        }
        setCameraReady(true);

        const tick = async (timestamp) => {
          if (stopped || hasScannedRef.current) return;

          if (
            !scanInFlight
            && timestamp - lastScanAt >= 125
            && video.readyState === video.HAVE_ENOUGH_DATA
          ) {
            scanInFlight = true;
            lastScanAt = timestamp;
            try {
              const context = drawVideoCenterCrop(video, frameCanvas);
              const decodedText = context
                ? await decodeQRCodeFrame(frameCanvas, { nativeDetector: detector })
                : null;
              const roomCode = decodedText
                ? roomCodeFromPayload(decodedText, { currentOrigin: window.location.origin })
                : null;
              if (roomCode) {
                void processRoomCode(roomCode);
                return;
              }
            } catch (_) {}
            finally {
              scanInFlight = false;
            }
          }
          rafId = requestAnimationFrame(tick);
        };
        rafId = requestAnimationFrame(tick);
      } catch (err) {
        try { stream?.getTracks().forEach(track => track.stop()); } catch (_) {}
        if (!stopped) setError(err?.message || String(err));
      }
    };

    startCamera();

    return () => {
      stopped = true;
      const s = scannerRef.current;
      scannerRef.current = null;
      if (s) {
        try { Promise.resolve(s.stop()).catch(() => {}); } catch (_) {}
      }
    };
  }, [navigate, loading, processRoomCode]);

  if (loading) {
    return (
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100dvh", background: "#000" }}>
        <div style={{ color: "#e53535", fontFamily: "monospace", letterSpacing: 4, fontSize: 12 }}>LOADING...</div>
      </div>
    );
  }

  return (
    <div style={{
      position: "fixed",
      inset: 0,
      overflow: "hidden",
      background: "#000",
      display: "flex",
      flexDirection: "column",
      zIndex: 50
    }}>
      {/* Full-screen camera */}
      <style>{`
        #qr-reader video {
          position: absolute !important;
          top: 0 !important;
          left: 0 !important;
          width: 100% !important;
          height: 100% !important;
          object-fit: cover !important;
          object-position: center !important;
        }
        #qr-reader > * {
          position: absolute !important;
          inset: 0 !important;
        }
      `}</style>
      <div
        id="qr-reader"
        style={{
          position: "absolute",
          inset: 0,
          width: "100%",
          height: "100%",
          overflow: "hidden",
          zIndex: 0
        }}
      />

      {/* Dark overlay top */}
      <div style={{
        position: "absolute", top: 0, left: 0, right: 0, height: "18%",
        background: "linear-gradient(to bottom, rgba(0,0,0,0.85), transparent)",
        zIndex: 10, pointerEvents: "none"
      }} />
      {/* Dark overlay bottom */}
      <div style={{
        position: "absolute", bottom: 0, left: 0, right: 0, height: "30%",
        background: "linear-gradient(to top, rgba(0,0,0,0.95), transparent)",
        zIndex: 10, pointerEvents: "none"
      }} />

      {/* Center scan frame */}
      <div style={{
        position: "absolute", top: "50%", left: "50%",
        transform: "translate(-50%, -50%)",
        zIndex: 20, pointerEvents: "none"
      }}>
        <div style={{
          width: 220, height: 220, position: "relative",
          boxShadow: scanning ? "0 0 0 4000px rgba(0,0,0,0.45)" : "0 0 0 4000px rgba(0,0,0,0.35)",
          borderRadius: 4
        }}>
          {/* Corner accents */}
          {[["top","left"],["top","right"],["bottom","left"],["bottom","right"]].map(([v,h], i) => (
            <div key={i} style={{
              position: "absolute", [v]: -2, [h]: -2, width: 28, height: 28,
              [`border${v.charAt(0).toUpperCase()+v.slice(1)}`]: `3px solid ${scanning ? "#4ade80" : "#e53535"}`,
              [`border${h.charAt(0).toUpperCase()+h.slice(1)}`]: `3px solid ${scanning ? "#4ade80" : "#e53535"}`,
              transition: "border-color 0.3s",
              boxShadow: scanning ? `${h === "left" ? "-" : ""}4px ${v === "top" ? "-" : ""}4px 12px rgba(74,222,128,0.4)` : "none"
            }} />
          ))}
          {/* Scan line */}
          {cameraReady && !scanning && (
            <motion.div
              animate={{ top: ["0%", "100%", "0%"] }}
              transition={{ duration: 2.5, repeat: Infinity, ease: "linear" }}
              style={{
                position: "absolute", left: 0, right: 0, height: 2,
                background: "linear-gradient(to right, transparent, #e53535, transparent)",
                boxShadow: "0 0 8px #e53535"
              }}
            />
          )}
        </div>
      </div>

      {/* Bottom info */}
      <div style={{
        position: "absolute", bottom: 0, left: 0, right: 0,
        zIndex: 30,
        background: "linear-gradient(to top, rgba(0,0,0,1) 60%, transparent)",
        padding: "60px 24px 36px",
        display: "flex", flexDirection: "column", alignItems: "center", gap: 10, textAlign: "center"
      }}>
        <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 22, letterSpacing: 3, color: "#fff" }}>
          {t('qr_scan_title')}
        </div>
        <div style={{ fontSize: 11, color: "#666", letterSpacing: 1, fontFamily: "monospace" }}>
          {t('qr_scan_instruction')}
        </div>
        {error && (
          <div style={{ fontSize: 10, color: "#e53535", letterSpacing: 1 }}>
            {t('qr_scan_error').replace('{error}', error)}
          </div>
        )}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: "100%", marginTop: 8 }}>
          <button
            onClick={async () => { const s = scannerRef.current; scannerRef.current = null; if (s) { try { await s.stop(); } catch(_) {} } navigate(createPageUrl("Home")); }}
            className="btn-ghost"
            style={{ padding: "10px 16px", display: "flex", alignItems: "center", gap: 6, fontSize: 11, letterSpacing: 2 }}
          >
            <ArrowLeft size={16} /> {t('qr_scan_back')}
          </button>
          <div style={{
            fontSize: 10, letterSpacing: 2, color: cameraReady ? "#4ade80" : "#666",
            fontFamily: "monospace", display: "flex", alignItems: "center", gap: 6
          }}>
            <span style={{
              width: 6, height: 6, borderRadius: "50%",
              background: cameraReady ? "#4ade80" : "#444",
              display: "inline-block",
              boxShadow: cameraReady ? "0 0 8px #4ade80" : "none",
              animation: cameraReady ? "pulse 2s infinite" : "none"
            }} />
            {cameraReady ? t('qr_scan_active') : t('qr_scan_loading')}
          </div>
        </div>
      </div>

      {/* Detected overlay */}
      <AnimatePresence>
        {detected && (
          <motion.div
            initial={{ scale: 0.8, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            style={{
              position: "absolute", inset: 0, zIndex: 30,
              background: "rgba(0,0,0,0.85)",
              display: "flex", flexDirection: "column",
              alignItems: "center", justifyContent: "center", gap: 16
            }}
          >
            <CheckCircle size={64} color="#4ade80" />
            <div style={{ fontSize: 18, fontWeight: 700, color: "#4ade80", letterSpacing: 3, fontFamily: "'Rajdhani', sans-serif" }}>
              {t('qr_scan_detected')}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

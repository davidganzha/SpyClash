import { useEffect, useRef, useState } from "react";
import { Html5Qrcode } from "html5-qrcode";
import { X, CheckCircle } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";

export default function QRScanner({ onScan, onClose }) {
  const { t } = useLanguage();
  const hasScannedRef = useRef(false);
  const scannerRef = useRef(null);
  const [detected, setDetected] = useState(false);

  useEffect(() => {
    let scanner = null;

    const startScanner = async () => {
      try {
        console.log("🎥 Initializing QR scanner...");
        scanner = new Html5Qrcode("qr-reader");
        scannerRef.current = scanner;

        await scanner.start(
          { facingMode: "environment" },
          {
            fps: 60,
            qrbox: function(viewfinderWidth, viewfinderHeight) {
              const minEdgeSize = Math.min(viewfinderWidth, viewfinderHeight);
              const qrboxSize = Math.floor(minEdgeSize * 0.8);
              return {
                width: qrboxSize,
                height: qrboxSize
              };
            },
            aspectRatio: 1.0,
            disableFlip: false,
            experimentalFeatures: {
              useBarCodeDetectorIfSupported: true
            }
          },
          (decodedText) => {
            if (hasScannedRef.current) {
              console.log("⚠️ Already processed, skipping");
              return;
            }

            console.log("✅ QR detected:", decodedText);
            hasScannedRef.current = true;
            setDetected(true);

            // Останавливаем сканер и вызываем callback
            scanner.stop().then(() => {
              console.log("📸 Scanner stopped, calling onScan");
              setTimeout(() => onScan(decodedText), 500);
            }).catch(() => {
              console.log("📸 Error stopping, but calling onScan anyway");
              setTimeout(() => onScan(decodedText), 500);
            });
          }
        );

        console.log("✅ Scanner started successfully");
      } catch (err) {
        console.error("❌ Failed to start scanner:", err);
        alert("Не удалось запустить камеру: " + err.message);
      }
    };

    startScanner();

    return () => {
      if (scannerRef.current) {
        scannerRef.current.stop().catch(() => {});
      }
    };
  }, [onScan]);

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(0,0,0,0.98)",
        zIndex: 9999,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: 20
      }}
    >
      <div style={{ marginBottom: 24, textAlign: "center", position: "relative", zIndex: 10001 }}>
        <div style={{ fontSize: 18, fontWeight: 700, letterSpacing: 3, color: "#e53535", marginBottom: 8 }}>
          СКАНИРОВАТЬ QR-КОД
        </div>
        <div style={{ fontSize: 12, color: "#666", letterSpacing: 1 }}>
          Наведите камеру на QR-код комнаты
        </div>
      </div>

      <div
        id="qr-reader"
        style={{
          width: "100%",
          maxWidth: 400,
          border: "2px solid #e53535",
          borderRadius: 4,
          position: "relative",
          zIndex: 10000
        }}
      />

      <button
        onClick={() => {
          console.log("❌ Closing scanner");
          if (scannerRef.current) {
            scannerRef.current.stop().catch(() => {});
          }
          onClose();
        }}
        className="btn-red"
        style={{
          position: "fixed",
          bottom: 40,
          left: "50%",
          transform: "translateX(-50%)",
          width: "auto",
          padding: "14px 32px",
          display: "flex",
          alignItems: "center",
          gap: 10,
          zIndex: 10002,
          boxShadow: "0 6px 20px rgba(229,53,53,0.8)",
          fontSize: 14
        }}
      >
        <X size={22} />
        <span style={{ fontSize: 13, letterSpacing: 2, fontWeight: 700 }}>{t('close') || 'ЗАКРЫТЬ'}</span>
      </button>

      <AnimatePresence>
        {detected && (
          <motion.div
            initial={{ scale: 0, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            exit={{ scale: 0, opacity: 0 }}
            style={{
              position: "fixed",
              top: "50%",
              left: "50%",
              transform: "translate(-50%, -50%)",
              background: "rgba(0,0,0,0.9)",
              border: "2px solid #4ade80",
              borderRadius: 12,
              padding: "24px 32px",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              gap: 12,
              zIndex: 10003
            }}
          >
            <CheckCircle size={48} color="#4ade80" />
            <div style={{ fontSize: 16, fontWeight: 700, color: "#4ade80", letterSpacing: 2 }}>
              КОД ОБНАРУЖЕН!
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}